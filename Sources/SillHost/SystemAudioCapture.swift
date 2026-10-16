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
    private var packer: RemoteAudioPCM?
    var onPacket: ((Data) -> Void)?
    var onStopped: ((Error) -> Void)?

    func start(display: SCDisplay) async throws {
        guard streamLock.withLock({ stream == nil }) else { return }
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
        streamLock.withLock { self.stream = stream }
        do {
            try await stream.startCapture()
        } catch {
            streamLock.withLock { if self.stream === stream { self.stream = nil } }
            throw error
        }
    }

    func stop() async {
        guard let stream = streamLock.withLock({ () -> SCStream? in
            let old = self.stream
            self.stream = nil
            return old
        }) else { return }
        try? await stream.stopCapture()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in packer = nil; continuation.resume() }
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
            packer?.add(UnsafeMutableAudioBufferListPointer(list), send: onPacket)
            _ = block
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard streamLock.withLock({ () -> Bool in
            guard stream === self.stream else { return false }
            self.stream = nil
            return true
        }) else { return }
        onStopped?(error)
    }
}

private final class RemoteAudioPCM {
    private let rate: Double
    private let channels: Int
    private let framesPerPacket: Int
    private var pending: [Int16] = []

    init(rate: Double, channels: Int) {
        self.rate = rate
        self.channels = channels
        framesPerPacket = max(1, Int(rate / 100))
    }

    func matches(rate: Double, channels: Int) -> Bool { self.rate == rate && self.channels == channels }

    func add(_ buffers: UnsafeMutableAudioBufferListPointer, send: ((Data) -> Void)?) {
        guard let send, let first = buffers.first, let firstData = first.mData else { return }
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
            pending.removeFirst(count)
            send(packet)
        }
    }

    private static func int16(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(max(-1, min(1, value)) * 32767)
    }
}
