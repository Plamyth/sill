import Foundation

/// Mac physical endpoints only. A peer's microphone/speaker needs a separate virtual/peer route.
public struct AudioRouteEndpoint: Codable, Equatable {
    public var uid: String
    public var name: String
    public var input: Bool
    public var output: Bool

    public init(uid: String, name: String, input: Bool, output: Bool) {
        self.uid = uid; self.name = name; self.input = input; self.output = output
    }
}

public struct AudioRouteDefaults: Codable, Equatable {
    /// Actual system defaults, even when a default is virtual and absent from the physical catalog.
    public var inputUID: String?
    public var outputUID: String?
    public init(inputUID: String?, outputUID: String?) {
        self.inputUID = inputUID; self.outputUID = outputUID
    }
}

public enum AudioRouteResult: String, Codable {
    case applied, unchanged, stale, invalid, conflict, unavailable, failed, rollbackFailed
}

public struct AudioRouteState: Codable, Equatable {
    /// Opaque host revision, renewed on observations and consumed requests; never reused on restart.
    public var revision: UUID
    public var endpoints: [AudioRouteEndpoint]
    public var defaults: AudioRouteDefaults
    /// false means defaults/catalog could not be read; nil defaults then do not assert disconnection.
    public var available: Bool
    public var answering: UUID?
    public var result: AudioRouteResult?

    public init(revision: UUID, endpoints: [AudioRouteEndpoint], defaults: AudioRouteDefaults,
                available: Bool, answering: UUID? = nil, result: AudioRouteResult? = nil) {
        self.revision = revision; self.endpoints = endpoints; self.defaults = defaults
        self.available = available; self.answering = answering; self.result = result
    }
}

public struct AudioRouteSelection: Codable, Equatable {
    public var requestID: UUID
    public var revision: UUID
    public var expected: AudioRouteDefaults
    /// nil leaves that direction alone. A request cannot clear a default or select automatically.
    public var inputUID: String?
    public var outputUID: String?

    public init(requestID: UUID = UUID(), revision: UUID, expected: AudioRouteDefaults,
                inputUID: String? = nil, outputUID: String? = nil) {
        self.requestID = requestID; self.revision = revision; self.expected = expected
        self.inputUID = inputUID; self.outputUID = outputUID
    }
}

public enum AudioRoutingPolicy {
    public static let maxSelectionPayload = 2048
    public static let maxStatePayload = 512 * 1024
    public static let maxEndpoints = 128
    public static let maxUIDBytes = 256
    public static let maxNameBytes = 128

    public static func validUID(_ uid: String) -> Bool {
        !uid.isEmpty && uid.utf8.count <= maxUIDBytes &&
        !uid.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public static func valid(_ request: AudioRouteSelection) -> Bool {
        (request.inputUID != nil || request.outputUID != nil) &&
        [request.inputUID, request.outputUID, request.expected.inputUID, request.expected.outputUID]
            .compactMap { $0 }.allSatisfy(validUID)
    }

    public static func authorized(encrypted: Bool, paired: Bool, connected: Bool,
                                  synthetic: Bool, shuttingDown: Bool) -> Bool {
        encrypted && paired && connected && !synthetic && !shuttingDown
    }
}
