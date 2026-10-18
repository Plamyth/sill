import Foundation

/// Version 1 verifies built-in master mutes and the three isolated BlackHole defaults.
/// This does not attest acoustic silence on external devices selected directly by another app.
public struct AudioPrivacyState: Codable, Equatable, Sendable {
    public var version: Int
    public var protected: Bool
    public var reason: String?

    public init(version: Int = 1, protected: Bool, reason: String? = nil) {
        self.version = version; self.protected = protected; self.reason = reason
    }
}
