import Foundation
import AudioToolbox
import AVFAudio
import CoreAudio
import StreamProtocol

protocol HALMicrophoneOutputUnit: AnyObject {
    var inputEnabled: Bool { get set }
    var outputEnabled: Bool { get set }
    var deviceID: AudioDeviceID { get }
    var format: AudioStreamBasicDescription? { get }
    var maximumFrames: UInt32 { get set }
    var provider: AURenderPullInputBlock? { get set }
    var isRunning: Bool { get }
    var resourcesAllocated: Bool { get }
    func selectDevice(_ id: AudioDeviceID) throws
    func setFormat(_ format: AudioStreamBasicDescription) throws
    func allocate() throws
    func start() throws
    func stop()
    func deallocate()
}

private struct HALMicrophoneFailure: Error, CustomStringConvertible {
    let description: String
}

private final class NativeMicrophoneOutputUnit: HALMicrophoneOutputUnit {
    private let unit: AUAudioUnit
    init() throws {
        unit = try AUAudioUnit(componentDescription: AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
    }
    var inputEnabled: Bool { get { unit.isInputEnabled } set { unit.isInputEnabled = newValue } }
    var outputEnabled: Bool { get { unit.isOutputEnabled } set { unit.isOutputEnabled = newValue } }
    var deviceID: AudioDeviceID { unit.deviceID }
    var format: AudioStreamBasicDescription? {
        unit.inputBusses.count > 0 ? unit.inputBusses[0].format.streamDescription.pointee : nil
    }
    var maximumFrames: UInt32 { get { unit.maximumFramesToRender } set { unit.maximumFramesToRender = newValue } }
    var provider: AURenderPullInputBlock? { get { unit.outputProvider } set { unit.outputProvider = newValue } }
    var isRunning: Bool { unit.isRunning }
    var resourcesAllocated: Bool { unit.renderResourcesAllocated }
    func selectDevice(_ id: AudioDeviceID) throws { try unit.setDeviceID(id) }
    func setFormat(_ format: AudioStreamBasicDescription) throws {
        var value = format
        guard unit.inputBusses.count > 0, let accepted = AVAudioFormat(streamDescription: &value) else {
            throw HALMicrophoneFailure(description: "output bus format unavailable")
        }
        try unit.inputBusses[0].setFormat(accepted)
    }
    func allocate() throws { try unit.allocateRenderResources() }
    func start() throws { try unit.startHardware() }
    func stop() { unit.stopHardware() }
    func deallocate() { unit.deallocateRenderResources() }
}

struct HALMicrophoneOperations: @unchecked Sendable {
    var objectGet: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UInt32, UnsafeRawPointer?, UnsafeMutablePointer<UInt32>, UnsafeMutableRawPointer) -> OSStatus
    var objectSize: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UnsafeMutablePointer<UInt32>) -> OSStatus
    var create: () throws -> any HALMicrophoneOutputUnit
    static var native: Self {
        Self(objectGet: { AudioObjectGetPropertyData($0, $1, $2, $3, $4, $5) },
             objectSize: { AudioObjectGetPropertyDataSize($0, $1, 0, nil, $2) },
             create: { try NativeMicrophoneOutputUnit() })
    }
}

final class HALMicrophoneContext: @unchecked Sendable {
    let render: MicrophoneRenderBuffer
    let channels: Int
    let channel: Int
    init(render: MicrophoneRenderBuffer, channels: Int, channel: Int) {
        self.render = render; self.channels = channels; self.channel = channel
    }
    func fill(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        for buffer in list {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard frames <= UInt32(MicrophoneWire.maxFrames), list.count == 1,
              Int(list[0].mNumberChannels) == channels,
              Int(list[0].mDataByteSize) >= Int(frames) * channels * 2,
              let data = list[0].mData else { return noErr }
        let samples = data.assumingMemoryBound(to: Int16.self)
        render.render(frames: Int(frames), now: render.monotonicNow()) { index, value in
            samples[index * channels + channel] = value
        }
        return noErr
    }
}

private actor HALMicrophoneWorker {
    private enum Stage { case absent, created, allocationAttempted, startAttempted, stopped, deallocated }
    private let ops: HALMicrophoneOperations
    private let grant: HostLocalOwnerGrant
    private let context: HALMicrophoneContext
    private var unit: (any HALMicrophoneOutputUnit)?
    private var stage = Stage.absent
    private var cleanupError: String?
    private var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var inputDevice = AudioDeviceID(kAudioObjectUnknown)
    init(grant: HostLocalOwnerGrant, render: MicrophoneRenderBuffer, ops: HALMicrophoneOperations) {
        self.grant = grant; self.ops = ops
        context = HALMicrophoneContext(render: render, channels: grant.destination.outputChannels, channel: grant.destination.outputChannel)
    }
    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else { throw HALMicrophoneFailure(description: "\(stage): \(status)") }
    }
    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check(ops.objectGet(object, &address, 0, nil, &size, &value), "read \(selector)")
        guard size == MemoryLayout<T>.size else { throw HALMicrophoneFailure(description: "property size") }
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: CFString? = nil
        try read(object, selector, into: &value)
        guard let value else { throw HALMicrophoneFailure(description: "missing identity") }
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
        guard device != kAudioObjectUnknown, size == MemoryLayout<AudioDeviceID>.size else { throw HALMicrophoneFailure(description: "unknown UID") }
        return device
    }
    private func validate(_ device: AudioDeviceID, uid: String, scope: AudioObjectPropertyScope, channels: Int) throws {
        guard try string(device, kAudioDevicePropertyDeviceUID) == uid else { throw HALMicrophoneFailure(description: "UID mismatch") }
        var transport: UInt32 = 0, owner: AudioObjectID = 0, alive: UInt32 = 0
        var rate: Float64 = 0
        try read(device, kAudioDevicePropertyTransportType, into: &transport)
        try read(device, kAudioObjectPropertyOwner, into: &owner)
        try read(device, kAudioDevicePropertyDeviceIsAlive, into: &alive)
        try read(device, kAudioDevicePropertyNominalSampleRate, into: &rate)
        guard transport == kAudioDeviceTransportTypeVirtual, alive == 1, rate == 48_000,
              try string(owner, kAudioPlugInPropertyBundleID) == grant.destination.pluginBundleID else {
            throw HALMicrophoneFailure(description: "unapproved virtual endpoint")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(ops.objectSize(device, &address, &size), "stream configuration size")
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        let stride = MemoryLayout<AudioBuffer>.stride
        guard Int(size) >= offset + stride, Int(size) <= offset + 32 * stride else { throw HALMicrophoneFailure(description: "stream configuration cap") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let capacity = size
        try check(ops.objectGet(device, &address, 0, nil, &size, storage), "stream configuration")
        guard size == capacity else { throw HALMicrophoneFailure(description: "stream configuration changed") }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        guard count > 0, count <= 32, offset + count * stride <= Int(size) else { throw HALMicrophoneFailure(description: "invalid stream configuration") }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let countChannels = buffers.reduce(0) { $0 + min(Int($1.mNumberChannels), 33) }
        guard countChannels == channels else { throw HALMicrophoneFailure(description: "channel mapping changed") }
    }


    func open() -> String? {
        do {
            guard grant.valid(at: context.render.monotonicNow()), context.render.isOpen else {
                throw HALMicrophoneFailure(description: "owner revoked")
            }
            let destination = grant.destination
            outputDevice = try resolve(destination.outputUID)
            inputDevice = try resolve(destination.inputUID)
            try validate(outputDevice, uid: destination.outputUID, scope: kAudioObjectPropertyScopeOutput, channels: destination.outputChannels)
            try validate(inputDevice, uid: destination.inputUID, scope: kAudioObjectPropertyScopeInput, channels: destination.inputChannels)
            let created = try ops.create()
            unit = created; stage = .created
            guard !created.isRunning, !created.resourcesAllocated else { throw HALMicrophoneFailure(description: "new unit already active") }
            created.inputEnabled = false
            created.outputEnabled = true
            guard !created.inputEnabled, created.outputEnabled else { throw HALMicrophoneFailure(description: "owned IO direction refused") }
            try created.selectDevice(outputDevice)
            let readback = created.deviceID
            guard readback == outputDevice else { throw HALMicrophoneFailure(description: "device readback mismatch") }
            let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(destination.outputChannels * 2), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(destination.outputChannels * 2), mChannelsPerFrame: UInt32(destination.outputChannels), mBitsPerChannel: 16, mReserved: 0)
            try created.setFormat(format)
            guard let accepted = created.format,
                  accepted.mSampleRate == format.mSampleRate, accepted.mFormatID == format.mFormatID,
                  accepted.mFormatFlags == format.mFormatFlags, accepted.mChannelsPerFrame == format.mChannelsPerFrame,
                  accepted.mBytesPerFrame == format.mBytesPerFrame, accepted.mBytesPerPacket == format.mBytesPerPacket,
                  accepted.mBitsPerChannel == 16, accepted.mFramesPerPacket == 1 else { throw HALMicrophoneFailure(description: "unsupported client format") }
            let context = self.context
            created.provider = { [context] _, _, frames, _, buffers in context.fill(frames: frames, buffers: buffers) }
            created.maximumFrames = UInt32(MicrophoneWire.maxFrames)
            guard created.provider != nil, created.maximumFrames == UInt32(MicrophoneWire.maxFrames) else {
                throw HALMicrophoneFailure(description: "render configuration refused")
            }
            stage = .allocationAttempted
            try created.allocate()
            guard created.resourcesAllocated, grant.valid(at: context.render.monotonicNow()), context.render.isOpen else {
                throw HALMicrophoneFailure(description: "allocation or owner lost")
            }
            stage = .startAttempted
            try created.start()
            guard created.isRunning, grant.valid(at: context.render.monotonicNow()), context.render.isOpen else {
                throw HALMicrophoneFailure(description: "start or owner lost")
            }
            return nil
        } catch { context.render.close(); return String(describing: error) }
    }

    func runtimeValid() -> Bool {
        guard cleanupError == nil, stage == .startAttempted, let unit,
              unit.isRunning, unit.resourcesAllocated, unit.deviceID == outputDevice,
              context.render.isOpen, grant.valid(at: context.render.monotonicNow()) else { return false }
        do {
            try validate(outputDevice, uid: grant.destination.outputUID, scope: kAudioObjectPropertyScopeOutput, channels: grant.destination.outputChannels)
            try validate(inputDevice, uid: grant.destination.inputUID, scope: kAudioObjectPropertyScopeInput, channels: grant.destination.inputChannels)
            return true
        } catch { return false }
    }

    func close(retry: Bool) -> String? {
        context.render.close()
        if let cleanupError, !retry { return cleanupError }
        cleanupError = nil
        guard let unit else { return nil }
        if stage == .startAttempted || unit.isRunning {
            unit.stop()
            guard !unit.isRunning else { cleanupError = "owned hardware still running"; return cleanupError }
            stage = .stopped
        }
        if stage == .allocationAttempted || stage == .stopped || unit.resourcesAllocated {
            unit.deallocate()
            guard !unit.resourcesAllocated, !unit.isRunning else { cleanupError = "owned render resources remain"; return cleanupError }
            stage = .deallocated
        }
        unit.provider = nil
        guard unit.provider == nil else { cleanupError = "owned provider remains"; return cleanupError }
        self.unit = nil
        stage = .absent
        return nil
    }
}

@MainActor
final class HALMicrophoneSink: HostMicrophoneSink {
    private let render: MicrophoneRenderBuffer
    private let worker: HALMicrophoneWorker
    private var validation: Task<Void, Never>?
    private var valid = true
    private var closing = false
    private init(grant: HostLocalOwnerGrant, render: MicrophoneRenderBuffer, ops: HALMicrophoneOperations) {
        self.render = render
        worker = HALMicrophoneWorker(grant: grant, render: render, ops: ops)
    }
    static func prepare(grant: HostLocalOwnerGrant, render: MicrophoneRenderBuffer,
                        ops: HALMicrophoneOperations = .native) async -> HostMicrophonePreparation {
        let sink = HALMicrophoneSink(grant: grant, render: render, ops: ops)
        let error = await sink.worker.open()
        sink.valid = error == nil
        return HostMicrophonePreparation(resource: sink, error: error)
    }
    func runtimeValid() -> Bool {
        guard valid, !closing, render.isOpen, render.grant.valid(at: render.monotonicNow()) else { return false }
        if validation == nil {
            let worker = self.worker
            validation = Task { [weak self] in
                let current = await worker.runtimeValid()
                guard let self else { return }
                self.validation = nil
                if !current { self.valid = false; self.render.close() }
            }
        }
        return valid
    }
    func close() async -> String? { await retire(retry: false) }
    func retryClose() async -> String? { await retire(retry: true) }
    private func retire(retry: Bool) async -> String? {
        render.close(); valid = false; closing = true
        return await worker.close(retry: retry)
    }
}
