import AVFoundation
import os

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
    private var engine: AVAudioEngine?
    private var starting = false
    private var generation = UUID()
    private var ownsLease = false

    init(audioLease: AudioLease = .iPad) {
        self.audioLease = audioLease
    }

    /// `emitBatch` runs on the conversion queue. Its owner must fence the exact peer and grant again
    /// before sending; a stopped capture never calls it after `stop()` returns.
    @MainActor
    func start(emitBatch: @escaping @Sendable ([IPadMicrophonePCMFrame]) -> Void) async throws {
        guard engine == nil, !starting else { throw CaptureError.alreadyRunning }
        starting = true
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
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureError.unavailableFormat
            }
            guard let captureID = worker.beginBatch(inputFormat: format, emit: emitBatch) else {
                throw CaptureError.conversionUnavailable
            }
            input.installTap(onBus: 0, bufferSize: 960, format: format) { [worker] buffer, _ in
                worker.enqueue(buffer, captureID: captureID)
            }
            engine = next
            next.prepare()
            try next.start()
            guard generation == attempt else { throw CancellationError() }
        } catch {
            ownsLease = ownsLease || audioLease.holds(leaseID)
            do { try stop() } catch { throw error }
            throw error
        }
    }

    func stop() throws {
        dispatchPrecondition(condition: .onQueue(.main))
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

    func begin(inputFormat: AVAudioFormat, continuingStream: Bool = false,
               emit: @escaping @Sendable (IPadMicrophonePCMFrame) -> Void) -> UUID? {
        beginBatch(inputFormat: inputFormat, continuingStream: continuingStream) { batch in batch.forEach(emit) }
    }

    func beginBatch(inputFormat: AVAudioFormat, continuingStream: Bool = false,
                    emit: @escaping @Sendable ([IPadMicrophonePCMFrame]) -> Void) -> UUID? {
        guard inputFormat.sampleRate.isFinite, (Double(IPadMicrophonePCM.minimumInputRate)...Double(IPadMicrophonePCM.maximumInputRate)).contains(inputFormat.sampleRate),
              (1...8).contains(inputFormat.channelCount),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(IPadMicrophonePCM.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        let captureID = UUID()
        queue.sync {
            self.converter = converter
            outputFormat = output
            if continuingStream { packetizer.discardPending() } else { packetizer.reset() }
            emitBatch = emit
            activeCaptureID = captureID
        }
        return captureID
    }

    func enqueue(_ input: AVAudioPCMBuffer, captureID: UUID) {
        guard input.frameLength > 0, input.frameLength <= AVAudioFrameCount(IPadMicrophonePCM.maxInputFrames) else { return }
        let accepted = pending.withLock { count -> Bool in
            guard count < 2 else { return false }
            count += 1
            return true
        }
        guard accepted else { return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format,
                                          frameCapacity: input.frameLength) else {
            pending.withLock { $0 -= 1 }
            return
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else {
            pending.withLock { $0 -= 1 }
            return
        }
        for index in source.indices {
            guard let from = source[index].mData, let to = target[index].mData,
                  target[index].mDataByteSize >= source[index].mDataByteSize else {
                pending.withLock { $0 -= 1 }
                return
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        queue.async { [self] in
            defer { pending.withLock { $0 -= 1 } }
            guard activeCaptureID == captureID else { return }
            convert(copy)
        }
    }

    func end() {
        queue.sync {
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
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(expanded)) else { return }
        var cursor: AVAudioFrameCount = 0
        var slices: [AVAudioPCMBuffer] = []
        var inputFailed = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { requested, status in
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
        guard !inputFailed, error == nil, result != .error,
              let channel = output.floatChannelData?.pointee else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        var batch: [IPadMicrophonePCMFrame] = []
        packetizer.append(samples) { batch.append($0) }
        if !batch.isEmpty { emitBatch(batch) }
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
