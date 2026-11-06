#if os(iOS)
import Foundation
import Network
import UIKit
import AVFoundation
import StreamProtocol

extension StreamClient {
    struct ForwardingExchange {
        let context: IPadAudioForwarding.Context
        let requestID: UUID
        let operation: AudioForwardingOperation
    }

    func retireAudioForwardingWire(unless peer: ObjectIdentifier?) {
        guard audioForwardingWire?.context.peer != peer else { return }
        audioForwardingWire = nil
        audioForwardingWireTimeout?.cancel(); audioForwardingWireTimeout = nil
    }

    var audioForwardingNow: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    var audioForwardingContext: IPadAudioForwarding.Context? {
        guard connected, appInForeground, UIApplication.shared.applicationState == .active,
              let connection, authenticatedMacAudioRoutePeer == ObjectIdentifier(connection),
              let mac = desiredAudioIdentity, let device = audioForwardingDevice,
              let scope = desiredAudio.scope, scope.source != .none else { return nil }
        return .init(peer: ObjectIdentifier(connection), mac: mac, device: device,
                     source: scope.source, generation: scope.generation, videoEpoch: scope.videoEpoch,
                     lifecycle: audioForwardingLocalGeneration)
    }

    var forwardingContextReadiness: [String: Bool] {
        let peer = connection.map(ObjectIdentifier.init)
        let context = audioForwardingContext
        let currentSession = session
        let id = currentSession?.macID
        let verified = macInfoVerified
        let saved = id.flatMap { id in savedMacs.first { $0.macID == id } }
        let pin = saved?.fingerprintData
        let peerPin = connection.flatMap { RemoteTLS.peerFingerprint($0) }
        let trustedRoute = currentSession.map { session in
            session.route.isRemote || (pin.map { session.home == .saved(pin: $0) } ?? false)
        } ?? false
        return [
            "connected": connected,
            "appInForeground": appInForeground,
            "applicationActive": UIApplication.shared.applicationState == .active,
            "connectionPresent": peer != nil,
            "authenticatedPeerMatchesConnection": peer != nil && authenticatedMacAudioRoutePeer == peer,
            "auth.sessionPresent": currentSession != nil,
            "auth.idPresent": id != nil,
            "auth.macInfoSaved": macInfoSaved,
            "auth.verifiedInfoPresent": verified != nil,
            "auth.verifiedIDMatches": id != nil && verified?.info.macID == id,
            "auth.savedMacPresent": saved != nil,
            "auth.pinPresent": pin != nil,
            "auth.verifiedPinMatches": pin != nil && verified?.fingerprint == pin,
            "auth.tlsPeerPinMatches": pin != nil && peerPin == pin,
            "auth.trustedRoute": trustedRoute,
            "desiredIdentityPresent": desiredAudioIdentity != nil,
            "forwardingDevicePresent": audioForwardingDevice != nil,
            "desiredScopePresent": desiredAudio.scope != nil,
            "sourceNotNone": desiredAudio.scope.map { $0.source != .none } ?? false,
            "contextPresent": context != nil,
            "contextMatchesForwardingState": context != nil && audioForwarding.context == context,
            "wirePresent": audioForwardingWire != nil,
            "pendingPresent": audioForwarding.pendingRequestID != nil,
            "forwardingFaulted": audioAdmission.forwardingFaulted,
        ]
    }

    func reconcileAudioForwarding() {
        if audioForwardingDevice == nil, let identity = DeviceIdentity.existing() {
            audioForwardingDevice = AudioForwardingDeviceID(fingerprint: identity.fingerprint)
        }
        retireAudioForwardingWire(unless: connection.map(ObjectIdentifier.init))
        let context = audioForwardingContext
        if audioAdmission.forwardingFaulted { audioForwarding.block(reason: "admission_faulted", now: audioForwardingNow) }
        let command: AudioForwardingControl?
        if context != audioForwarding.context {
            audioForwardingSubmissionAt = nil
            command = audioForwarding.connect(context,
                durable: context.flatMap { desiredAudioStore.forwarding(for: $0.mac) },
                desired: desiredAudio.selection, observeImmediately: audioForwardingWire == nil, now: audioForwardingNow)
        } else if audioForwardingWire == nil, audioForwarding.phase == .unknown {
            command = audioForwarding.begin(now: audioForwardingNow)
        } else { command = audioForwarding.advance(now: audioForwardingNow) }
        applyAudioForwarding(command)
    }

    func selectAudioForwarding(_ selection: IPadDesiredAudio.Selection) {
        // Read only the paired identity. Selection must never generate or replace its key.
        audioForwardingDevice = DeviceIdentity.existing().flatMap { AudioForwardingDeviceID(fingerprint: $0.fingerprint) }
        audioAdmission.resetForwardingFault()
        reconcileAudioForwarding()
        guard let context = audioForwardingContext else { return }
        applyAudioForwarding(audioForwarding.select(selection, in: context, now: audioForwardingNow,
                                                     deferToTransport: audioForwardingWire != nil))
    }

    func suspendAudioForwarding(discardDraft: Bool = true) {
        if discardDraft { audioForwardingLocalGeneration = UUID() }
        audioForwardingWake?.cancel(); audioForwardingWake = nil
        _ = audioForwarding.connect(nil, durable: audioForwarding.durable, now: audioForwardingNow)
        if audioForwardingPhase != audioForwarding.phase { audioForwardingPhase = audioForwarding.phase }
        audioAdmission.forwarding(peer: desiredAudio.peer, microphone: false, playback: false, deadline: nil)
    }

    func audioForwardingPermits(_ direction: IPadDesiredAudio.Direction) -> Bool {
        audioForwardingPermissionFailure(direction) == nil
    }

    func audioForwardingPermissionFailure(_ direction: IPadDesiredAudio.Direction) -> String? {
        guard desiredAudio.sessionPermits(direction) else { return "desired_session_not_permitted" }
        guard desiredAudio.selection == audioForwarding.durable?.selection else { return "desired_selection_mismatch" }
        guard desiredAudio.privacy == .protected else { return "privacy_not_protected" }
        guard let context = audioForwardingContext else { return "forwarding_context_missing" }
        if let failure = audioForwarding.permissionFailure(direction, in: context, now: audioForwardingNow) {
            return "forwarding_" + failure
        }
        if direction == .microphone {
            guard let submitted = audioForwardingSubmissionAt else { return "submission_time_missing" }
            guard let catalog = audioForwardingCatalogAt else { return "catalog_time_missing" }
            guard catalog >= submitted else { return "catalog_predates_submission" }
            guard microphonePolicy.scope != nil else { return "microphone_scope_missing" }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return "microphone_permission_denied" }
        }
        return nil
    }

    func applyAudioForwarding(_ command: AudioForwardingControl?) {
        audioForwardingWake?.cancel(); audioForwardingWake = nil
        if let command, audioForwardingWire == nil, let connection, let context = audioForwarding.context,
           context == audioForwardingContext, ObjectIdentifier(connection) == context.peer {
            let sentAt = audioForwardingNow
            guard audioForwarding.markSent(command.requestID, now: sentAt) else {
                audioForwarding.block(reason: "mark_sent_failed", now: sentAt); applyAudioForwarding(nil); return
            }
            if command.operation == .submit { audioForwardingSubmissionAt = sentAt }
            let payload = Wire.encode(command)
            guard payload.count <= 4096 else { audioForwarding.block(reason: "control_payload_oversized", now: audioForwardingNow); applyAudioForwarding(nil); return }
            let message = StreamMessage(kind: .forwardingControl, timestamp: Date().timeIntervalSince1970,
                                        isKeyframe: false, payload: payload)
            audioForwardingWire = ForwardingExchange(context: context, requestID: command.requestID, operation: command.operation)
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.audioForwardingWire?.requestID == command.requestID else { return }
                self.audioForwarding.block(reason: "wire_response_timeout", now: self.audioForwardingNow); self.applyAudioForwarding(nil)
                // The peer may still be executing this exchange. Only a matching response,
                // a send failure or replacement of the connection can drain the wire slot.
            }
            audioForwardingWireTimeout?.cancel(); audioForwardingWireTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
            connection.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === connection,
                          self.audioForwardingWire?.requestID == command.requestID else { return }
                    self.audioForwardingWire = nil
                    self.audioForwardingWireTimeout?.cancel(); self.audioForwardingWireTimeout = nil
                    self.audioForwarding.block(reason: "wire_send_failed", now: self.audioForwardingNow); self.applyAudioForwarding(nil)
                }
            })
            if let observation = audioForwardingStopDiagnostic {
                audioForwardingStopDiagnostic = nil
                if observation.context == context {
                    var fields = forwardingContextReadiness
                    fields["isObserve"] = command.operation == .observe
                    fields["isStopSubmission"] = command.intent?.action == .stop
                    IPadMicrophoneDiagnostics.shared.attempt(observation.id)
                        .recordForwardingGuards("explicit_stop_first_217_submitted", fields)
                }
            }
        }
        if audioForwardingPhase != audioForwarding.phase { audioForwardingPhase = audioForwarding.phase }
        let microphoneFailure = audioForwardingPermissionFailure(.microphone)
        let microphone = microphoneFailure == nil
        let playback = audioForwardingPermits(.playback)
        audioAdmission.forwarding(peer: desiredAudio.peer, microphone: microphone, playback: playback,
                                  deadline: audioForwarding.mediaDeadline)
        if let peer = desiredAudio.peer { audioCatalogAdmission = audioAdmission.ticket(for: peer) }
        if !microphone && (microphonePolicy.phase.canStop || microphoneCaptureToken != nil) {
            if let attempt = microphonePolicy.startRequestID {
                var fields = audioForwarding.firstBlockSummary ?? ["block.reason": "unknown"]
                fields["permissionFailure"] = microphoneFailure ?? "unknown"
                fields["stopPath"] = "applyAudioForwarding.microphonePolicy.backgrounded"
                fields["stopNow"] = String(audioForwardingNow)
                fields["forwardingPhase"] = String(describing: audioForwarding.phase)
                fields["phaseCanStop"] = String(microphonePolicy.phase.canStop)
                fields["captureTokenPresent"] = String(microphoneCaptureToken != nil)
                IPadMicrophoneDiagnostics.shared.attempt(attempt).record("forwarding_microphone_stop", fields)
            }
            applyMicrophone(microphonePolicy.backgrounded())
        }
        if !playback && remoteAudioStatus.requested { remoteAudioControl.backgrounded() }
        reconcileIPadProviderCall()
        guard let wake = audioForwarding.wakeAt, audioForwarding.context == audioForwardingContext,
              audioForwarding.context != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconcileAudioForwarding()
            self.reconcileDesiredAudio()
        }
        audioForwardingWake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, wake - audioForwardingNow), execute: work)
    }

    func receiveAudioForwarding(_ header: StreamHeader, _ data: Data, from peer: NWConnection) -> Bool {
        guard header.kind == .forwardingState else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === peer else { return }
            guard data.count <= 16384, let state = Wire.decode(AudioForwardingState.self, from: data) else {
                self.audioForwarding.block(reason: "state_decode_failed", now: self.audioForwardingNow); self.applyAudioForwarding(nil); return
            }
            self.acceptAudioForwarding(state, from: peer)
        }
        return true
    }
    func acceptAudioForwarding(_ state: AudioForwardingState, from peer: NWConnection) {
        guard connection === peer, let wire = audioForwardingWire,
              wire.context.peer == ObjectIdentifier(peer), wire.requestID == state.requestID,
              wire.operation == state.operation else {
            audioForwarding.block(reason: "wire_response_mismatch", now: audioForwardingNow); applyAudioForwarding(nil); return
        }
        audioForwardingWire = nil
        audioForwardingWireTimeout?.cancel(); audioForwardingWireTimeout = nil
        if let context = audioForwardingContext, context == wire.context,
           audioForwarding.context == context, audioForwarding.pendingRequestID == state.requestID {
            let previous = audioForwarding.durable
            let command = audioForwarding.receive(state, from: context, now: audioForwardingNow)
            if let durable = audioForwarding.durable, durable != previous {
                desiredAudioStore.saveForwarding(durable, for: context.mac)
            }
            applyAudioForwarding(command)
        }
        // A retired reply drains only. A new observe is created at its actual send time.
        reconcileDesiredAudio()
    }

}
#endif
