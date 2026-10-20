import Foundation
import Synchronization

final class VisionAudioGain: @unchecked Sendable {
    struct Ticket: Equatable, Sendable {
        let id: UUID
        let owner: UUID

        fileprivate init(owner: UUID) {
            id = UUID()
            self.owner = owner
        }
    }

    private struct Adjustment {
        let ticket: Ticket
        let start: Double
    }

    static let shared = VisionAudioGain()

    private let gain = Atomic<UInt64>(Double(1).bitPattern)
    private let control = NSLock()
    private var adjustment: Adjustment?

    private init() {}

    var value: Double { Double(bitPattern: gain.load(ordering: .relaxed)) }
    var renderGain: Float { Float(value) }

    func begin(owner: UUID) -> Ticket {
        control.withLock {
            let ticket = Ticket(owner: owner)
            adjustment = Adjustment(ticket: ticket, start: value)
            return ticket
        }
    }

    func preview(ticket: Ticket, degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        return control.withLock {
            guard let adjustment, adjustment.ticket == ticket else { return nil }
            let next = min(1, max(0, adjustment.start + degrees / 180))
            gain.store(next.bitPattern, ordering: .relaxed)
            return next
        }
    }

    @discardableResult
    func end(ticket: Ticket, commit: Bool) -> Bool {
        control.withLock {
            guard let adjustment, adjustment.ticket == ticket else { return false }
            if !commit { gain.store(adjustment.start.bitPattern, ordering: .relaxed) }
            self.adjustment = nil
            return true
        }
    }
}
