import Foundation
import StreamProtocol

/// Source intent belongs to one connection incarnation. No state is shared with another peer.
struct PeerStreamState {
    struct Ticket: Equatable {
        let incarnation: UUID
        let operation: UUID
        let source: StreamSource
        let display: DisplaySelection?
    }

    let incarnation: UUID
    private(set) var sequence: UInt64 = 0
    private(set) var source: StreamSource = .none
    private(set) var display: DisplaySelection?
    private(set) var epoch: VideoEpoch?
    private(set) var pending: Ticket?
    private(set) var closed = false
    private(set) var failure: String?
    var revision: String { "\(incarnation.uuidString):\(sequence)" }
    var generation: String { epoch?.generation ?? idleGeneration }
    private var idleGeneration = UUID().uuidString

    init(incarnation: UUID = UUID()) { self.incarnation = incarnation }

    mutating func request(_ source: StreamSource, display: DisplaySelection?,
                          origin: SourceRequest.Origin?, revision: String?,
                          inventory: DisplayInventory) -> Ticket? {
        guard !closed else { return nil }
        if origin == .automatic {
            guard source == .desktop, self.source == .none, pending == nil,
                  revision == self.revision else { return nil }
        }
        if source == .desktop {
            guard let display, inventory.contains(display) else { return nil }
        } else if display != nil { return nil }
        sequence &+= 1
        let ticket = Ticket(incarnation: incarnation, operation: UUID(), source: source, display: display)
        pending = ticket
        self.source = .none
        epoch = nil
        idleGeneration = UUID().uuidString
        failure = nil
        return ticket
    }

    func isCurrent(_ ticket: Ticket) -> Bool { !closed && ticket == pending && ticket.incarnation == incarnation }

    mutating func commit(_ ticket: Ticket, epoch: VideoEpoch?) -> Bool {
        guard isCurrent(ticket) else { return false }
        if ticket.source == .none {
            guard epoch == nil else { return false }
        } else {
            guard let epoch, epoch.isValid, epoch.source == ticket.source else { return false }
        }
        source = ticket.source
        display = ticket.display
        self.epoch = epoch
        pending = nil
        failure = nil
        return true
    }

    mutating func fail(_ ticket: Ticket, reason: String) {
        guard isCurrent(ticket) else { return }
        pending = nil
        source = .none
        display = nil
        epoch = nil
        failure = reason
    }

    mutating func close() {
        closed = true
        pending = nil
        source = .none
        display = nil
        epoch = nil
        idleGeneration = UUID().uuidString
    }

    func accepts(generation: String?, epoch: UUID?) -> Bool {
        guard !closed, pending == nil, let current = self.epoch else { return false }
        return generation == current.generation && epoch == current.id
    }
}
