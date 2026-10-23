import Foundation
import StreamProtocol

var checks = 0
func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { fatalError("FAIL: " + name) }
}
let peer = NSObject(), otherPeer = NSObject()
let device = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
let foreign = AudioForwardingDeviceID(hex: String(repeating: "b", count: 64))!
let mac = IPadDesiredAudio.Identity(macID: "fixture", pin: Data(repeating: 7, count: 32))!
let context = IPadAudioForwarding.Context(peer: ObjectIdentifier(peer), mac: mac, device: device,
    source: .desktop, generation: UUID(), videoEpoch: UUID(), lifecycle: UUID())
let otherContext = IPadAudioForwarding.Context(peer: ObjectIdentifier(otherPeer), mac: mac, device: device,
    source: context.source, generation: context.generation, videoEpoch: context.videoEpoch, lifecycle: UUID())
let configuration = try AudioForwardingConfiguration(controllerBootId: UUID(), privacyGeneration: UUID(), registryRevision: .init(1),
    members: [.init(participantId: "native.sill", bootId: UUID()), .init(participantId: "s23.audio.relay", bootId: UUID())])
let credential = try AudioForwardingCredential(pairedDeviceId: device, pairingGeneration: UUID(), credential: String(repeating: "A", count: 43))
let empty = try AudioForwardingSnapshot(revision: .init(9), intent: nil, binding: nil)
func catalog(_ snapshot: AudioForwardingSnapshot = empty, intent: UInt64 = 0, binding: UInt64 = 0) throws -> AudioForwardingCatalog {
    try .init(principal: .init(kind: .cable, id: device, authorizationGeneration: credential.pairingGeneration), role: .viewer,
              bootstrap: .init(credential: credential, ownCursor: .init(intentRevision: .init(intent), bindingRevision: .init(binding)), snapshot: snapshot))
}
func observed(_ request: AudioForwardingControl, _ value: AudioForwardingCatalog) throws -> AudioForwardingState {
    try .init(requestID: request.requestID, operation: .observe, catalog: value, result: nil)
}
func snapshot(_ request: AudioForwardingControl, phase: AudioForwardingBinding.Phase = .quiescing,
              generation: UUID = UUID(), epoch: UUID = UUID(), config: AudioForwardingConfiguration = configuration) throws -> AudioForwardingSnapshot {
    let r = request.intent!
    return try .init(revision: .init(r.expectedRevision.value + 1),
        intent: .init(pairedDeviceId: r.pairedDeviceId, intentId: r.intentId, intentRevision: r.intentRevision,
                      intentGeneration: generation, inputDesired: r.inputDesired, outputDesired: r.outputDesired),
        binding: .init(pairedDeviceId: r.pairedDeviceId, intentGeneration: generation, bindingEpoch: epoch, transportId: r.transportId,
                       transportKind: .native, operationId: request.requestID, phase: phase, configuration: config))
}
func phase(_ snapshot: AudioForwardingSnapshot, _ phase: AudioForwardingBinding.Phase,
           epoch: UUID? = nil, config: AudioForwardingConfiguration? = nil, transport: UUID? = nil) throws -> AudioForwardingSnapshot {
    let b = snapshot.binding!
    return try .init(revision: .init(snapshot.revision.value + 1), intent: snapshot.intent,
        binding: .init(pairedDeviceId: b.pairedDeviceId, intentGeneration: b.intentGeneration, bindingEpoch: epoch ?? b.bindingEpoch,
                       transportId: transport ?? b.transportId, transportKind: .native, operationId: b.operationId,
                       phase: phase, configuration: config ?? b.configuration))
}
func accepted(_ request: AudioForwardingControl, _ value: AudioForwardingSnapshot) throws -> AudioForwardingState {
    try .init(requestID: request.requestID, operation: .submit, catalog: nil, result: .accepted(value))
}
func ready() throws -> IPadAudioForwarding {
    var state = IPadAudioForwarding()
    let observe = state.connect(context, durable: nil, now: 0)!
    check(observe.operation == .observe && observe.intent == nil, "first command is observe, never request")
    check(state.receive(try observed(observe, catalog()), from: context, now: 0.1) == nil, "bootstrap alone cannot request")
    check(state.supported && state.phase == .ready, "choice support before microphone capability")
    check(!state.permits(.microphone, in: context, now: 0.1), "observed support has media0")
    return state
}
func active() throws -> (IPadAudioForwarding, AudioForwardingSnapshot, AudioForwardingControl) {
    var state = try ready()
    let request = state.select(.init(microphone: true, playback: true), in: context, now: 0.2)!
    check(request.operation == .submit && request.intent?.action == .request, "explicit choice submits request")
    check(request.intent?.expectedRevision.value == 9 && request.intent?.intentRevision.value == 1 && request.intent?.bindingRevision.value == 1, "request CAS from bootstrap cursors")
    let quiet = try snapshot(request)
    _ = state.receive(try accepted(request, quiet), from: context, now: 0.3)
    check(state.phase == .quiescing && !state.permits(.playback, in: context, now: 0.4), "quiescing media0")
    check(state.advance(now: 1.199) == nil, "observe never exceeds 1Hz")
    let poll = state.advance(now: 1.2)!
    let live = try phase(quiet, .active)
    _ = state.receive(try observed(poll, catalog(live, intent: 1, binding: 1)), from: context, now: 1.3)
    check(state.permits(.microphone, in: context, now: 1.3) && state.permits(.playback, in: context, now: 1.3), "matching native active admits both directions")
    check(state.mediaDeadline == 4.2, "TTL starts at request send time")
    return (state, live, request)
}

var unknown = IPadAudioForwarding()
check(!unknown.permits(.microphone, in: context, now: 0), "unknown media0")
var (state, live, firstRequest) = try active()
let refresh = state.advance(now: 2.2)!
check(refresh.operation == .observe && refresh.intent == nil, "active only observes, does not resubmit")
_ = state.receive(try observed(refresh, catalog(live, intent: 1, binding: 1)), from: context, now: 2.9)
check(state.mediaDeadline == 5.2, "delayed response does not gain receive-time TTL")
let lost = state.advance(now: 3.2)!
check(lost.operation == .observe, "one fresh active poll")
check(!state.permits(.playback, in: context, now: 5.2), "render deadline closes even before scheduler runs")
_ = state.advance(now: 5.2)
check(state.phase == .blocked && state.wakeAt == nil && state.durable != nil, "lost reply blocks and stops polling, durable retained")
_ = state.receive(try observed(lost, catalog(live, intent: 1, binding: 1)), from: context, now: 5.3)
check(state.phase == .blocked && !state.permits(.playback, in: context, now: 5.3), "late response cannot resurrect expired evidence")
check(state.advance(now: 50) == nil, "blocked no automatic request retry")
check(state.supported && !state.permits(.playback, in: context, now: 50),
      "known protocol support survives blocked media for explicit recovery")

// Official host fixture: own intent 7/binding 11 -> resume intent 7/binding 12.
let ownIntent = try AudioForwardingSnapshot.Intent(pairedDeviceId: device, intentId: UUID(), intentRevision: .init(7),
    intentGeneration: UUID(), inputDesired: true, outputDesired: true)
let remembered = try AudioForwardingSnapshot(revision: .init(19), intent: ownIntent, binding: nil)
let durable = IPadAudioForwarding.Durable(device: device, intentID: ownIntent.intentId, revision: .init(7),
                                         generation: ownIntent.intentGeneration, selection: .init(microphone: true, playback: true))
var reconnect = IPadAudioForwarding()
let initial = reconnect.connect(otherContext, durable: durable, desired: durable.selection, now: 0)!
let resume = reconnect.receive(try observed(initial, catalog(remembered, intent: 7, binding: 11)), from: otherContext, now: 0.1)!
check(resume.intent?.action == .resume && resume.intent?.intentRevision.value == 7 && resume.intent?.bindingRevision.value == 12,
      "official 7/11 -> 7/12 resume fixture")
check(resume.intent?.intentId == durable.intentID && resume.intent?.expectedRevision.value == 19,
      "resume keeps own intent ID and exact observed CAS")
check(resume.intent?.transportId != firstRequest.intent?.transportId, "reconnect uses new transport")
let resumed = try snapshot(resume, phase: .active, generation: durable.generation)
_ = reconnect.receive(try accepted(resume, resumed), from: otherContext, now: 0.2)
check(reconnect.permits(.playback, in: otherContext, now: 0.2), "same own resume accepted")
let update = reconnect.select(.init(microphone: false, playback: true), in: otherContext, now: 0.3)!
check(update.intent?.action == .update && update.intent?.intentRevision.value == 8 && update.intent?.bindingRevision.value == 13,
      "update increments both own cursors")
let updated = try snapshot(update, phase: .active)
_ = reconnect.receive(try accepted(update, updated), from: otherContext, now: 0.4)
let stop = reconnect.select(.init(), in: otherContext, now: 0.5)!
check(stop.intent?.action == .stop && stop.intent?.intentRevision.value == 9 && stop.intent?.bindingRevision.value == 14,
      "stop increments both own cursors")
check(stop.intent?.inputDesired == false && stop.intent?.outputDesired == false && !reconnect.permits(.playback, in: otherContext, now: 0.5), "stop immediate local mute")
_ = reconnect.receive(try accepted(stop, snapshot(stop, phase: .off)), from: otherContext, now: 0.6)
check(reconnect.phase == .ready && reconnect.wakeAt == nil, "off stops polling")

let foreignIntent = try AudioForwardingSnapshot.Intent(pairedDeviceId: foreign, intentId: UUID(), intentRevision: .init(30),
    intentGeneration: UUID(), inputDesired: true, outputDesired: true)
let foreignSnapshot = try AudioForwardingSnapshot(revision: .init(33), intent: foreignIntent, binding: nil)
var stranger = IPadAudioForwarding()
let foreignObserve = stranger.connect(context, durable: durable, desired: durable.selection, now: 0)!
check(stranger.receive(try observed(foreignObserve, catalog(foreignSnapshot, intent: 7, binding: 11)), from: context, now: 0.1) == nil,
      "foreign intent generates zero automatic resume/request")
check(stranger.phase == .ready && !stranger.permits(.playback, in: context, now: 0.2), "foreign snapshot media0")
let manual = stranger.select(.init(microphone: true), in: context, now: 0.2)!
check(manual.intent?.action == .request && manual.intent?.expectedRevision.value == 33 && manual.intent?.intentRevision.value == 8,
      "only explicit selection can replace foreign owner")

var draft = IPadAudioForwarding()
let draftObserve = draft.connect(context, durable: nil, now: 0)!
check(draft.select(.init(microphone: true), in: context, now: 0.1) == nil, "draft waits for observe")
_ = draft.connect(nil, durable: nil, now: 0.2)
_ = draft.receive(try observed(draftObserve, catalog()), from: context, now: 0.3)
check(draft.context == nil && draft.durable == nil && draft.wakeAt == nil, "background discards unsubmitted draft")
let freshObserve = draft.connect(otherContext, durable: nil, now: 0.4)!
check(draft.receive(try observed(freshObserve, catalog()), from: otherContext, now: 0.5) == nil, "draft cannot cross connection generation")
check(draft.select(.init(playback: true), in: context, now: 0.6) == nil, "old chooser context cannot submit")

var timed = try ready()
let timedRequest = timed.select(.init(playback: true), in: context, now: 0.2)!
_ = timed.advance(now: 10.2)
check(timed.phase == .blocked && timed.wakeAt == nil, "submit timeout blocks, no unsafe retry")
_ = timed.receive(try accepted(timedRequest, snapshot(timedRequest, phase: .active)), from: context, now: 10.3)
check(timed.phase == .blocked && timed.durable == nil, "late218 rejected after timeout")
var lateObserve = IPadAudioForwarding()
let staleRequest = lateObserve.connect(context, durable: nil, now: 0)!
_ = lateObserve.receive(try observed(staleRequest, catalog()), from: context, now: 3)
check(lateObserve.phase == .blocked && lateObserve.catalog == nil, "three-second-old observe cannot renew")

for mutation in 0..<5 {
    var (model, snapshot, _) = try active()
    let poll = model.advance(now: 2.2)!
    switch mutation {
    case 0:
        _ = model.receive(try observed(poll, catalog(try phase(snapshot, .active, epoch: UUID()), intent: 1, binding: 1)), from: context, now: 2.3)
    case 1:
        _ = model.receive(try observed(poll, catalog(try phase(snapshot, .active, transport: UUID()), intent: 1, binding: 1)), from: context, now: 2.3)
    case 2:
        let config = try AudioForwardingConfiguration(controllerBootId: UUID(), privacyGeneration: UUID(), registryRevision: .init(2), members: configuration.members)
        _ = model.receive(try observed(poll, catalog(try phase(snapshot, .active, config: config), intent: 1, binding: 1)), from: context, now: 2.3)
    case 3:
        _ = model.receive(try observed(poll, catalog(snapshot, intent: 1, binding: 2)), from: context, now: 2.3)
    default:
        _ = model.advance(now: 1)
    }
    check(model.phase == .blocked && !model.permits(.playback, in: context, now: 2.4), "binding/configuration/cursor/clock mismatch blocks \(mutation)")
}
var (refused, refusedSnapshot, _) = try active()
let refusedUpdate = refused.select(.init(microphone: false, playback: true), in: context, now: 2)!
_ = refused.receive(try .init(requestID: refusedUpdate.requestID, operation: .submit, catalog: nil,
    result: .refused(code: "stale_revision", snapshot: refusedSnapshot)), from: context, now: 2.1)
check(refused.phase == .blocked && refused.durable != nil && refused.wakeAt == nil, "refusal preserves desired but media0")
var (mismatch, _, _) = try active()
_ = mismatch.receive(try .init(requestID: UUID(), operation: .observe, catalog: catalog(), result: nil), from: context, now: 1.4)
check(mismatch.phase == .blocked, "unsolicited or wrong request ID blocked")
var (replaced, _, _) = try active()
let stalePeer = replaced.connect(otherContext, durable: replaced.durable, desired: replaced.durable!.selection, now: 2)!
_ = replaced.receive(try observed(stalePeer, catalog()), from: context, now: 2.1)
check(!replaced.permits(.playback, in: otherContext, now: 2.1), "other peer cannot renew current evidence")

let changedOwnIntent = try AudioForwardingSnapshot.Intent(pairedDeviceId: device, intentId: durable.intentID,
    intentRevision: durable.revision, intentGeneration: durable.generation, inputDesired: false, outputDesired: true)
var changedOwn = IPadAudioForwarding()
let changedObserve = changedOwn.connect(context, durable: durable, desired: durable.selection, now: 0)!
let changedSnapshot = try AudioForwardingSnapshot(revision: .init(20), intent: changedOwnIntent, binding: nil)
check(changedOwn.receive(try observed(changedObserve, catalog(changedSnapshot, intent: 7, binding: 11)), from: context, now: 0.1) == nil,
      "same ID/revision/generation with different desired cannot auto-resume")
var stoppedBeforeAck = IPadAudioForwarding()
let offObserve = stoppedBeforeAck.connect(otherContext, durable: durable, desired: .init(), now: 0)!
check(stoppedBeforeAck.receive(try observed(offObserve, catalog(remembered, intent: 7, binding: 11)), from: otherContext, now: 0.1) == nil,
      "manual off before ACK survives reconnect without resuming old durable on")
check(stoppedBeforeAck.advance(now: 2) == nil && stoppedBeforeAck.phase == .ready,
      "local/durable mismatch generates zero automatic messages")
let suite = "iPadForwardingOffFixture." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
let store = IPadDesiredAudioStore(defaults: defaults)
var (offBeforeAck, ackedSnapshot, _) = try active()
let ackedDurable = offBeforeAck.durable!
store.save(ackedDurable.selection, for: mac)
store.saveForwarding(ackedDurable, for: mac)
let unackedStop = offBeforeAck.select(.init(), in: context, now: 2)!
check(unackedStop.intent?.action == .stop, "manual off emits stop before ACK")
store.save(.init(), for: mac)
check(store.selection(for: mac) == .init() && store.forwarding(for: mac)?.selection == ackedDurable.selection,
      "store preserves local off independently of last acknowledged durable on")
_ = offBeforeAck.connect(otherContext, durable: store.forwarding(for: mac), desired: store.selection(for: mac), now: 2.1)
let postStopObserve = offBeforeAck.pendingRequestID!
let postStopState = try AudioForwardingState(requestID: postStopObserve, operation: .observe,
    catalog: catalog(ackedSnapshot, intent: ackedDurable.revision.value, binding: 1), result: nil)
check(offBeforeAck.receive(postStopState, from: otherContext, now: 2.2) == nil,
      "disconnect before stop ACK cannot resume stored durable on")
defaults.removePersistentDomain(forName: suite)
var deferred = IPadAudioForwarding()
check(deferred.connect(context, durable: nil, observeImmediately: false, now: 0) == nil,
      "wire drain can defer observation without starting a pending timeout")
let delayed = deferred.begin(now: 2)!
check(deferred.markSent(delayed.requestID, now: 5), "stamp pending at actual send, not queued creation")
_ = deferred.receive(try observed(delayed, catalog()), from: context, now: 7.9)
check(deferred.supported && deferred.phase == .ready, "deferred217 freshness uses actual send time")
let maximum = try JSONDecoder().decode(AudioForwardingRevision.self, from: Data("\"18446744073709551615\"".utf8))
check(maximum.value == UInt64.max, "canonical full UInt64 DTO")
for text in ["\"01\"", "\"-1\"", "7", "\"18446744073709551616\""] {
    check((try? JSONDecoder().decode(AudioForwardingRevision.self, from: Data(text.utf8))) == nil, "reject invalid revision \(text)")
}
check(StreamMessageKind.forwardingControl.rawValue == 217 && StreamMessageKind.forwardingState.rawValue == 218, "official kinds")
check(StreamMessage.clientPayloadLimit(for: .forwardingControl) == 4096 && StreamMessage.hostPayloadLimit(for: .forwardingControl) == -1, "217 direction and cap")
check(StreamMessage.hostPayloadLimit(for: .forwardingState) == 16384 && StreamMessage.clientPayloadLimit(for: .forwardingState) == -1, "218 direction and cap")
for kind in [StreamMessageKind.forwardingUplinkReserved, .forwardingDownlinkReserved] {
    check(StreamMessage.hostPayloadLimit(for: kind) == -1 && StreamMessage.clientPayloadLimit(for: kind) == -1, "reserved media0")
}
print("iPad 공통 음성 상태 전이·가짜 전송/시계 검사 \(checks)개 통과. 기기·오디오·네트워크 실행 없음.")
