import Foundation

struct AudioForwardingDeviceID: Codable, Hashable, Sendable {
    let hex: String

    init?(hex: String) {
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.hex = hex
    }

    init?(fingerprint: Data) {
        guard fingerprint.count == 32 else { return nil }
        hex = fingerprint.map { String(format: "%02x", $0) }.joined()
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AudioForwardingFailure.invalidIdentity
        }
        hex = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

struct AudioForwardingRevision: Codable, Equatable, Sendable {
    let value: UInt64
    init(_ value: UInt64) { self.value = value }
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = UInt64(text), String(value) == text else { throw AudioForwardingFailure.invalidRevision }
        self.value = value
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }
}

enum AudioForwardingFailure: Error {
    case invalidIdentity, invalidRevision, invalidIntent, invalidMembership, invalidBinding, unexpectedFields
}

enum AudioForwardingTransport: String, Codable, Sendable { case http, native }

private struct ForwardingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func exact<K: CodingKey & CaseIterable>(_ decoder: Decoder, _ type: K.Type) throws -> KeyedDecodingContainer<K> {
    let keys = try decoder.container(keyedBy: ForwardingKey.self).allKeys.map(\.stringValue)
    guard Set(keys) == Set(K.allCases.map(\.stringValue)) else { throw AudioForwardingFailure.unexpectedFields }
    return try decoder.container(keyedBy: type)
}

struct AudioForwardingIntentRequest: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case request, resume, update, stop }
    let schemaVersion: Int
    let pairedDeviceId: AudioForwardingDeviceID
    let intentId: UUID
    let intentRevision: AudioForwardingRevision
    let action: Action
    let inputDesired: Bool
    let outputDesired: Bool
    let expectedRevision: AudioForwardingRevision
    let transportId: UUID
    let transportKind: AudioForwardingTransport
    let bindingRevision: AudioForwardingRevision

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, pairedDeviceId, intentId, intentRevision, action, inputDesired,
             outputDesired, expectedRevision, transportId, transportKind, bindingRevision
    }

    init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        pairedDeviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .pairedDeviceId)
        intentId = try c.decode(UUID.self, forKey: .intentId)
        intentRevision = try c.decode(AudioForwardingRevision.self, forKey: .intentRevision)
        action = try c.decode(Action.self, forKey: .action)
        inputDesired = try c.decode(Bool.self, forKey: .inputDesired)
        outputDesired = try c.decode(Bool.self, forKey: .outputDesired)
        expectedRevision = try c.decode(AudioForwardingRevision.self, forKey: .expectedRevision)
        transportId = try c.decode(UUID.self, forKey: .transportId)
        transportKind = try c.decode(AudioForwardingTransport.self, forKey: .transportKind)
        bindingRevision = try c.decode(AudioForwardingRevision.self, forKey: .bindingRevision)
        guard schemaVersion == 1, intentRevision.value > 0, bindingRevision.value > 0,
              action != .stop || (!inputDesired && !outputDesired) else { throw AudioForwardingFailure.invalidIntent }
    }
}

struct AudioForwardingConfiguration: Codable, Equatable, Sendable {
    struct Member: Codable, Equatable, Sendable {
        let participantId: String
        let bootId: UUID
        enum CodingKeys: String, CodingKey, CaseIterable { case participantId, bootId }
        fileprivate init(participantId: String, bootId: UUID) {
            self.participantId = participantId
            self.bootId = bootId
        }
        init(from decoder: Decoder) throws {
            let c = try exact(decoder, CodingKeys.self)
            participantId = try c.decode(String.self, forKey: .participantId)
            bootId = try c.decode(UUID.self, forKey: .bootId)
            guard participantId.range(of: "^[a-z][a-z0-9.:-]{0,79}$", options: .regularExpression) != nil else {
                throw AudioForwardingFailure.invalidMembership
            }
        }
    }
    let controllerBootId: UUID
    let privacyGeneration: UUID
    let registryRevision: AudioForwardingRevision
    let members: [Member]
    enum CodingKeys: String, CodingKey, CaseIterable { case controllerBootId, privacyGeneration, registryRevision, members }
    init(controllerBootId: UUID, privacyGeneration: UUID, membership: LocalAudioParticipantRegistry.Snapshot) throws {
        guard Set(membership.boots.keys) == Set(LocalAudioParticipantID.allCases), membership.revision < UInt64.max else {
            throw AudioForwardingFailure.invalidMembership
        }
        self.controllerBootId = controllerBootId
        self.privacyGeneration = privacyGeneration
        registryRevision = AudioForwardingRevision(membership.revision)
        members = membership.boots.map { Member(participantId: $0.key.rawValue, bootId: $0.value) }
            .sorted { $0.participantId < $1.participantId }
    }
    init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        controllerBootId = try c.decode(UUID.self, forKey: .controllerBootId)
        privacyGeneration = try c.decode(UUID.self, forKey: .privacyGeneration)
        registryRevision = try c.decode(AudioForwardingRevision.self, forKey: .registryRevision)
        members = try c.decode([Member].self, forKey: .members).sorted { $0.participantId < $1.participantId }
        let ids = Set(members.map(\.participantId))
        guard (2...32).contains(members.count), ids.count == members.count,
              ids.isSuperset(of: ["native.sill", "s23.audio.relay"]) else { throw AudioForwardingFailure.invalidMembership }
    }
}

struct AudioForwardingBinding: Decodable, Equatable, Sendable {
    enum Phase: String, Decodable, Sendable { case quiescing, active, off }
    let pairedDeviceId: AudioForwardingDeviceID
    let intentGeneration: UUID
    let bindingEpoch: UUID
    let transportId: UUID
    let transportKind: AudioForwardingTransport
    let operationId: UUID
    let phase: Phase
    let configuration: AudioForwardingConfiguration
    enum CodingKeys: String, CodingKey, CaseIterable {
        case pairedDeviceId, intentGeneration, bindingEpoch, transportId, transportKind, operationId, phase, configuration
    }
    init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        pairedDeviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .pairedDeviceId)
        intentGeneration = try c.decode(UUID.self, forKey: .intentGeneration)
        bindingEpoch = try c.decode(UUID.self, forKey: .bindingEpoch)
        transportId = try c.decode(UUID.self, forKey: .transportId)
        transportKind = try c.decode(AudioForwardingTransport.self, forKey: .transportKind)
        operationId = try c.decode(UUID.self, forKey: .operationId)
        phase = try c.decode(Phase.self, forKey: .phase)
        configuration = try c.decode(AudioForwardingConfiguration.self, forKey: .configuration)
    }

    func participantRequest(for participant: LocalAudioParticipantID, budgetMilliseconds: Int) -> LocalAudioParticipantRequest? {
        guard phase == .quiescing,
              let member = configuration.members.first(where: { $0.participantId == participant.rawValue }) else { return nil }
        let request = LocalAudioParticipantRequest(schemaVersion: 1, operationId: operationId,
            privacyGeneration: configuration.privacyGeneration, registryRevision: String(configuration.registryRevision.value),
            participantId: participant, bootId: member.bootId, budgetMilliseconds: budgetMilliseconds)
        return request.isValid ? request : nil
    }
}

struct AudioForwardingSnapshot: Decodable, Sendable {
    struct Intent: Decodable, Sendable {
        let pairedDeviceId: AudioForwardingDeviceID
        let intentId: UUID
        let intentRevision: AudioForwardingRevision
        let intentGeneration: UUID
        let inputDesired: Bool
        let outputDesired: Bool
        let sentryDesired: Bool
        let localMutedDesired: Bool
        enum CodingKeys: String, CodingKey, CaseIterable {
            case pairedDeviceId, intentId, intentRevision, intentGeneration, inputDesired, outputDesired,
                 sentryDesired, localMutedDesired
        }
        init(from decoder: Decoder) throws {
            let c = try exact(decoder, CodingKeys.self)
            pairedDeviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .pairedDeviceId)
            intentId = try c.decode(UUID.self, forKey: .intentId)
            intentRevision = try c.decode(AudioForwardingRevision.self, forKey: .intentRevision)
            intentGeneration = try c.decode(UUID.self, forKey: .intentGeneration)
            inputDesired = try c.decode(Bool.self, forKey: .inputDesired)
            outputDesired = try c.decode(Bool.self, forKey: .outputDesired)
            sentryDesired = try c.decode(Bool.self, forKey: .sentryDesired)
            localMutedDesired = try c.decode(Bool.self, forKey: .localMutedDesired)
            guard intentRevision.value > 0, sentryDesired, localMutedDesired else { throw AudioForwardingFailure.invalidIntent }
        }
    }
    let schemaVersion: Int
    let revision: AudioForwardingRevision
    let intent: Intent?
    let binding: AudioForwardingBinding?
    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, revision, intent, binding }
    init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        revision = try c.decode(AudioForwardingRevision.self, forKey: .revision)
        intent = try c.decodeIfPresent(Intent.self, forKey: .intent)
        binding = try c.decodeIfPresent(AudioForwardingBinding.self, forKey: .binding)
        guard schemaVersion == 1 else { throw AudioForwardingFailure.invalidBinding }
        if let binding {
            guard let intent, intent.pairedDeviceId == binding.pairedDeviceId,
                  intent.intentGeneration == binding.intentGeneration,
                  binding.phase != .active || intent.inputDesired || intent.outputDesired,
                  binding.phase != .off || (!intent.inputDesired && !intent.outputDesired) else {
                throw AudioForwardingFailure.invalidBinding
            }
        }
    }
}

struct AudioForwardingCredential: Decodable, Sendable {
    let pairedDeviceId: AudioForwardingDeviceID
    let pairingGeneration: UUID
    let credential: String
    enum CodingKeys: String, CodingKey, CaseIterable { case pairedDeviceId, pairingGeneration, credential }
    init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        pairedDeviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .pairedDeviceId)
        pairingGeneration = try c.decode(UUID.self, forKey: .pairingGeneration)
        credential = try c.decode(String.self, forKey: .credential)
        guard credential.utf8.count == 43, credential.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw AudioForwardingFailure.invalidIdentity }
    }
}

enum AudioForwardingResult<Value: Decodable>: Decodable {
    case accepted(Value)
    case refused(code: String, snapshot: AudioForwardingSnapshot)
    private enum CodingKeys: String, CodingKey, CaseIterable { case state, code, snapshot }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: ForwardingKey.self)
        let state = ForwardingKey(stringValue: "state")!
        if keys.contains(state), try keys.decode(String.self, forKey: state) == "refused" {
            let c = try exact(decoder, CodingKeys.self)
            let state = try c.decode(String.self, forKey: .state)
            let code = try c.decode(String.self, forKey: .code)
            guard state == "refused", code.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil else {
                throw AudioForwardingFailure.invalidBinding
            }
            self = .refused(code: code, snapshot: try c.decode(AudioForwardingSnapshot.self, forKey: .snapshot))
        } else {
            self = .accepted(try Value(from: decoder))
        }
    }
}
