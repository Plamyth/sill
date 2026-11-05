import AVFAudio
import AudioToolbox
import Darwin
import Foundation

/// Serial, synchronous conversion only. Scope values come from the existing owner/media binding.
final class NativeRealtimePCM<Scope: Equatable> {
    enum Failure: Error, Equatable {
        case invalidCapacity, unavailable, busy, inactiveScope, staleSequence
        case invalidFormat, invalidFrames, invalidBytes, inputNotConsumed
        case conversionFailed, invalidOutput, consumerRejected
    }

    struct Receipt: Equatable {
        let sequence: UInt64
        let inputFrames: Int
        let outputFrames: Int
    }

    struct Operations {
        let convert: (AVAudioPCMBuffer, @escaping AVAudioConverterInputBlock) -> (AVAudioConverterOutputStatus, NSError?)
        let reset: () -> Void

        static func native(_ converter: AVAudioConverter) -> Self {
            Self(convert: { output, input in
                var error: NSError?
                let status = converter.convert(to: output, error: &error, withInputFrom: input)
                return (status, error)
            }, reset: { converter.reset() })
        }
    }

    static var maximumInputFrames: Int { 480_000 }
    let maxInputFrames: Int
    let ownedPCMByteCapacity: Int
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let operations: Operations
    private let lock = NSLock()
    private var scope: Scope?
    private var lastSequence: UInt64?

    init(maxInputFrames: Int = 960,
         operations makeOperations: ((AVAudioConverter) -> Operations)? = nil) throws {
        guard (1...Self.maximumInputFrames).contains(maxInputFrames) else { throw Failure.invalidCapacity }
        let outputCapacity = (maxInputFrames + 1) / 2 + 256
        guard let from = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                      channels: 1, interleaved: true),
              let to = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                    channels: 1, interleaved: true),
              from.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              to.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              let converter = AVAudioConverter(from: from, to: to),
              let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(maxInputFrames)),
              let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(outputCapacity))
        else { throw Failure.unavailable }
        converter.primeMethod = .none
        converter.dither = false
        self.maxInputFrames = maxInputFrames
        ownedPCMByteCapacity = (maxInputFrames + outputCapacity) * 2
        self.input = input
        self.output = output
        operations = makeOperations?(converter) ?? .native(converter)
        wipe()
    }

    deinit {
        wipe()
        operations.reset()
    }

    func reset(scope: Scope?) throws {
        guard lock.try() else { throw Failure.busy }
        defer { lock.unlock() }
        wipe()
        operations.reset()
        self.scope = scope
        lastSequence = nil
    }

    /// consume borrows the buffer only until it returns; escaping consumers must make a bounded copy.
    /// No queue or Task is created. A throwing consumer invalidates the current conversion scope.
    func convert(_ pcm: UnsafeRawBufferPointer, sampleRate: Double, channels: Int,
                 frameCount: Int, sequence: UInt64, scope requestedScope: Scope,
                 consume: (UnsafeRawBufferPointer, Receipt) throws -> Void) throws -> Receipt {
        guard lock.try() else { throw Failure.busy }
        defer { wipe(); lock.unlock() }
        guard let scope, scope == requestedScope else { throw Failure.inactiveScope }
        guard sequence > 0, lastSequence.map({ sequence > $0 }) ?? true else { throw Failure.staleSequence }
        guard sampleRate == 48_000, channels == 1 else { throw Failure.invalidFormat }
        guard frameCount > 0, frameCount <= maxInputFrames else { throw Failure.invalidFrames }
        let (byteCount, overflow) = frameCount.multipliedReportingOverflow(by: 2)
        guard !overflow, pcm.count == byteCount, pcm.count % 2 == 0, let source = pcm.baseAddress else {
            throw Failure.invalidBytes
        }
        var offset = 0
        var invalidRequest = false
        do {
            let (status, error) = operations.convert(output) { [input] requested, status in
                guard requested > 0 else {
                    invalidRequest = true
                    status.pointee = .noDataNow
                    return nil
                }
                guard offset < frameCount else {
                    status.pointee = .noDataNow
                    return nil
                }
                let count = min(Int(requested), frameCount - offset)
                guard let destination = input.int16ChannelData?[0] else {
                    invalidRequest = true
                    status.pointee = .noDataNow
                    return nil
                }
                memcpy(destination, source.advanced(by: offset * 2), count * 2)
                input.frameLength = AVAudioFrameCount(count)
                offset += count
                status.pointee = .haveData
                return input
            }
            guard error == nil, !invalidRequest else { throw Failure.conversionFailed }
            switch status {
            case .haveData, .inputRanDry: break
            default: throw Failure.conversionFailed
            }
            guard offset == frameCount else { throw Failure.inputNotConsumed }
            let count = Int(output.frameLength)
            guard count <= Int(output.frameCapacity), count <= (frameCount + 1) / 2 + 256,
                  let samples = output.int16ChannelData?[0] else { throw Failure.invalidOutput }
            let receipt = Receipt(sequence: sequence, inputFrames: frameCount, outputFrames: count)
            if count > 0 {
                do {
                    try consume(UnsafeRawBufferPointer(start: samples, count: count * 2), receipt)
                } catch { throw Failure.consumerRejected }
            }
            lastSequence = sequence
            return receipt
        } catch {
            operations.reset()
            self.scope = nil
            lastSequence = nil
            throw error
        }
    }

    private func wipe() {
        for buffer in [input, output] {
            if let samples = buffer.int16ChannelData?[0] {
                let count = Int(buffer.frameCapacity) * 2
                _ = memset_s(samples, count, 0, count)
            }
            buffer.frameLength = 0
        }
    }
}
