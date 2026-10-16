import AVFoundation
import Foundation

let input = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 2_048)!
buffer.frameLength = 2_048
for channel in 0..<2 {
    let samples = buffer.floatChannelData![channel]
    for index in 0..<Int(buffer.frameLength) {
        samples[index] = channel == 0 ? 0.4 : -0.2
    }
}

let worker = IPadMicrophoneConversionWorker()
let lock = NSLock()
var frames: [IPadMicrophonePCMFrame] = []
let collect: @Sendable (IPadMicrophonePCMFrame) -> Void = { frame in
    lock.lock()
    frames.append(frame)
    lock.unlock()
}
let old = worker.begin(inputFormat: input, emit: collect)!
worker.enqueue(buffer, captureID: old)
worker.end()
lock.lock()
let first = frames
lock.unlock()
precondition(!first.isEmpty && first[0].sequence == 1)
precondition(first.allSatisfy { $0.frameCount == 960 && $0.pcm.count == 1_920 })
precondition(first[0].pcm.contains(where: { $0 != 0 }))

let current = worker.begin(inputFormat: input, emit: collect)!
worker.enqueue(buffer, captureID: old) // callback from the retired capture
worker.enqueue(buffer, captureID: current)
worker.end()
lock.lock()
let second = Array(frames.dropFirst(first.count))
lock.unlock()
precondition(!second.isEmpty && second[0].sequence == 1)
precondition(second.count == first.count)
print("iPad microphone conversion and stale-capture fence passed")
