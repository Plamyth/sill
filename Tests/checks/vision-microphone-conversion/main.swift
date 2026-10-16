import AVFoundation
import Foundation
import os

var checks = 0, failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL \(name)") }
}
struct Result {
    var frames: [IPadMicrophonePCMFrame] = []
}
func convert(rate: Double, frames: AVAudioFrameCount, channels: AVAudioChannelCount = 1, blocks: Int = 1) -> [IPadMicrophonePCMFrame] {
    let result = OSAllocatedUnfairLock(initialState: Result())
    let worker = IPadMicrophoneConversionWorker()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    guard let id = worker.begin(inputFormat: format, emit: { frame in result.withLock { $0.frames.append(frame) } }) else {
        check(false, "software converter accepts hardware format"); return []
    }
    for _ in 0..<blocks {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = 0.25 }
        }
        worker.enqueue(buffer, captureID: id)
    }
    worker.end()
    return result.withLock { $0.frames }
}
for frames: AVAudioFrameCount in [960, 4_800, 16_384] {
    let output = convert(rate: 48_000, frames: frames)
    let expected = Int(frames)/960
    print("PROBE nominal \(frames) -> \(output.count) packets; expected \(expected)")
    check(output.count == expected, "48k hardware buffer \(frames) preserves all complete wire blocks")
    check(output.map(\.sequence) == Array(1...max(1, output.count)).prefix(output.count).map(UInt64.init), "48k sequence follows complete PCM blocks \(frames)")
    check(output.allSatisfy { $0.frameCount == 960 && $0.pcm.count == 1920 }, "wire blocks stay bounded \(frames)")
    check(output.allSatisfy { frame in stride(from: 0, to: frame.pcm.count, by: 2).allSatisfy { frame.pcm[$0] == 0 && frame.pcm[$0+1] == 32 } }, "same-rate mono PCM preserves sample value \(frames)")
}
let stereo = convert(rate: 48_000, frames: 4_800, channels: 2)
print("PROBE stereo4800 -> \(stereo.count) packets")
check(stereo.count == 5, "stereo hardware buffer preserves all complete mono blocks")
let upsampled = convert(rate: 16_000, frames: 1_600)
print("PROBE 16k1600 -> \(upsampled.count) packets")
check(upsampled.count >= 4, "upsampled 100ms preserves complete output beyond one converter buffer")
let largeUpsampled = convert(rate: 16_000, frames: 4_800)
print("PROBE 16k4800 -> \(largeUpsampled.count) packets")
check(largeUpsampled.count >= 14, "upsampled 300ms preserves complete output beyond one converter buffer")
print("RESULT_ASSERTIONS \(checks)")
print("RESULT_FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
