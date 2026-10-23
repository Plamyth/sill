import Foundation

/// Unversioned construction retains the legacy v1 contract. Hosts publish v2 explicitly.
/// Version 2 verifies writable master mutes for every active endpoint direction except the
/// validated BlackHole 2/16-channel devices, plus the three isolated BlackHole defaults.
/// This does not attest acoustic silence, display protection, input protection, or Sentry coverage.
public struct AudioPrivacyCoverage: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable { case input, output }
    public let uid: String
    public let direction: Direction
    public let channels: Int
    public let method: String
    public let protected: Bool
    public let reason: String?
    public let alternative: String?

    public init(uid: String, direction: Direction, channels: Int, method: String, protected: Bool, reason: String? = nil, alternative: String? = nil) {
        self.uid = uid; self.direction = direction; self.channels = channels
        self.method = method; self.protected = protected; self.reason = reason; self.alternative = alternative
    }
}

public struct AudioPrivacyState: Codable, Equatable, Sendable {
    public var version: Int
    public var protected: Bool
    public var reason: String?
    public var coverage: [AudioPrivacyCoverage]?
    public var latched: Bool?

    public init(version: Int = 1, protected: Bool, reason: String? = nil,
                coverage: [AudioPrivacyCoverage]? = nil, latched: Bool? = nil) {
        self.coverage = coverage; self.latched = latched
        self.version = version; self.protected = protected; self.reason = reason
    }
}
