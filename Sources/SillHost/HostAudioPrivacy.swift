import CoreAudio
import Foundation

struct HostAudioPrivacyOperations {
    var read: HALMicrophoneOperations
    var settable: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
    var set: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UInt32, UnsafeRawPointer) -> OSStatus
    var addListener: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    var removeListener: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus

    static var native: Self {
        Self(read: .native, settable: { AudioObjectIsPropertySettable($0, $1, $2) },
             set: { AudioObjectSetPropertyData($0, $1, 0, nil, $2, $3) },
             addListener: { AudioObjectAddPropertyListenerBlock($0, $1, $2, $3) },
             removeListener: { AudioObjectRemovePropertyListenerBlock($0, $1, $2, $3) })
    }
}

@MainActor
final class CoreAudioPrivacyHAL: HostAudioPrivacyHAL {
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private let ops: HostAudioPrivacyOperations
    private var listeners: [Listener] = []
    private var observationID: UUID?
    private let system = AudioObjectID(kAudioObjectSystemObject)
    init(ops: HostAudioPrivacyOperations) { self.ops = ops }

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private var registry: HALMicrophoneDeviceRegistry { HALMicrophoneDeviceRegistry(ops: ops.read) }
    private func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var value: UInt32 = 0
        try registry.read(object, selector, scope: scope, into: &value)
        return value
    }
    private func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioDeviceID] {
        var property = address(selector), size: UInt32 = 0
        guard ops.read.objectSize(object, &property, &size) == noErr,
              size > 0, size <= 4096, size % 4 == 0 else { throw PrivacyAudioFailure.readback }
        let capacity = size
        var result = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
        let status = result.withUnsafeMutableBytes {
            ops.read.objectGet(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, size == capacity, !result.contains(0), Set(result).count == result.count else {
            throw PrivacyAudioFailure.readback
        }
        return result
    }
    private func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) throws -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        let stride = MemoryLayout<AudioBuffer>.stride
        guard ops.read.objectSize(id, &property, &size) == noErr else { throw PrivacyAudioFailure.readback }
        // HDMI can expose no input stream configuration at all, or a zero-buffer list.
        if size == 0 { return 0 }
        guard Int(size) >= MemoryLayout<UInt32>.size, Int(size) <= offset + 32 * stride else {
            throw PrivacyAudioFailure.readback
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let capacity = size
        guard ops.read.objectGet(id, &property, 0, nil, &size, storage) == noErr,
              size == capacity else { throw PrivacyAudioFailure.readback }
        let count = Int(storage.load(as: UInt32.self))
        if count == 0 { return 0 }
        guard count <= 32, offset + count * stride <= Int(size) else { throw PrivacyAudioFailure.readback }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + min(Int($1.mNumberChannels), 1024) }
    }
    private func canWrite(_ id: AudioObjectID, _ property: inout AudioObjectPropertyAddress) -> Bool {
        var value = DarwinBoolean(false)
        return ops.settable(id, &property, &value) == noErr && value.boolValue
    }
    private func mute(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool? {
        var property = address(kAudioDevicePropertyMute, scope)
        guard canWrite(id, &property), let value = try? scalar(id, kAudioDevicePropertyMute, scope), value <= 1 else { return nil }
        return value == 1
    }

    func read() throws -> PrivacyAudioSnapshot {
        let devices = try ids(system, kAudioHardwarePropertyDevices)
        let defaults = try PrivacyAudioSnapshot(devices: [],
            input: scalar(system, kAudioHardwarePropertyDefaultInputDevice),
            output: scalar(system, kAudioHardwarePropertyDefaultOutputDevice),
            systemOutput: scalar(system, kAudioHardwarePropertyDefaultSystemOutputDevice))
        let plugins = try [2, 16].map { channels in
            ("audio.existential.BlackHole\(channels)ch", try registry.devices(pluginBundleID: "audio.existential.BlackHole\(channels)ch"))
        }
        var result: [PrivacyAudioDevice] = []
        for id in devices {
            guard try scalar(id, kAudioDevicePropertyDeviceIsAlive) == 1 else { continue }
            let transport = try scalar(id, kAudioDevicePropertyTransportType)
            let uid = try registry.string(id, kAudioDevicePropertyDeviceUID)
            guard try registry.resolve(uid) == id else { throw PrivacyAudioFailure.virtualIdentity }
            let input = try channels(id, kAudioObjectPropertyScopeInput)
            let output = try channels(id, kAudioObjectPropertyScopeOutput)
            let owners = plugins.filter { $0.1.contains(id) }
            guard owners.count <= 1 else { throw PrivacyAudioFailure.virtualIdentity }
            if let plugin = owners.first?.0 {
                for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                    try registry.validate(id, uid: uid, scope: scope,
                        channels: plugin == "audio.existential.BlackHole2ch" ? 2 : 16, pluginBundleID: plugin)
                }
            }
            let builtIn = transport == kAudioDeviceTransportTypeBuiltIn
            result.append(PrivacyAudioDevice(id: id, uid: uid,
                transport: builtIn ? .builtIn : transport == kAudioDeviceTransportTypeVirtual ? .virtual : .other,
                plugin: owners.first?.0, inputChannels: input, outputChannels: output,
                inputMuted: input > 0 ? mute(id, kAudioObjectPropertyScopeInput) : nil,
                outputMuted: output > 0 ? mute(id, kAudioObjectPropertyScopeOutput) : nil))
        }
        guard try ids(system, kAudioHardwarePropertyDevices) == devices,
              try scalar(system, kAudioHardwarePropertyDefaultInputDevice) == defaults.input,
              try scalar(system, kAudioHardwarePropertyDefaultOutputDevice) == defaults.output,
              try scalar(system, kAudioHardwarePropertyDefaultSystemOutputDevice) == defaults.systemOutput else {
            throw PrivacyAudioFailure.readback
        }
        return PrivacyAudioSnapshot(devices: result, input: defaults.input, output: defaults.output, systemOutput: defaults.systemOutput)
    }

    func write(_ change: PrivacyAudioWrite) -> Bool {
        // The injected boundary validates the current identity again, even for a stale command.
        guard let snapshot = try? read(), (try? snapshot.plan().contains(change)) == true else { return false }
        let object: AudioObjectID
        var property: AudioObjectPropertyAddress
        var value: UInt32
        switch change {
        case .mute(let id, let scope):
            object = id; property = address(kAudioDevicePropertyMute,
                scope == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
            value = 1
        case .select(let kind, let id):
            object = system; value = id
            property = address(kind == .input ? kAudioHardwarePropertyDefaultInputDevice :
                kind == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
        guard canWrite(object, &property) else { return false }
        return ops.set(object, &property, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    func restoreLocal(_ original: LocalAudioState) -> Bool {
        guard original.version == 1, Set(original.devices.map(\.uid)).count == original.devices.count,
              var snapshot = try? read() else { return false }
        var changes: [(AudioObjectID, AudioObjectPropertyAddress, UInt32)] = []
        for saved in original.devices {
            guard let device = snapshot.devices.first(where: { $0.uid == saved.uid }),
                  device.inputChannels == saved.inputChannels, device.outputChannels == saved.outputChannels else { return false }
            for (scope, value, current) in [(kAudioObjectPropertyScopeInput, saved.inputMuted, device.inputMuted),
                                            (kAudioObjectPropertyScopeOutput, saved.outputMuted, device.outputMuted)] {
                guard let value else { continue }
                guard current != nil else { return false }
                changes.append((device.id, address(kAudioDevicePropertyMute, scope), value ? 1 : 0))
            }
        }
        for (selector, uid, input) in [(kAudioHardwarePropertyDefaultInputDevice, original.inputUID, true),
                                       (kAudioHardwarePropertyDefaultOutputDevice, original.outputUID, false),
                                       (kAudioHardwarePropertyDefaultSystemOutputDevice, original.systemOutputUID, false)] {
            guard let device = snapshot.devices.first(where: { $0.uid == uid }),
                  (input ? device.inputChannels : device.outputChannels) > 0 else { return false }
            changes.append((system, address(selector), device.id))
        }
        for (object, originalProperty, _) in changes {
            var property = originalProperty
            guard canWrite(object, &property) else { return false }
        }
        for (object, originalProperty, originalValue) in changes {
            guard let before = try? read(), before == snapshot else { return false }
            var property = originalProperty, value = originalValue
            guard canWrite(object, &property), ops.set(object, &property, 4, &value) == noErr,
                  let after = try? read() else { return false }
            snapshot = after
        }
        return original.matches(snapshot)
    }

    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool {
        observationID = nil
        var retained: [Listener] = []
        for var listener in listeners {
            if ops.removeListener(listener.object, &listener.address, .main, listener.block) != noErr { retained.append(listener) }
        }
        listeners = retained
        guard retained.isEmpty else { return false }
        guard let changed else { return true }
        let observationID = UUID()
        self.observationID = observationID
        var properties = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
            .map { (system, address($0)) }
        for device in snapshot?.devices ?? [] {
            properties += [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceUID,
                kAudioDevicePropertyTransportType, kAudioDevicePropertyNominalSampleRate]
                .map { (device.id, address($0)) }
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                properties.append((device.id, address(kAudioDevicePropertyStreamConfiguration, scope)))
                if (scope == kAudioObjectPropertyScopeInput ? device.inputMuted : device.outputMuted) != nil,
                   (scope == kAudioObjectPropertyScopeInput ? device.inputChannels : device.outputChannels) > 0 {
                    properties.append((device.id, address(kAudioDevicePropertyMute, scope)))
                }
            }
        }
        for channels in [2, 16] {
            var property = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
            var bundle = "audio.existential.BlackHole\(channels)ch" as CFString
            var plugin = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = withUnsafePointer(to: &bundle) {
                ops.read.objectGet(system, &property, UInt32(MemoryLayout<CFString>.size), $0, &size, &plugin)
            }
            // System listeners remain installed when a required plugin is absent at startup.
            if status == noErr, size == MemoryLayout<AudioObjectID>.size, plugin != kAudioObjectUnknown {
                properties.append((plugin, address(kAudioPlugInPropertyDeviceList)))
                properties.append((plugin, address(kAudioPlugInPropertyBundleID)))
            }
        }
        for (object, originalProperty) in properties {
            var property = originalProperty
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard self?.observationID == observationID else { return }
                    changed()
                }
            }
            guard ops.addListener(object, &property, .main, block) == noErr else { return false }
            listeners.append(Listener(object: object, address: property, block: block))
        }
        return true
    }
}

extension HostAudioPrivacy {
    /// Only the branded production AppModel opts in. Legacy CLI and synthetic callers stay inert.
    package convenience init(defaults: UserDefaults) {
        let key = "CCRHostAudioPrivacyLatched.v1"
        let originalKey = "CCRHostAudioOriginalLocalState.v1"
        let original = defaults.data(forKey: originalKey).flatMap { try? JSONDecoder().decode(LocalAudioState.self, from: $0) }
        let authentication = LocalAudioAuthentication()
        self.init(hal: CoreAudioPrivacyHAL(ops: .native), latched: defaults.bool(forKey: key), persist: {
            defaults.set(true, forKey: key)
            return defaults.synchronize() && defaults.bool(forKey: key)
        }, localState: original, saveLocal: { state in
            if let state {
                guard let data = try? JSONEncoder().encode(state) else { return false }
                defaults.set(data, forKey: originalKey)
                return defaults.synchronize() && defaults.data(forKey: originalKey) == data
            }
            defaults.removeObject(forKey: originalKey)
            return defaults.synchronize() && defaults.object(forKey: originalKey) == nil
        }, clearLatch: {
            defaults.set(false, forKey: key)
            return defaults.synchronize() && !defaults.bool(forKey: key)
        }, authenticateLocal: { await authentication.evaluate() }, cancelAuthentication: { authentication.cancel() })
    }
}
