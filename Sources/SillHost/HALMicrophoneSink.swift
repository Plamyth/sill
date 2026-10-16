import Foundation
import AudioToolbox
import CoreAudio
import StreamProtocol
import os

struct HALMicrophoneOperations {
    var supportsCallbackQuiescence: Bool
    var objectGet: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UInt32, UnsafeRawPointer?, UnsafeMutablePointer<UInt32>, UnsafeMutableRawPointer) -> OSStatus
    var objectSize: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UnsafeMutablePointer<UInt32>) -> OSStatus
    var create: () -> (OSStatus, AudioUnit?)
    var set: (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UnsafeRawPointer, UInt32) -> OSStatus
    var get: (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>) -> OSStatus
    var initialize: (AudioUnit) -> OSStatus
    var start: (AudioUnit) -> OSStatus
    var stop: (AudioUnit) -> OSStatus
    var uninitialize: (AudioUnit) -> OSStatus
    var dispose: (AudioUnit) -> OSStatus
    var callbackQuiescence: () -> Bool

    static var native: Self {
        Self(supportsCallbackQuiescence: false, objectGet: { AudioObjectGetPropertyData($0, $1, $2, $3, $4, $5) },
             objectSize: { AudioObjectGetPropertyDataSize($0, $1, 0, nil, $2) },
             create: {
                 var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                     componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
                     componentFlags: 0, componentFlagsMask: 0)
                 guard let component = AudioComponentFindNext(nil, &description) else { return (-1, nil) }
                 var unit: AudioUnit?
                 let status = AudioComponentInstanceNew(component, &unit)
                 return (status, unit)
             }, set: { AudioUnitSetProperty($0, $1, $2, $3, $4, $5) },
             get: { AudioUnitGetProperty($0, $1, $2, $3, $4, $5) },
             initialize: { AudioUnitInitialize($0) }, start: { AudioOutputUnitStart($0) },
             stop: { AudioOutputUnitStop($0) }, uninitialize: { AudioUnitUninitialize($0) },
             dispose: { AudioComponentInstanceDispose($0) }, callbackQuiescence: { false })
    }
}

final class HALMicrophoneContext: @unchecked Sendable {
    let render: MicrophoneRenderBuffer
    let channels: Int
    let channel: Int
    private let callbacks = OSAllocatedUnfairLock(initialState: 0)
    init(render: MicrophoneRenderBuffer, channels: Int, channel: Int) {
        self.render = render; self.channels = channels; self.channel = channel
    }
    var inFlight: Int { callbacks.withLock { $0 } }
    func fill(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let buffers else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        func silence() {
            for buffer in list {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        let entered = callbacks.withLockIfAvailable { inFlight in
            inFlight += 1
            defer { inFlight -= 1 }
            silence()
            guard frames <= UInt32(MicrophoneWire.maxFrames), list.count == 1,
                  Int(list[0].mNumberChannels) == channels,
                  Int(list[0].mDataByteSize) >= Int(frames) * channels * 2,
                  let data = list[0].mData else { return }
            let samples = data.assumingMemoryBound(to: Int16.self)
            render.render(frames: Int(frames), now: render.monotonicNow()) { index, value in
                samples[index * channels + channel] = value
            }
        }
        if entered == nil { silence() }
        return noErr
    }
}

@MainActor
final class HALMicrophoneSink: HostMicrophoneSink {
    private let ops: HALMicrophoneOperations
    private let grant: HostLocalOwnerGrant
    private let context: HALMicrophoneContext
    private var contextPointer: UnsafeMutableRawPointer?
    private var unit: AudioUnit?
    private var initializationAttempted = false
    private var startAttempted = false
    private var stopped = false
    private var uninitialized = false
    private var disposed = false
    private var cleanupError: String?
    private var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var inputDevice = AudioDeviceID(kAudioObjectUnknown)

    private init(grant: HostLocalOwnerGrant, render: MicrophoneRenderBuffer, ops: HALMicrophoneOperations) {
        self.grant = grant; self.ops = ops
        context = HALMicrophoneContext(render: render, channels: grant.destination.outputChannels, channel: grant.destination.outputChannel)
    }

    nonisolated static var nativeSupported: Bool { HALMicrophoneOperations.native.supportsCallbackQuiescence }

    static func prepare(grant: HostLocalOwnerGrant, render: MicrophoneRenderBuffer,
                        ops: HALMicrophoneOperations = .native) -> HostMicrophonePreparation {
        guard ops.supportsCallbackQuiescence else {
            render.close()
            return HostMicrophonePreparation(resource: nil, error: "native callback quiescence unsupported; no IO attempted")
        }
        let sink = HALMicrophoneSink(grant: grant, render: render, ops: ops)
        do { try sink.open(); return HostMicrophonePreparation(resource: sink, error: nil) }
        catch { return HostMicrophonePreparation(resource: sink, error: String(describing: error)) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else { throw Failure(description: "\(stage): \(status)") }
    }

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check(ops.objectGet(object, &address, 0, nil, &size, &value), "read \(selector)")
        guard size == MemoryLayout<T>.size else { throw Failure(description: "property size") }
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: CFString? = nil
        try read(object, selector, into: &value)
        guard let value else { throw Failure(description: "missing identity") }
        return value as String
    }
    private func resolve(_ uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var qualifier = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try withUnsafePointer(to: &qualifier) {
            try check(ops.objectGet(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), $0, &size, &device), "resolve UID")
        }
        guard device != kAudioObjectUnknown, size == MemoryLayout<AudioDeviceID>.size else { throw Failure(description: "unknown UID") }
        return device
    }
    private func validate(_ device: AudioDeviceID, uid: String, scope: AudioObjectPropertyScope, channels: Int) throws {
        guard try string(device, kAudioDevicePropertyDeviceUID) == uid else { throw Failure(description: "UID mismatch") }
        var transport: UInt32 = 0, owner: AudioObjectID = 0, alive: UInt32 = 0
        var rate: Float64 = 0
        try read(device, kAudioDevicePropertyTransportType, into: &transport)
        try read(device, kAudioObjectPropertyOwner, into: &owner)
        try read(device, kAudioDevicePropertyDeviceIsAlive, into: &alive)
        try read(device, kAudioDevicePropertyNominalSampleRate, into: &rate)
        guard transport == kAudioDeviceTransportTypeVirtual, alive == 1, rate == 48_000,
              try string(owner, kAudioPlugInPropertyBundleID) == grant.destination.pluginBundleID else {
            throw Failure(description: "unapproved virtual endpoint")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(ops.objectSize(device, &address, &size), "stream configuration size")
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        let stride = MemoryLayout<AudioBuffer>.stride
        guard Int(size) >= offset + stride, Int(size) <= offset + 32 * stride else { throw Failure(description: "stream configuration cap") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let capacity = size
        try check(ops.objectGet(device, &address, 0, nil, &size, storage), "stream configuration")
        guard size == capacity else { throw Failure(description: "stream configuration changed") }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        guard count > 0, count <= 32, offset + count * stride <= Int(size) else { throw Failure(description: "invalid stream configuration") }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let countChannels = buffers.reduce(0) { $0 + min(Int($1.mNumberChannels), 33) }
        guard countChannels == channels else { throw Failure(description: "channel mapping changed") }
    }

    private func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ bus: AudioUnitElement, _ value: inout T) throws {
        guard let unit else { throw Failure(description: "unit absent") }
        try check(ops.set(unit, property, scope, bus, &value, UInt32(MemoryLayout<T>.size)), "set \(property)")
    }

    private func open() throws {
        guard grant.valid(at: context.render.monotonicNow()) else { throw Failure(description: "owner revoked") }
        let destination = grant.destination
        outputDevice = try resolve(destination.outputUID)
        inputDevice = try resolve(destination.inputUID)
        try validate(outputDevice, uid: destination.outputUID, scope: kAudioObjectPropertyScopeOutput, channels: destination.outputChannels)
        try validate(inputDevice, uid: destination.inputUID, scope: kAudioObjectPropertyScopeInput, channels: destination.inputChannels)
        let created = ops.create()
        unit = created.1
        try check(created.0, "create")
        guard let unit else { throw Failure(description: "create returned no unit") }
        var input: UInt32 = 0, output: UInt32 = 1
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &input)
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &output)
        var selected = outputDevice
        try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected)
        var readback = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(ops.get(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &readback, &size), "device readback")
        guard size == MemoryLayout<AudioDeviceID>.size, readback == outputDevice else { throw Failure(description: "device readback mismatch") }
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(destination.outputChannels * 2), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(destination.outputChannels * 2), mChannelsPerFrame: UInt32(destination.outputChannels), mBitsPerChannel: 16, mReserved: 0)
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format)
        var accepted = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(ops.get(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &accepted, &size), "format readback")
        guard size == MemoryLayout<AudioStreamBasicDescription>.size,
              accepted.mSampleRate == format.mSampleRate, accepted.mFormatID == format.mFormatID,
              accepted.mFormatFlags == format.mFormatFlags, accepted.mChannelsPerFrame == format.mChannelsPerFrame,
              accepted.mBytesPerFrame == format.mBytesPerFrame, accepted.mBytesPerPacket == format.mBytesPerPacket,
              accepted.mBitsPerChannel == 16, accepted.mFramesPerPacket == 1 else { throw Failure(description: "unsupported client format") }
        contextPointer = Unmanaged.passRetained(context).toOpaque()
        var callback = AURenderCallbackStruct(inputProc: { ref, _, _, _, frames, buffers in
            Unmanaged<HALMicrophoneContext>.fromOpaque(ref).takeUnretainedValue().fill(frames: frames, buffers: buffers)
        }, inputProcRefCon: contextPointer)
        try set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback)
        var maximum: UInt32 = UInt32(MicrophoneWire.maxFrames)
        try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum)
        initializationAttempted = true
        try check(ops.initialize(unit), "initialize")
        guard grant.valid(at: context.render.monotonicNow()), context.render.isOpen else { throw Failure(description: "owner revoked during setup") }
        startAttempted = true
        try check(ops.start(unit), "start")
    }

    func runtimeValid() -> Bool {
        guard cleanupError == nil, !disposed, context.render.isOpen, grant.valid(at: context.render.monotonicNow()) else { return false }
        do {
            try validate(outputDevice, uid: grant.destination.outputUID, scope: kAudioObjectPropertyScopeOutput, channels: grant.destination.outputChannels)
            try validate(inputDevice, uid: grant.destination.inputUID, scope: kAudioObjectPropertyScopeInput, channels: grant.destination.inputChannels)
            return true
        } catch { return false }
    }

    func retryClose() async -> String? {
        cleanupError = nil
        return await close()
    }

    func close() async -> String? {
        context.render.close()
        if let cleanupError { return cleanupError }
        guard let unit else { return nil }
        func failure(_ status: OSStatus, _ stage: String) -> String? {
            guard status != noErr else { return nil }
            let error = "\(stage): \(status)"
            cleanupError = error
            return error
        }
        if startAttempted && !stopped {
            if let error = failure(ops.stop(unit), "stop") { return error }
            stopped = true
        }
        if initializationAttempted && !uninitialized {
            if let error = failure(ops.uninitialize(unit), "uninitialize") { return error }
            uninitialized = true
        }
        if !disposed {
            if let error = failure(ops.dispose(unit), "dispose") { return error }
            disposed = true
        }
        if let pointer = contextPointer {
            guard ops.callbackQuiescence(), context.inFlight == 0 else {
                cleanupError = "callback quiescence unproved; retained context"
                return cleanupError
            }
            Unmanaged<HALMicrophoneContext>.fromOpaque(pointer).release()
            contextPointer = nil
        }
        self.unit = nil
        return nil
    }
}
