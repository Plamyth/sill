import Foundation
import CryptoKit
import Security
import StreamProtocol

@main
struct Checks {
    static var passed: [String] = []
    static func check(_ name: String, _ body: () throws -> Void) rethrows {
        try body(); passed.append(name)
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("거부하지 못함: \(name)") }
        catch { passed.append(name) }
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sharedFixture(_ path: String, validSemantics: Bool) throws -> [String: Any] {
        typealias M = MobileEnrollment
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let fixture = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let host = fixture["host"] as! [String: String], device = fixture["device"] as! [String: String]
        let enroll = fixture["enrollRequest"] as! [String: Any]
        let receipt = try M.Envelope.decode(JSONSerialization.data(withJSONObject: fixture["ownerReceipt"]!))
        let parts = try receipt.parts()
        let payload = try JSONSerialization.jsonObject(with: parts.payload) as! [String: Any]
        let deviceDER = Base64URL.decode(device["publicSPKI"]!)!
        let deviceSignature = Base64URL.decode(enroll["signature"] as! String)!
        let signingBytes = Data((M.purpose + "\0").utf8) + parts.payload
        let proofBytes = Data("ccr-mobile-device-proof-v1\0".utf8) + Data(SHA256.hash(data: parts.payload))
            + Data(SHA256.hash(data: parts.signature)) + Data(SHA256.hash(data: parts.spki))
        try check("공통 fixture raw host·device 서명과 해시 \(validSemantics)") {
            precondition(Base64URL.decode(host["signingMessage"]!) == signingBytes)
            precondition(Base64URL.decode(device["proofMessage"]!) == proofBytes)
            precondition(M.hexDigest(parts.payload) == host["payloadSha256"]!)
            precondition(M.hexDigest(parts.signature) == host["signatureSha256"]!)
            precondition(M.hexDigest(parts.spki) == host["spkiSha256"]!)
            precondition(M.hexDigest(signingBytes) == host["signingMessageSha256"]!)
            precondition(M.hexDigest(proofBytes) == device["proofMessageSha256"]!)
            precondition(M.hexDigest(deviceSignature) == device["signatureSha256"]!)
            let hostKey = try P256.Signing.PublicKey(derRepresentation: parts.spki)
            let deviceKey = try P256.Signing.PublicKey(derRepresentation: deviceDER)
            let hostSignature = try P256.Signing.ECDSASignature(derRepresentation: parts.signature)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: deviceSignature)
            precondition(hostKey.isValidSignature(hostSignature, for: signingBytes))
            precondition(deviceKey.isValidSignature(signature, for: proofBytes))
            let fingerprint = try M.Fingerprint(spkiDER: parts.spki)
            let deviceFingerprint = try M.Fingerprint(spkiDER: deviceDER)
            precondition(fingerprint.base64URL == host["fingerprintBase64url"]!)
            precondition(deviceFingerprint.base64URL == device["fingerprintBase64url"]!)
            precondition(deviceFingerprint.hex == device["spkiSha256"]!)
        }
        let now = (fixture["nowMs"] as! NSNumber).int64Value
        let challenge = fixture["challengeResponse"] as! [String: Any]
        let challengeType = try M.InitialChallenge(challengeId: challenge["challengeId"] as! String,
            nonce: challenge["nonce"] as! String, deviceId: challenge["deviceId"] as! String,
            origin: challenge["origin"] as! String, expiresAtMilliseconds: (challenge["expiresAt"] as! NSNumber).int64Value)
        let hostPin = try M.Fingerprint(spkiDER: parts.spki)
        let trustedProfile = try M.HostProfile(macID: MacID.make(fingerprint: hostPin.bytes),
            trustedFingerprint: host["fingerprintBase64url"]!, publicSPKIDER: parts.spki)
        let devicePin = try M.Fingerprint(spkiDER: deviceDER)
        if validSemantics {
            let input = try M.ReceiptInput(host: trustedProfile, challenge: challengeType, devicePublicSPKIDER: deviceDER,
                socketDeviceFingerprint: devicePin.base64URL, ownerPrincipal: payload["ownerPrincipal"] as! String,
                nowMilliseconds: now, nodeExpiresAtSeconds: now / 1000 + 60)
            let verified = try M.verifyReceipt(receipt, expected: input, nowMilliseconds: now)
            try verified.verifyDeviceProof(signature: enroll["signature"] as! String, devicePublicSPKIDER: deviceDER)
            check("v2 semantic 수용 및 원문 유지") { precondition(verified.payloadJSON == parts.payload) }
            let reencoded = try encoded(verified.payload)
            precondition(reencoded != parts.payload)
            rejects("v2 의미가 같아도 재직렬화한 서명은 거부") {
                _ = try M.verifyReceipt(M.Envelope(payload: Base64URL.encode(reencoded), signature: receipt.signature,
                    publicSPKI: receipt.publicSPKI), expected: input, nowMilliseconds: now)
            }
        } else {
            rejects("v1 UUID MacID semantic 거부") {
                _ = try M.HostProfile(macID: payload["macID"] as! String,
                    trustedFingerprint: hostPin.base64URL, publicSPKIDER: parts.spki)
            }
            rejects("v1 principal semantic 거부") {
                _ = try M.ReceiptInput(host: trustedProfile, challenge: challengeType, devicePublicSPKIDER: deviceDER,
                    socketDeviceFingerprint: devicePin.base64URL, ownerPrincipal: payload["ownerPrincipal"] as! String,
                    nowMilliseconds: now, nodeExpiresAtSeconds: now / 1000 + 60)
            }
        }
        return ["sha256": M.hexDigest(raw), "rawCryptoAccepted": true, "semanticAccepted": validSemantics,
                "fixtureClockMilliseconds": now, "runtimeAccepted": false]
    }

    static func main() throws {
        typealias M = MobileEnrollment
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let hostKey = RemoteKey.generate()!, deviceKey = RemoteKey.generate()!, otherKey = RemoteKey.generate()!
        let identity = HostIdentity(privateKey: hostKey, recognitionKey: Data(repeating: 0, count: 32))!
        let hostDER = SPKI.der(point: RemoteKey.publicPoint(hostKey)!)
        let deviceDER = SPKI.der(point: RemoteKey.publicPoint(deviceKey)!)
        let otherDER = SPKI.der(point: RemoteKey.publicPoint(otherKey)!)
        let host = try M.HostProfile(macID: identity.macID, trustedFingerprint: Base64URL.encode(identity.fingerprint),
                                     publicSPKIDER: hostDER)
        let device = try M.Fingerprint(spkiDER: deviceDER)
        let id = Base64URL.encode(Data(repeating: 1, count: 32))
        let nonce = Base64URL.encode(Data(repeating: 2, count: 32))
        let principal = String(repeating: "ab", count: 32)
        let issued: Int64 = 1_790_000_000, now = issued * 1000
        func input(expiryMS: Int64 = now + 30_000, clock: Int64 = now,
                   node: Int64 = issued + 60, pin: String? = nil, spki: Data? = nil,
                   owner: String = principal, origin: String = M.origin) throws -> M.ReceiptInput {
            let challenge = try M.InitialChallenge(challengeId: id, nonce: nonce, deviceId: device.hex,
                origin: origin, expiresAtMilliseconds: expiryMS)
            return try M.ReceiptInput(host: host, challenge: challenge, devicePublicSPKIDER: spki ?? deviceDER,
                socketDeviceFingerprint: pin ?? device.base64URL, ownerPrincipal: owner,
                nowMilliseconds: clock, nodeExpiresAtSeconds: node)
        }
        let request = try input()
        let receipt = try MobileEnrollmentSigner.receipt(request, identity: identity)
        let verified = try M.verifyReceipt(receipt, expected: request, nowMilliseconds: now)
        try check("정상 500ms 분수 challenge를 floor초 기준으로 오거부하지 않음") {
            let fractional = try input(expiryMS: now + 30_500, clock: now + 500)
            precondition(fractional.issuedAtSeconds == issued)
        }
        try check("정상 999ms 분수와 보수적인 receipt 만료") {
            let fractional = try input(expiryMS: now + 30_999, clock: now + 999)
            precondition(fractional.issuedAtSeconds == issued)
            let payload = try fractional.payload()
            precondition(payload.expiresAt == issued + 10)
        }
        try check("gateway 시계가 1초 빠른 challenge 허용") {
            _ = try input(expiryMS: now + 31_999, clock: now + 999)
        }
        let parts = try receipt.parts()
        func rawEnvelope(_ bytes: Data, purpose: String = M.purpose) -> M.Envelope {
            let signature = identity.signRecord(Data((purpose + "\0").utf8) + bytes)!
            return M.Envelope(payload: Base64URL.encode(bytes), signature: Base64URL.encode(signature),
                              publicSPKI: Base64URL.encode(hostDER))
        }
        func altered(_ key: String, _ value: Any) throws -> M.Envelope {
            var object = try JSONSerialization.jsonObject(with: parts.payload) as! [String: Any]
            object[key] = value
            return rawEnvelope(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        try check("계약의 최대 TTL보다 짧은 정상 receipt 허용") {
            _ = try M.verifyReceipt(altered("expiresAt", issued + 1), expected: request, nowMilliseconds: now)
        }
        try check("발급과 raw 검증 및 10초 TTL") {
            precondition(verified.payload.expiresAt == issued + 10)
            let expected = try encoded(request.payload())
            precondition(parts.payload == expected)
            precondition(String(decoding: parts.payload, as: UTF8.self).contains(M.origin))
        }
        try check("challenge 밀리초 floor가 receipt 초 만료를 제한") {
            let payload = try input(expiryMS: now + 4_999).payload()
            precondition(payload.expiresAt == issued + 4)
        }
        try check("node 만료가 receipt TTL을 제한") {
            let payload = try input(node: issued + 3).payload()
            precondition(payload.expiresAt == issued + 3)
        }
        for (name, call) in [
            ("다른 socket pin", { _ = try input(pin: Base64URL.encode(Data(repeating: 0, count: 32))) }),
            ("다른 기기키", { _ = try input(spki: otherDER) }),
            ("principal 대문자", { _ = try input(owner: principal.uppercased()) }),
            ("principal 숫자아님", { _ = try input(owner: String(repeating: "g", count: 64)) }),
            ("origin 후행 slash", { _ = try input(origin: M.origin + "/") }),
            ("challenge 만료 경계", { _ = try input(expiryMS: now) }),
            ("challenge 30초와 명시 skew 초과", { _ = try input(expiryMS: now + 31_001) }),
            ("challenge floor 후 TTL 없음", { _ = try input(expiryMS: now + 999) }),
            ("node 역전", { _ = try input(node: issued - 1) }),
            ("음수 epoch", { _ = try input(clock: -1) }),
            ("Int64 max ms", { _ = try input(clock: Int64.max) }),
            ("Int64 min", { _ = try input(clock: Int64.min) }),
            ("JS unsafe ms", { _ = try input(clock: M.maximumSafeInteger + 1) }),
            ("safe 최대 ms와 challenge 역전", { _ = try input(clock: M.maximumSafeInteger) }),
            ("JS unsafe challenge ms", { _ = try input(expiryMS: M.maximumSafeInteger + 1) })
        ] as [(String, () throws -> Void)] { rejects(name, call) }
        for invalid in [device.base64URL + "=", device.base64URL + "\n", "!", "A", String(repeating: "A", count: 42),
                        "_x", "", device.base64URL.replacingOccurrences(of: "-", with: "+") + "+"] {
            rejects("canonical fingerprint 거부 \(invalid.count)") { _ = try M.Fingerprint(base64URL: invalid) }
        }
        for invalid in [Data(), RemoteKey.publicPoint(deviceKey)!, Data(deviceDER.dropLast()),
                        deviceDER + Data([0]), Data(repeating: 0, count: 91), otherDER + Data([0])] {
            rejects("P256 SPKI 형식 거부 \(invalid.count)") { _ = try M.Fingerprint(spkiDER: invalid) }
        }
        rejects("다른 full host pin") {
            _ = try M.HostProfile(macID: host.macID, trustedFingerprint: device.base64URL, publicSPKIDER: hostDER)
        }
        rejects("다른 MacID") {
            _ = try M.HostProfile(macID: String(repeating: "0", count: 16),
                                  trustedFingerprint: host.fingerprint.base64URL, publicSPKIDER: hostDER)
        }
        rejects("signer의 다른 host identity") {
            _ = try MobileEnrollmentSigner.receipt(request,
                identity: HostIdentity(privateKey: otherKey, recognitionKey: Data(repeating: 0, count: 32))!)
        }
        for (key, value) in [("purpose", "other"), ("schemaVersion", 2), ("ownerPrincipal", 1),
                             ("origin", "http://evil.test"), ("macID", "wrong"), ("extra", 1),
                             ("issuedAt", issued * 1000), ("expiresAt", issued - 1)] as [(String, Any)] {
            rejects("서명은 유효하나 payload 거부 \(key)") {
                _ = try M.verifyReceipt(altered(key, value), expected: request, nowMilliseconds: now)
            }
        }
        let raw = String(decoding: parts.payload, as: UTF8.self)
        let malformed = [
            "{\"purpose\":\"other\"," + raw.dropFirst(),
            "{\"\\u0070urpose\":\"other\"," + raw.dropFirst(),
            raw.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0"),
            raw.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1e0"),
            raw.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
            raw.replacingOccurrences(of: "\"issuedAt\":\(issued)", with: "\"issuedAt\":9223372036854775808"),
            "{}", "{", raw + "x", "\u{FEFF}" + raw, "[1]", raw.replacingOccurrences(of: "\"purpose\":", with: "\"purpose\":null,\"z\":")
        ]
        for (index, value) in malformed.enumerated() {
            rejects("JSON 키·타입·부호·truncation 거부 \(index)") {
                _ = try M.verifyReceipt(rawEnvelope(Data(value.utf8)), expected: request, nowMilliseconds: now)
            }
        }
        for (label, time) in [("만료 정확 경계", now + 10_000), ("미래 clock 1001ms", now - 1001),
                              ("now 음수", -1), ("now unsafe", M.maximumSafeInteger + 1)] {
            rejects(label) { _ = try M.verifyReceipt(receipt, expected: request, nowMilliseconds: time) }
        }
        try check("미래 clock 정확 1000ms 허용") {
            _ = try M.verifyReceipt(receipt, expected: request, nowMilliseconds: now - 1000)
        }
        for invalid in [parts.signature + Data([0]), Data(parts.signature.dropLast()),
                        Data(repeating: 0, count: 64), Data([0x30, 0x06, 2, 1, 0, 2, 1, 0])] {
            rejects("DER 변형 거부 \(invalid.count)") {
                _ = try M.verifyReceipt(M.Envelope(payload: receipt.payload, signature: Base64URL.encode(invalid),
                    publicSPKI: receipt.publicSPKI), expected: request, nowMilliseconds: now)
            }
        }
        let envelopeBytes = try encoded(receipt)
        _ = try M.Envelope.decode(envelopeBytes)
        for invalid in [Data("{\"extra\":1,".utf8) + envelopeBytes.dropFirst(),
                        Data("{\"payload\":\"x\",".utf8) + envelopeBytes.dropFirst(),
                        Data("{\"\\u0070ayload\":\"x\",".utf8) + envelopeBytes.dropFirst(),
                        try encoded(M.Envelope(payload: receipt.payload + "=", signature: receipt.signature, publicSPKI: receipt.publicSPKI)),
                        try encoded(M.Envelope(payload: receipt.payload, signature: receipt.signature + "=", publicSPKI: receipt.publicSPKI)),
                        try encoded(M.Envelope(payload: receipt.payload, signature: receipt.signature, publicSPKI: receipt.publicSPKI + "="))] {
            rejects("envelope strict JSON·base64url \(invalid.count)") { _ = try M.Envelope.decode(invalid) }
        }
        let spaced = Data((" \n" + raw.replacingOccurrences(of: ",", with: ", ") + "\n").utf8)
        let spacedEnvelope = rawEnvelope(spaced)
        let spacedReceipt = try M.verifyReceipt(spacedEnvelope, expected: request, nowMilliseconds: now)
        check("재직렬화 없이 원문 공백 JSON 검증") { precondition(spacedReceipt.payloadJSON == spaced) }
        rejects("같은 의미 JSON 재직렬화 시 원래 서명 거부") {
            _ = try M.verifyReceipt(M.Envelope(payload: receipt.payload, signature: spacedEnvelope.signature,
                publicSPKI: receipt.publicSPKI), expected: request, nowMilliseconds: now)
        }
        let proof = verified.deviceProofBytes
        let deviceSignature = SecKeyCreateSignature(deviceKey, .ecdsaSignatureMessageX962SHA256, proof as CFData, nil)! as Data
        try verified.verifyDeviceProof(signature: Base64URL.encode(deviceSignature), devicePublicSPKIDER: deviceDER)
        check("기기 proof 도메인과 고정 32바이트 해시 세 개") {
            let prefix = Data("ccr-mobile-device-proof-v1\0".utf8)
            precondition(proof.count == prefix.count + 96)
            precondition(proof == prefix + Data(SHA256.hash(data: parts.payload))
                + Data(SHA256.hash(data: parts.signature)) + Data(SHA256.hash(data: parts.spki)))
        }
        rejects("다른 기기의 proof 키") {
            try verified.verifyDeviceProof(signature: Base64URL.encode(deviceSignature), devicePublicSPKIDER: otherDER)
        }
        rejects("raw payload 다른 기기 proof") {
            try spacedReceipt.verifyDeviceProof(signature: Base64URL.encode(deviceSignature), devicePublicSPKIDER: deviceDER)
        }
        let generation = "00112233-4455-6677-8899-aabbccddeeff"
        let requestID = "ffeeddcc-bbaa-9988-7766-554433221100"
        let hostChallenge = try M.HostChallenge(coreGeneration: generation, nonce: nonce, origin: M.origin)
        let hostFrame = try MobileEnrollmentSigner.hostIdentity(hostChallenge, host: host, identity: identity)
        try M.verifyHostIdentity(hostFrame.envelope, challenge: hostChallenge, host: host)
        _ = try M.decodeHostChallenge(encoded(hostChallenge))
        rejects("UUID 대문자 금지") {
            _ = try M.HostChallenge(coreGeneration: generation.uppercased(), nonce: nonce, origin: M.origin)
        }
        rejects("host identity 다른 nonce") {
            let other = try M.HostChallenge(coreGeneration: generation, nonce: id, origin: M.origin)
            try M.verifyHostIdentity(hostFrame.envelope, challenge: other, host: host)
        }
        rejects("host identity 다른 coreGeneration") {
            let other = try M.HostChallenge(coreGeneration: requestID, nonce: nonce, origin: M.origin)
            try M.verifyHostIdentity(hostFrame.envelope, challenge: other, host: host)
        }
        let deadline = now + 1500
        let digestBytes = try M.activeRequestBytes(coreGeneration: generation, requestId: requestID, nonce: nonce,
            deviceFingerprint: device.base64URL, ownerPrincipal: principal, origin: M.origin, deadlineMilliseconds: deadline)
        let digest = M.hexDigest(digestBytes)
        func activeChallenge(deadlineMS: Int64 = deadline, digestValue: String? = nil, core: String = generation) throws -> M.ActiveChallenge {
            let bytes = try M.activeRequestBytes(coreGeneration: core, requestId: requestID, nonce: nonce,
                deviceFingerprint: device.base64URL, ownerPrincipal: principal, origin: M.origin, deadlineMilliseconds: deadlineMS)
            return try M.ActiveChallenge(requestId: requestID, coreGeneration: core, nonce: nonce, origin: M.origin,
                deviceFingerprint: device.base64URL, ownerPrincipal: principal, requestDigest: digestValue ?? M.hexDigest(bytes),
                deadlineMilliseconds: deadlineMS, receivedAtMilliseconds: now)
        }
        let active = try activeChallenge()
        _ = try M.decodeActiveChallenge(encoded(active), receivedAtMilliseconds: now)
        for (name, bytes) in [("host", try encoded(hostChallenge)), ("active", try encoded(active))] {
            for invalid in [Data("{\"extra\":1,".utf8) + bytes.dropFirst(),
                            Data("{\"op\":\"other\",".utf8) + bytes.dropFirst(),
                            Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true").utf8),
                            Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: generation, with: generation.uppercased()).utf8),
                            bytes.dropLast()] {
                rejects("\(name) challenge strict decoder") {
                    if name == "host" { _ = try M.decodeHostChallenge(invalid) }
                    else { _ = try M.decodeActiveChallenge(invalid, receivedAtMilliseconds: now) }
                }
            }
        }
        let observation = try M.ActiveResultPayload(challenge: active, host: host, reason: .revoked,
            checkedAtMilliseconds: now, expiresAtMilliseconds: now + 2000, nowMilliseconds: now)
        let result = try MobileEnrollmentSigner.activeResult(observation, challenge: active, host: host,
                                                             identity: identity, nowMilliseconds: now)
        let resultPayload = try M.verifyActiveResult(result.envelope, challenge: active, host: host, nowMilliseconds: now)
        check("active false를 서명해도 인가 성공으로 바꾸지 않음") { precondition(!resultPayload.active) }
        for reason in M.ActiveReason.allCases {
            try check("active와 고정 reason의 일관성 \(reason.rawValue)") {
                let observed = try M.ActiveResultPayload(challenge: active, host: host, reason: reason,
                    checkedAtMilliseconds: now, expiresAtMilliseconds: now + 2000, nowMilliseconds: now)
                let frame = try MobileEnrollmentSigner.activeResult(observed, challenge: active, host: host,
                    identity: identity, nowMilliseconds: now)
                let verified = try M.verifyActiveResult(frame.envelope, challenge: active, host: host, nowMilliseconds: now)
                precondition(verified.active == (reason == .active) && verified.reason == reason)
                switch reason {
                case .active: precondition(reason.gatewayFailure == nil)
                case .unavailable:
                    precondition(reason.gatewayFailure?.status == 503 && reason.gatewayFailure?.code == "ENROLLMENT_PROVIDER_UNAVAILABLE")
                case .revoked:
                    precondition(reason.gatewayFailure?.status == 403 && reason.gatewayFailure?.code == "DEVICE_REVOKED")
                default:
                    precondition(reason.gatewayFailure?.status == 403 && reason.gatewayFailure?.code == "OWNER_TRUST_DENIED")
                }
            }
        }
        let activeParts = try result.envelope.parts()
        for (key, value) in [("active", true), ("reason", "active"), ("reason", "/Users/secret/error"),
                             ("reason", "NSError domain"), ("reason", "unknown"), ("requestDigest", String(repeating: "0", count: 64)),
                             ("nonce", id), ("requestId", generation), ("origin", "http://evil.test")] as [(String, Any)] {
            rejects("서명된 active 결과의 모순·미지정 코드·binding 거부 \(key)") {
                var object = try JSONSerialization.jsonObject(with: activeParts.payload) as! [String: Any]
                object[key] = value
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                _ = try M.verifyActiveResult(rawEnvelope(bytes, purpose: M.activeResultPurpose), challenge: active,
                                            host: host, nowMilliseconds: now)
            }
        }
        check("compact JSON 배열의 정확한 순서·slash·정수") {
            let expected = "[1,\"\(generation)\",\"\(requestID)\",\"\(nonce)\",\"\(device.base64URL)\",\"\(principal)\",\"\(M.origin)\",\(deadline)]"
            precondition(digestBytes == Data(expected.utf8))
        }
        rejects("active digest 불일치") { _ = try activeChallenge(digestValue: String(repeating: "0", count: 64)) }
        rejects("active deadline 1501ms") { _ = try activeChallenge(deadlineMS: now + 1501) }
        rejects("active deadline 현재 경계") { _ = try activeChallenge(deadlineMS: now) }
        rejects("active generation 변경") {
            _ = try M.verifyActiveResult(result.envelope, challenge: activeChallenge(core: requestID), host: host, nowMilliseconds: now)
        }
        for checked in [now - 1, now + 1001, deadline] {
            rejects("active checkedAt 범위 \(checked)") {
                _ = try M.ActiveResultPayload(challenge: active, host: host, reason: .active,
                    checkedAtMilliseconds: checked, expiresAtMilliseconds: checked + 1000, nowMilliseconds: now)
            }
        }
        for expires in [now, now - 1, now + 2001, M.maximumSafeInteger + 1] {
            rejects("active TTL 범위 \(expires)") {
                _ = try M.ActiveResultPayload(challenge: active, host: host, reason: .active,
                    checkedAtMilliseconds: now, expiresAtMilliseconds: expires, nowMilliseconds: now)
            }
        }
        rejects("active late response deadline 경계") {
            _ = try M.verifyActiveResult(result.envelope, challenge: active, host: host, nowMilliseconds: deadline)
        }
        try check("active clock skew 1000ms 경계") {
            _ = try M.ActiveResultPayload(challenge: active, host: host, reason: .active,
                checkedAtMilliseconds: now + 1000, expiresAtMilliseconds: now + 2000, nowMilliseconds: now)
        }
        var maximumPayload = try JSONSerialization.jsonObject(with: parts.payload) as! [String: Any]
        maximumPayload["issuedAt"] = M.maximumSafeInteger - 10
        maximumPayload["expiresAt"] = M.maximumSafeInteger
        let maximumJSON = try JSONSerialization.data(withJSONObject: maximumPayload, options: [.sortedKeys, .withoutEscapingSlashes])
        let maximumSignature = Data([0x30, 0x46, 0x02, 0x21, 0x00, 0x80]) + Data(repeating: 1, count: 31)
            + Data([0x02, 0x21, 0x00, 0x80]) + Data(repeating: 1, count: 31)
        let maximumEnvelope = M.Envelope(payload: Base64URL.encode(maximumJSON), signature: Base64URL.encode(maximumSignature),
                                         publicSPKI: receipt.publicSPKI)
        let receiptOnly: [String: Any] = ["ok": true, "method": OwnerMacBootstrap.method, "macID": host.macID,
            "ownerEnrollmentVersion": 1, "ownerReceipt": try JSONSerialization.jsonObject(with: encoded(maximumEnvelope))]
        let receiptOnlyBytes = try JSONSerialization.data(withJSONObject: receiptOnly, options: [.sortedKeys, .withoutEscapingSlashes])
        let receiptOnlyFrame = StreamMessage(kind: .pairResult, timestamp: 0, isKeyframe: false, payload: receiptOnlyBytes).serialized()
        check("최대 receipt-only fixture와 실제 14바이트 header의 4KiB 여유") {
            precondition(maximumSignature.count == 72 && hostDER.count == 91)
            precondition(id.count == 43 && nonce.count == 43 && principal.count == 64 && host.macID.count == 16)
            precondition(Set(receiptOnly.keys) == ["ok", "method", "macID", "ownerEnrollmentVersion", "ownerReceipt"])
            precondition(receiptOnly["proof"] == nil && receiptOnly["recognitionKey"] == nil)
            precondition(receiptOnlyFrame.count == receiptOnlyBytes.count + StreamMessage.headerLength)
            precondition(receiptOnlyFrame.count <= 4096)
            precondition(StreamMessage.parseHeader(receiptOnlyFrame)?.kind == .pairResult)
        }
        try receiptOnlyBytes.write(to: output.appendingPathComponent("receipt-only-maximum.raw.json"))
        try receiptOnlyFrame.write(to: output.appendingPathComponent("receipt-only-maximum.frame.bin"))
        let fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let shared = try [
            "v1": sharedFixture(fixtureDirectory.appendingPathComponent("device-enrollment-golden.json").path, validSemantics: false),
            "v2": sharedFixture(fixtureDirectory.appendingPathComponent("device-enrollment-golden-v2.json").path, validSemantics: true)
        ]
        try JSONSerialization.data(withJSONObject: shared, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("shared-fixture-results.json"))
        let golden: [String: Any] = [
            "schema": "ccr.mobile-enrollment-synthetic-golden/v1", "runtimeAccepted": false,
            "hostPublicSPKI": Base64URL.encode(hostDER), "hostFingerprint": host.fingerprint.base64URL, "macID": host.macID,
            "devicePublicKey": Base64URL.encode(deviceDER), "deviceId": device.hex, "ownerPrincipal": principal,
            "challenge": try JSONSerialization.jsonObject(with: encoded(request.challenge)),
            "ownerReceipt": try JSONSerialization.jsonObject(with: envelopeBytes),
            "payloadJSON": raw, "payloadBase64URL": receipt.payload,
            "signingBytes": Base64URL.encode(Data((M.purpose + "\0").utf8) + parts.payload),
            "deviceProofBytes": Base64URL.encode(proof), "deviceProofSignature": Base64URL.encode(deviceSignature),
            "spacedOwnerReceipt": try JSONSerialization.jsonObject(with: encoded(spacedEnvelope)),
            "hostIdentityFrame": try JSONSerialization.jsonObject(with: encoded(hostFrame)),
            "hostChallenge": try JSONSerialization.jsonObject(with: encoded(hostChallenge)),
            "activeChallenge": try JSONSerialization.jsonObject(with: encoded(active)),
            "activeResult": try JSONSerialization.jsonObject(with: encoded(result)),
            "activeDigestInput": String(decoding: digestBytes, as: UTF8.self), "activeRequestDigest": digest,
            "issuedAtSeconds": issued, "nodeExpiresAtSeconds": issued + 60, "nowMilliseconds": now,
            "maximumReceiptOnlyJSONBytes": receiptOnlyBytes.count, "streamHeaderBytes": StreamMessage.headerLength,
            "maximumReceiptOnlyFrameBytes": receiptOnlyFrame.count,
            "maximumReceiptOnlyFixtureIsSizingOnly": true,
            "remaining4096BudgetBytes": 4096 - receiptOnlyFrame.count,
            "tests": passed
        ]
        try JSONSerialization.data(withJSONObject: golden, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: output.appendingPathComponent("golden.json"))
        try parts.payload.write(to: output.appendingPathComponent("payload.raw.json"))
        try parts.signature.write(to: output.appendingPathComponent("host-signature.der"))
        try parts.spki.write(to: output.appendingPathComponent("host-spki.der"))
        try deviceDER.write(to: output.appendingPathComponent("device-spki.der"))
        try proof.write(to: output.appendingPathComponent("device-proof-message.bin"))
        try deviceSignature.write(to: output.appendingPathComponent("device-signature.der"))
        try digestBytes.write(to: output.appendingPathComponent("active-request.raw.json"))
        print("모바일 자동등록 순수 계약 \(passed.count)개 검사 통과. runtimeAccepted=false")
    }
}
