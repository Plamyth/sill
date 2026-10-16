import AVFoundation
import os
import StreamProtocol

/// Pull-based playback for short kind-33 packets. Network decoding never runs on the UI or
/// render threads. A new stream format or a disconnect invalidates the old render callback.
final class RemoteAudioPlayer: @unchecked Sendable {
    private let decodeQueue = DispatchQueue(label: "sill.remote-audio.decode", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock()
    private let epochLock = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var decoder: RemoteAACDecoder?
    private var samples: [Float] = []
    private var readIndex = 0
    private var playing = false
    private var formatVersion: UInt64 = 0
    private var rate: Double = 0
    private var channels = 0
    private var engine: AVAudioEngine?
    private var ownsPlaybackLease = false
    private let audioLeaseId = UUID()

    func receive(_ packet: Data) {
        let epoch = epochLock.withLock { $0 }
        decodeQueue.async { [self] in
            guard epochLock.withLock({ $0 == epoch }) else { return }
            if let encoded = AudioPacket.unpackEncoded(packet) {
                if decoder?.matches(rate: encoded.sampleRate, channels: encoded.channels,
                                    cookie: encoded.cookie) != true {
                    decoder = RemoteAACDecoder(rate: encoded.sampleRate, channels: encoded.channels,
                                               cookie: encoded.cookie)
                }
                guard let decoded = decoder?.decode(encoded.packet) else { return }
                append(decoded, rate: encoded.sampleRate, channels: encoded.channels, epoch: epoch)
            } else if let plain = AudioPacket.unpack(packet) {
                let decoded = plain.samples.map { Float($0) / 32768 }
                append(decoded, rate: plain.sampleRate, channels: plain.channels, epoch: epoch)
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        epochLock.withLock { value in
            value &+= 1
            lock.withLock {
                formatVersion &+= 1
                samples.removeAll(keepingCapacity: false)
                readIndex = 0
                playing = false
            }
        }
        engine?.stop()
        engine = nil
        if ownsPlaybackLease {
            do {
                try IPadAudioSession.shared.release(leaseId:audioLeaseId)
                ownsPlaybackLease = false
            } catch {
                Logger(subsystem: "me.saffer.sill", category: "AudioSession")
                    .error("Playback lease cleanup failed: \(String(describing: error), privacy: .public)")
            }
        }
        decodeQueue.async { [self] in
            decoder = nil
            rate = 0
            channels = 0
        }
    }

    private func append(_ incoming: [Float], rate newRate: Double, channels newChannels: Int, epoch: UInt64) {
        // Hold the epoch through append so a decode cannot refill the buffer after OFF cleared it.
        epochLock.withLock { current in
            guard current == epoch else { return }
            if rate != newRate || channels != newChannels {
                rate = newRate
                channels = newChannels
                let version = lock.withLock { () -> UInt64 in
                    formatVersion &+= 1
                    samples.removeAll(keepingCapacity: true)
                    readIndex = 0
                    playing = false
                    return formatVersion
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.epochLock.withLock({ $0 == epoch }),
                          self.lock.withLock({ self.formatVersion == version }) else { return }
                    self.restart(rate: newRate, channels: newChannels, version: version)
                }
            }
            let perMs = Int(newRate / 1000) * newChannels
            lock.withLock {
                if readIndex > 48_000 * 8 { samples.removeFirst(readIndex); readIndex = 0 }
                samples.append(contentsOf: incoming)
                let buffered = samples.count - readIndex
                if !playing && buffered >= 40 * perMs { playing = true }
                if buffered > 150 * perMs { readIndex = samples.count - 60 * perMs }
            }
        }
    }

    private func restart(rate: Double, channels: Int, version: UInt64) {
        engine?.stop()
        engine = nil
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: AVAudioChannelCount(channels), interleaved: false)
        else { return }
        do {
            try IPadAudioSession.shared.acquire(.remotePlayback,leaseId:audioLeaseId)
            ownsPlaybackLease = true
            let engine = AVAudioEngine()
            let source = AVAudioSourceNode(format: format) { [weak self] _, _, frames, list -> OSStatus in
                let output = UnsafeMutableAudioBufferListPointer(list)
                guard let self else {
                    for channel in output { if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) } }
                    return noErr
                }
                self.lock.withLock {
                    for frame in 0..<Int(frames) {
                        let ready = self.formatVersion == version && self.playing &&
                                    self.samples.count - self.readIndex >= channels
                        for channel in 0..<output.count {
                            let destination = output[channel].mData!.assumingMemoryBound(to: Float.self)
                            destination[frame] = ready && channel < channels ?
                                self.samples[self.readIndex + channel] : 0
                        }
                        if ready { self.readIndex += channels }
                        else if self.playing && self.formatVersion == version { self.playing = false }
                    }
                }
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            try engine.start()
            self.engine = engine
        } catch {
            engine = nil
            ownsPlaybackLease = ownsPlaybackLease || IPadAudioSession.shared.holds(leaseId:audioLeaseId)
            if ownsPlaybackLease {
                do {
                    try IPadAudioSession.shared.release(leaseId:audioLeaseId)
                    ownsPlaybackLease = false
                } catch {
                    Logger(subsystem: "me.saffer.sill", category: "AudioSession")
                        .error("Playback lease cleanup failed: \(String(describing: error), privacy: .public)")
                }
            }
            decodeQueue.async { [self] in
                self.rate = 0
                self.channels = 0
            }
        }
    }
}

private final class RemoteAACDecoder {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let rate: Double
    private let channels: Int
    private let cookie: Data

    init?(rate: Double, channels: Int, cookie: Data) {
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC_ELD,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: AVAudioChannelCount(channels), interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.magicCookie = cookie
        self.input = input
        self.output = output
        self.converter = converter
        self.rate = rate
        self.channels = channels
        self.cookie = cookie
    }

    func matches(rate: Double, channels: Int, cookie: Data) -> Bool {
        self.rate == rate && self.channels == channels && self.cookie == cookie
    }

    func decode(_ packet: Data) -> [Float]? {
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1,
                                                  maximumPacketSize: max(packet.count, 1))
        packet.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { compressed.data.copyMemory(from: source, byteCount: packet.count) }
        }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0,
            mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1024) else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, let data = pcm.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength) * channels))
    }
}
