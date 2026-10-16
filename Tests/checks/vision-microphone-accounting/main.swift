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
    let target = AVAudioFormat(standardFormatWithSampleRate:48_000,channels:1)!
    let reference = AVAudioConverter(from:format,to:target)!
    let total = size*4
    let whole = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:total)!
    whole.frameLength = total
    for i in 0..<Int(total) { whole.floatChannelData![0][i] = Float(i/Int(size)+1)/8 }
    let output = AVAudioPCMBuffer(pcmFormat:target,frameCapacity:AVAudioFrameCount(Double(total)*48_000/rate))!
    var cursor: AVAudioFrameCount = 0, retained: [AVAudioPCMBuffer] = []
    var error: NSError?
    let status = reference.convert(to:output,error:&error) { requested,state in
        guard cursor < total else { state.pointee = .noDataNow; return nil }
        let count = min(requested,total-cursor)
        let part = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:count)!
        part.frameLength = count
        part.floatChannelData![0].update(from:whole.floatChannelData![0].advanced(by:Int(cursor)),count:Int(count))
        cursor += count; retained.append(part); state.pointee = .haveData
        return part
    }
    withExtendedLifetime(retained) {}
    var referencePCM = Data(), actualPCM = Data()
    var packetizer = IPadMicrophonePCM()
    if error == nil && status != .error {
        packetizer.append(UnsafeBufferPointer(start:output.floatChannelData![0],count:Int(output.frameLength))) { referencePCM.append($0.pcm) }
    }
    frames.forEach { actualPCM.append($0.pcm) }
    check(!referencePCM.isEmpty && actualPCM == referencePCM,"chunked signal is bitwise equal to single continuous converter reference \(rate)Hz")
    print("REFERENCE \(rate)Hz sourceConsumed=\(cursor)/\(total) samples=\(output.frameLength) bytes=\(referencePCM.count) match=\(actualPCM == referencePCM)")
    print("ACCOUNTING \(rate)Hz packets=\(frames.count)/\(expected), levels=\(levels)")
}
print("RESULT_ASSERTIONS \(assertions)")
print("RESULT_FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
