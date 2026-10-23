import CoreAudio
import Foundation

/// Output tap readback is a candidate, never evidence of input, mixer, or crash-persistent protection.
@MainActor
final class HostProcessOutputSilence {
    struct Format: Equatable {
        let sampleRate: Double
        let formatID: UInt32
        let flags: UInt32
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let bytesPerFrame: UInt32
        let channels: UInt32
        let bitsPerChannel: UInt32
        let reserved: UInt32

        init(_ value: AudioStreamBasicDescription) {
            sampleRate = value.mSampleRate; formatID = value.mFormatID; flags = value.mFormatFlags
            bytesPerPacket = value.mBytesPerPacket; framesPerPacket = value.mFramesPerPacket
            bytesPerFrame = value.mBytesPerFrame; channels = value.mChannelsPerFrame
            bitsPerChannel = value.mBitsPerChannel; reserved = value.mReserved
        }
        var valid: Bool {
            sampleRate.isFinite && (8_000...384_000).contains(sampleRate) && formatID == kAudioFormatLinearPCM &&
            flags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger) != 0 &&
            (1...1024).contains(channels) && (1...64).contains(bitsPerChannel) && framesPerPacket == 1 &&
            bytesPerFrame >= ((bitsPerChannel + 7) / 8) * (flags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : channels) &&
            bytesPerPacket == bytesPerFrame && reserved == 0
        }
    }
    struct Stream: Equatable {
        let id: UInt32
        let index: UInt
        let startingChannel: UInt32
        let virtualFormat: Format
        let physicalFormat: Format
    }
    struct Device: Equatable {
        let id: UInt32
        let uid: String
        let transport: UInt32
        let outputChannels: Int
        let sampleRate: Double
        let streams: [Stream]
    }
    struct Tap: Equatable {
        let id: UInt32
        let uuid: UUID
        let deviceUID: String?
        let streamIndex: UInt?
        let excludedProcesses: [UInt32]
        let isExclusive: Bool
        let isPrivate: Bool
        let isMixdown: Bool
        let isMono: Bool
        let muteBehavior: Int
        let format: Format
    }
    enum Identity: Equatable { case missing, tap(UUID), foreign, unreadable }
    struct Operations {
        var read: () -> Device?
        var create: (String, Stream, UUID) -> (status: OSStatus, id: UInt32)
        var identify: (UInt32) -> Identity
        var readTap: (UInt32) -> Tap?
        var destroy: (UInt32) -> OSStatus
    }
    struct Evidence {
        let device: Device
        let taps: [Tap]
        var permitsRemoteAudio: Bool { false }
        var inputProtectionAttested: Bool { false }
        var analogMixerProtectionAttested: Bool { false }
        var survivesProcessDeathAttested: Bool { false }
    }
    private struct Owned {
        let id: UInt32
        let uuid: UUID
        let stream: Stream
    }
    private let uid: String
    private let ops: Operations
    private var original: Device?
    private var owned: [Owned] = []
    private var active = false
    private(set) var failure: String?
    var hasOwnedResources: Bool { !owned.isEmpty }

    init(uid: String, ops: Operations) { self.uid = uid; self.ops = ops }

    func startCandidate() -> Bool {
        guard original == nil, owned.isEmpty else { return false }
        failure = nil
        guard let before = ops.read(), valid(before) else {
            failure = "물리 출력 장치의 식별자·전체 스트림·형식을 확인하지 못했습니다."; return false
        }
        original = before
        for stream in before.streams {
            guard ops.read() == before else { return abort("출력 장치 구성이 바뀌었습니다.") }
            let uuid = UUID()
            let created = ops.create(uid, stream, uuid)
            guard created.id != kAudioObjectUnknown, !owned.contains(where: { $0.id == created.id }) else {
                return abort("출력 tap 식별자가 없거나 중복되었습니다.")
            }
            owned.append(Owned(id: created.id, uuid: uuid, stream: stream))
            guard created.status == noErr, verified(owned.last!) != nil else {
                return abort("출력 tap 생성과 소유권·설정 readback을 확인하지 못했습니다.")
            }
        }
        guard snapshot() != nil else { return abort("전체 출력 tap과 장치 구성이 일치하지 않습니다.") }
        active = true
        return true
    }

    func inspectCandidate() -> Evidence? { active ? snapshot() : nil }

    /// The parent must fence and drain native/relay participants before releasing this candidate.
    @discardableResult
    func retireAfterAuthenticatedReturn() -> Bool {
        active = false
        for tap in owned.reversed() {
            let identity = ops.identify(tap.id)
            if identity != .missing {
                guard identity == .tap(tap.uuid) else {
                    failure = "tap 소유권이 바뀌었거나 확인되지 않아 임의 해제하지 않았습니다."; continue
                }
                _ = ops.destroy(tap.id)
                guard ops.identify(tap.id) == .missing else {
                    failure = "소유한 출력 tap의 제거를 readback하지 못했습니다."; continue
                }
            }
            owned.removeAll { $0.id == tap.id && $0.uuid == tap.uuid }
        }
        if owned.isEmpty { original = nil }
        return owned.isEmpty
    }

    private func abort(_ message: String) -> Bool {
        failure = message
        _ = retireAfterAuthenticatedReturn()
        return false
    }
    private func valid(_ device: Device) -> Bool {
        let physical: Set<UInt32> = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeAVB, kAudioDeviceTransportTypeThunderbolt]
        guard device.id != 0, device.uid == uid, !uid.isEmpty, uid.utf8.count <= 1024,
              physical.contains(device.transport), (1...1024).contains(device.outputChannels),
              (1...128).contains(device.streams.count), Set(device.streams.map(\.id)).count == device.streams.count,
              device.sampleRate.isFinite, (8_000...384_000).contains(device.sampleRate) else { return false }
        var channel: UInt32 = 1
        for (index, stream) in device.streams.enumerated() {
            guard stream.id != 0, stream.index == UInt(index), stream.startingChannel == channel,
                  stream.virtualFormat.valid, stream.physicalFormat.valid,
                  stream.virtualFormat.sampleRate == device.sampleRate, stream.physicalFormat.sampleRate == device.sampleRate,
                  stream.physicalFormat.channels == stream.virtualFormat.channels else { return false }
            channel += stream.virtualFormat.channels
        }
        return Int(channel - 1) == device.outputChannels
    }
    private func verified(_ value: Owned) -> Tap? {
        guard ops.identify(value.id) == .tap(value.uuid), let tap = ops.readTap(value.id),
              tap.id == value.id, tap.uuid == value.uuid, tap.deviceUID == uid,
              tap.streamIndex == value.stream.index, tap.excludedProcesses.isEmpty,
              tap.isExclusive, tap.isPrivate, !tap.isMixdown, !tap.isMono,
              tap.muteBehavior == CATapMuteBehavior.muted.rawValue,
              tap.format == value.stream.virtualFormat, ops.identify(value.id) == .tap(value.uuid) else { return nil }
        return tap
    }
    private func snapshot() -> Evidence? {
        guard let original, owned.count == original.streams.count, ops.read() == original else { return nil }
        let taps = owned.compactMap(verified)
        guard taps.count == owned.count, ops.read() == original else { return nil }
        return Evidence(device: original, taps: taps)
    }
}

extension HostProcessOutputSilence.Operations {
    @available(macOS 14.2, *)
    static func description(uid: String, stream: UInt, uuid: UUID) -> CATapDescription {
        let value = CATapDescription(excludingProcesses: [], deviceUID: uid, stream: stream)
        value.uuid = uuid
        value.name = "CCR 물리 출력 보호 후보"
        value.isPrivate = true; value.isExclusive = true; value.isMixdown = false; value.isMono = false
        value.muteBehavior = .muted
        return value
    }

    @available(macOS 14.2, *)
    static func native(uid: String) -> Self {
        func address(_ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
            .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }
        func read<T>(_ id: UInt32, _ selector: UInt32, into value: inout T) -> OSStatus {
            var property = address(selector), size = UInt32(MemoryLayout<T>.size)
            let status = withUnsafeMutableBytes(of: &value) {
                AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!)
            }
            return status == noErr && size != MemoryLayout<T>.size ? kAudioHardwareBadPropertySizeError : status
        }
        func string(_ id: UInt32, _ selector: UInt32) -> String? {
            var value: Unmanaged<CFString>?
            let status = read(id, selector, into: &value)
            guard let value else { return nil }
            let result = value.takeRetainedValue()
            return status == noErr ? result as String : nil
        }
        func device() -> HostProcessOutputSilence.Device? {
            var property = address(kAudioHardwarePropertyTranslateUIDToDevice), qualifier = uid as CFString
            var id: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            let status = withUnsafePointer(to: &qualifier) {
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                    UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
            }
            guard status == noErr, size == 4, id != 0, string(id, kAudioDevicePropertyDeviceUID) == uid else { return nil }
            var transport: UInt32 = 0, alive: UInt32 = 0, rate: Double = 0
            guard read(id, kAudioDevicePropertyTransportType, into: &transport) == noErr,
                  read(id, kAudioDevicePropertyDeviceIsAlive, into: &alive) == noErr, alive == 1,
                  read(id, kAudioDevicePropertyNominalSampleRate, into: &rate) == noErr else { return nil }
            property = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput); size = 0
            guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
                  size > 0, size <= 128 * 4, size % 4 == 0 else { return nil }
            let capacity = size
            var streamIDs = [UInt32](repeating: 0, count: Int(size) / 4)
            let streamStatus = streamIDs.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!)
            }
            guard streamStatus == noErr, size == capacity else { return nil }
            var streams: [HostProcessOutputSilence.Stream] = []
            for (index, streamID) in streamIDs.enumerated() {
                var owner: UInt32 = 0, direction: UInt32 = 1, first: UInt32 = 0, kind: UInt32 = 0
                var virtual = AudioStreamBasicDescription(), physical = AudioStreamBasicDescription()
                guard read(streamID, kAudioObjectPropertyOwner, into: &owner) == noErr, owner == id,
                      read(streamID, kAudioObjectPropertyClass, into: &kind) == noErr, kind == kAudioStreamClassID,
                      read(streamID, kAudioStreamPropertyDirection, into: &direction) == noErr, direction == 0,
                      read(streamID, kAudioStreamPropertyStartingChannel, into: &first) == noErr,
                      read(streamID, kAudioStreamPropertyVirtualFormat, into: &virtual) == noErr,
                      read(streamID, kAudioStreamPropertyPhysicalFormat, into: &physical) == noErr else { return nil }
                streams.append(.init(id: streamID, index: UInt(index), startingChannel: first,
                    virtualFormat: .init(virtual), physicalFormat: .init(physical)))
            }
            property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput); size = 0
            let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!, stride = MemoryLayout<AudioBuffer>.stride
            guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
                  Int(size) >= offset, Int(size) <= offset + 128 * stride else { return nil }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            let bufferCapacity = size
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, storage) == noErr, size == bufferCapacity else { return nil }
            let count = Int(storage.load(as: UInt32.self))
            guard count > 0, count <= 128, offset + count * stride <= Int(size) else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            guard buffers.allSatisfy({ $0.mNumberChannels <= 1024 }) else { return nil }
            return .init(id: id, uid: uid, transport: transport,
                outputChannels: buffers.reduce(0) { $0 + Int($1.mNumberChannels) }, sampleRate: rate, streams: streams)
        }
        func identify(_ id: UInt32) -> HostProcessOutputSilence.Identity {
            var kind: UInt32 = 0
            let status = read(id, kAudioObjectPropertyClass, into: &kind)
            if status == kAudioHardwareBadObjectError { return .missing }
            guard status == noErr else { return .unreadable }
            guard kind == kAudioTapClassID else { return .foreign }
            guard let raw = string(id, kAudioTapPropertyUID), let uuid = UUID(uuidString: raw) else { return .unreadable }
            return .tap(uuid)
        }
        return Self(read: device, create: { uid, stream, uuid in
            let value = description(uid: uid, stream: stream.index, uuid: uuid)
            var id: UInt32 = 0
            let status = AudioHardwareCreateProcessTap(value, &id)
            return (status, id)
        }, identify: identify, readTap: { id in
            guard case .tap(let uuid) = identify(id) else { return nil }
            var object: Unmanaged<CATapDescription>?
            let status = read(id, kAudioTapPropertyDescription, into: &object)
            guard let object else { return nil }
            let value = object.takeRetainedValue()
            var format = AudioStreamBasicDescription()
            guard status == noErr, value.uuid == uuid, read(id, kAudioTapPropertyFormat, into: &format) == noErr else { return nil }
            return .init(id: id, uuid: uuid, deviceUID: value.deviceUID, streamIndex: value.stream,
                excludedProcesses: value.processes, isExclusive: value.isExclusive, isPrivate: value.isPrivate,
                isMixdown: value.isMixdown, isMono: value.isMono, muteBehavior: value.muteBehavior.rawValue, format: .init(format))
        }, destroy: { AudioHardwareDestroyProcessTap($0) })
    }
}
