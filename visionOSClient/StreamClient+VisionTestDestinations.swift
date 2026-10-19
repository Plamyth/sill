#if os(visionOS) || VISION_TEST_DESTINATION_CHECKS
import Foundation
import Network
import StreamProtocol

extension StreamClient {
    func bindVisionTestDestinations(to peer: NWConnection?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard visionTestDestinationPeer !== peer else { return }
        visionTestDestinationPeer = peer
        visionTestDestinationGeneration = UUID()
        visionTestDestinations.bind(nil)
    }

    func reconcileVisionTestDestinationAuthentication() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let binding = visionTestDestinations.binding else { return }
        guard let peer = connection, visionTestDestinationPeer === peer,
              authenticatedVisionMacAudioPeer == ObjectIdentifier(peer),
              session?.macID == binding.peerID else {
            visionTestDestinations.bind(nil)
            return
        }
    }

    func observeVisionTestDestinations(_ list: WindowList, from peer: NWConnection) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connection === peer else { return }
        bindVisionTestDestinations(to: peer)
        guard authenticatedVisionMacAudioPeer == ObjectIdentifier(peer), let macID = session?.macID else {
            visionTestDestinations.bind(nil)
            return
        }
        let binding = VisionTestDestinations.PeerBinding(peerID: macID, generation: visionTestDestinationGeneration)
        visionTestDestinations.bind(binding)
        visionTestDestinations.observe(list.testDestinations?.catalog, from: binding)
    }

    func invalidateVisionTestDestinations(from peer: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === peer else { return }
            self.visionTestDestinations.invalidate()
        }
    }
}
#endif
