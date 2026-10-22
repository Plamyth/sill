import Foundation

/// Serializes explicit OS effects across peers; source selection never enters this queue.
@MainActor
final class PeerInputQueue {
    final class Turn {
        fileprivate(set) var cancelled = false
    }
    private struct Entry {
        let peer: ObjectIdentifier
        let turn: Turn
        let work: @MainActor (Turn) async -> Void
    }
    private let capacity: Int
    private var pending: [Entry] = []
    private var current: Entry?
    private var worker: Task<Void, Never>?

    init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    @discardableResult
    func enqueue(peer: ObjectIdentifier, _ work: @escaping @MainActor (Turn) async -> Void) -> Bool {
        guard pending.count < capacity else { return false }
        pending.append(Entry(peer: peer, turn: Turn(), work: work))
        guard worker == nil else { return true }
        worker = Task { [weak self] in await self?.run() }
        return true
    }

    func cancel(peer: ObjectIdentifier) {
        if current?.peer == peer { current?.turn.cancelled = true }
        for entry in pending where entry.peer == peer { entry.turn.cancelled = true }
        pending.removeAll { $0.peer == peer }
    }

    func drain() async { await worker?.value }

    private func run() async {
        defer { current = nil; worker = nil }
        while !pending.isEmpty {
            let entry = pending.removeFirst()
            current = entry
            if !entry.turn.cancelled { await entry.work(entry.turn) }
        }
    }
}
