import Foundation
import StreamProtocol

@main struct Checks {
    static var count = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ name: String) {
        guard (try? value()) == true else { print("FAIL \(name)"); exit(1) }
        count += 1
        print("PASS \(name)")
    }
    static func refuses(_ body: () throws -> Void, _ name: String) {
        do { try body(); expect(false, name) } catch { expect(true, name) }
    }
    final class Fixture {
        let gate = SentryAdmission()
        let object = NSObject()
        var peer: ObjectIdentifier { ObjectIdentifier(object) }
        let device = String(repeating: "ab", count: 32)
        init(external: Bool = false) {
            gate.configure(latched: false, persistenceHealthy: true)
            gate.register(peer, externalRoute: external)
            gate.admit(peer)
            _ = grant()
        }
        @discardableResult func grant() -> UUID {
            gate.grantControl(to: peer, verifiedOwner: SentryAdmission.VerifiedOwnerDevice(
                deviceID: device, encryptedTLS: true, currentPairedOwner: true)!)!
        }
        func request(_ desired: Bool, id: UUID = UUID()) -> SentryControlRequest {
            let s = gate.status(for: peer)!
            return try! SentryControlRequest(requestID: id, hostBootID: s.hostBootID, sessionID: s.sessionID,
                revision: s.revision, authorizationGeneration: s.control!.authorizationGeneration, desired: desired)
        }
        func prepare(_ r: SentryControlRequest) -> SentryAdmission.ControlTicket {
            guard case .prepared(let ticket, let response) = gate.prepareControl(r, from: peer) else {
                fatalError("새 작업 준비 실패")
            }
            expect(response.accepted && response.operationState == .pending && response.code == .pending,
                   "접수와 실제 적용을 구분함")
            return ticket
        }
        @discardableResult func apply(_ desired: Bool) -> SentryControlRequest {
            let r = request(desired), t = prepare(r)
            let response: SentryControlResponse?
            if desired {
                let epoch = UUID()
                gate.capture(epoch, for: peer)
                response = gate.completeControl(t, result: .onVerified(surfacesVerified: true, captureEpoch: epoch))
            } else {
                response = gate.completeControl(t, result: .offVerified(curtainsReleased: true, tapReleased: true, heldInputCleared: true))
            }
            expect(response?.operationState == .applied && response?.state.requested == desired &&
                   response?.state.phase == (desired ? .userSessionProtected : .inactive), "검증 결과와 적용 phase 일치")
            return r
        }
    }
    static func response(_ value: SentryAdmission.ControlPreparation) -> SentryControlResponse? {
        switch value {
        case .prepared(_, let r), .readback(let r), .rejected(let r): return r
        case .unauthorized: return nil
        }
    }
    static func mutate(_ request: SentryControlRequest, _ key: String, _ value: Any) -> SentryControlRequest {
        var object = try! JSONSerialization.jsonObject(with: request.rawRequest) as! [String: Any]
        object[key] = value
        return try! SentryControlRequest(rawRequest: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    static func codecChecks(_ archive: URL) throws {
        let supplied = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures.json")
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: supplied)) as! [String: Any]
        for key in ["requestOnRaw", "requestOffRaw"] {
            let r = try SentryControlRequest(rawRequest: Data((fixtures[key] as! String).utf8))
            let hashKey = key == "requestOnRaw" ? "requestOnSHA256" : "requestOffSHA256"
            expect(r.requestDigest == fixtures[hashKey] as? String, "공유 원본문 fixture와 production digest 동일")
        }
        for key in ["responseOnRaw", "responseOffRaw"] {
            _ = try SentryControlResponse.decodePayload(Data((fixtures[key] as! String).utf8))
            expect(true, "기기 공유 fixture를 production 응답 parser가 소비")
        }
        let uuid = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let request = try SentryControlRequest(requestID: uuid, hostBootID: uuid, sessionID: uuid,
            revision: uuid, authorizationGeneration: uuid, desired: true)
        expect(request.rawRequest.count <= 512 && request.requestDigest.count == 64, "요청 상한과 원본문 digest")
        expect(try SentryControlRequest(rawRequest: request.rawRequest) == request, "원본문 왕복")
        let raw = String(decoding: request.rawRequest, as: UTF8.self)
        for suffix in [",\"desired\":false", ",\"des\\u0069red\":false", ",\"future\":true"] {
            refuses({ _ = try SentryControlRequest(rawRequest: Data((raw.dropLast() + suffix + "}").utf8)) }, "중복·escape 중복·unknown 요청 키 거절")
        }
        for (key, value) in [("desired", 1 as Any), ("desired", "true" as Any), ("desired", NSNull()),
                             ("version", true as Any), ("version", 1 as Any), ("version", 3 as Any),
                             ("requestID", uuid.uuidString as Any), ("hostBootID", "bad" as Any),
                             ("sessionID", uuid.uuidString as Any), ("revision", uuid.uuidString as Any),
                             ("authorizationGeneration", uuid.uuidString as Any)] {
            var o = try JSONSerialization.jsonObject(with: request.rawRequest) as! [String: Any]
            o[key] = value
            refuses({ _ = try SentryControlRequest(rawRequest: JSONSerialization.data(withJSONObject: o)) }, "정확한 UUID·bool·version 타입 검증")
        }
        for text in [raw.replacingOccurrences(of: "\"version\":2", with: "\"version\":2.0"),
                     raw.replacingOccurrences(of: "\"version\":2", with: "\"version\":2e0"), raw + "{}", "[]", "{}"] {
            refuses({ _ = try SentryControlRequest(rawRequest: Data(text.utf8)) }, "비정수 버전·후행 객체·잘못된 구조 거절")
        }
        let exact = request.rawRequest + Data(repeating: 32, count: 512 - request.rawRequest.count)
        expect((try? SentryControlRequest(rawRequest: exact)) != nil, "512 bytes 경계 허용")
        refuses({ _ = try SentryControlRequest(rawRequest: exact + Data([32])) }, "513 bytes 거절")
        expect((try! SentryControlRequest(rawRequest: exact)).requestDigest != request.requestDigest, "공백도 원본문 멱등 비교에 포함")
        let cap = SentryControlCapability(authorizationGeneration: uuid, manualIntent: .on)
        let state = SentryState(hostBootID: uuid, sessionID: uuid, revision: uuid, requested: true,
            phase: .userSessionProtected, limitations: ["한국어 범위"], control: cap)
        let legacyState = SentryState(hostBootID: uuid, sessionID: uuid, revision: uuid, requested: false,
            phase: .inactive, limitations: [])
        let stateJSON = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        expect(state.version == 1 && stateJSON.contains(uuid.uuidString), "v1 State Foundation UUID coding 유지")
        expect(stateJSON.contains(uuid.uuidString.lowercased()), "control generation은 lowercase")
        expect(try JSONDecoder().decode(SentryState.self, from: JSONEncoder().encode(legacyState)).control == nil,
               "control 없는 legacy State 호환")
        let reply = SentryControlResponse(requestID: uuid, accepted: true, operationState: .applied, code: .applied, state: state)
        let replyData = try reply.encodedPayload()
        expect(try SentryControlResponse.decodePayload(replyData) == reply, "응답 wire 왕복")
        let replyText = String(decoding: replyData, as: UTF8.self)
        for suffix in [",\"code\":\"SENTRY_UNKNOWN\"", ",\"c\\u006fde\":\"SENTRY_UNKNOWN\"", ",\"future\":false"] {
            refuses({ _ = try SentryControlResponse.decodePayload(Data((replyText.dropLast() + suffix + "}").utf8)) }, "응답 중복·unknown 거절")
        }
        var ro = try JSONSerialization.jsonObject(with: replyData) as! [String: Any]
        for value in [NSNull() as Any, 1 as Any, "bad" as Any] {
            ro["code"] = value
            refuses({ _ = try SentryControlResponse.decodePayload(JSONSerialization.data(withJSONObject: ro)) }, "code null·타입·unknown 거절")
        }
        ro.removeValue(forKey: "code")
        refuses({ _ = try SentryControlResponse.decodePayload(JSONSerialization.data(withJSONObject: ro)) }, "code 생략 거절")
        let boundary = replyData + Data(repeating: 32, count: 4096 - replyData.count)
        expect((try? SentryControlResponse.decodePayload(boundary)) != nil, "4096 bytes 응답 경계")
        refuses({ _ = try SentryControlResponse.decodePayload(boundary + Data([32])) }, "4097 bytes 응답 거절")
        let nestedDuplicate = replyText.replacingOccurrences(of: "\"manualIntent\":\"on\"", with: "\"manualIntent\":\"on\",\"manualIntent\":\"off\"")
        refuses({ _ = try SentryControlResponse.decodePayload(Data(nestedDuplicate.utf8)) }, "중첩 capability 중복 거절")
        let legacy = SentryActivation(requestID: uuid, hostBootID: uuid, sessionID: uuid, revision: uuid)
        expect(try JSONDecoder().decode(SentryActivation.self, from: JSONEncoder().encode(legacy)) == legacy, "v1 on-only 요청 그대로 호환")
        let oldReply = SentryResponse(requestID: uuid, accepted: true, state: legacyState)
        expect(try JSONDecoder().decode(SentryResponse.self, from: JSONEncoder().encode(oldReply)) == oldReply, "v1 응답 그대로 호환")
        expect(StreamMessageKind.activateSentry.rawValue == 213 && StreamMessageKind.sentryState.rawValue == 214 &&
            StreamMessage.clientPayloadLimit(for: .activateSentry) == 512 && StreamMessage.hostPayloadLimit(for: .sentryState) == 4096,
            "기존 kind와 요청·응답 상한 유지")
        let off = try SentryControlRequest(requestID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            hostBootID: uuid, sessionID: uuid, revision: uuid, authorizationGeneration: uuid, desired: false)
        let offState = SentryState(hostBootID: uuid, sessionID: uuid, revision: uuid, requested: false, phase: .inactive,
            limitations: ["한국어 범위"], control: .init(authorizationGeneration: uuid, manualIntent: .off))
        let vectors: [String: Any] = ["version": 2, "kindRequest": 213, "kindResponse": 214,
            "requestOnRaw": raw, "requestOffRaw": String(decoding: off.rawRequest, as: UTF8.self),
            "responseOnRaw": replyText,
            "responseOffRaw": String(decoding: try SentryControlResponse(requestID: off.requestID, accepted: true,
                operationState: .applied, code: .applied, state: offState).encodedPayload(), as: UTF8.self),
            "requestOnSHA256": request.requestDigest, "requestOffSHA256": off.requestDigest]
        try JSONSerialization.data(withJSONObject: vectors, options: [.prettyPrinted, .sortedKeys]).write(to: archive.appendingPathComponent("fixtures.json"))
        try request.rawRequest.write(to: archive.appendingPathComponent("request-on.json"))
        try off.rawRequest.write(to: archive.appendingPathComponent("request-off.json"))
        for phase in SentryControlResponse.OperationState.allFixtureCases {
            let c: SentryControlResponse.Code
            switch phase { case .applied: c = .applied; case .pending: c = .pending; case .rejected: c = .busy; case .superseded: c = .superseded; case .unknown: c = .unknown }
            let value = SentryControlResponse(requestID: uuid, accepted: phase != .rejected && phase != .unknown,
                operationState: phase, code: c, state: offState)
            _ = try value.encodedPayload()
            expect(true, "operationState와 필수 code wire 확인")
        }
    }
    static func admissionChecks() {
        let f = Fixture(external: true), gate = f.gate, peer = f.peer
        let gen = f.grant(), beforeGrant = gate.status(for: peer)!
        expect(f.grant() == gen && gate.status(for: peer) == beforeGrant, "동일 grant 재호출은 revision과 세대 불변")
        expect(gate.allowsActions(peer) && !gate.isRequested, "외부 연결만으로 보호를 요청하거나 일반 action을 차단하지 않음")
        let off = f.request(false), ticket = f.prepare(off)
        expect(gate.controlTicketIsCurrent(ticket), "준비 ticket 현재성 확인")
        expect(!gate.allowsActions(peer) && !gate.allows(peer, epoch: nil), "off 전환 전 action/frame fence")
        let busy = response(gate.prepareControl(f.request(true), from: peer))!
        expect(busy.code == .busy && !busy.accepted, "동시 명령 busy")
        let duplicate = response(gate.prepareControl(off, from: peer))!
        expect(duplicate.operationState == .pending && duplicate.state == gate.status(for: peer), "pending 중 동일 원본문은 readback")
        let conflict = response(gate.prepareControl(mutate(off, "desired", true), from: peer))!
        expect(conflict.code == .requestConflict && !conflict.accepted, "동일 ID의 다른 원본문 conflict")
        for key in ["hostBootID", "sessionID", "revision", "authorizationGeneration"] {
            expect(response(gate.prepareControl(mutate(off, key, UUID().uuidString.lowercased()), from: peer))?.code == .requestConflict,
                "알려진 동일 작업의 ID 필드를 고쳐도 원본문 conflict")
        }
        let spaced = try! SentryControlRequest(rawRequest: off.rawRequest + Data([32]))
        expect(response(gate.prepareControl(spaced, from: peer))?.code == .requestConflict,
            "동일 필드의 공백 변경도 같은 원본문으로 간주하지 않음")
        let epoch = UUID()
        gate.capture(epoch, for: peer)
        let applied = gate.completeControl(ticket, result: .offVerified(curtainsReleased: true, tapReleased: true, heldInputCleared: true))!
        expect(applied.operationState == .applied && applied.state.phase == .inactive && !applied.state.requested, "off 실제 검증 후만 applied")
        expect(gate.allows(peer, epoch: epoch) && gate.allowsActions(peer), "off는 기존 session/capture 유지")
        let inactive = gate.inactiveSnapshot()!
        expect(gate.protectionSnapshot() == nil && gate.inactiveMatches(inactive), "inactive 별도 증명과 active 증명 분리")
        for _ in 0..<2 {
            gate.requireProtection()
            gate.capture(UUID(), for: peer)
            expect(!gate.isRequested && gate.allowsActions(peer), "첫/두번째 click 전 자동 보호·프레임이 manual off를 덮지 않음")
        }
        expect(gate.inactiveMatches(inactive), "capture만 갱신되면 inactive 증명 유지")
        let fresh = response(gate.prepareControl(off, from: peer))!
        expect(fresh.operationState == .applied && fresh.state == gate.status(for: peer) && fresh.state.revision != applied.state.revision,
            "capture 변경은 superseded가 아니며 항상 최신 state")
        let unknownObject = NSObject(), anonymous = ObjectIdentifier(unknownObject)
        expect(response(gate.prepareControl(off, from: anonymous)) == nil, "미등록 peer state oracle 없음")
        gate.register(anonymous, externalRoute: true)
        expect(response(gate.prepareControl(off, from: anonymous)) == nil, "미승인 peer state oracle 없음")
        gate.admit(anonymous)
        expect(response(gate.prepareControl(off, from: anonymous)) == nil, "일반 admitted만으로 control 권한 없음")
        expect(!gate.isRequested, "다른 external 등록도 신뢰 유지 manual off를 덮지 않음")
        gate.remove(peer)
        gate.register(peer, externalRoute: true); gate.admit(peer)
        expect(f.grant() == gen, "동일 owner 재접속 전용 generation 유지")
        let reconnected = response(gate.prepareControl(off, from: peer))!
        expect(reconnected.operationState == .applied && reconnected.state.sessionID != off.sessionID && !gate.isRequested,
            "이전 session 원본문을 새 session에서 읽기만 함")
        expect(response(gate.prepareControl(mutate(off, "revision", UUID().uuidString.lowercased()), from: peer))?.code == .requestConflict,
            "이전 본문의 CAS 고치면 conflict")
        let noLedger = mutate(off, "requestID", UUID().uuidString.lowercased())
        expect(response(gate.prepareControl(noLedger, from: peer))?.code == .unknown, "이전 session의 원장 없는 작업은 unknown")
        let on = f.request(true), onTicket = f.prepare(on)
        expect(!gate.inactiveMatches(inactive), "명시 on 준비가 inactive 증명을 회수")
        expect(gate.completeControl(onTicket, result: .pending)?.operationState == .pending, "capture 도착 전 pending 유지")
        let onEpoch = UUID()
        gate.capture(onEpoch, for: peer)
        expect(gate.controlTicketIsCurrent(onTicket), "새 capture 자체가 pending ticket을 무효화하지 않음")
        expect(gate.completeControl(onTicket, result: .onVerified(surfacesVerified: true, captureEpoch: onEpoch))?.state.phase == .userSessionProtected,
            "on은 현재 표면·capture 증명 뒤 보호 phase")
        expect(response(gate.prepareControl(off, from: peer))?.operationState == .superseded, "다음 명시 명령 적용 뒤 과거 작업 superseded")
        let stable = gate.status(for: peer)!
        _ = gate.completeControl(ticket, result: .offVerified(curtainsReleased: true, tapReleased: true, heldInputCleared: true))
        expect(gate.status(for: peer) == stable, "오래된 completion이 현재 정책을 변경하지 않음")
        let wrong = f.request(false)
        for key in ["revision", "sessionID", "hostBootID", "authorizationGeneration"] {
            let r = response(gate.prepareControl(mutate(wrong, key, UUID().uuidString.lowercased()), from: peer))!
            expect(!r.accepted && r.operationState != .pending && r.state == gate.status(for: peer), "잘못된 boot/session/revision/generation 효과 없음")
        }
        let currentTicket = f.prepare(f.request(false))
        gate.revokeControl(forDeviceID: f.device)
        expect(!gate.controlTicketIsCurrent(currentTicket) && gate.completeControl(currentTicket, result: .offVerified(curtainsReleased: true, tapReleased: true, heldInputCleared: true)) == nil,
            "권한 회수 뒤 pending completion 효과 없음")
        expect(response(gate.prepareControl(on, from: peer)) == nil, "회수된 peer는 과거 작업으로 state 조회 불가")
        let newGen = f.grant()
        expect(newGen != gen && response(gate.prepareControl(on, from: peer))?.code == .notAuthorized, "재등록은 새 세대이고 과거 세대는 권한 대체 불가")
        let restarted = Fixture()
        expect(response(restarted.gate.prepareControl(on, from: restarted.peer))?.code == .unknown, "새 Hostboot은 과거 작업 unknown")
        for good in [false, true] {
            expect(SentryAdmission.VerifiedOwnerDevice(deviceID: String(repeating: "A", count: 64), encryptedTLS: true, currentPairedOwner: good) == nil,
                "지문은 32byte SHA256 lowerhex만")
        }
        expect(SentryAdmission.VerifiedOwnerDevice(fingerprintData: Data(repeating: 0xab, count: 32), encryptedTLS: true, currentPairedOwner: true)?.deviceID == f.device &&
               SentryAdmission.VerifiedOwnerDevice(fingerprintData: Data(repeating: 0xab, count: 31), encryptedTLS: true, currentPairedOwner: true) == nil,
            "현재 TLS fingerprintData는 정확히 32 bytes")
        expect(SentryAdmission.VerifiedOwnerDevice(deviceID: f.device, encryptedTLS: false, currentPairedOwner: true) == nil &&
               SentryAdmission.VerifiedOwnerDevice(deviceID: f.device, encryptedTLS: true, currentPairedOwner: false) == nil, "plaintext/selfclaim grant 생성 거절")
    }
    static func lifecycleChecks() {
        let f = Fixture(), gate = f.gate, peer = f.peer
        let evicted = f.apply(false)
        for _ in 0..<132 { _ = f.apply(false) }
        expect(gate.allowsActions(peer), "bounded ledger는 평생 quota가 아님")
        expect(response(gate.prepareControl(evicted, from: peer))?.code == .unknown && !gate.isRequested,
            "만료된 같은 session의 이전 원본문은 unknown이며 효과 재실행 없음")
        let first = f.apply(true)
        gate.capture(UUID(), for: peer)
        expect(response(gate.prepareControl(first, from: peer))?.operationState == .applied, "프레임 갱신만으로 과거 적용을 superseded하지 않음")
        let t = f.prepare(f.request(false))
        let failure = gate.completeControl(t, result: .offVerified(curtainsReleased: true, tapReleased: false, heldInputCleared: true))!
        expect(failure.accepted && failure.operationState == .rejected && failure.code == .targetUnconfirmed && !gate.allowsActions(peer),
            "tap/held/curtain 중 미확인 하나라도 applied 금지")
        let next = f.prepare(f.request(false))
        expect(gate.completeControl(next, result: .failed)?.code == .controlFailed, "실제 실패 code와 fence 정리")
        let pending = f.prepare(f.request(true))
        gate.remove(peer)
        expect(!gate.controlTicketIsCurrent(pending), "disconnect는 pending effect 완료 권한을 제거")
        gate.register(peer, externalRoute: true); gate.admit(peer); _ = f.grant()
        expect(response(gate.prepareControl(pending.request, from: peer))?.operationState == .unknown, "disconnect 중 미확인 작업은 unknown readback")
        let replacement = f.prepare(f.request(false))
        let beforeStale = gate.status(for: peer)
        _ = gate.completeControl(pending, result: .onVerified(surfacesVerified: true, captureEpoch: UUID()))
        expect(gate.status(for: peer) == beforeStale && gate.controlTicketIsCurrent(replacement) && !gate.allowsActions(peer),
            "오래된 completion은 새 pending의 fence와 상태를 바꾸지 않음")
        _ = gate.completeControl(replacement, result: .offVerified(curtainsReleased: true, tapReleased: true, heldInputCleared: true))
        _ = f.apply(false)
        gate.remove(peer)
        gate.revokeControl(forDeviceID: f.device)
        expect(!gate.isRequested, "active external 없는 신뢰 회수는 자동 inactive")
        gate.register(peer, externalRoute: true); gate.admit(peer); _ = f.grant()
        expect(!gate.isRequested, "권한 회수 후 다음 external 연결도 OFF 유지")
        _ = f.apply(false)
        gate.revokeControl(forDeviceID: f.device)
        expect(!gate.isRequested, "active external 있는 manual owner 회수도 OFF 유지")
        _ = f.grant(); _ = f.apply(false)
        gate.requireProtection()
        gate.update(verified: false, persistenceHealthy: true, reason: nil)
        gate.capture(UUID())
        expect(!gate.isRequested, "idle/포커스 경로의 자동 요청과 표면 갱신도 off 유지")
        let state = gate.status(for: peer)!
        let legacy = SentryActivation(hostBootID: state.hostBootID, sessionID: state.sessionID, revision: state.revision)
        expect(gate.accept(legacy, from: peer) && gate.isRequested && gate.status(for: peer)?.control?.manualIntent == .on,
            "v1 명시 on이 manual off를 바꾸며 자동 register와 구분")
        expect(gate.accept(legacy, from: peer), "v1 duplicate on은 재적용 없음")
        gate.fenceForLocalReturn()
        expect(!gate.allowsActions(peer) && response(gate.prepareControl(f.request(false), from: peer))?.code == .busy,
            "인증 로컬 복귀 fence 중 새 원격 명령 busy")
        gate.completeLocalReturn()
        expect(gate.status(for: peer) == nil && response(gate.prepareControl(first, from: peer)) == nil, "로컬 복귀는 세션·권한·원장을 회수")
    }
    static func reentrantReleaseFenceChecks() {
        let f = Fixture(), gate = f.gate, peer = f.peer, epoch = UUID()
        gate.capture(epoch, for: peer)
        expect(gate.allowsActions(peer) && gate.allows(peer, epoch: epoch), "release 준비 전 일반 입력과 frame 허용 상태")
        let request = f.request(false), ticket = f.prepare(request)
        var queuedDownOrKey = 0
        func verifyReleaseWithSynchronousChangedCallback() {
            if gate.allowsActions(peer) { queuedDownOrKey += 1 }
            if gate.allows(peer, epoch: epoch) { queuedDownOrKey += 1 }
        }
        verifyReleaseWithSynchronousChangedCallback()
        expect(queuedDownOrKey == 0 && gate.sourceSelectionAdmission(for: peer)?.ready == false,
            "표면 verify의 동기 changed 재진입은 종료 부채 뒤 새 down/key를 추가하지 않음")
        expect(gate.completeControl(ticket, result: .pending)?.operationState == .pending,
            "물리 release가 아직 끝나지 않았으면 pending fence 유지")
        verifyReleaseWithSynchronousChangedCallback()
        expect(queuedDownOrKey == 0 && gate.controlTicketIsCurrent(ticket), "비동기 완료 전 재진입도 현재 실행 fence로 거절")
        expect(response(gate.prepareControl(request, from: peer))?.operationState == .pending,
            "generic 입력 fence 동안 제어권한 readback 경로는 계속 열림")
        _ = gate.completeControl(ticket, result: .offVerified(curtainsReleased: true, tapReleased: true, heldInputCleared: true))
        expect(gate.allowsActions(peer) && gate.allows(peer, epoch: epoch), "실제 종료 부채 정리와 release 완료 뒤만 일반 경로 재개")
        let on = f.prepare(f.request(true))
        _ = gate.completeControl(on, result: .onPrepared(surfacesVerified: true))
        expect(!gate.controlTicketIsCurrent(on) && gate.allowsActions(peer) && gate.sourceSelectionAdmission(for: peer)?.ready == true,
            "onPrepared는 실행 fence를 해제하고 검증된 표면의 source selection 준비를 복구")
    }
    static func preparedOnChecks() {
        let f = Fixture(), gate = f.gate, peer = f.peer
        let request = f.request(true), ticket = f.prepare(request)
        let prepared = gate.completeControl(ticket, result: .onPrepared(surfacesVerified: true))!
        expect(prepared.operationState == .pending && prepared.state.phase == .pending && prepared.state.requested,
            "on 표면 확정은 capture 미선택일 때 pending")
        expect(!gate.controlTicketIsCurrent(ticket) && gate.allowsActions(peer) && gate.sourceSelectionAdmission(for: peer)?.ready == true,
            "onPrepared는 실행 fence를 풀고 소스 선택을 허용")
        expect(response(gate.prepareControl(request, from: peer))?.operationState == .pending, "onPrepared 동일 원본문 readback은 pending")
        let epoch = UUID()
        gate.capture(epoch, for: peer)
        expect(response(gate.prepareControl(request, from: peer))?.operationState == .applied,
            "같은 정책에서 현재 capture 확인 후 원작업 applied 승격")
        gate.capture(nil, for: peer)
        expect(response(gate.prepareControl(request, from: peer))?.operationState == .applied,
            "한번 적용된 작업의 기록은 후속 capture 해제로 재실행되지 않음")
        let second = Fixture(), r = second.request(true), t = second.prepare(r)
        _ = second.gate.completeControl(t, result: .onPrepared(surfacesVerified: true))
        _ = second.apply(false)
        expect(response(second.gate.prepareControl(r, from: second.peer))?.operationState == .superseded,
            "capture 선택 전 새 명시 off 허용 및 이전 pending on superseded")
        let stable = second.gate.status(for: second.peer)
        _ = second.gate.completeControl(t, result: .onPrepared(surfacesVerified: true))
        expect(stable == second.gate.status(for: second.peer), "확정한 onPrepared ticket 재완료는 효과 없음")
    }
    static func raceChecks() {
        let f = Fixture(), secondObject = NSObject(), second = ObjectIdentifier(secondObject)
        f.gate.register(second, externalRoute: false); f.gate.admit(second)
        _ = f.gate.grantControl(to: second, verifiedOwner: .init(deviceID: String(repeating: "cd", count: 32), encryptedTLS: true, currentPairedOwner: true)!)
        let a = f.request(false), s = f.gate.status(for: second)!
        let b = try! SentryControlRequest(hostBootID: s.hostBootID, sessionID: s.sessionID, revision: s.revision,
            authorizationGeneration: s.control!.authorizationGeneration, desired: true)
        let resultsLock = NSLock()
        var prepared = 0, busy = 0
        DispatchQueue.concurrentPerform(iterations: 2) { n in
            let result = f.gate.prepareControl(n == 0 ? a : b, from: n == 0 ? f.peer : second)
            resultsLock.lock(); defer { resultsLock.unlock() }
            if case .prepared = result { prepared += 1 }
            if response(result)?.code == .busy { busy += 1 }
        }
        expect(prepared == 1 && busy == 1, "다중 peer 동시 CAS는 한 작업만 효과 준비")
    }
    static func main() throws {
        try codecChecks(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        admissionChecks()
        lifecycleChecks()
        reentrantReleaseFenceChecks()
        preparedOnChecks()
        raceChecks()
        print("CHECKS_COMPLETE \(count)")
    }
}
private extension SentryControlResponse.OperationState {
    static var allFixtureCases: [Self] { [.applied, .pending, .rejected, .superseded, .unknown] }
}
