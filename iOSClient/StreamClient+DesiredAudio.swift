#if os(iOS)
import Foundation
import AVFoundation
import UIKit
import Network
import StreamProtocol

extension StreamClient {
    var desiredAudioIdentity: IPadDesiredAudio.Identity? {
        guard let trusted = audioRouteTrustedMac else { return nil }
        return IPadDesiredAudio.Identity(macID: trusted.macID, pin: trusted.pin)
    }

    func desiredAudioSetConnection(_ connection: NWConnection?) {
        providerCallSetConnection(connection)
        let peer = connection.map(ObjectIdentifier.init)
        guard desiredAudio.peer != peer else { return }
        retireAudioForwardingWire(unless: peer)
        suspendAudioForwarding()
        audioForwardingDevice = nil
        audioAdmission.bind(peer)
        audioCatalogAdmission = nil
        desiredAudio.bind(peer)
        audioPrivacyState = nil
        finishPendingAudioPermission()
        desiredAudioSelection = desiredAudio.selection
        audioAutomaticDirections.removeAll()
    }

    func admitAudioCatalog(_ ticket: IPadAudioAdmission.Ticket?) -> Bool {
        guard audioAdmission.isCurrent(ticket) else { return false }
        if audioCatalogAdmission != ticket { suspendDesiredAudio() }
        audioCatalogAdmission = ticket
        return true
    }

    func desiredAudioObserve(_ list: WindowList, from peer: NWConnection) {
        guard connection === peer else { return }
        observeIPadProviderCalls(list, from: peer)
        let oldScope = desiredAudio.scope
        audioForwardingCatalogAt = audioForwardingNow
        audioPrivacyState = list.audioPrivacy
        desiredAudio.observe(list, microphone: microphonePolicy.scope, from: ObjectIdentifier(peer))
        if oldScope != desiredAudio.scope { suspendDesiredAudio() }
        if desiredAudio.privacy != .protected {
            audioForwarding.block()
            applyAudioForwarding(nil)
            suspendDesiredAudio()
        }
        if audioForwarding.phase == .active, audioForwarding.durable?.selection.microphone == true,
           oldScope?.microphone != nil, desiredAudio.scope?.microphone == nil {
            audioForwarding.block()
            applyAudioForwarding(nil)
        }
    }

    func suspendDesiredAudio(preserveManualPermission: Bool = false) {
        let keepAuthorization = preserveManualPermission &&
            (audioRouteAuthorization != nil || !audioAutomaticDirections.contains(.microphone))
        if !keepAuthorization {
            audioRouteAuthorization = nil
        }
        if keepAuthorization && microphonePolicy.phase == .authorizing { desiredAudio.invalidate(.playback) }
        else { desiredAudio.invalidate() }
        audioAutomaticDirections.removeAll()
        remoteAudioControl.backgrounded()
        if keepAuthorization && microphonePolicy.phase == .authorizing { microphoneFrames.close() }
        else { applyMicrophone(microphonePolicy.backgrounded()) }
        if !keepAuthorization { finishPendingAudioPermission() }
    }

    func finishPendingAudioPermission() {
        let finish = audioPendingMicrophonePermission
        audioPendingMicrophonePermission = nil
        finish?()
    }

    func setDesiredAudio(_ direction: IPadDesiredAudio.Direction, enabled: Bool) {
        var selection = desiredAudio.selection
        selection[direction] = enabled
        setDesiredAudioSelection(selection)
    }

    func setDesiredAudioSelection(_ selection: IPadDesiredAudio.Selection) {
        refreshDesiredAudioIdentity()
        guard audioForwardingContext != nil || (!selection.microphone && !selection.playback) else { return }
        audioRouteAuthorization = nil
        suspendDesiredAudio()
        for direction in IPadDesiredAudio.Direction.allCases {
            desiredAudio.set(direction, desired: selection[direction])
        }
        desiredAudioSelection = desiredAudio.selection
        if let identity = desiredAudio.identity {
            desiredAudioStore.save(desiredAudio.selection, for: identity)
        }
        selectAudioForwarding(selection)
        reconcileDesiredAudio()
    }

    func cancelDesiredAudioRequest() {
        setDesiredAudioSelection(.init())
    }

    private func refreshDesiredAudioIdentity() {
        let identity = desiredAudioIdentity
        guard identity != desiredAudio.identity else { return }
        suspendDesiredAudio()
        desiredAudio.authenticate(identity, saved: identity.map(desiredAudioStore.selection) ?? .init())
        desiredAudioSelection = desiredAudio.selection
    }

    func reconcileDesiredAudio() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connected, let connection, desiredAudio.peer == ObjectIdentifier(connection) else { return }
        if audioResumeObserver == nil { audioResumeObserver = IPadAudioResumeObserver(client: self) }
        refreshDesiredAudioIdentity()
        let foreground = appInForeground && UIApplication.shared.applicationState == .active
        desiredAudio.observeForeground(foreground)
        reconcileAudioForwarding()
        desiredAudio.observeMicrophoneAuthorization(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        guard foreground else {
            if remoteAudioStatus.requested || microphonePolicy.phase.canStop || microphoneCaptureToken != nil {
                suspendDesiredAudio(preserveManualPermission: UIApplication.shared.applicationState == .inactive)
            }
            return
        }
        for direction in Array(audioAutomaticDirections) where !desiredAudioPermits(direction) {
            audioAutomaticDirections.remove(direction)
            if direction == .microphone { applyMicrophone(microphonePolicy.backgrounded()) }
            else { remoteAudioControl.sourceWillChange() }
        }
        let starts = desiredAudio.takeAutomaticStarts(foreground: foreground,
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            microphoneCanStart: audioForwardingPermits(.microphone) && microphonePolicy.canStart && microphoneCleanupProblem == nil && IPadAudioSession.shared.microphoneAvailable,
            playbackCanStart: audioForwardingPermits(.playback) && remoteAudioStatus.available && !remoteAudioStatus.requested)
        for direction in starts { startDesiredAudio(direction, automatically: true) }
    }

    func desiredAudioPermits(_ direction: IPadDesiredAudio.Direction) -> Bool {
        guard audioForwardingPermits(direction) else { return false }
        guard let current = connection,
              audioAdmission.ticket(for: ObjectIdentifier(current)) == audioCatalogAdmission,
              audioCatalogAdmission != nil else { return false }
        let automatic = audioAutomaticDirections.contains(direction)
        guard let connection, desiredAudio.peer == ObjectIdentifier(connection), desiredAudio.selection[direction] else { return false }
        guard desiredAudio.identity == desiredAudioIdentity else { return false }
        return desiredAudio.permits(direction, automatic: automatic,
            foreground: appInForeground && UIApplication.shared.applicationState == .active,
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }

    private func startDesiredAudio(_ direction: IPadDesiredAudio.Direction, automatically: Bool) {
        if automatically { audioAutomaticDirections.insert(direction) }
        guard desiredAudioPermits(direction) else { return }
        switch direction {
        case .microphone:
            guard microphonePolicy.canStart, microphoneCleanupProblem == nil else { return }
            applyMicrophone(microphonePolicy.toggle(), allowPermissionPrompt: !automatically)
        case .playback:
            guard remoteAudioStatus.available, !remoteAudioStatus.requested else { return }
            beginRemoteAudioRequest()
        }
    }
}

final class IPadAudioResumeObserver {
    private var observers: [NSObjectProtocol] = []

    init(client: StreamClient) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak client] _ in
                client?.suspendAudioForwarding(discardDraft: false)
                client?.desiredAudio.observeForeground(false)
                client?.suspendDesiredAudio(preserveManualPermission: true)
            })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak client] _ in
                client?.suspendAudioForwarding()
                client?.desiredAudio.observeForeground(false)
                client?.suspendDesiredAudio()
            })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak client] _ in
                DispatchQueue.main.async { [weak client] in
                    let permission = client?.audioPendingMicrophonePermission
                    client?.audioPendingMicrophonePermission = nil
                    permission?()
                    client?.reconcileDesiredAudio()
                }
            })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
#endif
