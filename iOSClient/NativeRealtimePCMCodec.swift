import AVFoundation
import Foundation

enum NativeRealtimePCMError: Error {
    case invalidAudio, invalidInput, unavailable, conversionFailed, staleGeneration, streamFinished
}

/// app-server 0.164.0 audio DTO only. No CCR Host envelope or session identity is implied.
struct NativeRealtimeAudio: Codable, Equatable {
    enum Direction {
        case input, output
        var maximumBytes: Int { self == .input ? 48_000 : 480_000 }
    }

    let data: String
    let sampleRate: Int
    let numChannels: Int
    let samplesPerChannel: Int?
    let itemId: String?

    init(data: String, sampleRate: Int, numChannels: Int, samplesPerChannel: Int?, itemId: String?) {
        self.data = data
        self.sampleRate = sampleRate
        self.numChannels = numChannels
        self.samplesPerChannel = samplesPerChannel
        self.itemId = itemId
    }

    init(pcm: Data, direction: Direction, itemId: String? = nil) throws {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= direction.maximumBytes else {
            throw NativeRealtimePCMError.invalidAudio
        }
        self.init(data: pcm.base64EncodedString(), sampleRate: 24_000, numChannels: 1,
                  samplesPerChannel: pcm.count / 2, itemId: itemId)
        _ = try validatedPCM(direction: direction)
    }

    func validatedPCM(direction: Direction) throws -> Data {
        let validID = itemId.map { value in
            (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) ||
                [45, 46, 58, 95].contains($0)
            }
        } ?? true
        guard sampleRate == 24_000, numChannels == 1, validID,
              !data.isEmpty, data.utf8.count <= ((direction.maximumBytes + 2) / 3) * 4,
              let pcm = Data(base64Encoded: data), !pcm.isEmpty,
              pcm.count % 2 == 0, pcm.count <= direction.maximumBytes,
              pcm.base64EncodedString() == data,
              samplesPerChannel == nil || samplesPerChannel == pcm.count / 2 else {
            throw NativeRealtimePCMError.invalidAudio
        }
        return pcm
    }

    private enum Keys: String, CodingKey, CaseIterable {
        case data, sampleRate, numChannels, samplesPerChannel, itemId
    }
    private struct Field: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(Keys.allCases.map(\.rawValue)) else {
            throw NativeRealtimePCMError.invalidAudio
        }
        let values = try decoder.container(keyedBy: Keys.self)
        self.init(data: try values.decode(String.self, forKey: .data),
                  sampleRate: try values.decode(Int.self, forKey: .sampleRate),
                  numChannels: try values.decode(Int.self, forKey: .numChannels),
                  samplesPerChannel: try values.decodeIfPresent(Int.self, forKey: .samplesPerChannel),
                  itemId: try values.decodeIfPresent(String.self, forKey: .itemId))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(data, forKey: .data)
        try values.encode(sampleRate, forKey: .sampleRate)
        try values.encode(numChannels, forKey: .numChannels)
        try values.encode(samplesPerChannel, forKey: .samplesPerChannel)
        try values.encode(itemId, forKey: .itemId)
    }
}

/// One serial owner calls this off the capture callback. Retains converter state, no PCM queue.
/// Generation is a local reset fence, never a provider, connection, or voice-session identity.
final class NativeRealtimePCMCodec {
    private enum Phase { case active, finished, failed }
    private let converter: AVAudioConverter
    private var phase = Phase.active
    private(set) var generation = UUID()

    init() throws {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                        channels: 1, interleaved: true),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw NativeRealtimePCMError.unavailable
        }
        converter.primeMethod = .normal
        self.converter = converter
    }

    @discardableResult
    func reset() -> UUID {
        converter.reset()
        generation = UUID()
        phase = .active
        return generation
    }

    func append(_ pcm: Data, frameCount: Int, generation: UUID) throws -> [NativeRealtimeAudio] {
        try check(generation)
        guard (1...48_000).contains(frameCount), pcm.count == frameCount * 2,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(frameCount)),
              let samples = input.int16ChannelData?.pointee else {
            throw NativeRealtimePCMError.invalidInput
        }
        input.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { bytes in
            let source = bytes.bindMemory(to: UInt8.self)
            for index in 0..<frameCount {
                samples[index] = Int16(bitPattern: UInt16(source[index * 2]) | UInt16(source[index * 2 + 1]) << 8)
            }
        }
        return try convert(input)
    }

    func flush(generation: UUID) throws -> [NativeRealtimeAudio] {
        guard generation == self.generation else { throw NativeRealtimePCMError.staleGeneration }
        if phase == .finished { return [] }
        try check(generation)
        let result = try convert(nil)
        phase = .finished
        converter.reset()
        return result
    }

    private func check(_ generation: UUID) throws {
        guard generation == self.generation else { throw NativeRealtimePCMError.staleGeneration }
        guard phase == .active else { throw NativeRealtimePCMError.streamFinished }
    }

    private func convert(_ input: AVAudioPCMBuffer?) throws -> [NativeRealtimeAudio] {
        var cursor: AVAudioFrameCount = 0
        var result: [NativeRealtimeAudio] = []
        // At most one second of input plus the converter tail, split at the Core input limit.
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 24_000) else {
                break
            }
            var slices: [AVAudioPCMBuffer] = []
            var failed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, status in
                guard let input else { status.pointee = .endOfStream; return nil }
                guard cursor < input.frameLength else { status.pointee = .noDataNow; return nil }
                let count = min(requested, input.frameLength - cursor)
                guard count > 0,
                      let slice = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count),
                      let source = input.int16ChannelData?.pointee,
                      let target = slice.int16ChannelData?.pointee else {
                    failed = true
                    status.pointee = .noDataNow
                    return nil
                }
                slice.frameLength = count
                target.update(from: source.advanced(by: Int(cursor)), count: Int(count))
                cursor += count
                slices.append(slice)
                status.pointee = .haveData
                return slice
            }
            withExtendedLifetime(slices) {}
            guard !failed, error == nil, status != .error,
                  let samples = output.int16ChannelData?.pointee else { break }
            if output.frameLength > 0 {
                var pcm = Data(capacity: Int(output.frameLength) * 2)
                for index in 0..<Int(output.frameLength) {
                    let bits = UInt16(bitPattern: samples[index])
                    pcm.append(UInt8(truncatingIfNeeded: bits))
                    pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
                }
                result.append(try NativeRealtimeAudio(pcm: pcm, direction: .input))
            }
            if status == .endOfStream {
                guard input == nil else { break }
                return result
            }
            if let input, status == .inputRanDry, cursor == input.frameLength { return result }
            guard output.frameLength > 0 else { break }
        }
        phase = .failed
        converter.reset()
        throw NativeRealtimePCMError.conversionFailed
    }
}
