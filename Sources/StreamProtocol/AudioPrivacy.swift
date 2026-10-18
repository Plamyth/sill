import Foundation

/// Version 2 requires verified mute coverage for every non-approved endpoint direction.
/// Unsupported USB or HDMI endpoints cannot advertise complete protection.
public struct AudioPrivacyState: Codable, Equatable, Sendable {
    public var version: Int
    public var protected: Bool
    public var reason: String?

    public init(version: Int = 2, protected: Bool, reason: String? = nil) {
        self.version = version; self.protected = protected; self.reason = reason
    }
}
