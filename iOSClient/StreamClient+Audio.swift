#if !os(visionOS)
import Foundation
import Network
import StreamProtocol

extension StreamClient {
    func toggleRemoteAudio() {
        #if os(iOS)
        audioRouteAuthorization = nil
        #endif
        remoteAudioControl.toggle()
        guard case .requesting(let requestID) = remoteAudioControl.status, let c = connection else { return }
        let origin = ObjectIdentifier(c)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.remoteAudioControl.expire(requestID, from: origin)
        }
    }

    func receiveRemoteAudio(_ header: StreamHeader, _ data: Data, from origin: NWConnection) -> Bool {
        guard header.kind == .audio || header.kind == .remoteAudioState else { return false }
        DispatchQueue.main.async {
            guard self.connection === origin else { return }
            let peer = ObjectIdentifier(origin)
            if header.kind == .audio {
                self.remoteAudioControl.receiveAudio(data, from: peer)
            } else if let state = Wire.decode(RemoteAudioState.self, from: data) {
                self.remoteAudioControl.receive(state, from: peer)
            }
        }
        return true
    }

    func sendRemoteAudio(_ request: RemoteAudioSubscription, to peer: ObjectIdentifier) {
        guard let c = connection, ObjectIdentifier(c) == peer else { return }
        IPadMicrophoneDiagnostics.shared.attempt(request.requestID)
            .record(request.enabled ? "playback_requested" : "playback_stopped")
        let message = StreamMessage(kind: .remoteAudioControl, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: false, payload: Wire.encode(request))
        // SessionLink migrates queued input on handover. Audio consent must stay on its original peer.
        c.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
            if let error { self?.connectionLost(c, error: error) }
        })
    }
}
#endif
