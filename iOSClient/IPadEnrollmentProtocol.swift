import Foundation
import CryptoKit
import StreamProtocol

enum IPadEnrollmentProtocol {
    static let origin = "https://macbookpro-1.tail88d92e.ts.net:10443"
    static let skew: Int64 = 1000
    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func hex64(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func decode(_ text: String, maximum: Int, count: Int? = nil) throws -> Data {
        guard text.utf8.count <= (maximum * 4 + 2) / 3, !text.isEmpty,
              let bytes = Base64URL.decode(text), !bytes.isEmpty, bytes.count <= maximum,
              count == nil || bytes.count == count, Base64URL.encode(bytes) == text else { throw IPadEnrollmentFailure.invalid }
        return bytes
    }
    static func publicKey(_ spki: Data) throws -> P256.Signing.PublicKey {
        let prefix = Data([0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,
                           0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00])
        guard spki.count == 91, spki.prefix(prefix.count) == prefix else { throw IPadEnrollmentFailure.invalid }
        return try P256.Signing.PublicKey(x963Representation: spki.dropFirst(prefix.count))
    }
    static func signature(_ data: Data) throws -> P256.Signing.ECDSASignature {
        let value = try P256.Signing.ECDSASignature(derRepresentation: data)
        guard value.derRepresentation == data else { throw IPadEnrollmentFailure.invalid }
        return value
    }

    struct Binding: Hashable {
        let macID: String
        let hostPin: Data
        let deviceSPKI: Data
        var deviceFingerprint: Data { IPadEnrollmentProtocol.hash(deviceSPKI) }
        var deviceID: String { hex(deviceFingerprint) }
        var json: IPadEnrollmentJSON { .object(["origin": .string(origin), "macID": .string(macID),
            "hostPin": .string(Base64URL.encode(hostPin)), "deviceFingerprint": .string(Base64URL.encode(deviceFingerprint))]) }
        init(macID: String, hostPin: Data, deviceSPKI: Data) throws {
            guard hostPin.count == 32, MacID.make(fingerprint: hostPin) == macID else { throw IPadEnrollmentFailure.invalid }
            _ = try publicKey(deviceSPKI)
            self.macID = macID; self.hostPin = hostPin; self.deviceSPKI = deviceSPKI
        }
    }

    struct Challenge {
        let json: IPadEnrollmentJSON
        let id: String, nonce: String, deviceID: String
        let expiresAt: Int64
        init(_ raw: Data, binding: Binding, now: Int64? = nil) throws {
            json = try .parse(raw)
            let f = try json.fields(["schema", "challengeId", "nonce", "deviceId", "origin", "expiresAt"])
            guard try f.text("schema") == "ccr.device-challenge/v1", try f.text("origin") == origin,
                  try f.text("deviceId") == binding.deviceID else { throw IPadEnrollmentFailure.invalid }
            id = try f.text("challengeId"); nonce = try f.text("nonce"); deviceID = binding.deviceID
            _ = try decode(id, maximum: 32, count: 32); _ = try decode(nonce, maximum: 32, count: 32)
            expiresAt = try f.integer("expiresAt")
            guard expiresAt > 0 else { throw IPadEnrollmentFailure.invalid }
            if let now { try lifetime(expiresAt, now: now, maximum: 30_000) }
        }
    }

    struct Receipt {
        let envelope: IPadEnrollmentJSON
        let proofMessage: Data
        let expiresAt: Int64
        init(_ raw: Data, challenge: Challenge, binding: Binding, now: Int64) throws {
            envelope = try .parse(raw, limit: 16_384)
            let f = try envelope.fields(["payload", "signature", "publicSPKI"])
            let payload = try decode(f.text("payload"), maximum: 4096)
            let sig = try decode(f.text("signature"), maximum: 72)
            let spki = try decode(f.text("publicSPKI"), maximum: 128)
            guard hash(spki) == binding.hostPin,
                  try publicKey(spki).isValidSignature(signature(sig), for: Data("ccr-mobile-enrollment-v1\0".utf8) + payload) else {
                throw IPadEnrollmentFailure.invalid
            }
            let p = try IPadEnrollmentJSON.parse(payload).fields(["schemaVersion", "purpose", "macID", "macFingerprint",
                "deviceFingerprint", "ownerPrincipal", "challengeId", "nonce", "origin", "issuedAt", "expiresAt"])
            guard try p.integer("schemaVersion") == 1, try p.text("purpose") == "ccr-mobile-enrollment-v1",
                  try p.text("macID") == binding.macID, try p.text("challengeId") == challenge.id,
                  try p.text("nonce") == challenge.nonce, try p.text("origin") == origin,
                  try decode(p.text("macFingerprint"), maximum: 32, count: 32) == binding.hostPin,
                  try decode(p.text("deviceFingerprint"), maximum: 32, count: 32) == binding.deviceFingerprint,
                  try hex64(p.text("ownerPrincipal")) else { throw IPadEnrollmentFailure.invalid }
            let issued = try milliseconds(p.integer("issuedAt"))
            expiresAt = try milliseconds(p.integer("expiresAt"))
            guard now > 0, issued <= now + skew, expiresAt > issued, expiresAt - issued <= 10_000,
                  expiresAt <= challenge.expiresAt else { throw IPadEnrollmentFailure.invalid }
            guard expiresAt > now, challenge.expiresAt > now else { throw IPadEnrollmentFailure.invalid }
            proofMessage = Data("ccr-mobile-device-proof-v1\0".utf8) + hash(payload) + hash(sig) + hash(spki)
        }
    }

    struct Credential: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let binding: Binding
        let id: String
        let expiresAt: Int64
        private let token: String
        var description: String { "iPad 전용 등록 자격" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["credential": "비공개"]) }
        var tokenHash: String { hex(hash(Data(token.utf8))) }
        /// 보호 API 요청을 만드는 호출자만 사용한다. CanvasRelay의 자격과 독립적이다.
        var authorizationValue: String { "Bearer " + token }
        init(_ raw: Data, binding: Binding, observedAt: Int64) throws {
            let f = try IPadEnrollmentJSON.parse(raw).fields(["schema", "deviceId", "credentialId", "token", "expiresAt", "origin"])
            guard try f.text("schema") == "ccr.device-credential/v1", try f.text("deviceId") == binding.deviceID,
                  try f.text("origin") == origin else { throw IPadEnrollmentFailure.invalid }
            id = try f.text("credentialId"); token = try f.text("token"); expiresAt = try f.integer("expiresAt")
            guard !id.isEmpty, id.utf8.count <= 128,
                  id.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
                  hex64(token) else { throw IPadEnrollmentFailure.invalid }
            try lifetime(expiresAt, now: observedAt, maximum: 86_400_000)
            self.binding = binding
        }
    }

    struct Readback {
        let id: String
        let expiresAt: Int64
        let message: Data
        init(_ raw: Data, challenge: Challenge, digest: String, binding: Binding, now: Int64) throws {
            let f = try IPadEnrollmentJSON.parse(raw).fields(["schema", "challengeId", "readbackId", "nonce", "deviceId", "requestDigest", "origin", "expiresAt"])
            guard try f.text("schema") == "ccr.device-readback-challenge/v1", try f.text("challengeId") == challenge.id,
                  try f.text("deviceId") == binding.deviceID, try f.text("origin") == origin,
                  try f.text("requestDigest") == digest, hex64(digest) else { throw IPadEnrollmentFailure.invalid }
            id = try f.text("readbackId"); let nonce = try f.text("nonce")
            _ = try decode(id, maximum: 32, count: 32); _ = try decode(nonce, maximum: 32, count: 32)
            expiresAt = try f.integer("expiresAt"); try lifetime(expiresAt, now: now, maximum: 30_000)
            message = Data("ccr-mobile-credential-readback-v1\0".utf8) + (try IPadEnrollmentJSON.array([
                .string(origin), .string(challenge.id), .string(id), .string(nonce), .string(binding.deviceID), .string(digest), .integer(expiresAt)]).bytes())
        }
    }

    static func ownerRequest(_ challenge: Challenge, binding: Binding, name: String, model: String) throws -> Data {
        try IPadEnrollmentJSON.object(["v": .integer(2), "method": .string("owner-tailnet-v1"), "proof": .string(""),
            "name": .string(name), "model": .string(model), "ownerEnrollment": .object(["schemaVersion": .integer(1),
                "challenge": challenge.json, "devicePublicKey": .string(Base64URL.encode(binding.deviceSPKI))])]).bytes()
    }
    static func ownerReply(_ raw: Data, binding: Binding) throws -> Data {
        let f = try IPadEnrollmentJSON.parse(raw, limit: 16_384).fields(["ok", "method", "macID", "ownerEnrollmentVersion", "ownerReceipt"])
        guard f["ok"] == .bool(true), try f.text("method") == "owner-tailnet-v1", try f.text("macID") == binding.macID,
              try f.integer("ownerEnrollmentVersion") == 1, let receipt = f["ownerReceipt"] else { throw IPadEnrollmentFailure.invalid }
        _ = try receipt.fields(["payload", "signature", "publicSPKI"])
        return try receipt.bytes()
    }
    static func enroll(_ receipt: Receipt, challenge: Challenge, binding: Binding, signature sig: Data) throws -> Data {
        guard try publicKey(binding.deviceSPKI).isValidSignature(signature(sig), for: receipt.proofMessage) else { throw IPadEnrollmentFailure.invalid }
        return try IPadEnrollmentJSON.object(["schema": .string("ccr.device-enroll/v1"), "challengeId": .string(challenge.id),
            "devicePublicKey": .string(Base64URL.encode(binding.deviceSPKI)), "signature": .string(Base64URL.encode(sig)), "ownerReceipt": receipt.envelope]).bytes()
    }
    static func requestDigest(_ body: Data) throws -> String {
        let value = try IPadEnrollmentJSON.parse(body, limit: 16_384)
        let f = try value.fields(["schema", "challengeId", "devicePublicKey", "signature", "ownerReceipt"])
        guard try f.text("schema") == "ccr.device-enroll/v1", let receipt = f["ownerReceipt"] else { throw IPadEnrollmentFailure.invalid }
        for key in ["challengeId", "devicePublicKey", "signature"] { _ = try f.text(key) }
        let r = try receipt.fields(["payload", "signature", "publicSPKI"])
        for key in r.keys { _ = try r.text(key) }
        return hex(hash(try value.bytes()))
    }
    static func error(_ body: Data, status: Int) throws -> IPadEnrollmentFailure {
        let code = try IPadEnrollmentJSON.parse(body).fields(["error"]).text("error")
        let codes: [Int: Set<String>] = [400: ["ENROLLMENT_INVALID_REQUEST"],
            401: ["CREDENTIAL_REQUIRED", "CREDENTIAL_INVALID", "CREDENTIAL_EXPIRED"],
            403: ["ENROLLMENT_PROOF_INVALID", "DEVICE_REVOKED", "OWNER_TRUST_DENIED"],
            409: ["ENROLLMENT_IDENTITY_CHANGED", "CHALLENGE_CONFLICT", "ENROLLMENT_READBACK_REQUIRED"],
            410: ["ENROLLMENT_CHALLENGE_EXPIRED"], 429: ["ENROLLMENT_RATE_LIMITED"],
            503: ["ENROLLMENT_PROVIDER_UNAVAILABLE", "ENROLLMENT_STORAGE_UNAVAILABLE", "ENROLLMENT_NOT_READY"],
            404: ["ENROLLMENT_OPERATION_UNCONFIRMED"]]
        guard codes[status]?.contains(code) == true else { throw IPadEnrollmentFailure.invalid }
        return .server(status, code)
    }
    static func lifetime(_ expiry: Int64, now: Int64, maximum: Int64) throws {
        guard now > 0, now <= 9_007_199_254_740_991, expiry > now, expiry - now <= maximum + skew else { throw IPadEnrollmentFailure.invalid }
    }
    static func milliseconds(_ seconds: Int64) throws -> Int64 {
        guard seconds > 0, seconds <= 9_007_199_254_740 else { throw IPadEnrollmentFailure.invalid }
        return seconds * 1000
    }
}
