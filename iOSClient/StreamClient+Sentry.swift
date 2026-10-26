#if os(iOS)
import Foundation
import Network
import StreamProtocol

extension StreamClient {
    func sentryBinding(on peer: NWConnection) -> IPadSentryControl.Binding? {
        guard connection === peer, connected, let session, let id = session.macID,
              let saved = savedMacs.first(where: { $0.macID == id }),
              saved.revoked != true, saved.newKey != true,
              let pin = saved.fingerprintData, MacID.make(fingerprint: pin) == id,
              session.route.isRemote || session.home == .saved(pin: pin),
              RemoteTLS.negotiatedALPN(peer) == RemoteTLS.sessionALPN,
              RemoteTLS.peerFingerprint(peer) == pin,
              let device = DeviceIdentity.existing(), device.fingerprint.count == 32 else { return nil }
        return IPadSentryControl.Binding(macID: id, hostPin: pin, deviceFingerprint: device.fingerprint)
    }

    func observeIPadSentry(catalog: Data, from peer: NWConnection) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connection === peer else { return }
        let binding = sentryBinding(on: peer)
        guard !sentryControl.isRetired(catalog: catalog, binding: binding, from: ObjectIdentifier(peer)) else { return }
        sentryObservation.observe(catalog: catalog, from: ObjectIdentifier(peer))
        sentryControl.observe(catalog: catalog, observation: sentryObservation,
            binding: binding, from: ObjectIdentifier(peer))
    }

    func setIPadSentry(desired: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let peer = connection else { return }
        guard let packet = sentryControl.perform(desired: desired, binding: sentryBinding(on: peer),
            from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime) else { return }
        sendIPadSentry(packet, to: peer)
    }

    func queryIPadSentry() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let peer = connection else { return }
        guard let packet = sentryControl.query(binding: sentryBinding(on: peer),
            from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime) else { return }
        sendIPadSentry(packet, to: peer)
    }

    private func sendIPadSentry(_ packet: Data, to peer: NWConnection) {
        guard connection === peer, packet.first == IPadSentryControl.requestKind,
              packet.count <= StreamMessage.headerLength + IPadSentryControl.requestCap,
              sentryControl.permits(packet, binding: sentryBinding(on: peer), from: ObjectIdentifier(peer)) else {
            sentryControl.unconfirmed()
            return
        }
        peer.send(content: packet, completion: .contentProcessed { [weak self, weak peer] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self, let peer, self.connection === peer,
                      self.sentryControl.originalRequest == Data(packet.dropFirst(StreamMessage.headerLength)) else { return }
                self.sentryControl.unconfirmed()
            }
        })
    }

    func receiveIPadSentry(_ data: Data, from peer: NWConnection, hostTimestamp: Double? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === peer else { return }
            if let hostTimestamp {
                IPadMicrophoneDiagnostics.shared.received(.sentryState, hostTimestamp: hostTimestamp)
            }
            self.acceptIPadSentryReply(data, from: peer, binding: self.sentryBinding(on: peer))
        }
    }
}
#endif
