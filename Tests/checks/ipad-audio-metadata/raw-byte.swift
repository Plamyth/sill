import AVFoundation
import Foundation

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [IPadMicrophonePCMFrame] = []
    func append(_ frame: IPadMicrophonePCMFrame) { lock.lock(); defer { lock.unlock() }; frames.append(frame) }
    var value: [IPadMicrophonePCMFrame] { lock.lock(); defer { lock.unlock() }; return frames }
}
@main struct RawByteChecks {
    static func main() {
        for rate in [16_000.0, 44_100.0, 48_000.0, 96_000.0] {
            for channels: AVAudioChannelCount in [1, 2] {
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
                buffer.frameLength = 2048
                for channel in 0..<Int(channels) {
                    for index in 0..<2048 { buffer.floatChannelData![channel][index] = Float((index % 11) - 5) / 10 }
                }
                let before = Collected(), after = Collected()
                let baseline = BaselineMicrophoneConversionWorker(), candidate = IPadMicrophoneConversionWorker()
                let old = baseline.begin(inputFormat: format, emit: { before.append($0) })!
                let new = candidate.begin(inputFormat: format, emit: { after.append($0) })!
                baseline.enqueue(buffer, captureID: old); baseline.end()
                candidate.enqueue(buffer, captureID: new); candidate.end()
                precondition(!before.value.isEmpty)
                precondition(before.value == after.value, "exact sequence/frameCount/PCM bytes must match baseline")
            }
        }
        print("8 offline synthetic conversion cases: exact raw-byte equality with 14e9410 passed; no sample data logged")
    }
}
