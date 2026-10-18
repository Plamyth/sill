import Foundation

/// Version 2 verifies writable master mutes for every active endpoint direction except the
/// validated BlackHole 2/16-channel devices, plus the three isolated BlackHole defaults.
/// This does not attest acoustic silence, display protection, input protection, or Sentry coverage.
public struct AudioPrivacyState: Codable, Equatable, Sendable {
    public var version: Int
    public var protected: Bool
    public var reason: String?

    public init(version: Int = 2, protected: Bool, reason: String? = nil) {
        self.version = version; self.protected = protected; self.reason = reason
    }
}
