import Foundation
import CoreAudio
import AudioToolbox
import StreamProtocol

final class FakeHAL {
    var trace: [String] = []
    var failAt: String?
    var readbackMismatch = false
    var unsupportedFormat = false
    var physicalTransport = false
    var wrongPlugin = false
    var wrongUID = false
    var wrongChannels = false
    var stopped = false
    var disposed = false
    var quiescent = true
    var selected = AudioDeviceID(0)
    var format = AudioStreamBasicDescription()
    var callback: AURenderCallbackStruct?
    let handle = AudioUnit(bitPattern: 0x1234)!
    func status(_ name: String) -> OSStatus {
        trace.append(name)
        return failAt == name ? -77 : noErr
    }
    var operations: HALMicrophoneOperations {
        HALMicrophoneOperations(supportsCallbackQuiescence: true, objectGet: { [self] object, address, _, qualifier, size, output in
            let selector = address.pointee.mSelector
            let result = status("read:\(selector)")
            guard result == noErr else { return result }
            switch selector {
            case kAudioHardwarePropertyTranslateUIDToDevice:
                let uid = qualifier!.assumingMemoryBound(to: CFString.self).pointee as String
                output.assumingMemoryBound(to: AudioDeviceID.self).pointee = uid == "test.output" ? 41 : 42
                size.pointee = 4
            case kAudioDevicePropertyDeviceUID:
                output.assumingMemoryBound(to: CFString?.self).pointee = (wrongUID ? "wrong" : object == 41 ? "test.output" : "test.input") as CFString
            case kAudioDevicePropertyTransportType:
                output.assumingMemoryBound(to: UInt32.self).pointee = physicalTransport ? 0 : kAudioDeviceTransportTypeVirtual
            case kAudioObjectPropertyOwner:
                output.assumingMemoryBound(to: AudioObjectID.self).pointee = 70
            case kAudioDevicePropertyDeviceIsAlive:
                output.assumingMemoryBound(to: UInt32.self).pointee = 1
            case kAudioDevicePropertyNominalSampleRate:
                output.assumingMemoryBound(to: Float64.self).pointee = 48_000
            case kAudioPlugInPropertyBundleID:
                output.assumingMemoryBound(to: CFString?.self).pointee = (wrongPlugin ? "wrong" : "test.plugin") as CFString
            case kAudioDevicePropertyStreamConfiguration:
                output.assumingMemoryBound(to: AudioBufferList.self).pointee = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: wrongChannels ? 3 : 2, mDataByteSize: 0, mData: nil))
            default: return -78
            }
            return noErr
        }, objectSize: { [self] _, _, size in
            let result = status("streamSize")
            size.pointee = UInt32(MemoryLayout<AudioBufferList>.size)
            return result
        }, create: { [self] in (status("create"), handle) },
        set: { [self] _, property, scope, bus, input, _ in
            let result = status("set:\(property):\(scope):\(bus)")
            guard result == noErr else { return result }
            switch property {
            case kAudioOutputUnitProperty_CurrentDevice: selected = input.assumingMemoryBound(to: AudioDeviceID.self).pointee
            case kAudioUnitProperty_StreamFormat: format = input.assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee
            case kAudioUnitProperty_SetRenderCallback: callback = input.assumingMemoryBound(to: AURenderCallbackStruct.self).pointee
            default: break
            }
            return noErr
        }, get: { [self] _, property, _, _, output, _ in
            let result = status("get:\(property)")
            guard result == noErr else { return result }
            switch property {
            case kAudioOutputUnitProperty_CurrentDevice:
                output.assumingMemoryBound(to: AudioDeviceID.self).pointee = readbackMismatch ? 999 : selected
            case kAudioUnitProperty_StreamFormat:
                var value = format
                if unsupportedFormat { value.mSampleRate = 44_100 }
                output.assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee = value
            default: return -78
            }
            return noErr
        }, initialize: { [self] _ in status("initialize") }, start: { [self] _ in status("start") },
        stop: { [self] _ in let value = status("stop"); stopped = value == noErr; return value },
        uninitialize: { [self] _ in status("uninitialize") },
        dispose: { [self] _ in let value = status("dispose"); disposed = value == noErr; return value },
        callbackQuiescence: { [self] in trace.append("quiescence"); return quiescent })
    }
    func render(frames: Int = 2) -> [Int16] {
        let pcm = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
        pcm.initialize(repeating: 123, count: frames * 2)
        defer { pcm.deinitialize(count: frames * 2); pcm.deallocate() }
        var buffers = AudioBufferList(mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 4), mData: pcm))
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        if let callback, let function = callback.inputProc, let ref = callback.inputProcRefCon {
            _ = function(ref, &flags, &time, 0, UInt32(frames), &buffers)
        }
        return Array(UnsafeBufferPointer(start: pcm, count: frames * 2))
    }
}
