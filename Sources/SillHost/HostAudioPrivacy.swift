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
    private func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     allowEmpty: Bool = false) throws -> [AudioDeviceID] {
        var property = address(selector, scope), size: UInt32 = 0
        guard ops.read.objectSize(object, &property, &size) == noErr,
              size <= 4096, size % 4 == 0 else { throw PrivacyAudioFailure.readback }
        if size == 0 {
            guard allowEmpty else { throw PrivacyAudioFailure.readback }
            return []
        }
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
        var total = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard buffer.mNumberChannels <= 1024 else { throw PrivacyAudioFailure.readback }
            total += Int(buffer.mNumberChannels)
        }
        guard total <= 1024 else { throw PrivacyAudioFailure.readback }
        return total
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

    private func format(_ stream: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> PrivacyAudioStream.Format {
        var value = AudioStreamBasicDescription()
        try registry.read(stream, selector, into: &value)
        return .init(sampleRate: value.mSampleRate, formatID: value.mFormatID, flags: value.mFormatFlags,
            bytesPerPacket: value.mBytesPerPacket, framesPerPacket: value.mFramesPerPacket,
            bytesPerFrame: value.mBytesPerFrame, channels: value.mChannelsPerFrame,
            bitsPerChannel: value.mBitsPerChannel, reserved: value.mReserved)
    }

    private func streams(_ device: AudioDeviceID) throws -> [PrivacyAudioStream] {
        guard try scalar(device, kAudioObjectPropertyClass) == kAudioDeviceClassID else { throw PrivacyAudioFailure.readback }
        var result: [PrivacyAudioStream] = []
        for (scope, direction) in [(kAudioObjectPropertyScopeInput, PrivacyAudioScope.input), (kAudioObjectPropertyScopeOutput, .output)] {
            let streamIDs = try ids(device, kAudioDevicePropertyStreams, scope, allowEmpty: true)
            for id in streamIDs {
                guard try scalar(id, kAudioObjectPropertyClass) == kAudioStreamClassID,
                      try scalar(id, kAudioObjectPropertyOwner) == device,
                      try scalar(id, kAudioStreamPropertyDirection) == (direction == .input ? 1 : 0) else {
                    throw PrivacyAudioFailure.readback
                }
                var activeProperty = address(kAudioStreamPropertyIsActive)
                result.append(try PrivacyAudioStream(id: id, ownerID: device, direction: direction,
                    startingChannel: scalar(id, kAudioStreamPropertyStartingChannel),
                    virtualFormat: format(id, kAudioStreamPropertyVirtualFormat),
                    physicalFormat: format(id, kAudioStreamPropertyPhysicalFormat),
                    active: scalar(id, kAudioStreamPropertyIsActive) != 0,
                    activeSettable: canWrite(id, &activeProperty)))
            }
            guard try ids(device, kAudioDevicePropertyStreams, scope, allowEmpty: true) == streamIDs else {
                throw PrivacyAudioFailure.readback
            }
        }
        return result.sorted { $0.id < $1.id }
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
            let physicalTransports = [kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeUSB,
                kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAVB,
                kAudioDeviceTransportTypeThunderbolt]
            let inputMuted = input > 0 ? mute(id, kAudioObjectPropertyScopeInput) : nil
            let outputMuted = output > 0 ? mute(id, kAudioObjectPropertyScopeOutput) : nil
            let streamState = (input > 0 && inputMuted == nil) || (output > 0 && outputMuted == nil)
                ? try? streams(id) : nil
            result.append(PrivacyAudioDevice(id: id, uid: uid,
                transport: builtIn ? .builtIn : transport == kAudioDeviceTransportTypeVirtual ? .virtual :
                    transport == kAudioDeviceTransportTypeAggregate ? .aggregate : physicalTransports.contains(transport) ? .other : .unknown,
                plugin: owners.first?.0, inputChannels: input, outputChannels: output,
                inputMuted: inputMuted, outputMuted: outputMuted, streams: streamState))
            guard try registry.string(id, kAudioDevicePropertyDeviceUID) == uid,
                  try registry.resolve(uid) == id,
                  try scalar(id, kAudioDevicePropertyTransportType) == transport,
                  try channels(id, kAudioObjectPropertyScopeInput) == input,
                  try channels(id, kAudioObjectPropertyScopeOutput) == output,
                  streamState == nil || (try? streams(id)) == streamState else { throw PrivacyAudioFailure.readback }
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
        guard let snapshot = try? read(), let expected = snapshot.applying(change) else { return false }
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
        case .deactivateStream(let uid, let stream, _):
            guard (try? snapshot.plan().contains(change)) == true,
                  (try? registry.resolve(uid)) == stream.ownerID else { return false }
            object = stream.id; property = address(kAudioStreamPropertyIsActive); value = 0
        }
        guard canWrite(object, &property), (try? read()) == snapshot else { return false }
        return ops.set(object, &property, UInt32(MemoryLayout<UInt32>.size), &value) == noErr && (try? read()) == expected
    }

    func restoreLocal(_ original: LocalAudioState) -> Bool {
        var phase = "초기 원본·HAL 읽기"
        var restored = false
        defer { print("[로컬 HAL 복원] completed=\(restored) phase=\(phase)") }
        guard original.isValid, var snapshot = try? read() else { return false }
        if original.matches(snapshot) { restored = true; return true }
        phase = "보호 상태·장치 집합"
        guard (try? snapshot.plan(allowPartial: true).isEmpty) == true,
              Set(snapshot.devices.map(\.uid)) == Set(original.devices.map(\.uid)) else { return false }
        var changes: [(uid: String, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                       value: UInt32?, streamID: UInt32?)] = []
        for saved in original.devices {
            phase = "장치 불변 식별"
            guard let device = snapshot.devices.first(where: { $0.uid == saved.uid }),
                  saved.matches(LocalAudioState.Device(device), includeActive: false) else { return false }
            for (scope, value, current) in [(kAudioObjectPropertyScopeInput, saved.inputMuted, device.inputMuted),
                                            (kAudioObjectPropertyScopeOutput, saved.outputMuted, device.outputMuted)] {
                guard let value else { continue }
                guard current != nil else { return false }
                changes.append((saved.uid, kAudioDevicePropertyMute, scope, value ? 1 : 0, nil))
            }
            for stream in saved.streams ?? [] {
                changes.append((saved.uid, kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal,
                                stream.active ? 1 : 0, stream.id))
            }
        }
        changes += [(original.inputUID, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, nil, nil),
                    (original.outputUID, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, nil, nil),
                    (original.systemOutputUID, kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, nil, nil)]
        for (index, item) in changes.enumerated() {
            let (uid, selector, scope, muteValue, streamID) = item
            phase = "단계 \(index) 원본 재조회"
            guard let before = try? read(), before == snapshot,
                  let index = before.devices.firstIndex(where: { $0.uid == uid }),
                  let resolved = try? registry.resolve(uid), resolved == before.devices[index].id else { return false }
            var expected = before
            let object: AudioObjectID
            var value: UInt32
            if let streamID, let muteValue {
                guard let streamIndex = before.devices[index].streams?.firstIndex(where: { $0.id == streamID }) else { return false }
                object = streamID; value = muteValue
                expected.devices[index].streams?[streamIndex].active = value == 1
            } else if let muteValue {
                object = resolved; value = muteValue
                if scope == kAudioObjectPropertyScopeInput { expected.devices[index].inputMuted = value == 1 }
                else { expected.devices[index].outputMuted = value == 1 }
            } else {
                object = system; value = resolved
                switch selector {
                case kAudioHardwarePropertyDefaultInputDevice: expected.input = resolved
                case kAudioHardwarePropertyDefaultOutputDevice: expected.output = resolved
                default: expected.systemOutput = resolved
                }
            }
            phase = "단계 \(index) 쓰기 가능·현재 식별 재검증"
            var property = address(selector, scope)
            guard canWrite(object, &property),
                  let final = try? read(), final == before,
                  (try? registry.resolve(uid)) == resolved else { return false }
            if expected == before { continue }
            phase = "단계 \(index) setter"
            let status = ops.set(object, &property, 4, &value)
            if status != noErr { print("[로컬 HAL 복원] setter 거부 selector=\(selector) status=\(status)") }
            guard status == noErr else { return false }
            phase = "단계 \(index) setter 후 재조회"
            guard let after = try? read() else { return false }
            guard after == expected else {
                print("[로컬 HAL 복원] setter 재조회 불일치 selector=\(selector) inputMatches=\(after.input == expected.input) outputMatches=\(after.output == expected.output) systemOutputMatches=\(after.systemOutput == expected.systemOutput) devicesMatch=\(after.devices == expected.devices)")
                return false
            }
            snapshot = expected
        }
        phase = "최종 원본 일치"
        restored = original.matches(snapshot)
        return restored
    }

    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool {
        observationID = nil
        var retained: [Listener] = []
        for var listener in listeners {
            let status = ops.removeListener(listener.object, &listener.address, .main, listener.block)
            if status != noErr {
                print("[로컬 HAL 감시] listener 제거 거부 selector=\(listener.address.mSelector) status=\(status)")
                retained.append(listener)
            }
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
                properties.append((device.id, address(kAudioDevicePropertyStreams, scope)))
                if (scope == kAudioObjectPropertyScopeInput ? device.inputMuted : device.outputMuted) != nil,
                   (scope == kAudioObjectPropertyScopeInput ? device.inputChannels : device.outputChannels) > 0 {
                    properties.append((device.id, address(kAudioDevicePropertyMute, scope)))
                }
            }
            for stream in device.streams ?? [] {
                properties += [kAudioObjectPropertyClass, kAudioObjectPropertyOwner, kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
                    kAudioStreamPropertyStartingChannel, kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat]
                    .map { (stream.id, address($0)) }
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
    package convenience init(defaults: UserDefaults, nativeStartup: NativeAudioStartup) {
        let journal = LocalAudioJournal(defaults: defaults)
        let authentication = LocalAudioAuthentication()
        self.init(hal: CoreAudioPrivacyHAL(ops: .native), latched: journal.latched,
            persist: { journal.write(latched: true, original: journal.original) },
            localState: journal.original, saveLocal: { original in
                journal.write(latched: original != nil, original: original)
            }, clearLatch: { journal.write(latched: false, original: nil) },
            authenticateLocal: { attempt in await authentication.evaluate(operationId: attempt) }, cancelAuthentication: { authentication.cancel() },
            authenticationChallengeID: { authentication.activeChallengeID },
            nativeStartup: nativeStartup)
    }
}
