import Foundation

/// A device's explicit request to hear the Mac through this Sill connection. The host keeps
/// the Mac's own output active. The first packet after `enabled` is kind 33 AudioPacket.
public struct RemoteAudioSubscription: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// Unique for this connection and user action. An old answer cannot grant a new request.
    public let requestID: UUID

    public init(enabled: Bool, requestID: UUID = UUID()) {
        self.enabled = enabled
        self.requestID = requestID
    }
}

/// The host's answer to kind 200. A nil requestID is a host-initiated revocation
/// (source change or capture failure); it cannot grant playback.
public struct RemoteAudioState: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let requestID: UUID?
    public let reason: String?

    public init(enabled: Bool, requestID: UUID?, reason: String? = nil) {
        self.enabled = enabled
        self.requestID = requestID
        self.reason = reason
    }
}
