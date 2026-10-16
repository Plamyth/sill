import Foundation

var pcm = IPadMicrophonePCM()
var frames: [IPadMicrophonePCMFrame] = []
let first = [Float](repeating: 0.5, count: 959)
first.withUnsafeBufferPointer { pcm.append($0) { frames.append($0) } }
precondition(frames.isEmpty)
let second: [Float] = [Float.nan, -1, 1] + [Float](repeating: 0, count: 957)
second.withUnsafeBufferPointer { pcm.append($0) { frames.append($0) } }
precondition(frames.count == 1 && frames[0].sequence == 1)
precondition(frames[0].frameCount == 960 && frames[0].pcm.count == 1920)
precondition(frames[0].pcm[1918] == 0 && frames[0].pcm[1919] == 0) // NaN becomes silence.
let third = [Float](repeating: 1, count: 960)
third.withUnsafeBufferPointer { pcm.append($0) { frames.append($0) } }
precondition(frames.count == 2 && frames[1].sequence == 2)
precondition(frames[1].pcm[0] == 0 && frames[1].pcm[1] == 128) // -1 -> -32768.
precondition(frames[1].pcm[2] == 255 && frames[1].pcm[3] == 127) // +1 -> +32767.
pcm.reset()
third.withUnsafeBufferPointer { pcm.append($0) { frames.append($0) } }
precondition(frames.count == 3 && frames[2].sequence == 1)
print("iPad microphone PCM framing passed")
