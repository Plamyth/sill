#if os(iOS)
import Foundation
import StreamProtocol

extension StreamClient {
    var audioRouteCapabilities: IPadAudioRoutePolicy.Capabilities {
        IPadAudioRoutePolicy.Capabilities(microphone: connected && microphonePolicy.scope != nil,
                                          playback: connected && active != .none && remoteAudioStatus.available)
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

    func offerInitialAudioRoutes() {
        if audioRouteOffer.offer(connected: connected, hasSource: active != .none, foreground: appInForeground) {
            audioRouteChooserPresented = true
        }
    }

    func showAudioRoutes() {
        guard connected, appInForeground else { return }
        _ = audioRouteOffer.offer(connected: connected, hasSource: true, foreground: appInForeground)
        audioRouteChooserPresented = true
    }

    func applyAudioRoutes(_ selection: IPadAudioRoutePolicy.Selection,
                          context: IPadAudioRoutePolicy.Context?) throws {
        guard connected, appInForeground, let context, context == audioRouteContext else {
            throw IPadAudioRoutePolicy.Problem.changedConnection
        }
        let actions = try IPadAudioRoutePolicy.actions(for: selection, capabilities: audioRouteCapabilities,
                                                      current: audioRouteSelection,
                                                      canStartMicrophone: microphonePolicy.canStart,
                                                      cleanupRequired: microphoneCleanupProblem != nil)
        if let enabled = actions.microphone, !enabled { toggleIPadMicrophone() }
        if actions.playback != nil { toggleRemoteAudio() }
        if let enabled = actions.microphone, enabled { toggleIPadMicrophone() }
    }
}
#endif
