import Foundation
import StreamProtocol

var checks = 0
func check(_ value: Bool, _ name: String) {
    guard value else { fatalError("FAIL: \(name)") }
    checks += 1
}
let host = String(repeating: "a", count: 64)
let device = String(repeating: "b", count: 64)
let binding = String(repeating: "c", count: 64)
let epoch: Int64 = 1_794_000_000_123
let owner = IPadCraftActionJournal.Owner(macID: "fixture-mac", hostPin: host, deviceID: device)
let deviceID = AudioForwardingDeviceID(hex: device)!
let descriptor = try ConfiguredCraftActionCatalog(expectedProfileId: UUID(), expectedAssignmentSha256: binding)
let inactiveState = SentryState(hostBootID: UUID(), sessionID: UUID(), revision: UUID(),
    requested: false, phase: .inactive, limitations: [])
func state(phase: SentryState.Phase = .userSessionProtected, requested: Bool = true,
           revision: UUID = UUID(), authorization: UUID? = UUID(),
           boot: UUID = inactiveState.hostBootID, session: UUID = inactiveState.sessionID) -> SentryState {
    .init(hostBootID: boot, sessionID: session, revision: revision, requested: requested,
          phase: phase, limitations: [], control: authorization.map { .init(authorizationGeneration: $0, manualIntent: .automatic) })
}
func catalogData(capability: Int?, state: SentryState?, source: Int = 0) throws -> Data {
    let list = WindowList(macName: "fixture", windows: [], active: source == 0 ? .desktop : .window(UInt32(source)), configuredCraftActions: capability)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as! [String: Any]
    object["sentry"] = try state.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
    return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
}
let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
final class Clock { var now: TimeInterval = 100 }
final class Memory {
    var record: IPadCraftActionJournal.Record?
    var failWrite = false
    var failRead = false
    var writes = 0
    var journal: IPadCraftActionJournal {
        .init(read: { [self] in
            if failRead { throw IPadConfiguredCraftAction.Failure.invalidWire }
            return record
        }, write: { [self] value in
            writes += 1
            if failWrite { throw IPadConfiguredCraftAction.Failure.invalidWire }
            record = value
        })
    }
}
final class Fixture {
    let clock = Clock()
    let peer = NSObject()
    let gate = IPadCraftSendGate()
    var published: IPadCraftSendGate.Ticket?
    let memory: Memory
    var context: IPadConfiguredCraftAction.Context
    var session: IPadCraftConnectedControl
    var sent: [ConfiguredCraftActionControl] = []
    init(memory: Memory = Memory(), capability: Int? = 1, journal: IPadCraftActionJournal? = nil) throws {
        self.memory = memory
        context = try .init(connection: UUID(), hostID: host, deviceID: device)
        let clock = self.clock
        session = IPadCraftConnectedControl(journal: journal ?? memory.journal, clock: { clock.now })
        gate.bind(ObjectIdentifier(peer))
        observe(capability: capability)
    }
    func observe(capability: Int?, state: SentryState? = inactiveState, ownerKnown: Bool = false,
                 localReturn: Bool = false, nextOwner: IPadCraftActionJournal.Owner = owner) {
        let origin = ObjectIdentifier(peer)
        published = gate.observe(catalog: try! catalogData(capability: capability, state: state), from: origin)
        let ticket = state.flatMap { gate.ticket(from: origin, published: published, capability: capability, state: $0) }
        let admission = IPadCraftAdmission(capability: capability, state: state, ownerKnown: ownerKnown,
            localReturnPending: localReturn, ticket: ticket)
        session.observe(context: context, owner: nextOwner, capability: capability, admission: admission)
    }
    @discardableResult func catalog() throws -> ConfiguredCraftActionControl? {
        guard let control = session.catalogRequest() else { return nil }
        sent.append(control)
        let state = try ConfiguredCraftActionState(control: control, deviceId: deviceID, catalog: descriptor)
        check(session.receive(try JSONEncoder().encode(state), from: context), "correlated production catalog")
        return control
    }
    func invoke(action: UUID = UUID(), duration: Int = 500, issued: Int64 = epoch,
                input: Bool = true, output: Bool = true, sentry: Bool = true) -> ConfiguredCraftActionControl? {
        let control = session.invoke(userAction: action, heldMilliseconds: duration, issuedAt: issued,
                                     inputReady: input, outputReady: output, sentryAllowed: sentry)
        if let control { sent.append(control) }
        return control
    }
    func result(_ control: ConfiguredCraftActionControl, outcome: ConfiguredCraftActionResult.Outcome,
                hash: String? = binding, invoked: Bool = true) throws -> Data {
        let result = try ConfiguredCraftActionResult(outcome: outcome, operationId: control.targetOperationId!,
            deviceId: deviceID, bindingSha256: hash, invoked: invoked, reason: "fixture_reason")
        return try JSONEncoder().encode(ConfiguredCraftActionState(control: control, deviceId: deviceID, result: result))
    }
    func reconnect(to nextOwner: IPadCraftActionJournal.Owner = owner) throws {
        session.observe(context: nil, owner: nil, capability: nil)
        context = try .init(connection: UUID(), hostID: nextOwner.hostPin, deviceID: nextOwner.deviceID)
        observe(capability: 1, nextOwner: nextOwner)
    }
}

for capability in [nil, 0, 3, -1] as [Int?] {
    let f = try Fixture(capability: capability)
    check(f.session.catalogRequest() == nil && f.invoke() == nil && f.session.query() == nil, "unadvertised route sends zero")
    check(f.memory.writes == 0 && f.sent.isEmpty, "unadvertised route does not journal")
}
let unauthenticated = try Fixture()
unauthenticated.session.observe(context: nil, owner: nil, capability: 1)
check(unauthenticated.session.catalogRequest() == nil, "capability does not authenticate peer")
let beforeCatalog = try Fixture()
check(beforeCatalog.invoke() == nil, "no inferred catalog")
let catalogControl = beforeCatalog.session.catalogRequest()!
let catalogBytes = try JSONEncoder().encode(ConfiguredCraftActionState(control: catalogControl, deviceId: deviceID, catalog: descriptor))
let otherRequest = ConfiguredCraftActionControl(requestId: UUID())
check(!beforeCatalog.session.receive(try JSONEncoder().encode(ConfiguredCraftActionState(control: otherRequest, deviceId: deviceID, catalog: descriptor)), from: beforeCatalog.context), "wrong requestId rejected")
let oldContext = beforeCatalog.context
try beforeCatalog.reconnect()
check(!beforeCatalog.session.receive(catalogBytes, from: oldContext), "old catalog cannot enter replacement connection")
try beforeCatalog.catalog()
check(beforeCatalog.session.canPrepare, "matching fresh catalog admits preparation")

for malformed in [Data("[]".utf8), Data("{}".utf8), Data(repeating: 32, count: 16385),
    Data(String(decoding: catalogBytes, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0").utf8),
    Data(String(decoding: catalogBytes, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1").utf8)] {
    let f = try Fixture()
    _ = f.session.catalogRequest()
    check(!f.session.receive(malformed, from: f.context) && !f.session.canPrepare, "malformed/oversize/duplicate catalog has no admission")
}
for milliseconds in [0, 1, 499] {
    let f = try Fixture(); try f.catalog()
    check(f.invoke(duration: milliseconds) == nil && f.memory.writes == 0, "short tap cannot invoke")
}
for issued in [Int64(0), -1, 9_007_199_254_740_992] {
    let f = try Fixture(); try f.catalog()
    check(f.invoke(issued: issued) == nil && f.memory.writes == 0, "wire bridge requires positive safe integer")
}
for ready in [(false, true, true), (true, false, true), (true, true, false)] {
    let f = try Fixture(); try f.catalog()
    check(f.invoke(input: ready.0, output: ready.1, sentry: ready.2) == nil && f.memory.writes == 0, "not-ready or protected/unknown Sentry does not invoke")
}
let once = try Fixture(); try once.catalog()
let gesture = UUID()
let invoke = once.invoke(action: gesture)!
check(once.memory.record?.request.operationId == invoke.targetOperationId && once.memory.writes == 1, "journal precedes returned production invocation")
check(once.invoke(action: gesture) == nil && once.invoke() == nil, "pending physical repeats never mint another operation")
let external = try JSONEncoder().encode(invoke)
let strict = try ConfiguredCraftActionControl.decode(external)
let raw = String(decoding: external, as: UTF8.self)
check(raw.contains(invoke.targetOperationId!.uuidString.lowercased()), "canonical lower operation UUID")
check(!raw.contains("session") && !raw.contains("keyCode") && strict.client?.issuedAt == epoch, "no session echo or authority and integer issuedAt")
let wrongOperation = ConfiguredCraftActionControl(requestId: invoke.requestId, operationId: invoke.targetOperationId)
let wrongOperationState = try ConfiguredCraftActionState(control: wrongOperation, deviceId: deviceID,
    result: ConfiguredCraftActionResult(outcome: .invoked, operationId: invoke.targetOperationId!, deviceId: deviceID, bindingSha256: binding, invoked: true))
check(!once.session.receive(try JSONEncoder().encode(wrongOperationState), from: once.context), "operation union correlation")
var object = try JSONSerialization.jsonObject(with: once.result(invoke, outcome: .invoked)) as! [String: Any]
var resultObject = object["result"] as! [String: Any]
resultObject["operationId"] = UUID().uuidString.lowercased(); object["result"] = resultObject
check(!once.session.receive(try JSONSerialization.data(withJSONObject: object), from: once.context), "wrong operationId cannot resolve")
check(!once.session.receive(try once.result(invoke, outcome: .invoked, hash: String(repeating: "d", count: 64)), from: once.context), "wrong binding cannot resolve")
let terminal = try once.result(invoke, outcome: .invoked)
check(once.session.receive(terminal, from: once.context), "known terminal accepted")
check(once.memory.record == nil && once.session.unresolved == nil, "known terminal clears original durable uncertainty")
check(!once.session.receive(terminal, from: once.context), "duplicate terminal does nothing")
check(once.invoke(action: gesture) == nil, "same physical gesture remains consumed after terminal")
check(once.invoke() != nil, "separate explicit gesture after terminal can invoke")

let unknown = try Fixture(); try unknown.catalog()
let unresolved = unknown.invoke()!
check(unknown.session.receive(try unknown.result(unresolved, outcome: .unknown, hash: nil, invoked: false), from: unknown.context), "unknown response accepted without claiming effect")
check(unknown.invoke() == nil && unknown.session.unresolved != nil, "unknown retains original operation")
let readOnly = unknown.session.query()!
check(readOnly.operation == .query && readOnly.client == nil && readOnly.operationId == unresolved.targetOperationId, "explicit query only reads original ID")
check(unknown.session.receive(try unknown.result(readOnly, outcome: .unknown, hash: nil, invoked: true), from: unknown.context), "unknown invoked true still unresolved")
check(unknown.invoke() == nil && unknown.memory.writes == 1, "query unknown never journals a new invoke")
let queryTerminal = unknown.session.query()!
check(unknown.session.receive(try unknown.result(queryTerminal, outcome: .rejected, hash: nil, invoked: false), from: unknown.context), "query terminal precisely resolves original")
check(unknown.session.unresolved == nil && unknown.memory.record == nil, "query terminal durable clear")

let timed = try Fixture(); try timed.catalog()
let timedInvoke = timed.invoke()!
let late = try timed.result(timedInvoke, outcome: .invoked)
timed.clock.now += 10
timed.session.timeout(requestID: timedInvoke.requestId)
check(!timed.session.receive(late, from: timed.context) && timed.invoke() == nil, "timeout does not auto retry or accept late response")
check(timed.session.unresolved?.request.operationId == timedInvoke.targetOperationId, "timeout keeps same operation")
let retired = timed.context
try timed.reconnect(); try timed.catalog()
check(!timed.session.receive(late, from: retired) && timed.invoke() == nil, "reconnect does not retry or absorb old result")
let afterReconnect = timed.session.query()!
check(afterReconnect.operationId == timedInvoke.targetOperationId, "same durable identity reconnect queries original")
check(timed.session.receive(try timed.result(afterReconnect, outcome: .invoked), from: timed.context), "current query may resolve old connection's operation")

let failedWrite = try Fixture(); try failedWrite.catalog(); failedWrite.memory.failWrite = true
check(failedWrite.invoke() == nil && failedWrite.session.storageFailed, "durable write failure sends zero")
check(failedWrite.invoke() == nil && failedWrite.session.query() == nil, "write failure cannot bypass using another ID")
let failedReadMemory = Memory(); failedReadMemory.failRead = true
let failedRead = try Fixture(memory: failedReadMemory); try failedRead.catalog()
check(failedRead.invoke() == nil && failedRead.session.storageFailed, "unreadable journal is fail closed")
let failedClear = try Fixture(); try failedClear.catalog()
let pendingClear = failedClear.invoke()!; failedClear.memory.failWrite = true
check(!failedClear.session.receive(try failedClear.result(pendingClear, outcome: .invoked), from: failedClear.context), "clear failure is not resolution")
check(failedClear.session.unresolved != nil && failedClear.invoke() == nil, "clear failure cannot release original uncertainty")

let journalURL = scratch.appendingPathComponent("durable/unresolved.json")
let fileJournal = IPadCraftActionJournal.file(journalURL)
let firstProcess = try Fixture(journal: fileJournal); try firstProcess.catalog()
let persisted = firstProcess.invoke()!
let stored = try Data(contentsOf: journalURL)
let storedText = String(decoding: stored, as: UTF8.self)
check(!storedText.contains("connection") && !storedText.contains("session") && !storedText.contains("credential") && !storedText.contains("privateKey"), "real atomic journal excludes session and credentials")
let secondProcess = try Fixture(journal: fileJournal); try secondProcess.catalog()
check(secondProcess.invoke() == nil && secondProcess.session.unresolved?.request.operationId == persisted.targetOperationId, "app restart restores unresolved without invoke")
let restoredQuery = secondProcess.session.query()!
check(restoredQuery.operationId == persisted.targetOperationId && restoredQuery.operation == .query, "restart explicit query uses original operation")
check(secondProcess.session.receive(try secondProcess.result(restoredQuery, outcome: .invoked), from: secondProcess.context), "restart query terminal resolves production model")
let thirdProcess = try Fixture(journal: fileJournal); try thirdProcess.catalog()
check(thirdProcess.session.unresolved == nil, "terminal durable readback remains resolved on next restart")

let ownerFixture = try Fixture(); try ownerFixture.catalog(); _ = ownerFixture.invoke()
for other in [IPadCraftActionJournal.Owner(macID: "another-mac", hostPin: host, deviceID: device),
              .init(macID: owner.macID, hostPin: String(repeating: "d", count: 64), deviceID: device),
              .init(macID: owner.macID, hostPin: host, deviceID: String(repeating: "e", count: 64))] {
    try ownerFixture.reconnect(to: other)
    check(ownerFixture.session.query() == nil && ownerFixture.invoke() == nil, "different durable owner cannot query or invoke")
}

let selectionGeneration = UUID()
let prepContext = try IPadConfiguredCraftAction.Context(connection: UUID(), hostID: host, deviceID: device)
var preparation = IPadCraftPreparation(context: prepContext, selectionGeneration: selectionGeneration)
check(preparation.permits(context: prepContext, selectionGeneration: selectionGeneration, foreground: false,
    permissionWaiting: true, sentryAllowed: true, now: 1), "permission inactive is not background failure")
check(preparation.permits(context: prepContext, selectionGeneration: selectionGeneration, foreground: false,
    permissionWaiting: true, sentryAllowed: true, now: 100), "permission time excluded from preparation deadline")
check(preparation.permits(context: prepContext, selectionGeneration: selectionGeneration, foreground: true,
    permissionWaiting: false, sentryAllowed: true, now: 100), "preparation deadline starts after permission")
check(!preparation.permits(context: prepContext, selectionGeneration: selectionGeneration, foreground: true,
    permissionWaiting: false, sentryAllowed: true, now: 108), "finite preparation deadline")
for delta in 0..<5 {
    var f = IPadCraftPreparation(context: prepContext, selectionGeneration: selectionGeneration)
    if delta == 0 { f.cancel() }
    check(!f.permits(context: delta == 1 ? nil : prepContext,
        selectionGeneration: delta == 2 ? UUID() : selectionGeneration,
        foreground: delta != 3, permissionWaiting: false, sentryAllowed: delta != 4, now: 100),
        "cancel/context/selection/background/Sentry suppress invocation")
}
var permissionChanged = IPadCraftPreparation(context: prepContext, selectionGeneration: selectionGeneration)
check(!permissionChanged.permits(context: prepContext, selectionGeneration: UUID(), foreground: true,
    permissionWaiting: true, sentryAllowed: true, now: 100), "permission wait cannot adopt another selection generation")
var realBackground = IPadCraftPreparation(context: prepContext, selectionGeneration: selectionGeneration)
check(!realBackground.permits(context: prepContext, selectionGeneration: selectionGeneration, foreground: false,
    permissionWaiting: true, backgrounded: true, sentryAllowed: true, now: 100), "actual background cancels even with permission outstanding")

let legacyConnection = UUID()
let legacyRequest = try ProviderCallRequest(requestId: UUID(), action: .start, expectedLeaseRevision: .init(1),
    pairedDeviceId: deviceID, desiredInput: true, desiredOutput: true, callSessionId: nil)
func legacyReply(_ request: ProviderCallRequest, _ status: ProviderCallResult.Status, session: String? = nil) throws -> ProviderCallState {
    try .init(request: request, result: .init(requestId: request.requestId, status: status,
        reason: "fixture_legacy", callSessionId: session))
}
func legacyModel() -> IPadProviderCall {
    var value = IPadProviderCall(connection: legacyConnection, target: .chatGPTDots, clock: { 100 })
    value.observe(connection: legacyConnection, capability: 1, hostKey: host)
    return value
}
for status in [ProviderCallResult.Status.failed, .unsupported] {
    var legacy = legacyModel()
    _ = legacy.perform(legacyRequest)
    check(!IPadCraftConnectedControl.legacyAllowsNewAction(legacy), "legacy pending blocks new path")
    check(legacy.receive(try legacyReply(legacyRequest, status), from: legacyConnection), "legacy terminal result correlated")
    check(legacy.request != nil && IPadCraftConnectedControl.legacyAllowsNewAction(legacy), "retained known terminal history allows Craft")
}
for status in [ProviderCallResult.Status.pending, .unknown, .started] {
    var legacy = legacyModel()
    _ = legacy.perform(legacyRequest)
    check(legacy.receive(try legacyReply(legacyRequest, status, session: status == .started ? "legacy-session" : nil), from: legacyConnection), "legacy outstanding result correlated")
    check(!IPadCraftConnectedControl.legacyAllowsNewAction(legacy), "legacy pending/unknown/active never overlaps Craft")
}
var stoppedLegacy = legacyModel()
_ = stoppedLegacy.perform(legacyRequest)
_ = stoppedLegacy.receive(try legacyReply(legacyRequest, .started, session: "legacy-session"), from: legacyConnection)
let legacyStop = try ProviderCallRequest(requestId: UUID(), action: .stop, expectedLeaseRevision: .init(1),
    pairedDeviceId: deviceID, desiredInput: true, desiredOutput: true, callSessionId: "legacy-session")
_ = stoppedLegacy.perform(legacyStop)
check(stoppedLegacy.receive(try legacyReply(legacyStop, .stopped, session: "legacy-session"), from: legacyConnection), "legacy direct stopped result")
check(stoppedLegacy.request != nil && IPadCraftConnectedControl.legacyAllowsNewAction(stoppedLegacy), "retained stopped request does not permanently block Craft")

let mediaPeer = NSObject()
let mediaMac = IPadDesiredAudio.Identity(macID: owner.macID, pin: Data(repeating: 4, count: 32))!
let mediaContext = IPadAudioForwarding.Context(peer: ObjectIdentifier(mediaPeer), mac: mediaMac, device: deviceID,
    source: .desktop, generation: UUID(), videoEpoch: UUID(), lifecycle: UUID())
let mediaConfiguration = try AudioForwardingConfiguration(controllerBootId: UUID(), privacyGeneration: UUID(), registryRevision: .init(1),
    members: [.init(participantId: "native.sill", bootId: UUID()), .init(participantId: "s23.audio.relay", bootId: UUID())])
let mediaCredential = try AudioForwardingCredential(pairedDeviceId: deviceID, pairingGeneration: UUID(), credential: String(repeating: "A", count: 43))
let emptyMedia = try AudioForwardingSnapshot(revision: .init(9), intent: nil, binding: nil)
let mediaCatalog = try AudioForwardingCatalog(principal: .init(kind: .cable, id: deviceID, authorizationGeneration: mediaCredential.pairingGeneration),
    role: .viewer, bootstrap: .init(credential: mediaCredential, ownCursor: .init(intentRevision: .init(0), bindingRevision: .init(0)), snapshot: emptyMedia))
func mediaSnapshot(_ control: AudioForwardingControl, phase: AudioForwardingBinding.Phase) throws -> AudioForwardingSnapshot {
    let request = control.intent!, generation = UUID()
    return try .init(revision: .init(request.expectedRevision.value + 1),
        intent: .init(pairedDeviceId: request.pairedDeviceId, intentId: request.intentId, intentRevision: request.intentRevision,
                      intentGeneration: generation, inputDesired: request.inputDesired, outputDesired: request.outputDesired),
        binding: .init(pairedDeviceId: request.pairedDeviceId, intentGeneration: generation, bindingEpoch: UUID(), transportId: request.transportId,
                       transportKind: .native, operationId: control.requestID, phase: phase, configuration: mediaConfiguration))
}
var media = IPadAudioForwarding()
let observeMedia = media.connect(mediaContext, durable: nil, now: 0)!
_ = media.receive(try AudioForwardingState(requestID: observeMedia.requestID, operation: .observe, catalog: mediaCatalog, result: nil), from: mediaContext, now: 0.1)
let turnOn = media.select(.init(microphone: true, playback: true), in: mediaContext, now: 0.2)!
_ = media.receive(try AudioForwardingState(requestID: turnOn.requestID, operation: .submit, catalog: nil,
    result: .accepted(mediaSnapshot(turnOn, phase: .active))), from: mediaContext, now: 0.3)
check(IPadCraftConnectedControl.audioReady(media, context: mediaContext, selection: .init(microphone: true, playback: true),
    faulted: false, inputReady: true, outputReady: true, now: 0.4), "fresh selected ON routes are ready")
check(!IPadCraftConnectedControl.audioReady(media, context: mediaContext, selection: .init(microphone: true, playback: true),
    faulted: false, inputReady: false, outputReady: true, now: 0.4), "selected ON requires actual input readiness")
let turnOff = media.select(.init(), in: mediaContext, now: 0.5)!
check(!IPadCraftConnectedControl.audioReady(media, context: mediaContext, selection: .init(),
    faulted: false, inputReady: false, outputReady: false, now: 0.5), "pending OFF cannot stand in for fresh OFF readback")
_ = media.receive(try AudioForwardingState(requestID: turnOff.requestID, operation: .submit, catalog: nil,
    result: .accepted(mediaSnapshot(turnOff, phase: .off))), from: mediaContext, now: 0.6)
check(IPadCraftConnectedControl.audioReady(media, context: mediaContext, selection: .init(),
    faulted: false, inputReady: false, outputReady: false, now: 0.7), "explicit both OFF with fresh real model readback allows toggle")
check(!IPadCraftConnectedControl.audioReady(media, context: mediaContext, selection: .init(),
    faulted: false, inputReady: false, outputReady: false, now: 3.6), "stale OFF never grants readiness")
check(!IPadCraftConnectedControl.audioReady(media, context: nil, selection: .init(),
    faulted: false, inputReady: false, outputReady: false, now: 0.7), "replacement context cannot reuse old OFF")
check(!IPadCraftConnectedControl.audioReady(media, context: mediaContext, selection: .init(),
    faulted: true, inputReady: false, outputReady: false, now: 0.7), "faulted OFF is not admission")
check(!IPadCraftConnectedControl.audioReady(media, context: mediaContext, selection: .init(microphone: true, playback: false),
    faulted: false, inputReady: true, outputReady: false, now: 0.7), "changed selection never inherits previous OFF readiness")

let suite = "ipad-craft-connected-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let store = IPadDesiredAudioStore(defaults: defaults)
let audioIdentity = IPadDesiredAudio.Identity(macID: owner.macID, pin: Data(repeating: 1, count: 32))!
check(!store.hasConfirmedSelection(for: audioIdentity), "unconfirmed first explicit action may prepare defaults")
let forwarding = IPadAudioForwarding.Durable(device: deviceID, intentID: UUID(), revision: .init(1), generation: UUID(), selection: .init())
store.saveForwarding(forwarding, for: audioIdentity)
check(!store.hasConfirmedSelection(for: audioIdentity), "automatic forwarding save does not confirm selection")
store.save(.init(), for: audioIdentity)
check(store.hasConfirmedSelection(for: audioIdentity) && store.selection(for: audioIdentity) == .init(), "explicit both OFF remains confirmed")
store.saveForwarding(forwarding, for: audioIdentity)
check(store.hasConfirmedSelection(for: audioIdentity), "automatic forwarding preserves explicit OFF marker")
let reopened = IPadDesiredAudioStore(defaults: defaults)
check(reopened.hasConfirmedSelection(for: audioIdentity) && reopened.selection(for: audioIdentity) == .init(), "UI reopen/store reload preserves OFF")
store.save(.init(microphone: false, playback: true), for: audioIdentity)
check(reopened.selection(for: audioIdentity) == .init(microphone: false, playback: true), "selected directions preserved on reopen")
var desired = IPadDesiredAudio()
let peer = NSObject()
desired.bind(ObjectIdentifier(peer))
desired.authenticate(audioIdentity, saved: reopened.selection(for: audioIdentity))
desired.bind(nil); desired.bind(ObjectIdentifier(peer))
desired.authenticate(audioIdentity, saved: reopened.selection(for: audioIdentity))
check(desired.selection == .init(microphone: false, playback: true), "existing desired model reconnect restores exact choice")
let archive = try JSONEncoder().encode(audioIdentity)
let identityObject = try JSONSerialization.jsonObject(with: archive)
defaults.set(try JSONSerialization.data(withJSONObject: ["version": 1, "records": [
    ["identity": identityObject, "selection": ["microphone": false, "playback": false]]]]), forKey: IPadDesiredAudioStore.key)
check(store.hasConfirmedSelection(for: audioIdentity) && store.selection(for: audioIdentity) == .init(), "legacy explicit OFF not overwritten")
// Capability, owner and phase matrix uses the same admission constructor as the app.
for cap in [1, 2] {
    for ownerKnown in [false, true] {
        for protected in [false, true] {
            let f = try Fixture(capability: cap)
            f.observe(capability: cap, state: protected ? state() : inactiveState, ownerKnown: ownerKnown)
            try f.catalog()
            let allowed = !protected || (cap == 2 && ownerKnown)
            check((f.invoke() != nil) == allowed, "capability/owner/phase admission matrix")
        }
    }
    for denied in [nil, state(phase: .pending), state(phase: .blocked),
                   state(phase: .inactive, requested: true), state(phase: .userSessionProtected, requested: false),
                   state(authorization: nil)] as [SentryState?] {
        let f = try Fixture(capability: cap)
        f.observe(capability: cap, state: denied, ownerKnown: true)
        try f.catalog()
        check(f.invoke() == nil && f.memory.writes == 0, "unknown/inconsistent/non-owner state denies invocation")
    }
    let localReturn = try Fixture(capability: cap)
    localReturn.observe(capability: cap, ownerKnown: true, localReturn: true)
    try localReturn.catalog()
    check(localReturn.invoke() == nil, "local return authentication blocks both capabilities")
}
for (initialCap, nextCap) in [(1, 2), (2, 1)] {
    let f = try Fixture(capability: initialCap)
    try f.catalog()
    let sent = f.invoke()!
    f.observe(capability: nextCap)
    check(f.session.exchange == nil && f.session.model.resolution?.outcome == .unknown, "cap transition closes pending as unknown")
    check(!f.session.receive(try f.result(sent, outcome: .invoked), from: f.context), "old cap response cannot clear journal")
    check(f.session.query()?.targetOperationId == sent.targetOperationId && f.invoke() == nil, "cap transition preserves query-only original ID")
}
let protectedState = state()
let changedStates = [state(revision: UUID(), authorization: protectedState.control!.authorizationGeneration),
    state(revision: protectedState.revision), state(boot: UUID()), state(session: UUID()),
    state(phase: .pending), state(phase: .blocked), inactiveState]
for changed in changedStates {
    let f = try Fixture(capability: 2)
    f.observe(capability: 2, state: protectedState, ownerKnown: true)
    try f.catalog()
    let invoke = f.invoke()!
    let admission = f.session.exchange!.admission!
    // Only the network observer advances. Main still holds the old, apparently admitted state.
    f.gate.observe(catalog: try catalogData(capability: 2, state: changed), from: ObjectIdentifier(f.peer))
    var calls = 0
    check(!f.gate.submit(admission.ticket) { calls += 1 } && calls == 0, "network revision revokes before main publication and final send")
    check(f.gate.ticket(from: ObjectIdentifier(f.peer), published: f.published, capability: 2, state: changed) == nil,
          "unpublished catalog cannot grant a replacement ticket")
    f.session.sendUnconfirmed(requestID: invoke.requestId)
    check(f.session.exchange == nil && f.session.model.resolution?.outcome == .unknown, "rejected final send retires pending exchange")
    check(f.session.query()?.targetOperationId == invoke.targetOperationId && f.memory.record != nil,
          "uncertain final send preserves durable query identity")
}
for cap in [nil, 0, 1, 3] as [Int?] {
    let f = try Fixture(capability: 2)
    f.observe(capability: 2, state: protectedState, ownerKnown: true)
    try f.catalog()
    _ = f.invoke()!
    let admission = f.session.exchange!.admission!
    f.gate.observe(catalog: try catalogData(capability: cap, state: protectedState), from: ObjectIdentifier(f.peer))
    check(!f.gate.submit(admission.ticket) { fatalError("stale capability submitted") }, "network capability revokes queued preparation")
}
for source in [1, 2] {
    let f = try Fixture()
    try f.catalog(); _ = f.invoke()!
    let ticket = f.session.exchange!.admission!.ticket
    f.gate.observe(catalog: try catalogData(capability: 1, state: inactiveState, source: source), from: ObjectIdentifier(f.peer))
    check(!f.gate.submit(ticket) { fatalError("stale source submitted") }, "source change revokes final send")
}
let unchanged = try Fixture(capability: 2)
unchanged.observe(capability: 2, state: protectedState, ownerKnown: true)
try unchanged.catalog(); _ = unchanged.invoke()!
let unchangedTicket = unchanged.session.exchange!.admission!.ticket
unchanged.gate.observe(catalog: try catalogData(capability: 2, state: protectedState), from: ObjectIdentifier(unchanged.peer))
var sends = 0
check(unchanged.gate.submit(unchangedTicket) { sends += 1 } && sends == 1, "identical catalog preserves final send authority")
unchanged.gate.invalidate(from: ObjectIdentifier(unchanged.peer))
check(!unchanged.gate.submit(unchangedTicket) { sends += 1 } && sends == 1, "Sentry reply invalidates before deferred main handling")
let outsider = NSObject()
unchanged.gate.bind(ObjectIdentifier(outsider))
check(!unchanged.gate.submit(unchangedTicket) { sends += 1 }, "replacement peer cannot consume old ticket")

let handoverState = state()
let handoverCatalog = try catalogData(capability: 2, state: handoverState)
let newPublished = unchanged.gate.observe(catalog: handoverCatalog, from: ObjectIdentifier(outsider))
let newTicket = unchanged.gate.ticket(from: ObjectIdentifier(outsider), published: newPublished, capability: 2, state: handoverState)
check(newTicket != nil && unchanged.gate.submit(newTicket!) { sends += 1 }, "handover peer recovers only after its fresh published catalog")
check(!unchanged.gate.submit(unchangedTicket) { fatalError("old peer revived") }, "fresh handover does not revive old ticket")

// Owner gate uses the real Sentry controller, not just phase/requested from a UI report.
var storedSentry: Data?
var ownerControl = IPadSentryControl(store: .init(load: { storedSentry }, save: { storedSentry = $0 }))
let sentryPeer = NSObject()
let sentryOrigin = ObjectIdentifier(sentryPeer)
let sentryBinding = IPadSentryControl.Binding(macID: "fixture", hostPin: Data(repeating: 1, count: 32), deviceFingerprint: Data(repeating: 2, count: 32))
var observedSentry = IPadSentryObservation()
ownerControl.bind(sentryOrigin); observedSentry.bind(sentryOrigin)
func observeOwner(_ value: SentryState) throws {
    let data = try catalogData(capability: 2, state: value)
    observedSentry.observe(catalog: data, from: sentryOrigin)
    ownerControl.observe(catalog: data, observation: observedSentry, binding: sentryBinding, from: sentryOrigin)
}
try observeOwner(protectedState)
check(ownerControl.admitsConfiguredCraft(state: protectedState, binding: sentryBinding, from: sentryOrigin), "validated current owner admits protected action")
check(!ownerControl.admitsConfiguredCraft(state: protectedState, binding: nil, from: sentryOrigin), "missing binding does not grant owner")
check(!ownerControl.admitsConfiguredCraft(state: protectedState, binding: sentryBinding, from: ObjectIdentifier(outsider)), "wrong peer does not grant owner")
let rotatedOwner = state(revision: protectedState.revision)
try observeOwner(rotatedOwner)
try observeOwner(protectedState)
check(!ownerControl.admitsConfiguredCraft(state: protectedState, binding: sentryBinding, from: sentryOrigin), "retired authorization cannot regain owner admission")
try observeOwner(rotatedOwner)
let pendingSentry = ownerControl.perform(desired: false, binding: sentryBinding, from: sentryOrigin, now: 100)
check(pendingSentry != nil && !ownerControl.admitsConfiguredCraft(state: rotatedOwner, binding: sentryBinding, from: sentryOrigin), "pending Sentry transition denies owner action")
ownerControl.unconfirmed()
check(!ownerControl.admitsConfiguredCraft(state: rotatedOwner, binding: sentryBinding, from: sentryOrigin), "unknown Sentry result denies owner action")

print("PASS \(checks) production connected-control assertions; network/device/key/audio effects=0")
