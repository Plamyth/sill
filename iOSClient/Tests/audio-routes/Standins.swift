import Foundation

final class RoutePeer {}

final class StreamClient {
    var connected = true
    var appInForeground = true
    var active = StreamSource.desktop
    var connection: RoutePeer? = RoutePeer()
    var audioRouteChooserPresented = false
    var audioRouteOffer = IPadAudioRouteOffer()
    var microphonePolicy = IPadMicrophonePolicy()
    var microphoneCleanupProblem: String?
    var microphonePhase: IPadMicrophonePolicy.Phase { microphonePolicy.phase }
    var remoteAudioStatus: IPadRemoteAudioController.Status { remoteAudioControl.status }
    var playbackRequests: [RemoteAudioSubscription] = []
    var microphoneEffects: [IPadMicrophonePolicy.Effect] = []
    var played = 0
    var stopped = 0
    lazy var remoteAudioControl = IPadRemoteAudioController(
        send: { [unowned self] _, request in playbackRequests.append(request) },
        stop: { [unowned self] in stopped += 1 },
        play: { [unowned self] _ in played += 1 }, changed: { _ in })

    func toggleRemoteAudio() { remoteAudioControl.toggle() }
    func toggleIPadMicrophone() { microphoneEffects += microphonePolicy.toggle() }

    func advertise(playback: Bool = true, microphone: Bool = true) {
        let id = ObjectIdentifier(connection!)
        remoteAudioControl.setConnection(id)
        _ = microphonePolicy.setConnection(id)
        let generation = UUID()
        let epoch = VideoEpoch(generation: generation.uuidString, source: active,
                               geometry: .init(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1)
        let capability = MicrophoneCapability(peer: UUID(), destination: UUID(), generation: UUID())
        let list = WindowList(macName: "Mac", windows: [], active: active,
                              remoteAudio: playback ? 1 : nil,
                              inputGeneration: generation.uuidString, videoEpoch: epoch,
                              microphone: microphone ? capability : nil)
        remoteAudioControl.receive(list, from: id)
        microphoneEffects += microphonePolicy.observe(list, from: id)
    }

    var microphoneRequests: [MicrophoneControl] {
        microphoneEffects.compactMap { if case .send(_, let request) = $0 { request } else { nil } }
    }
}

// EXTRACTED_ADAPTER
