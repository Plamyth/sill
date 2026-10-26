import Foundation

struct RemoteScreenDemandObservation: Sendable {
    struct Epoch: Sendable, Equatable, Encodable {
        let id: UUID
        let generation: String

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id.uuidString.lowercased(), forKey: .id)
            try c.encode(generation, forKey: .generation)
        }
        private enum CodingKeys: String, CodingKey { case id, generation }
    }

    struct Window: Sendable, Equatable {
        let windowID: UInt32
        let ownerPID: Int32
        let ownerStartSeconds: UInt64
        let ownerStartMicroseconds: UInt32
        let bundleIdentifier: String
    }

    struct Display: Sendable, Equatable {
        let displayID: UInt32
        let displayUUID: UUID
    }

    enum Source: Sendable, Equatable, Encodable {
        case window(Window)
        case display(Display)

        fileprivate var valid: Bool {
            switch self {
            case .window(let window):
                return window.windowID > 0 && window.ownerPID > 0 && window.ownerStartSeconds > 0
                    && window.ownerStartMicroseconds < 1_000_000
                    && !window.bundleIdentifier.isEmpty && window.bundleIdentifier.utf8.count <= 255
            case .display(let display):
                return display.displayID > 0
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .window(let window):
                try c.encode("window", forKey: .kind)
                try c.encode(window.windowID, forKey: .windowID)
                try c.encode(window.ownerPID, forKey: .ownerPID)
                try c.encode(String(window.ownerStartSeconds), forKey: .ownerStartSeconds)
                try c.encode(window.ownerStartMicroseconds, forKey: .ownerStartMicroseconds)
                try c.encode(window.bundleIdentifier, forKey: .bundleIdentifier)
            case .display(let display):
                try c.encode("display", forKey: .kind)
                try c.encode(display.displayID, forKey: .displayID)
                try c.encode(display.displayUUID.uuidString.lowercased(), forKey: .displayUUID)
            }
        }
        private enum CodingKeys: String, CodingKey {
            case kind, windowID, ownerPID, ownerStartSeconds, ownerStartMicroseconds, bundleIdentifier
            case displayID, displayUUID
        }
    }

    struct Consumer: Sendable {
        let incarnation: UUID
        let epoch: Epoch
        let source: Source
        let expiresAt: TimeInterval
    }

    let hostGeneration: UUID
    let revision: UInt64
    let complete: Bool
    let consumers: [Consumer]
    let observedAt: TimeInterval

    func request(now: TimeInterval) throws -> RemoteScreenDemandRequest {
        guard revision > 0 else { throw ProviderCallFailure.invalidFields }
        let fresh = now.isFinite && observedAt.isFinite && now >= observedAt && now - observedAt < 5
        var complete = complete && fresh && consumers.count <= 16
        var included: [RemoteScreenDemandRequest.Consumer] = []
        var incarnations = Set<UUID>()
        for consumer in consumers.prefix(16) {
            let milliseconds = ((consumer.expiresAt - now) * 1000).rounded(.down)
            guard fresh, consumer.expiresAt.isFinite, milliseconds >= 1, milliseconds <= 5000,
                  consumer.source.valid, !consumer.epoch.generation.isEmpty,
                  consumer.epoch.generation.utf8.count <= 128,
                  incarnations.insert(consumer.incarnation).inserted else {
                complete = false
                continue
            }
            included.append(.init(incarnation: consumer.incarnation.uuidString.lowercased(),
                epoch: consumer.epoch, source: consumer.source, validForMs: Int(milliseconds)))
        }
        var request = RemoteScreenDemandRequest(hostGeneration: hostGeneration.uuidString.lowercased(),
            revision: String(revision), complete: complete, consumers: included)
        while try JSONEncoder().encode(request).count + 1 >= 16_384 {
            request.consumers.removeLast()
            request.complete = false
        }
        return request
    }
}

struct RemoteScreenDemandRequest: Encodable, Sendable {
    struct Consumer: Encodable, Sendable {
        let incarnation: String
        let epoch: RemoteScreenDemandObservation.Epoch
        let source: RemoteScreenDemandObservation.Source
        let validForMs: Int
    }

    let schemaVersion = 1
    let op = "provider.screenDemand"
    let hostGeneration: String
    let revision: String
    fileprivate(set) var complete: Bool
    fileprivate(set) var consumers: [Consumer]
}

struct RemoteScreenDemandAcknowledgement: Decodable, Sendable {
    let hostGeneration: UUID
    let revision: UInt64
    let coreGeneration: UUID

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, op, hostGeneration, revision, coreGeneration, accepted
    }

    init(from decoder: Decoder) throws {
        try providerExactKeys(decoder, required: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1,
              try c.decode(String.self, forKey: .op) == "provider.screenDemand",
              try c.decode(Bool.self, forKey: .accepted) else { throw ProviderCallFailure.invalidFields }
        hostGeneration = try c.decode(UUID.self, forKey: .hostGeneration)
        coreGeneration = try c.decode(UUID.self, forKey: .coreGeneration)
        let text = try c.decode(String.self, forKey: .revision)
        guard let value = UInt64(text), value > 0, String(value) == text else {
            throw ProviderCallFailure.invalidFields
        }
        revision = value
    }

    func validate(_ request: RemoteScreenDemandRequest, coreGeneration expected: UUID?) throws {
        guard hostGeneration.uuidString.lowercased() == request.hostGeneration,
              String(revision) == request.revision,
              expected == nil || coreGeneration == expected else { throw ProviderCallFailure.invalidIdentity }
    }
}
