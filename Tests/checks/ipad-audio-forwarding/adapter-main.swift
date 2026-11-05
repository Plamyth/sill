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
            inputGeneration: generation.uuidString, videoEpoch: epoch, audioPrivacy: .init(version: 2, protected: false))
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
        check(!client.desiredAudioPermits(.microphone) && !client.desiredAudioPermits(.playback), "unarmed host never admits media")
        client.clock.now = 0.15
        client.fixtureObserve(list)
        check(client.audioForwarding.phase == .ready, "repeated unarmed catalog preserves authenticated control")
        let permission = IPadAudioRoutePolicy.Authorization(context: client.audioRouteContext!)
        client.audioRouteAuthorization = permission
        client.clock.now = 0.16
        client.fixtureObserve(list)
        check(client.audioRouteAuthorization == permission, "same-scope unarmed catalog preserves explicit permission request")
        client.audioRouteAuthorization = nil
        client.clock.now = 0.2
        try await client.applyAudioRoutes(.init(input: .iPadMicrophone, output: .iPadPlayback), context: client.audioRouteContext)
        let request = client.command(), r = client.command().intent!
        check(request.operation == .submit && r.inputDesired && r.outputDesired, "actual chooser submits full duplex atomically")
        check(client.subscriptions.filter(\.enabled).isEmpty && client.microphoneAttempts == 0, "217 submit alone never sends200/204")
        client.clock.now = 0.25
        client.fixtureObserve(list)
        check(client.audioForwarding.phase == .submitting && client.audioForwarding.pendingRequestID == request.requestID,
              "unarmed catalog cannot cancel explicit protection request")
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
        client.clock.now = 0.4
        client.fixtureObserve(list)
        check(client.audioForwarding.phase == .quiescing, "unarmed catalog keeps quiescing control alive")
        check(client.subscriptions.filter(\.enabled).isEmpty && client.microphoneAttempts == 0,
              "unarmed quiescing sends no media start")
        list.audioPrivacy = .init(version: 2, protected: true)
        client.clock.now = 0.5
        client.fixtureObserve(list)
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
        let permissionClient = StreamClient()
        permissionClient.desiredAudioSetConnection(permissionClient.connection)
        var permissionList = list
        permissionList.microphone = nil
        permissionList.audioPrivacy = .init(version: 2, protected: false)
        permissionClient.fixtureObserve(permissionList)
        let permissionObserve = permissionClient.command()
        permissionClient.clock.now = 0.1
        permissionClient.receive(try .init(requestID: permissionObserve.requestID, operation: .observe,
            catalog: catalog(empty, intent: 0, binding: 0), result: nil))
        AVCaptureDevice.status = .notDetermined
        AVCaptureDevice.holdPermission = true
        let pendingPermission = Task { @MainActor in
            try await permissionClient.applyAudioRoutes(.init(input: .iPadMicrophone, output: .iPadPlayback), context: permissionClient.audioRouteContext)
        }
        for _ in 0..<1000 where AVCaptureDevice.permissionWaiter == nil { await Task.yield() }
        check(AVCaptureDevice.permissionWaiter != nil, "unarmed chooser reaches real permission boundary")
        UIApplication.shared.applicationState = .inactive
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        permissionClient.fixtureObserve(permissionList)
        UIApplication.shared.applicationState = .active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await flush()
        check(!permissionClient.audioForwarding.supported, "foreground has no fresh218 before permission returns")
        AVCaptureDevice.status = .authorized
        AVCaptureDevice.holdPermission = false
        AVCaptureDevice.permissionWaiter?.resume(returning: true)
        AVCaptureDevice.permissionWaiter = nil
        try await pendingPermission.value
        check(permissionClient.desiredAudio.selection.microphone && permissionClient.desiredAudio.selection.playback,
              "same-scope explicit choice survives permission and pending fresh218")
        let refreshed = permissionClient.command()
        check(refreshed.operation == .observe && permissionClient.microphoneAttempts == 0 && permissionClient.subscriptions.filter(\.enabled).isEmpty,
              "permission alone queues fresh observe and never starts media")
        permissionClient.clock.now = 0.2
        permissionClient.receive(try .init(requestID: refreshed.requestID, operation: .observe,
            catalog: catalog(empty, intent: 0, binding: 0), result: nil))
        check(permissionClient.command().intent?.action == .request,
              "fresh218 submits previously explicit permission-approved intent")
        let reconnect = StreamClient()
        let identity = reconnect.desiredAudioIdentity!
        reconnect.desiredAudioStore.save(.init(microphone: true, playback: true), for: identity)
        reconnect.desiredAudioStore.saveForwarding(.init(device: device, intentID: intent.intentId,
            revision: intent.intentRevision, generation: intent.intentGeneration,
            selection: .init(microphone: true, playback: true)), for: identity)
        reconnect.desiredAudioSetConnection(reconnect.connection)
        reconnect.fixtureObserve(permissionList)
        let reconnectObserve = reconnect.command()
        reconnect.clock.now = 0.1
        reconnect.receive(try .init(requestID: reconnectObserve.requestID, operation: .observe,
            catalog: catalog(live, intent: 1, binding: 1), result: nil))
        check(reconnect.command().intent?.action == .resume && reconnect.command().intent?.intentId == intent.intentId,
              "unarmed reconnect resumes only matching previously approved durable intent")
        check(reconnect.microphoneAttempts == 0 && reconnect.subscriptions.filter(\.enabled).isEmpty,
              "durable resume still requires protected active media proof")
        for initiallyProtected in [true, false] {
            let lossClient = StreamClient()
            lossClient.desiredAudioSetConnection(lossClient.connection)
            _ = lossClient.microphonePolicy.setConnection(ObjectIdentifier(lossClient.connection!))
            lossClient.remoteAudioControl.setConnection(ObjectIdentifier(lossClient.connection!))
            var lossList = list
            lossList.audioPrivacy = .init(version: 2, protected: initiallyProtected)
            lossClient.fixtureObserve(lossList)
            let discovery = lossClient.command()
            lossClient.clock.now = 0.1
            lossClient.receive(try .init(requestID: discovery.requestID, operation: .observe,
                catalog: catalog(empty, intent: 0, binding: 0), result: nil))
            try await lossClient.applyAudioRoutes(.init(input: .iPadMicrophone, output: .iPadPlayback), context: lossClient.audioRouteContext)
            let submission = lossClient.command(), selection = submission.intent!
            let ownerIntent = try AudioForwardingSnapshot.Intent(pairedDeviceId: device, intentId: selection.intentId,
                intentRevision: selection.intentRevision, intentGeneration: UUID(), inputDesired: true, outputDesired: true)
            let ownerBinding = AudioForwardingBinding(pairedDeviceId: device, intentGeneration: ownerIntent.intentGeneration,
                bindingEpoch: UUID(), transportId: selection.transportId, transportKind: .native,
                operationId: UUID(), phase: .active, configuration: configuration)
            let active = try AudioForwardingSnapshot(revision: .init(10), intent: ownerIntent, binding: ownerBinding)
            lossClient.clock.now = 0.2
            lossClient.receive(try .init(requestID: submission.requestID, operation: .submit, catalog: nil, result: .accepted(active)))
            let oldTicket = lossClient.audioCatalogAdmission
            if !initiallyProtected {
                check(lossClient.subscriptions.filter(\.enabled).isEmpty && lossClient.microphoneAttempts == 0,
                      "active binding without protected catalog cannot start media")
            }
            lossList.audioPrivacy = .init(version: 2, protected: false)
            lossClient.clock.now = 0.3
            lossClient.fixtureObserve(lossList)
            check(lossClient.audioForwarding.phase == .blocked && !lossClient.desiredAudioPermits(.microphone) && !lossClient.desiredAudioPermits(.playback),
                  "unprotected active or loss of established protection blocks immediately")
            check(!lossClient.audioAdmission.withAdmission(oldTicket, {}), "protection loss invalidates render ticket")
            lossList.audioPrivacy = .init(version: 2, protected: true)
            lossClient.clock.now = 0.4
            lossClient.fixtureObserve(lossList)
            check(lossClient.audioForwarding.phase == .blocked && !lossClient.desiredAudioPermits(.playback),
                  "restored privacy alone cannot resume media")
        }
        for privacy: AudioPrivacyState? in [nil, .init(version: 1, protected: true), .init(version: 3, protected: true)] {
            let unsupported = StreamClient()
            unsupported.desiredAudioSetConnection(unsupported.connection)
            var unsupportedList = list
            unsupportedList.audioPrivacy = privacy
            unsupported.fixtureObserve(unsupportedList)
            check(!unsupported.audioRouteCapabilities.microphone && !unsupported.audioRouteCapabilities.playback,
                  "missing or unsupported privacy version cannot select audio")
            check(!unsupported.desiredAudioPermits(.microphone) && !unsupported.desiredAudioPermits(.playback),
                  "unsupported privacy has no media admission")
        }
        let guarded = StreamClient()
        guarded.desiredAudioSetConnection(guarded.connection)
        check(guarded.forwardingContextReadiness["forwardingDevicePresent"] == false &&
              guarded.forwardingContextReadiness["desiredScopePresent"] == false &&
              guarded.forwardingContextReadiness["contextPresent"] == false,
              "missing device and scope are observed without initializing them")
        guarded.fixtureObserve(list)
        let readyGuards = guarded.forwardingContextReadiness
        check(readyGuards["contextPresent"] == true && readyGuards["contextMatchesForwardingState"] == true &&
              readyGuards["wirePresent"] == true && readyGuards["pendingPresent"] == true &&
              readyGuards["forwardingFaulted"] == false, "actual observe exposes context and held wire without authority")
        let guardMessageCount = guarded.connection!.messages.count
        _ = guarded.forwardingContextReadiness
        check(guarded.connection!.messages.count == guardMessageCount, "sampling guards sends nothing")
        guarded.connected = false
        check(guarded.forwardingContextReadiness["connected"] == false && guarded.forwardingContextReadiness["contextPresent"] == false,
              "disconnected guard is sampled independently")
        guarded.connected = true
        guarded.appInForeground = false
        check(guarded.forwardingContextReadiness["appInForeground"] == false, "foreground intent guard observed")
        guarded.appInForeground = true
        UIApplication.shared.applicationState = .inactive
        check(guarded.forwardingContextReadiness["applicationActive"] == false && guarded.forwardingContextReadiness["contextMatchesForwardingState"] == false,
              "inactive sample cannot imply current context authority")
        UIApplication.shared.applicationState = .active
        let guardPeer = guarded.connection
        guarded.connection = nil
        check(guarded.forwardingContextReadiness["connectionPresent"] == false && guarded.forwardingContextReadiness["authenticatedPeerMatchesConnection"] == false,
              "two absent peers are never reported as authenticated match")
        guarded.connection = guardPeer
        guarded.authenticated = false
        check(guarded.forwardingContextReadiness["authenticatedPeerMatchesConnection"] == false && guarded.forwardingContextReadiness["desiredIdentityPresent"] == false,
              "authentication and identity absence remain booleans")
        guarded.authenticated = true
        for key in ["auth.sessionPresent", "auth.idPresent", "auth.macInfoSaved", "auth.verifiedInfoPresent",
                    "auth.verifiedIDMatches", "auth.savedMacPresent", "auth.pinPresent", "auth.verifiedPinMatches",
                    "auth.tlsPeerPinMatches", "auth.trustedRoute"] {
            check(guarded.forwardingContextReadiness[key] == true, "valid fixture reports " + key)
        }
        let savedSession = guarded.session
        guarded.session = nil
        check(guarded.forwardingContextReadiness["auth.sessionPresent"] == false && guarded.forwardingContextReadiness["auth.idPresent"] == false,
              "absent session cannot masquerade as matching IDs")
        guarded.session = savedSession
        guarded.session?.macID = nil
        check(guarded.forwardingContextReadiness["auth.idPresent"] == false && guarded.forwardingContextReadiness["auth.verifiedIDMatches"] == false,
              "absent ID is distinguished")
        guarded.session = savedSession
        guarded.macInfoSaved = false
        check(guarded.forwardingContextReadiness["auth.macInfoSaved"] == false, "saved-info flag observed")
        guarded.macInfoSaved = true
        let verified = guarded.macInfoVerified
        guarded.macInfoVerified = nil
        check(guarded.forwardingContextReadiness["auth.verifiedInfoPresent"] == false && guarded.forwardingContextReadiness["auth.verifiedPinMatches"] == false,
              "absent verified information cannot match a pin")
        guarded.macInfoVerified = (StreamClient.Session(macID: "other"), Data(repeating: 8, count: 32))
        check(guarded.forwardingContextReadiness["auth.verifiedIDMatches"] == false && guarded.forwardingContextReadiness["auth.verifiedPinMatches"] == false,
              "verified ID and pin mismatches are separate booleans")
        guarded.macInfoVerified = verified
        let savedMacs = guarded.savedMacs
        guarded.savedMacs = []
        check(guarded.forwardingContextReadiness["auth.savedMacPresent"] == false && guarded.forwardingContextReadiness["auth.pinPresent"] == false,
              "absent saved Mac and pin distinguished")
        guarded.savedMacs = [.init(macID: "fixture", fingerprintData: nil)]
        check(guarded.forwardingContextReadiness["auth.savedMacPresent"] == true && guarded.forwardingContextReadiness["auth.pinPresent"] == false,
              "saved Mac without pin distinguished")
        guarded.savedMacs = savedMacs
        guarded.connection?.peerPin = nil
        check(guarded.forwardingContextReadiness["auth.tlsPeerPinMatches"] == false, "TLS pin absence observed without exporting it")
        guarded.connection?.peerPin = Data(repeating: 7, count: 32)
        guarded.session?.route.isRemote = false
        check(guarded.forwardingContextReadiness["auth.trustedRoute"] == false, "untrusted route observed")
        guarded.session?.home = .saved(pin: Data(repeating: 7, count: 32))
        check(guarded.forwardingContextReadiness["auth.trustedRoute"] == true, "existing saved home route observed")
        guarded.session = savedSession
        guarded.desiredAudio.set(.microphone, desired: true)
        guarded.desiredAudio.set(.playback, desired: true)
        let beforeStop = guarded.forwardingContextReadiness
        let heldObserve = guarded.command()
        guarded.cancelDesiredAudioRequest()
        let stopEvent = IPadMicrophoneDiagnostics.records.last { $0.0 == "explicit_stop_requested" }
        let stopAuth = IPadMicrophoneDiagnostics.records.last { $0.0 == "explicit_stop_requested_auth" }
        check(stopEvent?.1.merging(stopAuth!.1, uniquingKeysWith: { _, next in next }) == beforeStop.mapValues { String($0) } &&
              stopEvent?.2 == stopAuth?.2 && stopEvent?.1.count == 14 && stopAuth?.1.count == 10,
              "same-sample stop events preserve all 24 guards under one diagnostic ID")
        check(!guarded.desiredAudio.selection.microphone && !guarded.desiredAudio.selection.playback &&
              guarded.desiredAudioStore.selection(for: guarded.desiredAudioIdentity!) == .init(),
              "diagnostic stop retains existing OFF storage contract")
        check(guarded.microphoneAttempts == 0 && guarded.subscriptions.filter(\.enabled).isEmpty,
              "guard sampling and stop cannot start media")
        let sendsBefore = IPadMicrophoneDiagnostics.records.filter { $0.0 == "explicit_stop_first_217_submitted" }.count
        guarded.receive(try .init(requestID: heldObserve.requestID, operation: .observe,
            catalog: catalog(live, intent: 1, binding: 1), result: nil))
        let sendEvents = IPadMicrophoneDiagnostics.records.filter { $0.0 == "explicit_stop_first_217_submitted" }
        let sendAuth = IPadMicrophoneDiagnostics.records.last { $0.0 == "explicit_stop_first_217_submitted_auth" }
        check(sendEvents.count == sendsBefore + 1 && sendEvents.last?.1["isStopSubmission"] == "true" &&
              guarded.command().intent?.action == .stop && guarded.audioForwardingStopDiagnostic == nil,
              "existing send boundary records the first stop control once and retires diagnostic")
        check(sendEvents.last!.1.values.allSatisfy { $0 == "true" || $0 == "false" },
              "stop send event contains boolean values only")
        check(sendEvents.last?.1.count == 16 && sendAuth?.1.count == 10 && sendEvents.last?.2 == sendAuth?.2 && sendAuth?.2 == stopAuth?.2,
              "first217 main and auth events preserve 26 fields with the same stop diagnostic ID")
        guarded.desiredAudio.sourceWillChange()
        check(guarded.forwardingContextReadiness["desiredScopePresent"] == false && guarded.forwardingContextReadiness["sourceNotNone"] == false &&
              guarded.forwardingContextReadiness["contextMatchesForwardingState"] == false,
              "retired scope reports absence without inherited context authority")
        // A synthetic Node intent25 has optional Sentry=false and required local mute=true.
        let optional = StreamClient()
        optional.desiredAudioSetConnection(optional.connection)
        let optionalPeer = optional.connection!
        var optionalList = list
        optionalList.audioPrivacy = .init(version:2,protected:true)
        optionalList.microphone = nil
        optional.fixtureObserve(optionalList)
        let optionalObserve = optional.command()
        let nodeIntent = try AudioForwardingSnapshot.Intent(pairedDeviceId:device,intentId:UUID(),intentRevision:.init(1),
            intentGeneration:UUID(),inputDesired:true,outputDesired:true,sentryDesired:false,localMutedDesired:true)
        let nodeSnapshot = try AudioForwardingSnapshot(revision:.init(25),intent:nodeIntent,binding:nil)
        let nodeState = try AudioForwardingState(requestID:optionalObserve.requestID,operation:.observe,
            catalog:catalog(nodeSnapshot,intent:1,binding:0),result:nil)
        let nodeMessage = StreamMessage(kind:.forwardingState,timestamp:0,isKeyframe:false,payload:Wire.encode(nodeState))
        optionalPeer.forwardingInFlight = 0
        _ = optional.receiveAudioForwarding(StreamMessage.parseHeader(nodeMessage.serialized().prefix(StreamMessage.headerLength))!,nodeMessage.payload,from:optionalPeer)
        await flush()
        check(optional.audioForwarding.phase == .ready && optional.audioForwardingWire == nil && optional.audioForwarding.pendingRequestID == nil,
              "actual218 sentryfalse observe decodes and drains its matched wire")
        check(optional.audioForwarding.lastReceivedSummary?["operation"] == "observe" && optional.audioForwarding.snapshot?.intent?.sentryDesired == false,
              "sentryfalse current shape is preserved without inferred protection")
        optional.desiredAudio.set(.microphone,desired:true);optional.desiredAudio.set(.playback,desired:true)
        optional.cancelDesiredAudioRequest()
        let optionalStop = optional.command(), stopIntent = optionalStop.intent!
        check(optionalStop.operation == .submit && stopIntent.action == .stop && stopIntent.expectedRevision.value == 25
              && stopIntent.intentId == nodeIntent.intentId && !stopIntent.inputDesired && !stopIntent.outputDesired,
              "actual OFF creates one correlated stop against observed intent25")
        let offIntent = try AudioForwardingSnapshot.Intent(pairedDeviceId:device,intentId:stopIntent.intentId,intentRevision:stopIntent.intentRevision,
            intentGeneration:nodeIntent.intentGeneration,inputDesired:false,outputDesired:false,sentryDesired:false,localMutedDesired:true)
        let offBinding = AudioForwardingBinding(pairedDeviceId:device,intentGeneration:offIntent.intentGeneration,bindingEpoch:UUID(),
            transportId:stopIntent.transportId,transportKind:.native,operationId:optionalStop.requestID,phase:.off,configuration:configuration)
        let offSnapshot = try AudioForwardingSnapshot(revision:.init(26),intent:offIntent,binding:offBinding)
        let offState = try AudioForwardingState(requestID:optionalStop.requestID,operation:.submit,catalog:nil,result:.accepted(offSnapshot))
        let offMessage = StreamMessage(kind:.forwardingState,timestamp:0,isKeyframe:false,payload:Wire.encode(offState))
        optionalPeer.forwardingInFlight = 0
        _ = optional.receiveAudioForwarding(StreamMessage.parseHeader(offMessage.serialized().prefix(StreamMessage.headerLength))!,offMessage.payload,from:optionalPeer)
        await flush()
        check(optional.audioForwarding.phase == .ready && optional.audioForwarding.binding?.phase == .off && optional.audioForwardingWire == nil,
              "actual matching sentryfalse off ACK finishes normal stop")
        check(!optional.desiredAudio.selection.microphone && !optional.desiredAudio.selection.playback
              && !optional.desiredAudioPermits(.microphone) && !optional.desiredAudioPermits(.playback),
              "normal stop keeps both media gates closed")
        let unprotected = StreamClient()
        unprotected.desiredAudioSetConnection(unprotected.connection)
        var unprotectedList = optionalList;unprotectedList.audioPrivacy = .init(version:2,protected:false)
        unprotected.fixtureObserve(unprotectedList)
        let unprotectedObserve = unprotected.command()
        unprotected.receive(try .init(requestID:unprotectedObserve.requestID,operation:.observe,catalog:catalog(empty,intent:0,binding:0),result:nil))
        unprotected.setDesiredAudioSelection(.init(microphone:true,playback:true))
        let startRequest = unprotected.command(), sr = startRequest.intent!
        let activeIntent = try AudioForwardingSnapshot.Intent(pairedDeviceId:device,intentId:sr.intentId,intentRevision:sr.intentRevision,
            intentGeneration:UUID(),inputDesired:true,outputDesired:true,sentryDesired:false,localMutedDesired:true)
        let activeBinding = AudioForwardingBinding(pairedDeviceId:device,intentGeneration:activeIntent.intentGeneration,bindingEpoch:UUID(),
            transportId:sr.transportId,transportKind:.native,operationId:startRequest.requestID,phase:.active,configuration:configuration)
        let activeSnapshot = try AudioForwardingSnapshot(revision:.init(sr.expectedRevision.value+1),intent:activeIntent,binding:activeBinding)
        unprotected.receive(try .init(requestID:startRequest.requestID,operation:.submit,catalog:nil,result:.accepted(activeSnapshot)))
        check(unprotected.audioForwarding.phase == .active && unprotected.desiredAudio.privacy != .protected,
              "optional Sentry is independent of actual privacy protection")
        check(!unprotected.desiredAudioPermits(.microphone) && !unprotected.desiredAudioPermits(.playback)
              && unprotected.microphoneAttempts == 0 && unprotected.subscriptions.filter(\.enabled).isEmpty,
              "accepted active sentryfalse never permits unprotected microphone or playback")
        unprotected.clock.now = 3.01
        check(!unprotected.audioForwarding.permits(.playback,in:unprotected.audioForwardingContext!,now:unprotected.clock.now),
              "optional Sentry does not extend the existing three-second lease")
        print("실제 iPad 어댑터·가짜 전송/시계 검사 \(checks)개 통과. 실제 미디어·기기·네트워크 없음.")
    }
}
