struct VisionTransition {
    enum Action { case desktop, disconnect }
    struct Ticket: Equatable { fileprivate let generation: UInt64 }
    private enum State {
        case idle
        case waiting(Ticket, Action)
    }
    private var state = State.idle
    private var generation: UInt64 = 0

    var isPending: Bool { if case .waiting = state { return true }; return false }

    mutating func request(_ action: Action) -> Ticket? {
        if case .waiting(let ticket, _) = state {
            if action == .disconnect { state = .waiting(ticket, .disconnect) }
            return nil
        }
        generation &+= 1
        let ticket = Ticket(generation: generation)
        state = .waiting(ticket, action)
        return ticket
    }

    mutating func settle(_ ticket: Ticket, confirmed: Bool) -> Action? {
        guard case .waiting(let current, let action) = state, current == ticket else { return nil }
        state = .idle
        return confirmed ? action : nil
    }

    mutating func cancel() { state = .idle }
}
