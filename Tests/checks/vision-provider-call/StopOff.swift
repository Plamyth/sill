import Foundation
import StreamProtocol

func check(_ condition: Bool, _ label: String) {
    if !condition { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
final class NWConnection {}
final class StreamClient {
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
now += VisionAudioForwarding.freshness
check(!expired.visionProviderCanStop, "오래된 OFF 원장은 종료를 허용하지 않음")
expired.performVisionProviderCall(.stop)
check(expired.sent.isEmpty, "오래된 원장은 실제 송신도 차단함")
print("PASS: 실제 Vision 통화 버튼·송신 메서드의 양방향 OFF 종료 회귀; 네트워크·통화·오디오 효과 0")
