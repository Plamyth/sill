import Foundation

@main struct InputQueueChecks {
    @MainActor static func main() async {
        final class Peer {}
        let a = Peer(), b = Peer()
        let idA = ObjectIdentifier(a), idB = ObjectIdentifier(b)
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        func settle() async { for _ in 0..<30 { await Task.yield() } }
        let queue = PeerInputQueue()
        var trace: [String] = []
        var gate: CheckedContinuation<Void, Never>?
        queue.enqueue(peer: idA) { turn in
            trace.append("focus-A")
            await withCheckedContinuation { gate = $0 }
            if !turn.cancelled { trace.append("down-A") }
        }
        await settle()
        queue.enqueue(peer: idA) { turn in if !turn.cancelled { trace.append("up-A") } }
        queue.enqueue(peer: idB) { turn in if !turn.cancelled { trace.append("down-B") } }
        check(trace == ["focus-A"], "new input cannot overtake activation wait")
        gate?.resume(); gate = nil
        await queue.drain()
        check(trace == ["focus-A", "down-A", "up-A", "down-B"], "rapid down/up preserved across activation")
        trace = []
        queue.enqueue(peer: idA) { turn in
            await withCheckedContinuation { gate = $0 }
            if !turn.cancelled { trace.append("old-A") }
        }
        await settle()
        queue.enqueue(peer: idA) { turn in if !turn.cancelled { trace.append("queued-old-A") } }
        queue.enqueue(peer: idB) { turn in if !turn.cancelled { trace.append("B") } }
        queue.cancel(peer: idA)
        queue.enqueue(peer: idA) { turn in if !turn.cancelled { trace.append("new-A") } }
        gate?.resume(); gate = nil
        await queue.drain()
        check(trace == ["B", "new-A"], "source cancellation affects only that peer and old turns")
        let bounded = PeerInputQueue(capacity: 1)
        bounded.enqueue(peer: idA) { turn in await withCheckedContinuation { gate = $0 }; if !turn.cancelled { trace.append("old") } }
        await settle()
        check(bounded.enqueue(peer: idB) { _ in trace.append("retained-B") }, "bounded queue admits remaining slot")
        check(!bounded.enqueue(peer: idA) { _ in trace.append("overflow") }, "bounded queue refuses overflow")
        bounded.cancel(peer: idA)
        gate?.resume(); gate = nil
        await bounded.drain()
        check(trace.last == "retained-B" && !trace.contains("overflow"), "overflow/cancel does not evict another peer")
        print("PASS \(checks) production OS input queue checks; no OS input effects")
    }
}
