import Foundation
import StreamProtocol

@main
struct ProviderAdapterChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ name: String) { checks += 1; precondition(value, name) }
    @MainActor static func flush() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }
    @MainActor static func ready() async throws -> StreamClient {
        let client = StreamClient(), generation = UUID(), peer = client.connection!
        let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
            geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
        let list = WindowList(macName: "fixture", windows: [], active: .desktop, remoteAudio: 1,
            inputGeneration: generation.uuidString, videoEpoch: epoch,
            audioPrivacy: .init(version: 2, protected: true), providerCalls: 1)
        client.desiredAudioSetConnection(peer)
        _ = client.microphonePolicy.setConnection(ObjectIdentifier(peer))
        client.remoteAudioControl.setConnection(ObjectIdentifier(peer))
        // TLS WindowList precedes connected and therefore has no trusted host key yet.
        client.connected = false
        client.fixtureObserve(list)
        expect(!client.providerCall.supported && client.providerCallCapability == 1, "first list capability retained without premature authentication")
        client.connected = true
        client.reconcileDesiredAudio()
        let observe = client.command()
        let device = AudioForwardingDeviceID(fingerprint: DeviceIdentity.existing()!.fingerprint)!
        let credential = try AudioForwardingCredential(pairedDeviceId: device, pairingGeneration: UUID(), credential: String(repeating: "A", count: 43))
        func catalog(_ snapshot: AudioForwardingSnapshot, intent: UInt64, binding: UInt64) throws -> AudioForwardingCatalog {
            try .init(principal: .init(kind: .cable, id: device, authorizationGeneration: credential.pairingGeneration), role: .viewer,
                bootstrap: .init(credential: credential, ownCursor: .init(intentRevision: .init(intent), bindingRevision: .init(binding)), snapshot: snapshot))
        }
        let empty = try AudioForwardingSnapshot(revision: .init(9), intent: nil, binding: nil)
        client.clock.now = 0.1
        client.receive(try .init(requestID: observe.requestID, operation: .observe, catalog: catalog(empty, intent: 0, binding: 0), result: nil))
        expect(!client.iPadProviderCanStart, "217 registration alone without ownbinding cannot perform")
        client.clock.now = 0.2
        try await client.applyAudioRoutes(.init(input: .iPadMicrophone, output: .iPadPlayback), context: client.audioRouteContext)
        let submit = client.command(), r = submit.intent!
        let configuration = try AudioForwardingConfiguration(controllerBootId: UUID(), privacyGeneration: UUID(), registryRevision: .init(1),
            members: [.init(participantId: "native.sill", bootId: UUID()), .init(participantId: "s23.audio.relay", bootId: UUID())])
        let intent = try AudioForwardingSnapshot.Intent(pairedDeviceId: device, intentId: r.intentId, intentRevision: r.intentRevision,
            intentGeneration: UUID(), inputDesired: true, outputDesired: true)
        let binding = AudioForwardingBinding(pairedDeviceId: device, intentGeneration: intent.intentGeneration,
            bindingEpoch: UUID(), transportId: r.transportId, transportKind: .native, operationId: UUID(), phase: .active, configuration: configuration)
        let live = try AudioForwardingSnapshot(revision: .init(10), intent: intent, binding: binding)
        client.clock.now = 0.3
        client.receive(try .init(requestID: submit.requestID, operation: .submit, catalog: nil, result: .accepted(live)))
        expect(client.iPadProviderCanStart && client.providerCall.supported, "authenticated viewer active own binding enables Dots only")
        return client
    }
    @MainActor static func controls(_ peer: NWConnection) -> [ProviderCallControl] {
        peer.messages.filter { $0.first == 221 }.compactMap { Wire.decode(ProviderCallControl.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
    }
    @MainActor static func deliver(_ client: StreamClient, _ status: ProviderCallResult.Status,
                                   request: ProviderCallRequest, peer: NWConnection, session: String? = nil) async throws {
        let state = try ProviderCallState(request: request, result: .init(requestId: request.requestId, status: status,
            reason: "fixture_result", callSessionId: session))
        let data = Wire.encode(state)
        let header = StreamMessage.parseHeader(StreamMessage(kind: .providerCallState, timestamp: 0, isKeyframe: false, payload: data).serialized())!
        expect(client.receiveIPadProviderCall(header, data, from: peer), "222 dispatched through actual adapter")
        await flush()
    }
    @MainActor static func main() async throws {
        let client = try await ready(), peer = client.connection!
        client.performIPadProviderCall(.start, target: .nativeCodex)
        client.performIPadProviderCall(.start, target: .grokBot)
        expect(controls(peer).isEmpty, "native and Grok targets never route to221")
        client.inputPaused = true
        client.performIPadProviderCall(.start, target: .chatGPTDots)
        expect(controls(peer).isEmpty, "paused UI cannot perform")
        client.inputPaused = false
        client.appInForeground = false
        client.performIPadProviderCall(.start, target: .chatGPTDots)
        expect(controls(peer).isEmpty, "background sends no221")
        client.appInForeground = true
        client.providerCallCapability = nil; client.reconcileIPadProviderCall()
        client.performIPadProviderCall(.start, target: .chatGPTDots)
        expect(controls(peer).isEmpty, "absent capability sends no221")
        client.providerCallCapability = 1; client.reconcileIPadProviderCall()
        let oldMedia = client.desiredAudio.selection, oldDurable = client.audioForwarding.durable
        let mediaStarts = peer.messages.filter { $0.first == 200 || $0.first == 204 }.count
        client.performIPadProviderCall(.start, target: .chatGPTDots)
        let start = controls(peer).last!.request
        expect(controls(peer).count == 1 && start.action == .start, "one explicit Dots perform")
        client.performIPadProviderCall(.start, target: .chatGPTDots)
        expect(controls(peer).count == 1, "occupied221 cannot overlap")
        client.clock.now = 1.2
        client.reconcileAudioForwarding()
        expect(client.audioForwardingWire != nil && client.providerCall.pending != nil, "217 observes independently while221pending")
        expect(peer.maximumForwardingInFlight == 1 && client.command().operation == .observe, "217single slot unchanged")
        let wrong = try ProviderCallRequest(requestId: UUID(), action: .start, expectedLeaseRevision: start.expectedLeaseRevision,
            pairedDeviceId: start.pairedDeviceId, desiredInput: start.desiredInput, desiredOutput: start.desiredOutput, callSessionId: nil)
        try await deliver(client, .started, request: wrong, peer: peer)
        expect(client.providerCall.pending?.control.request == start, "wrongID222 cannot drain221")
        client.authenticated = false
        client.reconcileIPadProviderCall()
        expect(client.providerCall.pending != nil && !client.providerCall.supported, "sameTLS nilhost keeps221slot")
        try await deliver(client, .started, request: start, peer: peer, session: "unverified")
        expect(client.providerCall.pending == nil && client.providerCall.result?.status == .unknown, "unverified exact response drains only")
        client.authenticated = true
        client.reconcileIPadProviderCall()
        expect(!client.iPadProviderCanStart && controls(peer).count == 1, "auth recovery cannot perform")
        client.clock.now = 1.8
        try await Task.sleep(nanoseconds: 600_000_000)
        let query = controls(peer).last!
        expect(controls(peer).count == 2 && query.request == start && query.operation == .query,
               "actual scheduled auth recovery sends originalIDquery, perform0")
        try await deliver(client, .started, request: start, peer: peer, session: "cached")
        expect(client.providerCall.historicalResult?.callSessionId == "cached" && !client.iPadProviderCanStop, "automatic cache cannot own currentcall")
        client.clock.now = 11
        expect(client.iPadProviderCanCheckPrevious, "manual history available only after original budget")
        client.checkPreviousIPadProviderCall(target: .nativeCodex)
        client.checkPreviousIPadProviderCall(target: .grokBot)
        let registration = client.audioForwarding
        client.audioForwarding.block()
        client.checkPreviousIPadProviderCall(target: .chatGPTDots)
        expect(!client.providerCallRegistered && controls(peer).count == 2, "blocked217 cannot reuse stale viewer registration for query")
        client.audioForwarding = registration
        expect(controls(peer).count == 2, "native target never sends Dots query")
        client.checkPreviousIPadProviderCall(target: .chatGPTDots)
        expect(controls(peer).count == 3 && controls(peer).last?.request == start && controls(peer).last?.operation == .query,
               "actual manual221query preserves identity")
        expect(client.providerCall.pending?.expiresAt == 21 && client.providerCall.firstSentAt == 0.3, "manual10s separate from initial deadline")
        try await deliver(client, .stopped, request: start, peer: peer)
        expect(client.providerCall.pending != nil, "wrong action manualreply nondrain")
        try await deliver(client, .started, request: start, peer: peer, session: "old-result")
        expect(!client.iPadProviderCanStart && !client.iPadProviderCanStop && !client.providerCall.needsAutomaticQuery, "manualterminal no perform no ownership no loop")
        expect(client.desiredAudio.selection == oldMedia && client.audioForwarding.durable == oldDurable, "provider never changes desire or durable media")
        expect(peer.messages.filter { $0.first == 200 || $0.first == 204 }.count == mediaStarts, "provider operation sends no new media requests")
        client.checkPreviousIPadProviderCall(target: .chatGPTDots)
        let late = client.providerCall.pending!
        client.clock.now = 21
        try await deliver(client, .started, request: start, peer: peer)
        expect(client.providerCall.pending?.id == late.id, "heldmainqueue lateACK cannot free physicalslot")
        expect(client.providerCall.timeout(late), "expired221 marked unknown")
        let replacement = NWConnection()
        client.connection = replacement
        client.desiredAudioSetConnection(replacement)
        expect(client.providerCall.pending == nil && client.providerCall.request == start && client.providerCallCapability == nil, "actualTLS replacement retains request but resets capability")
        try await deliver(client, .started, request: start, peer: peer)
        expect(!client.providerCall.supported && controls(replacement).isEmpty, "oldTLS cannot authorize replacement")

        let stopped = try await ready(), stopPeer = stopped.connection!
        stopped.performIPadProviderCall(.start, target: .chatGPTDots)
        let started = controls(stopPeer).last!.request
        try await deliver(stopped, .started, request: started, peer: stopPeer, session: "direct-call")
        expect(stopped.iPadProviderCanStop, "only directperformACK can expose explicitstop with livebinding")
        stopped.performIPadProviderCall(.stop, target: .chatGPTDots)
        let stop = controls(stopPeer).last!.request
        expect(stop.action == .stop && stop.callSessionId == "direct-call", "stop preserves actual direct session")
        try await deliver(stopped, .stopped, request: stop, peer: stopPeer)
        expect(stopped.iPadProviderCanStart, "directstopACK permits explicit next start")
        stopped.clock.now = 4
        stopped.performIPadProviderCall(.start, target: .chatGPTDots)
        expect(controls(stopPeer).count == 2, "expired217media evidence cannot perform even before main timer fires")
        print("PASS \(checks) actual iPad adapter checks; device/host/audio/network effects0")
    }
}
