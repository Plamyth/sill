import AVFAudio
import Foundation

typealias Engine = NativeRealtimePCM<Int>
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    precondition(value(), name)
    checks += 1
}
func rejects(_ expected: Engine.Failure, _ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("expected rejection") }
    catch { check((error as? Engine.Failure) == expected, "fixed rejection") }
}
func convert(_ engine: Engine, _ samples: [Int16], sequence: UInt64 = 1, scope: Int = 1,
             rate: Double = 48_000, channels: Int = 1, frames: Int? = nil) throws -> [Int16] {
    var result: [Int16] = []
    let receipt = try samples.withUnsafeBytes { bytes in
        try engine.convert(bytes, sampleRate: rate, channels: channels,
                           frameCount: frames ?? samples.count, sequence: sequence, scope: scope) { pcm, receipt in
            check(pcm.count == receipt.outputFrames * 2, "actual output frame count")
            result = Array(pcm.bindMemory(to: Int16.self))
        }
    }
    check(result.count == receipt.outputFrames, "reported actual frame count")
    return result
}

rejects(.invalidCapacity) { _ = try Engine(maxInputFrames: 0) }
rejects(.invalidCapacity) { _ = try Engine(maxInputFrames: Int.max) }
let engine = try Engine()
check(engine.maxInputFrames == 960 && engine.ownedPCMByteCapacity == 3392, "fixed owned capacity")
let zeros = [Int16](repeating: 0, count: 960)
rejects(.inactiveScope) { _ = try convert(engine, zeros) }
try engine.reset(scope: 1)
rejects(.inactiveScope) { _ = try convert(engine, zeros, scope: 2) }
rejects(.staleSequence) { _ = try convert(engine, zeros, sequence: 0) }
for rate in [0.0, -1.0, 24_000.0, Double.nan, Double.infinity] {
    rejects(.invalidFormat) { _ = try convert(engine, zeros, rate: rate) }
}
for channels in [0, 2, Int.max] {
    rejects(.invalidFormat) { _ = try convert(engine, zeros, channels: channels) }
}
for frames in [0, -1, 961, Int.max] {
    rejects(.invalidFrames) { _ = try convert(engine, zeros, frames: frames) }
}
rejects(.invalidBytes) { _ = try convert(engine, zeros, frames: 959) }
rejects(.invalidBytes) {
    try [UInt8](repeating: 0, count: 1919).withUnsafeBytes { bytes in
        _ = try engine.convert(bytes, sampleRate: 48_000, channels: 1, frameCount: 960,
                               sequence: 1, scope: 1) { _, _ in preconditionFailure("odd PCM consumed") }
    }
}
let silence = try convert(engine, zeros)
check(!silence.isEmpty && silence.allSatisfy { $0 == 0 }, "real converter silence")
rejects(.staleSequence) { _ = try convert(engine, zeros) }
rejects(.staleSequence) { _ = try convert(engine, zeros, sequence: 0) }
_ = try convert(engine, zeros, sequence: UInt64.max)
rejects(.staleSequence) { _ = try convert(engine, zeros, sequence: 1) }

let signal = (0..<9600).map { Int16(12_000 * sin(2 * Double.pi * 997 * Double($0) / 48_000)) }
let whole = try Engine(maxInputFrames: signal.count)
try whole.reset(scope: 1)
let reference = try convert(whole, signal)
try engine.reset(scope: 1)
var fragmented: [Int16] = []
for part in 0..<10 {
    fragmented += try convert(engine, Array(signal[(part * 960)..<((part + 1) * 960)]), sequence: UInt64(part + 1))
}
check(reference == fragmented && reference.count == 4800, "real converter split ordering equals batch")
check(reference.contains { $0 > 1000 } && reference.contains { $0 < -1000 }, "nontrivial converted signal")
let oddChunks = try Engine()
try oddChunks.reset(scope: 1)
var oddResult: [Int16] = []
var position = 0
for (index, count) in [1, 3, 7, 949].enumerated() {
    oddResult += try convert(oddChunks, Array(signal[position..<(position + count)]), sequence: UInt64(index + 1))
    position += count
}
check(oddResult == Array(reference.prefix(480)), "odd input frame splits preserve sample order")
try engine.reset(scope: 2)
rejects(.inactiveScope) { _ = try convert(engine, zeros, sequence: 11) }
let afterReset = try convert(engine, zeros, scope: 2)
check(afterReset.allSatisfy { $0 == 0 }, "reset discards old filter PCM")
try engine.reset(scope: nil)
rejects(.inactiveScope) { _ = try convert(engine, zeros, scope: 2) }

var heldInput: AVAudioPCMBuffer?
var heldOutput: AVAudioPCMBuffer?
let observed = try Engine(operations: { converter in
    let native = Engine.Operations.native(converter)
    return Engine.Operations(convert: { output, input in
        heldOutput = output
        return native.convert(output) { count, status in
            let value = input(count, status)
            if let pcm = value as? AVAudioPCMBuffer { heldInput = pcm }
            return value
        }
    }, reset: native.reset)
})
try observed.reset(scope: 1)
var source = Array(signal.prefix(960))
let consumed = try convert(observed, source)
source.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
check(consumed.contains { $0 != 0 }, "consumer bounded copy survives caller zeroing")
for buffer in [heldInput, heldOutput] {
    let buffer = buffer!
    check(buffer.frameLength == 0, "owned frame length cleared")
    let samples = UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameCapacity))
    check(samples.allSatisfy { $0 == 0 }, "owned PCM memory zeroed")
}
try observed.reset(scope: 2)
_ = try zeros.withUnsafeBytes { bytes in
    try observed.convert(bytes, sampleRate: 48_000, channels: 1, frameCount: 960,
                         sequence: 1, scope: 2) { _, _ in
        rejects(.busy) { try observed.reset(scope: 3) }
    }
}
enum ConsumerFailure: Error { case full }
rejects(.consumerRejected) {
    _ = try zeros.withUnsafeBytes { bytes in
        try observed.convert(bytes, sampleRate: 48_000, channels: 1, frameCount: 960,
                             sequence: 2, scope: 2) { _, _ in throw ConsumerFailure.full }
    }
}
rejects(.inactiveScope) { _ = try convert(observed, zeros, sequence: 3, scope: 2) }

for kind in 0..<5 {
    var resets = 0
    let faulty = try Engine(operations: { _ in
        Engine.Operations(convert: { output, input in
            var status = AVAudioConverterInputStatus.haveData
            _ = input(kind == 3 ? 0 : 960, &status)
            output.frameLength = kind == 4 ? 300 : 0
            if kind == 0 { return (.error, nil) }
            if kind == 1 { return (.inputRanDry, NSError(domain: "synthetic", code: 1)) }
            if kind == 2 { return (.endOfStream, nil) }
            return (.inputRanDry, nil)
        }, reset: { resets += 1 })
    })
    try faulty.reset(scope: 1)
    rejects(kind == 4 ? .invalidOutput : .conversionFailed) {
        _ = try convert(faulty, kind == 4 ? [0, 0] : zeros)
    }
    check(resets == 2, "converter error resets state")
    rejects(.inactiveScope) { _ = try convert(faulty, zeros, sequence: 2) }
}
let shortRead = try Engine(operations: { _ in
    Engine.Operations(convert: { _, input in
        var status = AVAudioConverterInputStatus.haveData
        _ = input(1, &status)
        return (.inputRanDry, nil)
    }, reset: {})
})
try shortRead.reset(scope: 1)
rejects(.inputNotConsumed) { _ = try convert(shortRead, zeros) }
let maxEngine = try Engine(maxInputFrames: Engine.maximumInputFrames)
check(maxEngine.ownedPCMByteCapacity <= 1_440_514, "hard owned PCM memory cap")
try maxEngine.reset(scope: 1)
let maximumSilence = try convert(maxEngine, [Int16](repeating: 0, count: Engine.maximumInputFrames))
check(maximumSilence.count == 240_000 && maximumSilence.allSatisfy { $0 == 0 }, "ten second input boundary")
print("NATIVE_PCM_FIXTURE " + "{\"checks\":\(checks),\"failed\":0,\"realAppleConverter\":true,\"actualAudioIO\":0,\"hostCalls\":0,\"audioPayloadSaved\":false}")
