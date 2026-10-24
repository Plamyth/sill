import Foundation
import StreamProtocol

var checks = 0
func expect(_ value: Bool, _ name: String) { checks += 1; precondition(value, name) }
let device = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
let first = UUID(), second = UUID(), hostKey = String(repeating: "c", count: 64)
let request = try ProviderCallRequest(requestId: UUID(), action: .start, expectedLeaseRevision: .init(7),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: nil)
func response(_ status: ProviderCallResult.Status, request: ProviderCallRequest = request, session: String? = nil) throws -> ProviderCallState {
    try .init(request: request, result: .init(requestId: request.requestId, status: status, reason: "fixture_result", callSessionId: session))
}
var now = 100.0
var model = IPadProviderCall(connection: first, clock: { now })
expect(IPadCallTarget.defaultTarget == .nativeCodex, "default target is native Codex")
expect(!IPadCallTarget.nativeCodex.supportsProviderCall && !IPadCallTarget.grokBot.supportsProviderCall && IPadCallTarget.chatGPTDots.supportsProviderCall, "221 only represents Dots")
expect(model.perform(request) == nil && model.manualQuery() == nil, "unadvertised contract sends nothing")
for cap in [nil, 0, 2] as [Int?] {
    model.observe(connection: first, capability: cap, hostKey: hostKey)
    expect(!model.canPerform, "only capability1 authorizes221")
}
model.observe(connection: first, capability: 1, hostKey: hostKey)
expect(model.query() == nil && model.manualQuery() == nil, "query requires original request")
expect(model.perform(request)?.operation == .perform, "explicit perform")
let original = model.pending!
expect(model.perform(request) == nil && model.query() == nil, "single physical slot")
expect(!model.receive(try response(.started), from: second), "old TLS cannot drain")
let other = try ProviderCallRequest(requestId: UUID(), action: .start, expectedLeaseRevision: .init(7),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: nil)
let changed = try ProviderCallRequest(requestId: request.requestId, action: .start, expectedLeaseRevision: .init(8),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: nil)
expect(!model.receive(try response(.started, request: other), from: first), "wrong ID cannot drain")
expect(!model.receive(try response(.started, request: changed), from: first), "wrong digest cannot drain")
expect(!model.receive(try response(.stopped), from: first), "wrong action cannot drain")
expect(model.pending?.id == original.id, "invalid replies retain physical slot")
expect(model.receive(try response(.pending), from: first), "pending drains its exact response")
expect(model.query() == nil && !model.canManuallyQuery, "first query waits500ms and manual waits budget")
for index in 1...4 {
    now = 100 + Double(index) * 0.5
    expect(model.query()?.request == request, "query retains original seven fields")
    expect(model.pending?.expiresAt == 110, "every automatic query keeps original absolute deadline")
    expect(model.receive(try response(.pending), from: first), "query pending result")
    expect(model.query() == nil, "query spacing enforced")
}
now = 102.5
expect(model.query() == nil && model.queries == 4 && model.result?.status == .unknown, "automatic budget exhausted")
expect(!model.needsAutomaticQuery && !model.canPerform && model.canManuallyQuery, "uncertainty only allows explicit history lookup")
let oldFirst = model.firstSentAt
expect(model.manualQuery()?.request == request && model.pending?.manual == true, "manual query retains exact request")
expect(model.pending?.expiresAt == 112.5 && model.firstSentAt == oldFirst && model.queries == 4, "manual transport10s never renews original budget")
expect(model.manualQuery() == nil && model.query() == nil, "manual lookup single inflight")
expect(model.receive(try response(.started, session: "historical-session"), from: first), "manual cache read")
expect(model.historicalResult?.status == .started && model.result?.status == .unknown, "cache separated from current call")
expect(!model.canPerform && !model.needsAutomaticQuery && model.query() == nil, "cache never rearms perform or automatic loop")
expect(model.historicalMessage?.contains("현재 통화나 미디어 사용 권한") == true, "history UI explains evidence boundary")
model.observe(connection: first, capability: 1, hostKey: nil)
expect(model.manualQuery() == nil, "unverified authentication cannot query")
model.observe(connection: first, capability: 1, hostKey: hostKey)
expect(model.manualQuery()?.request == request, "explicit auth recovery keeps request")
let manual = model.pending!
now = 112.5
expect(!model.receive(try response(.started), from: first), "late manual ACK cannot become authority")
expect(model.timeout(manual), "manual transport timeout")
expect(model.pending?.id == manual.id && !model.canPerform, "timeout retains physical slot until actual TLS replacement")
model.observe(connection: first, capability: 1, hostKey: hostKey)
expect(!model.supported && model.manualQuery() == nil && !model.timeout(manual), "same TLS cannot reopen timed out slot")
model.observe(connection: second, capability: 1, hostKey: hostKey)
expect(model.pending == nil && model.firstSentAt == oldFirst && model.query() == nil, "actual TLS replacement clears wire only, original budget unchanged")
expect(model.manualQuery()?.request == request, "user may query history once after reconnection")
expect(!model.receive(try response(.started), from: first), "old TLS cannot drain new query")
expect(model.receive(try response(.pending), from: second), "manual pending returned once")
expect(!model.needsAutomaticQuery, "manual pending creates no loop")

now = 200
model = IPadProviderCall(connection: first, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
let wire = model.pending!
model.observe(connection: first, capability: 1, hostKey: nil)
expect(model.pending?.id == wire.id && !model.supported, "nil authentication keeps physical slot")
model.observe(connection: first, capability: 1, hostKey: hostKey)
expect(model.query() == nil && model.perform(request) == nil, "auth recovery cannot overlap wire")
model.observe(connection: first, capability: 1, hostKey: String(repeating: "d", count: 64))
expect(model.hostKey == hostKey && !model.supported && model.pending != nil, "same TLS cannot switch trusted host with outstanding221")
expect(model.drain(try response(.started), from: first), "unverifiable exact reply drains only")
expect(model.result?.status == .unknown && model.historicalResult == nil, "unverified result not authority")
now = 200.5
model.observe(connection: first, capability: 1, hostKey: hostKey)
expect(model.query()?.request == request, "auth recovery queries originalID")
expect(model.receive(try response(.started, session: "old"), from: first), "automatic query cache result")
expect(model.result?.status == .unknown && model.historicalResult?.callSessionId == "old" && !model.canPerform, "automatic cache also cannot establish current ownership")
model.observe(connection: second, capability: 1, hostKey: String(repeating: "d", count: 64))
expect(model.request == nil && model.result == nil && model.historicalResult == nil, "other Mac inherits no old session")

now = 300
model = IPadProviderCall(connection: first, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
now = 308.5
expect(model.receive(try response(.pending), from: first), "late pending")
now = 309
expect(model.query()?.request == request && model.pending?.expiresAt == 310, "query cannot extend original deadline")
now = 310
expect(!model.receive(try response(.started), from: first), "lateACK unknown")
expect(model.timeout(model.pending!), "late automatic query disposes TLS")
now = 400
model = IPadProviderCall(connection: first, clock: { now })
model.observe(connection: first, capability: 1, hostKey: hostKey)
_ = model.perform(request)
expect(model.receive(try response(.started, session: "live"), from: first), "direct performACK")
let stop = try ProviderCallRequest(requestId: UUID(), action: .stop, expectedLeaseRevision: .init(7),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: "live")
expect(model.perform(stop)?.request.callSessionId == "live", "explicit stop uses direct acknowledged session")
expect(model.receive(try response(.stopped, request: stop), from: first), "direct stopACK")
model.observe(connection: second, capability: 1, hostKey: hostKey)
expect(model.result?.status == .unknown && !model.canPerform, "reconnect never inherits live ownership")
for invalid in [Double.nan, Double.infinity, -1] {
    model = IPadProviderCall(connection: first, clock: { invalid })
    model.observe(connection: first, capability: 1, hostKey: hostKey)
    expect(model.perform(request) == nil, "invalid monotonic clock")
}
expect(StreamMessage.clientPayloadLimit(for: .providerCallControl) == 4096, "221cap4096")
expect(StreamMessage.hostPayloadLimit(for: .providerCallState) == 16384, "222cap16384")
expect(StreamMessage.hostPayloadLimit(for: .providerCallControl) == -1 && StreamMessage.clientPayloadLimit(for: .providerCallState) == -1, "wrong direction denied")
expect(StreamMessage.clientPayloadLimit(for: .forwardingUplinkReserved) == -1 && StreamMessage.hostPayloadLimit(for: .forwardingDownlinkReserved) == -1, "219220reserved")
struct Vector: Decodable { let request: ProviderCallRequest; let requestDigest: String }
for vector in try JSONDecoder().decode([Vector].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) {
    expect(vector.request.digest == vector.requestDigest, "frozen host digest vector")
    let encoded = Wire.encode(ProviderCallControl(operation: .query, request: vector.request))
    expect(Wire.decode(ProviderCallControl.self, from: encoded)?.request == vector.request, "query wire roundtrip")
}
let oldList = try JSONDecoder().decode(WindowList.self, from: Wire.encode(WindowList(macName: "old", windows: [], active: .desktop)))
expect(oldList.providerCalls == nil, "old WindowList optional capability compatibility")
print("PASS \(checks) iPad Dots model and wire checks; native call and sentry authority unimplemented; external effects0")
