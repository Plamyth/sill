import Foundation
import CryptoKit
import StreamProtocol

func renewalRuntimeChecks() throws {
    let host = P256.Signing.PrivateKey(), device = P256.Signing.PrivateKey()
    let hostSPKI = SPKI.der(point: host.publicKey.x963Representation)
    let deviceSPKI = SPKI.der(point: device.publicKey.x963Representation)
    let binding = try P.Binding(macID: MacID.make(fingerprint: P.hash(hostSPKI)), hostPin: P.hash(hostSPKI), deviceSPKI: deviceSPKI)
    let initial: Int64 = 1_800_000_000_000
    func challenge(_ number: UInt8, at now: Int64) throws -> P.Challenge {
        try P.Challenge(data(.object(["schema": .string("ccr.device-challenge/v1"),
            "challengeId": .string(Base64URL.encode(Data(repeating: number, count: 32))),
            "nonce": .string(Base64URL.encode(Data(repeating: number + 16, count: 32))),
            "deviceId": .string(binding.deviceID), "origin": .string(P.origin), "expiresAt": .integer(now + 30_000)])), binding: binding, now: now)
    }
    func receipt(_ challenge: P.Challenge, at now: Int64) throws -> Data {
        let payload = data(J.object(["schemaVersion": .integer(1), "purpose": .string("ccr-mobile-enrollment-v1"),
            "macID": .string(binding.macID), "macFingerprint": .string(Base64URL.encode(binding.hostPin)),
            "deviceFingerprint": .string(Base64URL.encode(binding.deviceFingerprint)),
            "ownerPrincipal": .string(String(repeating: "e", count: 64)), "challengeId": .string(challenge.id),
            "nonce": .string(challenge.nonce), "origin": .string(P.origin),
            "issuedAt": .integer(now / 1000), "expiresAt": .integer(now / 1000 + 10)]))
        return data(.object(["payload": .string(Base64URL.encode(payload)),
            "signature": .string(Base64URL.encode(try host.signature(for: Data("ccr-mobile-enrollment-v1\0".utf8) + payload).derRepresentation)),
            "publicSPKI": .string(Base64URL.encode(hostSPKI))]))
    }
    let firstChallenge = try challenge(1, at: initial)
    let firstReceipt = try P.Receipt(receipt(firstChallenge, at: initial), challenge: firstChallenge, binding: binding, now: initial)
    let firstBody = try P.enroll(firstReceipt, challenge: firstChallenge, binding: binding,
        signature: device.signature(for: firstReceipt.proofMessage).derRepresentation)
    let fixture: J = .object(["enrollRequest": try J.parse(firstBody), "challengeResponse": firstChallenge.json,
        "readbackSigningMessageBase64url": .string("AA"), "readbackChallenge": .object([:]),
        "readbackRequest": .object(["signature": .string("AA")])])
    let profile = data(J.object(["schema": .string("ccr.owner-mac-bootstrap/v1"), "macID": .string(binding.macID),
        "fingerprint": .string(Base64URL.encode(binding.hostPin)), "addresses": .array([.string("100.100.100.100")]),
        "remotePort": .integer(52342)]))
    let profileURL = URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent().appendingPathComponent("synthetic-renew-profile.json")
    try profile.write(to: profileURL)

    for mode in ["success", "malformed", "ordinary401", "provider503", "unknown404", "archive-cas", "archive-read", "trust-change", "renew503", "renew401"] {
        let memory = try Memory(fixture)
        runtimeMemory = memory; Bundle.url = profileURL
        DeviceIdentity.value = .init(privateKey: .init(device.publicKey.x963Representation,
            sign: { try device.signature(for: $0).derRepresentation }), fingerprint: binding.deviceFingerprint)
        let stream = StreamClient()
        let peer = NWConnection(); peer.pin = binding.hostPin
        stream.connection = peer; stream.session = .init(macID: binding.macID)
        stream.savedMacs = [.init(macID: binding.macID, fingerprintData: binding.hostPin, homeTLS: true)]
        stream.connected = true
        var challenges = 0, enrollments = 0, archiveSeen = false
        var activeChallenge = firstChallenge
        var firstPending: J?
        func credential(_ renewed: Bool) -> J {
            .object(["schema": .string("ccr.device-credential/v1"), "deviceId": .string(binding.deviceID),
                "credentialId": .string(renewed ? "synthetic-renewed" : "synthetic-original"),
                "token": .string(String(repeating: renewed ? "d" : "c", count: 64)),
                "expiresAt": .integer(renewed ? memory.now + 86_400_000 : initial + 3_600_000), "origin": .string(P.origin)])
        }
        memory.receiptHandler = { try receipt($0, at: memory.now) }
        memory.onWrite = { bytes in
            guard mode == "trust-change", let parsed = try? J.parse(bytes, limit: 1_048_576),
                  object(parsed)["renewalRequired"] == .bool(true) else { return }
            peer.pin = Data(repeating: 0, count: 32)
        }
        memory.postHandler = { route, body in
            do {
                switch route {
                case .challenge:
                    challenges += 1
                    if challenges > 1 {
                        let stored = object(try J.parse(memory.raw!, limit: 1_048_576))
                        guard case .array(let history) = stored["history"]!, history.count == 1 else { throw IPadEnrollmentFailure.invalid }
                        let archived = object(history[0]), oldPending = object(archived["pending"]!)
                        let original = object(firstPending!)
                        archiveSeen = stored["binding"] == binding.json && oldPending["body"] == original["body"] && oldPending["digest"] == original["digest"] && oldPending["challenge"] == original["challenge"]
                        guard archiveSeen, challenges == 2 else { throw IPadEnrollmentFailure.invalid }
                        if mode == "renew503" { return memory.response(503, .object(["error": .string("ENROLLMENT_PROVIDER_UNAVAILABLE")])) }
                    }
                    activeChallenge = try challenge(UInt8(challenges), at: memory.now)
                    return memory.response(activeChallenge.json)
                case .enroll:
                    enrollments += 1
                    let stored = object(try J.parse(memory.raw!, limit: 1_048_576))
                    let pending = object(stored["pending"]!)
                    guard try P.decode(text(pending["body"]!), maximum: 16_384) == body else { throw IPadEnrollmentFailure.storage }
                    let request = object(try J.parse(body, limit: 16_384))
                    let verified = try P.Receipt(data(request["ownerReceipt"]!), challenge: activeChallenge, binding: binding, now: memory.now)
                    guard try P.publicKey(deviceSPKI).isValidSignature(P.signature(P.decode(text(request["signature"]!), maximum: 72)), for: verified.proofMessage) else { throw IPadEnrollmentFailure.invalid }
                    if enrollments > 1 && mode == "renew401" { return memory.response(401, .object(["error": .string("CREDENTIAL_EXPIRED")])) }
                    return memory.response(credential(enrollments > 1))
                case .readbackChallenge:
                    switch mode {
                    case "malformed": return memory.response(401, .object(["error": .string("CREDENTIAL_EXPIRED"), "extra": .bool(true)]))
                    case "ordinary401": return memory.response(401, .object(["error": .string("CREDENTIAL_INVALID")]))
                    case "provider503": return memory.response(503, .object(["error": .string("ENROLLMENT_PROVIDER_UNAVAILABLE")]))
                    case "unknown404": return memory.response(404, .object(["error": .string("ENROLLMENT_OPERATION_UNCONFIRMED")]))
                    case "archive-cas": memory.casFails = true
                    case "archive-read": memory.loadFails = true
                    default: break
                    }
                    return memory.response(401, .object(["error": .string("CREDENTIAL_EXPIRED")]))
                case .readback: throw IPadEnrollmentFailure.invalid
                }
            } catch { return .failure(error) }
        }
        stream.resumeOwnerEnrollment()
        settle { stream.ownerEnrollmentCredential != nil }
        let originalGrant = stream.ownerEnrollmentCredential!
        firstPending = object(try J.parse(memory.raw!, limit: 1_048_576))["pending"]
        memory.now = initial + 3_600_001
        stream.resumeOwnerEnrollment()
        settle { stream.ownerEnrollment?.phase != .requesting }
        if mode == "success" {
            let renewed = stream.ownerEnrollmentCredential
            try check(renewed != nil && renewed != originalGrant && archiveSeen, "확정 만료 archive 검증 뒤 실제 wrapper 자동 갱신")
            try check(challenges == 2 && memory.receiptCalls == 2 && enrollments == 2, "새 owner receipt·자체 proof·갱신 한 번")
            try check(try stream.ownerEnrollmentAuthorizedRequest(path: "/v1/catalog", method: "GET").value(forHTTPHeaderField: "Authorization") == renewed!.authorizationValue, "갱신된 자기 bearer 요청")
        } else if ["renew503", "renew401"].contains(mode) {
            try check(challenges == 2 && archiveSeen && stream.ownerEnrollmentCredential == nil, "갱신 실패도 요청당 한 번이며 반복 없음 \(mode)")
        } else {
            try check(challenges == 1 && memory.receiptCalls == 1 && enrollments == 1, "미확정·저장 실패·신뢰 변경 자동 갱신 0 \(mode)")
            try check(stream.ownerEnrollmentCredential == nil, "갱신 금지 분기는 expired credential 반환 0 \(mode)")
        }
        stream.cancelOwnerEnrollment()
        memory.postHandler = nil; memory.receiptHandler = nil; memory.onWrite = nil
    }
    DeviceIdentity.value = nil; runtimeMemory = nil
}
