import Foundation

public struct AudioForwardingDeviceID: Codable, Hashable, Sendable {
    public let hex: String

    public init?(hex: String) {
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.hex = hex
    }

    public init?(fingerprint: Data) {
        guard fingerprint.count == 32 else { return nil }
        hex = fingerprint.map { String(format: "%02x", $0) }.joined()
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AudioForwardingFailure.invalidIdentity
        }
        hex = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

public struct AudioForwardingRevision: Codable, Equatable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = UInt64(text), String(value) == text else { throw AudioForwardingFailure.invalidRevision }
        self.value = value
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }
}

public enum AudioForwardingFailure: Error {
    case invalidIdentity, invalidRevision, invalidIntent, invalidMembership, invalidBinding, unexpectedFields
}

public enum AudioForwardingTransport: String, Codable, Sendable { case http, native }

private struct ForwardingKey: CodingKey {
    public let stringValue: String
    var intValue: Int? { nil }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
}

private func exact<K: CodingKey & CaseIterable>(_ decoder: Decoder, _ type: K.Type) throws -> KeyedDecodingContainer<K> {
    let keys = try decoder.container(keyedBy: ForwardingKey.self).allKeys.map(\.stringValue)
    guard Set(keys) == Set(K.allCases.map(\.stringValue)) else { throw AudioForwardingFailure.unexpectedFields }
    return try decoder.container(keyedBy: type)
}

public struct AudioForwardingIntentRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case request, resume, update, stop }
    public let schemaVersion: Int
    public let pairedDeviceId: AudioForwardingDeviceID
    public let intentId: UUID
    public let intentRevision: AudioForwardingRevision
    public let action: Action
    public let inputDesired: Bool
    public let outputDesired: Bool
    public let expectedRevision: AudioForwardingRevision
    public let transportId: UUID
    public let transportKind: AudioForwardingTransport
    public let bindingRevision: AudioForwardingRevision

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, pairedDeviceId, intentId, intentRevision, action, inputDesired,
             outputDesired, expectedRevision, transportId, transportKind, bindingRevision
    }

    public init(pairedDeviceId: AudioForwardingDeviceID, intentId: UUID, intentRevision: AudioForwardingRevision,
                action: Action, inputDesired: Bool, outputDesired: Bool, expectedRevision: AudioForwardingRevision,
                transportId: UUID, transportKind: AudioForwardingTransport, bindingRevision: AudioForwardingRevision) throws {
        guard intentRevision.value > 0, bindingRevision.value > 0,
              action != .stop || (!inputDesired && !outputDesired) else { throw AudioForwardingFailure.invalidIntent }
        schemaVersion = 1
        self.pairedDeviceId = pairedDeviceId; self.intentId = intentId; self.intentRevision = intentRevision
        self.action = action; self.inputDesired = inputDesired; self.outputDesired = outputDesired
        self.expectedRevision = expectedRevision; self.transportId = transportId
        self.transportKind = transportKind; self.bindingRevision = bindingRevision
    }

    public init(from decoder: Decoder) throws {
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

public struct AudioForwardingConfiguration: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable {
        public let participantId: String
        public let bootId: UUID
        enum CodingKeys: String, CodingKey, CaseIterable { case participantId, bootId }
        public init(participantId: String, bootId: UUID) throws {
            guard participantId.range(of: "^[a-z][a-z0-9.:-]{0,79}$", options: .regularExpression) != nil else {
                throw AudioForwardingFailure.invalidMembership
            }
            self.participantId = participantId
            self.bootId = bootId
        }
        public init(from decoder: Decoder) throws {
            let c = try exact(decoder, CodingKeys.self)
            participantId = try c.decode(String.self, forKey: .participantId)
            bootId = try c.decode(UUID.self, forKey: .bootId)
            guard participantId.range(of: "^[a-z][a-z0-9.:-]{0,79}$", options: .regularExpression) != nil else {
                throw AudioForwardingFailure.invalidMembership
            }
        }
    }
    public let controllerBootId: UUID
    public let privacyGeneration: UUID
    public let registryRevision: AudioForwardingRevision
    public let members: [Member]
    enum CodingKeys: String, CodingKey, CaseIterable { case controllerBootId, privacyGeneration, registryRevision, members }
    public init(controllerBootId: UUID, privacyGeneration: UUID, registryRevision: AudioForwardingRevision, members: [Member]) throws {
        let ids = Set(members.map(\.participantId))
        guard (2...32).contains(members.count), ids.count == members.count,
              ids.isSuperset(of: ["native.sill", "s23.audio.relay"]) else { throw AudioForwardingFailure.invalidMembership }
        self.controllerBootId = controllerBootId; self.privacyGeneration = privacyGeneration
        self.registryRevision = registryRevision; self.members = members.sorted { $0.participantId < $1.participantId }
    }
    public init(from decoder: Decoder) throws {
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

public struct AudioForwardingBinding: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case quiescing, active, off }
    public let pairedDeviceId: AudioForwardingDeviceID
    public let intentGeneration: UUID
    public let bindingEpoch: UUID
    public let transportId: UUID
    public let transportKind: AudioForwardingTransport
    public let operationId: UUID
    public let phase: Phase
    public let configuration: AudioForwardingConfiguration
    enum CodingKeys: String, CodingKey, CaseIterable {
        case pairedDeviceId, intentGeneration, bindingEpoch, transportId, transportKind, operationId, phase, configuration
    }
    public init(pairedDeviceId: AudioForwardingDeviceID, intentGeneration: UUID, bindingEpoch: UUID,
                transportId: UUID, transportKind: AudioForwardingTransport, operationId: UUID,
                phase: Phase, configuration: AudioForwardingConfiguration) {
        self.pairedDeviceId = pairedDeviceId; self.intentGeneration = intentGeneration; self.bindingEpoch = bindingEpoch
        self.transportId = transportId; self.transportKind = transportKind; self.operationId = operationId
        self.phase = phase; self.configuration = configuration
    }
    public init(from decoder: Decoder) throws {
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


}

public struct AudioForwardingSnapshot: Codable, Sendable {
    public struct Intent: Codable, Sendable {
        public let pairedDeviceId: AudioForwardingDeviceID
        public let intentId: UUID
        public let intentRevision: AudioForwardingRevision
        public let intentGeneration: UUID
        public let inputDesired: Bool
        public let outputDesired: Bool
        public let sentryDesired: Bool
        public let localMutedDesired: Bool
        enum CodingKeys: String, CodingKey, CaseIterable {
            case pairedDeviceId, intentId, intentRevision, intentGeneration, inputDesired, outputDesired,
                 sentryDesired, localMutedDesired
        }
        public init(pairedDeviceId: AudioForwardingDeviceID, intentId: UUID, intentRevision: AudioForwardingRevision,
                    intentGeneration: UUID, inputDesired: Bool, outputDesired: Bool,
                    sentryDesired: Bool = true, localMutedDesired: Bool = true) throws {
            guard intentRevision.value > 0, sentryDesired, localMutedDesired else { throw AudioForwardingFailure.invalidIntent }
            self.pairedDeviceId = pairedDeviceId; self.intentId = intentId; self.intentRevision = intentRevision
            self.intentGeneration = intentGeneration; self.inputDesired = inputDesired; self.outputDesired = outputDesired
            self.sentryDesired = sentryDesired; self.localMutedDesired = localMutedDesired
        }
        public init(from decoder: Decoder) throws {
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
    public let schemaVersion: Int
    public let revision: AudioForwardingRevision
    public let intent: Intent?
    public let binding: AudioForwardingBinding?
    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, revision, intent, binding }
    public init(revision: AudioForwardingRevision, intent: Intent?, binding: AudioForwardingBinding?) throws {
        schemaVersion = 1; self.revision = revision; self.intent = intent; self.binding = binding
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        revision = try c.decode(AudioForwardingRevision.self, forKey: .revision)
        intent = try c.decodeIfPresent(Intent.self, forKey: .intent)
        binding = try c.decodeIfPresent(AudioForwardingBinding.self, forKey: .binding)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(revision, forKey: .revision)
        try c.encode(intent, forKey: .intent)
        try c.encode(binding, forKey: .binding)
    }
    private func validate() throws {
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

public struct AudioForwardingCredential: Codable, Sendable {
    public let pairedDeviceId: AudioForwardingDeviceID
    public let pairingGeneration: UUID
    public let credential: String
    enum CodingKeys: String, CodingKey, CaseIterable { case pairedDeviceId, pairingGeneration, credential }
    public init(pairedDeviceId: AudioForwardingDeviceID, pairingGeneration: UUID, credential: String) throws {
        self.pairedDeviceId = pairedDeviceId; self.pairingGeneration = pairingGeneration; self.credential = credential
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        pairedDeviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .pairedDeviceId)
        pairingGeneration = try c.decode(UUID.self, forKey: .pairingGeneration)
        credential = try c.decode(String.self, forKey: .credential)
        try validate()
    }
    private func validate() throws {
        guard credential.utf8.count == 43, credential.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw AudioForwardingFailure.invalidIdentity }
    }
}

public enum AudioForwardingResult<Value: Decodable>: Decodable {
    case accepted(Value)
    case refused(code: String, snapshot: AudioForwardingSnapshot)
    private enum CodingKeys: String, CodingKey, CaseIterable { case state, code, snapshot }
    public init(from decoder: Decoder) throws {
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

extension AudioForwardingResult: Encodable where Value: Encodable {
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .accepted(let value): try value.encode(to: encoder)
        case .refused(let code, let snapshot):
            guard code.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil else {
                throw AudioForwardingFailure.invalidBinding
            }
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("refused", forKey: .state)
            try c.encode(code, forKey: .code)
            try c.encode(snapshot, forKey: .snapshot)
        }
    }
}

extension AudioForwardingResult: Sendable where Value: Sendable {}

public struct AudioForwardingBootstrap: Codable, Sendable {
    public struct OwnCursor: Codable, Sendable {
        public let intentRevision: AudioForwardingRevision
        public let bindingRevision: AudioForwardingRevision
        enum CodingKeys: String, CodingKey, CaseIterable { case intentRevision, bindingRevision }
        public init(intentRevision: AudioForwardingRevision, bindingRevision: AudioForwardingRevision) {
            self.intentRevision = intentRevision; self.bindingRevision = bindingRevision
        }
        public init(from decoder: Decoder) throws {
            let c = try exact(decoder, CodingKeys.self)
            intentRevision = try c.decode(AudioForwardingRevision.self, forKey: .intentRevision)
            bindingRevision = try c.decode(AudioForwardingRevision.self, forKey: .bindingRevision)
        }
    }
    public let credential: AudioForwardingCredential
    public let ownCursor: OwnCursor
    public let snapshot: AudioForwardingSnapshot
    enum CodingKeys: String, CodingKey, CaseIterable { case credential, ownCursor, snapshot }
    public init(credential: AudioForwardingCredential, ownCursor: OwnCursor, snapshot: AudioForwardingSnapshot) throws {
        self.credential = credential; self.ownCursor = ownCursor; self.snapshot = snapshot
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        credential = try c.decode(AudioForwardingCredential.self, forKey: .credential)
        ownCursor = try c.decode(OwnCursor.self, forKey: .ownCursor)
        snapshot = try c.decode(AudioForwardingSnapshot.self, forKey: .snapshot)
        try validate()
    }
    private func validate() throws {
        if let intent = snapshot.intent, intent.pairedDeviceId == credential.pairedDeviceId,
           intent.intentRevision != ownCursor.intentRevision { throw AudioForwardingFailure.invalidRevision }
    }
}

public struct AudioForwardingCatalog: Codable, Sendable {
    public struct Principal: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case tailnet, cable; case localNetwork = "local-network" }
        public let kind: Kind
        public let id: AudioForwardingDeviceID
        public let authorizationGeneration: UUID
        enum CodingKeys: String, CodingKey, CaseIterable { case kind, id, authorizationGeneration }
        public init(kind: Kind, id: AudioForwardingDeviceID, authorizationGeneration: UUID) {
            self.kind = kind; self.id = id; self.authorizationGeneration = authorizationGeneration
        }
        public init(from decoder: Decoder) throws {
            let c = try exact(decoder, CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            id = try c.decode(AudioForwardingDeviceID.self, forKey: .id)
            authorizationGeneration = try c.decode(UUID.self, forKey: .authorizationGeneration)
        }
    }
    public enum Role: String, Codable, Sendable { case controlOnly, viewer }
    public let schemaVersion: Int
    public let principal: Principal
    public let role: Role
    public let bootstrap: AudioForwardingBootstrap
    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, principal, role, bootstrap }
    public init(principal: Principal, role: Role, bootstrap: AudioForwardingBootstrap) throws {
        schemaVersion = 2; self.principal = principal; self.role = role; self.bootstrap = bootstrap
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        principal = try c.decode(Principal.self, forKey: .principal)
        role = try c.decode(Role.self, forKey: .role)
        bootstrap = try c.decode(AudioForwardingBootstrap.self, forKey: .bootstrap)
        try validate()
    }
    private func validate() throws {
        guard schemaVersion == 2, principal.id == bootstrap.credential.pairedDeviceId,
              principal.authorizationGeneration == bootstrap.credential.pairingGeneration else {
            throw AudioForwardingFailure.invalidIdentity
        }
    }
}

public enum AudioForwardingOperation: String, Codable, Sendable { case observe, submit }

public struct AudioForwardingControl: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let operation: AudioForwardingOperation
    public let intent: AudioForwardingIntentRequest?
    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, requestID, operation, intent }
    public init(requestID: UUID, operation: AudioForwardingOperation, intent: AudioForwardingIntentRequest?) throws {
        schemaVersion = 1; self.requestID = requestID; self.operation = operation; self.intent = intent
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        operation = try c.decode(AudioForwardingOperation.self, forKey: .operation)
        intent = try c.decodeIfPresent(AudioForwardingIntentRequest.self, forKey: .intent)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(requestID, forKey: .requestID)
        try c.encode(operation, forKey: .operation); try c.encode(intent, forKey: .intent)
    }
    private func validate() throws {
        guard schemaVersion == 1, (operation == .observe) == (intent == nil) else {
            throw AudioForwardingFailure.invalidIntent
        }
    }
}

public struct AudioForwardingState: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let operation: AudioForwardingOperation
    public let catalog: AudioForwardingCatalog?
    public let result: AudioForwardingResult<AudioForwardingSnapshot>?
    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, requestID, operation, catalog, result }
    public init(requestID: UUID, operation: AudioForwardingOperation, catalog: AudioForwardingCatalog?,
                result: AudioForwardingResult<AudioForwardingSnapshot>?) throws {
        schemaVersion = 1; self.requestID = requestID; self.operation = operation; self.catalog = catalog; self.result = result
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try exact(decoder, CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        operation = try c.decode(AudioForwardingOperation.self, forKey: .operation)
        catalog = try c.decodeIfPresent(AudioForwardingCatalog.self, forKey: .catalog)
        result = try c.decodeIfPresent(AudioForwardingResult<AudioForwardingSnapshot>.self, forKey: .result)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(requestID, forKey: .requestID)
        try c.encode(operation, forKey: .operation); try c.encode(catalog, forKey: .catalog); try c.encode(result, forKey: .result)
    }
    private func validate() throws {
        guard schemaVersion == 1,
              operation == .observe ? catalog != nil && result == nil : catalog == nil && result != nil else {
            throw AudioForwardingFailure.invalidBinding
        }
    }
}
