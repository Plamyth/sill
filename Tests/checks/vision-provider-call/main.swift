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
var model = VisionProviderCall(connection: first, clock: { now })
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
model = VisionProviderCall(connection: first, clock: { now })
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
model = VisionProviderCall(connection: first, clock: { now })
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
    model = VisionProviderCall(connection: first, clock: { invalid })
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
print("PASS \(checks) native provider client checks; actual provider, device, audio and UI effects 0")

now = 400
model = VisionProviderCall(connection: first, clock: { now })
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
model = VisionProviderCall(connection: first, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
expect(model.receive(try response(.started, session: "old-host-call"), from: first), "first host result fixture")
model.disconnected()
model.observe(connection: second, capability: 1, hostKey: String(repeating: "d", count: 64))
expect(model.request == nil && model.result == nil && model.hostKey != hostKey && model.canPerform, "different trusted Mac never inherits old call session")
model.observe(connection: second, capability: 1, hostKey: nil)
expect(!model.canPerform && model.query() == nil, "unverified Mac identity cannot use provider capability")
print("PASS FINAL \(checks) native provider client checks")
