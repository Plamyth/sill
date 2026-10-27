/// Confined to StreamServer's network queue. Tickets also invalidate already-enqueued timers.
struct HomeListenerRecovery {
    enum State: Equatable {
        case idle, running, replacing, waiting(UInt64), stopped
    }

    private(set) var state = State.idle
    private var serial: UInt64 = 0
    private var failures = 0

    var acceptsEvents: Bool { state == .running || state == .replacing }

    mutating func start() -> Bool {
        guard state == .idle else { return false }
        state = .running
        return true
    }

    mutating func replace() {
        guard state != .stopped else { return }
        state = .replacing
    }

    mutating func ready() {
        guard acceptsEvents else { return }
        failures = 0
        state = .running
    }

    mutating func failed() -> (ticket: UInt64, delay: Double)? {
        guard acceptsEvents else { return nil }
        serial &+= 1
        let delays: [Double] = [2, 5, 15, 30]
        let delay = delays[failures]
        failures = min(failures + 1, delays.count - 1)
        state = .waiting(serial)
        return (serial, delay)
    }

    mutating func retry(_ ticket: UInt64) -> Bool {
        guard state == .waiting(ticket) else { return false }
        state = .replacing
        return true
    }

    mutating func stop() { state = .stopped }
}
