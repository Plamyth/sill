import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit
import StreamProtocol

/// Captures the Mac's sound without changing its output device, volume, or mute state.
/// This stream is separate from video, so selecting another window does not interrupt sound.
// The stream identity is locked; PCM packing stays on `queue`. Callbacks are installed
// before start and replaced only after stop has drained that queue.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "sill.remote-audio.capture", qos: .userInitiated)
    private let streamLock = NSLock()
    private var stream: SCStream?
    private var unretiredGenerations: Set<UUID> = []
    private var startingGenerations: Set<UUID> = []
    private var captureGeneration = UUID()
    private var packer: RemoteAudioPCM?
    private var sampleSequence: UInt64 = 0
    var onPacket: ((Data, UInt64) -> Void)?
    var onStopped: ((UUID, Error) -> Void)?

    var hasStream: Bool { streamLock.withLock { stream != nil } }
    var retirementConfirmed: Bool { streamLock.withLock { stream == nil && unretiredGenerations.isEmpty } }
    func isStoppedGeneration(_ generation: UUID) -> Bool {
        streamLock.withLock { captureGeneration == generation && stream == nil }
    }

    /// A capture-queue barrier for a new subscriber. Everything captured before this
    /// point has a sequence no greater than the returned value. Discard the partial
    /// PCM packet so a later sample cannot finish it under a new subscription.
    func subscriptionBoundary() async -> UInt64 {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                packer?.discardPending()
                continuation.resume(returning: sampleSequence)
            }
        }
    }

    func start(display: SCDisplay) async throws {
        guard streamLock.withLock({ self.stream == nil }) else { return }
        let configuration = SCStreamConfiguration()
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        let generation = UUID()
        streamLock.withLock {
            self.stream = stream
            captureGeneration = generation
            unretiredGenerations.insert(generation)
            startingGenerations.insert(generation)
        }
        do {
            try await stream.startCapture()
            streamLock.withLock { _ = startingGenerations.remove(generation) }
        } catch {
            streamLock.withLock {
                startingGenerations.remove(generation)
                if self.stream === stream { self.stream = nil }
            }
            throw error
        }
    }

    func stop() async {
        let (stream, generation, startSettled) = streamLock.withLock({ () -> (SCStream?, UUID, Bool) in
            let old = self.stream
            self.stream = nil
            return (old, captureGeneration, !startingGenerations.contains(captureGeneration))
        })
        let stopped: Bool
        if let stream {
            do { try await stream.stopCapture(); stopped = true }
            catch { stopped = false }
        } else { stopped = false }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                packer = nil
                streamLock.withLock {
                    if stopped && startSettled { unretiredGenerations.remove(generation) }
                }
                continuation.resume()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard streamLock.withLock({ stream === self.stream }), type == .audio,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        let value = format.pointee
        guard value.mFormatID == kAudioFormatLinearPCM,
              value.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              value.mBitsPerChannel == 32,
              (8_000...192_000).contains(value.mSampleRate),
              (1...8).contains(Int(value.mChannelsPerFrame)) else { return }
        let channels = Int(value.mChannelsPerFrame)
        sampleSequence &+= 1
        let sequence = sampleSequence
        if packer?.matches(rate: value.mSampleRate, channels: channels) != true {
            packer = RemoteAudioPCM(rate: value.mSampleRate, channels: channels)
        }
        var needed = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            blockBufferOut: nil) == noErr,
            needed >= MemoryLayout<AudioBufferList>.size, needed < 4096 else { return }
        var storage = [UInt8](repeating: 0, count: needed)
        storage.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            let list = base.assumingMemoryBound(to: AudioBufferList.self)
            var block: CMBlockBuffer?
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
                bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &block) == noErr
            else { return }
            packer?.add(UnsafeMutableAudioBufferListPointer(list), sequence: sequence, send: onPacket)
            _ = block
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let generation = streamLock.withLock({ () -> UUID? in
            guard stream === self.stream else { return nil }
            self.stream = nil
            return captureGeneration
        }) else { return }
        queue.async { [self] in
            guard isStoppedGeneration(generation) else { return }
            packer = nil
        }
        onStopped?(generation, error)
    }
}

private final class RemoteAudioPCM {
    private let rate: Double
    private let channels: Int
    private let framesPerPacket: Int
    private var pending: [Int16] = []
    private var pendingSequence: UInt64?

    init(rate: Double, channels: Int) {
        self.rate = rate
        self.channels = channels
        framesPerPacket = max(1, Int(rate / 100))
    }

    func matches(rate: Double, channels: Int) -> Bool { self.rate == rate && self.channels == channels }

    func discardPending() { pending.removeAll(keepingCapacity: true); pendingSequence = nil }

    func add(_ buffers: UnsafeMutableAudioBufferListPointer, sequence: UInt64,
             send: ((Data, UInt64) -> Void)?) {
        guard let send, let first = buffers.first, let firstData = first.mData else { return }
        if pendingSequence == nil { pendingSequence = sequence }
        if buffers.count == 1 {
            let available = Int(first.mNumberChannels)
            guard available > 0 else { return }
            let frames = Int(first.mDataByteSize) / (4 * available)
            let source = firstData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    pending.append(Self.int16(source[frame * available + min(channel, available - 1)]))
                }
            }
        } else {
            let frames = buffers.map { Int($0.mDataByteSize) / 4 }.min() ?? 0
            let sources = (0..<channels).map {
                buffers[min($0, buffers.count - 1)].mData?.assumingMemoryBound(to: Float.self)
            }
            for frame in 0..<frames {
                for channel in 0..<channels { pending.append(Self.int16(sources[channel]?[frame] ?? 0)) }
            }
        }
        let count = framesPerPacket * channels
        while pending.count >= count {
            let packet = pending.withUnsafeBufferPointer {
                AudioPacket.pack(sampleRate: UInt32(rate), channels: UInt8(channels),
                                 samples: UnsafeBufferPointer(rebasing: $0[0..<count]))
            }
            let earliest = pendingSequence ?? sequence
            pending.removeFirst(count)
            pendingSequence = pending.isEmpty ? nil : sequence
            send(packet, earliest)
        }
    }

    private static func int16(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(max(-1, min(1, value)) * 32767)
    }
}
