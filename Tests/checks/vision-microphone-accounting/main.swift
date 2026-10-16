import AVFoundation
import Foundation
import os

var assertions = 0, failures = 0
func check(_ value: @autoclosure () -> Bool,_ name:String) {
    assertions += 1
    if !value() { failures += 1; print("FAIL \(name)") }
}
for (rate,size): (Double,AVAudioFrameCount) in [(16_000,4_800),(48_000,4_800)] {
    let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:1)!
    let result = OSAllocatedUnfairLock(initialState:[IPadMicrophonePCMFrame]())
    let completed = DispatchSemaphore(value:0)
    let worker = IPadMicrophoneConversionWorker()
    let id = worker.beginBatch(inputFormat:format) { frames in
        result.withLock { $0.append(contentsOf:frames) }; completed.signal()
    }!
    for block in 0..<4 {
        let input = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:size)!
        input.frameLength = size
        let value = Float(block+1)/8
        for i in 0..<Int(size) { input.floatChannelData![0][i] = value }
        worker.enqueue(input,captureID:id)
        check(completed.wait(timeout:.now()+2) == .success,"large input completion \(rate)Hz block\(block)")
    }
    worker.end()
    let frames = result.withLock { $0 }
    let expected = Int(Double(size)*4*48_000/rate)/960
    check(frames.count >= expected-1 && frames.count <= expected,"large consecutive complete packet accounting \(rate)Hz")
    check(frames.map(\.sequence) == (1...max(1,frames.count)).prefix(frames.count).map(UInt64.init),"large consecutive sequence \(rate)Hz")
    var levels = [Int](repeating:0,count:4)
    for frame in frames {
        for i in stride(from:0,to:frame.pcm.count,by:2) {
            let sample = Int(Int16(bitPattern:UInt16(frame.pcm[i]) | UInt16(frame.pcm[i+1])<<8))
            for level in 0..<4 where abs(sample-(level+1)*4096) < 8 { levels[level] += 1 }
        }
    }
    let perBlock = Int(Double(size)*48_000/rate)
    check(levels.allSatisfy { $0 >= perBlock-960 },"distinct consecutive signals retain each input block \(rate)Hz")
    print("ACCOUNTING \(rate)Hz packets=\(frames.count)/\(expected), levels=\(levels)")
}
print("RESULT_ASSERTIONS \(assertions)")
print("RESULT_FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
