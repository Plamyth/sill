#if os(iOS)
import Foundation
import Network
import StreamProtocol

extension StreamClient {
    var authenticatedMacAudioRoutePeer: ObjectIdentifier? {
        guard connected, let connection, let session, let id = session.macID,
              macInfoSaved, let verified = macInfoVerified,
              verified.info.macID == id,
              let saved = savedMacs.first(where: { $0.macID == id }),
              let pin = saved.fingerprintData, verified.fingerprint == pin,
              RemoteTLS.peerFingerprint(connection) == pin,
              session.route.isRemote || session.home == .saved(pin: pin) else { return nil }
        return ObjectIdentifier(connection)
    }

    func fetchMacAudioRoutes() {
        guard let connection, let peer = authenticatedMacAudioRoutePeer, macAudioRoutes.peer == peer,
              macAudioRoutes.pending == nil else { return }
        _ = macRouteTransport.fetch(on: connection)
    }

    func selectMacAudioRoutes(inputUID: String?, outputUID: String?,
                              displayed: MacAudioRouteSession.CatalogToken) throws {
        guard let connection, let peer = authenticatedMacAudioRoutePeer, macAudioRoutes.peer == peer else {
            throw IPadAudioRoutePolicy.Problem.changedConnection
        }
        let request = try macAudioRoutes.request(displayed: displayed, inputUID: inputUID, outputUID: outputUID)
        let accepted = macRouteTransport.change(request, on: connection) { [weak self] requestID in
            self?.macAudioRoutes.expire(requestID, on: peer)
        }
        guard accepted else {
            macRouteTransport.finish(request.requestID)
            macAudioRoutes.expire(request.requestID, on: peer)
            throw IPadAudioRoutePolicy.Problem.changedConnection
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.macRouteTransport.finish(request.requestID)
            self?.macAudioRoutes.expire(request.requestID, on: peer)
        }
    }

    func receiveMacAudioRoutes(_ data: Data, from connection: NWConnection) {
        guard data.count <= AudioRoutingPolicy.maxStatePayload,
              let state = Wire.decode(AudioRouteState.self, from: data) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection,
                  self.authenticatedMacAudioRoutePeer == ObjectIdentifier(connection) else { return }
            let requestID = self.macAudioRoutes.pending?.requestID
            self.macAudioRoutes.receive(state, from: ObjectIdentifier(connection))
            if let requestID, self.macAudioRoutes.pending?.requestID != requestID {
                self.macRouteTransport.finish(requestID)
            }
        }
    }
}
#endif
