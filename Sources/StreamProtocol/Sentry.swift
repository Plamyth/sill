import Foundation

public struct SourceSelectionAdmission: Codable, Equatable, Sendable {
    public static let maximumGeneration: UInt64 = 9_007_199_254_740_991
    public let schemaVersion: Int
    public let generation: UInt64
    public let ready: Bool

    public init?(generation: UInt64, ready: Bool) {
        guard (1...Self.maximumGeneration).contains(generation) else { return nil }
        schemaVersion = 1
        self.generation = generation
        self.ready = ready
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, generation, ready }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        let generation = try values.decode(UInt64.self, forKey: .generation)
        let ready = try values.decode(Bool.self, forKey: .ready)
        guard schemaVersion == 1, let value = Self(generation: generation, ready: ready) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "소스 선택 준비 상태가 유효하지 않습니다."))
        }
        self = value
    }
}

public struct SentryState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case inactive, pending, userSessionProtected, blocked
    }
    public let version: Int
    public let hostBootID: UUID
    public let sessionID: UUID
    public let revision: UUID
    public let requested: Bool
    public let phase: Phase
    public let reason: String?
    public let limitations: [String]

    public init(hostBootID: UUID, sessionID: UUID, revision: UUID, requested: Bool,
                phase: Phase, reason: String? = nil, limitations: [String]) {
        version = 1
        self.hostBootID = hostBootID
        self.sessionID = sessionID
        self.revision = revision
        self.requested = requested
        self.phase = phase
        self.reason = reason
        self.limitations = limitations
    }
}

public struct SentryActivation: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let hostBootID: UUID
    public let sessionID: UUID
    public let revision: UUID

    public init(requestID: UUID = UUID(), hostBootID: UUID, sessionID: UUID, revision: UUID) {
        version = 1
        self.requestID = requestID
        self.hostBootID = hostBootID
        self.sessionID = sessionID
        self.revision = revision
    }
}

public struct SentryResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let accepted: Bool
    public let state: SentryState
    public let reason: String?

    public init(requestID: UUID, accepted: Bool, state: SentryState, reason: String? = nil) {
        self.requestID = requestID
        self.accepted = accepted
        self.state = state
        self.reason = reason
    }
}
