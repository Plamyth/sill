import Foundation
import StreamProtocol

private final class BoundaryConnection {
    enum State { case ready }
    let state = State.ready
    let endpoint = "injected"
    enum Completion { case contentProcessed((Error?) -> Void) }
    var completions: [() -> Void] = []
    func cancel() {}
    func send(content: Data, completion: Completion) {
        if case .contentProcessed(let callback) = completion { completions.append { callback(nil) } }
    }
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
    final class Client {
        let connection: BoundaryConnection
        var remoteAudioEnabled = false
        var remoteAudioAfterSequence: UInt64 = .max
        var pendingBytes = 0
        let presentationInput = false
        let route = (isRemote: false, unused: false)
        var oldestUnackedFrameAt: TimeInterval?
        let connectedAt = Date().timeIntervalSince1970
        var inflight = 0, inflightFrames = 0, takenThisSecond = 0
        var lastSentAt: TimeInterval = 0
        var keyframeSeq = 0, keyframeBytesInFlight = 0, backlogFloor = 0
        var keyframesInFlight: [(seq: Int, bytes: Int)] = []
        init(_ connection: BoundaryConnection) { self.connection = connection }
    }
    static let remoteDeadAfter = 15.0, deadAfter = 4.0, remoteGrace = 15.0, graceAfterConnect = 8.0
    let queue = DispatchQueue(label: "privacy.injected.net")
    let remoteAudioDrain = DispatchGroup()
    var clients: [ObjectIdentifier: Client] = [:]
    var remoteAudioEpoch: UInt64 = 0
    let videoAdmission: (current: VideoEpoch?, unused: Bool) = (nil, false)
    var sent: [StreamMessage] = []
    func send(_ message: StreamMessage, to connection: BoundaryConnection) { sent.append(message) }
    // PRODUCTION_SERVER_BOUNDARIES
}
@MainActor
private final class BoundaryCapture {
    var stops = 0
    func stop() async { stops += 1 }
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
    var physicalAudioRoutesRetired = false
    var remoteAudioRunning = false
    let remoteAudioCapture = BoundaryCapture()
    let remoteAudioLifecycle = RemoteAudioCaptureLifecycle()
    var audioRoutePublished: [ObjectIdentifier: UUID] = [:]
    var audioRouteArrivals: [ObjectIdentifier: [TimeInterval]] = [:]
    var broadcasts = 0
    init(_ privacy: HostAudioPrivacy?) {
        audioPrivacy = privacy
        privacy?.changed = { [weak self] state in self?.audioPrivacyChanged(state) }
        privacy?.revokeForLocalReturn = { [weak self] in await self?.prepareLocalAudioReturn() ?? false }
    }
    private func broadcastList() { broadcasts += 1 }
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
        expect(microphoneIngress.revoked > 0 && microphoneReceiver.revoked > 0 &&
               microphoneReceiver.forgotten > 0, "property failure immediately revokes microphone authority")
        expect(remoteAudioRequests.isEmpty && remoteAudioActions.isEmpty, "in-flight subscription cannot revive after failure")
        expect(!canEnableRemoteAudio(id, requestID: request, action: 1), "stale audio completion refused")
        for _ in 0..<100 {
            if remoteAudioCapture.stops > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(remoteAudioCapture.stops > 0, "property failure schedules actual lifecycle capture teardown")
    }
    func localReturnCheck(_ fake: PrivacyFakeHAL) async {
        guard let audioPrivacy else { return }
        let peer = BoundaryConnection(), id = ObjectIdentifier(peer)
        routes[id] = BoundaryRoute(); connections[id] = peer
        server.queue.sync { server.clients[id] = BoundaryServer.Client(peer) }
        server.setRemoteAudio(true, for: peer, afterSequence: 0)
        server.broadcastRemoteAudio(Data([1]), epoch: 0, sequence: 1)
        let submitted = server.queue.sync { peer.completions.count }
        expect(submitted == 1, "production broadcast and send hold an actual audio completion")
        let before = fake.writes.count
        let task = Task { @MainActor in await audioPrivacy.requestLocalReturn() }
        for _ in 0..<40 { if physicalAudioRoutesRetired { break }; await Task.yield() }
        expect(fake.writes.count == before && physicalAudioRoutesRetired, "coordinator waits for production server audio drain before restore")
        server.broadcastRemoteAudio(Data([2]), epoch: 0, sequence: 2)
        let stillPending = server.queue.sync { peer.completions.count }
        expect(stillPending == 1, "closed production epoch drops queued stale audio during local return")
        let state = audioHardwareRoutes.observe()
        let pick = AudioRouteSelection(revision: state.revision, expected: state.defaults, inputUID: "physical")
        let message = StreamMessage(kind: .changeAudioRoute, timestamp: 0, isKeyframe: false, payload: Wire.encode(pick))
        handleAudioRoute(message, from: peer)
        expect(hardware.writes == 0, "physical route is denied while local-return boundary waits")
        server.queue.sync {
            let callbacks = peer.completions; peer.completions.removeAll()
            callbacks.forEach { $0() }
        }
        let returned = await task.value
        expect(returned && !audioPrivacy.latched, "actual server drain acknowledgement permits authenticated restore")
        audioRouteArrivals.removeAll()
        handleAudioRoute(message, from: peer)
        expect(hardware.writes == 0, "existing paired peer has no physical-route authority after latch clears")
        let selected = Wire.decode(AudioRouteState.self, from: server.sent.last!.payload)
        expect(selected?.result == .unavailable, "post-return physical route refusal is explicit")
        expect(audioPrivacy.armAndVerify() && audioPrivacy.latched, "new explicit trusted arm can establish a fresh protected session")
    }

}

@MainActor
func coordinatorChecks(_ privacy: HostAudioPrivacy) async {
    await PrivacyCoordinatorFixture(privacy).check()
    await PrivacyCoordinatorFixture(nil).check()
}

@MainActor
func serverDrainChecks() async {
    let fake = PrivacyFakeHAL()
    let privacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: fake.operations), clearLatch: { true }, authenticateLocal: { true })
    expect(privacy.armAndVerify(), "production boundary restore fixture armed")
    await PrivacyCoordinatorFixture(privacy).localReturnCheck(fake)
    privacy.stop()

    let staleFake = PrivacyFakeHAL()
    let stale = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: staleFake.operations), clearLatch: { true }, authenticateLocal: { true })
    var acknowledgement: CheckedContinuation<Bool, Never>?
    stale.revokeForLocalReturn = { await withCheckedContinuation { acknowledgement = $0 } }
    expect(stale.armAndVerify(), "post-auth generation fixture armed")
    let task = Task { @MainActor in await stale.requestLocalReturn() }
    for _ in 0..<40 { if acknowledgement != nil { break }; await Task.yield() }
    expect(acknowledgement != nil, "authenticated request waits at acknowledged revocation boundary")
    _ = stale.armAndVerify()
    let writes = staleFake.writes.count
    acknowledgement?.resume(returning: true)
    let returned = await task.value
    expect(!returned && stale.latched && staleFake.writes.count == writes, "generation change during server drain prevents every restore setter")
    stale.stop()

    let stalledServer = BoundaryServer(), stalledPeer = BoundaryConnection()
    stalledServer.queue.sync { stalledServer.clients[ObjectIdentifier(stalledPeer)] = BoundaryServer.Client(stalledPeer) }
    stalledServer.setRemoteAudio(true, for: stalledPeer, afterSequence: 0)
    stalledServer.broadcastRemoteAudio(Data([1]), epoch: 0, sequence: 1)
    let drained = await withCheckedContinuation { continuation in
        stalledServer.drainRemoteAudio { continuation.resume(returning: $0) }
    }
    expect(!drained, "production drain times out closed when submitted audio never completes")
    stalledServer.queue.sync {
        let callbacks = stalledPeer.completions; stalledPeer.completions.removeAll()
        callbacks.forEach { $0() }
    }
}
