import AVFoundation
import Foundation
import os
import StreamProtocol

@main struct RenderLevelChecks {
    static var checks = 0
    static func check(_ value: Bool, _ reason: String) { checks += 1; precondition(value, reason) }
    @MainActor static func drain(_ player: PlaybackProbe) async {
        player.drainDecode()
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }
    static func render(_ source: FakeAudioSourceNode, frames: Int = 4, channels: Int = 2) -> [Float] {
        let buffers = AudioBufferList.allocate(maximumBuffers: channels)
        let samples = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { samples.forEach { $0.deallocate() }; buffers.unsafeMutablePointer.deallocate() }
        for channel in 0..<channels {
            samples[channel].initialize(repeating: 99, count: frames)
            buffers[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: samples[channel])
        }
        var silence = ObjCBool(false), stamp = AudioTimeStamp()
        check(source.render(&silence, &stamp, AVAudioFrameCount(frames), buffers.unsafeMutablePointer) == noErr,
              "actual callback succeeds with synthetic destinations")
        return samples.flatMap { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }
    @MainActor static func metadata(_ counter: IPadMicrophoneDiagnostics.RenderCounters, _ name: String) throws -> [String: Any] {
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name)
        let log = IPadMicrophoneDiagnostics(fileURL: base.appendingPathComponent("events.json"))
        let runtime = IPadMicrophoneDiagnostics.Runtime(connected: true, foreground: true,
            sourceKind: "desktop", sourceID: nil, generation: nil, videoEpoch: nil,
            microphoneDesired: false, playbackDesired: true, microphonePhase: "off", playbackPhase: "starting",
            capturePresent: false, captureRunning: nil, cachedAudioPrivacyProtected: true,
            forwardingPhase: "active", sentryPhase: nil, sentryRequested: nil, hostBootID: nil, hostSessionID: nil)
        log.snapshot(runtime: runtime, render: counter, playbackRunning: true, session: [:])
        log.flush()
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String: Any]
        return document["render"] as! [String: Any]
    }
    @MainActor static func main() async throws {
        let player = PlaybackProbe()
        let input = (0..<4800).map { [Int16(16384), -16384, 0, 32767][$0 % 4] }
        let packet = input.withUnsafeBufferPointer { AudioPacket.pack(sampleRate: 48000, channels: 2, samples: $0) }
        player.receive(packet, subscription: UUID()) { _ in }
        await drain(player)
        check(player.buffered == 4800 && player.diagnosticRender?.finiteCopiedSamples == 0,
              "received and decoded samples do not count as callback copies")
        let unobserved = try metadata(player.diagnosticRender!, "unobserved")
        check(unobserved["copiedSampleRMS"] is NSNull, "no copied finite samples means unknown RMS")
        let oldSource = player.currentEngine!.source!
        let copied = render(oldSource)
        let first = player.diagnosticRender!
        let expected = copied.reduce(0.0) { $0 + Double($1) * Double($1) }
        check(first.copiedFrames == 4 && first.finiteCopiedSamples == 8 && first.nonzeroCopiedSamples == 6,
              "only actual per-channel destination copies contribute samples and nonzero count")
        check(first.copiedSampleSumSquares == expected && first.copiedSamplePeak == Double(copied.map(abs).max()!),
              "sum squares and peak agree with actual destination memory")
        let positive = try metadata(first, "positive")
        check(abs((positive["copiedSampleRMS"] as! Double) - (expected / 8).squareRoot()) < 1e-12,
              "snapshot computes RMS from the copied-sample aggregate")
        check(positive["attempt"] as? String == first.attempt.uuidString && positive["formatVersion"] as? UInt64 == first.formatVersion,
              "level metadata retains attempt and formatVersion")
        _ = render(oldSource, frames: 2400)
        let exhausted = player.diagnosticRender!
        _ = render(oldSource)
        check(player.diagnosticRender!.finiteCopiedSamples == exhausted.finiteCopiedSamples && player.diagnosticRender!.silenceFilledFrames > exhausted.silenceFilledFrames,
              "underrun silence fill does not contribute copied samples")
        player.stop()
        let stopped = player.diagnosticRender!
        check(render(oldSource).allSatisfy { $0 == 0 } && player.diagnosticRender!.finiteCopiedSamples == stopped.finiteCopiedSamples,
              "stop fences retained callback without adding level evidence")
        let nextAttempt = UUID()
        player.seedDecoded(Array(repeating: 0, count: 4800), rate: 32000, attempt: nextAttempt)
        await drain(player)
        let fresh = player.diagnosticRender!
        check(fresh.attempt == nextAttempt && fresh.formatVersion != first.formatVersion && fresh.finiteCopiedSamples == 0
              && fresh.nonzeroCopiedSamples == 0 && fresh.copiedSampleSumSquares == 0 && fresh.copiedSamplePeak == 0,
              "new attempt and format reset every aggregate")
        _ = render(oldSource)
        check(player.diagnosticRender!.finiteCopiedSamples == 0, "late old format callback cannot contaminate new counters")
        check(render(player.currentEngine!.source!).allSatisfy { $0 == 0 }, "actual copied zero-valued stream stays zero")
        let zero = player.diagnosticRender!
        let zeroMetadata = try metadata(zero, "zero")
        check(zero.finiteCopiedSamples == 8 && zero.nonzeroCopiedSamples == 0 && zero.copiedSamplePeak == 0
              && zeroMetadata["copiedSampleRMS"] as? Double == 0, "copied silence is measured zero rather than unknown")
        player.stop()
        player.seedDecoded([.nan, .infinity, -.infinity, .greatestFiniteMagnitude] + Array(repeating: 0, count: 4796), attempt: UUID())
        await drain(player)
        let nonfiniteOutput = render(player.currentEngine!.source!)
        let finite = player.diagnosticRender!
        check(nonfiniteOutput.contains { !$0.isFinite } && finite.finiteCopiedSamples == 5 && finite.nonzeroCopiedSamples == 1,
              "nonfinite destinations are excluded from aggregates without changing playback samples")
        check(finite.copiedSampleSumSquares.isFinite && finite.copiedSamplePeak == Double(Float.greatestFiniteMagnitude),
              "Float maximum is squared in Double without overflow")
        let finiteMetadata = try metadata(finite, "finite")
        check((finiteMetadata["copiedSampleRMS"] as! Double).isFinite, "finite guard keeps metadata JSON encodable")
        player.stop()
        let peer = NSObject(), time = OSAllocatedUnfairLock(initialState: 0.0)
        let admission = IPadAudioAdmission(now: { time.withLock { $0 } })
        admission.bind(ObjectIdentifier(peer))
        _ = admission.observe(WindowList(macName: "fixture", windows: [], active: .desktop, remoteAudio: 1,
            audioPrivacy: .init(version: 2, protected: true)), from: ObjectIdentifier(peer))
        admission.forwarding(peer: ObjectIdentifier(peer), microphone: false, playback: true, deadline: 10)
        let gated = PlaybackProbe(admission: admission)
        gated.seedDecoded(Array(repeating: 0.5, count: 4800), attempt: UUID(), ticket: admission.ticket(for: ObjectIdentifier(peer)))
        await drain(gated)
        let gateSource = gated.currentEngine!.source!
        _ = render(gateSource)
        let beforeDenied = gated.diagnosticRender!
        time.withLock { $0 = 11 }
        check(render(gateSource).allSatisfy { $0 == 0 }, "expired admission writes silence to all destinations")
        let denied = gated.diagnosticRender!
        check(denied.admissionDeniedFrames == 4 && denied.finiteCopiedSamples == beforeDenied.finiteCopiedSamples
              && denied.nonzeroCopiedSamples == beforeDenied.nonzeroCopiedSamples && denied.copiedSampleSumSquares == beforeDenied.copiedSampleSumSquares
              && denied.copiedSamplePeak == beforeDenied.copiedSamplePeak, "admission denial adds no copied-level evidence")
        gated.stop()
        var saturated = IPadMicrophoneDiagnostics.RenderCounters(attempt: UUID(), formatVersion: 1)
        saturated.finiteCopiedSamples = UInt64.max
        saturated.recordCopiedSample(1)
        check(saturated.finiteCopiedSamples == UInt64.max && saturated.copiedSampleSumSquares == 0, "sample count saturation cannot wrap the RMS denominator")
        print("PASS \(checks) actual render callback and snapshot level assertions; synthetic buffers, no audio hardware")
    }
}
