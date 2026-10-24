import Foundation
import StreamProtocol

var checks = 0
func expect(_ value: Bool, _ name: String) {
    checks += 1
    precondition(value, name)
}
let device = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
let first = UUID(), second = UUID()
let hostKey = String(repeating: "c", count: 64)
let request = try ProviderCallRequest(requestId: UUID(), action: .start, expectedLeaseRevision: .init(7),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: nil)
func response(_ status: ProviderCallResult.Status, request: ProviderCallRequest = request, session: String? = nil) throws -> ProviderCallState {
    try .init(request: request, result: .init(requestId: request.requestId, status: status, reason: "fixture_result", callSessionId: session))
}
var now = 100.0
var model = VisionProviderCall(connection: first, target: .chatgptDots, clock: { now })
expect(model.perform(request) == nil, "capability absent sends no perform")
for capability in [nil, 0, 2] as [Int?] {
    model.observe(connection: first, capability: capability, hostKey: hostKey)
    expect(!model.canPerform, "unsupported capability stays disabled")
}
model.observe(connection: first, capability: 1, hostKey: hostKey)
expect(model.canPerform, "current connection capability admits an explicit request")
expect(model.query() == nil, "query without original perform creates no effect")
expect(model.perform(request)?.operation == .perform, "manual perform is sent once")
let pending = model.pending!
expect(model.perform(request) == nil && model.query() == nil, "one provider wire slot")
expect(!model.receive(try response(.started), from: second), "other connection cannot complete request")
let other = try ProviderCallRequest(requestId: UUID(), action: .start, expectedLeaseRevision: .init(7),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: nil)
expect(!model.receive(try response(.started, request: other), from: first), "other request ID cannot complete request")
let changed = try ProviderCallRequest(requestId: request.requestId, action: .start, expectedLeaseRevision: .init(8),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: nil)
expect(!model.receive(try response(.started, request: changed), from: first), "same ID with different digest cannot complete request")
expect(!model.receive(try response(.stopped), from: first), "start cannot adopt a stop ACK")
expect(model.receive(try response(.pending), from: first), "pending is incomplete")
expect(!model.canPerform, "pending cannot issue another effect")
now += 0.5
expect(model.query()?.request == request, "query preserves original seven fields")
expect(model.pending?.control.operation == .query, "query never becomes perform")
expect(model.receive(try response(.pending), from: first), "query pending does not start a call")
expect(model.query() == nil, "query interval is at least half a second")
for _ in 1..<4 {
    now += 0.5
    expect(model.query() != nil, "bounded query")
    expect(model.receive(try response(.pending), from: first), "bounded pending result")
}
now += 0.5
expect(model.query() == nil && model.queries == 4 && model.result?.status == .unknown, "query count budget ends in unknown")
expect(!model.canPerform, "unknown never creates a new request ID automatically")
model.disconnected()
expect(!model.supported && model.request == request, "disconnect retains original identity and resets capability")
model.observe(connection: second, capability: nil, hostKey: hostKey)
expect(model.query() == nil, "old connection capability cannot authorize a query")
model.observe(connection: second, capability: 1, hostKey: hostKey)
expect(model.query() == nil, "reconnect does not renew count budget")

now = 200
model = VisionProviderCall(connection: first, target: .chatgptDots, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
let timed = model.pending!
now = 209.99
expect(!model.timeout(timed), "timeout cannot retire an unexpired wire request")
now = 210
expect(model.timeout(timed) && !model.supported && model.result?.status == .unknown, "timeout retires exactly its own slot")
expect(!model.timeout(timed), "timeout effect is single-use")
model.observe(connection: second, capability: 1, hostKey: hostKey)
expect(model.query() == nil && model.firstSentAt == 200, "reconnect does not renew original time budget")
expect(!model.receive(try response(.started), from: first), "late ACK on retired connection creates no authority")

now = 300
model = VisionProviderCall(connection: first, target: .chatgptDots, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
model.disconnected()
now += 1
model.observe(connection: second, capability: 1, hostKey: hostKey)
expect(model.query()?.request == request && model.queries == 1, "early reconnect resumes only read-only query")
expect(!model.receive(try response(.started, session: "call-1"), from: first), "old TLS ACK cannot complete new TLS query")
expect(model.receive(try response(.started, session: "call-1"), from: second), "matching query can recover original result")
expect(model.result?.callSessionId == "call-1", "provider session identity is preserved")
expect(model.query() == nil, "confirmed result stops query scheduling")
let stop = try ProviderCallRequest(requestId: UUID(), action: .stop, expectedLeaseRevision: .init(7),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: "call-1")
expect(model.perform(stop)?.request.callSessionId == "call-1", "explicit stop binds the actual provider session")
expect(!model.receive(try response(.started, request: stop), from: second), "stop cannot adopt start ACK")
expect(model.receive(try response(.stopped, request: stop), from: second), "actual stop ACK is separate from media protection")

for invalid in [Double.nan, Double.infinity, -1] {
    model = VisionProviderCall(connection: first, target: .chatgptDots, clock: { invalid })
    model.observe(connection: first, capability: 1, hostKey: hostKey)
    expect(model.perform(request) == nil, "invalid monotonic clock sends no perform")
}
expect(StreamMessage.clientPayloadLimit(for: .providerCallControl) == 4096, "221 bounded before allocation")
expect(StreamMessage.hostPayloadLimit(for: .providerCallState) == 16384, "222 bounded before allocation")
expect(StreamMessage.hostPayloadLimit(for: .providerCallControl) == -1, "221 wrong direction denied")
expect(StreamMessage.clientPayloadLimit(for: .providerCallState) == -1, "222 wrong direction denied")
expect(StreamMessage.clientPayloadLimit(for: .forwardingUplinkReserved) == -1 && StreamMessage.hostPayloadLimit(for: .forwardingDownlinkReserved) == -1, "219/220 stay reserved")
let bytes = try JSONEncoder().encode(ProviderCallControl(operation: .perform, request: request))
let decoded = try JSONDecoder().decode(ProviderCallControl.self, from: bytes)
expect(decoded.request == request, "shared request roundtrip preserves digest")
print("PASS \(checks) Dots provider client checks; actual provider, device, audio and UI effects 0")

now = 400
model = VisionProviderCall(connection: first, target: .chatgptDots, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
now = 408.5
expect(model.receive(try response(.pending), from: first), "late pending stays incomplete")
now = 409
expect(model.query() != nil && model.pending?.expiresAt == 410, "query preserves initial absolute deadline")
let originalDeadlineQuery = model.pending!
now = 411
expect(!model.receive(try response(.started, session: "call-late"), from: first), "query cannot extend total ten-second response budget")
expect(model.timeout(originalDeadlineQuery), "query timeout uses initial deadline")
now = 500
model = VisionProviderCall(connection: first, target: .chatgptDots, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
expect(model.receive(try response(.started, session: "old-host-call"), from: first), "first host result fixture")
model.disconnected()
model.observe(connection: second, capability: 1, hostKey: String(repeating: "d", count: 64))
expect(model.request == nil && model.result == nil && model.hostKey != hostKey && model.canPerform, "different trusted Mac never inherits old call session")
model.observe(connection: second, capability: 1, hostKey: nil)
expect(!model.canPerform && model.query() == nil, "unverified Mac identity cannot use provider capability")
print("PASS FINAL \(checks) Dots provider client checks")

now = 600
model = VisionProviderCall(connection: first, target: .chatgptDots, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
model.disconnected()
now = 601
model.observe(connection: second, capability: 1, hostKey: nil)
expect(!model.supported && model.hostKey == hostKey && model.request == request && model.firstSentAt == 600, "transient missing authentication closes authority while preserving original identity and budget")
expect(model.perform(request) == nil && model.query() == nil, "unverified connection sends no provider operation")
model.observe(connection: second, capability: 1, hostKey: hostKey)
expect(!model.canPerform && model.query()?.request == request, "same verified Mac resumes query rather than creating a new effect")
expect(model.firstSentAt == 600 && model.queries == 1, "authentication recovery never resets total query budget")
print("PASS FINAL \(checks) Dots provider client checks")

now = 700
model = VisionProviderCall(connection: first, target: .chatgptDots, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
let sameWire = model.pending!
model.observe(connection: first, capability: 1, hostKey: nil)
expect(model.pending?.sentAt == sameWire.sentAt && !model.supported, "same TLS authentication loss preserves actual in-flight wire")
model.observe(connection: first, capability: 1, hostKey: hostKey)
expect(model.pending?.sentAt == sameWire.sentAt && model.query() == nil && model.perform(request) == nil, "same TLS reauthentication cannot overlap old perform with query")
model.observe(connection: first, capability: 1, hostKey: String(repeating: "e", count: 64))
expect(!model.supported && model.hostKey == hostKey && model.pending != nil, "same live wire cannot change its trusted Mac binding")
expect(model.drain(try response(.started, session: "not-authority"), from: first), "unverified response can drain only its exact wire slot")
expect(model.pending == nil && model.result?.status == .unknown && !model.canPerform, "draining unverified response never adopts call authority")
model.observe(connection: first, capability: 1, hostKey: hostKey)
expect(model.query()?.request == request, "same original request can query only after wire drain")
print("PASS FINAL \(checks) Dots provider client checks")

let regressionChecks = checks
expect(checks == 68, "all original 68 checks ran with explicit Dots selection")

now = 800
var selection = VisionProviderCall(connection: first, clock: { now })
expect(VisionCallTarget.allCases == [.nativeCodex, .chatgptDots, .grok], "typed control targets are native Codex, Dots and Grok")
expect(selection.target == .nativeCodex && selection.canChangeTarget, "default is native Codex without a call")
selection.observe(connection: first, capability: 1, hostKey: hostKey)
expect(selection.supported && !selection.canPerform, "Dots capability never authorizes default native target")
expect(selection.perform(request) == nil && selection.perform(stop) == nil && selection.query() == nil,
       "native target cannot send Dots start, stop or query")
expect(selection.request == nil && selection.pending == nil && selection.result == nil,
       "selecting native never reports connection or call success")
expect(selection.message == "Mac Codex 음성의 원격 시작·종료는 미확인입니다.", "native adapter stays explicitly unverified")
expect(selection.selectTarget(.grok), "idle target can change to Grok")
expect(selection.perform(request) == nil && selection.perform(stop) == nil && selection.query() == nil,
       "Grok cannot send Dots start, stop or query")
expect(selection.request == nil && selection.result == nil && selection.firstSentAt == nil,
       "target selection never starts a call or query budget")
expect(selection.message == "Grok 통화의 원격 시작·종료는 미확인입니다.", "Grok adapter stays explicitly unverified")
selection.observe(connection: second, capability: 1, hostKey: String(repeating: "d", count: 64))
expect(selection.target == .grok && !selection.canPerform, "trusted host change preserves selected target and cannot enable Grok")
expect(selection.selectTarget(.chatgptDots) && selection.canPerform, "explicit Dots choice can use existing capability")
expect(selection.request == nil && selection.pending == nil, "Dots selection alone creates no operation")
expect(selection.perform(request)?.operation == .perform, "explicit Dots action uses existing perform")
let targetWire = selection.pending!
expect(!selection.canChangeTarget && !selection.selectTarget(.nativeCodex) && !selection.selectTarget(.grok),
       "in-flight Dots wire blocks target transition")
expect(selection.target == .chatgptDots && selection.pending?.control.request == targetWire.control.request &&
       selection.pending?.sentAt == targetWire.sentAt && selection.pending?.expiresAt == targetWire.expiresAt,
       "blocked transition preserves original wire and deadline")
expect(selection.selectTarget(.chatgptDots) && selection.pending != nil, "reselecting Dots cannot replace pending wire")
selection.observe(connection: second, capability: 1, hostKey: nil)
expect(!selection.selectTarget(.nativeCodex) && selection.pending?.sentAt == targetWire.sentAt,
       "same TLS missing pin cannot clear wire through target selection")
selection.observe(connection: second, capability: 1, hostKey: hostKey)
expect(!selection.supported && !selection.selectTarget(.grok) && selection.pending != nil,
       "same TLS changed pin cannot clear wire through target selection")
expect(selection.drain(try response(.started, session: "untrusted-target"), from: second),
       "untrusted Dots response still drains exact wire")
expect(selection.result?.status == .unknown && selection.pending == nil && selection.canChangeTarget,
       "untrusted drain releases selection without adopting call success")
expect(selection.selectTarget(.nativeCodex) && selection.query() == nil && selection.perform(request) == nil,
       "native after drain cannot issue Dots recovery or a new effect")
expect(selection.request == request && selection.firstSentAt == 800 && selection.queries == 0,
       "target change preserves original Dots identity and recovery budget")
expect(selection.message.contains("미확인"), "native never displays prior Dots result as native success")
expect(selection.selectTarget(.chatgptDots), "return to Dots for query-only recovery")
selection.observe(connection: second, capability: 1, hostKey: String(repeating: "d", count: 64))
now += 0.5
expect(!selection.canPerform && selection.query()?.operation == .query, "Dots recovery remains query-only")
expect(selection.firstSentAt == 800 && selection.queries == 1, "target round trip never renews query budget")
expect(!selection.selectTarget(.nativeCodex), "in-flight query blocks target transition")
expect(selection.receive(try response(.pending), from: second), "query pending fixture")
expect(selection.pending == nil && !selection.canChangeTarget && !selection.selectTarget(.grok),
       "pending provider result blocks transition between wire requests")
expect(selection.query() == nil, "target transition attempt cannot bypass half-second query spacing")
now += 0.5
expect(selection.query()?.operation == .query, "blocked target transition preserves scheduled query")
expect(selection.receive(try response(.started, session: "dots-only-session"), from: second), "Dots result resolves pending selection lock")
expect(selection.canChangeTarget && selection.message.contains("Dots"), "completed Dots result releases target selection")
let selectedStop = try ProviderCallRequest(requestId: UUID(), action: .stop, expectedLeaseRevision: .init(7),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: "dots-only-session")
expect(selection.selectTarget(.nativeCodex) && !selection.canPerform && selection.perform(selectedStop) == nil,
       "native cannot stop a retained Dots session")
expect(selection.result?.callSessionId == "dots-only-session" && selection.message.contains("미확인"),
       "retained Dots session never becomes native success")
expect(selection.selectTarget(.grok) && selection.perform(selectedStop) == nil && selection.query() == nil,
       "Grok cannot control retained Dots session")
expect(selection.selectTarget(.chatgptDots) && selection.perform(selectedStop)?.request.callSessionId == "dots-only-session",
       "explicit return to Dots retains existing stop adapter contract")
selection.disconnected()
expect(selection.target == .chatgptDots && selection.pending == nil && selection.canChangeTarget,
       "disconnect retires wire and permits target selection without changing target")
expect(selection.selectTarget(.nativeCodex), "native can be selected after disconnected Dots request")
selection.observe(connection: first, capability: 1, hostKey: String(repeating: "d", count: 64))
expect(selection.query() == nil && selection.perform(request) == nil && selection.result?.status == .unknown,
       "reconnected native target sends no Dots recovery")
expect(selection.selectTarget(.chatgptDots) && selection.query()?.operation == .query,
       "same verified Mac can resume only original Dots query after target round trip")
let targetTimeout = selection.pending!
now = targetTimeout.expiresAt
expect(selection.timeout(targetTimeout) && selection.canChangeTarget && selection.result?.status == .unknown,
       "timeout releases target lock and preserves unknown result")
expect(selection.selectTarget(.nativeCodex) && selection.query() == nil,
       "native after timeout cannot issue Dots query")
selection.observe(connection: second, capability: 1, hostKey: hostKey)
expect(selection.target == .nativeCodex && selection.request == nil && !selection.canPerform,
       "new trusted Mac clears old Dots state and keeps native selection")
print("PASS \(checks) total client checks; original Dots 68, new target checks \(checks - regressionChecks); actual provider, app, device, audio effects 0")
