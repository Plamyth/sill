import Foundation
import StreamProtocol

private final class BoundaryConnection {
    enum State { case ready }
    let state = State.ready
}
private struct BoundaryRoute { let encrypted = true; let fingerprint: Data? = Data([1]) }
private final class BoundaryTrust { func isPaired(_ fingerprint: Data) -> Bool { fingerprint == Data([1]) } }
private final class BoundaryIngress {
    var revoked = 0
    func revoke() { revoked += 1 }
    func peer(_ connection: BoundaryConnection) -> (id: UUID, fingerprint: Data)? { (UUID(), Data([1])) }
}
private final class BoundaryMicrophone {
    var revoked = 0
    var forgotten = 0
    var capabilities = 0
    func revoke(reason: String) { revoked += 1 }
    func forgetCapabilities() { forgotten += 1 }
    func capability(peer: UUID, source: StreamSource, inputGeneration: UUID, videoEpoch: UUID,
                    fingerprint: Data) -> MicrophoneCapability? {
        capabilities += 1
        return MicrophoneCapability(peer: peer, destination: UUID(), generation: UUID())
    }
}
private final class BoundaryServer {
    var disabled = 0
    var sent: [StreamMessage] = []
    func setRemoteAudio(_ enabled: Bool, for connection: BoundaryConnection) { if !enabled { disabled += 1 } }
    func send(_ message: StreamMessage, to connection: BoundaryConnection) { sent.append(message) }
}
private final class BoundaryHardware: AudioRouteHardware {
    var writes = 0
    func read() throws -> AudioRouteInventory {
        AudioRouteInventory(endpoints: [AudioRouteEndpoint(uid: "physical", name: "물리 장치", input: true, output: true)],
            defaults: AudioRouteDefaults(inputUID: "BlackHole2ch_UID", outputUID: "BlackHole16ch_UID"))
    }
    func compareAndSet(_ direction: AudioRouteDirection, uid: String, expected: AudioRouteDefaults,
                       intent: AudioRouteWriteIntent) -> AudioRouteWrite { writes += 1; return .attempted(success: true) }
}

@MainActor
private final class PrivacyCoordinatorFixture {
    let audioPrivacy: HostAudioPrivacy?
    var nativeAudioBindingAuthorized: ((Data) -> Bool)? = { _ in true }
    var physicalAudioRoutesRetired = false
    var peerStreams: [ObjectIdentifier: (epoch: UUID?, unused: Bool)] = [:]
    private func peerAudioDisplay(_ id: ObjectIdentifier) -> Int? { catalog.display }
    var synthetic = false
    var switching = false
    var shuttingDown = false
    var active = StreamSource.desktop
    let catalog = (display: Optional(1), unused: false)
    let videoEpoch: (id: UUID, unused: Bool)? = (UUID(), false)
    let inputGeneration = UUID().uuidString
    let microphoneIngress = BoundaryIngress()
    let microphoneReceiver = BoundaryMicrophone()
    let server = BoundaryServer()
    let hardware = BoundaryHardware()
    lazy var audioHardwareRoutes = AudioHardwareRoutes(hardware: hardware)
    var routes: [ObjectIdentifier: BoundaryRoute] = [:]
    var connections: [ObjectIdentifier: BoundaryConnection] = [:]
    var remote: BoundaryTrust? = BoundaryTrust()
    var remoteAudioSubscribers: Set<ObjectIdentifier> = []
    var remoteAudioRequests: [ObjectIdentifier: UUID] = [:]
    var remoteAudioActions: [ObjectIdentifier: UInt64] = [:]
    var remoteAudioEpoch: UInt64 = 0
    var audioRoutePublished: [ObjectIdentifier: UUID] = [:]
    var audioRouteArrivals: [ObjectIdentifier: [TimeInterval]] = [:]
    var broadcasts = 0
    var teardowns = 0
    init(_ privacy: HostAudioPrivacy?) {
        audioPrivacy = privacy
        privacy?.changed = { [weak self] state in self?.audioPrivacyChanged(state) }
    }
    private func broadcastList() { broadcasts += 1 }
    private func enqueueRemoteAudioRevocation(reason: String) {
        teardowns += 1; remoteAudioSubscribers.removeAll()
        remoteAudioRequests.removeAll(); remoteAudioActions.removeAll()
    }
    private func listMessage() -> StreamMessage {
        StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false,
            payload: Wire.encode(WindowList(macName: "시험", windows: [], active: active, audioPrivacy: audioPrivacy?.state)))
    }

    // PRODUCTION_BOUNDARIES

    func check() async {
        let peer = BoundaryConnection(), id = ObjectIdentifier(peer), request = UUID()
        routes[id] = BoundaryRoute(); connections[id] = peer
        let wasReady = audioPrivacyReady()
        remoteAudioRequests[id] = request; remoteAudioActions[id] = 1
        nativeAudioBindingAuthorized = nil
        expect(!nativeAudioBindingReady(peer), "원장 어댑터가 없으면 네이티브 오디오 입장 거부")
        expect(!canEnableRemoteAudio(id, requestID: request, action: 1), "바인딩 확인 없는 재생 승인 거부")
        expect(Wire.decode(WindowList.self, from: microphoneCatalog(to: peer).payload)?.microphone == nil,
               "바인딩 확인 없는 마이크 capability 거부")
        nativeAudioBindingAuthorized = { _ in true }
        remoteAudioRequests[id] = request; remoteAudioActions[id] = 1
        expect(canEnableRemoteAudio(id, requestID: request, action: 1) == wasReady, "audio admission requires readback")
        let list = Wire.decode(WindowList.self, from: microphoneCatalog(to: peer).payload)!
        expect((list.microphone != nil) == wasReady, "microphone catalog requires verified privacy")
        expect(list.audioPrivacy?.protected == audioPrivacy?.state.protected, "catalog status matches current verification")
        if audioPrivacy?.latched == true {
            let state = audioHardwareRoutes.observe()
            let select = AudioRouteSelection(revision: state.revision, expected: state.defaults, inputUID: "physical")
            handleAudioRoute(StreamMessage(kind: .changeAudioRoute, timestamp: 0, isKeyframe: false,
                payload: Wire.encode(select)), from: peer)
            expect(hardware.writes == 0, "latched physical selection rejected before any setter or rollback")
            expect(Wire.decode(AudioRouteState.self, from: server.sent.last!.payload)?.result == .unavailable,
                   "physical route refusal is correlated")
        }
        remoteAudioSubscribers.insert(id)
        audioPrivacyChanged(AudioPrivacyState(protected: false, reason: "시험 실패"))
        expect(server.disabled == 1 && microphoneIngress.revoked > 0 && microphoneReceiver.revoked > 0 &&
               microphoneReceiver.forgotten > 0, "property failure closes existing audio and microphone gates synchronously")
        expect(remoteAudioRequests.isEmpty && remoteAudioActions.isEmpty, "in-flight subscription cannot revive after failure")
        expect(!canEnableRemoteAudio(id, requestID: request, action: 1), "stale audio completion refused")
        for _ in 0..<20 { await Task.yield() }
        expect(teardowns > 0, "property failure schedules capture teardown")
    }
}

@MainActor
func coordinatorChecks(_ privacy: HostAudioPrivacy) async {
    await PrivacyCoordinatorFixture(privacy).check()
    await PrivacyCoordinatorFixture(nil).check()
}
