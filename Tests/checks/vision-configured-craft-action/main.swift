import Foundation
import StreamProtocol

typealias Action = VisionConfiguredCraftAction
var checks = 0
func expect(_ value: Bool, _ name: String) {
    checks += 1
    if !value { fputs("FAIL \(name)\n", stderr); exit(1) }
}
let assignment = String(repeating: "ab", count: 32)
let profile = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
let binding = Action.Binding(deviceId: String(repeating: "d", count: 64), profileId: profile, assignmentSha256: assignment)
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
            device: String = String(repeating: "d", count: 64), hash: String? = assignment) -> Action.Result {
    try! .init(outcome: outcome, operationId: operation, deviceId: AudioForwardingDeviceID(hex: device)!, bindingSha256: hash,
          invoked: invoked, reason: "fixture")
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
       preparing.request.expectedProfileId == binding.profileId.uuidString.lowercased() && preparing.request.issuedAt == 1_793_900_000_000,
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
for invalid in [result(.invoked, invoked: true, operation: UUID()), result(.invoked, invoked: true, device: String(repeating: "e", count: 64)),
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
newBinding.binding = .init(deviceId: String(repeating: "e", count: 64), profileId: binding.profileId,
    assignmentSha256: binding.assignmentSha256)
var assignmentChanged = context
assignmentChanged.binding = .init(deviceId: String(repeating: "d", count: 64), profileId: UUID(),
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

let object: [String: Any] = ["outcome": "unknown", "operationId": id.uuidString.lowercased(), "deviceId": String(repeating: "d", count: 64),
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
expect(clientObject["expectedProfileId"] as? String == profile.uuidString.lowercased() &&
       clientObject["expectedAssignmentSha256"] as? String == assignment, "UUID profile과 불투명 SHA를 그대로 인코딩함")
let catalogRequest = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConfiguredCraftActionControl(requestId: UUID()))) as! [String: Any]
expect(Set(catalogRequest.keys) == ["schemaVersion", "requestId", "operation"] &&
       catalogRequest["operation"] as? String == "catalog", "외부 catalog는 공통 codec의 exact3를 사용함")
let catalogObject: [String: Any] = ["schemaVersion": 1, "supported": true, "expectedProfileId": profile.uuidString.lowercased(),
    "inputID": "speed.button.stop-play", "trigger": "longPress", "expectedAssignmentSha256": String(repeating: "a", count: 64)]
func catalog(_ object: [String: Any]) -> Action.Catalog? {
    try? JSONDecoder().decode(Action.Catalog.self, from: JSONSerialization.data(withJSONObject: object))
}
expect(catalog(catalogObject)?.expectedProfileId == profile.uuidString.lowercased(), "Catalog6는 settings SHA나 deviceSession 없이 수용함")
let extraCatalogKeys = ["deviceSessionId", "settingsSha256"].map { key -> (String, Bool) in
    var extra = catalogObject
    extra[key] = "unexpected-advertised-value"
    return (key, catalog(extra) != nil)
}
for (key, accepted) in extraCatalogKeys {
    expect(!accepted, "Catalog exact6 추가 키 \(key)를 거절함; 관측=\(extraCatalogKeys)")
}
for key in catalogObject.keys {
    var missing = catalogObject; missing.removeValue(forKey: key)
    expect(catalog(missing) == nil, "Catalog 필수 6필드는 생략할 수 없음")
}
for (key, value) in [("schemaVersion", 2 as Any), ("supported", false), ("inputID", String(repeating: "e", count: 64)),
                     ("trigger", "tap"), ("expectedProfileId", "not-a-uuid"),
                     ("expectedAssignmentSha256", String(repeating: "A", count: 64))] {
    var invalid = catalogObject; invalid[key] = value
    expect(catalog(invalid) == nil, "다른 스키마·입력·trigger·형식의 Catalog를 활성화하지 않음")
}
for receipt in [decode(nullableRejection)!, result(.rejected, invoked: false, hash: String(repeating: "c", count: 64)),
                result(.unknown, invoked: false), result(.unknown, invoked: true),
                result(.unknown, invoked: true, hash: String(repeating: "c", count: 64)),
                result(.invoked, invoked: true, hash: String(repeating: "c", count: 64))] {
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

let host = "executor-host"
var intent = VisionRemoteAudioIntent()
let preparedSelection = intent.prepareSelection(.init(playback: true, microphone: true), hostKey: host, operationId: UUID())!
expect(intent.desires[host] == .init(playback: true, microphone: true), "처음 명시 동작만 기본 두 방향을 준비함")
intent.setDesired(false, direction: .microphone, hostKey: host)
let changedRevision = intent.desiredRevision(.microphone, hostKey: host)
expect(intent.cancelPreparation(preparedSelection) == [.playback], "취소는 준비가 소유한 방향 revision만 반환함")
expect(intent.desires[host] == .init() && intent.desiredRevision(.microphone, hostKey: host) == changedRevision,
       "사용자의 나중 마이크 OFF와 그 revision을 보존함")
expect(intent.cancelPreparation(preparedSelection).isEmpty, "같은 준비 취소를 반복해도 새 선택에 영향이 없음")
var pristine = VisionRemoteAudioIntent()
let oldPreparation = pristine.prepareSelection(.init(playback: true, microphone: true), hostKey: host, operationId: UUID())!
expect(pristine.cancelPreparation(oldPreparation).count == 2 && pristine.desires[host] == nil,
       "아무 명시 선택도 없던 준비를 취소하면 미선택 상태를 복원함")
let newPreparation = pristine.prepareSelection(.init(playback: true, microphone: true), hostKey: host, operationId: UUID())!
expect(pristine.cancelPreparation(oldPreparation).isEmpty && pristine.desires[host]?.microphone == true,
       "이전 operation의 늦은 취소가 새 준비를 지우지 않음")
expect(newPreparation.revision > oldPreparation.revision, "선택 제거 뒤 새 준비도 증가한 revision을 받음")
for desire in [VisionRemoteAudioIntent.Desire(), .init(playback: true, microphone: false),
               .init(playback: false, microphone: true), .init(playback: true, microphone: true)] {
    var saved = VisionRemoteAudioIntent(desires: [host: desire])
    let ticket = saved.prepareSelection(desire, hostKey: host, operationId: UUID())!
    expect(ticket.revision == 0 && saved.cancelPreparation(ticket).isEmpty && saved.desires[host] == desire,
           "기존 네 가지 명시 선택은 준비·취소가 변경하지 않음")
    if desire != .init(playback: true, microphone: true) {
        expect(saved.prepareSelection(.init(playback: true, microphone: true), hostKey: host, operationId: UUID()) == nil,
               "기존 OFF를 기본 ON으로 덮는 준비를 거절함")
    }
}

var executorContext = Action.Context(hostKey: "trusted-host", scope: scope, binding: binding,
    routeGeneration: UUID(), capabilityPresent: true, routeImplemented: true, admitted: true)
var executorClock = 100.0
var preparationCalls = 0, cancellationCalls = 0, finishCalls = 0, sends = 0
var preparationIDs: [UUID] = [], sentIDs: [UUID] = []
var lastControl: ConfiguredCraftActionControl?
var querySends = 0
func fixtureReadScope() -> VisionConfiguredCraftActionExecutor.ReadScope? {
    guard let scope = executorContext.scope else { return nil }
    return .init(hostKey: executorContext.hostKey!, connection: scope.connection, window: scope.window,
        admission: scope.admission, foreground: scope.foreground, video: scope.video,
        device: AudioForwardingDeviceID(hex: binding.deviceId)!)
}
let executor = VisionConfiguredCraftActionExecutor(context: { executorContext }, readScope: fixtureReadScope, prepare: { operation in
    preparationCalls += 1; preparationIDs.append(operation.request.operationId)
    executorContext.selection = operation.mediaSelection; executorContext.selectionRevision += 1
    return executorContext.selectionRevision
}, cancelPreparation: { _ in cancellationCalls += 1 }, finishPreparation: { _ in finishCalls += 1 },
    send: { control, _, _ in
        lastControl = control
        if let request = control.client { sends += 1; sentIDs.append(request.operationId) }
        if control.operation == .query { querySends += 1 }
        return true
    }, cancelSend: { _ in }, clock: { executorClock })
func acceptFixtureCatalog() {
    guard executor.context.binding == nil else { return }
    guard let control = lastControl, control.operation == .catalog else { return }
    let state = try! ConfiguredCraftActionState(control: control, deviceId: fixtureReadScope()!.device,
        catalog: .init(expectedProfileId: profile, expectedAssignmentSha256: assignment))
    expect(executor.receive(try! JSONEncoder().encode(state), in: fixtureReadScope()!), "격리 common catalog envelope를 상관 ID와 함께 수용함")
}
executor.begin(heldFor: 0.499, issuedAt: date)
expect(preparationCalls == 0 && sends == 0, "executor에서도 짧은 누름은 미디어·송신0")
executor.observe(capability: nil)
executor.begin(heldFor: 0.5, issuedAt: date)
expect(preparationCalls == 0 && sends == 0, "미지원 capability에서 실제 준비 closure도 호출0")
executor.observe(capability: 1)
executor.begin(heldFor: 0.5, issuedAt: date)
expect(preparationCalls == 0 && sends == 0, "catalog 성공 전 route flag만으로 준비하지 않음")
acceptFixtureCatalog()
executor.begin(heldFor: 0.5, issuedAt: date)
expect(preparationCalls == 1 && sends == 0 && executorContext.readback == nil,
       "prepare 실행은 준비 영수증만 반환하며 mediaReady를 만들지 않음")
executor.refresh(); executor.begin(heldFor: 0.5, issuedAt: date)
expect(preparationCalls == 1 && sends == 0, "같은 준비를 반복 실행하거나 invoke를 선행하지 않음")
executorContext = changedScope(executorContext, foreground: UUID())
executor.refresh()
expect(cancellationCalls == 1 && sends == 0, "전경 세대 상실은 해당 준비 취소1·송신0")
executorContext.readback = readyReadback(.init(playback: true, microphone: true))
executor.refresh()
expect(sends == 0, "취소 뒤 늦은 readback은 invoke를 만들지 않음")
executorContext.readback = nil
acceptFixtureCatalog()
executor.begin(heldFor: 0.5, issuedAt: date)
executorContext.readback = readyReadback(.init(playback: true, microphone: true))
executor.refresh(); executor.refresh()
expect(finishCalls == 0, "writer의 큐 접수만으로 준비 소유권을 넘기지 않음; 관측=\(finishCalls)")
executor.submitted(lastControl!.requestId)
executor.submitted(lastControl!.requestId)
expect(sends == 1 && finishCalls == 1 && preparationIDs.last == sentIDs.last,
       "현재 fresh readback 뒤 같은 operation을 단 한 번 송신·준비 인계함")
executorClock = 111
executor.refresh(); executor.refresh()
expect(sends == 1, "응답 timeout과 unknown에서 자동 invoke 재시도0")
let noResultPhase = executor.model.phase
if case .unknown = noResultPhase {} else { fatalError("executor timeout unknown missing") }
for mutate in [
    { (c: inout Action.Context) in c = changedScope(c, connection: UUID()) },
    { (c: inout Action.Context) in c = changedScope(c, window: UUID()) },
    { (c: inout Action.Context) in c = changedScope(c, admission: UUID()) },
    { (c: inout Action.Context) in c = changedScope(c, video: UUID()) },
    { (c: inout Action.Context) in c.admitted = false },
    { (c: inout Action.Context) in c.invocationAllowed = false },
    { (c: inout Action.Context) in c.selectionRevision += 1 },
    { (c: inout Action.Context) in c.otherDeviceSelected = true; c.deviceRouteRevision = UUID() }
] {
    executorContext = Action.Context(hostKey: "trusted-host", scope: scope, binding: binding,
        routeGeneration: UUID(), capabilityPresent: true, routeImplemented: true, admitted: true)
    executor.refresh(); acceptFixtureCatalog()
    executor.begin(heldFor: 0.5, issuedAt: date)
    let beforeCancel = cancellationCalls
    mutate(&executorContext); executor.refresh()
    expect(cancellationCalls == beforeCancel + 1 && sends == 1,
           "연결·창·admission·video·focus·Sentry·선택·장치 변경은 준비 취소 후 늦은 명령0")
}
executorContext.invocationAllowed = false
let beforeBlocked = preparationCalls
let beforeBlockedSends = sends
executor.begin(heldFor: 0.5, issuedAt: date)
expect(preparationCalls == beforeBlocked && sends == beforeBlockedSends && executor.message?.contains("권한") == true,
       "실행 권한 미확인 상태를 표시하고 준비·invoke0")
executorContext = Action.Context(hostKey: "trusted-host", scope: scope, binding: binding,
    routeGeneration: UUID(), capabilityPresent: true, routeImplemented: true, admitted: true)
executor.refresh(); acceptFixtureCatalog()
executor.begin(heldFor: 0.5, issuedAt: date)
let cancelBefore = cancellationCalls
executor.cancel(); executor.cancel()
executorContext.readback = readyReadback(.init(playback: true, microphone: true))
executor.refresh()
expect(cancellationCalls == cancelBefore + 1 && sends == 1, "명시 취소는 operation별 한 번이며 이후 readback 송신0")


executorContext.readback = nil
executor.refresh(); acceptFixtureCatalog()
executor.begin(heldFor: 0.5, issuedAt: date)
executorContext.readback = readyReadback(.init(playback: true, microphone: true)); executor.refresh()
let invokedControl = lastControl!
expect(invokedControl.operation == .invoke && sends == 2, "제품 executor는 공통 invoke envelope를 한 번 작성함")
executor.submitted(UUID())
expect(finishCalls == 1, "다른 requestId의 늦은 submitted가 현재 준비를 인계하지 않음")
let uncertain = try ConfiguredCraftActionState(control: invokedControl, deviceId: fixtureReadScope()!.device, error: "unavailable")
expect(executor.receive(try JSONEncoder().encode(uncertain), in: fixtureReadScope()!), "invoke 외부 error union을 수용함")
if case .unknown = executor.model.phase {} else { fatalError("외부 unavailable을 rejected로 승격했습니다") }
expect(executor.canQuery && sends == 2, "외부 error는 원 operation UNKNOWN이며 자동 invoke0")
executor.query()
let originalQuery = lastControl!
expect(originalQuery.operation == .query && originalQuery.operationId == invokedControl.client!.operationId && querySends == 1,
       "복구는 원 operationId의 read-only query만 전송함")
let unknownResult = try ConfiguredCraftActionResult(outcome: .unknown, operationId: originalQuery.operationId!,
    deviceId: fixtureReadScope()!.device, bindingSha256: nil, invoked: true)
let queryResponse = try ConfiguredCraftActionState(control: originalQuery, deviceId: fixtureReadScope()!.device, result: unknownResult)
expect(executor.receive(try JSONEncoder().encode(queryResponse), in: fixtureReadScope()!), "query의 unknown+invoked true/null을 원형 보존함")
executor.refresh()
expect(sends == 2 && querySends == 1, "unknown 결과 뒤 자동 invoke/query 반복0")
executorContext = changedScope(executorContext, connection: UUID())
executor.refresh()
let reconnectCatalog = lastControl!
let catalogUnavailable = try ConfiguredCraftActionState(control: reconnectCatalog, deviceId: fixtureReadScope()!.device, error: "unavailable")
_ = executor.receive(try JSONEncoder().encode(catalogUnavailable), in: fixtureReadScope()!)
executorContext.invocationAllowed = false
expect(executor.canQuery, "같은 인증 기기 reconnect 및 Sentry 미확인에서도 원 결과 query는 읽기 전용으로 허용함")
executor.query()
let reconnectQuery = lastControl!
expect(reconnectQuery.operation == .query && reconnectQuery.operationId == originalQuery.operationId && sends == 2,
       "reconnect는 이전 session echo·새 invoke 없이 같은 operation을 조회함")
let typedRejected = try ConfiguredCraftActionResult(outcome: .rejected, operationId: reconnectQuery.operationId!,
    deviceId: fixtureReadScope()!.device, bindingSha256: nil, invoked: false)
let typedState = try ConfiguredCraftActionState(control: reconnectQuery, deviceId: fixtureReadScope()!.device, result: typedRejected)
var wrongCorrelation = try JSONSerialization.jsonObject(with: JSONEncoder().encode(typedState)) as! [String: Any]
wrongCorrelation["requestId"] = UUID().uuidString.lowercased()
expect(!executor.receive(try JSONSerialization.data(withJSONObject: wrongCorrelation), in: fixtureReadScope()!),
       "다른 requestId 응답은 현재 query를 완료하지 않음")
expect(!executor.receive(try JSONEncoder().encode(typedState), in: fixtureReadScope()!), "이미 확인한 인계를 query rejected로 낮추지 않음")
if case .completed(_, let saved) = executor.model.phase { expect(saved == unknownResult, "원 unknown invoked true를 보존함") }
else { fatalError("typed query result missing") }
let confirmedQueryResult = try ConfiguredCraftActionResult(outcome: .invoked, operationId: reconnectQuery.operationId!,
    deviceId: fixtureReadScope()!.device, bindingSha256: nil, invoked: true)
let confirmedQueryState = try ConfiguredCraftActionState(control: reconnectQuery,
    deviceId: fixtureReadScope()!.device, result: confirmedQueryResult)
expect(executor.receive(try JSONEncoder().encode(confirmedQueryState), in: fixtureReadScope()!), "원 기한 안의 더 확실한 원 operation 결과를 수용함")
expect(!executor.canQuery && sends == 2, "terminal 결과의 읽기가 자동 재토글을 만들지 않음")
let catalogControl = ConfiguredCraftActionControl(requestId: UUID())
let catalogEnvelope = try ConfiguredCraftActionState(control: catalogControl, deviceId: fixtureReadScope()!.device,
    catalog: .init(expectedProfileId: profile, expectedAssignmentSha256: assignment))
for key in ["deviceSessionId", "settingsSha256"] {
    var extra = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalogEnvelope)) as! [String: Any]
    var nested = extra["catalog"] as! [String: Any]; nested[key] = "unexpected"; extra["catalog"] = nested
    expect((try? ConfiguredCraftActionState.decode(JSONSerialization.data(withJSONObject: extra))) == nil,
           "현재 실제 공통 raw codec도 Catalog exact6 추가 키 반례를 거절함")
}


var pendingLoss = Action()
var live = context
live.selection = .init(playback: true, microphone: true)
live.readback = readyReadback(live.selection!)
let liveOperation = invocation(begin(&pendingLoss, live))
_ = pendingLoss.takeInvocation(liveOperation, context: live, now: 100)
live.readback = nil
expect(pendingLoss.advance(context: live, now: 101) == .cancelPreparation(liveOperation),
       "writer 대기 중 fresh 준비 상실은 같은 operation의 큐 취소 directive를 반환함")
if case .unknown(let saved) = pendingLoss.phase { expect(saved == liveOperation, "미디어 소실 뒤 원 operation UNKNOWN 보존") }
else { fatalError("pending media loss unknown missing") }
expect(pendingLoss.advance(context: context, now: 102) == nil, "늦은 mediaReady 복귀는 자동 invoke를 만들지 않음")


for (outcome, invoked) in [(Action.Result.Outcome.invoked, false), (.rejected, true)] {
    for query in [false, true] {
        var now = 100.0
        var localContext = Action.Context(hostKey: "trusted-host", scope: scope,
            selection: .init(), readback: readyReadback(.init()))
        let readScope = VisionConfiguredCraftActionExecutor.ReadScope(hostKey: "trusted-host",
            connection: scope.connection, window: scope.window, admission: scope.admission,
            foreground: scope.foreground, video: scope.video,
            device: AudioForwardingDeviceID(hex: binding.deviceId)!)
        var control: ConfiguredCraftActionControl?
        var invokeCount = 0, finishes = 0, pendingRemovals = 0
        localContext.admitted = true
        let receiver = VisionConfiguredCraftActionExecutor(context: { localContext }, readScope: { readScope },
            prepare: { _ in fatalError("confirmed OFF requires no preparation") },
            cancelPreparation: { _ in }, finishPreparation: { _ in finishes += 1 },
            send: { value, _, _ in control = value; if value.operation == .invoke { invokeCount += 1 }; return true },
            cancelSend: { _ in pendingRemovals += 1 }, clock: { now })
        receiver.observe(capability: 1)
        let catalogState = try ConfiguredCraftActionState(control: control!, deviceId: readScope.device,
            catalog: .init(expectedProfileId: profile, expectedAssignmentSha256: assignment))
        expect(receiver.receive(try JSONEncoder().encode(catalogState), in: readScope), "반례 fixture의 현재 catalog를 수용함")
        receiver.begin(heldFor: 0.5, issuedAt: date)
        let operationId = control!.client!.operationId
        if query { now = 110; receiver.refresh(); receiver.query() }
        let pendingControl = control!, originalPhase = receiver.model.phase
        let beforeRemovals = pendingRemovals, beforeFinishes = finishes
        now = query ? 119.8 : 109.8
        let contradiction = try ConfiguredCraftActionState(control: pendingControl, deviceId: readScope.device,
            result: .init(outcome: outcome, operationId: operationId, deviceId: readScope.device,
                          bindingSha256: nil, invoked: invoked))
        let malformed = try JSONEncoder().encode(contradiction)
        expect((try? ConfiguredCraftActionState.decode(malformed)) != nil, "현재 raw codec가 허용하는 의미 모순을 모델 경계에서 검사함")
        let accepted = receiver.receive(malformed, in: readScope)
        expect(!accepted, "\(query ? "query" : "invoke") \(outcome)/\(invoked) 모순 응답을 거절함; 관측=\(accepted)")
        expect(receiver.model.phase == originalPhase && pendingRemovals == beforeRemovals && finishes == beforeFinishes,
               "모델 거절은 원 pending·기한·준비 소유권을 바꾸지 않음")
        now += 0.1
        let normal = try ConfiguredCraftActionState(control: pendingControl, deviceId: readScope.device,
            result: .init(outcome: .invoked, operationId: operationId, deviceId: readScope.device,
                          bindingSha256: assignment, invoked: true))
        expect(receiver.receive(try JSONEncoder().encode(normal), in: readScope), "같은 요청의 원기한 내 정상 결과를 뒤이어 수용함")
        if case .completed(_, let saved) = receiver.model.phase {
            expect(saved.outcome == .invoked && saved.invoked, "정상 결과를 보존함")
        } else { fatalError("correct response discarded after contradiction") }
        now += 20; receiver.refresh()
        expect(invokeCount == 1 && !receiver.canQuery, "모순 뒤 정상 수용은 UNKNOWN·자동 재호출로 바뀌지 않음")
    }
}


for query in [false, true] {
    var now = 100.0
    var control: ConfiguredCraftActionControl?
    var invokes = 0, removals = 0
    let c = Action.Context(hostKey: "trusted-host", scope: scope, admitted: true,
        selection: .init(), readback: readyReadback(.init()))
    let readScope = VisionConfiguredCraftActionExecutor.ReadScope(hostKey: "trusted-host",
        connection: scope.connection, window: scope.window, admission: scope.admission,
        foreground: scope.foreground, video: scope.video, device: AudioForwardingDeviceID(hex: binding.deviceId)!)
    let receiver = VisionConfiguredCraftActionExecutor(context: { c }, readScope: { readScope },
        prepare: { _ in fatalError("confirmed OFF requires no preparation") }, cancelPreparation: { _ in },
        finishPreparation: { _ in }, send: { value, _, _ in control = value; if value.operation == .invoke { invokes += 1 }; return true },
        cancelSend: { _ in removals += 1 }, clock: { now })
    receiver.observe(capability: 1)
    let catalog = try ConfiguredCraftActionState(control: control!, deviceId: readScope.device,
        catalog: .init(expectedProfileId: profile, expectedAssignmentSha256: assignment))
    _ = receiver.receive(try JSONEncoder().encode(catalog), in: readScope)
    receiver.begin(heldFor: 0.5, issuedAt: date)
    let id = control!.client!.operationId
    if query { now = 110; receiver.refresh(); receiver.query() }
    let request = control!, originalDeadline = query ? 120.0 : 110.0
    let bad = try ConfiguredCraftActionState(control: request, deviceId: readScope.device,
        result: .init(outcome: .invoked, operationId: id, deviceId: readScope.device, bindingSha256: nil, invoked: false))
    now = originalDeadline - 0.1
    expect(!receiver.receive(try JSONEncoder().encode(bad), in: readScope), "기한 직전 모순 응답을 거절함")
    let beforeExpiry = removals
    let good = try ConfiguredCraftActionState(control: request, deviceId: readScope.device,
        result: .init(outcome: .invoked, operationId: id, deviceId: readScope.device, bindingSha256: assignment, invoked: true))
    now = originalDeadline
    expect(!receiver.receive(try JSONEncoder().encode(good), in: readScope), "모순 응답 뒤에도 원 기한에 도달한 정상 결과는 수용하지 않음")
    receiver.refresh()
    expect(removals == beforeExpiry + 1 && invokes == 1 && receiver.canQuery,
           "원 deadline에서 pending 한 번 정리·UNKNOWN 유지·자동 invoke0")
}

let reasonBase = try ConfiguredCraftActionState(control: originalQuery, deviceId: fixtureReadScope()!.device,
    result: .init(outcome: .unknown, operationId: originalQuery.operationId!, deviceId: fixtureReadScope()!.device,
                  bindingSha256: nil, invoked: false))
let reasonObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reasonBase)) as! [String: Any]
func rawReason(_ text: String) throws -> Data {
    var object = reasonObject
    var result = object["result"] as! [String: Any]; result["reason"] = text; object["result"] = result
    return try JSONSerialization.data(withJSONObject: object)
}
for text in ["action-executor-failed", " \t권한-거절\n", String(repeating: "가", count: 85) + "a", String(repeating: "🙂", count: 64)] {
    let decoded = try ConfiguredCraftActionState.decode(rawReason(text))
    expect(decoded.result?.reason == text && Array(decoded.result!.reason!.utf8) == Array(text.utf8),
           "nested reason은 하이픈·공백 포함 원문과 UTF8 256bytes 경계를 보존함")
}
for text in ["", " \t\n", String(repeating: "가", count: 85) + "ab", String(repeating: "🙂", count: 65)] {
    expect((try? ConfiguredCraftActionState.decode(rawReason(text))) == nil,
           "nested reason은 빈 값·공백뿐인 값·UTF8 256bytes 초과를 거절함")
}
for error in ["action-executor-failed", "상태_미확인", "  unavailable  "] {
    expect((try? ConfiguredCraftActionState(control: originalQuery, deviceId: fixtureReadScope()!.device, error: error)) == nil,
           "outer error의 stable underscore 규칙은 확장하지 않음")
}
let rawNumeric = String(data: try JSONEncoder().encode(reasonBase), encoding: .utf8)!
for replacement in ["1.0", "1e0", "true"] {
    let malformed = rawNumeric.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":" + replacement)
    expect((try? ConfiguredCraftActionState.decode(Data(malformed.utf8))) == nil,
           "실제 state raw decoder는 분수·지수·boolean 숫자 별칭을 거절함")
}

func knownQueryResult(invoked: Bool) -> (Action, Action.Operation, Action.Context) {
    var current = Action.Context(hostKey: "trusted-host", scope: scope, binding: binding,
        routeGeneration: UUID(), capabilityPresent: true, routeImplemented: true, admitted: true)
    current.readback = readyReadback(.init(playback: true, microphone: true))
    var action = Action()
    _ = action.begin(heldFor: 0.5, context: current, now: 100, issuedAt: date, operationId: UUID.init)
    _ = action.advance(context: current, now: 101)
    guard let operation = action.operation else { fatalError("query fixture operation missing") }
    expect(action.takeInvocation(operation, context: current, now: 102) != nil, "조회 보존 대조군을 한 번 제출함")
    let known = try! Action.Result(outcome: .unknown, operationId: operation.request.operationId,
        deviceId: AudioForwardingDeviceID(hex: binding.deviceId)!, bindingSha256: assignment,
        invoked: invoked, reason: "executor-submitted-result-unknown")
    expect(action.receive(known, context: current, now: 103), "기존 원 operation의 미확인 결과를 수용함")
    return (action, operation, current)
}
for knownInvoked in [false, true] {
    var (action, operation, current) = knownQueryResult(invoked: knownInvoked)
    let weak = try Action.Result(outcome: .unknown, operationId: operation.request.operationId,
        deviceId: AudioForwardingDeviceID(hex: binding.deviceId)!, bindingSha256: nil, invoked: false)
    expect(action.receiveReadback(weak, hostKey: current.fence!.hostKey,
        device: AudioForwardingDeviceID(hex: binding.deviceId)!), "같은 operation의 조회 응답을 처리함")
    guard case .completed(_, let saved) = action.phase else { fatalError("known query result missing") }
    expect(saved.invoked == knownInvoked && saved.bindingSha256 == assignment &&
        saved.reason == "executor-submitted-result-unknown", "약한 조회가 기존 실행 인계·binding·reason을 지우지 않음")
}
var (knownInvokedAction, knownInvokedOperation, knownInvokedContext) = knownQueryResult(invoked: true)
let beforeRejectedQuery = knownInvokedAction.phase
let rejectedQuery = try Action.Result(outcome: .rejected, operationId: knownInvokedOperation.request.operationId,
    deviceId: AudioForwardingDeviceID(hex: binding.deviceId)!, bindingSha256: nil, invoked: false)
expect(!knownInvokedAction.receiveReadback(rejectedQuery, hostKey: knownInvokedContext.fence!.hostKey,
    device: AudioForwardingDeviceID(hex: binding.deviceId)!) && knownInvokedAction.phase == beforeRejectedQuery,
    "이미 확인한 인계를 rejected false로 낮추지 않음")
var (notInvokedAction, notInvokedOperation, notInvokedContext) = knownQueryResult(invoked: false)
let definiteRejection = try Action.Result(outcome: .rejected, operationId: notInvokedOperation.request.operationId,
    deviceId: AudioForwardingDeviceID(hex: binding.deviceId)!, bindingSha256: nil, invoked: false)
expect(notInvokedAction.receiveReadback(definiteRejection, hostKey: notInvokedContext.fence!.hostKey,
    device: AudioForwardingDeviceID(hex: binding.deviceId)!), "인계 확인이 없으면 원 operation의 확정 typed rejected로 복구함")
if case .completed(_, let saved) = notInvokedAction.phase {
    expect(saved.outcome == .rejected && !saved.invoked, "확정 거절을 UNKNOWN으로 무조건 숨기지 않음")
} else { fatalError("definite rejection missing") }

for stage in ["preparing", "ready", "awaiting"] {
    for change in ["capability", "sentryRevision"] {
        var current = Action.Context(hostKey: "trusted-host", scope: scope, binding: binding,
            routeGeneration: UUID(), capabilityPresent: true, routeImplemented: true, admitted: true)
        current.hostCapabilityVersion = 2; current.sentryRevision = UUID()
        if stage != "preparing" { current.readback = readyReadback(.init(playback: true, microphone: true)) }
        var receiver = Action()
        _ = receiver.begin(heldFor: 0.5, context: current, now: 100, issuedAt: date)
        let operation = receiver.operation!
        if stage == "awaiting" {
            expect(receiver.takeInvocation(operation, context: current, now: 100.1) != nil,
                "보호 권한 변경 전 동일 operation을 제출함")
        }
        if change == "capability" { current.hostCapabilityVersion = 1 }
        else { current.sentryRevision = UUID() }
        if case .cancelPreparation(let cancelled) = receiver.advance(context: current, now: 101) {
            expect(cancelled == operation, "지원 버전·센트리 revision 변경은 원 operation만 취소함")
        } else { fatalError("security revision change did not cancel") }
        expect(receiver.takeInvocation(operation, context: current, now: 101.1) == nil,
            "변경 뒤 늦은 준비 완료가 새 invoke를 내보내지 않음")
        if stage == "awaiting" {
            if case .unknown = receiver.phase {} else { fatalError("sent operation must stay unknown") }
        } else if case .cancelled = receiver.phase {} else { fatalError("unsent operation must cancel") }
    }
}

let capabilityReadScope = VisionConfiguredCraftActionExecutor.ReadScope(hostKey: "trusted-host",
    connection: scope.connection, window: scope.window, admission: scope.admission,
    foreground: scope.foreground, video: scope.video, device: AudioForwardingDeviceID(hex: binding.deviceId)!)
let capabilityExecutor = VisionConfiguredCraftActionExecutor(context: { context }, readScope: { capabilityReadScope },
    prepare: { _ in fatalError("catalog observation must not prepare media") }, cancelPreparation: { _ in },
    finishPreparation: { _ in }, send: { _, _, _ in true }, cancelSend: { _ in }, clock: { 100 })
capabilityExecutor.observe(capability: 2)
expect(capabilityExecutor.context.capabilityPresent && capabilityExecutor.context.hostCapabilityVersion == 2,
    "지원 버전2는 기존 catalog/조회 경로를 재사용함")
capabilityExecutor.observe(capability: 3)
expect(!capabilityExecutor.canBegin && !capabilityExecutor.canReadCatalog, "알 수 없는 지원 버전을 활성화하지 않음")

print("PASS \(checks) configured Craft action checks; actual Host/Core/device/media/input actions 0")
