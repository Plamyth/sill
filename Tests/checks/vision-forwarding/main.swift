import Foundation
import StreamProtocol

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    assertions += 1
    precondition(condition(), name)
}
let device = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
let other = AudioForwardingDeviceID(hex: String(repeating: "b", count: 64))!
let pairing = UUID()
let configuration = try AudioForwardingConfiguration(controllerBootId: UUID(), privacyGeneration: UUID(),
    registryRevision: .init(1), members: [
        .init(participantId: "native.sill", bootId: UUID()),
        .init(participantId: "s23.audio.relay", bootId: UUID())])
let empty = try AudioForwardingSnapshot(revision: .init(4), intent: nil, binding: nil)
let desired = VisionRemoteAudioIntent.Desire(playback: true, microphone: true)
func catalog(_ snapshot: AudioForwardingSnapshot, device id: AudioForwardingDeviceID = device,
             generation: UUID = pairing, intent: UInt64 = 0, binding: UInt64 = 0) throws -> AudioForwardingCatalog {
    try .init(principal: .init(kind: .cable, id: id, authorizationGeneration: generation), role: .viewer,
        bootstrap: .init(credential: .init(pairedDeviceId: id, pairingGeneration: generation,
            credential: String(repeating: "a", count: 43)),
            ownCursor: .init(intentRevision: .init(intent), bindingRevision: .init(binding)), snapshot: snapshot))
}
func observed(_ model: inout VisionAudioForwarding, _ value: AudioForwardingCatalog) throws {
    let request = model.pending?.control ?? model.observe()!
    let state = try AudioForwardingState(requestID: request.requestID, operation: .observe, catalog: value, result: nil)
    let decoded = try JSONDecoder().decode(AudioForwardingState.self, from: JSONEncoder().encode(state))
    model.receive(decoded, from: model.connection)
}
func snapshot(_ request: AudioForwardingIntentRequest, revision: UInt64,
              phase: AudioForwardingBinding.Phase, generation: UUID = UUID()) throws -> AudioForwardingSnapshot {
    try .init(revision: .init(revision), intent: .init(pairedDeviceId: request.pairedDeviceId,
        intentId: request.intentId, intentRevision: request.intentRevision, intentGeneration: generation,
        inputDesired: request.inputDesired, outputDesired: request.outputDesired),
        binding: .init(pairedDeviceId: request.pairedDeviceId, intentGeneration: generation,
            bindingEpoch: UUID(), transportId: request.transportId, transportKind: .native,
            operationId: UUID(), phase: phase, configuration: configuration))
}
func submitted(_ model: inout VisionAudioForwarding, _ snapshot: AudioForwardingSnapshot) throws {
    let pending = model.pending!.control
    model.receive(try .init(requestID: pending.requestID, operation: .submit, catalog: nil,
        result: .accepted(snapshot)), from: model.connection)
}

var model = VisionAudioForwarding(connection: UUID(), device: device)
model.select(desired)
let observation = model.next(desire: desired)!
check(observation.operation == .observe && !model.permits(.microphone), "observe precedes native media")
try observed(&model, catalog(empty, intent: 8, binding: 11))
let submit = model.next(desire: desired)!
let request = submit.intent!
check(request.action == .request && request.transportKind == .native, "explicit native request")
check(request.intentRevision.value == 9 && request.bindingRevision.value == 12 && request.expectedRevision.value == 4,
      "use catalog ownCursor and snapshot CAS")
check(!model.permits(.playback), "sending a request is not media authorization")
let preparing = try snapshot(request, revision: 5, phase: .quiescing)
try submitted(&model, preparing)
check(!model.permits(.playback), "quiescing never starts media")
let live = try snapshot(request, revision: 6, phase: .active)
try observed(&model, catalog(live, intent: 9, binding: 12))
check(model.permits(.playback) && model.permits(.microphone), "only matching active native binding starts both directions")

var resumed = VisionAudioForwarding(connection: UUID(), device: device)
try observed(&resumed, catalog(live, intent: 9, binding: 12))
check(!resumed.permits(.playback), "catalog alone cannot adopt a previous connection's actual media")
let resume = resumed.next(desire: desired)!.intent!
check(resume.action == .resume && resume.intentId == request.intentId && resume.intentRevision == request.intentRevision,
      "automatic reconnect retains acknowledged intent identity")
check(resume.bindingRevision.value == 13 && resume.transportId != request.transportId,
      "reconnect advances binding cursor on a new native transport")
try submitted(&resumed, snapshot(resume, revision: 7, phase: .active))
check(resumed.permits(.microphone), "acknowledged resume permits native media")
resumed.preparationTimedOut(resume.transportId)
check(resumed.permits(.microphone), "completed preparation is not expired by its old deadline")
resumed.suspend()
check(!resumed.permits(.microphone), "background/offbody closes actual without writing desired")
check(desired.microphone && desired.playback, "lifecycle never changes stored desired")

model.select(.init(playback: true, microphone: false))
check(!model.permits(.playback), "manual update immediately fences old actual")
try observed(&model, catalog(live, intent: 9, binding: 12))
let update = model.next(desire: .init(playback: true, microphone: false))!.intent!
check(update.action == .update && update.intentRevision.value == 10 && update.expectedRevision.value == 6,
      "direction update uses fresh own cursor and CAS")
let outputOnly = try snapshot(update, revision: 8, phase: .active)
try submitted(&model, outputOnly)
check(model.permits(.playback) && !model.permits(.microphone), "output-only binding never grants microphone")
try observed(&model, catalog(outputOnly, intent: 10, binding: 13))
model.select(.init())
try observed(&model, catalog(outputOnly, intent: 10, binding: 13))
let stop = model.next(desire: .init())!.intent!
check(stop.action == .stop && !stop.inputDesired && !stop.outputDesired && stop.intentRevision.value == 11,
      "explicit off uses common stop contract")
try submitted(&model, snapshot(stop, revision: 9, phase: .off))
check(!model.permits(.playback), "stop readback keeps actual off")

let otherRequest = try AudioForwardingIntentRequest(pairedDeviceId: other, intentId: UUID(), intentRevision: .init(3),
    action: .request, inputDesired: true, outputDesired: true, expectedRevision: .init(5),
    transportId: UUID(), transportKind: .native, bindingRevision: .init(2))
let otherLive = try snapshot(otherRequest, revision: 10, phase: .active)
var competitor = VisionAudioForwarding(connection: UUID(), device: device)
try observed(&competitor, catalog(otherLive, intent: 9, binding: 12))
check(competitor.next(desire: desired) == nil && competitor.problem != nil,
      "automatic reconnect cannot replace another device's explicit selection")
check(!competitor.shouldObserve && !competitor.permits(.microphone), "other owner stops automatic observation and actual")
competitor.select(desired)
try observed(&competitor, catalog(otherLive, intent: 9, binding: 12))
check(competitor.next(desire: desired)?.intent?.action == .request, "new explicit selection may request common ownership")

var invalid = VisionAudioForwarding(connection: UUID(), device: device)
try observed(&invalid, catalog(empty, device: other))
check(invalid.problem != nil && !invalid.permits(.playback), "TLS local device fingerprint must match principal")
var rotated = VisionAudioForwarding(connection: UUID(), device: device)
try observed(&rotated, catalog(empty))
try observed(&rotated, catalog(empty, generation: UUID()))
check(rotated.problem != nil, "pairing generation cannot rotate within one peer connection")
var timed = VisionAudioForwarding(connection: UUID(), device: device)
let pending = timed.observe()!
timed.timeout(pending.requestID)
check(timed.problem != nil && !timed.shouldObserve, "timeout is terminal until explicit choice")
var stale = VisionAudioForwarding(connection: UUID(), device: device)
_ = stale.observe()
let unexpected = try AudioForwardingState(requestID: UUID(), operation: .observe, catalog: catalog(empty), result: nil)
stale.receive(unexpected, from: UUID())
check(stale.problem == nil && stale.pending != nil, "replaced peer generation cannot mutate current attempt")
stale.receive(unexpected, from: stale.connection)
check(stale.problem != nil, "stale current-peer response fails closed")
var refused = VisionAudioForwarding(connection: UUID(), device: device)
refused.select(desired)
try observed(&refused, catalog(empty))
let refusal = refused.next(desire: desired)!
refused.receive(try .init(requestID: refusal.requestID, operation: .submit, catalog: nil,
    result: .refused(code: "revision_conflict", snapshot: empty)), from: refused.connection)
check(refused.problem != nil && !refused.shouldObserve, "explicit refusal cannot auto retry with a new effect")
var bounded = VisionAudioForwarding(connection: UUID(), device: device)
bounded.select(desired)
try observed(&bounded, catalog(empty))
let slow = bounded.next(desire: desired)!.intent!
let slowValue = try snapshot(slow, revision: 5, phase: .quiescing)
try submitted(&bounded, slowValue)
for _ in 0..<5 { try observed(&bounded, catalog(slowValue, intent: slow.intentRevision.value, binding: slow.bindingRevision.value)) }
check(bounded.problem != nil && !bounded.shouldObserve, "pending preparation has a bounded read budget")
var regressed = VisionAudioForwarding(connection: UUID(), device: device)
try observed(&regressed, catalog(live, intent: 9, binding: 12))
try observed(&regressed, catalog(empty))
check(regressed.problem != nil, "snapshot revision cannot go backwards")

var displaced = VisionAudioForwarding(connection: UUID(), device: device)
try observed(&displaced, catalog(live, intent: 9, binding: 12))
let displacedRequest = displaced.next(desire: desired)!.intent!
let displacedLive = try snapshot(displacedRequest, revision: 7, phase: .active)
try submitted(&displaced, displacedLive)
check(displaced.permits(.playback), "actual is live before a later ownership change")
try observed(&displaced, catalog(otherLive, intent: 9, binding: 13))
check(displaced.problem != nil && !displaced.permits(.playback) && !displaced.permits(.microphone),
      "ownership change readback closes both previously active media directions")
var inconsistent = VisionAudioForwarding(connection: UUID(), device: device)
try observed(&inconsistent, catalog(live, intent: 9, binding: 12))
let rewritten = try AudioForwardingSnapshot(revision: live.revision, intent: nil, binding: nil)
try observed(&inconsistent, catalog(rewritten))
check(inconsistent.problem != nil, "same revision cannot describe a different ledger")

var restarted = VisionAudioForwarding(connection: UUID(), device: device)
try observed(&restarted, catalog(live, intent: 9, binding: 12))
let beforeRestart = restarted.next(desire: desired)!.intent!
let beforeRestartLive = try snapshot(beforeRestart, revision: live.revision.value, phase: .active,
                                     generation: live.intent!.intentGeneration)
try submitted(&restarted, beforeRestartLive)
check(restarted.permits(.microphone), "same journal intent revision can activate a new binding")
let noBinding = try AudioForwardingSnapshot(revision: beforeRestartLive.revision,
                                            intent: beforeRestartLive.intent, binding: nil)
try observed(&restarted, catalog(noBinding, intent: 9, binding: 13))
check(!restarted.permits(.microphone) && restarted.problem == nil,
      "controller restart fences actual while retaining own remembered intent")
let recovered = restarted.next(desire: desired)!.intent!
check(recovered.action == .resume && recovered.intentId == beforeRestart.intentId &&
      recovered.intentRevision == beforeRestart.intentRevision && recovered.bindingRevision.value == 14,
      "same authenticated TCP rebinds missing binding using resume and current own cursor")
check(recovered.transportId != beforeRestart.transportId && recovered.expectedRevision == live.revision,
      "recovery creates only a new transport while intent CAS revision stays unchanged")
let recoveredLive = try snapshot(recovered, revision: live.revision.value, phase: .active,
                                 generation: live.intent!.intentGeneration)
try submitted(&restarted, recoveredLive)
check(restarted.permits(.microphone), "recovery actual starts only after a new active binding")
try observed(&restarted, catalog(noBinding, intent: 9, binding: 14))
check(restarted.problem != nil && !restarted.shouldObserve,
      "repeated missing binding cannot create an endless resume loop")

var cursorRegression = VisionAudioForwarding(connection: UUID(), device: device)
try observed(&cursorRegression, catalog(empty, intent: 8, binding: 11))
try observed(&cursorRegression, catalog(empty, intent: 8, binding: 10))
check(cursorRegression.problem != nil, "own binding cursor cannot move backwards on the authenticated peer")

var context = VisionRemoteAudioIntent.Context()
context.hostKey = "paired-host"
context.scope = .init(connection: UUID(), window: UUID(), admission: UUID(), video: UUID(), foreground: UUID(), privacy: 1)
context.connected = true; context.authenticated = true; context.foreground = true; context.presented = true
context.inputBlocked = false; context.privacyVersion = 2; context.cleanupReady = true
context.protected = false; context.nativeBindingReady = false
var authority = VisionRemoteAudioAuthority()
let owner = UUID()
authority.update(owner, context: context)
authority.setDesired(true, direction: .microphone, hostKey: "paired-host", preferred: owner)
_ = authority.advance(cleanupReady: true)
check(authority.owner == owner && !authority.permits(owner, direction: .microphone),
      "masked legacy capability can elect request owner without granting actual media")
check(authority.request(owner, direction: .microphone, manual: true) == nil, "raw204 cannot bypass native binding")

let encoded = try JSONEncoder().encode(try catalog(empty))
var malformed = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
malformed["schemaVersion"] = 1
check((try? JSONDecoder().decode(AudioForwardingCatalog.self,
    from: JSONSerialization.data(withJSONObject: malformed))) == nil, "catalog schema1 rejected")
malformed = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
malformed["unexpected"] = true
check((try? JSONDecoder().decode(AudioForwardingCatalog.self,
    from: JSONSerialization.data(withJSONObject: malformed))) == nil, "extra catalog field rejected by exact host DTO")
var interrupted = VisionAudioForwarding(connection: UUID(), device: device)
interrupted.select(desired)
let oldObserve = interrupted.next(desire: desired)!
interrupted.suspend()
check(interrupted.pending == nil && interrupted.submitted == nil,
      "lifecycle interruption cancels the outstanding control and submitted authority")
let freshObserve = interrupted.next(desire: desired)!
check(freshObserve.operation == .observe && freshObserve.requestID != oldObserve.requestID,
      "new lifecycle requires its own fresh observation")
try observed(&interrupted, catalog(otherLive, intent: 9, binding: 12))
check(interrupted.next(desire: desired) == nil && !interrupted.permits(.playback),
      "unsubmitted manual choice cannot steal another device after background and return")
check(desired.playback && desired.microphone, "discarding manual choice preserves saved desired")

var interruptedOwn = VisionAudioForwarding(connection: UUID(), device: device)
interruptedOwn.select(desired)
_ = interruptedOwn.next(desire: desired)
interruptedOwn.suspend()
try observed(&interruptedOwn, catalog(live, intent: 9, binding: 12))
let ownResume = interruptedOwn.next(desire: desired)!.intent!
check(ownResume.action == .resume && ownResume.intentId == request.intentId &&
      ownResume.intentRevision == request.intentRevision,
      "discarded manual choice resumes only the matching own remembered intent")

var interruptedSubmit = VisionAudioForwarding(connection: UUID(), device: device)
interruptedSubmit.select(desired)
try observed(&interruptedSubmit, catalog(empty))
let oldSubmit = interruptedSubmit.next(desire: desired)!
interruptedSubmit.suspend()
interruptedSubmit.receive(try .init(requestID: oldSubmit.requestID, operation: .submit,
    catalog: nil, result: .accepted(snapshot(oldSubmit.intent!, revision: 5, phase: .active))),
    from: interruptedSubmit.connection)
check(!interruptedSubmit.permits(.playback) && interruptedSubmit.submitted == nil,
      "late accepted 218 cannot authorize the new lifecycle")
interruptedSubmit.timeout(oldSubmit.requestID)
check(!interruptedSubmit.permits(.microphone), "old control deadline cannot grant new lifecycle media")

var lateObservation = VisionAudioForwarding(connection: UUID(), device: device)
lateObservation.select(desired)
let retiredObserve = lateObservation.next(desire: desired)!
lateObservation.suspend()
lateObservation.receive(try .init(requestID: retiredObserve.requestID, operation: .observe,
    catalog: catalog(live, intent: 9, binding: 12), result: nil), from: lateObservation.connection)
check(lateObservation.snapshot == nil && lateObservation.submitted == nil && !lateObservation.permits(.playback),
      "late observe 218 is not a fresh lifecycle observation")

print("PASS \(assertions) offline native forwarding contract assertions")
