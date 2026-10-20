import AVFoundation
import Darwin
import Foundation
import os
import StreamProtocol

enum VisionAudioPlaybackEvent: Equatable, Sendable {
    case rendering
    case waiting
    case failed(String)
}

private enum VisionAudioProcess {
    static let log = Logger(subsystem: "sill.vision", category: "audio-playback")
}

final class VisionAudioPlayer: @unchecked Sendable {
    private struct State {
        var playback = VisionAudioPlaybackState()
        var callback: ((UUID, VisionAudioPlaybackEvent) -> Void)?
        var notified: VisionAudioPlaybackEvent?
        var controlScheduled = false
        var cleanupChanged: ((String?) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let decodeQueue: DispatchQueue
    private let output: VisionAudioOutput
    private var decoder: VisionAACDecoder?
    private var decoderTicket: VisionAudioTicket?
    private var decoderGap: UInt64 = 0

    init(hardware: VisionAudioHardware = VisionAudioSharedHardware.shared, ownerID: UUID = UUID(),
         decodeQueue: DispatchQueue = DispatchQueue(label: "sill.vision-audio.decode", qos: .userInitiated)) {
        self.decodeQueue = decodeQueue
        output = VisionAudioOutput(hardware: hardware, owner: ownerID)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.output.observe { [weak self] problem in
                guard let self else { return }
                let notification = self.state.withLock { value in (value.cleanupChanged, value.playback.ticket) }
                notification.0?(problem)
                if let problem, let ticket = notification.1 { self.fail(ticket, problem) }
            }
        }
    }

    var cleanupProblem: String? { output.hardware.cleanupProblem }
    var onCleanupChange: ((String?) -> Void)? {
        get { state.withLock { $0.cleanupChanged } }
        set { state.withLock { $0.cleanupChanged = newValue } }
    }

    func retryCleanup() {
        dispatchPrecondition(condition: .onQueue(.main))
        output.hardware.retryCleanup()
    }

    deinit {
        stop()
        let output = output
        DispatchQueue.main.async { output.removeObserver() }
    }

    func begin(grant: UUID, onEvent: @escaping (UUID, VisionAudioPlaybackEvent) -> Void) {
        let ticket = VisionAudioTicket(grant: grant, epoch: UUID())
        let accepted = state.withLock { value -> Bool in
            guard output.reserve(ticket) else { return false }
            value.playback.begin(ticket)
            value.callback = onEvent
            value.notified = nil
            value.controlScheduled = false
            return true
        }
        guard accepted else {
            DispatchQueue.main.async { onEvent(grant, .failed("Another audio player owns the playback lease.")) }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state.withLock({ $0.playback.admits(ticket) }) else { return }
            self.output.arm(ticket) { [weak self] in self?.deliver(ticket) }
            self.deliver(ticket)
        }
    }

    func receive(_ packet: Data, grant: UUID) {
        let schedule = state.withLock { value -> Bool in
            guard let ticket = value.playback.ticket, ticket.grant == grant,
                  value.playback.admits(ticket) else { return false }
            return value.playback.mailbox.offer(packet, ticket: ticket, now: Self.now)
        }
        if schedule { decodeQueue.async { [self] in drain() } }
    }

    func stop() {
        let ticket = state.withLock { value -> VisionAudioTicket? in
            value.callback = nil
            value.notified = nil
            value.controlScheduled = false
            return value.playback.revoke()
        }
        guard let ticket else { return }
        let output = output
        output.revoke(ticket)
        let close = {
            #if os(visionOS)
            defer { DispatchQueue.main.async { VisionRemoteAudioStore.shared.refresh() } }
            #endif
            if let error = output.close(ticket) {
                VisionAudioProcess.log.error("Playback cleanup failed: \(error, privacy: .public)")
            }
        }
        if Thread.isMainThread { close() }
        else { DispatchQueue.main.async(execute: close) }
    }

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private static var now: TimeInterval { Double(mach_absolute_time()) * secondsPerTick }

    private func drain() {
        while let work = state.withLock({ $0.playback.mailbox.next(now: Self.now) }) {
            decode(work)
            state.withLock { $0.playback.mailbox.finish() }
        }
        if state.withLock({ $0.playback.ticket != decoderTicket || $0.playback.failure != nil }) {
            decoder = nil
            decoderTicket = nil
        }
    }

    private func decode(_ work: VisionAudioMailbox.Work) {
        guard state.withLock({ $0.playback.admits(work.ticket) && $0.playback.mailbox.isFresh(work, now: Self.now) }) else {
            decoder = nil
            return
        }
        if decoderTicket != work.ticket || decoderGap != work.gap {
            decoder = nil
            decoderTicket = work.ticket
            decoderGap = work.gap
        }
        let format: VisionAudioFormat
        let samples: [Float]
        if let encoded = AudioPacket.unpackEncoded(work.data) {
            guard let valid = VisionAudioFormat(rate: encoded.sampleRate, channels: encoded.channels),
                  !encoded.packet.isEmpty, encoded.packet.count <= VisionAudioMailbox.packetByteLimit,
                  encoded.cookie.count <= 255 else {
                fail(work.ticket, "Unsupported AAC format. Expected mono or stereo at 8 to 96 kHz.")
                return
            }
            format = valid
            if decoder?.matches(rate: valid.rate, channels: valid.channels, cookie: encoded.cookie) != true {
                decoder = VisionAACDecoder(rate: valid.rate, channels: valid.channels, cookie: encoded.cookie)
            }
            guard let decoded = decoder?.decode(encoded.packet), !decoded.isEmpty else {
                fail(work.ticket, "AAC decoder could not produce valid PCM.")
                return
            }
            samples = decoded
        } else if let plain = AudioPacket.unpack(work.data) {
            guard let valid = VisionAudioFormat(rate: plain.sampleRate, channels: plain.channels),
                  !plain.samples.isEmpty, plain.samples.count <= 16_384,
                  plain.samples.count % plain.channels == 0 else {
                fail(work.ticket, "Unsupported PCM format. Expected mono or stereo at 8 to 96 kHz.")
                return
            }
            decoder = nil
            format = valid
            samples = plain.samples.map { Float($0) / 32768 }
        } else {
            fail(work.ticket, "Invalid audio packet.")
            return
        }
        guard samples.count <= 32_768, samples.count % format.channels == 0,
              samples.allSatisfy({ $0.isFinite }) else {
            fail(work.ticket, "Decoded audio contains invalid samples.")
            return
        }
        let schedule = state.withLock { value -> Bool in
            guard value.playback.admits(work.ticket) else { return false }
            guard value.playback.mailbox.isFresh(work, now: Self.now) else {
                value.playback.mailbox.invalidateDecode()
                return false
            }
            guard value.playback.append(samples, format: format, work: work, now: Self.now),
                  !value.controlScheduled else { return false }
            value.controlScheduled = true
            return true
        }
        if schedule {
            let ticket = work.ticket
            DispatchQueue.main.async { [weak self] in self?.reconcile(ticket) }
        }
    }

    private func reconcile(_ ticket: VisionAudioTicket) {
        let configuration = state.withLock { value -> (VisionAudioFormat, UInt64)? in
            guard value.playback.admits(ticket) else { return nil }
            value.controlScheduled = false
            guard let format = value.playback.ring.format,
                  value.playback.hasFreshPCM(now: Self.now) else { return nil }
            return (format, value.playback.version)
        }
        guard let (format, version) = configuration,
              !output.matches(ticket, version: version) else { return }
        let renderState = state
        let authorization = {
            renderState.withLock { value -> VisionAudioPlaybackAuthorization in
                guard value.playback.admits(ticket) else { return .revoked }
                return value.playback.version == version ? .current : .superseded
            }
        }
        do {
            try output.start(ticket, format: format, version: version, authorization: authorization) { [gain = VisionAudioGain.shared] _, _, frames, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                for buffer in buffers {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                guard buffers.count >= format.channels else { return noErr }
                for channel in 0..<format.channels {
                    guard buffers[channel].mData != nil,
                          Int(buffers[channel].mDataByteSize) >= Int(frames) * MemoryLayout<Float>.size else { return noErr }
                }
                _ = renderState.withLockIfAvailable { value in
                    let renderGain = gain.renderGain
                    value.playback.render(ticket: ticket, version: version, frames: Int(frames), now: Self.now) { frame, channel, sample in
                        buffers[channel].mData!.assumingMemoryBound(to: Float.self)[frame] = renderGain == 0 ? 0 : sample * renderGain
                    }
                }
                return noErr
            }
        } catch {
            enum Recovery { case revoked, replacedFormat, failed }
            let message = "Audio playback could not start: \(error.localizedDescription)"
            let recovery = state.withLock { value -> Recovery in
                guard value.playback.admits(ticket) else { return .revoked }
                guard value.playback.version == version else { return .replacedFormat }
                value.playback.fail(ticket, message: message)
                return .failed
            }
            switch recovery {
            case .failed: finishFailure(ticket, message: message)
            case .revoked: _ = output.close(ticket)
            case .replacedFormat: break
            }
        }
    }

    private func fail(_ ticket: VisionAudioTicket, _ message: String) {
        let changed = state.withLock { value -> Bool in
            guard value.playback.admits(ticket) else { return false }
            value.playback.fail(ticket, message: message)
            value.controlScheduled = false
            return true
        }
        if changed {
            DispatchQueue.main.async { [weak self] in self?.finishFailure(ticket, message: message) }
        }
    }

    private func finishFailure(_ ticket: VisionAudioTicket, message: String) {
        let cleanup = output.close(ticket)
        if let cleanup {
            state.withLock { value in
                if value.playback.ticket == ticket {
                    value.playback.replaceFailure(message + " Cleanup failed: " + cleanup)
                }
            }
        }
        deliver(ticket)
    }

    private func deliver(_ ticket: VisionAudioTicket) {
        let delivery = state.withLock { value -> (((UUID, VisionAudioPlaybackEvent) -> Void), VisionAudioPlaybackEvent)? in
            guard value.playback.ticket == ticket, let callback = value.callback else { return nil }
            let event: VisionAudioPlaybackEvent
            if let error = value.playback.failure { event = .failed(error) }
            else { event = value.playback.rendered == .rendering ? .rendering : .waiting }
            guard value.notified != event else { return nil }
            value.notified = event
            return (callback, event)
        }
        guard let (callback, event) = delivery,
              state.withLock({ $0.playback.ticket == ticket }) else { return }
        callback(ticket.grant, event)
    }
}

private final class VisionAudioOutput: @unchecked Sendable {
    let hardware: VisionAudioHardware
    private let owner: UUID
    private var ticket: VisionAudioTicket?
    private var timer: DispatchSourceTimer?
    private var poll: (() -> Void)?

    init(hardware: VisionAudioHardware, owner: UUID) { self.hardware = hardware; self.owner = owner }

    private func claim(_ ticket: VisionAudioTicket) -> VisionAudioClaim {
        VisionAudioClaim(owner: owner, role: .playback, epoch: ticket.epoch)
    }

    func reserve(_ ticket: VisionAudioTicket) -> Bool {
        hardware.reserve(owner: owner, role: .playback, epoch: ticket.epoch) != nil
    }

    func revoke(_ ticket: VisionAudioTicket) { hardware.revoke(claim(ticket)) }

    func observe(_ handler: @escaping (String?) -> Void) { hardware.observeProblems(owner: owner, handler: handler) }
    func removeObserver() { hardware.removeObserver(owner: owner) }

    func arm(_ ticket: VisionAudioTicket, poll: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.ticket = ticket
        self.poll = poll
    }

    func matches(_ ticket: VisionAudioTicket, version: UInt64) -> Bool {
        self.ticket == ticket && hardware.matches(claim(ticket), version: version)
    }

    func start(_ ticket: VisionAudioTicket, format: VisionAudioFormat, version: UInt64,
               authorization: @escaping () -> VisionAudioPlaybackAuthorization, render: @escaping AVAudioSourceNodeRenderBlock) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.ticket == ticket, authorization() == .current else { throw CancellationError() }
        try hardware.startPlayback(claim(ticket), format: format, version: version, authorization: authorization, render: render)
        if timer == nil, let poll {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
            timer.setEventHandler(handler: poll)
            self.timer = timer
            timer.resume()
        }
    }

    func close(_ ticket: VisionAudioTicket) -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.ticket == nil || self.ticket == ticket else { return nil }
        hardware.revoke(claim(ticket))
        timer?.cancel()
        timer = nil
        poll = nil
        let error = hardware.close(claim(ticket))
        self.ticket = nil
        return error
    }
}

private final class VisionAACDecoder {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let rate: Double
    private let channels: Int
    private let cookie: Data

    init?(rate: Double, channels: Int, cookie: Data) {
        guard VisionAudioFormat(rate: rate, channels: channels) != nil, cookie.count <= 255 else { return nil }
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
        guard !packet.isEmpty, packet.count <= VisionAudioMailbox.packetByteLimit else { return nil }
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1,
                                                  maximumPacketSize: packet.count)
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
        guard status != .error, error == nil, pcm.frameLength > 0, pcm.frameLength <= 1024,
              let data = pcm.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength) * channels))
    }
}
