import Foundation
import CryptoKit

/// 순수 wire 계약이다. 이 타입의 생성·서명 성공은 TLS admission이나 owner 등록 인가가 아니다.
public enum MobileEnrollment {
    public static let purpose = "ccr-mobile-enrollment-v1"
    public static let hostIdentityPurpose = "ccr-enrollment-host-identity-v1"
    public static let activeResultPurpose = "ccr-enrollment-active-result-v1"
    public static let origin = "https://macbookpro-1.tail88d92e.ts.net:10443"
    public static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    public static let maximumClockSkewMilliseconds: Int64 = 1000
    public enum Failure: Error { case invalidFields, invalidKey, identityMismatch, invalidTime, invalidSignature }

    public struct Fingerprint: Equatable, Sendable {
        public let bytes: Data
        public var base64URL: String { Base64URL.encode(bytes) }
        public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
        public init(base64URL: String) throws { bytes = try canonicalBytes(base64URL, count: 32) }
        public init(spkiDER: Data) throws {
            _ = try publicKey(spkiDER)
            bytes = Data(SHA256.hash(data: spkiDER))
        }
    }

    public struct HostProfile: Sendable {
        public let macID: String
        public let fingerprint: Fingerprint
        public let publicSPKIDER: Data
        /// pin은 서명된 정본 profile 또는 실제 fd의 PeerAnchor 검증 경계에서 이미 신뢰한 값이어야 한다.
        public init(macID: String, trustedFingerprint: String, publicSPKIDER: Data) throws {
            let pin = try Fingerprint(base64URL: trustedFingerprint)
            guard try Fingerprint(spkiDER: publicSPKIDER) == pin,
                  MacID.make(fingerprint: pin.bytes) == macID else { throw Failure.identityMismatch }
            self.macID = macID; fingerprint = pin; self.publicSPKIDER = publicSPKIDER
        }
    }

    public struct InitialChallenge: Encodable, Sendable {
        public let schema = "ccr.device-challenge/v1"
        public let challengeId: String
        public let nonce: String
        public let deviceId: String
        public let origin: String
        /// epoch 밀리초. HTTP parser 및 challenge 소비 원장은 호출자 소유다.
        public let expiresAt: Int64
        public init(challengeId: String, nonce: String, deviceId: String, origin: String,
                    expiresAtMilliseconds: Int64) throws {
            _ = try canonicalBytes(challengeId, count: 32)
            _ = try canonicalBytes(nonce, count: 32)
            try lowerHex(deviceId)
            try approvedOrigin(origin)
            try safeTime(expiresAtMilliseconds)
            self.challengeId = challengeId; self.nonce = nonce; self.deviceId = deviceId
            self.origin = origin; expiresAt = expiresAtMilliseconds
        }
    }

    public struct ReceiptInput: Sendable {
        public let host: HostProfile
        public let challenge: InitialChallenge
        public let devicePublicSPKIDER: Data
        public let deviceFingerprint: Fingerprint
        public let ownerPrincipal: String
        public let nowMilliseconds: Int64
        public let issuedAtSeconds: Int64
        public let nodeExpiresAtSeconds: Int64
        /// socketDeviceFingerprint와 ownerPrincipal은 실제 검증한 TLS·owner 경계가 공급한다.
        public init(host: HostProfile, challenge: InitialChallenge, devicePublicSPKIDER: Data,
                    socketDeviceFingerprint: String, ownerPrincipal: String,
                    nowMilliseconds: Int64, nodeExpiresAtSeconds: Int64) throws {
            let fingerprint = try Fingerprint(spkiDER: devicePublicSPKIDER)
            guard try Fingerprint(base64URL: socketDeviceFingerprint) == fingerprint,
                  fingerprint.hex == challenge.deviceId else { throw Failure.identityMismatch }
            try lowerHex(ownerPrincipal)
            try safeTime(nowMilliseconds); try safeTime(nodeExpiresAtSeconds)
            let issuedAtSeconds = nowMilliseconds / 1000
            let remaining = challenge.expiresAt.subtractingReportingOverflow(nowMilliseconds)
            guard !remaining.overflow, remaining.partialValue > 0,
                  remaining.partialValue <= 30_000 + maximumClockSkewMilliseconds,
                  nodeExpiresAtSeconds > issuedAtSeconds else { throw Failure.invalidTime }
            self.host = host; self.challenge = challenge; self.devicePublicSPKIDER = devicePublicSPKIDER
            deviceFingerprint = fingerprint; self.ownerPrincipal = ownerPrincipal
            self.nowMilliseconds = nowMilliseconds
            self.issuedAtSeconds = issuedAtSeconds; self.nodeExpiresAtSeconds = nodeExpiresAtSeconds
            _ = try payload()
        }

        public func payload() throws -> Payload {
            let tenSeconds = try adding(issuedAtSeconds, 10)
            let expiry = min(challenge.expiresAt / 1000, nodeExpiresAtSeconds, tenSeconds)
            guard expiry > issuedAtSeconds else { throw Failure.invalidTime }
            return Payload(macID: host.macID, macFingerprint: host.fingerprint.base64URL,
                deviceFingerprint: deviceFingerprint.base64URL, ownerPrincipal: ownerPrincipal,
                challengeId: challenge.challengeId, nonce: challenge.nonce, origin: challenge.origin,
                issuedAt: issuedAtSeconds, expiresAt: expiry)
        }
    }

    public struct Payload: Encodable, Equatable, Sendable {
        public let schemaVersion = 1
        public let purpose = MobileEnrollment.purpose
        public let macID: String
        public let macFingerprint: String
        public let deviceFingerprint: String
        public let ownerPrincipal: String
        public let challengeId: String
        public let nonce: String
        public let origin: String
        public let issuedAt: Int64
        public let expiresAt: Int64
        fileprivate init(macID: String, macFingerprint: String, deviceFingerprint: String, ownerPrincipal: String,
                         challengeId: String, nonce: String, origin: String, issuedAt: Int64, expiresAt: Int64) {
            self.macID = macID; self.macFingerprint = macFingerprint; self.deviceFingerprint = deviceFingerprint
            self.ownerPrincipal = ownerPrincipal; self.challengeId = challengeId; self.nonce = nonce
            self.origin = origin; self.issuedAt = issuedAt; self.expiresAt = expiresAt
        }
    }

    public struct Envelope: Encodable, Sendable {
        public let payload: String
        public let signature: String
        public let publicSPKI: String
        public init(payload: String, signature: String, publicSPKI: String) {
            self.payload = payload; self.signature = signature; self.publicSPKI = publicSPKI
        }
        public static func decode(_ rawJSON: Data) throws -> Envelope {
            let object = try FlatJSON(rawJSON, keys: ["payload", "signature", "publicSPKI"])
            let envelope = Envelope(payload: try object.string("payload"), signature: try object.string("signature"),
                                    publicSPKI: try object.string("publicSPKI"))
            _ = try envelope.parts()
            return envelope
        }
        public func parts() throws -> (payload: Data, signature: Data, spki: Data) {
            guard let payload = Base64URL.decode(payload), !payload.isEmpty, payload.count <= 16_384,
                  let signature = Base64URL.decode(signature), let spki = Base64URL.decode(publicSPKI) else {
                throw Failure.invalidFields
            }
            _ = try publicKey(spki)
            _ = try derSignature(signature)
            return (payload, signature, spki)
        }
    }

    public struct VerifiedReceipt: Sendable {
        public let payload: Payload
        public let payloadJSON: Data
        public let hostSignatureDER: Data
        public let hostSPKIDER: Data
        fileprivate init(payload: Payload, parts: (payload: Data, signature: Data, spki: Data)) {
            self.payload = payload; payloadJSON = parts.payload
            hostSignatureDER = parts.signature; hostSPKIDER = parts.spki
        }
        public var deviceProofBytes: Data {
            Data("ccr-mobile-device-proof-v1\0".utf8) + Data(SHA256.hash(data: payloadJSON))
                + Data(SHA256.hash(data: hostSignatureDER)) + Data(SHA256.hash(data: hostSPKIDER))
        }
        public func verifyDeviceProof(signature: String, devicePublicSPKIDER: Data) throws {
            guard try Fingerprint(spkiDER: devicePublicSPKIDER).base64URL == payload.deviceFingerprint,
                  let bytes = Base64URL.decode(signature),
                  try publicKey(devicePublicSPKIDER).isValidSignature(derSignature(bytes), for: deviceProofBytes) else {
                throw Failure.invalidSignature
            }
        }
    }

    public static func verifyReceipt(_ envelope: Envelope, expected: ReceiptInput,
                                     nowMilliseconds: Int64) throws -> VerifiedReceipt {
        let parts = try envelope.parts()
        let object = try FlatJSON(parts.payload, keys: ["schemaVersion", "purpose", "macID", "macFingerprint",
            "deviceFingerprint", "ownerPrincipal", "challengeId", "nonce", "origin", "issuedAt", "expiresAt"])
        guard try object.integer("schemaVersion") == 1, try object.string("purpose") == purpose else {
            throw Failure.invalidFields
        }
        let payload = Payload(macID: try object.string("macID"), macFingerprint: try object.string("macFingerprint"),
            deviceFingerprint: try object.string("deviceFingerprint"), ownerPrincipal: try object.string("ownerPrincipal"),
            challengeId: try object.string("challengeId"), nonce: try object.string("nonce"), origin: try object.string("origin"),
            issuedAt: try object.integer("issuedAt"), expiresAt: try object.integer("expiresAt"))
        let bound = try expected.payload()
        guard payload.macID == bound.macID, payload.macFingerprint == bound.macFingerprint,
              payload.deviceFingerprint == bound.deviceFingerprint, payload.ownerPrincipal == bound.ownerPrincipal,
              payload.challengeId == bound.challengeId, payload.nonce == bound.nonce, payload.origin == bound.origin,
              payload.issuedAt == bound.issuedAt, payload.expiresAt <= bound.expiresAt else { throw Failure.identityMismatch }
        try receiptTime(issued: payload.issuedAt, expires: payload.expiresAt, now: nowMilliseconds)
        try verify(envelope, purpose: purpose, host: expected.host)
        return VerifiedReceipt(payload: payload, parts: parts)
    }

    public struct HostAttach: Encodable, Sendable {
        public let schemaVersion = 1
        public let op = "enrollment.host.attach"
        public init() {}
    }

    public struct HostChallenge: Encodable, Equatable, Sendable {
        public let schemaVersion = 1
        public let op = "enrollment.host.challenge"
        public let coreGeneration: String
        public let nonce: String
        public let origin: String
        public init(coreGeneration: String, nonce: String, origin: String) throws {
            try canonicalUUID(coreGeneration); _ = try canonicalBytes(nonce, count: 32); try approvedOrigin(origin)
            self.coreGeneration = coreGeneration; self.nonce = nonce; self.origin = origin
        }
    }

    public struct HostIdentityPayload: Encodable, Sendable {
        public let schemaVersion = 1
        public let purpose = MobileEnrollment.hostIdentityPurpose
        public let coreGeneration: String
        public let nonce: String
        public let origin: String
        public let macID: String
        public let macFingerprint: String
        public init(challenge: HostChallenge, host: HostProfile) {
            coreGeneration = challenge.coreGeneration; nonce = challenge.nonce; origin = challenge.origin
            macID = host.macID; macFingerprint = host.fingerprint.base64URL
        }
    }

    public static func decodeHostChallenge(_ rawJSON: Data) throws -> HostChallenge {
        let object = try FlatJSON(rawJSON, keys: ["schemaVersion", "op", "coreGeneration", "nonce", "origin"])
        guard try object.integer("schemaVersion") == 1,
              try object.string("op") == "enrollment.host.challenge" else { throw Failure.invalidFields }
        return try HostChallenge(coreGeneration: object.string("coreGeneration"), nonce: object.string("nonce"),
                                 origin: object.string("origin"))
    }

    public struct HostIdentityFrame: Encodable, Sendable {
        public let schemaVersion = 1
        public let op = "enrollment.host.identity"
        public let envelope: Envelope
        public init(envelope: Envelope) { self.envelope = envelope }
    }

    public static func verifyHostIdentity(_ envelope: Envelope, challenge: HostChallenge, host: HostProfile) throws {
        let parts = try envelope.parts()
        let object = try FlatJSON(parts.payload, keys: ["schemaVersion", "purpose", "coreGeneration", "nonce", "origin",
                                                      "macID", "macFingerprint"])
        guard try object.integer("schemaVersion") == 1, try object.string("purpose") == hostIdentityPurpose,
              try object.string("coreGeneration") == challenge.coreGeneration, try object.string("nonce") == challenge.nonce,
              try object.string("origin") == challenge.origin, try object.string("macID") == host.macID,
              try object.string("macFingerprint") == host.fingerprint.base64URL else { throw Failure.identityMismatch }
        try verify(envelope, purpose: hostIdentityPurpose, host: host)
    }

    public struct ActiveChallenge: Encodable, Sendable {
        public let schemaVersion = 1
        public let op = "enrollment.active.challenge"
        public let requestId: String
        public let coreGeneration: String
        public let nonce: String
        public let origin: String
        public let deviceFingerprint: String
        public let ownerPrincipal: String
        public let requestDigest: String
        public let deadline: Int64
        fileprivate let receivedAtMilliseconds: Int64
        private enum CodingKeys: String, CodingKey {
            case schemaVersion, op, requestId, coreGeneration, nonce, origin, deviceFingerprint, ownerPrincipal, requestDigest, deadline
        }
        public init(requestId: String, coreGeneration: String, nonce: String, origin: String,
                    deviceFingerprint: String, ownerPrincipal: String, requestDigest: String,
                    deadlineMilliseconds: Int64, receivedAtMilliseconds: Int64) throws {
            try canonicalUUID(requestId); try canonicalUUID(coreGeneration)
            _ = try canonicalBytes(nonce, count: 32); try approvedOrigin(origin)
            _ = try Fingerprint(base64URL: deviceFingerprint); try lowerHex(ownerPrincipal); try lowerHex(requestDigest)
            try safeTime(deadlineMilliseconds); try safeTime(receivedAtMilliseconds)
            guard deadlineMilliseconds > receivedAtMilliseconds,
                  deadlineMilliseconds - receivedAtMilliseconds <= 1500 else { throw Failure.invalidTime }
            let digestBytes = try activeRequestBytes(coreGeneration: coreGeneration, requestId: requestId, nonce: nonce,
                deviceFingerprint: deviceFingerprint, ownerPrincipal: ownerPrincipal, origin: origin,
                deadlineMilliseconds: deadlineMilliseconds)
            guard hexDigest(digestBytes) == requestDigest else { throw Failure.identityMismatch }
            self.requestId = requestId; self.coreGeneration = coreGeneration; self.nonce = nonce
            self.origin = origin; self.deviceFingerprint = deviceFingerprint; self.ownerPrincipal = ownerPrincipal
            self.requestDigest = requestDigest; deadline = deadlineMilliseconds
            self.receivedAtMilliseconds = receivedAtMilliseconds
        }
    }

    public static func activeRequestBytes(coreGeneration: String, requestId: String, nonce: String,
                                          deviceFingerprint: String, ownerPrincipal: String, origin: String,
                                          deadlineMilliseconds: Int64) throws -> Data {
        try canonicalUUID(coreGeneration); try canonicalUUID(requestId)
        _ = try canonicalBytes(nonce, count: 32); _ = try Fingerprint(base64URL: deviceFingerprint)
        try lowerHex(ownerPrincipal); try approvedOrigin(origin); try safeTime(deadlineMilliseconds)
        return try JSONSerialization.data(withJSONObject: [1, coreGeneration, requestId, nonce,
            deviceFingerprint, ownerPrincipal, origin, deadlineMilliseconds] as [Any], options: [.withoutEscapingSlashes])
    }

    public static func decodeActiveChallenge(_ rawJSON: Data, receivedAtMilliseconds: Int64) throws -> ActiveChallenge {
        let object = try FlatJSON(rawJSON, keys: ["schemaVersion", "op", "requestId", "coreGeneration", "nonce", "origin",
            "deviceFingerprint", "ownerPrincipal", "requestDigest", "deadline"])
        guard try object.integer("schemaVersion") == 1,
              try object.string("op") == "enrollment.active.challenge" else { throw Failure.invalidFields }
        return try ActiveChallenge(requestId: object.string("requestId"), coreGeneration: object.string("coreGeneration"),
            nonce: object.string("nonce"), origin: object.string("origin"), deviceFingerprint: object.string("deviceFingerprint"),
            ownerPrincipal: object.string("ownerPrincipal"), requestDigest: object.string("requestDigest"),
            deadlineMilliseconds: object.integer("deadline"), receivedAtMilliseconds: receivedAtMilliseconds)
    }

    public static func hexDigest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public enum ActiveReason: String, Encodable, Sendable, CaseIterable {
        case active, revoked, notRegistered, identityChanged, disabled, unavailable
        public var gatewayFailure: (status: Int, code: String)? {
            switch self {
            case .active: return nil
            case .unavailable: return (503, "ENROLLMENT_PROVIDER_UNAVAILABLE")
            case .revoked: return (403, "DEVICE_REVOKED")
            case .notRegistered, .identityChanged, .disabled: return (403, "OWNER_TRUST_DENIED")
            }
        }
    }

    /// reason은 호출자가 실제 registry에서 관측한 결과다. 이 타입은 조회나 Tailnet 검증을 수행하지 않는다.
    public struct ActiveResultPayload: Encodable, Sendable {
        public let schemaVersion = 1
        public let purpose = MobileEnrollment.activeResultPurpose
        public let requestId: String
        public let coreGeneration: String
        public let nonce: String
        public let origin: String
        public let requestDigest: String
        public let macFingerprint: String
        public let deviceFingerprint: String
        public let ownerPrincipal: String
        public let active: Bool
        public let reason: ActiveReason
        public let checkedAt: Int64
        public let expiresAt: Int64
        public init(challenge: ActiveChallenge, host: HostProfile, reason: ActiveReason,
                    checkedAtMilliseconds: Int64, expiresAtMilliseconds: Int64, nowMilliseconds: Int64) throws {
            try activeTime(challenge: challenge, checked: checkedAtMilliseconds, expires: expiresAtMilliseconds,
                           now: nowMilliseconds)
            requestId = challenge.requestId; coreGeneration = challenge.coreGeneration; nonce = challenge.nonce
            origin = challenge.origin; requestDigest = challenge.requestDigest
            macFingerprint = host.fingerprint.base64URL; deviceFingerprint = challenge.deviceFingerprint
            ownerPrincipal = challenge.ownerPrincipal; active = reason == .active; self.reason = reason
            checkedAt = checkedAtMilliseconds; expiresAt = expiresAtMilliseconds
        }
        public func validate(challenge: ActiveChallenge, host: HostProfile, nowMilliseconds: Int64) throws {
            guard requestId == challenge.requestId, coreGeneration == challenge.coreGeneration, nonce == challenge.nonce,
                  origin == challenge.origin, requestDigest == challenge.requestDigest,
                  macFingerprint == host.fingerprint.base64URL, deviceFingerprint == challenge.deviceFingerprint,
                  ownerPrincipal == challenge.ownerPrincipal else { throw Failure.identityMismatch }
            try activeTime(challenge: challenge, checked: checkedAt, expires: expiresAt, now: nowMilliseconds)
        }
    }

    public struct ActiveResultFrame: Encodable, Sendable {
        public let schemaVersion = 1
        public let op = "enrollment.active.result"
        public let envelope: Envelope
        public init(envelope: Envelope) { self.envelope = envelope }
    }

    public static func verifyActiveResult(_ envelope: Envelope, challenge: ActiveChallenge, host: HostProfile,
                                         nowMilliseconds: Int64) throws -> ActiveResultPayload {
        let parts = try envelope.parts()
        let object = try FlatJSON(parts.payload, keys: ["schemaVersion", "purpose", "requestId", "coreGeneration", "nonce",
            "origin", "requestDigest", "macFingerprint", "deviceFingerprint", "ownerPrincipal", "active", "reason",
            "checkedAt", "expiresAt"])
        guard try object.integer("schemaVersion") == 1, try object.string("purpose") == activeResultPurpose,
              try object.string("requestId") == challenge.requestId, try object.string("coreGeneration") == challenge.coreGeneration,
              try object.string("nonce") == challenge.nonce, try object.string("origin") == challenge.origin,
              try object.string("requestDigest") == challenge.requestDigest, try object.string("macFingerprint") == host.fingerprint.base64URL,
              try object.string("deviceFingerprint") == challenge.deviceFingerprint,
              try object.string("ownerPrincipal") == challenge.ownerPrincipal else { throw Failure.identityMismatch }
        guard let reason = ActiveReason(rawValue: try object.string("reason")),
              try object.boolean("active") == (reason == .active) else { throw Failure.invalidFields }
        let payload = try ActiveResultPayload(challenge: challenge, host: host,
            reason: reason, checkedAtMilliseconds: object.integer("checkedAt"),
            expiresAtMilliseconds: object.integer("expiresAt"), nowMilliseconds: nowMilliseconds)
        try verify(envelope, purpose: activeResultPurpose, host: host)
        return payload
    }

    private static func verify(_ envelope: Envelope, purpose: String, host: HostProfile) throws {
        let parts = try envelope.parts()
        guard parts.spki == host.publicSPKIDER,
              try publicKey(parts.spki).isValidSignature(derSignature(parts.signature),
                  for: Data((purpose + "\0").utf8) + parts.payload) else { throw Failure.invalidSignature }
    }
    private static func canonicalBytes(_ text: String, count: Int) throws -> Data {
        guard let bytes = Base64URL.decode(text), bytes.count == count else { throw Failure.invalidFields }
        return bytes
    }
    private static func lowerHex(_ text: String) throws {
        guard text.utf8.count == 64, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidFields
        }
    }
    private static func canonicalUUID(_ text: String) throws {
        guard let uuid = UUID(uuidString: text), uuid.uuidString.lowercased() == text else { throw Failure.invalidFields }
    }
    private static func approvedOrigin(_ value: String) throws {
        guard value == origin else { throw Failure.invalidFields }
    }
    private static func publicKey(_ der: Data) throws -> P256.Signing.PublicKey {
        guard der.count == 91 else { throw Failure.invalidKey }
        let key = try P256.Signing.PublicKey(derRepresentation: der)
        guard SPKI.der(point: key.x963Representation) == der else { throw Failure.invalidKey }
        return key
    }
    private static func derSignature(_ der: Data) throws -> P256.Signing.ECDSASignature {
        guard (8...72).contains(der.count) else { throw Failure.invalidSignature }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        guard signature.derRepresentation == der else { throw Failure.invalidSignature }
        return signature
    }
    private static func safeTime(_ time: Int64) throws {
        guard time >= 0, time <= maximumSafeInteger else { throw Failure.invalidTime }
    }
    private static func adding(_ value: Int64, _ delta: Int64) throws -> Int64 {
        let result = value.addingReportingOverflow(delta)
        guard !result.overflow else { throw Failure.invalidTime }
        try safeTime(result.partialValue)
        return result.partialValue
    }
    private static func milliseconds(seconds: Int64) throws -> Int64 {
        try safeTime(seconds)
        let result = seconds.multipliedReportingOverflow(by: 1000)
        guard !result.overflow else { throw Failure.invalidTime }
        try safeTime(result.partialValue)
        return result.partialValue
    }
    private static func receiptTime(issued: Int64, expires: Int64, now: Int64) throws {
        try safeTime(now)
        let issuedMS = try milliseconds(seconds: issued), expiresMS = try milliseconds(seconds: expires)
        guard expires > issued, expires - issued <= 10, now < expiresMS,
              issuedMS <= (try adding(now, maximumClockSkewMilliseconds)) else { throw Failure.invalidTime }
    }
    private static func activeTime(challenge: ActiveChallenge, checked: Int64, expires: Int64, now: Int64) throws {
        try safeTime(checked); try safeTime(expires); try safeTime(now)
        guard now >= challenge.receivedAtMilliseconds, checked >= challenge.receivedAtMilliseconds,
              now < challenge.deadline, checked < challenge.deadline,
              checked <= (try adding(now, maximumClockSkewMilliseconds)),
              expires > checked, expires - checked <= 2000, now < expires else { throw Failure.invalidTime }
    }

    /// 이 wire의 객체는 flat scalar뿐이다. 키의 escape를 해석한 뒤 중복·unknown·비정수 숫자를 거부한다.
    private struct FlatJSON {
        enum Value { case string(String), integer(Int64), boolean(Bool) }
        let values: [String: Value]
        init(_ data: Data, keys: Set<String>) throws {
            guard !data.isEmpty, data.count <= 16_384, String(data: data, encoding: .utf8) != nil else {
                throw Failure.invalidFields
            }
            var scanner = ScalarScanner(bytes: Array(data))
            values = try scanner.object()
            guard Set(values.keys) == keys else { throw Failure.invalidFields }
        }
        func string(_ key: String) throws -> String {
            guard case .string(let value) = values[key] else { throw Failure.invalidFields }; return value
        }
        func integer(_ key: String) throws -> Int64 {
            guard case .integer(let value) = values[key] else { throw Failure.invalidFields }; return value
        }
        func boolean(_ key: String) throws -> Bool {
            guard case .boolean(let value) = values[key] else { throw Failure.invalidFields }; return value
        }
    }
    private struct ScalarScanner {
        let bytes: [UInt8]
        var offset = 0
        mutating func whitespace() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        mutating func take(_ byte: UInt8) throws {
            whitespace()
            guard offset < bytes.count, bytes[offset] == byte else { throw Failure.invalidFields }; offset += 1
        }
        mutating func string() throws -> String {
            whitespace(); let start = offset; try take(34)
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                if byte == 92 { guard offset < bytes.count else { throw Failure.invalidFields }; offset += 1 }
            }
            throw Failure.invalidFields
        }
        mutating func value() throws -> FlatJSON.Value {
            whitespace()
            guard offset < bytes.count else { throw Failure.invalidFields }
            if bytes[offset] == 34 { return .string(try string()) }
            let start = offset
            while offset < bytes.count, ![9, 10, 13, 32, 44, 125].contains(bytes[offset]) { offset += 1 }
            let text = String(decoding: bytes[start..<offset], as: UTF8.self)
            if text == "true" { return .boolean(true) }
            if text == "false" { return .boolean(false) }
            guard text.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
                  text != "-0", let number = Int64(text) else { throw Failure.invalidFields }
            return .integer(number)
        }
        mutating func object() throws -> [String: FlatJSON.Value] {
            try take(123)
            var values: [String: FlatJSON.Value] = [:]
            while true {
                let key = try string()
                guard values[key] == nil else { throw Failure.invalidFields }
                try take(58); values[key] = try value(); whitespace()
                guard offset < bytes.count else { throw Failure.invalidFields }
                if bytes[offset] == 125 { offset += 1; break }
                try take(44)
            }
            whitespace()
            guard offset == bytes.count else { throw Failure.invalidFields }
            return values
        }
    }
}
