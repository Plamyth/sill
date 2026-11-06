import Foundation
import StreamProtocol

let suite = "VisionCraftStore." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let store = VisionRemoteAudioStore(defaults: defaults)
let fixtureBinding = VisionConfiguredCraftAction.Binding(deviceId: String(repeating: "d", count: 64),
    profileId: UUID(), assignmentSha256: String(repeating: "a", count: 64))
let fixtureRoute = UUID()
var checks = 0
func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { fputs("FAIL actual Store " + message + "\n", stderr); exit(1) }
}
func operation(_ client: StreamClient) -> VisionConfiguredCraftAction.Operation {
    var model = VisionConfiguredCraftAction()
    guard case .prepare(let value) = model.begin(heldFor: 0.5, context: client.visionConfiguredCraftContext,
        now: 100, issuedAt: Date(timeIntervalSince1970: 1_793_900_000)) else { fatalError("prepare fixture missing") }
    return value
}
let a = StreamClient("craft-a")
store.register(a)
let first = operation(a)
let revision = store.prepareConfiguredAction(first, client: a)!
check(revision == a.visionConfiguredCraftContext.selectionRevision, "방향 revision 영수증 반환")
check(a.visionPlaybackDesired && a.visionMicrophoneDesired, "명시 선택 부재에서만 기본 두 방향을 저장")
check(a.nativeSelections == 1 && a.visionAudio.starts == 0 && a.microphoneStarts == 0,
      "기존 forwarding 준비를 사용하고 fresh capability ACK 전에는 캡처·재생0")
a.respondToQuery()
check(a.visionAudio.starts == 1 && a.microphoneStarts == 1, "실제 Store가 기존 playback/microphone 준비 메서드를 호출")
let stops = (a.visionAudio.stops, a.microphoneStops)
store.cancelConfiguredAction(first, client: a)
check(store.model.intent.desires["craft-a"] == nil, "준비 취소가 처음의 미선택 상태를 복원")
check(a.visionAudio.stops > stops.0 && a.microphoneStops > stops.1, "해당 준비의 두 로컬 역할 정리")
let next = operation(a)
let nextRevision = store.prepareConfiguredAction(next, client: a)!
store.cancelConfiguredAction(first, client: a)
check(a.visionPlaybackDesired && a.visionMicrophoneDesired && a.visionConfiguredCraftContext.selectionRevision == nextRevision,
      "이전 operation 늦은 취소는 새 준비를 보존")
_ = store.setDesired(false, client: a, direction: .microphone, expectedScope: nil)
let explicitRevision = store.model.intent.desiredRevision(.microphone, hostKey: "craft-a")
store.cancelConfiguredAction(next, client: a)
check(!a.visionPlaybackDesired && !a.visionMicrophoneDesired &&
      store.model.intent.desiredRevision(.microphone, hostKey: "craft-a") == explicitRevision,
      "사용자의 새 OFF/revision 보존, 준비가 만든 남은 방향만 회수")
let off = operation(a)
let before = (a.visionAudio.starts, a.microphoneStarts)
_ = store.prepareConfiguredAction(off, client: a)
store.cancelConfiguredAction(off, client: a)
check(before.0 == a.visionAudio.starts && before.1 == a.microphoneStarts,
      "명시 양쪽 OFF는 준비·취소가 ON이나 미디어 시작으로 바꾸지 않음")
let c = StreamClient("craft-c"), d = StreamClient("craft-c")
store.register(c); store.register(d)
let oldWindow = operation(c)
_ = store.prepareConfiguredAction(oldWindow, client: c)
_ = store.setDesired(true, client: d, direction: .playback, expectedScope: nil)
let otherStops = d.visionAudio.stops
store.cancelConfiguredAction(oldWindow, client: c)
check(d.visionPlaybackDesired && d.visionAudio.stops == otherStops,
      "다른 창의 새 명시 playback 선택과 자원을 늦은 취소가 정리하지 않음")
print("PASS \(checks) actual extracted Store preparation/cancellation checks; inert media/permission/network ports only")
