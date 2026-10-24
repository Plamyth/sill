import Foundation
import StreamProtocol
import CryptoKit

@main @MainActor struct Checks {
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { print("FAIL \(name)"); exit(1) }
        print("PASS \(name)")
    }
    static func main() throws {
        check(StreamMessageKind(rawValue: 223) != nil && StreamMessageKind(rawValue: 224) != nil,
              "새 복귀 계약의 223/224 kind가 기존 unknown 경로와 구분됨")
        check(StreamMessage.clientPayloadLimit(for: .sentryReturnRequest) == 4096 &&
            StreamMessage.hostPayloadLimit(for: .sentryReturnState) == 16384 &&
            StreamMessage.clientPayloadLimit(for: .sentryReturnState) == -1 &&
            StreamMessage.hostPayloadLimit(for: .sentryReturnRequest) == -1, "새 kind의 방향과 크기 제한")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let f = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("fixtures.json"))) as! [String: Any]
        for name in ["requestDeviceRaw", "requestMacRaw", "enrollRaw", "rotateRaw", "revokeRaw", "currentRaw", "cancelRaw", "proofRaw"] {
            let bytes = Data((f[name] as! String).utf8)
            let value = try SentryReturnControl.decodePayload(bytes)
            let roundtrip = try SentryReturnControl.decodePayload(value.encodedPayload())
            check(value == roundtrip, "공유 fixture 왕복 \(name)")
        }
        let request = try SentryReturnRequest(rawRequest: Data((f["requestDeviceRaw"] as! String).utf8))
        check(request.requestDigest == f["requestDeviceSHA256"] as? String, "원본 요청 바이트 SHA256 golden")
        let challengeBytes = try JSONSerialization.data(withJSONObject: f["challenge"]!)
        let challenge = try JSONDecoder().decode(SentryReturnChallenge.self, from: challengeBytes)
        let signed = try challenge.signingBytes()
        check(signed.base64EncodedString() == f["signingPayloadBase64"] as? String &&
            SentryReturnRequest.digest(signed) == f["signingBytesSHA256"] as? String, "Android와 Apple의 canonical 서명 바이트 golden")
        guard case .prove(_, _, let signature) = try SentryReturnControl.decodePayload(Data((f["proofRaw"] as! String).utf8)) else { fatalError() }
        let key = try P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: f["publicKeySPKIBase64"] as! String)!)
        let proof = try P256.Signing.ECDSASignature(derRepresentation: signature)
        check(key.isValidSignature(proof, for: signed), "고정 P256 DER proof를 실제 CryptoKit 검증")
        for name in ["pendingStateRaw", "completedStateRaw"] {
            let state = try SentryReturnState.decodePayload(Data((f[name] as! String).utf8))
            let decoded = try SentryReturnState.decodePayload(state.encodedPayload())
            check(state == decoded, "상태 fixture 왕복 \(name)")
        }
        let capability = try SentryReturnCapability.decodePayload(JSONSerialization.data(withJSONObject: f["capability"]!))
        check(capability.keyEnrollment == "macLocalRequired", "공유 capability는 키 변경에 Mac 인증 필수를 명시")
        let original = f["requestDeviceRaw"] as! String
        for bad in [String(original.dropLast()) + ",\"accepted\":true}",
                    String(original.dropLast()) + ",\"operation\":\"request\"}",
                    String(original.dropLast()) + ",\"oper\\u0061tion\":\"request\"}",
                    original.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
                    original.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
                    original.replacingOccurrences(of: "\"deviceBoundKey\"", with: "null"),
                    String(repeating: " ", count: 4097) + original] {
            do { _ = try SentryReturnControl.decodePayload(Data(bad.utf8)); check(false, "잘못된 wire 거절") }
            catch { check(true, "중복·escaped 중복·unknown·잘못된 타입·상한 거절") }
        }
        let point = key.x963Representation.base64EncodedString()
        let enrollmentRaw = f["enrollRaw"] as! String
        do {
            _ = try SentryReturnControl.decodePayload(Data(enrollmentRaw.replacingOccurrences(of: f["publicKeySPKIBase64"] as! String, with: point).utf8))
            check(false, "X9.63를 SPKI로 오인하지 않음")
        } catch { check(true, "X9.63를 SPKI로 오인하지 않음") }
        for bad in [enrollmentRaw.replacingOccurrences(of: "macLocal", with: "deviceBoundKey"),
                    enrollmentRaw.replacingOccurrences(of: "\"keyID\":", with: "\"approved\":true,\"keyID\":")] {
            do { _ = try SentryReturnControl.decodePayload(Data(bad.utf8)); check(false, "TLS나 기기 인증 bool으로 키 변경을 승인하지 않음") }
            catch { check(true, "TLS나 기기 인증 bool으로 키 변경을 승인하지 않음") }
        }
        let nonCanonical = (f["proofRaw"] as! String).replacingOccurrences(of: "=\"", with: "\"")
        if nonCanonical != f["proofRaw"] as! String {
            do { _ = try SentryReturnControl.decodePayload(Data(nonCanonical.utf8)); check(false, "base64 padding 생략 거절") }
            catch { check(true, "base64 padding 생략 거절") }
        }
        try authorityChecks()
    }

    typealias A = SentryReturnAuthority
    @MainActor final class Fixture {
        let authority: A
        var snapshot: A.Snapshot
        let key: P256.Signing.PrivateKey
        let keyID = UUID().uuidString.lowercased()
        init() throws {
            let boot = UUID()
            authority = A(hostBootID: boot)
            let lease = try SentryReturnLease(hostBootID: boot.uuidString.lowercased(), sessionID: UUID().uuidString.lowercased(),
                revision: UUID().uuidString.lowercased(), authorizationGeneration: UUID().uuidString.lowercased())
            let owner = A.Owner(ownerID: "owner-1", hostFingerprint: String(repeating: "ab", count: 32),
                deviceFingerprint: String(repeating: "cd", count: 32), tlsFingerprint: String(repeating: "cd", count: 32),
                pairingGeneration: UUID().uuidString.lowercased(), encryptedTLS: true, currentPairedOwner: true)!
            snapshot = .init(owner: owner, lease: lease)
            key = P256.Signing.PrivateKey()
        }
        func request(_ mode: SentryReturnAuthMode = .macLocal, enrollment: SentryReturnKeyEnrollment? = nil) throws -> SentryReturnRequest {
            try .init(lease: snapshot.lease, authMode: mode, keyEnrollment: enrollment)
        }
        func handle(_ message: SentryReturnControl, _ now: TimeInterval = 0) -> A.Decision {
            authority.handle(message, now: now, current: { self.snapshot })
        }
        func mac(_ request: SentryReturnRequest, _ now: TimeInterval = 0) -> A.MacAuthenticationTicket {
            let result = handle(.request(request), now)
            guard case .authenticateMac(let ticket)? = result.commands.first else { fatalError("Mac 인증 command 없음") }
            check(result.state?.authStatus == .pending && result.state?.operationState == .authenticating,
                  "Mac 인증 의도만 생성하고 성공은 보고하지 않음")
            return ticket
        }
        func authenticate(_ ticket: A.MacAuthenticationTicket, _ now: TimeInterval = 0) -> A.Decision {
            authority.completeMacAuthentication(ticket, result: .authenticated, now: now, current: { self.snapshot })
        }
        func enroll(_ now: TimeInterval = 0) throws {
            let mutation = try SentryReturnKeyEnrollment(action: .enroll, keyID: keyID,
                publicKey: key.publicKey.derRepresentation.base64EncodedString())
            let ticket = mac(try request(enrollment: mutation), now)
            check(!authority.capability(owner: snapshot.owner, macLocalAvailable: true).deviceBoundKey,
                  "키 등록 요청과 TLS만으로 권한이 생기지 않음")
            let decision = authenticate(ticket, now)
            guard case .keyChanged(let change)? = decision.commands.first else { fatalError("키 등록 결과 없음") }
            check(change.previous == nil && change.current?.keyID == keyID && change.authorizedBy == ticket &&
                  decision.state?.code == .keyEnrolled, "현재 Mac 인증 ticket에 결속된 첫 키 등록")
        }
        func moveSession() throws {
            let l = snapshot.lease
            snapshot = .init(owner: snapshot.owner, lease: try .init(hostBootID: l.hostBootID,
                sessionID: UUID().uuidString.lowercased(), revision: UUID().uuidString.lowercased(), authorizationGeneration: l.authorizationGeneration))
        }
    }
    static func returnTicket(_ decision: A.Decision) -> A.LocalReturnTicket {
        guard case .returnLocal(let ticket)? = decision.commands.first else { fatalError("복귀 command 없음") }; return ticket
    }
    static func proof(_ fixture: Fixture, request: SentryReturnRequest, challenge: SentryReturnChallenge,
                      key: P256.Signing.PrivateKey? = nil) throws -> SentryReturnControl {
        .prove(request.reference, authGeneration: challenge.authGeneration,
               signature: try (key ?? fixture.key).signature(for: challenge.signingBytes()).derRepresentation)
    }
    static func authorityChecks() throws {
        do {
            let f = try Fixture(), request = try f.request(), ticket = f.mac(request)
            check(f.handle(.current(request.reference), 1).commands.isEmpty && f.handle(.request(request), 2).commands.isEmpty,
                  "current와 같은 원본 재송신은 인증을 재실행하지 않음")
            let changed = try SentryReturnRequest(rawRequest: Data((" " + String(decoding: request.rawRequest, as: UTF8.self)).utf8))
            check(f.handle(.request(changed), 3).state?.code == .requestConflict, "같은 ID의 다른 원본 바이트는 충돌")
            let result = f.authenticate(ticket, 4), local = returnTicket(result)
            check(result.state?.authStatus == .succeeded && result.state?.operationState == .restoring,
                  "인증 성공과 실제 복귀 완료를 구분")
            let permit = f.authority.authorizeCommit(local, now: 5, current: { f.snapshot })!
            check(f.authority.authorizeCommit(local, now: 5, current: { f.snapshot }) == nil, "commit permit은 한 번만 발행")
            try f.moveSession()
            let done = f.authority.completeReturn(permit, result: .verifiedRestored, now: 6, currentOwner: { f.snapshot.owner })
            check(done.state?.operationState == .completed && done.state?.currentProtection == "notObserved" &&
                done.state?.nextPolicy == "parentAdmissionRequired", "세션 reset 뒤 과거 완료와 부모 admission 관측을 분리")
            check(f.handle(.current(request.reference), 7).state?.operationState == .completed &&
                f.handle(.current(request.reference), 8).commands.isEmpty, "동일 owner/device 재접속 결과 조회는 읽기 전용")
            check(f.authority.completeReturn(permit, result: .verifiedRestored, now: 8,
                currentOwner: { f.snapshot.owner }).commands.isEmpty, "완료 callback 재전달은 복귀를 재실행하지 않음")
            let stranger = A.Owner(ownerID: "owner-2", hostFingerprint: f.snapshot.owner.hostFingerprint,
                deviceFingerprint: f.snapshot.owner.deviceFingerprint, tlsFingerprint: f.snapshot.owner.tlsFingerprint,
                pairingGeneration: f.snapshot.owner.pairingGeneration, encryptedTLS: true, currentPairedOwner: true)!
            check(f.authority.handle(.current(request.reference), now: 9,
                current: { .init(owner: stranger, lease: f.snapshot.lease) }).state == nil, "다른 owner의 결과 조회 거절")
        }
        do {
            let f = try Fixture(), request = try f.request(), ticket = f.mac(request)
            let result = f.handle(.cancel(request.reference, authGeneration: ticket.challenge.authGeneration), 1)
            check(result.state?.operationState == .cancelled && result.commands.count == 1, "취소는 Mac 인증 중단 의도 생성")
            check(f.authenticate(ticket, 2).commands.isEmpty && f.handle(.current(request.reference), 3).state?.authStatus == .cancelled,
                  "취소 뒤 늦은 Mac 성공은 무효")
        }
        do {
            let f = try Fixture(), request = try f.request(), ticket = f.mac(request)
            check(f.authority.expire(now: 120).first?.state?.authStatus == .expired, "인증 만료 경계에서 즉시 거절")
            check(f.authenticate(ticket, 121).commands.isEmpty, "만료 뒤 늦은 Mac 성공은 무효")
        }
        do {
            let f = try Fixture(), request = try f.request(), ticket = f.mac(request)
            try f.moveSession()
            check(f.authenticate(ticket, 1).commands.allSatisfy { if case .cancelMac = $0 { return true }; return false },
                  "인증 중 세션 이동은 복귀 없이 인증만 취소")
            check(f.handle(.current(request.reference), 2).state?.code == .staleLease, "세션 이동은 stale lease로 기록")
        }
        do {
            let f = try Fixture(), request = try f.request(), ticket = f.mac(request)
            check(f.authority.disconnected(f.snapshot.owner, now: 1).flatMap(\.commands).count == 1,
                  "장치 분리는 기존 callback에서 인증 취소 의도 생성")
            check(f.authenticate(ticket, 2).commands.isEmpty, "분리 뒤 오래된 인증 callback 거절")
        }
        do {
            let f = try Fixture(), request = try f.request(.deviceBoundKey)
            check(f.handle(.request(request)).state?.code == .noEnrolledKey &&
                !f.authority.capability(owner: f.snapshot.owner, macLocalAvailable: true).deviceBoundKey,
                  "사전 등록 키가 없는 기기 인증은 명시적 미지원")
        }
        do {
            let f = try Fixture(); try f.enroll()
            let request = try f.request(.deviceBoundKey)
            let start = f.handle(.request(request), 1), challenge = start.state!.challenge!
            let signed = try proof(f, request: request, challenge: challenge)
            let accepted = f.handle(signed, 2), ticket = returnTicket(accepted)
            check(accepted.state?.authStatus == .succeeded && accepted.state?.operationState == .restoring,
                  "실제 P256 proof 검증 뒤에만 복귀 의도 생성")
            check(f.handle(signed, 3).commands.isEmpty, "동일 nonce proof는 한 번만 소비")
            try f.moveSession()
            check(!f.authority.returnIsCurrent(ticket, now: 4, current: { f.snapshot }) &&
                f.authority.authorizeCommit(ticket, now: 4, current: { f.snapshot }) == nil,
                  "복귀 중 stale lease로 commit 불가")
            check(f.handle(.current(request.reference), 5).state?.code == .staleLease, "현재 조회는 stale 작업을 재실행하지 않음")
        }
        for failure in ["wrongKey", "wrongGeneration", "expired", "cancelled", "repaired", "disconnected"] {
            let f = try Fixture(); try f.enroll()
            let request = try f.request(.deviceBoundKey), initial = f.handle(.request(request), 1), challenge = initial.state!.challenge!
            var message = try proof(f, request: request, challenge: challenge)
            var at: TimeInterval = 2
            if failure == "wrongKey" { message = try proof(f, request: request, challenge: challenge, key: .init()) }
            if failure == "wrongGeneration", case .prove(let ref, _, let sig) = message {
                message = .prove(ref, authGeneration: UUID().uuidString.lowercased(), signature: sig)
            }
            if failure == "expired" { at = 121 }
            if failure == "cancelled" { _ = f.handle(.cancel(request.reference, authGeneration: challenge.authGeneration), 2); at = 3 }
            if failure == "disconnected" { _ = f.authority.disconnected(f.snapshot.owner, now: 2); at = 3 }
            if failure == "repaired" {
                let o = f.snapshot.owner
                f.snapshot = .init(owner: A.Owner(ownerID: o.ownerID, hostFingerprint: o.hostFingerprint,
                    deviceFingerprint: o.deviceFingerprint, tlsFingerprint: o.tlsFingerprint,
                    pairingGeneration: UUID().uuidString.lowercased(), encryptedTLS: true, currentPairedOwner: true)!, lease: f.snapshot.lease)
            }
            let rejected = f.handle(message, at)
            check(!rejected.commands.contains { if case .returnLocal = $0 { return true }; return false },
                  "잘못되거나 오래된 기기 서명은 복귀하지 않음 \(failure)")
        }
        do {
            let f = try Fixture(); try f.enroll()
            let request = try f.request(.deviceBoundKey), challenge = f.handle(.request(request), 1).state!.challenge!
            let old = try proof(f, request: request, challenge: challenge)
            _ = f.handle(.cancel(request.reference, authGeneration: challenge.authGeneration), 2)
            let next = try f.request(.deviceBoundKey), nextChallenge = f.handle(.request(next), 3).state!.challenge!
            guard case .prove(_, _, let oldSignature) = old else { fatalError() }
            let replay = f.handle(.prove(next.reference, authGeneration: nextChallenge.authGeneration, signature: oldSignature), 4)
            check(replay.state?.code == .invalidProof && replay.commands.isEmpty, "새 요청 tuple와 nonce에 과거 서명 재생 거절")
        }
        do {
            let f = try Fixture(); try f.enroll()
            let nextKey = P256.Signing.PrivateKey(), nextID = UUID().uuidString.lowercased()
            let rotate = try SentryReturnKeyEnrollment(action: .rotate, keyID: nextID,
                publicKey: nextKey.publicKey.derRepresentation.base64EncodedString(), previousKeyID: f.keyID)
            let ticket = f.mac(try f.request(enrollment: rotate), 1)
            check(f.authenticate(ticket, 2).state?.code == .keyRotated, "키 회전도 현재 Mac 인증으로만 완료")
            let request = try f.request(.deviceBoundKey), challenge = f.handle(.request(request), 3).state!.challenge!
            check(challenge.keyID == nextID, "회전된 키 ID를 새 challenge에 결속")
            let oldProof = try proof(f, request: request, challenge: challenge)
            check(f.handle(oldProof, 4).state?.code == .invalidProof,
                  "회전 전 키 서명 거절")
            let revoke = try SentryReturnKeyEnrollment(action: .revoke, keyID: nextID)
            let revokeTicket = f.mac(try f.request(enrollment: revoke), 5)
            check(f.authority.capability(owner: f.snapshot.owner, macLocalAvailable: true).deviceBoundKey,
                  "해제 요청만으로 키가 바뀌지 않음")
            check(f.authenticate(revokeTicket, 6).state?.code == .keyRevoked &&
                !f.authority.capability(owner: f.snapshot.owner, macLocalAvailable: true).deviceBoundKey,
                  "키 해제도 현재 Mac 인증 완료 뒤에만 반영")
        }
        do {
            let f = try Fixture(), request = try f.request(), auth = f.mac(request)
            let ticket = returnTicket(f.authenticate(auth, 1))
            let failed = f.authority.restorationFailed(ticket, now: 2)
            check(failed.state?.authStatus == .succeeded && failed.state?.operationState == .failed,
                  "인증 성공 후 복귀 준비 실패를 분리")
        }
        do {
            let f = try Fixture(), request = try f.request(), auth = f.mac(request)
            let ticket = returnTicket(f.authenticate(auth, 1))
            let permit = f.authority.authorizeCommit(ticket, now: 2, current: { f.snapshot })!
            let cancelled = f.handle(.cancel(request.reference, authGeneration: ticket.challenge.authGeneration), 3)
            check(cancelled.state?.authStatus == .succeeded && cancelled.state?.operationState == .unknown,
                  "commit 시작 후 취소는 효과 불명확으로 구분")
            check(f.authority.completeReturn(permit, result: .verifiedRestored, now: 4,
                currentOwner: { f.snapshot.owner }).state == nil, "commit 취소 뒤 늦은 readback은 완료로 승격하지 않음")
        }
        do {
            let f = try Fixture(), request = try f.request(), auth = f.mac(request)
            _ = returnTicket(f.authenticate(auth, 1))
            check(f.authority.expire(now: 31).first?.state?.authStatus == .succeeded &&
                f.handle(.current(request.reference), 32).state?.operationState == .expired,
                  "복귀 30초 예산은 인증 상태와 독립적으로 만료")
        }
        do {
            let f = try Fixture(), request = try f.request(), auth = f.mac(request)
            let restarted = A()
            let lease = try SentryReturnLease(hostBootID: restarted.hostBootID, sessionID: UUID().uuidString.lowercased(),
                revision: UUID().uuidString.lowercased(), authorizationGeneration: UUID().uuidString.lowercased())
            let snapshot = A.Snapshot(owner: f.snapshot.owner, lease: lease)
            check(restarted.handle(.current(request.reference), now: 1, current: { snapshot }).state?.operationState == .unknown &&
                restarted.handle(.request(request), now: 2, current: { snapshot }).commands.isEmpty,
                  "재기동은 unknown이며 이전 boot 요청을 자동 실행하지 않음")
            check(restarted.completeMacAuthentication(auth, result: .authenticated, now: 3,
                current: { snapshot }).commands.isEmpty, "다른 authority의 인증 ticket 거절")
        }
        do {
            let f = try Fixture(); try f.enroll()
            let o = f.snapshot.owner
            for identity in ["owner", "device", "host", "pairing"] {
                let owner = A.Owner(ownerID: identity == "owner" ? "owner-2" : o.ownerID,
                    hostFingerprint: identity == "host" ? String(repeating: "ef", count: 32) : o.hostFingerprint,
                    deviceFingerprint: identity == "device" ? String(repeating: "ef", count: 32) : o.deviceFingerprint,
                    tlsFingerprint: identity == "device" ? String(repeating: "ef", count: 32) : o.tlsFingerprint,
                    pairingGeneration: identity == "pairing" ? UUID().uuidString.lowercased() : o.pairingGeneration,
                    encryptedTLS: true, currentPairedOwner: true)!
                check(!f.authority.capability(owner: owner, macLocalAvailable: true).deviceBoundKey,
                      "새 owner·앱 identity·호스트·페어링에 키 권한 자동 확대 없음 \(identity)")
            }
            try f.moveSession()
            check(f.authority.capability(owner: f.snapshot.owner, macLocalAvailable: true).deviceBoundKey,
                  "동일 owner/device의 TLS 재접속은 기존 등록만 유지")
        }
        for action in [SentryReturnKeyEnrollment.Action.enroll, .rotate, .revoke] {
            let f = try Fixture()
            if action != .enroll { try f.enroll() }
            let mutation = try SentryReturnKeyEnrollment(action: action,
                keyID: action == .revoke ? f.keyID : UUID().uuidString.lowercased(),
                publicKey: action == .revoke ? nil : P256.Signing.PrivateKey().publicKey.derRepresentation.base64EncodedString(),
                previousKeyID: action == .rotate ? f.keyID : nil)
            let ticket = f.mac(try f.request(enrollment: mutation), 1)
            let old = f.snapshot.lease
            f.snapshot = .init(owner: f.snapshot.owner, lease: try .init(hostBootID: old.hostBootID, sessionID: old.sessionID,
                revision: old.revision, authorizationGeneration: UUID().uuidString.lowercased()))
            let denied = f.authenticate(ticket, 2)
            check(!denied.commands.contains { if case .keyChanged = $0 { return true }; return false } &&
                f.authority.capability(owner: f.snapshot.owner, macLocalAvailable: true).deviceBoundKey == (action != .enroll),
                  "키 변경 Mac 인증 중 권한 세대가 바뀌면 기존 등록 보존 \(action)")
        }
        for result in [A.MacAuthenticationCompletion.denied, .cancelled, .unavailable] {
            let f = try Fixture()
            let mutation = try SentryReturnKeyEnrollment(action: .enroll, keyID: f.keyID,
                publicKey: f.key.publicKey.derRepresentation.base64EncodedString())
            let ticket = f.mac(try f.request(enrollment: mutation))
            let decision = f.authority.completeMacAuthentication(ticket, result: result, now: 1, current: { f.snapshot })
            check(!f.authority.capability(owner: f.snapshot.owner, macLocalAvailable: true).deviceBoundKey &&
                decision.state?.operationState != .completed, "Mac 인증 실패·취소·미지원으로 키 등록 불가 \(result)")
        }
        do {
            let f = try Fixture(), request = try f.request(), ticket = f.mac(request)
            var once = true
            let callback = f.authority.completeMacAuthentication(ticket, result: .authenticated, now: 1, current: {
                if once {
                    once = false
                    _ = f.handle(.cancel(request.reference, authGeneration: ticket.challenge.authGeneration), 1)
                }
                return f.snapshot
            })
            check(callback.commands.isEmpty && f.handle(.current(request.reference), 2).state?.operationState == .cancelled,
                  "현재 snapshot closure의 재진입 취소 뒤 늦은 인증 승격 거절")
        }
        do {
            let f = try Fixture(), request = try f.request()
            check(f.handle(.request(request), .greatestFiniteMagnitude).state == nil,
                  "표현 범위를 벗어난 monotonic 시간은 trap 없이 거절")
        }
        do {
            let f = try Fixture()
            for index in 0..<A.maximumRecords {
                let decision = f.handle(.request(try f.request(.deviceBoundKey)), Double(index))
                if decision.state?.code != .noEnrolledKey { fatalError("원장 용량 검사 전제 실패") }
            }
            let capacityRequest = try f.request(.deviceBoundKey)
            check(f.handle(.request(capacityRequest), Double(A.maximumRecords)).state?.code == .capacity,
                  "원장은 상한에서 거절하며 과거 요청을 제거·재실행하지 않음")
        }
    }
}
