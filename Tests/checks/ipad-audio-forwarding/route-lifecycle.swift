import Foundation
import StreamProtocol

@main struct RouteLifecycleChecks {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print((value ? "PASS " : "FAIL ") + label)
            if !value { failures += 1 }
        }
        for event in ["route", "category", "unplug", "interruption", "interruption-no-resume", "reset"] {
            UIApplication.shared.applicationState = .active
            let client = StreamClient(), generation = UUID()
            let peer = client.connection!
            let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
                geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
            let list = WindowList(macName: "fixture", windows: [], active: .desktop, remoteAudio: 1,
                inputGeneration: generation.uuidString, videoEpoch: epoch,
                audioPrivacy: .init(version: 2, protected: true))
            let device = AudioForwardingDeviceID(fingerprint: DeviceIdentity.existing()!.fingerprint)!
            let credential = try AudioForwardingCredential(pairedDeviceId: device,
                pairingGeneration: UUID(), credential: String(repeating: "A", count: 43))
            func catalog(_ snapshot: AudioForwardingSnapshot, intent: UInt64, binding: UInt64) throws -> AudioForwardingCatalog {
                try .init(principal: .init(kind: .cable, id: device, authorizationGeneration: credential.pairingGeneration), role: .viewer,
                    bootstrap: .init(credential: credential, ownCursor: .init(intentRevision: .init(intent), bindingRevision: .init(binding)), snapshot: snapshot))
            }
            let configuration = try AudioForwardingConfiguration(controllerBootId: UUID(), privacyGeneration: UUID(), registryRevision: .init(1),
                members: [.init(participantId: "native.sill", bootId: UUID()), .init(participantId: "s23.audio.relay", bootId: UUID())])
            client.desiredAudioSetConnection(peer)
            _ = client.microphonePolicy.setConnection(ObjectIdentifier(peer))
            client.remoteAudioControl.setConnection(ObjectIdentifier(peer))
            client.fixtureObserve(list)
            let observe = client.command()
            let empty = try AudioForwardingSnapshot(revision: .init(1), intent: nil, binding: nil)
            client.clock.now = 0.1
            client.receive(try .init(requestID: observe.requestID, operation: .observe,
                catalog: catalog(empty, intent: 0, binding: 0), result: nil))
            client.setDesiredAudio(.playback, enabled: true)
            let submit = client.command(), request = submit.intent!
            let intent = try AudioForwardingSnapshot.Intent(pairedDeviceId: device, intentId: request.intentId,
                intentRevision: request.intentRevision, intentGeneration: UUID(), inputDesired: false, outputDesired: true)
            func live(_ request: AudioForwardingIntentRequest, revision: UInt64) throws -> AudioForwardingSnapshot {
                try .init(revision: .init(revision), intent: intent,
                    binding: .init(pairedDeviceId: device, intentGeneration: intent.intentGeneration,
                        bindingEpoch: UUID(), transportId: request.transportId, transportKind: .native,
                        operationId: UUID(), phase: .active, configuration: configuration))
            }
            let original = try live(request, revision: 2)
            client.clock.now = 0.2
            client.receive(try .init(requestID: submit.requestID, operation: .submit, catalog: nil, result: .accepted(original)))
            check(client.subscriptions.filter(\.enabled).count == 1, event + " starts through real 217/218 and 200")
            let ticket = client.audioCatalogAdmission
            let durable = client.audioForwarding.durable
            let messages = peer.messages.count
            let reason: AVAudioSession.RouteChangeReason = event == "category" ? .categoryChange : event == "unplug" ? .oldDeviceUnavailable : .newDeviceAvailable
            if event.hasPrefix("interruption") {
                client.interrupted(Notification(name: AVAudioSession.interruptionNotification,
                    userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue)]))
            } else if event == "reset" {
                client.mediaReset(Notification(name: AVAudioSession.mediaServicesWereResetNotification))
            } else {
                client.routeChanged(Notification(name: AVAudioSession.routeChangeNotification,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: reason.rawValue)]))
            }
            if event == "category" {
                check(client.audioAdmission.withAdmission(ticket, {}) && peer.messages.count == messages,
                    "self categoryChange leaves valid admission and subscription intact")
                continue
            }
            check(!client.audioAdmission.withAdmission(ticket, {}) && client.playbackStops == 1,
                event + " immediately closes old render admission and stops playback")
            check(client.desiredAudio.selection == .init(microphone: false, playback: true) && client.audioForwarding.durable == durable,
                event + " preserves per-direction desire and durable owner")
            client.reconcileDesiredAudio()
            var fresh = client.command()
            check(fresh.operation == .observe && fresh.requestID != submit.requestID,
                event + " requires fresh 217 observation")
            if event == "route" {
                client.routeChanged(Notification(name: AVAudioSession.routeChangeNotification,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: reason.rawValue)]))
                client.clock.now = 0.25
                client.receive(try .init(requestID: fresh.requestID, operation: .observe,
                    catalog: catalog(original, intent: 1, binding: 1), result: nil))
                fresh = client.command()
                check(fresh.operation == .observe && peer.maximumForwardingInFlight == 1,
                    "consecutive route events drain retired proof before one current observation")
            }
            client.clock.now = 0.3
            client.receive(try .init(requestID: fresh.requestID, operation: .observe,
                catalog: catalog(original, intent: 1, binding: 1), result: nil))
            let resume = client.command()
            check(resume.intent?.action == .resume && resume.intent?.intentId == intent.intentId && resume.intent?.intentRevision == intent.intentRevision,
                event + " resumes only own intent without new desired revision")
            client.clock.now = 0.4
            client.receive(try .init(requestID: resume.requestID, operation: .submit, catalog: nil,
                result: .accepted(live(resume.intent!, revision: 3))))
            client.fixtureObserve(list)
            let starts = client.subscriptions.filter(\.enabled).count
            check(event == "route" ? starts == 2 : starts == 1,
                event + (event == "route" ? " fresh active proof recovers playback-only without a new microphone scope" : " cannot reopen output without safe recovery"))
            if event == "unplug" || event == "reset" || event.hasPrefix("interruption") {
                UIApplication.shared.applicationState = .inactive
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
                UIApplication.shared.applicationState = .background
                client.appInForeground = false
                NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
                UIApplication.shared.applicationState = .active
                client.appInForeground = true
                NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                let afterForeground = client.command()
                client.clock.now = 0.5
                client.receive(try .init(requestID: afterForeground.requestID, operation: .observe,
                    catalog: catalog(live(resume.intent!, revision: 3), intent: 1, binding: 2), result: nil))
                let afterResume = client.command()
                client.clock.now = 0.6
                client.receive(try .init(requestID: afterResume.requestID, operation: .submit, catalog: nil,
                    result: .accepted(live(afterResume.intent!, revision: 4))))
                check(client.subscriptions.filter(\.enabled).count == 1,
                    event + " foreground and fresh proof cannot override the unresolved OS pause")
                if event.hasPrefix("interruption") {
                    let shouldResume = event == "interruption"
                    let ended = Notification(name: AVAudioSession.interruptionNotification,
                        userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
                            AVAudioSessionInterruptionOptionKey: NSNumber(value: shouldResume ? 1 : 0)])
                    client.interrupted(ended)
                    let endedObserve = client.command()
                    client.clock.now = 0.7
                    client.receive(try .init(requestID: endedObserve.requestID, operation: .observe,
                        catalog: catalog(live(afterResume.intent!, revision: 4), intent: 1, binding: 3), result: nil))
                    let endedResume = client.command()
                    client.clock.now = 0.8
                    client.receive(try .init(requestID: endedResume.requestID, operation: .submit, catalog: nil,
                        result: .accepted(live(endedResume.intent!, revision: 5))))
                    check(client.subscriptions.filter(\.enabled).count == (shouldResume ? 2 : 1),
                        "interruption end respects shouldResume and requires fresh active proof")
                    let beforeDuplicate = peer.messages.count
                    client.interrupted(ended)
                    check(peer.messages.count == beforeDuplicate, "duplicate interruption end cannot renew media")
                }
                if event != "interruption" {
                    client.setDesiredAudio(.microphone, enabled: false)
                    check(!client.desiredAudio.sessionPermits(.playback), "microphone OFF cannot confirm paused output")
                    client.setDesiredAudio(.playback, enabled: true)
                    check(client.desiredAudio.sessionPermits(.playback) && client.subscriptions.filter(\.enabled).count == 1,
                        "explicit output confirmation clears its pause but still waits for new common proof")
                }
            }
            client.audioForwardingWake?.cancel()
            client.audioForwardingWireTimeout?.cancel()
            client.audioResumeObserver = nil
        }
        if failures > 0 { print("FAIL route lifecycle \(failures) assertions"); exit(1) }
        print("PASS route lifecycle adapter. Controlled OS/media, no view or physical audio acceptance.")
    }
}
