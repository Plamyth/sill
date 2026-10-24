import Foundation

struct LegacyLocalAudioState: Codable, Equatable {
    struct Device: Codable, Equatable {
        let uid: String
        let transport: PrivacyAudioDevice.Transport
        let plugin: String?
        let inputChannels: Int
        let outputChannels: Int
        let inputMuted: Bool?
        let outputMuted: Bool?
    }
    let version: Int
    let inputUID: String
    let outputUID: String
    let systemOutputUID: String
    let devices: [Device]

    init(_ snapshot: PrivacyAudioSnapshot) throws {
        func uid(_ id: UInt32) throws -> String {
            guard let device = snapshot.devices.first(where: { $0.id == id }) else { throw PrivacyAudioFailure.readback }
            return device.uid
        }
        version = 2
        inputUID = try uid(snapshot.input)
        outputUID = try uid(snapshot.output)
        systemOutputUID = try uid(snapshot.systemOutput)
        devices = snapshot.devices.map { Device(uid: $0.uid, transport: $0.transport, plugin: $0.plugin, inputChannels: $0.inputChannels,
            outputChannels: $0.outputChannels, inputMuted: $0.inputMuted, outputMuted: $0.outputMuted) }
    }

    var isValid: Bool {
        version == 2 && !devices.isEmpty && Set(devices.map(\.uid)).count == devices.count &&
        devices.allSatisfy { !$0.uid.isEmpty && $0.inputChannels >= 0 && $0.outputChannels >= 0 &&
            ($0.inputMuted == nil || $0.inputChannels > 0) && ($0.outputMuted == nil || $0.outputChannels > 0) } &&
        devices.contains { $0.uid == inputUID && $0.inputChannels > 0 } &&
        devices.contains { $0.uid == outputUID && $0.outputChannels > 0 } &&
        devices.contains { $0.uid == systemOutputUID && $0.outputChannels > 0 }
    }

    func matches(_ snapshot: PrivacyAudioSnapshot) -> Bool {
        guard isValid, let current = try? LegacyLocalAudioState(snapshot) else { return false }
        return current.inputUID == inputUID && current.outputUID == outputUID && current.systemOutputUID == systemOutputUID &&
            current.devices.count == devices.count && devices.allSatisfy { saved in current.devices.contains(saved) }
    }
}

@MainActor
final class LegacyLocalAudioJournal {
    struct Envelope: Codable {
        let version: Int
        let latched: Bool
        let original: LegacyLocalAudioState?
    }
    static let key = "CCRHostAudioPrivacyJournal.v2"
    private let store: (Data) -> Void
    private let load: () -> Data?
    private let synchronize: () -> Bool
    private(set) var latched: Bool
    private(set) var original: LegacyLocalAudioState?

    init(data: Data?, legacyLatched: Bool = false, legacyOriginal: LegacyLocalAudioState? = nil,
         store: @escaping (Data) -> Void, load: @escaping () -> Data?, synchronize: @escaping () -> Bool) {
        self.store = store; self.load = load; self.synchronize = synchronize
        if let data {
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 2,
               (!envelope.latched || envelope.original?.isValid == true) {
                latched = envelope.latched
                original = envelope.latched ? envelope.original : nil
            } else {
                latched = true; original = nil
            }
        } else {
            latched = legacyLatched
            original = legacyLatched && legacyOriginal?.isValid == true ? legacyOriginal : nil
        }
    }

    convenience init(defaults: UserDefaults) {
        let original = defaults.data(forKey: "CCRHostAudioOriginalLocalState.v1")
            .flatMap { try? JSONDecoder().decode(LegacyLocalAudioState.self, from: $0) }
        self.init(data: defaults.data(forKey: Self.key),
            legacyLatched: defaults.bool(forKey: "CCRHostAudioPrivacyLatched.v1"), legacyOriginal: original,
            store: { defaults.set($0, forKey: Self.key) }, load: { defaults.data(forKey: Self.key) },
            synchronize: { defaults.synchronize() })
    }

    func write(latched: Bool, original: LegacyLocalAudioState?) -> Bool {
        guard !latched || original?.isValid == true else { return false }
        guard let data = try? JSONEncoder().encode(Envelope(version: 2, latched: latched, original: original)) else { return false }
        store(data)
        guard synchronize(), load() == data else { return false }
        self.latched = latched
        self.original = original
        return true
    }
}
