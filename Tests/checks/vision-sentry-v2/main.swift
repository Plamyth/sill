import Foundation
import Network
import StreamProtocol

var assertions = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    assertions += 1
    if !condition() { failures += 1; print("FAIL \(label)") }
}
func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
final class Journal {
    var records: [VisionSentryStoredRequest] = []
    var failLoad = false
    var failSave = false
    var corruptReadback = false
    var writes = 0
    var store: VisionSentryRequestStore {
        .init(load: {
            if self.failLoad { throw VisionSentryRequestStore.Failure.storage }
            return self.corruptReadback ? [] : self.records
        }, save: {
            self.writes += 1
            if self.failSave { throw VisionSentryRequestStore.Failure.storage }
            self.records = $0
        })
    }
}
let peer = NWConnection(), other = NWConnection()
let p = ObjectIdentifier(peer), q = ObjectIdentifier(other)
let boot = UUID(), session = UUID(), generation = UUID()
let binding = VisionSentryStoredRequest.Binding(macID: "fixture-mac", hostFingerprint: Data(repeating: 1, count: 32),
    deviceFingerprint: Data(repeating: 2, count: 32))
func state(_ phase: SentryState.Phase = .inactive, requested: Bool = false, intent: SentryManualIntent = .automatic,
           revision: UUID = UUID(), bootID: UUID = boot, sessionID: UUID = session, auth: UUID = generation,
           capability: Bool = true) -> SentryState {
    .init(hostBootID: bootID, sessionID: sessionID, revision: revision, requested: requested, phase: phase,
        limitations: ["현재 로그인 세션"], control: capability ? .init(authorizationGeneration: auth, manualIntent: intent) : nil)
}
func list(_ value: SentryState?, source: StreamSource = .desktop) -> WindowList {
    .init(macName: "검사 Mac", windows: [], active: source, sentry: value)
}
func model(_ journal: Journal, _ initial: SentryState = state()) -> VisionSentryController {
    let m = VisionSentryController(store: journal.store)
    m.bind(p, trusted: true, identity: binding)
    m.observe(list(initial), from: p)
    return m
}
func begin(_ m: VisionSentryController, desired: Bool?, now: TimeInterval = 0) -> SentryControlRequest {
    let r = m.beginControl(desired: desired, now: now, cancel: {})!
    check(m.submitControl(r, to: p, now: now, send: { true }), "현재 피어 전송 허용")
    return r
}
func reply(_ r: SentryControlRequest, _ status: SentryControlResponse.OperationState = .applied,
           value: SentryState, accepted: Bool = true, code: SentryControlResponse.Code? = nil) -> SentryControlResponse {
    let codes: [SentryControlResponse.OperationState: SentryControlResponse.Code] = [
        .applied: .applied, .pending: .pending, .rejected: .busy, .superseded: .superseded, .unknown: .unknown]
    return .init(requestID: r.requestID, accepted: accepted, operationState: status, code: code ?? codes[status]!, state: value)
}

let fixtureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let fixture = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
for name in ["On", "Off"] {
    let raw = Data((fixture["request\(name)Raw"] as! String).utf8)
    let request = try SentryControlRequest(rawRequest: raw)
    check(request.requestDigest == fixture["request\(name)SHA256"] as? String, "공유 요청 원문 SHA256 \(name)")
    check(request.rawRequest == raw && request.desired == (name == "On"), "공유 요청 바이트·명시 의도 \(name)")
    let response = try SentryControlResponse.decodePayload(Data((fixture["response\(name)Raw"] as! String).utf8))
    check(response.requestID == request.requestID && response.operationState == .applied, "공유 응답 \(name)")
    let roundTrip = try SentryControlResponse.decodePayload(response.encodedPayload())
    check(roundTrip == response, "응답 엄격 왕복 \(name)")
    for mutation in [String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\"version\":2", with: "\"version\":2,\"version\":2"),
                     String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\"desired\":", with: "\"extra\":1,\"desired\":")] {
        check((try? SentryControlRequest(rawRequest: Data(mutation.utf8))) == nil, "중복·추가 키 거절 \(name)")
    }
}

let journal = Journal(), m = model(journal)
let request = m.beginControl(desired: true, now: 0, cancel: {})!
check(journal.writes == 1 && journal.records.last?.rawRequest == request.rawRequest, "전송 전 원문 영속 저장")
check(m.snapshot.accepted == nil && m.snapshot.operationState == nil, "로컬 전송 접수는 Host 수락 아님")
check(journal.records.last?.ledgerAccepted == false && !m.snapshot.canReadback, "saved-only는 원장 접수 미확인")
var sends = 0
check(m.submitControl(request, to: p, now: 1, send: {
    sends += 1
    return journal.records.last?.rawRequest == request.rawRequest
}), "저장 readback 후에만 전송")
check(!m.submitControl(request, to: p, now: 1, send: { sends += 1; return true }) && sends == 1, "중복 submit 차단")
check(journal.records.last?.ledgerAccepted == false && journal.records.last?.hasTerminalReceipt == false,
    "송신 ACK는 접수·종료 확인으로 저장하지 않음")
check(m.beginControl(desired: false, now: 1, cancel: {}) == nil, "응답 전 중복 전환 차단")
let prepared = state(.userSessionProtected, requested: true, intent: .on)
m.receiveControl(reply(request, .pending, value: prepared), from: p, now: 2)
check(m.snapshot.accepted == true && m.snapshot.operationState == .pending, "onPrepared 수락과 적용 대기 분리")
check(m.snapshot.message.contains("적용 대기") && m.snapshot.canDeactivate, "capture 전 pending on의 새 off 허용")
check(journal.records.last?.ledgerAccepted == true && m.snapshot.canReadback, "Host accepted true만 원장 접수로 영속 보존")
check(journal.records.last?.hasTerminalReceipt == false, "accepted pending은 종료 기록 아님")
let writesBeforeReadback = journal.writes
let read = begin(m, desired: nil, now: 3)
check(read.rawRequest == request.rawRequest && journal.writes == writesBeforeReadback, "pending 원문 재조회는 재인코딩·추가 저장 없음")
m.receiveControl(reply(read, value: prepared), from: p, now: 4)
check(m.snapshot.operationState == .applied, "capture 확인 후 같은 원문 applied")
check(journal.records.last?.hasTerminalReceipt == true, "이미 접수된 pending도 applied 영수증을 별도 영속 저장")
let off = begin(m, desired: false, now: 5)
check(off.requestID != request.requestID && !off.desired && journal.records.count == 2, "명시 off는 새 요청이며 옛 원문 보존")
let pendingOff = state(.pending, requested: false, intent: .on)
m.observe(list(pendingOff, source: .none), from: p)
check(m.snapshot.available && m.snapshot.pendingID == off.requestID, "v2 pending false catalog는 진행 중이며 기존 요청 유지")
m.receiveControl(reply(off, .pending, value: pendingOff), from: p, now: 6)
check(m.snapshot.operationState == .pending && !m.snapshot.message.contains("적용을 확인"), "pending false 응답은 완료 아님")
let offRead = begin(m, desired: nil, now: 7)
let inactive = state(intent: .off)
m.receiveControl(reply(offRead, value: inactive), from: p, now: 8)
check(m.snapshot.operationState == .applied && m.snapshot.state?.phase == .inactive && m.snapshot.state?.requested == false,
    "off applied·inactive·false 동일 권한 수용")

let pendingOnJournal = Journal(), pendingOn = model(pendingOnJournal)
let onBeforeCapture = begin(pendingOn, desired: true)
pendingOn.receiveControl(reply(onBeforeCapture, .pending, value: prepared), from: p, now: 1)
pendingOn.observe(list(prepared, source: .none), from: p)
let beforeCaptureOff = begin(pendingOn, desired: false, now: 2)
check(!beforeCaptureOff.desired && beforeCaptureOff.revision == prepared.revision, "capture 전 새 off는 현재 CAS에서 생성")

let freshSession = UUID()
let restored = model(journal, state(intent: .off, sessionID: freshSession))
check(restored.snapshot.canReadback && !restored.snapshot.canActivate, "앱 재실행 뒤 수동 재조회 전 새 전환 차단")
let restoredRead = begin(restored, desired: nil)
check(restoredRead.rawRequest == off.rawRequest && restoredRead.sessionID != freshSession, "재실행 때 옛 session·revision 원문 그대로")
restored.receiveControl(reply(restoredRead, value: state(intent: .off, sessionID: freshSession)), from: p, now: 1)
check(restored.snapshot.operationState == .applied, "재실행 뒤 현재 session 응답으로 재조회 확인")
restored.bind(nil, trusted: false)
restored.bind(q, trusted: true, identity: binding)
restored.observe(list(state(intent: .off, sessionID: freshSession)), from: q)
check(restored.snapshot.canReadback && restored.snapshot.operationState == nil, "같은 신뢰 연결 복귀는 자동 전송 없음·수동 가능")
let reconnectRead = restored.beginControl(desired: nil, now: 2, cancel: {})!
check(reconnectRead.rawRequest == off.rawRequest, "재연결도 원본문 유지")

for changed in ["mac", "hostPin", "devicePin", "boot", "generation", "revoked", "missingCapability"] {
    let protected = model(journal)
    let changedBinding = VisionSentryStoredRequest.Binding(macID: changed == "mac" ? "다른 Mac" : binding.macID,
        hostFingerprint: changed == "hostPin" ? Data(repeating: 3, count: 32) : binding.hostFingerprint,
        deviceFingerprint: changed == "devicePin" ? Data(repeating: 4, count: 32) : binding.deviceFingerprint)
    protected.bind(p, trusted: changed != "revoked", identity: changedBinding)
    protected.observe(list(state(bootID: changed == "boot" ? UUID() : boot,
        auth: changed == "generation" ? UUID() : generation, capability: changed != "missingCapability")), from: p)
    check(!protected.snapshot.canReadback && protected.beginControl(desired: nil, now: 0, cancel: {}) == nil,
        "다른 binding·권한 원문 실행 금지 \(changed)")
    check(journal.records.count == 2, "거절 시 보존 기록 유지 \(changed)")
}

for failure in ["load", "save", "readback", "full"] {
    let bad = Journal()
    bad.failLoad = failure == "load"
    bad.failSave = failure == "save"
    if failure == "full" {
        bad.records = Array(repeating: .init(binding: binding, rawRequest: request.rawRequest, ledgerAccepted: true),
            count: VisionSentryRequestStore.maximumRecords)
    }
    let blocked = model(bad)
    bad.corruptReadback = failure == "readback"
    check(blocked.beginControl(desired: true, now: 0, cancel: {}) == nil, "저장 실패 시 전송 불가 \(failure)")
}

for status in [SentryControlResponse.OperationState.rejected, .superseded, .unknown] {
    let j = Journal(), operation = model(j)
    let r = begin(operation, desired: false)
    operation.receiveControl(reply(r, status, value: state(), accepted: status == .superseded), from: p, now: 1)
    check(operation.snapshot.operationState == status && operation.snapshot.canReadback == (status == .superseded), "결과별 독립 상태·canonical 재조회 \(status)")
    if status == .unknown { check(!operation.snapshot.canActivate && !operation.snapshot.canDeactivate, "unknown은 새 toggle 차단") }
}

for invalid in ["peer", "id", "boot", "generation", "session", "offPending", "offRequested", "offIntent", "accepted"] {
    let j = Journal(), operation = model(j)
    let r = begin(operation, desired: false)
    let result = state(invalid == "offPending" ? .pending : .inactive, requested: invalid == "offRequested",
        intent: invalid == "offIntent" ? .on : .off, bootID: invalid == "boot" ? UUID() : boot,
        sessionID: invalid == "session" ? UUID() : session, auth: invalid == "generation" ? UUID() : generation)
    let response = SentryControlResponse(requestID: invalid == "id" ? UUID() : r.requestID,
        accepted: invalid != "accepted", operationState: .applied, code: .applied, state: result)
    operation.receiveControl(response, from: invalid == "peer" ? q : p, now: 1)
    check(operation.snapshot.operationState != .applied && operation.snapshot.pendingID == r.requestID,
        "off 완료 거짓 응답 차단 \(invalid)")
    check(!j.records[0].hasTerminalReceipt, "잘못된 완료 응답은 종료 영수증 저장 금지 \(invalid)")
}

let timeJournal = Journal(), timed = model(timeJournal), timedRequest = begin(timed, desired: true)
timed.timeout(timedRequest.requestID, now: 8)
check(timed.snapshot.operationState == .unknown && !timed.snapshot.canReadback && !timed.snapshot.canActivate, "timeout은 미확인·같은 세션 재전송 차단")
check(timed.snapshot.readbackNeedsNewSession && timed.beginControl(desired: nil, now: 9, cancel: {}) == nil,
    "응답 미확인 원문은 같은 세션 조회 금지")
timed.bind(nil, trusted: false); timed.bind(p, trusted: true, identity: binding)
timed.observe(list(state(sessionID: UUID())), from: p)
let retried = begin(timed, desired: nil, now: 9)
check(retried.rawRequest == timedRequest.rawRequest, "timeout 뒤 ID 새로 만들지 않음")

let attemptJournal = Journal(), attempts = model(attemptJournal)
let firstAttempt = UUID(), secondAttempt = UUID()
let first = attempts.beginControl(desired: false, attemptID: firstAttempt, now: 0, cancel: {})!
attempts.cancelled(first.requestID, attemptID: firstAttempt)
check(attempts.beginControl(desired: nil, now: 1, cancel: {}) == nil, "취소 직후 같은 세션 조회 금지")
attempts.bind(nil, trusted: false); attempts.bind(p, trusted: true, identity: binding)
attempts.observe(list(state(sessionID: UUID())), from: p)
let second = attempts.beginControl(desired: nil, attemptID: secondAttempt, now: 1, cancel: {})!
attempts.cancelled(first.requestID, attemptID: firstAttempt)
attempts.timeout(first.requestID, now: 100, attemptID: firstAttempt)
check(attempts.snapshot.pendingID == second.requestID, "옛 attempt 취소·timeout이 동일 원문 새 재조회를 취소하지 않음")
check(!attempts.submitControl(first, to: p, now: 1, attemptID: firstAttempt, send: { true }), "옛 attempt 큐 전송 차단")
check(attempts.submitControl(second, to: p, now: 1, attemptID: secondAttempt, send: { true }), "현재 attempt만 원문 전송")

let legacy = model(Journal(), state(.pending, requested: false, capability: false))
check(!legacy.snapshot.available && !legacy.snapshot.canDeactivate, "v1 pending false 보수 경계 유지")
let inactiveOff = state(intent: .off)
let idempotent = model(Journal(), inactiveOff)
let repeatedOff = begin(idempotent, desired: false)
let sameRevisionPending = state(.pending, intent: .off, revision: inactiveOff.revision)
idempotent.observe(list(sameRevisionPending), from: p)
check(idempotent.snapshot.state == sameRevisionPending && idempotent.snapshot.pendingID == repeatedOff.requestID,
    "v2 멱등 off의 동일 revision pending false catalog 수용")
idempotent.receiveControl(reply(repeatedOff, .pending, value: sameRevisionPending), from: p, now: 1)
check(idempotent.snapshot.available && idempotent.snapshot.operationState == .pending && idempotent.snapshot.accepted == true,
    "inactive에서 멱등 off의 pending false도 완료로 표시하지 않음")
let expired = model(Journal())
let expiredRequest = expired.beginControl(desired: false, now: 0, cancel: {})!
check(!expired.submitControl(expiredRequest, to: p, now: 8, send: { true }) && !expired.snapshot.canReadback &&
    expired.snapshot.operationState == .unknown && expired.snapshot.readbackNeedsNewSession,
    "전송 전 만료의 saved-only 원문은 같은 세션에서 재실행 금지")
let noBinding = VisionSentryController(store: Journal().store)
noBinding.bind(p, trusted: true); noBinding.observe(list(state()), from: p)
check(!noBinding.snapshot.canDeactivate && !noBinding.snapshot.canActivate, "v2 TLS binding 미확인이면 v1으로 우회하지 않음")

for stage in ["saved-only", "sent-no-response", "send-failed", "accepted-rejected"] {
    let j = Journal(), originalState = state(), originalModel = model(j, originalState)
    let raw = originalModel.beginControl(desired: false, now: 0, cancel: {})!
    if stage != "saved-only" {
        _ = originalModel.submitControl(raw, to: p, now: 0, send: { stage != "send-failed" })
    }
    if stage == "accepted-rejected" {
        originalModel.receiveControl(reply(raw, .rejected, value: originalState, accepted: true), from: p, now: 1)
        check(originalModel.snapshot.operationState == .rejected && originalModel.snapshot.message.contains("원장 접수는 확인"),
            "accepted true rejected는 접수와 적용 거절 구분")
    }
    let restarted = model(j, originalState)
    check(j.records[0].ledgerAccepted == (stage == "accepted-rejected"), "접수 확인만 저장 \(stage)")
    check(restarted.snapshot.canReadback == (stage == "accepted-rejected"), "앱 재실행 같은 세션 canonical 정책 \(stage)")
    if stage != "accepted-rejected" {
        check(restarted.beginControl(desired: nil, now: 2, cancel: {}) == nil, "미접수 원문 같은 세션 조회 0 \(stage)")
        restarted.bind(nil, trusted: false); restarted.bind(p, trusted: true, identity: binding)
        let newSession = state(sessionID: UUID())
        restarted.observe(list(newSession), from: p)
        let safeRead = begin(restarted, desired: nil, now: 3)
        check(safeRead.rawRequest == raw.rawRequest && safeRead.sessionID != newSession.sessionID,
            "새 세션에서만 옛 CAS 원문 조회 \(stage)")
        restarted.receiveControl(reply(safeRead, .unknown, value: newSession, accepted: false), from: p, now: 4)
        check(restarted.snapshot.operationState == .unknown && j.records.count == 1 && !restarted.snapshot.canActivate &&
            !restarted.snapshot.canDeactivate && j.records[0].rawRequest == raw.rawRequest,
            "unknown은 새 ID·변경 CAS 명령 없이 보존 \(stage)")
    } else {
        let confirmed = begin(restarted, desired: nil, now: 2)
        check(confirmed.rawRequest == raw.rawRequest, "accepted true rejected 원문은 같은 세션 재조회 가능")
    }
}

let evictedJournal = Journal(), evicted = model(evictedJournal)
let evictedRequest = begin(evicted, desired: false)
evicted.receiveControl(reply(evictedRequest, value: state(intent: .off)), from: p, now: 1)
let afterEviction = state(.userSessionProtected, requested: true, intent: .on)
evicted.observe(list(afterEviction), from: p)
let evictedRead = begin(evicted, desired: nil, now: 2)
check(evictedRead.rawRequest == evictedRequest.rawRequest && evictedRead.revision != afterEviction.revision,
    "접수된 옛 원문은 동일 세션 CAS가 전진해도 그대로 조회")
evicted.receiveControl(reply(evictedRead, .unknown, value: afterEviction, accepted: false), from: p, now: 3)
check(evicted.snapshot.operationState == .unknown && evictedJournal.records.count == 1 && evictedJournal.records[0].ledgerAccepted &&
    !evicted.snapshot.canActivate && !evicted.snapshot.canDeactivate, "원장 eviction unknown은 접수 이력을 유지하고 새 효과 명령 0")
check(!evictedJournal.records[0].hasTerminalReceipt, "과거 완료 뒤 현재 unknown이면 다시 보존 대상으로 유지")

for unknown in ["version", "role", "canSet"] {
    var fields = try JSONSerialization.jsonObject(with: Wire.encode(list(state()))) as! [String: Any]
    var sentry = fields["sentry"] as! [String: Any]
    var capability = sentry["control"] as! [String: Any]
    if unknown == "version" { capability["version"] = 3; capability["role"] = ["future": true] }
    else if unknown == "role" { capability["role"] = "future-role" }
    else { capability["canSet"] = false }
    sentry["control"] = capability; fields["sentry"] = sentry
    let decoded = VisionSentryController.decodeCatalog(try JSONSerialization.data(withJSONObject: fields))
    let legacyOnly = model(Journal())
    if let decoded { legacyOnly.observe(decoded, from: p) }
    check(decoded?.sentry?.control == nil && legacyOnly.snapshot.canActivate && !legacyOnly.snapshot.canDeactivate,
        "unknown capability는 정상 trusted v1 on-only 허용 \(unknown)")
    let untrusted = VisionSentryController()
    untrusted.bind(p, trusted: false)
    if let decoded { untrusted.observe(decoded, from: p) }
    check(!untrusted.snapshot.canActivate, "unknown capability도 신뢰 우회 없음 \(unknown)")
}
var malformed = try JSONSerialization.jsonObject(with: Wire.encode(list(state()))) as! [String: Any]
var malformedState = malformed["sentry"] as! [String: Any]
var malformedControl = malformedState["control"] as! [String: Any]
malformedControl["authorizationGeneration"] = "broken"
malformedState["control"] = malformedControl; malformed["sentry"] = malformedState
let malformedDecoded = VisionSentryController.decodeCatalog(try JSONSerialization.data(withJSONObject: malformed))
check(malformedDecoded == nil,
    "알려진 v2 capability의 잘못된 권한 값은 v1으로 하향하지 않음")

func client(_ j: Journal, value: SentryState = state()) -> (StreamClient, NWConnection) {
    let c = StreamClient(store: j.store), peer = NWConnection()
    c.sentryTestIdentity = binding
    c.connection = peer
    c.observeVisionSentry(list(value), from: peer); drain()
    return (c, peer)
}
let transportJournal = Journal(), (c, transportPeer) = client(transportJournal)
c.setVisionSentry(false); c.setVisionSentry(false); c.queue.sync {}; drain()
check(transportPeer.sent.count == 1 && transportJournal.writes == 1, "실제 adapter는 중복 off 한 번만 전송·보존")
let wire = transportPeer.sent[0]
let wireRequest = try SentryControlRequest(rawRequest: Data(wire.dropFirst(StreamMessage.headerLength)))
check(wireRequest.rawRequest == transportJournal.records[0].rawRequest && StreamMessage.parseHeader(wire)?.kind == .activateSentry,
    "실제213 transport는 저장 원문 그대로")
check(!transportJournal.records[0].ledgerAccepted, "실제 SessionLink 송신 완료도 접수 표시 false 유지")
c.receiveVisionSentry(try reply(wireRequest, .pending, value: pendingOff).encodedPayload(), from: transportPeer); drain()
check(c.visionSentrySnapshot.operationState == .pending && c.visionSentrySnapshot.accepted == true, "실제214 adapter pending false")
c.connection = nil; c.queue.sync {}; drain()
check(transportPeer.sent.count == 1, "disconnect는 원격 off 추가 전송 없음")
let (restart, restartPeer) = client(transportJournal, value: state(sessionID: freshSession))
restart.queue.sync {}; drain()
check(restartPeer.sent.isEmpty && restart.visionSentrySnapshot.canReadback, "재실행·연결·catalog는 자동 전송 없음")
restart.readbackVisionSentry(); restart.readbackVisionSentry(); restart.queue.sync {}; drain()
check(restartPeer.sent.count == 1 && Data(restartPeer.sent[0].dropFirst(StreamMessage.headerLength)) == wireRequest.rawRequest,
    "수동 재조회만 원본문 전송·중복 조회 차단")

for change in ["peer", "generation", "boot", "session", "capability", "trust"] {
    let j = Journal(), (held, heldPeer) = client(j)
    _ = held.link.hold(heldPeer)
    held.setVisionSentry(false); held.queue.sync {}
    switch change {
    case "peer": held.connection = NWConnection()
    case "generation": held.observeVisionSentry(list(state(auth: UUID())), from: heldPeer)
    case "boot": held.observeVisionSentry(list(state(bootID: UUID())), from: heldPeer)
    case "session": held.observeVisionSentry(list(state(sessionID: UUID())), from: heldPeer)
    case "capability": held.observeVisionSentry(list(state(capability: false)), from: heldPeer)
    default: held.visionSentryTrusted = false; held.bindVisionSentry(to: heldPeer)
    }
    _ = held.link.unhold(heldPeer); drain()
    check(heldPeer.sent.isEmpty, "보류 전송의 현재 binding 변경 차단 \(change)")
    check(j.records.count == 1, "보류 취소도 원문 보존 \(change)")
}
for change in ["trust", "binding"] {
    let j = Journal(), (held, heldPeer) = client(j)
    _ = held.link.hold(heldPeer)
    held.setVisionSentry(false); held.queue.sync {}
    if change == "trust" { held.visionSentryTrusted = false }
    else { held.sentryTestIdentity = .init(macID: "다른 Mac", hostFingerprint: binding.hostFingerprint, deviceFingerprint: binding.deviceFingerprint) }
    _ = held.link.unhold(heldPeer); drain()
    check(heldPeer.sent.isEmpty && j.records[0].ledgerAccepted == false, "최종 송신 직전 binding 재검증 \(change)")
}
let legacyJournal = Journal(), (oldHost, oldPeer) = client(legacyJournal, value: state(capability: false))
let unavailableJournal = Journal()
unavailableJournal.failLoad = true
let legacyWithoutStore = model(unavailableJournal, state(capability: false))
check(legacyWithoutStore.snapshot.canActivate && legacyWithoutStore.snapshot.problem == nil,
    "v1 on은 새 v2 저장소 장애 때문에 차단하거나 오보하지 않음")
oldHost.setVisionSentry(false); oldHost.queue.sync {}; drain()
check(oldPeer.sent.isEmpty && legacyJournal.writes == 0, "v2 capability 없는 Host에 off 전송 금지")
oldHost.setVisionSentry(true); oldHost.queue.sync {}; drain()
check(oldPeer.sent.count == 1 && Wire.decode(SentryActivation.self, from: Data(oldPeer.sent[0].dropFirst(StreamMessage.headerLength)))?.version == 1,
    "기존 Host에는 v1 on 호환")

let lifecycleJournal = Journal()
var lifecycle = model(lifecycleJournal)
var lifecycleCompleted = 0
for index in 0..<256 {
    guard let request = lifecycle.beginControl(desired: index.isMultiple(of: 2), now: 0, cancel: {}) else { break }
    check(lifecycle.submitControl(request, to: p, now: 0, send: { true }), "반복 명령은 저장 확인 후 전송")
    let completed = state(request.desired ? .userSessionProtected : .inactive,
        requested: request.desired, intent: request.desired ? .on : .off)
    lifecycle.receiveControl(reply(request, value: completed), from: p, now: 1)
    check(lifecycle.snapshot.operationState == .applied, "반복 명령 완료 확인")
    check(lifecycleJournal.records.last?.hasTerminalReceipt == true, "정상 종료 영수증 내구 저장")
    lifecycleCompleted += 1
    lifecycleJournal.records = try JSONDecoder().decode([VisionSentryStoredRequest].self,
        from: JSONEncoder().encode(lifecycleJournal.records))
    if lifecycleCompleted == 128 {
        check(lifecycleJournal.records.count == 64, "128회 완료 후 bounded journal")
        lifecycle = model(lifecycleJournal, completed)
        let restored = begin(lifecycle, desired: nil)
        check(restored.rawRequest == request.rawRequest, "128회 뒤 재시작도 마지막 원문 그대로 수동 조회")
        lifecycle.receiveControl(reply(restored, value: completed), from: p, now: 1)
    }
}
check(lifecycleCompleted == 256 && lifecycleJournal.records.count == 64,
    "256회 정상 on/off와 128회 뒤 재시작에도 새 명령 계속 가능")

let encodedRecord = try JSONEncoder().encode(journal.records[0])
var legacyRecord = try JSONSerialization.jsonObject(with: encodedRecord) as! [String: Any]
legacyRecord.removeValue(forKey: "hasTerminalReceipt")
let legacyAccepted = try JSONDecoder().decode(VisionSentryStoredRequest.self,
    from: JSONSerialization.data(withJSONObject: legacyRecord))
check(legacyAccepted.ledgerAccepted && !legacyAccepted.hasTerminalReceipt, "legacy accepted만으로 종료를 추정하지 않음")
legacyRecord.removeValue(forKey: "ledgerAccepted")
let legacyUnconfirmed = try JSONDecoder().decode(VisionSentryStoredRequest.self,
    from: JSONSerialization.data(withJSONObject: legacyRecord))
check(!legacyUnconfirmed.ledgerAccepted && !legacyUnconfirmed.hasTerminalReceipt, "legacy 필드 누락은 둘 다 false")
for malformed in ["not-bool", 1, ["terminal": true]] as [Any] {
    legacyRecord["hasTerminalReceipt"] = malformed
    let data = try JSONSerialization.data(withJSONObject: legacyRecord)
    check((try? JSONDecoder().decode(VisionSentryStoredRequest.self, from: data)) == nil, "종료 표시는 엄격한 Boolean만 허용")
}
legacyRecord["hasTerminalReceipt"] = true
check((try? JSONDecoder().decode(VisionSentryStoredRequest.self,
    from: JSONSerialization.data(withJSONObject: legacyRecord))) == nil, "원장 접수 없는 종료 표시는 decode 거절")
let invalidTerminal = VisionSentryStoredRequest(binding: binding, rawRequest: request.rawRequest, hasTerminalReceipt: true)
check((try? invalidTerminal.request()) == nil, "생성된 record도 종료이면 원장 접수 필수")
let invalidTerminalJournal = Journal()
invalidTerminalJournal.records = [invalidTerminal]
check(!model(invalidTerminalJournal).snapshot.controlAvailable, "잘못된 저장 종료 표시는 새 전송 차단")

for accepted in [false, true] {
    for status in [SentryControlResponse.OperationState.applied, .rejected, .superseded, .pending, .unknown] {
        let j = Journal(), operation = model(j)
        let r = begin(operation, desired: false)
        operation.receiveControl(reply(r, status, value: state(intent: .off), accepted: accepted), from: p, now: 1)
        let terminal = accepted && [.applied, .rejected, .superseded].contains(status)
        check(j.records[0].hasTerminalReceipt == terminal, "수락·종료 상태 조합만 종료 영수증 \(accepted) \(status)")
        check(j.records[0].ledgerAccepted == accepted && j.records[0].rawRequest == r.rawRequest,
            "결과 조합에도 접수·원문 바이트 보존 \(accepted) \(status)")
        if status == .rejected && accepted {
            check(operation.snapshot.operationState == .rejected && operation.snapshot.message.contains("적용을 거절"),
                "종료된 거절도 적용 성공으로 표시하지 않음")
        }
    }
}

func fullJournal(terminals: Set<Int>) throws -> Journal {
    let j = Journal()
    let oldBoot = UUID()
    for index in 0..<VisionSentryRequestStore.maximumRecords {
        let request = try SentryControlRequest(requestID: UUID(), hostBootID: oldBoot, sessionID: session,
            revision: UUID(), authorizationGeneration: generation, desired: index.isMultiple(of: 2))
        j.records.append(.init(binding: binding, rawRequest: Data(" \n".utf8) + request.rawRequest,
            ledgerAccepted: !index.isMultiple(of: 2), hasTerminalReceipt: terminals.contains(index)))
    }
    return j
}
let mixed = try fullJournal(terminals: [3, 17, 63])
let preserved = mixed.records
let compacting = model(mixed)
let compactedRequest = compacting.beginControl(desired: true, now: 0, cancel: {})!
check(mixed.records == Array(preserved[..<3]) + Array(preserved[4...]) +
    [.init(binding: binding, rawRequest: compactedRequest.rawRequest)],
    "가장 오래된 종료 기록 하나만 제거하고 미해결·다른 종료 원문 순서·바이트 보존")
check(mixed.writes == 1 && mixed.records.count == 64, "교체와 새 명령을 한 번에 저장·readback")
var compactedSends = 0
check(compacting.submitControl(compactedRequest, to: p, now: 0, send: {
    compactedSends += 1
    return mixed.records.last?.rawRequest == compactedRequest.rawRequest
}) && compactedSends == 1, "교체한 원문 확인 뒤에만 새 전송")
let oldRecord = try preserved[3].request()
let beforeLateReply = mixed.records
compacting.receiveControl(reply(oldRecord, value: state(.userSessionProtected, requested: true, intent: .on)), from: p, now: 1)
check(mixed.records == beforeLateReply && compacting.snapshot.pendingID == compactedRequest.requestID,
    "제거된 옛 ID의 지연 응답은 새 record·완료 표시를 변경하지 않음")

for failure in ["save", "readback", "all-unresolved"] {
    let j = try fullJournal(terminals: failure == "all-unresolved" ? [] : [3])
    let original = j.records
    let operation = model(j)
    j.failSave = failure == "save"
    j.corruptReadback = failure == "readback"
    var sends = 0
    if let r = operation.beginControl(desired: true, now: 0, cancel: {}) {
        _ = operation.submitControl(r, to: p, now: 0, send: { sends += 1; return true })
    }
    check(sends == 0 && (failure == "all-unresolved" ? operation.snapshot.problem != .storage : operation.snapshot.problem == .storage),
        "교체 실패와 정상 미해결 한도 거절을 구분하고 전송 0 \(failure)")
    if failure != "readback" { check(j.records == original, "저장 실패·미해결 한도에서 원문 불변 \(failure)") }
    else {
        check(j.records.filter { !$0.hasTerminalReceipt }.prefix(3) == original.prefix(3),
            "저장 후 readback 실패에도 미해결 원문 보존")
    }
}

for failure in ["save", "readback"] {
    let j = Journal(), operation = model(j)
    let r = begin(operation, desired: false)
    j.failSave = failure == "save"
    j.corruptReadback = failure == "readback"
    operation.receiveControl(reply(r, value: state(intent: .off)), from: p, now: 1)
    check(operation.snapshot.problem == .storage && operation.snapshot.operationState != .applied,
        "종료 영수증 저장·readback 실패는 완료로 표시하지 않음 \(failure)")
    check(operation.beginControl(desired: true, now: 2, cancel: {}) == nil, "종료 저장 실패 뒤 새 전송 차단 \(failure)")
}

let unresolvedTransport = try fullJournal(terminals: [])
let (blockedTransport, blockedPeer) = client(unresolvedTransport)
blockedTransport.setVisionSentry(true); blockedTransport.queue.sync {}; drain()
check(blockedPeer.sent.isEmpty && unresolvedTransport.writes == 0, "64건 미해결이면 실제 adapter 전송·저장 0")

do {
    let j = try fullJournal(terminals: [])
    j.records.removeLast()
    let preserved = j.records
    let operation = model(j), r = begin(operation, desired: true)
    let pending = state(.userSessionProtected, requested: true, intent: .on)
    operation.receiveControl(reply(r, .pending, value: pending), from: p, now: 1)
    let beforeRefusal = j.records, writes = j.writes
    check(operation.snapshot.canReadback && operation.snapshot.canDeactivate, "F1 64건 미해결 상태의 기존 pending 조회 가능")
    let refused = operation.beginControl(desired: false, now: 2, cancel: {})
    print("OBSERVATION F1 refused=\(refused == nil) readback=\(operation.snapshot.canReadback) storageFailure=\(operation.snapshot.problem == .storage)")
    check(refused == nil && j.records == beforeRefusal && j.writes == writes, "F1 한도 거절은 미해결 원문·접수·저장을 변경하지 않음")
    check(operation.snapshot.problem != .storage && operation.snapshot.controlAvailable && operation.snapshot.canReadback,
        "F1 정상 한도 거절 뒤 저장소와 기존 원문 조회 유지")
    if let read = operation.beginControl(desired: nil, now: 3, cancel: {}) {
        check(read.rawRequest == r.rawRequest && read.requestID == r.requestID && read.revision == r.revision,
            "F1 거절 뒤 exact raw·ID·옛 CAS로 조회")
        check(operation.submitControl(read, to: p, now: 3, send: { true }), "F1 거절 뒤 기존 조회 전송 허용")
        operation.receiveControl(reply(read, value: pending), from: p, now: 4)
        check(j.records.last?.hasTerminalReceipt == true && Array(j.records.prefix(63)) == preserved,
            "F1 한도에서도 종료 영수증 저장·다른 미해결 기록 보존")
        let off = operation.beginControl(desired: false, now: 5, cancel: {})
        check(off?.desired == false && j.records.count == 64 && Array(j.records.prefix(63)) == preserved,
            "F1 종료 확인 뒤에만 해당 종료 기록 교체 가능")
    } else { check(false, "F1 한도 거절 뒤 수동 조회가 실제 시작됨") }
}

do {
    let j = Journal(), operation = model(j), r = begin(operation, desired: false)
    operation.receiveControl(reply(r, value: state(intent: .off)), from: p, now: 1)
    operation.observe(list(state(.pending, intent: .on)), from: p)
    print("OBSERVATION F2 past-applied message=\(operation.snapshot.message)")
    check(operation.snapshot.message.hasPrefix("Mac이 센츄리 보호 설정을 전환"), "F2 현재 pending false를 과거 applied보다 먼저 표시")
    check(operation.snapshot.operationState == .applied && operation.snapshot.accepted == true &&
        operation.snapshot.message.contains("요청 적용을 확인") && operation.snapshot.canReadback,
        "F2 과거 적용·접수 이력과 원문 조회는 유지")
    let restored = model(j, state(.pending, intent: .on))
    print("OBSERVATION F2 restored message=\(restored.snapshot.message)")
    check(restored.snapshot.message.hasPrefix("Mac이 센츄리 보호 설정을 전환") && restored.snapshot.message.contains("보존된 요청"),
        "F2 복원 원문 안내와 현재 pending false 전환을 함께 표시")
    let unreceived = Journal(), original = model(unreceived), _ = original.beginControl(desired: false, now: 0, cancel: {})
    let restricted = model(unreceived, state(.pending, intent: .on))
    check(restricted.snapshot.message.hasPrefix("Mac이 센츄리 보호 설정을 전환") &&
        restricted.snapshot.message.contains("같은 세션에서는 재전송하지 않습니다") &&
        restricted.snapshot.readbackNeedsNewSession && !restricted.snapshot.canReadback,
        "F2 현재 pending false 표시가 미접수 원문의 같은 세션 조회 제한을 보존")
}

func mutateDurableRaw(_ j: Journal, _ change: String) {
    let old = j.records[0]
    switch change {
    case "missing": j.records = []
    case "raw": j.records[0] = .init(binding: old.binding, rawRequest: Data(" ".utf8) + old.rawRequest)
    case "binding": j.records[0] = .init(binding: .init(macID: "다른 Mac", hostFingerprint: binding.hostFingerprint,
        deviceFingerprint: binding.deviceFingerprint), rawRequest: old.rawRequest)
    case "load-failure": j.failLoad = true
    case "receipt": j.records[0] = .init(binding: old.binding, rawRequest: old.rawRequest, ledgerAccepted: true)
    default: break
    }
}

for change in ["missing", "raw", "binding", "load-failure", "unchanged", "receipt"] {
    let j = Journal(), operation = model(j)
    let r = operation.beginControl(desired: false, now: 0, cancel: {})!
    mutateDurableRaw(j, change)
    let preserved = j.records, writes = j.writes
    var sends = 0
    let submitted = operation.submitControl(r, to: p, now: 1, send: { sends += 1; return true })
    let allowed = change == "unchanged" || change == "receipt"
    print("OBSERVATION durable-first \(change) submitted=\(submitted) sends=\(sends)")
    check(submitted == allowed && sends == (allowed ? 1 : 0), "최초 submit의 durable raw·binding 대조 \(change)")
    check(j.records == preserved && j.writes == writes, "최초 submit은 유실 원문 재작성·새 ID 생성 없음 \(change)")
}

for held in [false, true] {
    for change in ["missing", "raw", "binding", "load-failure", "unchanged", "receipt"] {
        let j = Journal(), (c, peer) = client(j)
        if held { _ = c.link.hold(peer) } else { c.queue.suspend() }
        c.setVisionSentry(false)
        if held { c.queue.sync {} }
        check(peer.sent.isEmpty && j.records.count == 1 && j.writes == 1,
            "실제 adapter는 save·readback 뒤 최종 송신 전 대기 \(held) \(change)")
        let raw = j.records[0].rawRequest
        mutateDurableRaw(j, change)
        let preserved = j.records
        if held { _ = c.link.unhold(peer) } else { c.queue.resume(); c.queue.sync {} }
        drain()
        let allowed = change == "unchanged" || change == "receipt"
        print("OBSERVATION durable-network held=\(held) \(change) sends=\(peer.sent.count)")
        check(peer.sent.count == (allowed ? 1 : 0), "실제 SessionLink·Network 최종 송신의 durable raw 재대조 \(held) \(change)")
        if let sent = peer.sent.first {
            check(Data(sent.dropFirst(StreamMessage.headerLength)) == raw, "최종 송신도 저장한 exact raw 바이트 유지 \(held) \(change)")
        }
        check(j.records == preserved && j.writes == 1, "최종 송신 검사는 원문·접수 이력 재작성 없음 \(held) \(change)")
        c.queue.sync {}; drain()
        check(peer.sent.count == (allowed ? 1 : 0), "취소·무응답 뒤 자동 TLS 재전송 없음 \(held) \(change)")
    }
}

print("RESULT_ASSERTIONS \(assertions)")
exit(failures == 0 ? 0 : 1)
