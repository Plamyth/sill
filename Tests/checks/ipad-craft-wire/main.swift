import Foundation
import StreamProtocol

var count = 0
func check(_ value: Bool, _ name: String) {
    precondition(value, name); count += 1
}
func rejects(_ name: String, _ body: () throws -> Void) {
    do { try body(); preconditionFailure(name) } catch { count += 1 }
}
let requestID = UUID(uuidString: "01234567-89ab-4cde-8fab-0123456789ab")!
let operationID = UUID(uuidString: "11234567-89ab-4cde-8fab-0123456789ab")!
let device = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
let otherDevice = AudioForwardingDeviceID(hex: String(repeating: "b", count: 64))!
let catalog = try ConfiguredCraftActionCatalog(expectedProfileId: UUID(), expectedAssignmentSha256: String(repeating: "c", count: 64))
let client = try ConfiguredCraftActionRequest(operationId: operationID, deviceId: device, catalog: catalog, issuedAt: 1794000000123)
let controls = [ConfiguredCraftActionControl(requestId: requestID),
                ConfiguredCraftActionControl(requestId: requestID, client: client),
                ConfiguredCraftActionControl(requestId: requestID, operationId: operationID)]
for control in controls {
    let data = try JSONEncoder().encode(control)
    let roundtrip = try ConfiguredCraftActionControl.decode(data)
    check(roundtrip.requestId == requestID && roundtrip.operation == control.operation, "control correlation")
    check(roundtrip.targetOperationId == control.targetOperationId, "original operation")
    let raw = String(decoding: data, as: UTF8.self)
    check(!raw.contains(requestID.uuidString), "canonical lowercase UUID")
    check(!raw.contains("deviceSessionId") && !raw.contains("authenticatedDeviceId"), "no client authority")
}
let invoke = controls[1], query = controls[2]
let result = try ConfiguredCraftActionResult(outcome: .unknown, operationId: operationID,
    deviceId: device, bindingSha256: nil, invoked: true, reason: "executor_result_unknown")
for control in [invoke, query] {
    let state = try ConfiguredCraftActionState(control: control, deviceId: device, result: result)
    let decoded = try ConfiguredCraftActionState.decode(JSONEncoder().encode(state))
    check(decoded.matches(control) && decoded.result?.invoked == true, "unknown preserves executor fact")
    check(decoded.result?.effectConfirmed == false, "never voice effect acceptance")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
    let nested = object["result"] as! [String: Any]
    check(nested["bindingSha256"] is NSNull, "required explicit null hash")
}
let state = try ConfiguredCraftActionState(control: controls[0], deviceId: device, catalog: catalog)
check(try ConfiguredCraftActionState.decode(JSONEncoder().encode(state)).matches(controls[0]), "catalog union")
let error = try ConfiguredCraftActionState(control: invoke, deviceId: device, error: "sentry_protected")
check(try ConfiguredCraftActionState.decode(JSONEncoder().encode(error)).error == "sentry_protected", "outer stable error")
rejects("outer error is stable code") { _ = try ConfiguredCraftActionState(control: invoke, deviceId: device, error: "bad-reason") }
for reason in ["prior-operation-result-unknown", "executor-submitted-result-unknown",
               " original producer reason ", String(repeating: "가", count: 85) + "a"] {
    let producer = try ConfiguredCraftActionResult(outcome: .unknown, operationId: operationID,
        deviceId: device, bindingSha256: nil, invoked: true, reason: reason)
    let envelope = try ConfiguredCraftActionState(control: query, deviceId: device, result: producer)
    let decoded = try ConfiguredCraftActionState.decode(JSONEncoder().encode(envelope))
    check(decoded.result?.reason == reason && decoded.result?.invoked == true, "producer reason preserved byte-for-byte")
}
for reason in ["", " \t\n", String(repeating: "x", count: 257), String(repeating: "가", count: 86)] {
    rejects("invalid producer reason constructor") {
        _ = try ConfiguredCraftActionResult(outcome: .unknown, operationId: operationID,
            deviceId: device, bindingSha256: nil, invoked: false, reason: reason)
    }
    let envelope = try ConfiguredCraftActionState(control: query, deviceId: device, result: result)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as! [String: Any]
    var nested = object["result"] as! [String: Any]; nested["reason"] = reason; object["result"] = nested
    rejects("invalid producer reason raw decoder") {
        _ = try ConfiguredCraftActionState.decode(JSONSerialization.data(withJSONObject: object))
    }
}
let nullReasonEnvelope = try ConfiguredCraftActionState(control: query, deviceId: device, result: result)
var nullReasonObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nullReasonEnvelope)) as! [String: Any]
var nullReasonResult = nullReasonObject["result"] as! [String: Any]
nullReasonResult["reason"] = NSNull(); nullReasonObject["result"] = nullReasonResult
rejects("explicit null producer reason rejected") {
    _ = try ConfiguredCraftActionState.decode(JSONSerialization.data(withJSONObject: nullReasonObject))
}
rejects("wrong device result") { _ = try ConfiguredCraftActionState(control: invoke, deviceId: otherDevice, result: result) }
rejects("wrong operation result") {
    let other = ConfiguredCraftActionControl(requestId: requestID, operationId: UUID())
    _ = try ConfiguredCraftActionState(control: other, deviceId: device, result: result)
}
let plain = String(decoding: try JSONEncoder().encode(controls[0]), as: UTF8.self)
for bad in [plain.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0"),
            plain.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1e0"),
            plain.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
            plain.replacingOccurrences(of: requestID.uuidString.lowercased(), with: requestID.uuidString),
            "{\"schemaVersion\":1," + plain.dropFirst(),
            "{\"schema\\u0056ersion\":1," + plain.dropFirst(),
            "{\"deviceSessionId\":\"fake\"," + plain.dropFirst(), "[]", "null"] {
    rejects("strict original tokens/keys/UUID") { _ = try ConfiguredCraftActionControl.decode(Data(bad.utf8)) }
}
let invokeBytes = String(decoding: try JSONEncoder().encode(invoke), as: UTF8.self)
for token in ["0", "-1", "1.0", "1e3", "true", "\"1794000000123\"", "9007199254740992"] {
    let bad = invokeBytes.replacingOccurrences(of: "1794000000123", with: token)
    rejects("issuedAt positive safe integer token") { _ = try ConfiguredCraftActionControl.decode(Data(bad.utf8)) }
}
rejects("oversize control") { _ = try ConfiguredCraftActionControl.decode(Data(repeating: 32, count: 4097)) }
rejects("oversize state") { _ = try ConfiguredCraftActionState.decode(Data(repeating: 32, count: 16385)) }
check(StreamMessageKind.sentryReturnRequest.rawValue == 223 && StreamMessageKind.sentryReturnState.rawValue == 224, "existing Sentry kinds")
check(StreamMessageKind.configuredCraftActionControl.rawValue == 225 && StreamMessageKind.configuredCraftActionState.rawValue == 226, "Craft kinds")
check(StreamMessage.clientPayloadLimit(for: .configuredCraftActionControl) == 4096, "control bound")
check(StreamMessage.hostPayloadLimit(for: .configuredCraftActionState) == 16384, "state bound")
check(StreamMessage.clientPayloadLimit(for: .configuredCraftActionState) == -1 && StreamMessage.hostPayloadLimit(for: .configuredCraftActionControl) == -1, "reverse directions rejected")
for capability: Int? in [nil, 1] {
    let list = WindowList(macName: "fixture", windows: [], active: .desktop, configuredCraftActions: capability)
    let decoded = try JSONDecoder().decode(WindowList.self, from: JSONEncoder().encode(list))
    check(decoded.configuredCraftActions == capability, "optional capability roundtrip")
}
print("PASS \(count) actual protocol checks; no host/client/socket/action/audio effects")
