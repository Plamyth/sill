import Foundation
import StreamProtocol

struct VisionPresentation {
    struct Ticket: Equatable {
        let id = UUID()
        let epoch: VideoEpoch
        let peer: ObjectIdentifier
        let layer: ObjectIdentifier
    }

    enum State: Equatable {
        case closed
        case waitingForIDR(Ticket)
        case waitingForFramework(Ticket)
        case ready(Ticket)
    }

    private(set) var state = State.closed

    var ticket: Ticket? {
        switch state {
        case .closed: return nil
        case .waitingForIDR(let t), .waitingForFramework(let t), .ready(let t): return t
        }
    }

    var admitted: Ticket? {
        if case .ready(let ticket) = state { return ticket }
        return nil
    }

    mutating func begin(epoch: VideoEpoch, peer: ObjectIdentifier, layer: ObjectIdentifier) {
        state = .waitingForIDR(Ticket(epoch: epoch, peer: peer, layer: layer))
    }

    mutating func enqueuedIDR(_ ticket: Ticket) {
        guard state == .waitingForIDR(ticket) else { return }
        state = .waitingForFramework(ticket)
    }

    mutating func observe(_ ticket: Ticket, ready: Bool, healthy: Bool, attached: Bool, foreground: Bool) {
        guard self.ticket == ticket else { return }
        guard healthy, attached, foreground else { state = .closed; return }
        switch state {
        case .waitingForFramework where ready: state = .ready(ticket)
        case .ready where !ready: state = .closed
        default: break
        }
    }

    mutating func revoke() { state = .closed }
}
