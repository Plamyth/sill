import Foundation
import CryptoKit
import StreamProtocol

func signedPayloadChecks() throws {
    let host = P256.Signing.PrivateKey()
    let spki = SPKI.der(point: host.publicKey.x963Representation)
    let pin = P.hash(spki)
    let device = object(object(golden)["device"]!)
    let binding = try P.Binding(macID: MacID.make(fingerprint: pin), hostPin: pin,
        deviceSPKI: P.decode(text(device["publicSPKI"]!), maximum: 128))
    let now: Int64 = 1_800_000_000_000
    let challengeJSON: J = .object(["schema": .string("ccr.device-challenge/v1"),
        "challengeId": .string(Base64URL.encode(Data(repeating: 1, count: 32))),
        "nonce": .string(Base64URL.encode(Data(repeating: 2, count: 32))),
        "deviceId": .string(binding.deviceID), "origin": .string(P.origin), "expiresAt": .integer(now + 30_000)])
    let challenge = try P.Challenge(data(challengeJSON), binding: binding, now: now)
    let payload: J = .object(["schemaVersion": .integer(1), "purpose": .string("ccr-mobile-enrollment-v1"),
        "macID": .string(binding.macID), "macFingerprint": .string(Base64URL.encode(pin)),
        "deviceFingerprint": .string(Base64URL.encode(binding.deviceFingerprint)),
        "ownerPrincipal": .string(String(repeating: "b", count: 64)), "challengeId": .string(challenge.id),
        "nonce": .string(challenge.nonce), "origin": .string(P.origin),
        "issuedAt": .integer(now / 1000), "expiresAt": .integer(now / 1000 + 10)])
    func envelope(_ raw: Data, purpose: String = "ccr-mobile-enrollment-v1") throws -> J {
        let signature = try host.signature(for: Data((purpose + "\0").utf8) + raw).derRepresentation
        return .object(["payload": .string(Base64URL.encode(raw)), "signature": .string(Base64URL.encode(signature)),
            "publicSPKI": .string(Base64URL.encode(spki))])
    }
    func verify(_ value: J, challenge supplied: P.Challenge? = nil) throws -> P.Receipt {
        try P.Receipt(data(envelope(data(value))), challenge: supplied ?? challenge, binding: binding, now: now)
    }
    let valid = try verify(payload)
    try check(valid.expiresAt == now + 10_000, "메모리 Host 유효 서명 기준 사례")
    let changes: [(String, J)] = [
        ("schemaVersion", .integer(2)), ("schemaVersion", .string("1")), ("schemaVersion", .bool(true)),
        ("schemaVersion", .number("1.0")), ("schemaVersion", .number("1e0")), ("schemaVersion", .null),
        ("purpose", .string("other-purpose")), ("purpose", .bool(true)), ("purpose", .null),
        ("macID", .string("0000000000000000")), ("macID", .integer(1)),
        ("macFingerprint", .string(Base64URL.encode(Data(repeating: 3, count: 32)))),
        ("deviceFingerprint", .string(Base64URL.encode(Data(repeating: 4, count: 32)))),
        ("ownerPrincipal", .string(String(repeating: "A", count: 64))),
        ("ownerPrincipal", .string(String(repeating: "b", count: 63))),
        ("ownerPrincipal", .string(String(repeating: "b", count: 65))), ("ownerPrincipal", .bool(true)),
        ("challengeId", .string(Base64URL.encode(Data(repeating: 5, count: 32)))),
        ("nonce", .string(Base64URL.encode(Data(repeating: 6, count: 32)))),
        ("origin", .string("https://other.invalid:10443")), ("origin", .string(P.origin + "/")),
        ("origin", .array([])), ("issuedAt", .bool(true)), ("issuedAt", .string("1800000000")),
        ("issuedAt", .number("1800000000.0")), ("issuedAt", .number("18e8")), ("issuedAt", .null),
        ("issuedAt", .integer(now / 1000 + 2)), ("issuedAt", .number("-1")),
        ("expiresAt", .integer(now / 1000)), ("expiresAt", .integer(now / 1000 + 11)),
        ("expiresAt", .bool(true)), ("expiresAt", .number("1800000010.0")),
        ("expiresAt", .string("1800000010")), ("expiresAt", .null),
        ("expiresAt", .integer(9_007_199_254_741)), ("expiresAt", .number("9007199254740992")),
        ("unknown", .string("extra"))]
    for (key, value) in changes {
        let raw = data(changed(payload, key, value))
        let signed = try envelope(raw)
        let parts = object(signed)
        let sig = try P.decode(text(parts["signature"]!), maximum: 72)
        try check(try P.publicKey(spki).isValidSignature(P.signature(sig), for: Data("ccr-mobile-enrollment-v1\0".utf8) + raw), "잘못된 payload도 실제 유효 Host 서명 \(key)")
        reject("유효 서명 뒤 payload 가드 \(key)") { _ = try P.Receipt(data(signed), challenge: challenge, binding: binding, now: now) }
    }
    var missing = object(payload); missing.removeValue(forKey: "ownerPrincipal")
    reject("유효 서명 필수 필드 누락") { _ = try verify(.object(missing)) }
    let payloadText = try payload.canonical()
    for duplicate in [",\"schemaVersion\":1", ",\"\\u0073chemaVersion\":1", ",\"origin\":\"" + P.origin + "\""] {
        let raw = Data((String(payloadText.dropLast()) + duplicate + "}").utf8)
        let signed = try envelope(raw)
        reject("유효 서명 중복 payload 키") { _ = try P.Receipt(data(signed), challenge: challenge, binding: binding, now: now) }
    }
    let short = try P.Challenge(data(changed(challengeJSON, "expiresAt", .integer(now + 5000))), binding: binding, now: now)
    reject("유효 서명 원 challenge expiry 상한") { _ = try verify(payload, challenge: short) }
    let old = changed(changed(payload, "issuedAt", .integer(now / 1000 - 20)), "expiresAt", .integer(now / 1000 - 10))
    reject("유효 서명 만료 payload") { _ = try verify(old) }
    let otherPurpose = try envelope(data(payload), purpose: "ccr-mobile-device-proof-v1")
    reject("다른 목적의 유효 서명") { _ = try P.Receipt(data(otherPurpose), challenge: challenge, binding: binding, now: now) }

    let canonical = try envelope(data(payload))
    for field in ["payload", "signature", "publicSPKI"] {
        let value = object(canonical)[field]!
        reject("canonical base64url 패딩 거절 \(field)") {
            _ = try P.Receipt(data(changed(canonical, field, .string(try value.text() + "="))), challenge: challenge, binding: binding, now: now)
        }
    }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    let encoded = Base64URL.encode(spki)
    var noncanonical = Array(encoded)
    noncanonical[noncanonical.count - 1] = alphabet[alphabet.firstIndex(of: noncanonical.last!)! | 1]
    reject("canonical base64url의 사용하지 않는 비트") { _ = try P.decode(String(noncanonical), maximum: 128) }
    for invalid in ["_w==", "_x", "A", "+w", "/w", "_w\n"] {
        reject("base64url 어휘·길이·정규화") { _ = try P.decode(invalid, maximum: 128) }
    }
    let canonicalSignature = try host.signature(for: Data([1])).derRepresentation
    let nonminimal = Data([0x30, 0x81, canonicalSignature[1]]) + canonicalSignature.dropFirst(2)
    for invalid in [Data(), Data([0x30, 0]), Data(canonicalSignature.dropLast()), canonicalSignature + Data([0]), nonminimal] {
        reject("DER signature 자체 정규화 가드") { _ = try P.signature(invalid) }
    }
    var otherCurve = spki; otherCurve[22] ^= 1
    var invalidPoint = spki; invalidPoint.replaceSubrange(26..<91, with: Data(repeating: 0, count: 65))
    for invalid in [Data(), spki + Data([0]), Data(spki.dropLast()), otherCurve, invalidPoint,
                    SPKI.der(point: Data([2]) + Data(repeating: 0, count: 32))] {
        reject("P256 SPKI 자체 길이·OID·점 가드") { _ = try P.publicKey(invalid) }
    }
}
