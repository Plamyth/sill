import Foundation
import StreamProtocol

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    precondition(value(), name)
}
let suite = "VisionCallWindowHandoff." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let store = VisionRemoteAudioStore(defaults: defaults)
let key = String(repeating: "c", count: 64)
let otherKey = String(repeating: "d", count: 64)
let sessionID = "A3C96A77-BF2A-4C10-9937-8096E843643E"
let device = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
var now = ProcessInfo.processInfo.systemUptime

func pump(_ seconds: TimeInterval = 0.03) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func client(_ host: String = key) -> StreamClient {
    let client = StreamClient(host)
    store.register(client)
    return client
}
func take(_ client: StreamClient) {
    _ = store.setDesired(true, client: client, direction: .playback, expectedScope: nil)
    check(store.model.owner == client.visionAudioOwnerID, "only the elected window owns audio")
    var list = client.visionAudioIntentCatalog!
    list.providerCalls = 1
    list.providerCallKinds = [ProviderCallKind.nativeCodex.rawValue, ProviderCallKind.chatgptDots.rawValue]
    client.observeVisionProviderCalls(list, from: client.connection!)
}
func bind(_ client: StreamClient) throws {
    let generation = UUID()
    var model = VisionAudioForwarding(connection: client.visionAudioIntentConnection, device: device, clock: { now })
    model.select(client.visionForwardingDesire)
    let query = model.observe()!
    let empty = try AudioForwardingSnapshot(revision: .init(1), intent: nil, binding: nil)
    let catalog = try AudioForwardingCatalog(principal: .init(kind: .cable, id: device, authorizationGeneration: generation),
        role: .viewer, bootstrap: .init(credential: .init(pairedDeviceId: device, pairingGeneration: generation,
            credential: String(repeating: "a", count: 43)), ownCursor: .init(intentRevision: .init(0), bindingRevision: .init(0)), snapshot: empty))
    model.receive(try .init(requestID: query.requestID, operation: .observe, catalog: catalog, result: nil), from: client.visionAudioIntentConnection)
    let submit = model.next(desire: client.visionForwardingDesire)!
    let request = submit.intent!
    let configuration = try AudioForwardingConfiguration(controllerBootId: UUID(), privacyGeneration: UUID(),
        registryRevision: .init(1), members: [.init(participantId: "native.sill", bootId: UUID()), .init(participantId: "s23.audio.relay", bootId: UUID())])
    let snapshot = try AudioForwardingSnapshot(revision: .init(2), intent: .init(pairedDeviceId: device,
        intentId: request.intentId, intentRevision: request.intentRevision, intentGeneration: generation,
        inputDesired: request.inputDesired, outputDesired: request.outputDesired), binding: .init(pairedDeviceId: device,
            intentGeneration: generation, bindingEpoch: UUID(), transportId: request.transportId, transportKind: .native,
            operationId: UUID(), phase: .active, configuration: configuration))
    model.receive(try .init(requestID: submit.requestID, operation: .submit, catalog: nil, result: .accepted(snapshot)), from: client.visionAudioIntentConnection)
    client.visionForwarding = model
    check(client.visionForwarding?.binding != nil, "fresh current-window audio binding is established")
}
func reply(_ client: StreamClient, request: ProviderCallRequest, status: ProviderCallResult.Status,
           session: String?, kind: ProviderCallKind = .nativeCodex) throws {
    let state = try ProviderCallState(request: request, result: .init(requestId: request.requestId,
        status: status, reason: "fixture_result", callSessionId: session, provider: kind.rawValue))
    let payload = Wire.encode(state)
    let bytes = StreamMessage(kind: .providerCallState, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload).serialized()
    _ = client.receiveVisionProviderCall(StreamMessage.parseHeader(bytes)!, payload, from: client.connection!)
    pump()
}

var a: StreamClient? = client()
let b = client()
take(a!)
try bind(a!)
a!.performVisionProviderCall(.start)
check(a!.sentProvider.count == 1, "A explicitly starts one native call")
let start = a!.sentProvider[0].request
try reply(a!, request: start, status: .started, session: sessionID)
check(a!.visionProviderCall.activeCall?.callSessionId == sessionID, "A saves the confirmed native UUID unchanged")
take(b)
check(b.visionProviderCall.activeCall?.callSessionId == sessionID && b.visionProviderCall.connection == b.visionAudioIntentConnection,
    "B receives identity with its own connection")
check(b.visionForwarding == nil && !b.visionProviderCanStop && !b.visionProviderCanStart,
    "A audio binding is never inherited and duplicate start is blocked")
check(!a!.visionProviderCanStop && !store.saveProviderCall(a!), "A loses write and stop authority after owner movement")
weak var retired = a
store.retire(a!)
a = nil
check(retired == nil && b.visionProviderCall.activeCall?.callSessionId == sessionID, "identity survives original client retirement and deallocation")
pump(0.6)
check(b.sentProvider.isEmpty && b.visionProviderCall.queries == 0, "handoff never retransmits start stop or query")
try bind(b)
b.visionProviderCall.observe(connection: b.visionAudioIntentConnection, capability: 1, hostKey: key,
    providerCallKinds: [ProviderCallKind.chatgptDots.rawValue])
check(!b.visionProviderCanStop && !b.visionProviderCall.selectTarget(.chatgptDots), "Dots capability cannot authorize native identity")
b.performVisionProviderCall(.stop)
check(b.sentProvider.isEmpty, "missing native capability sends no stop")
take(b)
b.authenticationCurrent = false
b.performVisionProviderCall(.stop)
check(b.sentProvider.isEmpty && !b.visionProviderCanStop, "new window must authenticate its own current peer")
b.authenticationCurrent = true
let currentScope = b.context.scope
b.context.scope = .init(connection: b.visionAudioIntentConnection, window: UUID(), admission: UUID(),
    video: UUID(), foreground: UUID(), privacy: 1)
b.performVisionProviderCall(.stop)
check(b.sentProvider.isEmpty, "changed scope cannot reuse the previous owner ticket before admission refresh")
b.context.scope = currentScope
b.context.inputBlocked = true
b.performVisionProviderCall(.stop)
check(b.sentProvider.isEmpty, "blocked scope cannot inherit stop authority")
b.context.inputBlocked = false
now += 4
b.performVisionProviderCall(.stop)
check(b.sentProvider.isEmpty && !b.visionProviderCanStop, "expired current-window snapshot rejects stop")
try bind(b)
check(b.visionProviderCanStop && !b.visionProviderCanStart, "fresh owner can only explicitly stop the active session")
b.performVisionProviderCall(.stop)
let stop = b.sentProvider.last!.request
check(b.sentProvider.count == 1 && stop.callSessionId == sessionID && b.sentProvider[0].providerKind == .nativeCodex,
    "B stops the exact raw UUID with the native selector")
try reply(b, request: stop, status: .stopped, session: sessionID.lowercased())
check(b.visionProviderCall.pending != nil && b.visionProviderCall.activeCall != nil, "UUID case mismatch cannot clear shared ownership")
try reply(b, request: stop, status: .stopped, session: sessionID, kind: .chatgptDots)
check(b.visionProviderCall.pending != nil, "wrong provider cannot clear shared ownership")
try reply(b, request: stop, status: .failed, session: nil)
check(b.visionProviderCanStop && b.visionProviderCall.activeCall?.callSessionId == sessionID, "failed stop retains shared active identity")
let c = client(otherKey)
take(c)
try bind(c)
c.performVisionProviderCall(.stop)
b.performVisionProviderCall(.stop)
check(c.sentProvider.isEmpty && b.sentProvider.count == 1, "other Host and non-owner window cannot stop the retained session")
take(b)
try bind(b)
b.performVisionProviderCall(.stop)
let retry = b.sentProvider.last!.request
try reply(b, request: retry, status: .stopped, session: sessionID)
check(b.visionProviderCall.activeCall == nil && b.visionProviderCall.canChangeTarget, "matching confirmed stop clears shared ownership")

let pendingWindow = client()
take(pendingWindow)
try bind(pendingWindow)
pendingWindow.performVisionProviderCall(.start)
let pendingStart = pendingWindow.sentProvider.last!.request
let originalBudget = pendingWindow.visionProviderCall.firstSentAt
let receivingWindow = client()
take(receivingWindow)
check(receivingWindow.visionProviderCall.request == pendingStart && receivingWindow.visionProviderCall.activeCall == nil &&
    receivingWindow.visionProviderCall.result?.status == .unknown, "pending start without a session stays the original unknown request")
check(receivingWindow.visionProviderCall.firstSentAt == originalBudget && receivingWindow.visionProviderCall.queries == 0,
    "handoff preserves original query identity and budget")
try bind(receivingWindow)
receivingWindow.performVisionProviderCall(.start)
receivingWindow.performVisionProviderCall(.stop)
pump(0.6)
check(receivingWindow.sentProvider.isEmpty && pendingWindow.sentProvider.count == 1 && receivingWindow.visionProviderCall.queries == 0,
    "unknown pending start permits no fake stop duplicate start or automatic query")
try reply(pendingWindow, request: pendingStart, status: .started, session: sessionID)
check(!store.saveProviderCall(pendingWindow), "revoked writer ticket rejects late started publication")
take(pendingWindow)
check(pendingWindow.visionProviderCall.request == pendingStart && pendingWindow.visionProviderCall.activeCall == nil &&
    pendingWindow.visionProviderCall.result?.status == .unknown, "re-elected original window restores current shared state instead of late local success")
store.retire(pendingWindow)
store.retire(receivingWindow)

let dotsHost = String(repeating: "e", count: 64)
let dots = client(dotsHost)
take(dots)
try bind(dots)
check(dots.visionProviderCall.selectTarget(.chatgptDots), "idle provider selection remains explicit")
dots.performVisionProviderCall(.start)
let dotsStart = dots.sentProvider.last!.request
try reply(dots, request: dotsStart, status: .started, session: "dots-session", kind: .chatgptDots)
dots.performVisionProviderCall(.stop)
let oldDotsStop = dots.sentProvider.last!.request
let dotsNext = client(dotsHost)
take(dotsNext)
try bind(dotsNext)
dotsNext.performVisionProviderCall(.stop)
let dotsStop = dotsNext.sentProvider.last!.request
check(dotsStop.callSessionId == "dots-session" && dotsNext.sentProvider.last?.providerKind == .chatgptDots,
    "Dots handoff keeps its own session and selector")
try reply(dotsNext, request: dotsStop, status: .stopped, session: nil, kind: .chatgptDots)
check(dotsNext.visionProviderCall.activeCall == nil, "legacy null stopped clears only the matching requested Dots session")
let stoppedObserver = client(dotsHost)
take(stoppedObserver)
check(stoppedObserver.visionProviderCall.activeCall == nil, "a new owner sees the confirmed shared stop")
take(dotsNext)
try bind(dotsNext)
dotsNext.performVisionProviderCall(.start)
let replacement = dotsNext.sentProvider.last!.request
try reply(dotsNext, request: replacement, status: .started, session: "dots-replacement", kind: .chatgptDots)
try reply(dots, request: oldDotsStop, status: .stopped, session: nil, kind: .chatgptDots)
check(!store.saveProviderCall(dots), "late old stop cannot publish over a replacement call")
take(dots)
check(dots.visionProviderCall.activeCall?.callSessionId == "dots-replacement", "owner CAS preserves the latest shared replacement")
try reply(dots, request: oldDotsStop, status: .stopped, session: nil, kind: .chatgptDots)
check(dots.visionProviderCall.activeCall?.callSessionId == "dots-replacement", "re-elected window rejects its own obsolete response")
print("PASS WINDOW_HANDOFF_CHECKS \(checks); actual Host/device/audio effects 0")
