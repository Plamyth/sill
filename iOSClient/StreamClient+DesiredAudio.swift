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
        let peer = connection.map(ObjectIdentifier.init)
        guard desiredAudio.peer != peer else { return }
        desiredAudio.bind(peer)
        audioPrivacyState = nil
        audioPendingMicrophonePermission = nil
        desiredAudioSelection = desiredAudio.selection
        audioAutomaticDirections.removeAll()
        audioPresentation.reset()
    }

    func desiredAudioObserve(_ list: WindowList, from peer: NWConnection) {
        guard connection === peer else { return }
        let oldScope = desiredAudio.scope
        audioPrivacyState = list.audioPrivacy
        desiredAudio.observe(list, microphone: microphonePolicy.scope, from: ObjectIdentifier(peer))
        if oldScope != desiredAudio.scope { audioPresentation.reset() }
        if desiredAudio.privacy != .protected { suspendDesiredAudio() }
    }

    func suspendDesiredAudio(preserveManualPermission: Bool = false) {
        let keepAuthorization = preserveManualPermission && !audioAutomaticDirections.contains(.microphone)
        if !keepAuthorization {
            audioRouteAuthorization = nil
            audioPendingMicrophonePermission = nil
        }
        if keepAuthorization && microphonePolicy.phase == .authorizing { desiredAudio.invalidate(.playback) }
        else { desiredAudio.invalidate() }
        audioAutomaticDirections.removeAll()
        remoteAudioControl.backgrounded()
        if keepAuthorization && microphonePolicy.phase == .authorizing { microphoneFrames.close() }
        else { applyMicrophone(microphonePolicy.backgrounded()) }
    }

    func setDesiredAudio(_ direction: IPadDesiredAudio.Direction, enabled: Bool) {
        refreshDesiredAudioIdentity()
        audioRouteAuthorization = nil
        if direction == .microphone { audioPendingMicrophonePermission = nil }
        desiredAudio.set(direction, desired: enabled)
        desiredAudioSelection = desiredAudio.selection
        if let identity = desiredAudio.identity {
            desiredAudioStore.save(desiredAudio.selection, for: identity)
        }
        audioAutomaticDirections.remove(direction)
        guard enabled else {
            if direction == .microphone { applyMicrophone(microphonePolicy.backgrounded()) }
            else { remoteAudioControl.sourceWillChange() }
            return
        }
        desiredAudio.markManualAttempt(direction)
        startDesiredAudio(direction, automatically: false)
    }

    func cancelDesiredAudioRequest() {
        setDesiredAudio(.microphone, enabled: false)
        setDesiredAudio(.playback, enabled: false)
    }

    private func refreshDesiredAudioIdentity() {
        let identity = desiredAudioIdentity
        guard identity != desiredAudio.identity else { return }
        suspendDesiredAudio()
        desiredAudio.authenticate(identity, saved: identity.map(desiredAudioStore.selection) ?? .init())
        desiredAudioSelection = desiredAudio.selection
    }

    func reconcileDesiredAudio(keyframe: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connected, let connection, desiredAudio.peer == ObjectIdentifier(connection) else { return }
        if audioResumeObserver == nil { audioResumeObserver = IPadAudioResumeObserver(client: self) }
        refreshDesiredAudioIdentity()
        let gate = readDesiredAudioPresentation(keyframe: keyframe)
        let foreground = appInForeground && UIApplication.shared.applicationState == .active
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
            presented: gate.presented, fullControl: gate.fullControl,
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            microphoneCanStart: microphonePolicy.canStart && microphoneCleanupProblem == nil && IPadAudioSession.shared.microphoneAvailable,
            playbackCanStart: remoteAudioStatus.available && !remoteAudioStatus.requested)
        for direction in starts { startDesiredAudio(direction, automatically: true) }
    }

    func desiredAudioPermits(_ direction: IPadDesiredAudio.Direction) -> Bool {
        let automatic = audioAutomaticDirections.contains(direction)
        guard let connection, desiredAudio.peer == ObjectIdentifier(connection), desiredAudio.selection[direction] else { return false }
        if automatic && desiredAudio.identity != desiredAudioIdentity { return false }
        let gate = automatic ? readDesiredAudioPresentation() : (presented: false, fullControl: false)
        return desiredAudio.permits(direction, automatic: automatic,
            foreground: appInForeground && UIApplication.shared.applicationState == .active,
            presented: gate.presented, fullControl: gate.fullControl,
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

    private func readDesiredAudioPresentation(keyframe: Bool = false) -> (presented: Bool, fullControl: Bool) {
        let view = displayView
        guard let layer = view.layer as? AVSampleBufferDisplayLayer else { return (false, false) }
        let window = view.window
        let attached = window?.isKeyWindow == true && window?.windowScene?.activationState == .foregroundActive &&
            !view.isHidden && view.alpha > 0
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
        let overlay = window?.hitTest(point, with: nil) as? InputOverlayView
        let scope = desiredAudio.scope
        let fullControl = attached && overlay?.window === window && overlay?.superview === view.superview &&
            overlay?.videoSize == videoSize &&
            videoSize.width > 0 && videoSize.height > 0 && !inputPaused && !moveUnderWay &&
            active == scope?.source && desiredAudioInputGeneration.flatMap(UUID.init(uuidString:)) == scope?.generation &&
            overlay != nil
        let presented = audioPresentation.observe(scope: scope, ready: layer.isReadyForDisplay,
            keyframe: keyframe, healthy: layer.status != .failed && !layer.requiresFlushToResumeDecoding,
            attached: attached)
        return (presented, fullControl)
    }
}

final class IPadAudioResumeObserver {
    private var observers: [NSObjectProtocol] = []

    init(client: StreamClient) {
        let center = NotificationCenter.default
        let layer = client.displayView.layer
        for name in [NSNotification.Name.AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                     .AVSampleBufferDisplayLayerFailedToDecode,
                     .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange] {
            observers.append(center.addObserver(forName: name, object: layer, queue: .main) { [weak client] _ in
                client?.reconcileDesiredAudio()
            })
        }
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak client] _ in client?.suspendDesiredAudio(preserveManualPermission: true) })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak client] _ in client?.suspendDesiredAudio() })
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
