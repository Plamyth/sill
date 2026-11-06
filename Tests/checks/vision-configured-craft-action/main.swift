import Foundation

typealias Action = VisionConfiguredCraftAction
var checks = 0
func expect(_ value: Bool, _ name: String) {
    checks += 1
    if !value { fputs("FAIL \(name)\n", stderr); exit(1) }
}
let assignment = String(repeating: "Ab", count: 32)
let profile = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
let binding = Action.Binding(deviceId: "device", profileId: profile, assignmentSha256: assignment)
let scope = VisionRemoteAudioIntent.Scope(connection: UUID(), window: UUID(), admission: UUID(),
    video: UUID(), foreground: UUID(), privacy: 1)
var context = Action.Context(hostKey: "trusted-host", scope: scope, binding: binding,
    routeGeneration: UUID(), capabilityPresent: true, routeImplemented: true, admitted: true)
func readyReadback(_ desire: VisionRemoteAudioIntent.Desire) -> Action.MediaReadback {
    .init(desire: desire, microphoneReady: desire.microphone, speakerReady: desire.playback,
          microphoneOff: !desire.microphone, speakerOff: !desire.playback)
}
let date = Date(timeIntervalSince1970: 1_793_900_000)
let id = UUID()
var issued = 0
func issue() -> UUID { issued += 1; return id }
func begin(_ model: inout Action, _ c: Action.Context, held: Double = 0.5) -> Action.Effect? {
    model.begin(heldFor: held, context: c, now: 100, issuedAt: date, operationId: issue)
}
func invocation(_ effect: Action.Effect?) -> Action.Operation {
    guard case .invoke(let op) = effect else { fatalError("invoke effect missing") }
    return op
}
func result(_ outcome: Action.Result.Outcome, invoked: Bool, operation: UUID = id,
            device: String = "device", hash: String? = assignment, confirmed: Bool = false) -> Action.Result {
    .init(outcome: outcome, operationId: operation, deviceId: device, bindingSha256: hash,
          invoked: invoked, effectConfirmed: confirmed, reason: "fixture")
}
expect(Action.holdDuration == 0.5, "500ms를 사용함")
for held in [0, 0.1, 0.499, Double.nan, Double.infinity] {
    var model = Action()
    expect(begin(&model, context, held: held) == nil && model.phase == .idle, "짧은 누름은 준비·호출을 만들지 않음")
}
for mode in 0..<5 {
    var unsupported = context
    if mode == 0 { unsupported.capabilityPresent = false }
    if mode == 1 { unsupported.routeImplemented = false }
    if mode == 2 { unsupported.binding = nil }
    if mode == 3 { unsupported.routeGeneration = nil }
    if mode == 4 { unsupported.admitted = false }
    var model = Action()
    expect(begin(&model, unsupported) == nil && model.phase == .idle, "미지원 route·descriptor·권한에서는 미디어 준비도 없음")
}
expect(issued == 0, "미지원·짧은 누름은 operationId도 만들지 않음")

var model = Action()
guard case .prepare(let preparing) = begin(&model, context) else { fatalError("prepare missing") }
expect(issued == 1 && preparing.request.operationId == id, "명시적 길게 누르기당 ID 하나")
expect(preparing.request.schemaVersion == 1 && preparing.request.inputID == "speed.button.stop-play" &&
       preparing.request.trigger == "longPress" && preparing.request.operation == "invoke-configured-craft-action" &&
       preparing.request.expectedProfileId == binding.profileId && preparing.request.issuedAt == 1_793_900_000_000,
       "초안 필드를 그대로 결속함")
expect(preparing.request.expectedAssignmentSha256 == assignment, "광고 assignment SHA를 불투명하게 보존함")
expect(model.advance(context: context, now: 101) == nil && begin(&model, context) == nil,
       "준비 중 중복 명시 입력·poll은 전송을 만들지 않음")
context.readback = readyReadback(.init(playback: true, microphone: true))
let op = invocation(model.advance(context: context, now: 102))
expect(op == preparing && model.advance(context: context, now: 102.1) == nil,
       "준비 뒤 같은 operation으로 invoke effect를 한 번만 냄")
expect(model.takeInvocation(op, context: context, now: 102.2)?.operationId == id,
       "전송 직전에 현재 fence와 입출력 준비를 재확인함")
expect(model.takeInvocation(op, context: context, now: 102.3) == nil, "같은 invoke effect를 중복 소비하지 않음")
for invalid in [result(.invoked, invoked: true, operation: UUID()), result(.invoked, invoked: true, device: "other"),
                result(.invoked, invoked: true, confirmed: true),
                result(.invoked, invoked: false), result(.rejected, invoked: true)] {
    expect(!model.receive(invalid, context: context, now: 103), "다른 요청·기기·통화 ACK·모순 상태를 거절함")
}
expect(model.receive(result(.unknown, invoked: true), context: context, now: 103),
       "unknown+invoked true는 executor 인계·효과 미확인으로 수용함")
if case .completed(_, let saved) = model.phase {
    expect(saved.outcome == .unknown && saved.invoked && !saved.effectConfirmed, "unknown의 invoked true를 지우지 않음")
} else { fatalError("unknown result missing") }
let unknownState = model.phase
expect(model.advance(context: context, now: 104) == nil && model.phase == unknownState && model.canBegin(context),
       "unknown 뒤 자동 재토글은 없고 새 사용자 동작만 허용함")
expect(!model.receive(result(.invoked, invoked: true), context: context, now: 104), "terminal 뒤 늦은 결과가 의미를 바꾸지 않음")
let nextId = UUID()
let explicitNext = invocation(model.begin(heldFor: 0.5, context: context, now: 105, issuedAt: date, operationId: { nextId }))
expect(explicitNext.request.operationId == nextId && nextId != id,
       "사용자가 다시 길게 누른 새 동작만 새 operationId를 만듦")
expect(!model.receive(result(.unknown, invoked: true), context: context, now: 106), "이전 unknown 결과가 새 명시 동작을 가로채지 못함")

func changedScope(_ c: Action.Context, connection: UUID? = nil, window: UUID? = nil,
                  admission: UUID? = nil, video: UUID? = nil, foreground: UUID? = nil, privacy: UInt64 = 1) -> Action.Context {
    var next = c
    let s = c.scope!
    next.scope = .init(connection: connection ?? s.connection, window: window ?? s.window,
        admission: admission ?? s.admission, video: video ?? s.video, foreground: foreground ?? s.foreground, privacy: privacy)
    return next
}
var notAdmitted = context; notAdmitted.admitted = false
var noRoute = context; noRoute.routeImplemented = false
var newRoute = context; newRoute.routeGeneration = UUID()
var newBinding = context
newBinding.binding = .init(deviceId: "other-device", profileId: binding.profileId,
    assignmentSha256: binding.assignmentSha256)
var assignmentChanged = context
assignmentChanged.binding = .init(deviceId: "device", profileId: UUID(),
    assignmentSha256: "new-advertised-hash")
let changed = [changedScope(context, connection: UUID()), changedScope(context, window: UUID()),
    changedScope(context, admission: UUID()), changedScope(context, video: UUID()),
    changedScope(context, foreground: UUID()), notAdmitted, noRoute, newRoute, newBinding, assignmentChanged]
for stale in changed {
    var preparingContext = context; preparingContext.readback = nil
    var pending = Action()
    _ = begin(&pending, preparingContext)
    expect(pending.advance(context: stale, now: 101) != nil, "준비 중 연결·전경·창owner·route·할당 변경은 취소함")
    expect(pending.advance(context: context, now: 102) == nil, "취소 뒤 준비 완료가 늦게 와도 명령을 만들지 않음")
    var queued = Action()
    let captured = invocation(begin(&queued, context))
    expect(queued.takeInvocation(captured, context: stale, now: 101) == nil, "이전 연결의 늦은 명령 소비를 거절함")
    expect(queued.takeInvocation(captured, context: context, now: 102) == nil, "거절된 queue를 복구해 다시 실행하지 않음")
    var sent = Action()
    let sentOp = invocation(begin(&sent, context))
    _ = sent.takeInvocation(sentOp, context: context, now: 100)
    expect(!sent.receive(result(.invoked, invoked: true), context: stale, now: 101), "다른 세대의 결과는 수용하지 않음")
    _ = sent.advance(context: stale, now: 101)
    expect(sent.advance(context: context, now: 102) == nil, "전송 후 세대 상실도 자동 재토글하지 않음")
}
for ready in [false, true] {
    var c = context; c.readback = ready ? readyReadback(.init(playback: true, microphone: true)) : nil
    var cancelled = Action(); let effect = begin(&cancelled, c)
    expect(cancelled.cancel() != nil && cancelled.cancel() == nil, "취소는 해당 operation 정리만 한 번 요구함")
    expect(cancelled.advance(context: context, now: 101) == nil, "취소 후 준비 readback은 명령 없음")
    if case .invoke(let queued) = effect { expect(cancelled.takeInvocation(queued, context: context, now: 101) == nil, "취소 후 늦은 queue 소비 없음") }
}
for time in [108.0, 99, Double.nan] {
    var c = context; c.readback = nil
    var timed = Action(); _ = begin(&timed, c)
    expect(timed.advance(context: context, now: time) != nil && timed.advance(context: context, now: 109) == nil,
           "유한 준비 기한·역행 시각은 취소하며 재실행하지 않음")
}
var timed = Action(); let timedOp = invocation(begin(&timed, context)); _ = timed.takeInvocation(timedOp, context: context, now: 100)
_ = timed.advance(context: context, now: 110)
expect(timed.phase == .unknown(timedOp) && timed.canBegin(context), "timeout은 기존 ID의 unknown이며 새 명시 동작은 막지 않음")
expect(!timed.receive(result(.invoked, invoked: true), context: context, now: 110), "timeout 뒤 늦은 invoked가 성공으로 바뀌지 않음")
expect(timed.advance(context: context, now: 111) == nil, "timeout 후 poll은 아무 effect도 없음")
var privacyPreparation = Action(); var unready = context; unready.readback = nil
_ = begin(&privacyPreparation, unready)
expect(privacyPreparation.advance(context: changedScope(context, privacy: 2), now: 101) != nil,
       "입출력 준비의 정상 privacy revision 갱신은 연결 세대 변경으로 오판하지 않음")

let object: [String: Any] = ["outcome": "unknown", "operationId": id.uuidString, "deviceId": "device",
    "bindingSha256": assignment, "invoked": true, "effectConfirmed": false]
func decode(_ object: [String: Any]) -> Action.Result? {
    try? JSONDecoder().decode(Action.Result.self, from: JSONSerialization.data(withJSONObject: object))
}
expect(decode(object)?.invoked == true && decode(object)?.outcome == .unknown, "초안 JSON도 unknown+invoked true를 보존함")
for key in object.keys {
    var missing = object; missing.removeValue(forKey: key)
    expect(decode(missing) == nil, "outcome·hash·필수 상태 필드는 생략할 수 없음")
}
var absentOutcome = object; absentOutcome["outcome"] = "started"
expect(decode(absentOutcome) == nil, "통화 started ACK를 shortcut 결과로 파싱하지 않음")
var nullableRejection = object
nullableRejection["outcome"] = "rejected"
nullableRejection["invoked"] = false
nullableRejection["bindingSha256"] = NSNull()
expect(decode(nullableRejection)?.outcome == .rejected,
       "비교 전 거절의 필수 nullable bindingSha256를 보존함")

for desire in [VisionRemoteAudioIntent.Desire(), .init(playback: true, microphone: false),
               .init(playback: false, microphone: true), .init(playback: true, microphone: true)] {
    var selected = context
    selected.selection = desire
    selected.selectionRevision = 42
    selected.readback = readyReadback(desire)
    var explicit = Action()
    let selectedOp = invocation(begin(&explicit, selected))
    expect(selectedOp.mediaSelection == desire, "사용자가 명시한 각 ON/OFF 방향을 보존함")
    expect(explicit.takeInvocation(selectedOp, context: selected, now: 101) != nil,
           "OFF를 포함한 fresh readback 일치는 active 통화 없이 호출 가능함")
    expect(explicit.receive(result(.invoked, invoked: true), context: selected, now: 102), "OFF 선택도 효과 미확인 호출 결과로만 보존함")
    var cancelled = Action(); _ = begin(&cancelled, selected)
    guard case .cancelPreparation(let cleanup) = cancelled.cancel() else { fatalError("cleanup missing") }
    expect(cleanup.mediaSelection == desire && selected.selection == desire, "준비 취소는 사용자 OFF를 양쪽 ON으로 바꾸지 않음")
    selected.readback = readyReadback(.init(playback: !desire.playback, microphone: desire.microphone))
    expect(!selected.mediaReady, "다른 선택의 readback을 준비 완료로 쓰지 않음")
}
var otherDevice = context
otherDevice.selection = nil
otherDevice.otherDeviceSelected = true
otherDevice.deviceRouteRevision = UUID()
otherDevice.readback = readyReadback(.init())
var preservedDevice = Action()
let deviceOp = invocation(begin(&preservedDevice, otherDevice))
expect(deviceOp.mediaSelection == .init(), "다른 장치 명시 선택이 있으면 Vision 양방향을 기본 ON으로 강제하지 않음")
var changedDevice = otherDevice; changedDevice.deviceRouteRevision = UUID()
expect(preservedDevice.takeInvocation(deviceOp, context: changedDevice, now: 101) == nil,
       "선택한 다른 장치의 readback 세대가 바뀌면 늦은 호출을 취소함")
otherDevice.deviceRouteRevision = nil
expect(!Action().canBegin(otherDevice), "다른 장치 선택은 확인된 route revision 없이 호출하지 않음")
var noChoice = context; noChoice.selection = nil; noChoice.readback = nil
var firstAction = Action()
guard case .prepare(let defaults) = begin(&firstAction, noChoice) else { fatalError("defaults missing") }
expect(defaults.mediaSelection == .init(playback: true, microphone: true), "명시 선택이 없을 때만 기기 기본 양방향 준비를 요청함")
var userOff = noChoice; userOff.selection = .init(); userOff.selectionRevision = 1; userOff.readback = readyReadback(.init())
guard case .cancelPreparation = firstAction.advance(context: userOff, now: 101) else { fatalError("changed intent not cancelled") }
expect(firstAction.advance(context: context, now: 102) == nil, "기본 준비 중 사용자의 OFF 선택 뒤 늦은 기본 준비가 호출하지 않음")
var unconfirmedOff = userOff
unconfirmedOff.readback = .init(desire: .init(), microphoneReady: false, speakerReady: false,
    microphoneOff: false, speakerOff: true)
expect(!unconfirmedOff.mediaReady, "OFF도 실제 정리가 확인되지 않으면 준비 완료가 아님")

var ownPreparation = Action()
guard case .prepare(let ownOp) = begin(&ownPreparation, noChoice) else { fatalError("own preparation missing") }
var preparedContext = noChoice
preparedContext.selection = .init(playback: true, microphone: true)
preparedContext.selectionRevision = 7
preparedContext.readback = readyReadback(.init(playback: true, microphone: true))
expect(!ownPreparation.recordPreparedSelection(operationId: UUID(), revision: 7, context: preparedContext),
       "다른 operation의 준비 revision은 수용하지 않음")
expect(!ownPreparation.recordPreparedSelection(operationId: id, revision: 6, context: preparedContext),
       "실제 현재 revision과 다른 준비 영수증을 거절함")
expect(ownPreparation.recordPreparedSelection(operationId: id, revision: 7, context: preparedContext),
       "이 operation이 만든 정확한 기본 준비 revision만 결속함")
let afterOwnPreparation = invocation(ownPreparation.advance(context: preparedContext, now: 102))
expect(afterOwnPreparation.request == ownOp.request && afterOwnPreparation.fence.selectionRevision == 7,
       "기본 준비는 같은 요청 ID와 기한을 유지함")
var newlyOff = preparedContext; newlyOff.selection = .init(); newlyOff.selectionRevision = 8; newlyOff.readback = readyReadback(.init())
expect(ownPreparation.takeInvocation(afterOwnPreparation, context: newlyOff, now: 103) == nil,
       "준비 후 사용자 OFF가 새로 들어오면 늦은 명령을 거절함")
expect(ownPreparation.advance(context: preparedContext, now: 104) == nil && newlyOff.selection == .init(),
       "취소는 새 사용자 OFF 의도를 덮지 않음")
var delayed = Action(); _ = begin(&delayed, noChoice)
expect(!delayed.recordPreparedSelection(operationId: id, revision: 8, context: newlyOff),
       "늦은 기본 준비 영수증으로 사용자가 고른 OFF를 되돌리지 않음")
var scopeChanged = preparedContext; scopeChanged.scope = changedScope(preparedContext, window: UUID()).scope
expect(!delayed.recordPreparedSelection(operationId: id, revision: 7, context: scopeChanged),
       "준비 영수증도 창 owner 세대를 넘어오지 못함")
_ = delayed.cancel()
expect(!delayed.recordPreparedSelection(operationId: id, revision: 7, context: preparedContext), "취소 뒤 준비 callback도 무효임")

let encoded = try JSONEncoder().encode(preparing.request)
let clientObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
expect(Set(clientObject.keys) == ["schemaVersion", "operation", "operationId", "deviceId", "inputID", "trigger",
       "expectedProfileId", "expectedAssignmentSha256", "issuedAt"], "최종 client는 정확한 9필드이며 session echo가 없음")
expect(clientObject["operation"] as? String == "invoke-configured-craft-action", "Core가 확정한 operation을 인코딩함")
expect(String(data: encoded, encoding: .utf8)!.contains("\"issuedAt\":1793900000000"),
       "issuedAt는 초나 실수가 아닌 UTC epoch milliseconds JSON 정수임")
expect(clientObject["expectedProfileId"] as? String == profile.uuidString &&
       clientObject["expectedAssignmentSha256"] as? String == assignment, "UUID profile과 불투명 SHA를 그대로 인코딩함")
let catalogRequest = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Action.CatalogRequest())) as! [String: Any]
expect(Set(catalogRequest.keys) == ["schemaVersion", "operation"] &&
       catalogRequest["operation"] as? String == "get-configured-craft-action", "Catalog request는 확정한 2필드만 인코딩함")
let catalogObject: [String: Any] = ["schemaVersion": 1, "supported": true, "expectedProfileId": profile.uuidString,
    "inputID": "speed.button.stop-play", "trigger": "longPress", "expectedAssignmentSha256": String(repeating: "a", count: 64)]
func catalog(_ object: [String: Any]) -> Action.Catalog? {
    try? JSONDecoder().decode(Action.Catalog.self, from: JSONSerialization.data(withJSONObject: object))
}
expect(catalog(catalogObject)?.expectedProfileId == profile, "Catalog6는 settings SHA나 deviceSession 없이 수용함")
for key in catalogObject.keys {
    var missing = catalogObject; missing.removeValue(forKey: key)
    expect(catalog(missing) == nil, "Catalog 필수 6필드는 생략할 수 없음")
}
for (key, value) in [("schemaVersion", 2 as Any), ("supported", false), ("inputID", "other"),
                     ("trigger", "tap"), ("expectedProfileId", "not-a-uuid"),
                     ("expectedAssignmentSha256", String(repeating: "A", count: 64))] {
    var invalid = catalogObject; invalid[key] = value
    expect(catalog(invalid) == nil, "다른 스키마·입력·trigger·형식의 Catalog를 활성화하지 않음")
}
for receipt in [decode(nullableRejection)!, result(.rejected, invoked: false, hash: "different-host-assignment"),
                result(.unknown, invoked: false), result(.unknown, invoked: true),
                result(.unknown, invoked: true, hash: "different-host-assignment"),
                result(.invoked, invoked: true, hash: "different-host-assignment")] {
    var receiver = Action(); let candidate = invocation(begin(&receiver, context))
    _ = receiver.takeInvocation(candidate, context: context, now: 100)
    expect(receiver.receive(receipt, context: context, now: 101), "null·다른 hash·unknown을 응답 전체 폐기로 처리하지 않음")
    if case .completed(_, let saved) = receiver.phase {
        expect(saved == receipt && !saved.effectConfirmed, "6필드 결과와 invoked false/true를 효과 미확인으로 보존함")
    } else { fatalError("result not retained") }
    expect(receiver.advance(context: context, now: 102) == nil, "거절·unknown 수용이 자동 재토글을 만들지 않음")
    if receipt.outcome != .rejected { expect(receiver.message?.contains("미확인") == true || receiver.message?.contains("확인하지 못") == true,
        "hash 불일치나 unknown을 executor 실행·통화 성공으로 표시하지 않음") }
}
print("PASS \(checks) configured Craft action checks; actual Host/Core/device/media/input actions 0")
