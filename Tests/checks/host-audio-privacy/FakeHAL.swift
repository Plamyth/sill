import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import StreamProtocol

final class PrivacyFakeHAL: @unchecked Sendable {
    struct Failure: Error {}
    var snapshot = PrivacyAudioSnapshot(devices: [
        PrivacyAudioDevice(id: 10, uid: "builtin", transport: .builtIn, plugin: nil,
            inputChannels: 2, outputChannels: 2, inputMuted: false, outputMuted: false),
        PrivacyAudioDevice(id: 20, uid: "BlackHole2ch_UID", transport: .virtual,
            plugin: "audio.existential.BlackHole2ch", inputChannels: 2, outputChannels: 2),
        PrivacyAudioDevice(id: 30, uid: "BlackHole16ch_UID", transport: .virtual,
            plugin: "audio.existential.BlackHole16ch", inputChannels: 16, outputChannels: 16)
    ], input: 10, output: 10, systemOutput: 10)
    var writes: [PrivacyAudioWrite] = []
    var reads = 0
    var failSetter: Int?
    var ignoreSetter: Int?
    var missingSelector: AudioObjectPropertySelector?
    var wrongPlugin = false
    var wrongResolution = false
    var writable = true
    var readOnlyMutes: [PrivacyAudioWrite] = []
    var failedMuteReads: [PrivacyAudioWrite] = []
    var rejectedMuteListener: PrivacyAudioWrite?
    var listenerFailure = false
    var emptyInputConfiguration = false
    var zeroInputBuffers = false
    var beforeSet: (() -> Void)?
    var afterSet: (() -> Void)?
    var removalFailure = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var listenerCount: Int { listeners.count }
    private let lock = NSRecursiveLock()

    private func bundle(_ id: AudioObjectID) -> String { "audio.existential.BlackHole\(id == 1002 ? 2 : 16)ch" }
    private func pluginDevices(_ id: AudioObjectID) -> [AudioDeviceID] {
        snapshot.devices.filter { $0.plugin == bundle(id) }.map(\.id)
    }
    private func get(_ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                     _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>, _ output: UnsafeMutableRawPointer) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        let property = address.pointee
        if property.mSelector == missingSelector { return -1 }
        func number(_ value: UInt32) -> OSStatus {
            output.storeBytes(of: value, as: UInt32.self); size.pointee = 4; return noErr
        }
        func string(_ value: String) -> OSStatus {
            output.assumingMemoryBound(to: CFString?.self).pointee = value as CFString
            size.pointee = UInt32(MemoryLayout<CFString?>.size); return noErr
        }
        func array(_ value: [UInt32]) -> OSStatus {
            guard size.pointee >= value.count * 4 else { return -1 }
            for (index, id) in value.enumerated() { output.storeBytes(of: id, toByteOffset: index * 4, as: UInt32.self) }
            size.pointee = UInt32(value.count * 4); return noErr
        }
        switch property.mSelector {
        case kAudioHardwarePropertyDevices where object == kAudioObjectSystemObject: return array(snapshot.devices.map(\.id))
        case kAudioHardwarePropertyDefaultInputDevice: return number(snapshot.input)
        case kAudioHardwarePropertyDefaultOutputDevice: return number(snapshot.output)
        case kAudioHardwarePropertyDefaultSystemOutputDevice: return number(snapshot.systemOutput)
        case kAudioHardwarePropertyTranslateBundleIDToPlugIn:
            let value = qualifier!.assumingMemoryBound(to: CFString.self).pointee as String
            return number(value == bundle(1002) ? 1002 : value == bundle(1016) ? 1016 : 0)
        case kAudioPlugInPropertyBundleID: return string(wrongPlugin ? "impostor" : bundle(object))
        case kAudioPlugInPropertyDeviceList: return array(pluginDevices(object))
        case kAudioHardwarePropertyTranslateUIDToDevice:
            let value = qualifier!.assumingMemoryBound(to: CFString.self).pointee as String
            return number(wrongResolution ? 999 : snapshot.devices.first(where: { $0.uid == value })?.id ?? 0)
        default: break
        }
        guard let device = snapshot.devices.first(where: { $0.id == object }) else { return -1 }
        switch property.mSelector {
        case kAudioDevicePropertyDeviceUID: return string(device.uid)
        case kAudioDevicePropertyTransportType:
            return number(device.transport == .builtIn ? kAudioDeviceTransportTypeBuiltIn :
                device.transport == .virtual ? kAudioDeviceTransportTypeVirtual : kAudioDeviceTransportTypeUSB)
        case kAudioDevicePropertyDeviceIsAlive: return number(1)
        case kAudioDevicePropertyNominalSampleRate:
            output.storeBytes(of: Float64(48_000), as: Float64.self); size.pointee = 8; return noErr
        case kAudioDevicePropertyMute:
            guard property.mElement == kAudioObjectPropertyElementMain,
                  !failedMuteReads.contains(.mute(object,
                    property.mScope == kAudioObjectPropertyScopeInput ? .input : .output)) else { return -1 }
            guard let value = property.mScope == kAudioObjectPropertyScopeInput ? device.inputMuted : device.outputMuted else { return -1 }
            return number(value ? 1 : 0)
        case kAudioDevicePropertyStreamConfiguration:
            let channels = property.mScope == kAudioObjectPropertyScopeInput ? device.inputChannels : device.outputChannels
            let list = output.assumingMemoryBound(to: AudioBufferList.self)
            list.pointee.mNumberBuffers = zeroInputBuffers && channels == 0 ? 0 : 1
            list.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: 0, mData: nil)
            size.pointee = UInt32(MemoryLayout<AudioBufferList>.size); return noErr
        default: return -1
        }
    }

    var microphoneOperations: HALMicrophoneOperations {
        HALMicrophoneOperations(objectGet: { [self] object, property, _, qualifier, size, output in
            get(object, property, qualifier, size, output)
        }, objectSize: { [self] object, property, size in
            lock.lock(); defer { lock.unlock() }
            switch property.pointee.mSelector {
            case kAudioHardwarePropertyDevices where object == kAudioObjectSystemObject: size.pointee = UInt32(snapshot.devices.count * 4)
            case kAudioPlugInPropertyDeviceList: size.pointee = UInt32(pluginDevices(object).count * 4)
            case kAudioDevicePropertyStreamConfiguration:
                let noInput = snapshot.devices.first(where: { $0.id == object })?.inputChannels == 0
                size.pointee = emptyInputConfiguration && noInput && property.pointee.mScope == kAudioObjectPropertyScopeInput
                    ? 0 : UInt32(MemoryLayout<AudioBufferList>.size)
            default: return -1
            }
            return noErr
        }, create: { FakeOutputUnit() })
    }

    var operations: HostAudioPrivacyOperations {
        HostAudioPrivacyOperations(read: microphoneOperations, settable: { [self] object, property, value in
            let readOnly = property.pointee.mSelector == kAudioDevicePropertyMute &&
                readOnlyMutes.contains(.mute(object,
                    property.pointee.mScope == kAudioObjectPropertyScopeInput ? .input : .output))
            value.pointee = DarwinBoolean(writable && !readOnly); return noErr
        }, set: { [self] object, property, size, input in
            lock.lock(); defer { lock.unlock() }
            beforeSet?()
            guard size == 4 else { return -1 }
            let value = input.load(as: UInt32.self)
            let change: PrivacyAudioWrite
            switch property.pointee.mSelector {
            case kAudioDevicePropertyMute:
                guard value <= 1 else { return -1 }
                change = .mute(object, property.pointee.mScope == kAudioObjectPropertyScopeInput ? .input : .output)
            case kAudioHardwarePropertyDefaultInputDevice: change = .select(.input, value)
            case kAudioHardwarePropertyDefaultOutputDevice: change = .select(.output, value)
            case kAudioHardwarePropertyDefaultSystemOutputDevice: change = .select(.systemOutput, value)
            default: return -1
            }
            writes.append(change)
            if failSetter == writes.count { return -1 }
            if ignoreSetter != writes.count {
                apply(change)
                if case .mute(let id, let scope) = change,
                   let index = snapshot.devices.firstIndex(where: { $0.id == id }) {
                    if scope == .input { snapshot.devices[index].inputMuted = value == 1 }
                    else { snapshot.devices[index].outputMuted = value == 1 }
                }
            }
            afterSet?()
            return noErr
        }, addListener: { [self] object, address, _, callback in
            if listenerFailure { return -1 }
            if address.pointee.mSelector == kAudioDevicePropertyMute,
               rejectedMuteListener == .mute(object,
                address.pointee.mScope == kAudioObjectPropertyScopeInput ? .input : .output) { return -1 }
            listeners.append((object, address.pointee, callback)); return noErr
        }, removeListener: { [self] object, address, _, _ in
            if removalFailure { return -1 }
            listeners.removeAll { $0.0 == object && $0.1.mSelector == address.pointee.mSelector && $0.1.mScope == address.pointee.mScope }
            return noErr
        })
    }

    func apply(_ write: PrivacyAudioWrite) {
        switch write {
        case .mute(let id, let scope):
            if let index = snapshot.devices.firstIndex(where: { $0.id == id }) {
                if scope == .input { snapshot.devices[index].inputMuted = true }
                else { snapshot.devices[index].outputMuted = true }
            }
        case .select(let kind, let id):
            switch kind { case .input: snapshot.input = id; case .output: snapshot.output = id; case .systemOutput: snapshot.systemOutput = id }
        }
    }
    func safe() { for write in (try? snapshot.plan()) ?? [] { apply(write) } }
    func isListening(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope) -> Bool {
        listeners.contains { $0.0 == object && $0.1.mSelector == selector && $0.1.mScope == scope }
    }
    func fire(_ selector: AudioObjectPropertySelector, object: AudioObjectID? = nil) {
        for (id, original, callback) in listeners where original.mSelector == selector && (object == nil || object == id) {
            var property = original
            withUnsafePointer(to: &property) { callback(1, $0) }
        }
    }
}

private final class FakeOutputUnit: HALMicrophoneOutputUnit {
    var inputEnabled = false
    var outputEnabled = false
    var deviceID: AudioDeviceID = 0
    var format: AudioStreamBasicDescription?
    var maximumFrames: UInt32 = 1024
    var provider: AURenderPullInputBlock?
    var isRunning = false
    var resourcesAllocated = false
    func selectDevice(_ id: AudioDeviceID) throws { deviceID = id }
    func setFormat(_ format: AudioStreamBasicDescription) throws { self.format = format }
    func allocate() throws { resourcesAllocated = true }
    func start() throws { isRunning = true }
    func stop() { isRunning = false }
    func deallocate() { resourcesAllocated = false }
}
