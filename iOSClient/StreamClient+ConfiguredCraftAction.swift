#if os(iOS)
import Foundation
import Network
import UIKit
import AVFoundation
import StreamProtocol

extension StreamClient {
    /// Authentication comes from the existing TLS pin and the registered viewer catalog.
    var configuredCraftIdentity: (IPadConfiguredCraftAction.Context, IPadCraftActionJournal.Owner)? {
        guard let peer = connection, connected, configuredCraftPeer == ObjectIdentifier(peer),
              authenticatedMacAudioRoutePeer == ObjectIdentifier(peer),
              let trusted = desiredAudioIdentity, let device = audioForwardingDevice,
              let catalog = audioForwarding.catalog, catalog.role == .viewer,
              catalog.principal.id == device, catalog.bootstrap.credential.pairedDeviceId == device else { return nil }
        let host = trusted.pin.map { String(format: "%02x", $0) }.joined()
        guard let context = try? IPadConfiguredCraftAction.Context(connection: configuredCraftConnection,
                                                                   hostID: host, deviceID: device.hex) else { return nil }
        return (context, .init(macID: trusted.macID, hostPin: host, deviceID: device.hex))
    }

    var configuredCraftSentryInactive: Bool {
        guard case .reported(let state) = sentryObservation.status else { return false }
        return state.phase == .inactive && !state.requested
    }

    var usesConfiguredCraftAction: Bool {
        configuredCraftAction.unresolved != nil || configuredCraftAction.storageFailed ||
            (providerCall.target == .nativeCodex && configuredCraftCapability == 1 && IPadCraftConnectedControl.legacyAllowsNewAction(providerCall))
    }

    var configuredCraftCanPrepare: Bool {
        configuredCraftAction.canPrepare && configuredCraftSentryInactive &&
            IPadCraftConnectedControl.legacyAllowsNewAction(providerCall) && !inputPaused &&
            appInForeground && UIApplication.shared.applicationState == .active &&
            audioRouteContext != nil && audioForwardingContext != nil
    }

    var configuredCraftAudioReady: Bool {
        let outputReady: Bool
        if case .listening = remoteAudioStatus { outputReady = audioForwardingPermits(.playback) }
        else { outputReady = false }
        return IPadCraftConnectedControl.audioReady(audioForwarding, context: audioForwardingContext,
            selection: desiredAudio.selection, faulted: audioAdmission.forwardingFaulted,
            inputReady: audioForwardingPermits(.microphone) && microphonePhase == .live,
            outputReady: outputReady, now: audioForwardingNow)
    }

    func configuredCraftSetConnection(_ next: NWConnection?) {
        let peer = next.map(ObjectIdentifier.init)
        guard peer != configuredCraftPeer else { return }
        configuredCraftPeer = peer; configuredCraftConnection = UUID(); configuredCraftCapability = nil
        configuredCraftAction.observe(context: nil, owner: nil, capability: nil)
    }

    func reconcileConfiguredCraftAction() {
        let identity = configuredCraftIdentity
        configuredCraftAction.observe(context: identity?.0, owner: identity?.1, capability: configuredCraftCapability)
        if let control = configuredCraftAction.catalogRequest() { sendConfiguredCraftAction(control) }
    }

    func refreshConfiguredCraftCatalog() {
        reconcileConfiguredCraftAction()
        if let control = configuredCraftAction.catalogRequest(explicit: true) { sendConfiguredCraftAction(control) }
    }

    func checkPreviousConfiguredCraftAction() {
        reconcileConfiguredCraftAction()
        if let control = configuredCraftAction.query() { sendConfiguredCraftAction(control) }
    }

    @MainActor func prepareConfiguredCraftAction(userAction: UUID, context displayed: IPadAudioRoutePolicy.Context?) async throws {
        reconcileConfiguredCraftAction()
        guard configuredCraftCanPrepare, let peer = connection, let identity = configuredCraftIdentity, let displayed,
              displayed == audioRouteContext, let forwarding = audioForwardingContext,
              case .reported(let sentry) = sentryObservation.status else { throw IPadAudioRoutePolicy.Problem.changedConnection }
        let selectedGeneration = desiredAudioSelectionGeneration
        var permissionPreparation = IPadCraftPreparation(context: identity.0, selectionGeneration: selectedGeneration)
        let initial = desiredAudioIdentity.map { desiredAudioStore.hasConfirmedSelection(for: $0) } ?? true
        let selected = initial ? audioRouteSelection : .init(input: .iPadMicrophone, output: .iPadPlayback)
        func validateAnchor() throws {
            try Task.checkCancellation()
            guard connection === peer, configuredCraftConnection == identity.0.connection,
                  authenticatedMacAudioRoutePeer == ObjectIdentifier(peer),
                  desiredAudioIdentity?.macID == identity.1.macID,
                  providerCallTrustedHostKey == identity.1.hostPin, audioForwardingDevice?.hex == identity.1.deviceID,
                  configuredCraftSentryInactive,
                  sentryObservation.status == .reported(sentry), !inputPaused,
                  appInForeground, UIApplication.shared.applicationState != .background,
                  audioRouteContext?.peer == displayed.peer, audioRouteContext?.source == displayed.source,
                  desiredAudioSelectionGeneration == selectedGeneration else { throw IPadAudioRoutePolicy.Problem.changedConnection }
        }
        func validate() throws {
            try validateAnchor()
            guard configuredCraftIdentity?.0 == identity.0, configuredCraftIdentity?.1 == identity.1,
                  configuredCraftAction.canPrepare, audioForwardingContext == forwarding else {
                throw IPadAudioRoutePolicy.Problem.changedConnection
            }
        }
        try validate()
        guard let catalogRequest = configuredCraftAction.catalogRequest(explicit: true) else {
            throw IPadAudioRoutePolicy.Problem.changedConnection
        }
        sendConfiguredCraftAction(catalogRequest)
        while configuredCraftAction.exchange?.control.requestId == catalogRequest.requestId {
            try Task.checkCancellation()
            guard configuredCraftIdentity?.0 == identity.0, configuredCraftIdentity?.1 == identity.1,
                  desiredAudioSelectionGeneration == selectedGeneration, configuredCraftSentryInactive,
                  sentryObservation.status == .reported(sentry), UIApplication.shared.applicationState == .active else {
                throw IPadAudioRoutePolicy.Problem.changedConnection
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try validate()
        // Obtain permission before applyAudioRoutes so its asynchronous prompt cannot overwrite a newer choice.
        if selected.input != .off, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            guard permissionPreparation.permits(context: configuredCraftIdentity?.0,
                selectionGeneration: desiredAudioSelectionGeneration, foreground: appInForeground,
                permissionWaiting: true, backgrounded: UIApplication.shared.applicationState == .background,
                sentryInactive: configuredCraftSentryInactive, now: audioForwardingNow) else {
                throw IPadAudioRoutePolicy.Problem.changedConnection
            }
            let authorization = IPadAudioRoutePolicy.Authorization(context: displayed)
            audioRouteAuthorization = authorization
            defer { if audioRouteAuthorization == authorization { audioRouteAuthorization = nil } }
            let allowed = await requestAudioRouteMicrophonePermission()
            if allowed, !Task.isCancelled, audioRouteAuthorization == authorization,
               UIApplication.shared.applicationState == .inactive {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        audioPendingMicrophonePermission = { continuation.resume() }
                    }
                } onCancel: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.audioRouteAuthorization == authorization else { return }
                        self.finishPendingAudioPermission()
                    }
                }
            }
            guard allowed, audioRouteAuthorization == authorization else { throw IPadAudioRoutePolicy.Problem.permissionDenied }
            let freshDeadline = audioForwardingNow + 8
            while configuredCraftIdentity?.0 != identity.0 || !configuredCraftAction.canPrepare {
                try validateAnchor()
                guard audioRouteAuthorization == authorization, UIApplication.shared.applicationState == .active,
                      audioForwardingNow < freshDeadline else { throw IPadAudioRoutePolicy.Problem.changedConnection }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard permissionPreparation.permits(context: configuredCraftIdentity?.0,
                selectionGeneration: desiredAudioSelectionGeneration,
                foreground: appInForeground && UIApplication.shared.applicationState == .active,
                permissionWaiting: false, backgrounded: UIApplication.shared.applicationState == .background,
                sentryInactive: configuredCraftSentryInactive, now: audioForwardingNow) else {
                throw IPadAudioRoutePolicy.Problem.changedConnection
            }
            try validate()
        }
        try validate()
        if !initial || !configuredCraftAudioReady {
            guard let freshRoute = audioRouteContext,
                  displayed.microphone == freshRoute.microphone || (displayed.microphone == nil &&
                    freshRoute.microphone?.source == forwarding.source &&
                    freshRoute.microphone?.inputGeneration == forwarding.generation &&
                    freshRoute.microphone?.videoEpoch == forwarding.videoEpoch) else {
                throw IPadAudioRoutePolicy.Problem.changedConnection
            }
            // This call has no permission suspension: the unchanged selection was checked after authorization.
            guard selected.input == .off || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw IPadAudioRoutePolicy.Problem.permissionDenied
            }
            try await applyAudioRoutes(selected, context: freshRoute)
        }
        try Task.checkCancellation()
        let preparedGeneration = desiredAudioSelectionGeneration
        var preparation = IPadCraftPreparation(context: identity.0, selectionGeneration: preparedGeneration)
        while true {
            try Task.checkCancellation()
            guard configuredCraftIdentity?.1 == identity.1, configuredCraftAction.canPrepare,
                  sentryObservation.status == .reported(sentry),
                  audioRouteContext?.peer == displayed.peer, audioRouteContext?.source == displayed.source,
                  audioForwardingContext == forwarding, selected == audioRouteSelection,
                  !inputPaused, IPadCraftConnectedControl.legacyAllowsNewAction(providerCall),
                  preparation.permits(context: configuredCraftIdentity?.0, selectionGeneration: desiredAudioSelectionGeneration,
                    foreground: appInForeground && UIApplication.shared.applicationState == .active,
                    permissionWaiting: false, sentryInactive: configuredCraftSentryInactive, now: audioForwardingNow) else {
                throw IPadAudioRoutePolicy.Problem.changedConnection
            }
            if configuredCraftAudioReady {
                let epoch = Date().timeIntervalSince1970 * 1000
                guard epoch.isFinite, epoch > 0, epoch <= 9_007_199_254_740_991,
                      let control = configuredCraftAction.invoke(userAction: userAction, heldMilliseconds: 500,
                        issuedAt: Int64(epoch), inputReady: true, outputReady: true, sentryInactive: configuredCraftSentryInactive) else {
                    throw IPadAudioRoutePolicy.Problem.changedConnection
                }
                sendConfiguredCraftAction(control)
                return
            }
            if case .failed(let reason) = microphonePhase { throw NSError(domain: "ConfiguredCraftAction", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
            if case .failed(let reason) = remoteAudioStatus { throw NSError(domain: "ConfiguredCraftAction", code: 2, userInfo: [NSLocalizedDescriptionKey: reason]) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func sendConfiguredCraftAction(_ control: ConfiguredCraftActionControl) {
        guard let peer = connection, let identity = configuredCraftIdentity,
              configuredCraftCapability == 1, configuredCraftAction.owner == identity.1,
              let exchange = configuredCraftAction.exchange, exchange.context == identity.0,
              exchange.control.requestId == control.requestId,
              control.operation != .invoke || (configuredCraftCanSendInvoke && configuredCraftAudioReady),
              let payload = try? JSONEncoder().encode(control),
              (try? ConfiguredCraftActionControl.decode(payload)) != nil else { return }
        peer.send(content: StreamMessage(kind: .configuredCraftActionControl, timestamp: Date().timeIntervalSince1970,
            isKeyframe: false, payload: payload).serialized(), completion: .contentProcessed { [weak self, weak peer] error in
                guard error != nil else { return }
                DispatchQueue.main.async { [weak self, weak peer] in
                    guard let self, let peer, self.connection === peer,
                          self.configuredCraftIdentity?.0 == exchange.context,
                          self.configuredCraftAction.exchange?.control.requestId == control.requestId else { return }
                    // Retire only this exchange. Never stop or cancel a replacement connection.
                    self.configuredCraftAction.observe(context: nil, owner: nil, capability: nil)
                }
            })
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, exchange.deadline - ProcessInfo.processInfo.systemUptime)) { [weak self] in
            guard let self, self.configuredCraftIdentity?.0 == exchange.context else { return }
            self.configuredCraftAction.timeout(requestID: control.requestId)
        }
    }

    private var configuredCraftCanSendInvoke: Bool {
        configuredCraftSentryInactive && !inputPaused && appInForeground &&
            UIApplication.shared.applicationState == .active && IPadCraftConnectedControl.legacyAllowsNewAction(providerCall)
    }

    func receiveConfiguredCraftAction(_ header: StreamHeader, _ data: Data, from peer: NWConnection) -> Bool {
        guard header.kind == .configuredCraftActionState else { return false }
        DispatchQueue.main.async { [weak self, weak peer] in
            guard let self, let peer, self.connection === peer,
                  let identity = self.configuredCraftIdentity,
                  self.configuredCraftAction.owner == identity.1, self.configuredCraftCapability == 1 else { return }
            _ = self.configuredCraftAction.receive(data, from: identity.0)
        }
        return true
    }
}
#endif
