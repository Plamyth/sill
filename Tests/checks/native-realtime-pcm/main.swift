import AVFoundation
import Foundation

func check(_ value: Bool) { precondition(value) }

func rejects(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected boundary rejection") } catch {}
}

func bytes(_ samples: [Int16]) -> Data {
    var result = Data(capacity: samples.count * 2)
    for sample in samples {
        let bits = UInt16(bitPattern: sample)
        result.append(UInt8(truncatingIfNeeded: bits))
        result.append(UInt8(truncatingIfNeeded: bits >> 8))
    }
    return result
}

func samples(_ chunks: [NativeRealtimeAudio]) throws -> [Int16] {
    var result: [Int16] = []
    for chunk in chunks {
        let data = try chunk.validatedPCM(direction: .input)
        precondition(chunk.samplesPerChannel == data.count / 2)
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: values.count, by: 2) {
                result.append(Int16(bitPattern: UInt16(values[index]) | UInt16(values[index + 1]) << 8))
            }
        }
    }
    return result
}

func tone(_ frames: Int, frequency: Double = 1_000, offset: Int = 0) -> [Int16] {
    (0..<frames).map { Int16((sin(2 * .pi * frequency * Double($0 + offset) / 48_000) * 12_000).rounded()) }
}

func convert(_ input: [Int16], block: Int) throws -> [Int16] {
    let codec = try NativeRealtimePCMCodec()
    let generation = codec.generation
    var chunks: [NativeRealtimeAudio] = []
    for index in stride(from: 0, to: input.count, by: block) {
        let end = min(input.count, index + block)
        chunks += try codec.append(bytes(Array(input[index..<end])), frameCount: end - index, generation: generation)
    }
    chunks += try codec.flush(generation: generation)
    check(try codec.flush(generation: generation).isEmpty)
    return try samples(chunks)
}

func dtoChecks() throws {
    let sentinel = bytes([0, 32_767, -32_768, -1])
    let dto = try NativeRealtimeAudio(pcm: sentinel, direction: .input)
    check(try dto.validatedPCM(direction: .input) == sentinel)
    let json = try JSONEncoder().encode(dto)
    let fields = try JSONSerialization.jsonObject(with: json) as! [String: Any]
    precondition(fields.count == 5 && fields["itemId"] is NSNull)
    check(try JSONDecoder().decode(NativeRealtimeAudio.self, from: json) == dto)

    func changed(_ key: String, _ value: Any) throws -> NativeRealtimeAudio {
        var copy = fields
        copy[key] = value
        return try JSONDecoder().decode(NativeRealtimeAudio.self, from: JSONSerialization.data(withJSONObject: copy))
    }
    for (key, value) in [("data", "" as Any), ("data", "AQ=="), ("data", "AB=="),
                         ("data", "AAA"), ("data", "AA A="), ("data", "!!!!"),
                         ("sampleRate", 48_000), ("numChannels", 2), ("samplesPerChannel", -1),
                         ("samplesPerChannel", 5), ("itemId", "bad id"), ("itemId", ""),
                         ("itemId", String(repeating: "x", count: 129)), ("itemId", "é")] {
        rejects { _ = try changed(key, value).validatedPCM(direction: .input) }
    }
    rejects { _ = try changed("extra", true) }
    rejects { _ = try changed("encoding", "pcm_s16le") }
    for key in fields.keys {
        var copy = fields
        copy.removeValue(forKey: key)
        rejects {
            _ = try JSONDecoder().decode(NativeRealtimeAudio.self, from: JSONSerialization.data(withJSONObject: copy))
        }
    }
    check(try changed("samplesPerChannel", NSNull()).validatedPCM(direction: .output) == sentinel)
    check(try changed("itemId", "A0-._:z").validatedPCM(direction: .output) == sentinel)
    let exactInput = try NativeRealtimeAudio(pcm: Data(repeating: 0, count: 48_000), direction: .input)
    check(try exactInput.validatedPCM(direction: .input).count == 48_000)
    rejects { _ = try NativeRealtimeAudio(pcm: Data(repeating: 0, count: 48_002), direction: .input) }
    let exactOutput = try NativeRealtimeAudio(pcm: Data(repeating: 0, count: 480_000), direction: .output)
    check(try exactOutput.validatedPCM(direction: .output).count == 480_000)
    rejects { _ = try exactOutput.validatedPCM(direction: .input) }
    rejects { _ = try NativeRealtimeAudio(pcm: Data(repeating: 0, count: 480_002), direction: .output) }
    rejects { _ = try NativeRealtimeAudio(pcm: Data(), direction: .output) }
}

func signalChecks() throws {
    let input = tone(48_000)
    let whole = try convert(input, block: 48_000)
    let streaming = try convert(input, block: 960)
    precondition(whole.count == 24_000 && streaming.count == whole.count)
    precondition(zip(whole, streaming).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    let stable = Array(streaming.dropFirst(240).dropLast(240))
    let rms = sqrt(stable.reduce(0.0) { $0 + pow(Double($1), 2) } / Double(stable.count))
    precondition((8_000...9_000).contains(rms))
    let positiveCrossings = zip(stable, stable.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
    precondition((970...990).contains(positiveCrossings))
    for value: Int16 in [-32_768, -10_000, 10_000, 32_767] {
        let dc = try convert(Array(repeating: value, count: 4_800), block: 960)
        precondition(dc.count == 2_400)
        precondition(dc.dropFirst(240).dropLast(240).allSatisfy { abs(Int($0) - Int(value)) <= 2 })
    }
    let silence = try convert(Array(repeating: 0, count: 48_000), block: 960)
    precondition(silence.count == 24_000 && silence.allSatisfy { $0 == 0 })
    let high = try convert(tone(48_000, frequency: 18_000), block: 960)
    let highRMS = sqrt(high.dropFirst(240).dropLast(240).reduce(0.0) { $0 + pow(Double($1), 2) } / 23_520)
    precondition(highRMS < 500)
    let singleFrames = try convert(tone(960), block: 1)
    let onePacket = try convert(tone(960), block: 960)
    precondition(singleFrames == onePacket && singleFrames.count == 480)
    print("PASS synthetic tone, DC polarity/limits, silence, anti-aliasing, exact samples and split parity")
}

func lifecycleChecks() throws {
    let codec = try NativeRealtimePCMCodec()
    let old = codec.generation
    for (pcm, frames) in [(Data(), 0), (Data([0]), 1), (Data([0, 0]), 2),
                           (Data([0, 0]), -1), (Data(repeating: 0, count: 96_002), 48_001)] {
        rejects { _ = try codec.append(pcm, frameCount: frames, generation: old) }
    }
    let packet = bytes(tone(960))
    _ = try codec.append(packet, frameCount: 960, generation: old)
    let current = codec.reset()
    precondition(current != old)
    rejects { _ = try codec.append(packet, frameCount: 960, generation: old) }
    rejects { _ = try codec.flush(generation: old) }
    var fresh = try codec.append(Data(repeating: 0, count: 1_920), frameCount: 960, generation: current)
    fresh += try codec.flush(generation: current)
    check(try samples(fresh) == Array(repeating: 0, count: 480))
    rejects { _ = try codec.append(packet, frameCount: 960, generation: current) }
    check(try codec.flush(generation: current).isEmpty)
    let empty = codec.reset()
    check(try codec.flush(generation: empty).isEmpty)
    let ongoing = codec.reset()
    var total = 0
    for index in 0..<1_500 {
        let chunks = try codec.append(bytes(tone(960, offset: index * 960)), frameCount: 960, generation: ongoing)
        total += try samples(chunks).count
    }
    total += try samples(codec.flush(generation: ongoing)).count
    precondition(total == 720_000)
    print("PASS 1500 continuous 20ms blocks, 720000 output samples, flush/reset and stale fences")
}

func coreChecks(script: String, module: String, node: String) throws {
    let codec = try NativeRealtimePCMCodec()
    var chunks = try codec.append(bytes(tone(960)), frameCount: 960, generation: codec.generation)
    chunks += try codec.flush(generation: codec.generation)
    chunks.append(try NativeRealtimeAudio(pcm: Data(repeating: 0, count: 48_000), direction: .input))
    chunks.append(try NativeRealtimeAudio(pcm: bytes([0, 32_767, -32_768, -1]), direction: .input))
    let input = Pipe(), output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [script, module]
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(chunks))
    try input.fileHandleForWriting.close()
    let report = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0)
    precondition(String(data: report, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                 == "PASS Core producer accepts Swift DTO and output callback matches PCM")
    print("PASS Core producer accepts Swift DTO and output callback matches PCM")
}

@main
struct Checks {
    static func main() throws {
        try dtoChecks()
        print("PASS Core DTO exact fields, canonical base64, 1s/10s limits and nullable samples")
        try signalChecks()
        try lifecycleChecks()
        if CommandLine.arguments.count == 4 {
            try coreChecks(script: CommandLine.arguments[1], module: CommandLine.arguments[2], node: CommandLine.arguments[3])
        }
    }
}
