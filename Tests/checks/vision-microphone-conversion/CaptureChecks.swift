import AVFoundation
import Foundation
import os

struct InjectedFailure: LocalizedError { var errorDescription: String? { "injected graph failure" } }
final class CaptureGraph: VisionAudioGraphDriving {
    var recordPermissionGranted = true
    var profiles: [VisionAudioProfile] = []
    var inputs: [VisionAudioCaptureGraph?] = []
    var format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var failStart = false, failDeactivate = false
    var duringStart: (() -> Void)?
    func configure(_ profile: VisionAudioProfile) throws { profiles.append(profile) }
    func start(playback: VisionAudioPlaybackGraph?, capture: VisionAudioCaptureGraph?) throws {
        inputs.append(capture)
        capture?.formatChanged(format)
        let hook = duringStart; duringStart = nil; hook?()
        if failStart { throw InjectedFailure() }
    }
    func stop() throws {}
    func deactivate() throws { if failDeactivate { throw InjectedFailure() } }
}
func pump(_ until: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}
func feed(_ graph: VisionAudioCaptureGraph?, frames: AVAudioFrameCount = 4_800) {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.25 }
    graph?.copyInput(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
}
func runAdapterChecks() {
    var complete = false
    Task { @MainActor in
        let d = CaptureGraph(), owner = UUID(), gate = OSAllocatedUnfairLock(initialState: false)
        let hw = VisionAudioHardware(driver: d)
        var permissions = 0
        let denied = VisionMicrophoneCapture(hardware: hw, owner: owner, permitted: { false }, requestPermission: {
            permissions += 1; return true
        }, closeFrames: {}, failed: { _ in })
        do { try await denied.start { _ in }; check(false,"missing grant refused") }
        catch { check(permissions == 0 && d.profiles.isEmpty, "missing grant requests no permission or hardware") }

        var pendingPermission: CheckedContinuation<Bool,Never>?
        var startFinished = false
        let pending = VisionMicrophoneCapture(hardware: hw, owner: owner, permitted: { true }, requestPermission: {
            permissions += 1
            return await withCheckedContinuation { pendingPermission = $0 }
        }, closeFrames: { gate.withLock { $0 = false } }, failed: { _ in })
        Task { @MainActor in
            do { try await pending.start { _ in }; check(false,"permission continuation cannot resurrect stop") }
            catch {}
            startFinished = true
        }
        while pendingPermission == nil { await Task.yield() }
        do { try pending.stop() } catch { check(false,"pending permission stop is clean") }
        pendingPermission?.resume(returning: true)
        while !startFinished { await Task.yield() }
        check(d.profiles.isEmpty, "permission grant after stop cannot configure hardware")

        let frames = OSAllocatedUnfairLock(initialState: [IPadMicrophonePCMFrame]())
        var nativeFailures = 0
        let capture = VisionMicrophoneCapture(hardware: hw, owner: owner, permitted: { true }, requestPermission: {
            permissions += 1; return true
        }, closeFrames: { gate.withLock { $0 = false } }, failed: { _ in nativeFailures += 1 })
        do {
            d.duringStart = { feed(d.inputs.last!) }
            try await capture.start { batch in
                if gate.withLock({ $0 }) { frames.withLock { $0.append(contentsOf: batch) } }
            }
            check(frames.withLock { $0.isEmpty }, "capture readiness does not open transport before caller consent")
            gate.withLock { $0 = true }
            feed(d.inputs.last!)
            let deadline = Date().addingTimeInterval(2)
            while frames.withLock({ $0.count }) < 5 && Date() < deadline { await Task.yield() }
            check(frames.withLock { $0.count == 5 }, "committed capture converts complete hardware buffer")
            let speaker = hw.reserve(owner: owner, role: .playback, epoch: UUID())!
            try hw.startPlayback(speaker, format: VisionAudioFormat(rate: 48_000, channels: 1)!, version: 1,
                                 authorization: { .current }, render: { _,_,_,_ in noErr })
            feed(d.inputs.last!)
            let nextDeadline = Date().addingTimeInterval(2)
            while frames.withLock({ $0.count }) < 10 && Date() < nextDeadline { await Task.yield() }
            check(frames.withLock { $0.count == 10 && $0[5].sequence == 6 }, "duplex format rebuild preserves wire sequence within grant")
            check(d.profiles.last == .microphone, "speaker and capture share one microphone profile")
            _ = hw.close(speaker)
            hw.invalidate("injected route loss")
            check(!gate.withLock({ $0 }) && nativeFailures == 1, "native failure synchronously closes frames and reports current attempt")
            do { try capture.stop(); check(false,"uncertain cleanup must be retained") } catch {}
            try capture.retryCleanup()
            check(hw.cleanupProblem == nil, "explicit capture cleanup retires same quarantined owner")
        } catch { check(false, "capture integration unexpected \(error)") }

        let d2 = CaptureGraph()
        let hardware2 = VisionAudioHardware(driver: d2)
        let failedCapture = VisionMicrophoneCapture(hardware: hardware2, owner: owner, permitted: { true }, requestPermission: { true }, closeFrames: {}, failed: { _ in })
        d2.failStart = true
        do { try await failedCapture.start { _ in }; check(false,"failed native start refused") }
        catch { check(hardware2.cleanupProblem != nil, "throw before claim return retains exact owner quarantine") }
        d2.failStart = false; d2.failDeactivate = true
        do { try failedCapture.retryCleanup(); check(false,"cleanup failure must persist") } catch {}
        check(hardware2.cleanupProblem != nil, "failed cleanup retry preserves quarantine")
        d2.failDeactivate = false
        do { try failedCapture.retryCleanup() } catch { check(false,"same owner cleanup should recover") }
        check(hardware2.cleanupProblem == nil, "successful cleanup without a returned claim releases ownership")

        let d3 = CaptureGraph()
        let h3 = VisionAudioHardware(driver: d3)
        let playback = h3.reserve(owner: owner, role: .playback, epoch: UUID())!
        var authorization = VisionAudioPlaybackAuthorization.current
        do { try h3.startPlayback(playback, format: VisionAudioFormat(rate: 48_000, channels: 1)!, version: 1, authorization: { authorization }, render: { _,_,_,_ in noErr }) }
        catch { check(false,"pending readiness setup") }
        var readyFinished = false, readySucceeded = false
        let waiting = VisionMicrophoneCapture(hardware: h3, owner: owner, permitted: { true }, requestPermission: { true }, closeFrames: {}, failed: { _ in })
        d3.duringStart = { authorization = .superseded }
        let previous = d3.inputs.count
        Task { @MainActor in
            do { try await waiting.start { _ in }; readySucceeded = true } catch {}
            readyFinished = true
        }
        while d3.inputs.count == previous { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        check(!readyFinished, "reserved capture waits until actual graph commits")
        do { try h3.startPlayback(playback, format: VisionAudioFormat(rate: 44_100, channels: 1)!, version: 2, authorization: { .current }, render: { _,_,_,_ in noErr }) }
        catch { check(false,"newer playback graph should commit capture") }
        while !readyFinished { await Task.yield() }
        check(readySucceeded && h3.cleanupProblem == nil, "later committed graph completes capture readiness")
        do { try waiting.stop() } catch { check(false,"committed capture stop") }
        _ = h3.close(playback)
        complete = true
    }
    pump { complete }
    check(complete, "bounded asynchronous capture checks finish")
}
