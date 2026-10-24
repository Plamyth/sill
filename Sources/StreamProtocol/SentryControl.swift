import Foundation
import CryptoKit

public enum SentryControlFailure: Error { case invalidPayload, unsupportedVersion, payloadTooLarge }

public enum SentryManualIntent: String, Codable, Sendable { case automatic, on, off }

public struct SentryControlCapability: Codable, Equatable, Sendable {
    public let version: Int
    public let role: String
    public let authorizationGeneration: UUID
    public let canSet: Bool
    public let manualIntent: SentryManualIntent

    public init(authorizationGeneration: UUID, manualIntent: SentryManualIntent) {
        version = 2
        role = "ownerDevice"
        self.authorizationGeneration = authorizationGeneration
        canSet = true
        self.manualIntent = manualIntent
    }

    private enum CodingKeys: String, CodingKey { case version, role, authorizationGeneration, canSet, manualIntent }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 2,
              try c.decode(String.self, forKey: .role) == "ownerDevice",
              try c.decode(Bool.self, forKey: .canSet) else { throw SentryControlFailure.invalidPayload }
        self.init(authorizationGeneration: try sentryUUID(c.decode(String.self, forKey: .authorizationGeneration)),
                  manualIntent: try c.decode(SentryManualIntent.self, forKey: .manualIntent))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(role, forKey: .role)
        try c.encode(authorizationGeneration.uuidString.lowercased(), forKey: .authorizationGeneration)
        try c.encode(canSet, forKey: .canSet)
        try c.encode(manualIntent, forKey: .manualIntent)
    }
}

/// rawRequest가 멱등성의 원본이다. 재조회할 때 다시 인코딩하거나 CAS 필드를 고치지 않는다.
public struct SentryControlRequest: Equatable, Sendable {
    public static let maximumPayload = 512
    public let requestID: UUID
    public let hostBootID: UUID
    public let sessionID: UUID
    public let revision: UUID
    public let authorizationGeneration: UUID
    public let desired: Bool
    public let rawRequest: Data
    public let requestDigest: String
    public var version: Int { 2 }

    private struct Payload: Codable {
        let version: Int
        let requestID, hostBootID, sessionID, revision, authorizationGeneration: String
        let desired: Bool
    }

    public init(rawRequest: Data) throws {
        try SentryJSON.validate(rawRequest, maximum: Self.maximumPayload, request: true)
        let value = try JSONDecoder().decode(Payload.self, from: rawRequest)
        guard value.version == 2 else { throw SentryControlFailure.unsupportedVersion }
        requestID = try sentryUUID(value.requestID)
        hostBootID = try sentryUUID(value.hostBootID)
        sessionID = try sentryUUID(value.sessionID)
        revision = try sentryUUID(value.revision)
        authorizationGeneration = try sentryUUID(value.authorizationGeneration)
        desired = value.desired
        self.rawRequest = rawRequest
        requestDigest = SHA256.hash(data: rawRequest).map { String(format: "%02x", $0) }.joined()
    }

    public init(requestID: UUID = UUID(), hostBootID: UUID, sessionID: UUID, revision: UUID,
                authorizationGeneration: UUID, desired: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try self.init(rawRequest: encoder.encode(Payload(version: 2,
            requestID: requestID.uuidString.lowercased(), hostBootID: hostBootID.uuidString.lowercased(),
            sessionID: sessionID.uuidString.lowercased(), revision: revision.uuidString.lowercased(),
            authorizationGeneration: authorizationGeneration.uuidString.lowercased(), desired: desired)))
    }
}

public struct SentryControlResponse: Codable, Equatable, Sendable {
    public enum OperationState: String, Codable, Sendable { case applied, pending, rejected, superseded, unknown }
    public enum Code: String, Codable, Sendable {
        case applied = "SENTRY_APPLIED", pending = "SENTRY_PENDING", superseded = "SENTRY_SUPERSEDED"
        case unknown = "SENTRY_UNKNOWN", unsupported = "SENTRY_UNSUPPORTED", notAuthorized = "SENTRY_NOT_AUTHORIZED"
        case staleState = "SENTRY_STALE_STATE", requestConflict = "SENTRY_REQUEST_CONFLICT", busy = "SENTRY_BUSY"
        case controlFailed = "SENTRY_CONTROL_FAILED", targetUnconfirmed = "SENTRY_TARGET_UNCONFIRMED"
    }
    public static let maximumPayload = 4096
    public let version: Int
    public let requestID: UUID
    public let accepted: Bool
    public let operationState: OperationState
    public let code: Code
    public let state: SentryState

    public init(requestID: UUID, accepted: Bool, operationState: OperationState, code: Code, state: SentryState) {
        version = 2
        self.requestID = requestID
        self.accepted = accepted
        self.operationState = operationState
        self.code = code
        self.state = state
    }

    public static func decodePayload(_ data: Data) throws -> Self {
        try SentryJSON.validate(data, maximum: maximumPayload, request: false)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func encodedPayload() throws -> Data {
        let data = try JSONEncoder().encode(self)
        _ = try Self.decodePayload(data)
        return data
    }
    private enum CodingKeys: String, CodingKey { case version, requestID, accepted, operationState, code, state }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 2 else { throw SentryControlFailure.unsupportedVersion }
        let state = try c.decode(SentryState.self, forKey: .state)
        guard state.version == 1 else { throw SentryControlFailure.invalidPayload }
        self.init(requestID: try sentryUUID(c.decode(String.self, forKey: .requestID)),
                  accepted: try c.decode(Bool.self, forKey: .accepted),
                  operationState: try c.decode(OperationState.self, forKey: .operationState),
                  code: try c.decode(Code.self, forKey: .code), state: state)
        let expected: Code?
        switch operationState {
        case .applied: expected = .applied
        case .pending: expected = .pending
        case .superseded: expected = .superseded
        case .unknown: expected = .unknown
        case .rejected: expected = nil
        }
        if let expected {
            guard code == expected, operationState == .unknown || accepted else { throw SentryControlFailure.invalidPayload }
        } else {
            guard ![Code.applied, .pending, .superseded, .unknown].contains(code) else { throw SentryControlFailure.invalidPayload }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try c.encode(accepted, forKey: .accepted)
        try c.encode(operationState, forKey: .operationState)
        try c.encode(code, forKey: .code)
        try c.encode(state, forKey: .state)
    }
}

private func sentryUUID(_ value: String) throws -> UUID {
    guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
        throw SentryControlFailure.invalidPayload
    }
    return uuid
}

/// JSONDecoder가 버리는 중복·알 수 없는 키를 payload 경계에서 먼저 거부한다.
private struct SentryJSON {
    let bytes: [UInt8]
    var offset = 0
    let request: Bool
    static func validate(_ data: Data, maximum: Int, request: Bool) throws {
        guard data.count <= maximum else { throw SentryControlFailure.payloadTooLarge }
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { throw SentryControlFailure.invalidPayload }
        var scanner = Self(bytes: Array(data), request: request)
        try scanner.object(path: "root")
        scanner.whitespace()
        guard scanner.offset == scanner.bytes.count else { throw SentryControlFailure.invalidPayload }
    }
    mutating func whitespace() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    mutating func take(_ byte: UInt8) throws {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { throw SentryControlFailure.invalidPayload }
        offset += 1
    }
    mutating func string() throws -> String {
        whitespace()
        let start = offset
        try take(34)
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
            if byte == 92 {
                guard offset < bytes.count else { throw SentryControlFailure.invalidPayload }
                offset += 1
            }
        }
        throw SentryControlFailure.invalidPayload
    }
    mutating func object(path: String) throws {
        let allowed: Set<String>
        let required: Set<String>
        switch path {
        case "root" where request:
            allowed = ["version", "requestID", "hostBootID", "sessionID", "revision", "authorizationGeneration", "desired"]
            required = allowed
        case "root":
            allowed = ["version", "requestID", "accepted", "operationState", "code", "state"]; required = allowed
        case "root.state":
            allowed = ["version", "hostBootID", "sessionID", "revision", "requested", "phase", "reason", "limitations", "control"]
            required = allowed.subtracting(["reason", "control"])
        case "root.state.control":
            allowed = ["version", "role", "authorizationGeneration", "canSet", "manualIntent"]; required = allowed
        default: throw SentryControlFailure.invalidPayload
        }
        try take(123)
        var seen = Set<String>()
        while true {
            let key = try string()
            guard allowed.contains(key), seen.insert(key).inserted else { throw SentryControlFailure.invalidPayload }
            try take(58)
            try value(path: path + "." + key)
            whitespace()
            guard offset < bytes.count else { throw SentryControlFailure.invalidPayload }
            if bytes[offset] == 125 { offset += 1; break }
            try take(44)
        }
        guard required.isSubset(of: seen) else { throw SentryControlFailure.invalidPayload }
    }
    mutating func value(path: String) throws {
        whitespace()
        guard offset < bytes.count else { throw SentryControlFailure.invalidPayload }
        if bytes[offset] == 123 { try object(path: path); return }
        if bytes[offset] == 34 { _ = try string(); return }
        if bytes[offset] == 91 {
            guard path == "root.state.limitations" else { throw SentryControlFailure.invalidPayload }
            try take(91); whitespace()
            if offset < bytes.count, bytes[offset] == 93 { offset += 1; return }
            while true {
                _ = try string(); whitespace()
                guard offset < bytes.count else { throw SentryControlFailure.invalidPayload }
                if bytes[offset] == 93 { offset += 1; return }
                try take(44)
            }
        }
        let start = offset
        while offset < bytes.count, ![9, 10, 13, 32, 44, 125].contains(bytes[offset]) { offset += 1 }
        let text = String(decoding: bytes[start..<offset], as: UTF8.self)
        guard ["true", "false", "null", "1", "2"].contains(text) else { throw SentryControlFailure.invalidPayload }
        if text == "null", path != "root.state.reason" { throw SentryControlFailure.invalidPayload }
    }
}
