import AVFoundation
import Foundation
import os

final class IPadMicrophoneDiagnostics: @unchecked Sendable {
    struct Attempt: Sendable {
        let id: UUID
        let log: IPadMicrophoneDiagnostics
        func count(_ metric: Metric, _ amount: UInt64 = 1, errorCode: Int? = nil) {
            log.count(id, metric, amount, errorCode: errorCode)
        }
        func record(_ event: String, _ fields: @autoclosure () -> [String: String] = [:]) { log.record(id, event, fields) }
    }
    private struct Event: Codable {
        let timestamp: Double
        let uptimeNanoseconds: UInt64
        let attempt: UUID
        let event: String
        let fields: [String: String]
    }
    enum Metric: String, Codable, CaseIterable {
        case admittedPlaybackPackets, decodedPackets, decodedFrames, emptyDecodedPackets
        case decoderUnavailable, decodeErrors, invalidAudioPackets, stalePlaybackPackets
        case tapBuffers, tapFrames, convertedFrames, capturePackets, capturePacketFrames, conversionErrors
        case sendSubmittedBatches, sendSubmittedPackets, sendSubmittedFrames
        case sendCompletedBatches, sendFailedBatches, captureDroppedBuffers, gateDroppedBatches
        case captureStartErrors, playbackStartErrors
    }
    enum ReceptionKind: String { case catalog, audioPacket, remoteAudioState, sentryState, microphoneReceipt }
    struct Reception: Codable {
        let messages: UInt64
        let observedAt: Double
        let observedUptimeNanoseconds: UInt64
        let hostTimestamp: Double?
        let generation: UUID?
        let videoEpoch: UUID?
    }
    func received(_ kind: ReceptionKind, hostTimestamp: Double, generation: UUID? = nil, videoEpoch: UUID? = nil) {
        state.withLock { value in
            let old = value.receptions[kind.rawValue]?.messages ?? 0
            value.receptions[kind.rawValue] = Reception(messages: old == UInt64.max ? old : old + 1,
                observedAt: Date().timeIntervalSince1970,
                observedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                hostTimestamp: hostTimestamp.isFinite ? hostTimestamp : nil, generation: generation, videoEpoch: videoEpoch)
        }
    }

    func connectionChanged() {
        state.withLock {
            $0.connectionObservationID = UUID()
            $0.receptions.removeAll(keepingCapacity: true)
            $0.runtime = nil
            $0.latestSnapshot = nil
        }
    }
    struct Runtime: Codable {
        var connected: Bool
        var foreground: Bool
        var sourceKind: String?
        var sourceID: UInt32?
        var generation: UUID?
        var videoEpoch: UUID?
        var microphoneDesired: Bool
        var playbackDesired: Bool
        var microphonePhase: String
        var playbackPhase: String
        var capturePresent: Bool
        var captureRunning: Bool?
        var cachedAudioPrivacyProtected: Bool?
        var forwardingPhase: String
        var sentryPhase: String?
        var sentryRequested: Bool?
        var hostBootID: UUID?
        var hostSessionID: UUID?
    }
    struct AttemptCounters: Codable {
        let attempt: UUID
        let firstObservedAt: Double
        let firstObservedUptime: UInt64
        let connectionObservationID: UUID
        let scopeAtFirstObservation: Runtime?
        var counters: [String: UInt64] = [:]
        var lastErrorCode: Int?
        var lastErrorMetric: Metric?
        var lastObservedAt: Double
    }
    struct RenderCounters: Codable {
        let attempt: UUID
        let formatVersion: UInt64
        var callbacks: UInt64 = 0
        var requestedFrames: UInt64 = 0
        var copiedFrames: UInt64 = 0
        var silenceFilledFrames: UInt64 = 0
        var underrunTransitions: UInt64 = 0
        var admissionDeniedFrames: UInt64 = 0
    }
    private let observationID = UUID()
    private let observationStartedAt = Date().timeIntervalSince1970
    private let observationStartedUptime = DispatchTime.now().uptimeNanoseconds
    private struct Storage {
        var connectionObservationID = UUID()
        var receptions: [String: Reception] = [:]
        var counters: [UUID: AttemptCounters] = [:]
        var counterOrder: [UUID] = []
        var runtime: Runtime?
        var latestSnapshot: [String: Any]?
        var snapshotPending = false
        var nextSnapshotUptime: UInt64 = 0
        var events: [Event] = []
        var seen: [UUID: Set<String>] = [:]
        var attempts: [UUID] = []
        var scheduled = false
    }
    static let shared = IPadMicrophoneDiagnostics(fileURL: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("CCR Sill/microphone-diagnostics.json"))
    let fileURL: URL
    private let state = OSAllocatedUnfairLock(initialState: Storage())
    private let writer = DispatchQueue(label: "sill.microphone.diagnostics", qos: .utility)

    init(fileURL: URL) { self.fileURL = fileURL }
    func attempt(_ id: UUID) -> Attempt {
        state.withLock { ensureAttempt(id, in: &$0) }
        return Attempt(id: id, log: self)
    }
    private func ensureAttempt(_ id: UUID, in value: inout Storage) {
        guard value.counters[id] == nil else { return }
        if value.counterOrder.count == 8 { value.counters.removeValue(forKey: value.counterOrder.removeFirst()) }
        value.counterOrder.append(id)
        value.counters[id] = AttemptCounters(attempt: id, firstObservedAt: Date().timeIntervalSince1970,
            firstObservedUptime: DispatchTime.now().uptimeNanoseconds, connectionObservationID: value.connectionObservationID, scopeAtFirstObservation: value.runtime,
            lastObservedAt: Date().timeIntervalSince1970)
    }
    private func count(_ id: UUID, _ metric: Metric, _ amount: UInt64, errorCode: Int?) {
        state.withLock { value in
            // Late callbacks from evicted attempts must not displace the current eight attempts.
            guard var counter = value.counters[id] else { return }
            let old = counter.counters[metric.rawValue] ?? 0
            counter.counters[metric.rawValue] = old > UInt64.max - amount ? UInt64.max : old + amount
            counter.lastObservedAt = Date().timeIntervalSince1970
            if let errorCode { counter.lastErrorCode = errorCode; counter.lastErrorMetric = metric }
            value.counters[id] = counter
        }
    }
    var snapshotURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("audio-metadata-snapshot.json") }

    /// Called by existing main-queue lifecycle/statistics work, never by the audio callback.
    func snapshot(runtime: Runtime, render: RenderCounters?, playbackRunning: Bool, session: @autoclosure () -> [String: Any]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = DispatchTime.now().uptimeNanoseconds
        let observation = state.withLock { value in
            value.runtime = runtime
            return (id: value.connectionObservationID, receptions: value.receptions,
                counters: value.counterOrder.compactMap { value.counters[$0] })
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let null = NSNull()
        let encode: (any Encodable) -> Any = { value in
            guard let data = try? JSONEncoder().encode(value),
                  let result = try? JSONSerialization.jsonObject(with: data) else { return null }
            return result
        }
        let reception = (id: observation.id, latest: observation.receptions)
        let latest = reception.latest.values.max { $0.observedUptimeNanoseconds < $1.observedUptimeNanoseconds }
        let verified = info["CCRSourceIdentityVerified"] as? Bool == true
        let document: [String: Any] = [
            "schema": "ccr.ipad.audio-metadata/v1", "generatedAt": Date().timeIntervalSince1970,
            "appObservationSampledAt": Date().timeIntervalSince1970,
            "connectionObservationID": reception.id.uuidString, "receivedObservations": encode(reception.latest),
            "sentryAndAudioPrivacyScope": "cached received Host reports only; not current HAL observation or protection verification",
            "observationScope": "current app process metadata; no live acceptance claim",
            "sampledUptimeNanoseconds": now, "observedAt": latest?.observedAt ?? (null as Any),
            "observedUptimeNanoseconds": latest?.observedUptimeNanoseconds ?? (null as Any),
            "receivedObservationsScope": "current peer envelopes observed by app; not payload acceptance or current HAL state",
            "observationID": observationID.uuidString,
            "observationStartedAt": observationStartedAt, "observationStartedUptimeNanoseconds": observationStartedUptime,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "build": info["CFBundleVersion"] as? String ?? (null as Any),
            "version": info["CFBundleShortVersionString"] as? String ?? (null as Any),
            "commit": verified ? (info["CCRSourceCommit"] as? String ?? (null as Any)) : null,
            "tree": verified ? (info["CCRSourceTree"] as? String ?? (null as Any)) : null,
            "sourceIdentityVerified": verified,
            "runtime": encode(runtime), "audioSession": session(), "attempts": encode(observation.counters),
            "render": render.map { encode($0) } ?? null, "playbackEngineRunning": playbackRunning,
            "counterScope": "instrumented boundaries per attempt in this process; absent counters/fields are unknown; not Host receipts",
            "renderScope": "per attempt and formatVersion, possibly retired; frames copied or silence-filled; no sample inspection or audible-output proof",
            "hostClockOffsetSeconds": null, "hostMediaCounters": null]
        let deadline = state.withLock { value -> UInt64? in
            guard value.connectionObservationID == observation.id else { return nil }
            value.latestSnapshot = document
            guard !value.snapshotPending else { return nil }
            value.snapshotPending = true
            return value.nextSnapshotUptime
        }
        guard let deadline else { return }
        if deadline <= now { writer.async { [self] in persistSnapshot() } }
        else { writer.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [self] in persistSnapshot() } }
    }
    private func persistSnapshot() {
        let document = state.withLock { value -> [String: Any]? in
            value.snapshotPending = false
            guard let document = value.latestSnapshot else { return nil }
            value.latestSnapshot = nil
            value.nextSnapshotUptime = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            return document
        }
        guard let document else { return }
        do {
            try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            guard data.count <= 65_536 else { return }
            try data.write(to: snapshotURL, options: .atomic)
        } catch { NSLog("Sill audio metadata snapshot write failed (code %ld)", (error as NSError).code) }
    }
    private func record(_ id: UUID, _ event: String, _ fields: () -> [String: String]) {
        let metric: Metric?
        if event.hasPrefix("tap_drop_") { metric = .captureDroppedBuffers }
        else if event.hasPrefix("gate_drop_") { metric = .gateDroppedBatches }
        else if event == "engine_start_error" { metric = .captureStartErrors }
        else if event == "playback_engine_failed" || event == "playback_format_failed" { metric = .playbackStartErrors }
        else { metric = nil }
        if let metric { count(id, metric, 1, errorCode: nil) }
        let schedule = state.withLock { value -> Bool in
            if value.seen[id] == nil {
                if value.attempts.count == 8 { value.seen.removeValue(forKey: value.attempts.removeFirst()) }
                value.attempts.append(id)
                value.seen[id] = []
            }
            guard value.seen[id]!.count < 32, value.seen[id]!.insert(event).inserted else { return false }
            if value.events.count == 128 { value.events.removeFirst() }
            value.events.append(Event(timestamp: Date().timeIntervalSince1970,
                uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds, attempt: id,
                event: String(event.prefix(64)), fields: Dictionary(uniqueKeysWithValues: fields().sorted { $0.key < $1.key }.prefix(16)
                    .map { (String($0.key.prefix(64)), String($0.value.prefix(256))) })))
            guard !value.scheduled else { return false }
            value.scheduled = true
            return true
        }
        if schedule { writer.async { [self] in persist() } }
    }
    private func persist() {
        let events = state.withLock { value -> [Event] in value.scheduled = false; return value.events }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(events).write(to: fileURL, options: .atomic)
        } catch { NSLog("Sill microphone diagnostic write failed (code %ld)", (error as NSError).code) }
    }
    func flush() { writer.sync {} }

    static func format(_ format: AVAudioFormat) -> String {
        let asbd = format.streamDescription.pointee
        return "rate=\(format.sampleRate),channels=\(format.channelCount),common=\(format.commonFormat.rawValue),interleaved=\(format.isInterleaved),bytesPerFrame=\(asbd.mBytesPerFrame),flags=\(asbd.mFormatFlags)"
    }
    #if os(iOS)
    static func route() -> String {
        let session = AVAudioSession.sharedInstance()
        return "in=\(session.currentRoute.inputs.map { $0.portType.rawValue }),out=\(session.currentRoute.outputs.map { $0.portType.rawValue }),rate=\(session.sampleRate),channels=\(session.inputNumberOfChannels),io=\(session.ioBufferDuration)"
    }
    #endif
}

/// Native capture only. The caller must first receive a matching, live Mac grant for an explicit
/// user request; constructing this object does not ask for permission or open the microphone.
#if os(iOS)
final class IPadMicrophoneCapture {
    struct AudioLease {
        let acquire: (UUID) throws -> Void
        let release: (UUID) throws -> Void
        let holds: (UUID) -> Bool

        static let iPad = AudioLease(
            acquire: { try IPadAudioSession.shared.acquire(.microphoneUplink, leaseId: $0) },
            release: { try IPadAudioSession.shared.release(leaseId: $0) },
            holds: { IPadAudioSession.shared.holds(leaseId: $0) })
    }

    enum CaptureError: LocalizedError {
        case alreadyRunning, permissionDenied, unavailableFormat, conversionUnavailable

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "iPad 마이크가 이미 사용 중입니다."
            case .permissionDenied: "iPad 마이크 권한이 필요합니다."
            case .unavailableFormat: "iPad 마이크 입력 형식을 확인할 수 없습니다."
            case .conversionUnavailable: "iPad 마이크 소리를 전송 형식으로 바꿀 수 없습니다."
            }
        }
    }

    private let worker = IPadMicrophoneConversionWorker()
    private let leaseID = UUID()
    private let audioLease: AudioLease
    private let diagnostics: IPadMicrophoneDiagnostics.Attempt?
    private var engine: AVAudioEngine?
    var diagnosticRunning: Bool { engine?.isRunning ?? false }
    private var starting = false
    private var generation = UUID()
    private var ownsLease = false

    init(audioLease: AudioLease = .iPad, diagnostics: IPadMicrophoneDiagnostics.Attempt? = nil) {
        self.audioLease = audioLease
        self.diagnostics = diagnostics
    }

    /// `emitBatch` runs on the conversion queue. Its owner must fence the exact peer and grant again
    /// before sending; a stopped capture never calls it after `stop()` returns.
    @MainActor
    func start(emitBatch: @escaping @Sendable ([IPadMicrophonePCMFrame]) -> Void) async throws {
        guard engine == nil, !starting else { throw CaptureError.alreadyRunning }
        starting = true
        let began = DispatchTime.now().uptimeNanoseconds
        diagnostics?.record("engine_setup_begin", ["route": IPadMicrophoneDiagnostics.route()])
        let attempt = UUID()
        generation = attempt
        defer { starting = false }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.permissionDenied
        }
        guard generation == attempt else { throw CancellationError() }

        do {
            try audioLease.acquire(leaseID)
            ownsLease = true
            let next = AVAudioEngine()
            let input = next.inputNode
            let format = input.outputFormat(forBus: 0)
            diagnostics?.record("engine_native_format", ["format": IPadMicrophoneDiagnostics.format(format), "route": IPadMicrophoneDiagnostics.route()])
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureError.unavailableFormat
            }
            guard let captureID = worker.beginBatch(inputFormat: format, diagnostics: diagnostics, emit: emitBatch) else {
                throw CaptureError.conversionUnavailable
            }
            input.installTap(onBus: 0, bufferSize: 960, format: format) { [worker, diagnostics] buffer, _ in
                worker.enqueue(buffer, captureID: captureID, diagnostics: diagnostics)
            }
            engine = next
            next.prepare()
            try next.start()
            diagnostics?.record("engine_started", ["elapsedMilliseconds": String(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000), "running": String(next.isRunning), "route": IPadMicrophoneDiagnostics.route()])
            guard generation == attempt else { throw CancellationError() }
        } catch {
            diagnostics?.record("engine_start_error", ["errorCode": String((error as NSError).code)])
            ownsLease = ownsLease || audioLease.holds(leaseID)
            do { try stop() } catch { throw error }
            throw error
        }
    }

    func stop() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        diagnostics?.record("capture_stop", ["running": String(engine?.isRunning ?? false), "ownsLease": String(ownsLease), "route": IPadMicrophoneDiagnostics.route()])
        generation = UUID()
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        worker.end()
        if ownsLease {
            try audioLease.release(leaseID)
            ownsLease = false
        }
    }
}
#endif

/// The tap copies at most two short buffers; conversion and packet framing stay off the render
/// callback. If work falls behind, it drops new buffers rather than stretching spoken latency.
final class IPadMicrophoneConversionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sill.ipad-microphone.convert", qos: .userInitiated)
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var packetizer = IPadMicrophonePCM()
    private var emitBatch: (@Sendable ([IPadMicrophonePCMFrame]) -> Void)?
    private var activeCaptureID: UUID?
    private var diagnostics: IPadMicrophoneDiagnostics.Attempt?

    func begin(inputFormat: AVAudioFormat, continuingStream: Bool = false,
               emit: @escaping @Sendable (IPadMicrophonePCMFrame) -> Void) -> UUID? {
        beginBatch(inputFormat: inputFormat, continuingStream: continuingStream) { batch in batch.forEach(emit) }
    }

    func beginBatch(inputFormat: AVAudioFormat, continuingStream: Bool = false,
                    diagnostics: IPadMicrophoneDiagnostics.Attempt? = nil, emit: @escaping @Sendable ([IPadMicrophonePCMFrame]) -> Void) -> UUID? {
        guard inputFormat.sampleRate.isFinite, (Double(IPadMicrophonePCM.minimumInputRate)...Double(IPadMicrophonePCM.maximumInputRate)).contains(inputFormat.sampleRate),
              (1...8).contains(inputFormat.channelCount),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(IPadMicrophonePCM.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        let captureID = UUID()
        queue.sync {
            self.diagnostics = diagnostics
            self.converter = converter
            outputFormat = output
            if continuingStream { packetizer.discardPending() } else { packetizer.reset() }
            emitBatch = emit
            activeCaptureID = captureID
        }
        return captureID
    }

    func enqueue(_ input: AVAudioPCMBuffer, captureID: UUID, diagnostics: IPadMicrophoneDiagnostics.Attempt? = nil) {
        diagnostics?.count(.tapBuffers)
        diagnostics?.count(.tapFrames, UInt64(input.frameLength))
        diagnostics?.record("first_tap", ["frames": String(input.frameLength), "capacity": String(input.frameCapacity)])
        guard input.frameLength > 0, input.frameLength <= AVAudioFrameCount(IPadMicrophonePCM.maxInputFrames) else {
            diagnostics?.record("tap_drop_size", ["frames": String(input.frameLength)])
            return
        }
        let accepted = pending.withLock { count -> Bool in
            guard count < 2 else { return false }
            count += 1
            return true
        }
        guard accepted else { diagnostics?.record("tap_drop_pending"); return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format,
                                          frameCapacity: input.frameLength) else {
            diagnostics?.record("tap_drop_copy")
            pending.withLock { $0 -= 1 }
            return
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else {
            diagnostics?.record("tap_drop_copy")
            pending.withLock { $0 -= 1 }
            return
        }
        for index in source.indices {
            guard let from = source[index].mData, let to = target[index].mData,
                  target[index].mDataByteSize >= source[index].mDataByteSize else {
                diagnostics?.record("tap_drop_copy_bytes", ["sourceBytes": String(source[index].mDataByteSize), "targetBytes": String(target[index].mDataByteSize)])
                pending.withLock { $0 -= 1 }
                return
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        queue.async { [self] in
            defer { pending.withLock { $0 -= 1 } }
            guard activeCaptureID == captureID else { diagnostics?.record("tap_drop_stale_capture"); return }
            convert(copy)
        }
    }

    func end() {
        queue.sync {
            diagnostics?.record("worker_end")
            diagnostics = nil
            activeCaptureID = nil
            emitBatch = nil
            converter = nil
            outputFormat = nil
            packetizer.reset()
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) {
        guard let converter, let outputFormat, let emitBatch else { return }
        let expanded = Int(ceil(Double(input.frameLength) * outputFormat.sampleRate / converter.inputFormat.sampleRate))
        guard (1...IPadMicrophonePCM.maxConvertedFrames).contains(expanded),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(expanded)) else { diagnostics?.count(.conversionErrors); return }
        let began = DispatchTime.now().uptimeNanoseconds
        var requestedFrames: UInt64 = 0
        var inputCalls = 0
        var cursor: AVAudioFrameCount = 0
        var slices: [AVAudioPCMBuffer] = []
        var inputFailed = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { requested, status in
            inputCalls += 1
            requestedFrames += UInt64(requested)
            guard cursor < input.frameLength else { status.pointee = .noDataNow; return nil }
            let count = min(requested, input.frameLength - cursor)
            guard count > 0, let slice = Self.slice(input, offset: cursor, count: count) else {
                inputFailed = true
                status.pointee = .noDataNow
                return nil
            }
            cursor += count
            slices.append(slice)
            status.pointee = .haveData
            return slice
        }
        withExtendedLifetime(slices) {}
        let details = ["inputFrames": String(input.frameLength), "suppliedFrames": String(cursor),
            "requestedFrames": String(requestedFrames), "inputCalls": String(inputCalls),
            "outputFrames": String(output.frameLength), "outputCapacity": String(output.frameCapacity),
            "result": String(result.rawValue), "errorCode": error.map { String($0.code) } ?? "none",
            "inputFailed": String(inputFailed), "elapsedMilliseconds": String(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)]
        diagnostics?.record("first_conversion", details)
        if output.frameLength > 0 { diagnostics?.record("first_nonzero_conversion", details) }
        if cursor < input.frameLength { diagnostics?.record("conversion_partial_input", details) }
        if inputFailed || error != nil || result == .error {
            diagnostics?.count(.conversionErrors, errorCode: error?.code)
            diagnostics?.record("conversion_error", details)
        }
        guard !inputFailed, error == nil, result != .error,
              let channel = output.floatChannelData?.pointee else { return }
        diagnostics?.count(.convertedFrames, UInt64(output.frameLength))
        let samples = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        var batch: [IPadMicrophonePCMFrame] = []
        packetizer.append(samples) { batch.append($0) }
        if !batch.isEmpty {
            diagnostics?.count(.capturePackets, UInt64(batch.count))
            diagnostics?.count(.capturePacketFrames, UInt64(batch.reduce(0) { $0 + $1.frameCount }))
            diagnostics?.record("first_batch", ["packets": String(batch.count), "firstSequence": String(batch[0].sequence)])
            emitBatch(batch)
        }
    }

    private static func slice(_ input: AVAudioPCMBuffer, offset: AVAudioFrameCount,
                              count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard offset <= input.frameLength, count <= input.frameLength - offset,
              let result = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count) else { return nil }
        result.frameLength = count
        let bytesPerFrame = Int(input.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let start = Int(offset) * bytesPerFrame, bytes = Int(count) * bytesPerFrame
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for index in source.indices {
            guard Int(source[index].mDataByteSize) >= start + bytes,
                  Int(target[index].mDataByteSize) >= bytes,
                  let from = source[index].mData, let to = target[index].mData else { return nil }
            memcpy(to, from.advanced(by: start), bytes)
        }
        return result
    }

}
