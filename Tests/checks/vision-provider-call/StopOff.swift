import Foundation
import StreamProtocol

var methodChecks = 0
func check(_ condition: Bool, _ label: String) {
    methodChecks += 1
    if !condition { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
final class NWConnection {}
final class StreamClient {
    var visionAudioIntentConnection = UUID()
    var visionAudioOwnerID = UUID()
    var connection: NWConnection? = NWConnection()
    var authenticatedVisionMacAudioPeer: ObjectIdentifier? { connection.map(ObjectIdentifier.init) }
    var visionAudioTrustedHostKey: String? = String(repeating: "c", count: 64)
    var visionProviderCall: VisionProviderCall
    var visionForwarding: VisionAudioForwarding?
    var visionAudioIntentContext = VisionRemoteAudioIntent.Context()
    var visionForwardingDesire = VisionRemoteAudioIntent.Desire()
    var sent: [ProviderCallControl] = []
    init(_ call: VisionProviderCall, _ forwarding: VisionAudioForwarding) {
        visionProviderCall = call; visionForwarding = forwarding
        visionAudioIntentContext.hostKey = visionAudioTrustedHostKey
        visionAudioIntentContext.scope = .init(connection: UUID(), window: UUID(), admission: UUID(),
            video: UUID(), foreground: UUID(), privacy: 1)
        visionAudioIntentContext.connected = true; visionAudioIntentContext.authenticated = true
        visionAudioIntentContext.foreground = true; visionAudioIntentContext.presented = true
        visionAudioIntentContext.inputBlocked = false; visionAudioIntentContext.privacyVersion = 2
        visionAudioIntentContext.cleanupReady = true
    }
    func sendVisionProviderCall(_ control: ProviderCallControl, to peer: NWConnection) { sent.append(control) }
    func scheduleVisionProviderQuery(_ peer: NWConnection) {}
}
final class VisionRemoteAudioStore {
    static let shared = VisionRemoteAudioStore()
    struct Model { var owner: UUID? }
    var model = Model()
}
var now = 100.0
let connection = UUID()
let device = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
let generation = UUID()
let configuration = try AudioForwardingConfiguration(controllerBootId: UUID(), privacyGeneration: UUID(),
    registryRevision: .init(1), members: [.init(participantId: "native.sill", bootId: UUID()),
        .init(participantId: "s23.audio.relay", bootId: UUID())])
func snapshot(_ request: AudioForwardingIntentRequest, revision: UInt64,
              phase: AudioForwardingBinding.Phase) throws -> AudioForwardingSnapshot {
    try .init(revision: .init(revision), intent: .init(pairedDeviceId: device, intentId: request.intentId,
        intentRevision: request.intentRevision, intentGeneration: generation,
        inputDesired: request.inputDesired, outputDesired: request.outputDesired),
        binding: .init(pairedDeviceId: device, intentGeneration: generation, bindingEpoch: UUID(),
            transportId: request.transportId, transportKind: .native, operationId: UUID(), phase: phase,
            configuration: configuration))
}
func observe(_ model: inout VisionAudioForwarding, _ value: AudioForwardingSnapshot) throws {
    let control = model.observe()!
    let catalog = try AudioForwardingCatalog(principal: .init(kind: .cable, id: device,
        authorizationGeneration: generation), role: .viewer, bootstrap: .init(credential:
            .init(pairedDeviceId: device, pairingGeneration: generation, credential: String(repeating: "a", count: 43)),
            ownCursor: .init(intentRevision: .init(1), bindingRevision: .init(1)), snapshot: value))
    model.receive(try .init(requestID: control.requestID, operation: .observe, catalog: catalog, result: nil), from: connection)
}
let original = try AudioForwardingIntentRequest(pairedDeviceId: device, intentId: UUID(), intentRevision: .init(1),
    action: .request, inputDesired: true, outputDesired: true, expectedRevision: .init(1),
    transportId: UUID(), transportKind: .native, bindingRevision: .init(1))
var forwarding = VisionAudioForwarding(connection: connection, device: device, clock: { now })
forwarding.select(.init())
try observe(&forwarding, snapshot(original, revision: 2, phase: .active))
let control = forwarding.next(desire: .init())!
let off = try snapshot(control.intent!, revision: 3, phase: .off)
forwarding.receive(try .init(requestID: control.requestID, operation: .submit, catalog: nil, result: .accepted(off)), from: connection)
check(forwarding.binding == nil && forwarding.submitted == nil, "양방향 OFF는 미디어 바인딩을 정리함")
let start = try ProviderCallRequest(requestId: UUID(), action: .start, expectedLeaseRevision: .init(2),
    pairedDeviceId: device, desiredInput: true, desiredOutput: true, callSessionId: nil)
var call = VisionProviderCall(connection: connection, target: .chatgptDots, clock: { now })
call.observe(connection: connection, capability: 1, hostKey: String(repeating: "c", count: 64))
_ = call.perform(start)
check(call.receive(try .init(request: start, result: .init(requestId: start.requestId, status: .started,
    reason: "fixture_started", callSessionId: "same-call")), from: connection), "기존 통화 시작 결과를 확인함")
let client = StreamClient(call, forwarding)
VisionRemoteAudioStore.shared.model.owner = client.visionAudioOwnerID
let validStop = try ProviderCallRequest(requestId: UUID(), action: .stop, expectedLeaseRevision: off.revision,
    pairedDeviceId: device, desiredInput: false, desiredOutput: false, callSessionId: "same-call")
check(validStop.matches(off), "Host는 최신 OFF 원장의 통화 종료를 허용함")
check(client.visionProviderCanStop, "양방향 OFF 뒤 기존 통화 종료 버튼이 활성화됨")
check(!client.visionProviderCanStart, "OFF 상태는 새 통화 시작을 허용하지 않음")
client.performVisionProviderCall(.stop)
client.performVisionProviderCall(.stop)
check(client.sent.count == 1 && client.sent[0].request.callSessionId == "same-call" &&
    client.sent[0].request.matches(off), "정확한 통화와 최신 원장으로 종료를 한 번 보냄")
check(!client.sent[0].request.desiredInput && !client.sent[0].request.desiredOutput &&
    !client.visionForwarding!.permits(.microphone) && !client.visionForwarding!.permits(.playback), "종료는 음성 입출력을 다시 켜지 않음")
let expired = StreamClient(call, forwarding)
let blocked = StreamClient(call, forwarding)
VisionRemoteAudioStore.shared.model.owner = blocked.visionAudioOwnerID
blocked.visionAudioIntentContext.inputBlocked = true
check(!blocked.visionProviderCanStop, "차단된 화면은 OFF 상태에서도 종료 권한을 얻지 않음")
blocked.performVisionProviderCall(.stop)
check(blocked.sent.isEmpty, "차단된 화면은 종료를 송신하지 않음")
var changing = forwarding
changing.select(.init(playback: true, microphone: true))
let switching = StreamClient(call, changing)
VisionRemoteAudioStore.shared.model.owner = switching.visionAudioOwnerID
check(!switching.visionProviderCanStop, "새 음성 선택 중 이전 OFF 원장을 사용하지 않음")
switching.performVisionProviderCall(.stop)
check(switching.sent.isEmpty, "대상 전환 중 종료를 송신하지 않음")
var suspended = forwarding
suspended.suspend()
check(StreamClient(call, suspended).visionProviderCanStop == false, "중단된 연결은 OFF 원장을 재사용하지 않음")
VisionRemoteAudioStore.shared.model.owner = expired.visionAudioOwnerID
now += VisionAudioForwarding.freshness
check(!expired.visionProviderCanStop, "오래된 OFF 원장은 종료를 허용하지 않음")
expired.performVisionProviderCall(.stop)
check(expired.sent.isEmpty, "오래된 원장은 실제 송신도 차단함")
print("PASS: 실제 Vision 통화 버튼·송신 메서드의 양방향 OFF 종료 회귀; 네트워크·통화·오디오 효과 0")

// The Core target producer is absent. These checks consume its exact data shape only.
import CryptoKit
let tuple = ["ccr-codex-realtime-target-v1", "codex-app-server",
    "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"]
let hash = SHA256.hash(data: try JSONSerialization.data(withJSONObject: tuple, options: [.withoutEscapingSlashes]))
    .map { String(format: "%02x", $0) }.joined()
var object = Dictionary(uniqueKeysWithValues: zip(
    ["schema", "providerKind", "providerInstanceId", "threadId", "voiceSessionId"], tuple))
object["targetHash"] = hash
func target(_ fields: [String: String]) throws -> CodexRealtimePreparedTarget {
    try JSONDecoder().decode(CodexRealtimePreparedTarget.self,
        from: JSONSerialization.data(withJSONObject: fields))
}
let exact = try target(object)
check(hash == "bbbeec5e117c5c78893bd7e0500dcf17276f3f553b23a509f64450ec1781e7a5", "별도 Python UTF8 JSON 해시 벡터와 일치함")
let exactHash = try exact.hash()
check(exact.voiceSessionId == tuple[4] && exactHash == hash, "native UUID 문자 대소문자를 보존함")
for (key, value) in [("extra", "x"), ("providerKind", "chatgpt-dots-webguest"),
    ("targetHash", hash.uppercased()), ("voiceSessionId", tuple[4].lowercased()), ("threadId", "not-a-uuid")] {
    var invalid = object; invalid[key] = value
    check((try? target(invalid)) == nil, "다른 키·주체·해시·식별자를 거절함")
}
var context = client.visionAudioIntentContext
context.scope = .init(connection: connection, window: UUID(), admission: UUID(), video: UUID(), foreground: UUID(), privacy: 1)
context.protected = true
let core = UUID()
let hostKey = String(repeating: "c", count: 64)
func fence(_ c: VisionRemoteAudioIntent.Context, _ snapshot: AudioForwardingSnapshot = off,
           coreGeneration: UUID = core, owner: Bool = true) -> VisionNativePreparedCall.Fence? {
    .init(connection: connection, context: c, snapshot: snapshot, device: device,
          coreGeneration: coreGeneration, ownsAudio: owner)
}
let originalFence = fence(context)!
let preparation = VisionNativePreparedCall(target: exact, challengeTargetHash: hash,
    coreGeneration: core, fence: originalFence, observedAt: 100, expiresAt: 103)!
check(preparation.isCurrent(originalFence, now: 102.99), "현재 소유 창·native 원장·Core 세대에서만 준비 관측을 소비함")
check(!preparation.isCurrent(originalFence, now: 103) && !preparation.isCurrent(originalFence, now: 99), "기한 경계와 역행 시각을 거절함")
check(VisionNativePreparedCall(target: exact, challengeTargetHash: String(repeating: "0", count: 64),
    coreGeneration: core, fence: originalFence, observedAt: 100, expiresAt: 103) == nil, "외부 challenge 해시 불일치를 거절함")
check(VisionNativePreparedCall(target: exact, challengeTargetHash: hash,
    coreGeneration: UUID(), fence: originalFence, observedAt: 100, expiresAt: 103) == nil, "Core 세대 불일치를 거절함")
check(VisionNativePreparedCall(target: exact, challengeTargetHash: hash,
    coreGeneration: core, fence: originalFence, observedAt: 100, expiresAt: 104) == nil, "포워딩 3초보다 긴 준비 권한을 만들지 않음")
var otherWindow = context
otherWindow.scope = .init(connection: connection, window: UUID(), admission: UUID(), video: UUID(), foreground: UUID(), privacy: 1)
check(!preparation.isCurrent(fence(otherWindow)!, now: 101), "다른 창은 준비 대상을 가로채지 못함")
check(!preparation.isCurrent(fence(context, coreGeneration: UUID())!, now: 101), "새 Core 세대에 준비 대상을 재사용하지 않음")
check(fence(context, owner: false) == nil, "오디오 소유권 반납 뒤 준비 대상을 소비하지 않음")
var unprotected = context; unprotected.protected = false
check(fence(unprotected) == nil, "실제 미디어 보호 확인 없이 준비 대상을 소비하지 않음")
var hidden = context; hidden.presented = false
check(fence(hidden) == nil, "닫힌 창은 준비 대상을 소비하지 않음")
now = 101
var native = VisionProviderCall(connection: connection, clock: { now })
native.observe(connection: connection, capability: 1, hostKey: hostKey)
check(native.consumeNativePreparation(preparation, fence: originalFence), "native 준비 모델의 실제 소비 경로")
check(!native.canPerform && native.perform(start) == nil, "대상 지정 wire producer 없이 Dots 실행기로 native 명령을 보내지 않음")
check(!native.consumeNativePreparation(preparation, fence: fence(otherWindow)!), "창 전환은 이전 준비 대상을 폐기함")
check(native.nativePreparation == nil, "실패한 소비가 이전 권한을 남기지 않음")
_ = native.consumeNativePreparation(preparation, fence: originalFence)
native.disconnected()
check(native.nativePreparation == nil, "peer 교체는 준비 대상을 폐기함")
let nativeResult = try ProviderCallResult(requestId: start.requestId, status: .started,
    reason: "fixture_started", callSessionId: tuple[4], provider: "codex-app-server")
check(nativeResult.mediaProtection == "not_attested", "native 결과로 미디어 보호를 성공 처리하지 않음")
var dots = VisionProviderCall(connection: connection, target: .chatgptDots, clock: { now })
dots.observe(connection: connection, capability: 1, hostKey: hostKey)
_ = dots.perform(start)
check(!dots.receive(try .init(request: start, result: nativeResult), from: connection), "Dots 요청에 native 성공 결과를 혼합하지 않음")
print("PASS: native exact target/hash/provider/freshness/window/owner/Core 소비 회귀. 실제 연결·미디어 효과 0")

var preparedCall = VisionProviderCall(connection: connection, clock: { now })
preparedCall.observe(connection: connection, capability: 1, hostKey: hostKey)
let consumer = StreamClient(preparedCall, forwarding)
consumer.visionAudioIntentConnection = connection
consumer.visionAudioIntentContext = context
VisionRemoteAudioStore.shared.model.owner = consumer.visionAudioOwnerID
let targetData = try JSONSerialization.data(withJSONObject: object)
check(consumer.consumeVisionNativePreparedTarget(targetData, challengeTargetHash: hash,
    coreGeneration: core, currentCoreGeneration: core, observedAt: 100, expiresAt: 103,
    from: consumer.connection!), "production 소비 메서드가 현재 peer와 창·owner에 준비 대상을 결속함")
check(consumer.visionProviderCall.nativePreparation?.target == exact, "production 소비 결과가 정확한 native 대상을 보존함")
check(!consumer.consumeVisionNativePreparedTarget(targetData, challengeTargetHash: hash,
    coreGeneration: core, currentCoreGeneration: core, observedAt: 100, expiresAt: 103,
    from: NWConnection()), "다른 peer의 producer 응답을 거절함")
check(consumer.visionProviderCall.nativePreparation == nil, "잘못된 peer 관측은 이전 준비 대상도 폐기함")
VisionRemoteAudioStore.shared.model.owner = UUID()
check(!consumer.consumeVisionNativePreparedTarget(targetData, challengeTargetHash: hash,
    coreGeneration: core, currentCoreGeneration: core, observedAt: 100, expiresAt: 103,
    from: consumer.connection!), "production 소비도 다른 창의 오디오 소유권을 가로채지 않음")
let revised = try AudioForwardingSnapshot(revision: .init(4), intent: off.intent, binding: off.binding)
check(!preparation.isCurrent(fence(context, revised)!, now: 101), "원장 revision 변경은 준비 대상을 무효화함")
let changedBinding = try AudioForwardingBinding(pairedDeviceId: device, intentGeneration: generation,
    bindingEpoch: UUID(), transportId: off.binding!.transportId, transportKind: .native,
    operationId: off.binding!.operationId, phase: .off, configuration: configuration)
let changedEpoch = try AudioForwardingSnapshot(revision: off.revision, intent: off.intent, binding: changedBinding)
check(!preparation.isCurrent(fence(context, changedEpoch)!, now: 101), "같은 revision의 binding epoch 변경도 준비 대상을 무효화함")
print("PASS: production native 소비 메서드·peer·owner·revision·binding epoch 회귀")

now = 101
var nativeControlCall = VisionProviderCall(connection: connection, clock: { now })
nativeControlCall.observe(connection: connection, capability: 1, hostKey: hostKey, providerCallKinds: ["codex-app-server"])
_ = nativeControlCall.perform(start)
check(nativeControlCall.receive(try .init(request: start, result: nativeResult), from: connection), "native 시작의 동일 selector 응답")
let nativeClient = StreamClient(nativeControlCall, forwarding)
VisionRemoteAudioStore.shared.model.owner = nativeClient.visionAudioOwnerID
check(nativeClient.visionProviderCanStop, "native도 최신 OFF 원장에서 종료 가능함")
nativeClient.performVisionProviderCall(.stop)
check(nativeClient.sent.count == 1 && nativeClient.sent[0].providerKind == .nativeCodex &&
    nativeClient.sent[0].request.callSessionId == tuple[4] && nativeClient.sent[0].request.matches(off), "native 종료는 실제 세션과 OFF 원장을 보존함")
let wrongOwner = StreamClient(nativeControlCall, forwarding)
check(!wrongOwner.visionProviderCanStop, "다른 창 소유자는 native 종료 불가")
wrongOwner.performVisionProviderCall(.stop)
check(wrongOwner.sent.isEmpty, "다른 창은 native 종료 전송 불가")
let nativeExpired = StreamClient(nativeControlCall, forwarding)
VisionRemoteAudioStore.shared.model.owner = nativeExpired.visionAudioOwnerID
now = 104
check(!nativeExpired.visionProviderCanStop, "오래된 원장은 native 종료 불가")
nativeExpired.performVisionProviderCall(.stop)
check(nativeExpired.sent.isEmpty, "오래된 원장으로 native 전송 없음")
print("PASS: native selector의 실제 종료 메서드와 소유권·최신성 회귀. 외부 효과 0")

let catalogClient = StreamClient(VisionProviderCall(connection: connection, clock: { now }), forwarding)
catalogClient.visionAudioIntentConnection = connection
var advertised = WindowList(macName: "격리 Mac", windows: [], active: .none)
advertised.providerCalls = 1
advertised.providerCallKinds = [ProviderCallKind.nativeCodex.rawValue]
let decodedCatalog = try JSONDecoder().decode(WindowList.self, from: JSONEncoder().encode(advertised))
catalogClient.observeVisionProviderCalls(decodedCatalog, from: catalogClient.connection!)
check(catalogClient.visionProviderCall.nativeSupported, "실제 catalog 관측 메서드가 native 지원 종류를 소비함")
advertised.providerCallKinds = nil
catalogClient.observeVisionProviderCalls(advertised, from: NWConnection())
check(catalogClient.visionProviderCall.nativeSupported, "다른 peer의 목록은 native 지원을 바꾸지 않음")
catalogClient.observeVisionProviderCalls(advertised, from: catalogClient.connection!)
check(!catalogClient.visionProviderCall.nativeSupported, "현재 peer가 명시적 지원을 철회하면 native 실행도 차단함")
print("PASS: 실제 catalog codec·peer·native capability 연결 회귀. 외부 효과 0")
for kind in [ProviderCallKind.nativeCodex, .chatgptDots] {
    for status in [ProviderCallResult.Status.failed, .unsupported, .unknown] {
        now = 101
        let target: VisionCallTarget = kind == .nativeCodex ? .nativeCodex : .chatgptDots
        var owned = VisionProviderCall(connection: connection, target: target, clock: { now })
        owned.observe(connection: connection, capability: 1, hostKey: hostKey, providerCallKinds: [kind.rawValue])
        _ = owned.perform(start)
        check(owned.receive(try .init(request: start, result: .init(requestId: start.requestId, status: .started,
            reason: "fixture_started", callSessionId: "owned-session", provider: kind.rawValue)), from: connection), "활성 통화 시작")
        let client = StreamClient(owned, forwarding)
        client.visionAudioIntentConnection = connection
        VisionRemoteAudioStore.shared.model.owner = client.visionAudioOwnerID
        client.performVisionProviderCall(.stop)
        check(client.sent.count == 1, "실제 종료 메서드의 첫 수동 요청")
        let firstStop = client.sent[0].request
        check(client.visionProviderCall.receive(try .init(request: firstStop, result: .init(requestId: firstStop.requestId,
            status: status, reason: "provider_not_dispatched", provider: kind.rawValue)), from: connection), "종료 명령의 실패·미지원·불명확 결과")
        check(!client.visionProviderCall.canChangeTarget && !client.visionProviderCall.selectTarget(.grok),
            "P2-1 종료 실패 뒤 살아 있는 통화의 대상 소유권을 유지함")
        check(client.visionProviderCanStop && !client.visionProviderCanStart,
            "종료 실패 뒤 같은 세션의 수동 종료만 가능함")
        check(client.sent.count == 1, "결과 수신만으로 종료를 자동 재시도하지 않음")
        check(client.visionProviderCall.activeCall?.callSessionId == "owned-session" &&
            client.visionProviderCall.result?.status == status, "활성 통화와 현재 명령 결과를 분리함")
        check(client.visionProviderCall.perform(start) == nil, "활성 통화가 있으면 같은 provider의 새 시작도 차단함")
        let wrongSessionStop = try ProviderCallRequest(requestId: UUID(), action: .stop,
            expectedLeaseRevision: off.revision, pairedDeviceId: device,
            desiredInput: false, desiredOutput: false, callSessionId: "other-session")
        check(client.visionProviderCall.perform(wrongSessionStop) == nil && client.visionProviderCall.pending == nil,
            "잘못된 세션의 수동 종료도 거절함")
        now = 104
        client.performVisionProviderCall(.stop)
        check(client.sent.count == 1 && !client.visionProviderCanStop, "오래된 원장은 종료 재요청을 차단함")
        var refreshed = forwarding
        try observe(&refreshed, off)
        client.visionForwarding = refreshed

        VisionRemoteAudioStore.shared.model.owner = UUID()
        client.performVisionProviderCall(.stop)
        check(client.sent.count == 1, "다른 오디오 소유자는 종료를 재요청할 수 없음")
        VisionRemoteAudioStore.shared.model.owner = client.visionAudioOwnerID
        client.visionAudioIntentContext.inputBlocked = true
        client.performVisionProviderCall(.stop)
        check(client.sent.count == 1, "차단된 화면은 종료를 재요청할 수 없음")
        client.visionAudioIntentContext.inputBlocked = false
        client.performVisionProviderCall(.stop)
        check(client.sent.count == 2 && client.sent[1].providerKind == kind &&
            client.sent[1].request.requestId != firstStop.requestId &&
            client.sent[1].request.callSessionId == "owned-session" && client.sent[1].request.matches(off),
            "명시적인 재요청은 동일 selector·세션과 최신 원장을 보존함")
        let retry = client.sent[1].request
        check(!client.visionProviderCall.receive(try .init(request: retry, result: .init(requestId: retry.requestId,
            status: .stopped, reason: "fixture_stopped", provider: kind.rawValue)), from: connection),
            "세션이 없는 stopped도 소유권을 해제하지 않음")
        check(!client.visionProviderCall.receive(try .init(request: retry, result: .init(requestId: retry.requestId,
            status: .stopped, reason: "fixture_stopped", callSessionId: "other-session", provider: kind.rawValue)), from: connection),
            "다른 세션의 stopped는 소유권을 해제하지 않음")
        check(!client.visionProviderCall.receive(try .init(request: retry, result: .init(requestId: retry.requestId,
            status: .stopped, reason: "fixture_stopped", callSessionId: "owned-session",
            provider: kind == .nativeCodex ? ProviderCallKind.chatgptDots.rawValue : ProviderCallKind.nativeCodex.rawValue)), from: connection),
            "다른 selector의 stopped는 소유권을 해제하지 않음")
        check(client.visionProviderCall.receive(try .init(request: retry, result: .init(requestId: retry.requestId,
            status: .stopped, reason: "fixture_stopped", callSessionId: "owned-session", provider: kind.rawValue)), from: connection),
            "같은 세션·selector의 확인된 stopped만 수용함")
        check(client.visionProviderCall.canChangeTarget && !client.visionProviderCanStop && client.visionProviderCall.selectTarget(.grok),
            "확인된 종료 뒤에만 활성 통화 소유권을 해제함")
    }
}
print("PASS: 실제 Vision 메서드의 실패 종료 복구·대상 잠금·동일 세션 종료 회귀")

for kind in [ProviderCallKind.nativeCodex, .chatgptDots] {
    for interruption in ["timeout", "disconnect"] {
        now = 101
        var call = VisionProviderCall(connection: connection,
            target: kind == .nativeCodex ? .nativeCodex : .chatgptDots, clock: { now })
        call.observe(connection: connection, capability: 1, hostKey: hostKey, providerCallKinds: [kind.rawValue])
        _ = call.perform(start)
        _ = call.receive(try .init(request: start, result: .init(requestId: start.requestId,
            status: .started, reason: "fixture_started", callSessionId: "retained-session", provider: kind.rawValue)), from: connection)
        let client = StreamClient(call, forwarding)
        client.visionAudioIntentConnection = connection
        VisionRemoteAudioStore.shared.model.owner = client.visionAudioOwnerID
        client.performVisionProviderCall(.stop)
        let originalStop = client.sent[0].request
        let pending = client.visionProviderCall.pending!
        if interruption == "timeout" {
            now = pending.expiresAt
            check(client.visionProviderCall.timeout(pending), "종료 timeout을 현재 명령에 적용함")
        } else {
            client.visionProviderCall.disconnected()
        }
        check(client.visionProviderCall.activeCall?.callSessionId == "retained-session" &&
            !client.visionProviderCall.canChangeTarget && !client.visionProviderCanStart,
            "timeout·disconnect는 확인된 통화 소유권을 지우지 않음")
        client.performVisionProviderCall(.stop)
        check(client.sent.count == 1, "재인증 전에는 새 종료 요청이 없음")
        client.visionAudioTrustedHostKey = String(repeating: "e", count: 64)
        client.visionProviderCall.observe(connection: connection, capability: 1,
            hostKey: client.visionAudioTrustedHostKey, providerCallKinds: [kind.rawValue])
        check(client.visionProviderCall.activeCall?.callSessionId == "retained-session" &&
            !client.visionProviderCanStop && client.visionProviderCall.hostKey == hostKey,
            "다른 Host는 살아 있는 통화를 지우거나 종료 경로를 가로채지 못함")
        client.visionAudioTrustedHostKey = hostKey
        client.visionProviderCall.observe(connection: connection, capability: 1, hostKey: hostKey,
            providerCallKinds: [kind.rawValue])
        if interruption == "disconnect" {
            now += 0.5
            let query = client.visionProviderCall.query()!
            check(query.request == originalStop && query.providerKind == kind && client.visionProviderCall.firstSentAt == 101,
                "disconnect 뒤 조회는 원래 종료 요청과 selector·예산을 보존함")
            _ = client.visionProviderCall.receive(try .init(request: originalStop, result: .init(requestId: originalStop.requestId,
                status: .unknown, reason: "fixture_unknown", provider: kind.rawValue)), from: connection)
        } else {
            check(client.visionProviderCall.query() == nil && client.visionProviderCall.firstSentAt == 101,
                "timeout 뒤 조회 예산을 임의 갱신하지 않음")
        }
        var fresh = forwarding
        try observe(&fresh, off)
        client.visionForwarding = fresh
        check(client.visionProviderCanStop && !client.visionProviderCanStart, "같은 Host와 최신 오디오 원장에서는 수동 종료 복구 가능")
        client.performVisionProviderCall(.stop)
        check(client.sent.count == 2 && client.sent[1].request.callSessionId == "retained-session" &&
            client.sent[1].providerKind == kind, "timeout·disconnect 뒤에도 명시적 수동 종료는 동일 세션을 사용함")
        let stop = client.sent[1].request
        check(client.visionProviderCall.receive(try .init(request: stop, result: .init(requestId: stop.requestId,
            status: .stopped, reason: "fixture_stopped", callSessionId: "retained-session", provider: kind.rawValue)), from: connection),
            "timeout·disconnect 뒤 같은 세션의 정상 종료를 수용함")
        check(client.visionProviderCall.activeCall == nil && client.visionProviderCall.canChangeTarget,
            "복구 종료가 확인된 뒤 활성 소유권을 해제함")
    }
}
print("PASS ACTUAL_METHOD_CHECKS \(methodChecks); 실제 Host·기기·음성 효과 0")
