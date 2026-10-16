#if os(iOS)
import Foundation
import Network
import StreamProtocol

final class MacAudioRouteTransport {
    private let link: SessionLink
    private var submissions: [UUID: SessionLink.Submission] = [:]

    init(link: SessionLink) { self.link = link }

    func fetch(on peer: NWConnection) -> Bool {
        let message = StreamMessage(kind: .fetchAudioRoutes, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: false, payload: Data())
        return link.send(message.serialized(), onlyOn: peer)
    }

    func change(_ request: AudioRouteSelection, on peer: NWConnection,
                cancelled: @escaping (UUID) -> Void) -> Bool {
        let submission = SessionLink.Submission { outcome in
            if outcome == .cancelled { cancelled(request.requestID) }
        }
        submissions[request.requestID] = submission
        let message = StreamMessage(kind: .changeAudioRoute, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: false, payload: Wire.encode(request))
        return link.send(message.serialized(), onlyOn: peer, submission: submission)
    }

    func finish(_ requestID: UUID) {
        guard let submission = submissions.removeValue(forKey: requestID) else { return }
        link.cancel(submission)
    }

    func reset() {
        let pending = submissions.values
        submissions.removeAll()
        for submission in pending { link.cancel(submission) }
    }
}
#endif
