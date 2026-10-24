import Foundation
import CryptoKit

public enum SentryReturnFailure: Error { case invalidPayload, unsupportedVersion, payloadTooLarge }
public enum SentryReturnAuthMode: String, Codable, Sendable { case macLocal, deviceBoundKey }

public struct SentryReturnLease: Codable, Equatable, Sendable {
    public let hostBootID, sessionID, revision, authorizationGeneration: String
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hostBootID, sessionID, revision, authorizationGeneration
    }
    public init(hostBootID: String, sessionID: String, revision: String, authorizationGeneration: String) throws {
        guard [hostBootID, sessionID, revision, authorizationGeneration].allSatisfy(returnUUID) else {
            throw SentryReturnFailure.invalidPayload
        }
        self.hostBootID = hostBootID; self.sessionID = sessionID
        self.revision = revision; self.authorizationGeneration = authorizationGeneration
    }
    public init(from decoder: Decoder) throws {
        try returnKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(hostBootID: c.decode(String.self, forKey: .hostBootID),
            sessionID: c.decode(String.self, forKey: .sessionID), revision: c.decode(String.self, forKey: .revision),
            authorizationGeneration: c.decode(String.self, forKey: .authorizationGeneration))
    }
}

public struct SentryReturnKeyEnrollment: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case enroll, rotate, revoke }
    public let action: Action
    public let keyID: String
    /// Uncompressed P-256 X9.63, 65 bytes, canonical unpadded base64url. Never a TLS identity replacement.
    public let publicKey: String?
    public let previousKeyID: String?
    private enum CodingKeys: String, CodingKey { case action, keyID, publicKey, previousKeyID }
    public init(action: Action, keyID: String, publicKey: String? = nil, previousKeyID: String? = nil) throws {
        guard returnUUID(keyID) else { throw SentryReturnFailure.invalidPayload }
        switch action {
        case .enroll:
            guard previousKeyID == nil, let publicKey, let bytes = returnBase64(publicKey),
                  (try? P256.Signing.PublicKey(x963Representation: bytes)) != nil else { throw SentryReturnFailure.invalidPayload }
        case .rotate:
            guard let previousKeyID, returnUUID(previousKeyID), previousKeyID != keyID,
                  let publicKey, let bytes = returnBase64(publicKey),
                  (try? P256.Signing.PublicKey(x963Representation: bytes)) != nil else { throw SentryReturnFailure.invalidPayload }
        case .revoke:
            guard publicKey == nil, previousKeyID == nil else { throw SentryReturnFailure.invalidPayload }
        }
        self.action = action; self.keyID = keyID; self.publicKey = publicKey; self.previousKeyID = previousKeyID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let action = try c.decode(Action.self, forKey: .action)
        let keys: Set<String> = action == .revoke ? ["action", "keyID"] : action == .enroll
            ? ["action", "keyID", "publicKey"] : ["action", "keyID", "publicKey", "previousKeyID"]
        try returnKeys(decoder, keys)
        try self.init(action: action, keyID: c.decode(String.self, forKey: .keyID),
            publicKey: c.decodeIfPresent(String.self, forKey: .publicKey),
            previousKeyID: c.decodeIfPresent(String.self, forKey: .previousKeyID))
    }
}

public struct SentryReturnReference: Codable, Equatable, Sendable {
    public let requestID, hostBootID, requestDigest: String
    private enum CodingKeys: String, CodingKey, CaseIterable { case requestID, hostBootID, requestDigest }
    public init(requestID: String, hostBootID: String, requestDigest: String) throws {
        guard returnUUID(requestID), returnUUID(hostBootID), returnHex(requestDigest) else { throw SentryReturnFailure.invalidPayload }
        self.requestID = requestID; self.hostBootID = hostBootID; self.requestDigest = requestDigest
    }
    public init(from decoder: Decoder) throws {
        try returnKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requestID: c.decode(String.self, forKey: .requestID),
            hostBootID: c.decode(String.self, forKey: .hostBootID), requestDigest: c.decode(String.self, forKey: .requestDigest))
    }
}

public struct SentryReturnRequest: Equatable, Sendable {
    public let requestID: String
    public let lease: SentryReturnLease
    public let authMode: SentryReturnAuthMode
    public let keyEnrollment: SentryReturnKeyEnrollment?
    public let rawRequest: Data
    public let requestDigest: String
    public var reference: SentryReturnReference {
        try! .init(requestID: requestID, hostBootID: lease.hostBootID, requestDigest: requestDigest)
    }
    public init(rawRequest: Data) throws {
        try ReturnJSON.validate(rawRequest, maximum: SentryReturnControl.maximumPayload)
        let e = try JSONDecoder().decode(ReturnEnvelope.self, from: rawRequest)
        guard e.operation == .request || e.operation == .keyEnrollment,
              let requestID = e.requestID, returnUUID(requestID), let lease = e.lease, let mode = e.authMode,
              e.operation != .keyEnrollment || (e.keyEnrollment != nil && mode == .macLocal) else {
            throw SentryReturnFailure.invalidPayload
        }
        self.requestID = requestID; self.lease = lease; authMode = mode; keyEnrollment = e.keyEnrollment
        self.rawRequest = rawRequest; requestDigest = Self.digest(rawRequest)
    }
    public init(requestID: String = UUID().uuidString.lowercased(), lease: SentryReturnLease,
                authMode: SentryReturnAuthMode, keyEnrollment: SentryReturnKeyEnrollment? = nil) throws {
        var object: [String: Any] = ["schemaVersion": 1, "operation": keyEnrollment == nil ? "request" : "keyEnrollment",
            "requestID": requestID, "lease": try returnObject(lease), "authMode": authMode.rawValue]
        if let keyEnrollment { object["keyEnrollment"] = try returnObject(keyEnrollment) }
        try self.init(rawRequest: returnJSON(object))
    }
    public static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SentryReturnControl: Equatable, Sendable {
    public static let maximumPayload = 4096
    case request(SentryReturnRequest)
    case current(SentryReturnReference)
    case cancel(SentryReturnReference, authGeneration: String)
    case prove(SentryReturnReference, authGeneration: String, signature: Data)

    public static func decodePayload(_ data: Data) throws -> Self {
        try ReturnJSON.validate(data, maximum: maximumPayload)
        let e = try JSONDecoder().decode(ReturnEnvelope.self, from: data)
        switch e.operation {
        case .request, .keyEnrollment: return .request(try .init(rawRequest: data))
        case .current:
            guard let reference = e.reference else { throw SentryReturnFailure.invalidPayload }
            return .current(reference)
        case .cancel:
            guard let reference = e.reference, let generation = e.authGeneration, returnUUID(generation) else {
                throw SentryReturnFailure.invalidPayload
            }
            return .cancel(reference, authGeneration: generation)
        case .prove:
            guard let reference = e.reference, let generation = e.authGeneration, returnUUID(generation),
                  let encoded = e.signature, let signature = returnBase64(encoded),
                  (try? P256.Signing.ECDSASignature(derRepresentation: signature)) != nil else {
                throw SentryReturnFailure.invalidPayload
            }
            return .prove(reference, authGeneration: generation, signature: signature)
        }
    }
    public func encodedPayload() throws -> Data {
        if case .request(let request) = self { return request.rawRequest }
        var object: [String: Any] = ["schemaVersion": 1]
        switch self {
        case .request: break
        case .current(let reference): object["operation"] = "current"; object["reference"] = try returnObject(reference)
        case .cancel(let reference, let generation):
            object["operation"] = "cancel"; object["reference"] = try returnObject(reference); object["authGeneration"] = generation
        case .prove(let reference, let generation, let signature):
            object["operation"] = "prove"; object["reference"] = try returnObject(reference)
            object["authGeneration"] = generation; object["signature"] = Base64URL.encode(signature)
        }
        let data = try returnJSON(object)
        _ = try Self.decodePayload(data)
        return data
    }
}

/// Every property is signed. The host derives identities from its validated connection, never from UI claims.
public struct SentryReturnChallenge: Codable, Equatable, Sendable {
    public static let purpose = "ccr-sentry-local-return-v1"
    public let reference: SentryReturnReference
    public let lease: SentryReturnLease
    public let authGeneration, nonce, ownerID, hostFingerprint, deviceFingerprint, pairingGeneration: String
    public let authMode: SentryReturnAuthMode
    public let keyID: String?
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case reference, lease, authGeneration, nonce, ownerID, hostFingerprint, deviceFingerprint, pairingGeneration, authMode, keyID
    }
    public init(reference: SentryReturnReference, lease: SentryReturnLease, authGeneration: String, nonce: String,
                ownerID: String, hostFingerprint: String, deviceFingerprint: String, pairingGeneration: String,
                authMode: SentryReturnAuthMode, keyID: String?) throws {
        guard reference.hostBootID == lease.hostBootID, returnUUID(authGeneration), returnUUID(pairingGeneration),
              returnBase64(nonce)?.count == 32, returnHex(hostFingerprint), returnHex(deviceFingerprint),
              !ownerID.isEmpty, ownerID.utf8.count <= 128,
              ownerID.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }),
              authMode == .macLocal ? keyID == nil : keyID.map(returnUUID) == true else {
            throw SentryReturnFailure.invalidPayload
        }
        self.reference = reference; self.lease = lease; self.authGeneration = authGeneration; self.nonce = nonce
        self.ownerID = ownerID; self.hostFingerprint = hostFingerprint; self.deviceFingerprint = deviceFingerprint
        self.pairingGeneration = pairingGeneration; self.authMode = authMode; self.keyID = keyID
    }
    public init(from decoder: Decoder) throws {
        try returnKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: c.decode(SentryReturnReference.self, forKey: .reference),
            lease: c.decode(SentryReturnLease.self, forKey: .lease), authGeneration: c.decode(String.self, forKey: .authGeneration),
            nonce: c.decode(String.self, forKey: .nonce), ownerID: c.decode(String.self, forKey: .ownerID),
            hostFingerprint: c.decode(String.self, forKey: .hostFingerprint), deviceFingerprint: c.decode(String.self, forKey: .deviceFingerprint),
            pairingGeneration: c.decode(String.self, forKey: .pairingGeneration), authMode: c.decode(SentryReturnAuthMode.self, forKey: .authMode),
            keyID: c.decodeIfPresent(String.self, forKey: .keyID))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reference, forKey: .reference); try c.encode(lease, forKey: .lease)
        try c.encode(authGeneration, forKey: .authGeneration); try c.encode(nonce, forKey: .nonce)
        try c.encode(ownerID, forKey: .ownerID); try c.encode(hostFingerprint, forKey: .hostFingerprint)
        try c.encode(deviceFingerprint, forKey: .deviceFingerprint); try c.encode(pairingGeneration, forKey: .pairingGeneration)
        try c.encode(authMode, forKey: .authMode); try c.encode(keyID, forKey: .keyID)
    }
    /// ASCII purpose + NUL + compact sorted-key UTF-8 JSON. No slash escaping, floats or Unicode normalization.
    public func signingBytes() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data((Self.purpose + "\0").utf8) + (try encoder.encode(self))
    }
}

public struct SentryReturnState: Codable, Equatable, Sendable {
    public enum AuthStatus: String, Codable, Sendable { case notStarted, pending, succeeded, failed, cancelled, expired, unsupported }
    public enum OperationState: String, Codable, Sendable {
        case authenticating, restoring, completed, cancelled, expired, rejected, failed, unknown
    }
    public enum Code: String, Codable, Sendable {
        case authenticationRequired, returnPrepared, localReturned, keyEnrolled, keyRotated, keyRevoked
        case cancelled, expired, staleLease, noEnrolledKey, invalidProof, authenticationFailed, restoreFailed
        case requestConflict, busy, unknown, capacity, enrollmentConflict
    }
    public static let maximumPayload = 16384
    public let schemaVersion: Int
    public let reference: SentryReturnReference
    public let authGeneration: String?
    public let authStatus: AuthStatus
    public let operationState: OperationState
    public let code: Code
    public let challenge: SentryReturnChallenge?
    public let remainingMilliseconds: Int
    public let currentProtection: String
    public let nextPolicy: String
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, reference, authGeneration, authStatus, operationState, code, challenge, remainingMilliseconds, currentProtection, nextPolicy
    }
    public init(reference: SentryReturnReference, authGeneration: String?, authStatus: AuthStatus,
                operationState: OperationState, code: Code, challenge: SentryReturnChallenge?, remainingMilliseconds: Int) throws {
        guard authGeneration.map(returnUUID) ?? true, (0...120000).contains(remainingMilliseconds),
              operationState != .completed || authStatus == .succeeded,
              challenge == nil || (challenge?.reference == reference && challenge?.authGeneration == authGeneration &&
                  authStatus == .pending && operationState == .authenticating && remainingMilliseconds > 0) else {
            throw SentryReturnFailure.invalidPayload
        }
        schemaVersion = 1; self.reference = reference; self.authGeneration = authGeneration; self.authStatus = authStatus
        self.operationState = operationState; self.code = code; self.challenge = challenge; self.remainingMilliseconds = remainingMilliseconds
        currentProtection = "notObserved"; nextPolicy = "parentAdmissionRequired"
    }
    public init(from decoder: Decoder) throws {
        try returnKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw SentryReturnFailure.unsupportedVersion }
        guard try c.decode(String.self, forKey: .currentProtection) == "notObserved",
              try c.decode(String.self, forKey: .nextPolicy) == "parentAdmissionRequired" else { throw SentryReturnFailure.invalidPayload }
        try self.init(reference: c.decode(SentryReturnReference.self, forKey: .reference),
            authGeneration: c.decodeIfPresent(String.self, forKey: .authGeneration),
            authStatus: c.decode(AuthStatus.self, forKey: .authStatus), operationState: c.decode(OperationState.self, forKey: .operationState),
            code: c.decode(Code.self, forKey: .code), challenge: c.decodeIfPresent(SentryReturnChallenge.self, forKey: .challenge),
            remainingMilliseconds: c.decode(Int.self, forKey: .remainingMilliseconds))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(reference, forKey: .reference)
        try c.encode(authGeneration, forKey: .authGeneration); try c.encode(authStatus, forKey: .authStatus)
        try c.encode(operationState, forKey: .operationState); try c.encode(code, forKey: .code)
        try c.encode(challenge, forKey: .challenge); try c.encode(remainingMilliseconds, forKey: .remainingMilliseconds)
        try c.encode(currentProtection, forKey: .currentProtection); try c.encode(nextPolicy, forKey: .nextPolicy)
    }
    public static func decodePayload(_ data: Data) throws -> Self {
        try ReturnJSON.validate(data, maximum: maximumPayload)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func encodedPayload() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try e.encode(self); _ = try Self.decodePayload(data); return data
    }
}

public struct SentryReturnCapability: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestKind, stateKind, requestMaxBytes, stateMaxBytes: Int
    public let macLocal, deviceBoundKey: Bool
    public let keyEnrollment: String
    public init(macLocal: Bool, deviceBoundKey: Bool) {
        schemaVersion = 1; requestKind = 223; stateKind = 224
        requestMaxBytes = SentryReturnControl.maximumPayload; stateMaxBytes = SentryReturnState.maximumPayload
        self.macLocal = macLocal; self.deviceBoundKey = deviceBoundKey; keyEnrollment = "macLocalRequired"
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, requestKind, stateKind, requestMaxBytes, stateMaxBytes, macLocal, deviceBoundKey, keyEnrollment
    }
    public init(from decoder: Decoder) throws {
        try returnKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1,
              try c.decode(Int.self, forKey: .requestKind) == 223, try c.decode(Int.self, forKey: .stateKind) == 224,
              try c.decode(Int.self, forKey: .requestMaxBytes) == SentryReturnControl.maximumPayload,
              try c.decode(Int.self, forKey: .stateMaxBytes) == SentryReturnState.maximumPayload,
              try c.decode(String.self, forKey: .keyEnrollment) == "macLocalRequired" else { throw SentryReturnFailure.invalidPayload }
        self.init(macLocal: try c.decode(Bool.self, forKey: .macLocal), deviceBoundKey: try c.decode(Bool.self, forKey: .deviceBoundKey))
    }
    public static func decodePayload(_ data: Data) throws -> Self {
        try ReturnJSON.validate(data, maximum: 1024)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

private enum ReturnOperation: String, Decodable { case request, current, cancel, prove, keyEnrollment }
private struct ReturnEnvelope: Decodable {
    let operation: ReturnOperation
    let requestID: String?
    let lease: SentryReturnLease?
    let authMode: SentryReturnAuthMode?
    let keyEnrollment: SentryReturnKeyEnrollment?
    let reference: SentryReturnReference?
    let authGeneration, signature: String?
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, operation, requestID, lease, authMode, keyEnrollment, reference, authGeneration, signature
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw SentryReturnFailure.unsupportedVersion }
        operation = try c.decode(ReturnOperation.self, forKey: .operation)
        let keys: Set<String>
        switch operation {
        case .request: keys = ["schemaVersion", "operation", "requestID", "lease", "authMode"]
        case .keyEnrollment: keys = ["schemaVersion", "operation", "requestID", "lease", "authMode", "keyEnrollment"]
        case .current: keys = ["schemaVersion", "operation", "reference"]
        case .cancel: keys = ["schemaVersion", "operation", "reference", "authGeneration"]
        case .prove: keys = ["schemaVersion", "operation", "reference", "authGeneration", "signature"]
        }
        try returnKeys(decoder, keys)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID); lease = try c.decodeIfPresent(SentryReturnLease.self, forKey: .lease)
        authMode = try c.decodeIfPresent(SentryReturnAuthMode.self, forKey: .authMode)
        keyEnrollment = try c.decodeIfPresent(SentryReturnKeyEnrollment.self, forKey: .keyEnrollment)
        reference = try c.decodeIfPresent(SentryReturnReference.self, forKey: .reference)
        authGeneration = try c.decodeIfPresent(String.self, forKey: .authGeneration); signature = try c.decodeIfPresent(String.self, forKey: .signature)
    }
}
private struct ReturnField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func returnKeys(_ decoder: Decoder, _ keys: Set<String>) throws {
    guard Set(try decoder.container(keyedBy: ReturnField.self).allKeys.map(\.stringValue)) == keys else {
        throw SentryReturnFailure.invalidPayload
    }
}
private func returnUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
private func returnHex(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
private func returnBase64(_ value: String) -> Data? {
    guard let bytes = Base64URL.decode(value), Base64URL.encode(bytes) == value else { return nil }; return bytes
}
private func returnObject<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
private func returnJSON(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}

/// JSONDecoder discards duplicate names, including escaped spellings. Reject them before decoding.
private struct ReturnJSON {
    let bytes: [UInt8]
    var index = 0
    static func validate(_ data: Data, maximum: Int) throws {
        guard data.count <= maximum else { throw SentryReturnFailure.payloadTooLarge }
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { throw SentryReturnFailure.invalidPayload }
        var scanner = Self(bytes: Array(data)); try scanner.value(depth: 0); scanner.space()
        guard scanner.index == scanner.bytes.count, data.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 else {
            throw SentryReturnFailure.invalidPayload
        }
    }
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) throws {
        space(); guard index < bytes.count, bytes[index] == byte else { throw SentryReturnFailure.invalidPayload }; index += 1
    }
    mutating func string() throws -> String {
        space(); let start = index; try take(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            if byte == 92 { guard index < bytes.count else { throw SentryReturnFailure.invalidPayload }; index += 1 }
        }
        throw SentryReturnFailure.invalidPayload
    }
    mutating func value(depth: Int) throws {
        space(); guard depth <= 8, index < bytes.count else { throw SentryReturnFailure.invalidPayload }
        if bytes[index] == 34 { _ = try string(); return }
        if bytes[index] == 123 {
            try take(123); space(); var names = Set<String>()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            while true {
                let name = try string(); guard names.insert(name).inserted else { throw SentryReturnFailure.invalidPayload }
                try take(58); try value(depth: depth + 1); space()
                guard index < bytes.count else { throw SentryReturnFailure.invalidPayload }
                if bytes[index] == 125 { index += 1; return }; try take(44)
            }
        }
        // This version has no arrays. Scalar grammar and types are checked by JSONDecoder.
        guard bytes[index] != 91 else { throw SentryReturnFailure.invalidPayload }
        let start = index
        while index < bytes.count, ![9, 10, 13, 32, 44, 125].contains(bytes[index]) { index += 1 }
        guard index > start else { throw SentryReturnFailure.invalidPayload }
    }
}
