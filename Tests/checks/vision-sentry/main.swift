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
let a = NWConnection(), b = NWConnection()
let pa = ObjectIdentifier(a), pb = ObjectIdentifier(b)
let boot = UUID(), session = UUID()
func state(_ phase: SentryState.Phase = .inactive, revision: UUID = UUID(),
           host: UUID = boot, sessionID: UUID = session) -> SentryState {
    SentryState(hostBootID: host, sessionID: sessionID, revision: revision,
                requested: phase != .inactive, phase: phase, limitations: ["현재 로그인 세션만 보호"])
}
func list(_ sentry: SentryState?, source: StreamSource = .desktop, generation: String = "g0") -> WindowList {
    WindowList(macName: "테스트 Mac", windows: [], active: source, inputGeneration: generation, sentry: sentry)
}
func model(_ initial: SentryState = state()) -> VisionSentryController {
    let m = VisionSentryController()
    m.bind(pa, trusted: true)
    m.observe(list(initial), from: pa)
    return m
}
func request(_ m: VisionSentryController, now: TimeInterval = 0) -> SentryActivation {
    let r = m.begin(now: now, cancel: {})!
    check(m.submit(r, to: pa, now: now, send: { true }), "request admitted to exact peer")
    return r
}
check(StreamMessageKind.activateSentry.rawValue == 213 && StreamMessageKind.sentryState.rawValue == 214,
      "narrow wire kinds remain 213 and 214")
check(StreamMessage.clientPayloadLimit(for: .activateSentry) == 512 && StreamMessage.hostPayloadLimit(for: .activateSentry) == -1,
      "activation is client only with 512 cap")
check(StreamMessage.hostPayloadLimit(for: .sentryState) == 4096 && StreamMessage.clientPayloadLimit(for: .sentryState) == -1,
      "state is host only with 4096 cap")
let original = state()
check(Wire.decode(SentryState.self, from: Wire.encode(original)) == original, "state round trips candidate schema")
check(Wire.decode(WindowList.self, from: Wire.encode(list(original)))?.sentry == original, "optional catalog state round trips")
check(Wire.decode(WindowList.self, from: Wire.encode(list(nil)))?.sentry == nil, "legacy catalog remains decodable")
let m = model(original), command = request(m)
check(command.version == 1 && command.hostBootID == boot && command.sessionID == session && command.revision == original.revision,
      "activation captures exact current catalog scope")
check(m.begin(now: 1, cancel: {}) == nil, "one pending command only")
var repeats = 0
check(!m.submit(command, to: pa, now: 1, send: { repeats += 1; return true }) && repeats == 0,
      "same activation cannot submit twice")
m.receive(SentryResponse(requestID: command.requestID, accepted: true, state: state(.pending)), from: pa, now: 1)
check(m.snapshot.state?.phase == .pending && !m.snapshot.canActivate, "accepted pending never means protected")
check(!m.snapshot.message.contains("보호 중"), "pending copy does not claim protection")
let encoded = try! JSONSerialization.jsonObject(with: Wire.encode(command)) as! [String: Any]
check(Set(encoded.keys) == Set(["version", "requestID", "hostBootID", "sessionID", "revision"]),
      "activation has no remote off, account or gesture fields")

let fresh = model(), old = request(fresh)
let protected = state(.userSessionProtected)
fresh.observe(list(protected), from: pa)
fresh.receive(SentryResponse(requestID: old.requestID, accepted: true, state: state(.pending)), from: pa, now: 2)
check(fresh.snapshot.state == protected && fresh.snapshot.pendingID == nil, "late ACK never replaces newer catalog")
fresh.observe(list(state(.blocked)), from: pb)
check(fresh.snapshot.state == protected, "old peer catalog cannot replace current state")
fresh.bind(pb, trusted: true)
check(fresh.snapshot.state == nil && !fresh.snapshot.available, "rebind clears known state")
fresh.observe(list(state()), from: pb)
fresh.receive(SentryResponse(requestID: old.requestID, accepted: true, state: protected), from: pa, now: 2)
check(fresh.snapshot.state?.phase == .inactive, "old peer ACK cannot cross rebind")
fresh.bind(nil, trusted: false)
check(fresh.snapshot.state == nil && fresh.snapshot.pendingID == nil, "disconnect clears local status only")

for change in 0..<5 {
    let initial = state()
    let scoped = model(initial), r = request(scoped)
    switch change {
    case 0: scoped.observe(list(state(host: UUID())), from: pa)
    case 1: scoped.observe(list(state(sessionID: UUID())), from: pa)
    case 2: scoped.observe(list(initial, source: .window(42)), from: pa)
    case 3: scoped.observe(list(initial, generation: "g1"), from: pa)
    default: scoped.observe(list(nil), from: pa)
    }
    let current = scoped.snapshot
    scoped.receive(SentryResponse(requestID: r.requestID, accepted: true, state: protected), from: pa, now: 2)
    check(scoped.snapshot == current, "catalog scope change fences old ACK \(change)")
}
let wrong = model(), r = request(wrong)
wrong.receive(SentryResponse(requestID: UUID(), accepted: true, state: protected), from: pa, now: 1)
wrong.receive(SentryResponse(requestID: r.requestID, accepted: true, state: state(.userSessionProtected, host: UUID())), from: pa, now: 1)
wrong.receive(SentryResponse(requestID: r.requestID, accepted: true, state: state(.userSessionProtected, sessionID: UUID())), from: pa, now: 1)
wrong.receive(SentryResponse(requestID: r.requestID, accepted: true,
                             state: state(.userSessionProtected, revision: r.revision)), from: pa, now: 1)
check(wrong.snapshot.pendingID == r.requestID && wrong.snapshot.state?.phase == .inactive,
      "wrong request, boot, session or inconsistent revision never claims protection")
let revisionModel = model(original)
let next = state()
revisionModel.observe(list(next), from: pa)
let revisionRequest = request(revisionModel)
revisionModel.receive(SentryResponse(requestID: revisionRequest.requestID, accepted: true, state: original), from: pa, now: 1)
check(revisionModel.snapshot.state == next && revisionModel.snapshot.pendingID != nil, "retired revision ACK is ignored")
let timed = model(), timedRequest = request(timed)
timed.timeout(timedRequest.requestID, now: 8)
timed.receive(SentryResponse(requestID: timedRequest.requestID, accepted: true, state: protected), from: pa, now: 9)
check(timed.snapshot.state == nil && timed.snapshot.problem == .timedOut && timed.snapshot.pendingID == nil,
      "finite timeout makes state unknown and late ACK stays ignored")
check(timed.begin(now: 9, cancel: {}) == nil, "timeout cannot silently retry without fresh catalog")
timed.observe(list(state(.pending)), from: pa)
check(timed.snapshot.state?.phase == .pending && timed.snapshot.problem == nil, "fresh readback restores actual state")
let expired = model(), expiredRequest = expired.begin(now: 0, cancel: {})!
var sends = 0
check(!expired.submit(expiredRequest, to: pa, now: 8, send: { sends += 1; return true }) && sends == 0,
      "expiry fences final send")
let noSource = model()
noSource.observe(list(state(), source: .none), from: pa)
check(noSource.begin(now: 0, cancel: {}) == nil, "no current Mac pixels cannot activate")
let untrusted = VisionSentryController()
untrusted.bind(pa, trusted: false); untrusted.observe(list(original), from: pa)
check(!untrusted.snapshot.available && untrusted.begin(now: 0, cancel: {}) == nil, "unpaired and plain peers cannot activate")
let unsupported = model(protected)
var futureJSON = try! JSONSerialization.jsonObject(with: Wire.encode(original)) as! [String: Any]
futureJSON["version"] = 2
let future = Wire.decode(SentryState.self, from: try! JSONSerialization.data(withJSONObject: futureJSON))!
unsupported.observe(list(future), from: pa)
check(!unsupported.snapshot.available && unsupported.snapshot.state == nil, "unsupported version clears status and UI capability")
unsupported.observe(list(protected), from: pa); unsupported.invalidateCatalog(from: pa)
check(!unsupported.snapshot.available && unsupported.snapshot.state == nil, "undecodable catalog clears known protection")

for invalidation in ["stale", "missing", "unsupported", "undecodable"] {
    let protectedA = state(.userSessionProtected), blockedB = state(.blocked)
    let replay = model(protectedA)
    replay.observe(list(blockedB), from: pa)
    check(replay.snapshot.state == blockedB, "valid replacement reports blocked \(invalidation)")
    switch invalidation {
    case "stale": replay.observe(list(protectedA), from: pa)
    case "missing": replay.observe(list(nil), from: pa)
    case "unsupported": replay.observe(list(future), from: pa)
    default: replay.invalidateCatalog(from: pa)
    }
    check(replay.snapshot == VisionSentryController.Snapshot(), "catalog invalidation remains unknown \(invalidation)")
    for attempt in 1...2 {
        replay.observe(list(protectedA), from: pa)
        check(replay.snapshot == VisionSentryController.Snapshot(),
              "retired protection stays rejected without a catalog \(invalidation) attempt \(attempt)")
    }
    replay.observe(list(blockedB), from: pa)
    check(replay.snapshot.state == blockedB && replay.snapshot.available && replay.snapshot.canActivate,
          "invalid replacement never retires current blocked revision \(invalidation)")
}
for scope in ["boot", "session"] {
    let protectedA = state(.userSessionProtected), blockedB = state(.blocked)
    let authority = model(protectedA)
    authority.observe(list(blockedB), from: pa)
    let replacement = state(.userSessionProtected, revision: protectedA.revision,
                            host: scope == "boot" ? UUID() : boot,
                            sessionID: scope == "session" ? UUID() : session)
    authority.observe(list(replacement), from: pa)
    check(authority.snapshot.state == replacement && authority.snapshot.available,
          "current peer retains authority to replace \(scope) scope")
}
let inconsistent = model(protected)
inconsistent.observe(list(state(.blocked, revision: protected.revision)), from: pa)
check(inconsistent.snapshot == VisionSentryController.Snapshot(), "inconsistent current revision clears status")
inconsistent.observe(list(protected), from: pa)
check(inconsistent.snapshot.state == protected, "inconsistent replacement does not retire current revision")
let reboundRevision = model(protected)
reboundRevision.observe(list(state(.blocked)), from: pa)
reboundRevision.bind(pb, trusted: true)
reboundRevision.observe(list(protected), from: pb)
check(reboundRevision.snapshot.state == protected, "new peer binding clears retired revisions")

func client() -> (StreamClient, NWConnection) {
    let c = StreamClient(), peer = NWConnection()
    c.connection = peer
    c.observeVisionSentry(list(state()), from: peer)
    drain()
    return (c, peer)
}
let (native, peer) = client()
native.activateVisionSentry(); native.queue.sync {}; drain()
check(peer.sent.count == 1, "actual adapter sends one activation")
let sent = peer.sent.first!
let activation = Wire.decode(SentryActivation.self, from: Data(sent.dropFirst(StreamMessage.headerLength)))!
check(StreamMessage.parseHeader(sent)?.kind == .activateSentry && native.visionSentrySnapshot.pendingID == activation.requestID,
      "actual adapter binds wire request ID")
native.receiveVisionSentry(Wire.encode(SentryResponse(requestID: activation.requestID, accepted: true, state: state(.pending))), from: peer)
drain()
check(native.visionSentrySnapshot.state?.phase == .pending, "actual adapter publishes truthful response")
native.connection = nil; native.queue.sync {}; drain()
check(peer.sent.count == 1 && native.visionSentrySnapshot.state == nil, "disconnect sends no remote disable")

let (held, heldPeer) = client()
check(held.link.hold(heldPeer), "hold established")
held.activateVisionSentry(); held.queue.sync {}
let firstPending = held.visionSentry.snapshot.pendingID!
held.observeVisionSentry(list(state(), generation: "new"), from: heldPeer)
held.activateVisionSentry(); held.queue.sync {}; drain()
check(held.visionSentry.snapshot.pendingID != nil && held.visionSentry.snapshot.pendingID != firstPending,
      "old submission cancellation cannot cancel a fresh request")
_ = held.link.unhold(heldPeer); drain()
check(heldPeer.sent.count == 1, "held stale catalog submission is removed before drain")
held.connection = nil
let (rebound, reboundPeer) = client()
_ = rebound.link.hold(reboundPeer)
rebound.activateVisionSentry(); rebound.queue.sync {}
rebound.connection = NWConnection()
_ = rebound.link.unhold(reboundPeer); drain()
check(reboundPeer.sent.isEmpty && rebound.connection!.sent.isEmpty, "queued activation never follows peer rebind")
let (missing, missingPeer) = client()
_ = missing.link.hold(missingPeer)
missing.activateVisionSentry(); missing.queue.sync {}
missing.observeVisionSentry(list(nil), from: missingPeer)
_ = missing.link.unhold(missingPeer); drain()
check(missingPeer.sent.isEmpty && !missing.visionSentrySnapshot.available, "missing capability cancels held send and hides UI")
missing.activateVisionSentry(); missing.queue.sync {}; drain()
check(missingPeer.sent.isEmpty && missing.visionSentrySnapshot.pendingID == nil,
      "installed host137 without candidate capability cannot receive activation")
let (cancelled, cancelledPeer) = client()
_ = cancelled.link.hold(cancelledPeer)
cancelled.activateVisionSentry(); cancelled.queue.sync {}
let cancelledID = cancelled.visionSentry.snapshot.pendingID!
cancelled.visionSentry.timeout(cancelledID, now: ProcessInfo.processInfo.systemUptime + 9)
_ = cancelled.link.unhold(cancelledPeer); drain()
check(cancelledPeer.sent.isEmpty && cancelled.visionSentrySnapshot.problem == .timedOut,
      "actual held submission cannot send after timeout")
let deadlineLink = SessionLink(), deadlinePeer = NWConnection()
deadlineLink.connection = deadlinePeer
_ = deadlineLink.hold(deadlinePeer)
var deadlineOutcome: SessionLink.Submission.Outcome?
let deadlineSubmission = SessionLink.Submission(deadline: ProcessInfo.processInfo.systemUptime - 1) { deadlineOutcome = $0 }
check(deadlineLink.send(Data([213]), onlyOn: deadlinePeer, submission: deadlineSubmission), "expired submission can wait behind hold")
_ = deadlineLink.unhold(deadlinePeer); drain()
check(deadlinePeer.sent.isEmpty && deadlineOutcome == .cancelled,
      "final Network.send fence rejects expired hold even before main timeout callback")
print("RESULT_ASSERTIONS \(assertions)")
exit(failures == 0 ? 0 : 1)
