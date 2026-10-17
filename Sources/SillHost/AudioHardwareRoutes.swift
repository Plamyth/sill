import Foundation
import CoreAudio
import StreamProtocol

enum AudioRouteDirection { case input, output }
enum AudioRouteWriteIntent { case selection, rollback }

struct AudioRouteInventory: Equatable {
    var endpoints: [AudioRouteEndpoint]
    var defaults: AudioRouteDefaults
}

enum AudioRouteWrite {
    case refused                 // no setter called (CAS, hotplug, or property check failed)
    case attempted(success: Bool) // caller must read back, including on a HAL error
}

protocol AudioRouteHardware {
    func read() throws -> AudioRouteInventory
    func compareAndSet(_ direction: AudioRouteDirection, uid: String,
                       expected: AudioRouteDefaults, intent: AudioRouteWriteIntent) -> AudioRouteWrite
}

/// Owned exclusively by StreamCoordinator's main actor. Observation never writes hardware.
/// All clients share this revision and transaction owner; no selection is saved/replayed on join.
final class AudioHardwareRoutes {
    private let hardware: any AudioRouteHardware
    private var inventory: AudioRouteInventory?
    private var revision = UUID()

    init(hardware: any AudioRouteHardware = CoreAudioRouteHardware()) { self.hardware = hardware }

    func observe() -> AudioRouteState {
        let next = try? hardware.read()
        if next != inventory { inventory = next; revision = UUID() }
        return state()
    }

    private func state(answering: UUID? = nil, result: AudioRouteResult? = nil) -> AudioRouteState {
        AudioRouteState(revision: revision, endpoints: inventory?.endpoints ?? [],
                        defaults: inventory?.defaults ?? AudioRouteDefaults(inputUID: nil, outputUID: nil),
                        available: inventory != nil, answering: answering, result: result)
    }

    func select(_ request: AudioRouteSelection) -> AudioRouteState {
        _ = observe()
        func reply(_ result: AudioRouteResult) -> AudioRouteState {
            state(answering: request.requestID, result: result)
        }
        guard AudioRoutingPolicy.valid(request) else { return reply(.invalid) }
        guard request.revision == revision else { return reply(.stale) }
        guard var working = inventory else { return reply(.unavailable) }
        guard request.expected == working.defaults else { return reply(.conflict) }
        for (uid, direction) in [(request.inputUID, AudioRouteDirection.input), (request.outputUID, .output)] {
            if let uid, !working.endpoints.contains(where: {
                $0.uid == uid && (direction == .input ? $0.input : $0.output)
            }) { return reply(.invalid) }
        }
        // Consume even a no-op: retrying this exact revision can never produce a second effect.
        revision = UUID()
        let original = working.defaults
        let changes: [(AudioRouteDirection, String)] = [(AudioRouteDirection.input, request.inputUID), (.output, request.outputUID)]
            .compactMap { direction, uid in uid.map { (direction, $0) } }
            .filter { direction, uid in Self.uid(original, direction) != uid }
        guard !changes.isEmpty else { return reply(.unchanged) }
        // There is no safe rollback target when the old default could not be identified.
        guard changes.allSatisfy({ Self.uid(original, $0.0) != nil }) else { return reply(.unavailable) }
        var attempted: [(AudioRouteDirection, String)] = []

        func fail(_ result: AudioRouteResult) -> AudioRouteState {
            var restored = true
            for (direction, desired) in attempted.reversed() {
                guard let old = Self.uid(original, direction), let current = try? hardware.read() else {
                    restored = false; continue
                }
                if Self.uid(current.defaults, direction) == old { continue }
                // A different external selection wins. Never roll back somebody else's choice.
                guard Self.uid(current.defaults, direction) == desired else { restored = false; continue }
                let write = hardware.compareAndSet(direction, uid: old, expected: current.defaults, intent: .rollback)
                guard case .attempted = write, let after = try? hardware.read(),
                      Self.uid(after.defaults, direction) == old else { restored = false; continue }
            }
            _ = observe()
            if inventory == nil { restored = false }
            return reply(restored ? result : .rollbackFailed)
        }

        for (direction, desired) in changes {
            guard let before = try? hardware.read() else { return fail(.unavailable) }
            guard before == working else { return fail(.conflict) }
            let write = hardware.compareAndSet(direction, uid: desired, expected: working.defaults, intent: .selection)
            guard case .attempted(let success) = write else { return fail(.conflict) }
            attempted.append((direction, desired))
            guard success else { return fail(.failed) }
            Self.set(&working.defaults, direction, desired)
            guard let after = try? hardware.read() else { return fail(.failed) }
            guard after == working else { return fail(.conflict) }
        }
        inventory = working
        return reply(.applied)
    }

    private static func uid(_ defaults: AudioRouteDefaults, _ direction: AudioRouteDirection) -> String? {
        direction == .input ? defaults.inputUID : defaults.outputUID
    }
    private static func set(_ defaults: inout AudioRouteDefaults, _ direction: AudioRouteDirection, _ uid: String) {
        if direction == .input { defaults.inputUID = uid } else { defaults.outputUID = uid }
    }
}

/// CoreAudio has no atomic compare-and-swap for the two defaults. Recheck both immediately before
/// each setter, then let the owner read back and conditionally restore only values it attempted.
/// The system sounds default is intentionally outside this protocol.
struct CoreAudioRouteHardware: AudioRouteHardware {
    private enum Failure: Error { case unavailable }
    private let system = AudioObjectID(kAudioObjectSystemObject)

    func read() throws -> AudioRouteInventory {
        let ids = try devices()
        let before = try defaults()
        var endpoints: [AudioRouteEndpoint] = []
        var seen = Set<String>()
        for id in ids {
            guard try scalar(id, kAudioDevicePropertyDeviceIsAlive) == 1 else { continue }
            let transport = try scalar(id, kAudioDevicePropertyTransportType)
            guard Self.physical(transport) else { continue }
            let uid = try string(id, kAudioDevicePropertyDeviceUID)
            guard AudioRoutingPolicy.validUID(uid), seen.insert(uid).inserted else { throw Failure.unavailable }
            let input = try canDefault(id, .input)
            let output = try canDefault(id, .output)
            guard input || output else { continue }
            let rawName = try string(id, kAudioObjectPropertyName)
            let name = Self.label(rawName)
            endpoints.append(AudioRouteEndpoint(uid: uid, name: name, input: input, output: output))
            guard endpoints.count <= AudioRoutingPolicy.maxEndpoints else { throw Failure.unavailable }
        }
        // Do not publish a torn catalog/default pair during a system change.
        guard try devices() == ids, try defaults() == before else { throw Failure.unavailable }
        return AudioRouteInventory(endpoints: endpoints.sorted { $0.uid < $1.uid }, defaults: before)
    }

    func compareAndSet(_ direction: AudioRouteDirection, uid: String,
                       expected: AudioRouteDefaults, intent: AudioRouteWriteIntent) -> AudioRouteWrite {
        do {
            guard AudioRoutingPolicy.validUID(uid) else { return .refused }
            // Resolve from current CoreAudio UIDs, never from a client-supplied numeric device ID.
            let matching = try devices().filter { try string($0, kAudioDevicePropertyDeviceUID) == uid }
            guard matching.count == 1, let id = matching.first,
                  try scalar(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                  try canDefault(id, direction) else { return .refused }
            // Selection must remain physical even if the device changed since the catalog read.
            // A rollback may restore the user's original virtual default, never a peer request.
            if intent == .selection, !Self.physical(try scalar(id, kAudioDevicePropertyTransportType)) { return .refused }
            var address = property(direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(system, &address, &settable) == noErr, settable.boolValue,
                  try defaults() == expected else { return .refused }
            var value = id
            return .attempted(success: AudioObjectSetPropertyData(system, &address, 0, nil,
                                    UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr)
        } catch { return .refused }
    }

    private func defaults() throws -> AudioRouteDefaults {
        func uid(_ selector: AudioObjectPropertySelector) throws -> String? {
            let id = try scalar(system, selector)
            guard id != kAudioObjectUnknown else { return nil }
            let value = try string(id, kAudioDevicePropertyDeviceUID)
            guard AudioRoutingPolicy.validUID(value) else { throw Failure.unavailable }
            return value
        }
        return try AudioRouteDefaults(inputUID: uid(kAudioHardwarePropertyDefaultInputDevice),
                                      outputUID: uid(kAudioHardwarePropertyDefaultOutputDevice))
    }

    private func canDefault(_ id: AudioDeviceID, _ direction: AudioRouteDirection) throws -> Bool {
        let scope = direction == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        var address = property(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= offset, size <= 64 * 1024 else { throw Failure.unavailable }
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bytes.deallocate() }
        let capacity = size
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bytes) == noErr,
              size <= capacity, size >= offset else { throw Failure.unavailable }
        let list = bytes.assumingMemoryBound(to: AudioBufferList.self)
        guard Int(list.pointee.mNumberBuffers) <= (Int(size) - offset) / MemoryLayout<AudioBuffer>.stride else {
            throw Failure.unavailable
        }
        guard UnsafeMutableAudioBufferListPointer(list).contains(where: { $0.mNumberChannels > 0 }) else { return false }
        return try scalar(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope) == 1
    }

    private func devices() throws -> [AudioDeviceID] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size <= 4096 * MemoryLayout<AudioDeviceID>.size,
              Int(size) % MemoryLayout<AudioDeviceID>.size == 0 else { throw Failure.unavailable }
        if size == 0 { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let capacity = size
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, size <= capacity, Int(size) % MemoryLayout<AudioDeviceID>.size == 0 else { throw Failure.unavailable }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size)).sorted()
    }

    private func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var address = property(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { throw Failure.unavailable }
        return value
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = property(selector)
        // AudioHardwareBase.h gives the caller ownership for DeviceUID and ObjectName.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { throw Failure.unavailable }
        let owned = value.takeRetainedValue()
        guard size == MemoryLayout<Unmanaged<CFString>?>.size else { throw Failure.unavailable }
        return owned as String
    }

    private func property(_ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func physical(_ transport: UInt32) -> Bool {
        [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeUSB,
         kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
         kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt].contains(transport)
    }

    private static func label(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            guard result.utf8.count + scalar.utf8.count <= AudioRoutingPolicy.maxNameBytes else { break }
            result.unicodeScalars.append(scalar)
        }
        return result.isEmpty ? "Audio device" : result
    }
}
