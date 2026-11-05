import Foundation
import StreamProtocol

var checks = 0
func expect(_ value: Bool, _ reason: String) { checks += 1; precondition(value, reason) }
var now = 100.0
let peer = UUID(), nextPeer = UUID(), key = String(repeating: "c", count: 64)
let device = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
let session = "abCDef01-2345-4678-9abc-0123456789Ab"
func request(_ action: ProviderCallRequest.Action = .start, session: String? = nil) throws -> ProviderCallRequest {
    try .init(requestId: UUID(), action: action, expectedLeaseRevision: .init(7), pairedDeviceId: device,
              desiredInput: true, desiredOutput: true, callSessionId: session)
}
func state(_ request: ProviderCallRequest, _ status: ProviderCallResult.Status,
           session: String? = nil, provider: String = "codex-app-server") throws -> ProviderCallState {
    try .init(request: request, result: .init(requestId: request.requestId, status: status,
        reason: "fixture_result", callSessionId: session, provider: provider))
}
func native() -> IPadProviderCall {
    var model = IPadProviderCall(connection: peer, target: .nativeCodex, clock: { now })
    model.observe(connection: peer, capability: 1, hostKey: key, providerCallKinds: ["codex-app-server"])
    return model
}
let start = try request()
var model = IPadProviderCall(connection: peer, target: .nativeCodex, clock: { now })
for kinds: [String]? in [nil, [], ["chatgpt-dots-webguest"], ["codex_app_server"]] {
    model.observe(connection: peer, capability: 1, hostKey: key, providerCallKinds: kinds)
    expect(!model.targetSupported && model.perform(start) == nil, "legacy capability never advertises native control")
}
model = native()
let control = model.perform(start)!
let object = try JSONSerialization.jsonObject(with: Wire.encode(control)) as! [String: Any]
expect(control.schemaVersion == 2 && control.providerKind == .nativeCodex, "native uses schema2 exact selector")
expect(Set(object.keys) == ["schemaVersion", "operation", "request", "expectedProviderKind"], "only the fourth control field is added")
expect(object["expectedProviderKind"] as? String == "codex-app-server", "native selector is exact")
expect((object["request"] as! [String: Any]).count == 7, "request retains seven fields")
expect(Wire.decode(ProviderCallControl.self, from: Wire.encode(control))?.request.digest == start.digest,
       "native selector leaves request digest unchanged")
let slot = model.pending!.id
expect(!model.receive(try state(start, .started, session: session, provider: "chatgpt-dots-webguest"), from: peer), "Dots cannot satisfy native")
for invalid: String? in [nil, "not-a-uuid"] {
    expect(!model.receive(try state(start, .started, session: invalid), from: peer), "native started requires a session UUID")
}
expect(model.pending?.id == slot, "invalid result retains physical slot")
expect(model.receive(try state(start, .started, session: session), from: peer), "native direct started accepted")
expect(model.activeCall?.callSessionId == session && !model.selectTarget(.chatGPTDots), "active session spelling and target lock retained")
let overlappingStart = try request()
let normalizedStop = try request(.stop, session: session.lowercased())
expect(model.perform(overlappingStart) == nil && model.perform(normalizedStop) == nil,
       "active call blocks restart and case-normalized stop")
for failure: ProviderCallResult.Status in [.failed, .unsupported, .unknown] {
    let stop = try request(.stop, session: session)
    expect(model.perform(stop)?.request.callSessionId == session, "explicit stop reuses current exact session")
    expect(model.receive(try state(stop, failure), from: peer), "stop command failure accepted separately")
    expect(model.activeCall?.callSessionId == session && model.canPerform && !model.canChangeTarget,
           "failed stop preserves manual recovery and blocks target switch")
    expect(model.perform(try request()) == nil, "failed stop cannot authorize a new call")
}
let stop = try request(.stop, session: session)
_ = model.perform(stop)
for invalid: String? in [nil, UUID().uuidString, session.lowercased()] {
    expect(!model.receive(try state(stop, .stopped, session: invalid), from: peer), "native stopped must match exact original session")
}
expect(model.receive(try state(stop, .stopped, session: session), from: peer) && model.activeCall == nil,
       "confirmed matching stopped releases active call")
expect(model.selectTarget(.chatGPTDots), "confirmed stop permits explicit target switch")
let dotsStart = try request()
let dotsControl = model.perform(dotsStart)!
let dotsObject = try JSONSerialization.jsonObject(with: Wire.encode(dotsControl)) as! [String: Any]
expect(dotsControl.schemaVersion == 1 && dotsObject.count == 3 && dotsObject["expectedProviderKind"] == nil,
       "legacy Dots schema1 encoding is unchanged")
expect(model.receive(try state(dotsStart, .started, session: "dots-session", provider: "chatgpt-dots-webguest"), from: peer), "Dots direct start")
let dotsStop = try request(.stop, session: "dots-session")
_ = model.perform(dotsStop)
expect(model.receive(try state(dotsStop, .stopped, provider: "chatgpt-dots-webguest"), from: peer) && model.activeCall == nil,
       "Dots null stopped preserves original contract")
model = native()
_ = model.perform(start)
_ = model.receive(try state(start, .started, session: session), from: peer)
let timedStop = try request(.stop, session: session)
_ = model.perform(timedStop)
let timedSlot = model.pending!
now = 111
expect(model.timeout(timedSlot) && model.pending?.id == timedSlot.id && model.activeCall?.callSessionId == session,
       "timeout preserves physical slot and active call")
model.observe(connection: peer, capability: 1, hostKey: key, providerCallKinds: ["codex-app-server"])
expect(!model.canPerform, "same TLS cannot clear timeout")
model.observe(connection: nextPeer, capability: 1, hostKey: key, providerCallKinds: ["codex-app-server"])
expect(model.pending == nil && model.activeCall?.callSessionId == session && model.canPerform,
       "actual TLS replacement preserves same-host explicit stop recovery")
let retry = try request(.stop, session: session)
expect(model.perform(retry) != nil, "manual stop after connection replacement")
expect(!model.receive(try state(retry, .stopped, session: session), from: peer), "old TLS cannot drain new stop")
expect(model.receive(try state(retry, .stopped, session: session), from: nextPeer), "same session stop on new TLS")
now = 200
model = native()
_ = model.perform(start)
_ = model.receive(try state(start, .started, session: session), from: peer)
model.observe(connection: nextPeer, capability: 1, hostKey: String(repeating: "d", count: 64), providerCallKinds: ["codex-app-server"])
expect(model.hostKey == key && model.activeCall?.callSessionId == session && !model.canPerform,
       "other Mac cannot inherit or discard active call")
model.observe(connection: nextPeer, capability: 1, hostKey: key, providerCallKinds: ["codex-app-server"])
expect(model.canPerform && !model.selectTarget(.grokBot), "same trusted Mac restores stop only")
for version in [1, 2, 3] {
    var invalid = object
    invalid["schemaVersion"] = version
    invalid["expectedProviderKind"] = "chatgpt-dots-webguest"
    expect(Wire.decode(ProviderCallControl.self, from: try JSONSerialization.data(withJSONObject: invalid)) == nil,
           "selector cannot be smuggled into legacy or unknown schema")
}
let list = WindowList(macName: "fixture", windows: [], active: .desktop, providerCalls: 1, providerCallKinds: ["codex-app-server"])
expect(Wire.decode(WindowList.self, from: Wire.encode(list))?.providerCallKinds == ["codex-app-server"], "explicit provider list wire roundtrip")
print("PASS \(checks) native selector/session/stop-recovery model checks; no Host/device/media effects")
