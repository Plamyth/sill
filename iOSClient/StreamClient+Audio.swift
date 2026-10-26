#if !os(visionOS)
import Foundation
import Network
import StreamProtocol

extension StreamClient {
    func toggleRemoteAudio() {
        #if os(iOS)
        setDesiredAudio(.playback, enabled: !remoteAudioStatus.requested)
        #else
        beginRemoteAudioRequest()
        #endif
    }

    func beginRemoteAudioRequest() {
        remoteAudioControl.toggle()
        guard case .requesting(let requestID) = remoteAudioControl.status, let c = connection else { return }
        let origin = ObjectIdentifier(c)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.remoteAudioControl.expire(requestID, from: origin)
        }
    }

    func receiveRemoteAudio(_ header: StreamHeader, _ data: Data, from origin: NWConnection) -> Bool {
        guard header.kind == .audio || header.kind == .remoteAudioState else { return false }
        #if os(iOS)
        let admission = audioAdmission.ticket(for: ObjectIdentifier(origin))
        #endif
        DispatchQueue.main.async {
            guard self.connection === origin else { return }
            #if os(iOS)
            IPadMicrophoneDiagnostics.shared.received(header.kind == .audio ? .audioPacket : .remoteAudioState,
                hostTimestamp: header.timestamp)
            guard self.audioAdmission.isCurrent(admission) else { return }
            #endif
            let peer = ObjectIdentifier(origin)
            #if os(iOS)
            guard self.desiredAudioPermits(.playback) else {
                self.remoteAudioControl.sourceWillChange()
                return
            }
            #endif
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
        #if os(iOS)
        if request.enabled && !desiredAudioPermits(.playback) { return }
        observeAudioDiagnostics()
        #endif
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
