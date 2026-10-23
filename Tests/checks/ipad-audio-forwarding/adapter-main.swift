import Foundation
import StreamProtocol

@main
struct AdapterChecks {
    static var checks = 0
    static func check(_ value: Bool, _ name: String) {
        checks += 1
        precondition(value, name)
    }
    @MainActor static func flush() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }
    @MainActor static func main() async throws {
        let client = StreamClient(), generation = UUID()
        let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
            geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
        var list = WindowList(macName: "fixture", windows: [], active: .desktop, remoteAudio: 1,
            inputGeneration: generation.uuidString, videoEpoch: epoch, audioPrivacy: .init(version: 2, protected: true))
        let peer = client.connection!
        client.desiredAudioSetConnection(peer)
        _ = client.microphonePolicy.setConnection(ObjectIdentifier(peer))
        client.remoteAudioControl.setConnection(ObjectIdentifier(peer))
        client.fixtureObserve(list)
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
        check(client.microphonePolicy.scope == nil && !client.microphonePolicy.canStart, "pre-binding microphone catalog absent")
        check(client.audioRouteCapabilities.microphone && client.audioRouteCapabilities.playback, "authenticated218 supports explicit choice before media capability")
        client.clock.now = 0.2
        try await client.applyAudioRoutes(.init(input: .iPadMicrophone, output: .iPadPlayback), context: client.audioRouteContext)
        let request = client.command(), r = client.command().intent!
        check(request.operation == .submit && r.inputDesired && r.outputDesired, "actual chooser submits full duplex atomically")
        check(client.subscriptions.filter(\.enabled).isEmpty && client.microphoneAttempts == 0, "217 submit alone never sends200/204")
        let configuration = try AudioForwardingConfiguration(controllerBootId: UUID(), privacyGeneration: UUID(), registryRevision: .init(1),
            members: [.init(participantId: "native.sill", bootId: UUID()), .init(participantId: "s23.audio.relay", bootId: UUID())])
        let intent = try AudioForwardingSnapshot.Intent(pairedDeviceId: device, intentId: r.intentId, intentRevision: r.intentRevision,
            intentGeneration: UUID(), inputDesired: true, outputDesired: true)
        let binding = AudioForwardingBinding(pairedDeviceId: device, intentGeneration: intent.intentGeneration,
            bindingEpoch: UUID(), transportId: r.transportId, transportKind: .native, operationId: UUID(), phase: .quiescing, configuration: configuration)
        let quiet = try AudioForwardingSnapshot(revision: .init(10), intent: intent, binding: binding)
        client.clock.now = 0.3
        client.receive(try .init(requestID: request.requestID, operation: .submit, catalog: nil, result: .accepted(quiet)))
        check(!client.desiredAudioPermits(.microphone) && !client.desiredAudioPermits(.playback), "quiescing keeps legacy grants closed")
        client.clock.now = 1.2
        client.reconcileAudioForwarding()
        let poll = client.command()
        let liveBinding = AudioForwardingBinding(pairedDeviceId: device, intentGeneration: intent.intentGeneration,
            bindingEpoch: binding.bindingEpoch, transportId: r.transportId, transportKind: .native,
            operationId: binding.operationId, phase: .active, configuration: configuration)
        let live = try AudioForwardingSnapshot(revision: .init(11), intent: intent, binding: liveBinding)
        client.clock.now = 1.3
        client.receive(try .init(requestID: poll.requestID, operation: .observe, catalog: catalog(live, intent: 1, binding: 1), result: nil))
        check(client.microphoneAttempts == 0 && !client.desiredAudioPermits(.microphone), "active still waits for new microphone capability")
        check(client.subscriptions.filter(\.enabled).count == 1, "actual200 starts once after common active")
        list.microphone = .init(peer: UUID(), destination: UUID(), generation: UUID())
        client.clock.now = 1.4
        client.fixtureObserve(list)
        check(client.microphoneAttempts == 1 && client.desiredAudioPermits(.microphone), "new capability after active opens existing microphone gate")
        let microphoneStarts = peer.messages.filter { $0.first == 204 }.compactMap {
            Wire.decode(MicrophoneControl.self, from: Data($0.dropFirst(StreamMessage.headerLength)))
        }.filter { $0.operation == .start }
        check(microphoneStarts.count == 1, "actual204 start passes the single gate exactly once")
        var rendered = 0, sent = 0
        let ticket = client.audioCatalogAdmission
        check(client.audioAdmission.withAdmission(ticket, { rendered += 1 }), "live render admitted")
        check(client.audioAdmission.withAdmission(ticket, direction: .microphone, { sent += 1 }), "live frame admitted")
        client.clock.now = 4.2
        check(!client.audioAdmission.withAdmission(ticket, { rendered += 1 }), "render expires without main scheduler")
        check(!client.audioAdmission.withAdmission(ticket, direction: .microphone, { sent += 1 }), "frame expires without main scheduler")
        check(rendered == 1 && sent == 1, "expired callbacks media0")
        client.reconcileAudioForwarding()
        check(client.audioForwarding.phase == .blocked && client.audioForwardingWake == nil, "admission expiry stops polling")
        let count = peer.messages.count
        client.clock.now = 5
        client.reconcileDesiredAudio()
        check(peer.messages.count == count, "TTL failure cannot retry request or resume")
        check(client.desiredAudio.selection.microphone && client.desiredAudioStore.forwarding(for: client.desiredAudioIdentity!) != nil, "failure preserves saved desire and durable intent")
        let positiveBeforeRetry = client.subscriptions.filter(\.enabled).count
        check(client.audioRouteCapabilities.microphone && client.audioRouteCapabilities.playback,
              "known authenticated peer support survives blocked media state")
        try await client.applyAudioRoutes(.init(input: .iPadMicrophone, output: .iPadPlayback), context: client.audioRouteContext)
        let retryObserve = client.command()
        check(retryObserve.operation == .observe && retryObserve.intent == nil,
              "explicit retry reaches fresh observe through actual chooser actions")
        check(!client.desiredAudioPermits(.microphone) && !client.desiredAudioPermits(.playback),
              "retry observation never restores old media evidence")
        client.clock.now = 5.1
        client.receive(try .init(requestID: retryObserve.requestID, operation: .observe,
            catalog: catalog(live, intent: 1, binding: 1), result: nil))
        check(client.command().intent?.action == .update && client.command().intent?.intentRevision.value == 2,
              "only explicit fresh retry submits a new CAS update, never automatic resume/request")
        check(client.subscriptions.filter(\.enabled).count == positiveBeforeRetry && !client.desiredAudioPermits(.playback),
              "fresh retry still waits for its own accepted active binding")
        let malformed = StreamMessage(kind: .forwardingState, timestamp: 0, isKeyframe: false, payload: Data("{}".utf8))
        _ = client.receiveAudioForwarding(StreamMessage.parseHeader(malformed.serialized().prefix(StreamMessage.headerLength))!, malformed.payload, from: peer)
        await flush()
        check(client.audioForwarding.phase == .blocked, "malformed218 through actual receive adapter fails closed")
        let oldContext = client.audioForwardingContext!
        client.suspendAudioForwarding()
        check(client.audioForwardingContext != oldContext, "foreground cycle invalidates pending manual context")
        check(!client.desiredAudioPermits(.microphone) && !client.desiredAudioPermits(.playback), "suspension immediate media0")
        client.appInForeground = false
        UIApplication.shared.applicationState = .background
        client.reconcileAudioForwarding()
        check(client.audioForwardingWake == nil && client.audioForwarding.context == nil, "background zero observes")
        // A held host exchange survives local invalidation. Old responses drain only.
        for change in ["background", "source-roundtrip"] {
            UIApplication.shared.applicationState = .active
            let held = StreamClient()
            held.desiredAudioSetConnection(held.connection)
            _ = held.microphonePolicy.setConnection(ObjectIdentifier(held.connection!))
            held.remoteAudioControl.setConnection(ObjectIdentifier(held.connection!))
            var initialList = list
            initialList.microphone = nil
            held.fixtureObserve(initialList)
            let original = held.command()
            let originalPeer = held.connection!
            let countBefore = originalPeer.messages.count
            if change == "background" {
                held.appInForeground = false; UIApplication.shared.applicationState = .background
                held.suspendAudioForwarding(); held.reconcileAudioForwarding()
                held.clock.now = 0.5
                held.appInForeground = true; UIApplication.shared.applicationState = .active
                held.reconcileAudioForwarding()
            } else {
                held.suspendAudioForwarding(); held.desiredAudio.sourceWillChange()
                let gen = UUID()
                var changed = initialList
                changed.active = .window(99); changed.inputGeneration = gen.uuidString
                changed.videoEpoch = VideoEpoch(generation: gen.uuidString, source: .window(99),
                    geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
                held.fixtureObserve(changed)
                held.suspendAudioForwarding(); held.desiredAudio.sourceWillChange()
                held.fixtureObserve(initialList)
            }
            check(originalPeer.messages.count == countBefore, "held217 prevents new observe across " + change)
            check(held.audioForwarding.phase == .unknown && held.audioForwarding.catalog == nil, "old scope loses authority while wire retained")
            held.clock.now = 2.5
            held.receive(try .init(requestID: original.requestID, operation: .observe,
                catalog: catalog(empty, intent: 0, binding: 0), result: nil))
            check(originalPeer.messages.count == countBefore + 1 && originalPeer.maximumForwardingInFlight == 1,
                  "old218 drains before a single fresh observe " + change)
            check(held.audioForwarding.catalog == nil && held.audioForwarding.phase == .observing,
                  "drained218 never establishes new-scope evidence")
            let newObserve = held.command()
            held.clock.now = 2.6
            held.receive(try .init(requestID: newObserve.requestID, operation: .observe,
                catalog: catalog(empty, intent: 0, binding: 0), result: nil))
            check(held.audioForwarding.supported && originalPeer.maximumForwardingInFlight == 1,
                  "fresh scope observes once after drain")
        }
        UIApplication.shared.applicationState = .active
        let failedSend = StreamClient()
        failedSend.connection!.holdSendCompletions = true
        failedSend.desiredAudioSetConnection(failedSend.connection)
        failedSend.fixtureObserve(list)
        let failedPeer = failedSend.connection!
        failedSend.suspendAudioForwarding()
        failedSend.reconcileAudioForwarding()
        failedPeer.failSends()
        await flush()
        check(failedSend.audioForwardingWire == nil && failedSend.audioForwarding.phase == .blocked,
              "send failure drains retained old-scope wire without authorizing new scope")
        check(failedPeer.maximumForwardingInFlight == 1, "failed old-scope send never overlaps217")
        print("실제 iPad 어댑터·가짜 전송/시계 검사 \(checks)개 통과. 실제 미디어·기기·네트워크 없음.")
    }
}
