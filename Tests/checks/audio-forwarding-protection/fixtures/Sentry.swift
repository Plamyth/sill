import Foundation

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
