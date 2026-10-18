#if os(iOS)
import Foundation
import AVFoundation
import UIKit
import StreamProtocol

extension StreamClient {
    var audioRouteCapabilities: IPadAudioRoutePolicy.Capabilities {
        IPadAudioRoutePolicy.Capabilities(microphone: connected && microphonePolicy.scope != nil,
                                          playback: connected && active != .none && remoteAudioStatus.available)
    }

    var audioRoutePlaybackUnavailableReason: String? {
        if !connected { return "Mac 연결 후 이 iPad의 출력 장치를 선택할 수 있습니다." }
        if active == .none { return "Mac 화면을 선택한 뒤 이 iPad에서 소리를 재생할 수 있습니다." }
        if !remoteAudioStatus.available { return "현재 Mac 연결에서 오디오 재생 지원을 알리지 않았습니다. Mac의 화면·시스템 오디오 기록 권한과 CCR Sill 버전을 확인하세요." }
        return nil
    }

    var audioRouteSelection: IPadAudioRoutePolicy.Selection {
        IPadAudioRoutePolicy.Selection(input: microphonePhase.canStop ? .iPadMicrophone : .off,
                                      output: remoteAudioStatus.requested ? .iPadPlayback : .off)
    }

    var audioRouteContext: IPadAudioRoutePolicy.Context? {
        guard connected, let connection else { return nil }
        return IPadAudioRoutePolicy.Context(peer: ObjectIdentifier(connection), source: active,
                                           microphone: microphonePolicy.scope)
    }

    var audioRouteTrustedMac: IPadAudioRouteAcknowledgments.Identity? {
        guard authenticatedMacAudioRoutePeer != nil, let id = session?.macID,
              let pin = savedMacs.first(where: { $0.macID == id })?.fingerprintData else { return nil }
        return IPadAudioRouteAcknowledgments.Identity(macID: id, pin: pin)
    }

    @MainActor func offerInitialAudioRoutes() {
        if !audioRouteAcknowledgmentEnabled {
            if audioRouteOffer.offerForPhone(connected: connected, hasSource: active != .none,
                                             foreground: appInForeground) { presentAudioRoutes() }
            return
        }
        let identity = audioRouteTrustedMac
        if audioRouteOffer.offer(identity: identity,
                                 acknowledged: identity.map(audioRouteAcknowledgments.contains) ?? false,
                                 hasSource: active != .none,
                                 supported: audioRouteCapabilities.microphone || audioRouteCapabilities.playback,
                                 foreground: appInForeground && audioRouteAppActive) {
            presentAudioRoutes()
        }
    }

    @MainActor func showAudioRoutes() {
        guard connected, appInForeground else { return }
        if audioRouteAcknowledgmentEnabled { audioRouteOffer.openedManually(identity: audioRouteTrustedMac) }
        else { _ = audioRouteOffer.offerForPhone(connected: connected, hasSource: true, foreground: appInForeground) }
        presentAudioRoutes()
    }

    private func presentAudioRoutes() {
        audioRoutePresentation = audioRouteContext.map {
            IPadAudioRoutePolicy.Presentation(identity: audioRouteTrustedMac, context: $0)
        }
        audioRouteChooserPresented = true
    }

    @MainActor func dismissAudioRoutesByUser() {
        acknowledgeAudioRoutes(identity: audioRoutePresentation?.identity, context: audioRoutePresentation?.context)
        audioRouteAuthorization = nil
        audioRouteChooserPresented = false
    }

    @MainActor func acknowledgeAudioRoutes(identity: IPadAudioRouteAcknowledgments.Identity?,
                                context: IPadAudioRoutePolicy.Context?) {
        guard audioRouteAcknowledgmentEnabled, appInForeground, audioRouteAppActive,
              let identity, identity == audioRouteTrustedMac,
              let context, context.peer == audioRouteContext?.peer else { return }
        audioRouteAcknowledgments.acknowledge(identity)
    }

    @MainActor func applyAudioRoutes(_ selection: IPadAudioRoutePolicy.Selection,
                          context: IPadAudioRoutePolicy.Context?) async throws {
        audioRouteAuthorization = nil
        guard connected, appInForeground, audioRouteAppActive, let context, context == audioRouteContext else {
            throw IPadAudioRoutePolicy.Problem.changedConnection
        }
        var actions = try IPadAudioRoutePolicy.actions(for: selection, capabilities: audioRouteCapabilities,
                                                      current: audioRouteSelection,
                                                      canStartMicrophone: microphonePolicy.canStart,
                                                      cleanupRequired: microphoneCleanupProblem != nil)
        if actions.microphone == true {
            let authorization = IPadAudioRoutePolicy.Authorization(context: context)
            audioRouteAuthorization = authorization
            defer { if audioRouteAuthorization == authorization { audioRouteAuthorization = nil } }
            let diagnostic = IPadMicrophoneDiagnostics.shared.attempt(authorization.id)
            diagnostic.record("routes_permission_requested")
            let allowed = await requestAudioRouteMicrophonePermission()
            guard !Task.isCancelled, audioRouteAuthorization == authorization,
                  connected, appInForeground, audioRouteAppActive, context == audioRouteContext else {
                diagnostic.record("routes_permission_cancelled")
                throw IPadAudioRoutePolicy.Problem.changedConnection
            }
            diagnostic.record("routes_permission_result", ["allowed": String(allowed)])
            guard allowed else { throw IPadAudioRoutePolicy.Problem.permissionDenied }
            actions = try IPadAudioRoutePolicy.actions(for: selection, capabilities: audioRouteCapabilities,
                current: audioRouteSelection, canStartMicrophone: microphonePolicy.canStart,
                cleanupRequired: microphoneCleanupProblem != nil)
        }
        if let enabled = actions.microphone, !enabled { toggleIPadMicrophone() }
        if let enabled = actions.microphone, enabled { toggleIPadMicrophone() }
        if actions.playback != nil { toggleRemoteAudio() }
    }

    @MainActor var audioRouteAppActive: Bool { UIApplication.shared.applicationState == .active }
    @MainActor var audioRouteAcknowledgmentEnabled: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor func requestAudioRouteMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
#endif
