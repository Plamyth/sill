import Foundation

@MainActor
final class FakeCapture {
    private(set) var active = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stopCalls = 0
    private(set) var startCalls = 0

    func start() {
        startCalls += 1
        active = true
    }

    func stop() async {
        stopCalls += 1
        await withCheckedContinuation { stopWaiters.append($0) }
        active = false
    }

    func finishStop() {
        precondition(!stopWaiters.isEmpty)
        stopWaiters.removeFirst().resume()
    }

    var waitingStops: Int { stopWaiters.count }
}

@MainActor
final class FakeDelayedCapture {
    private(set) var active = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stopCalls = 0

    func start() async -> Bool {
        await withCheckedContinuation { startWaiters.append($0) }
        active = true
        return true
    }

    func finishStart() {
        precondition(!startWaiters.isEmpty)
        startWaiters.removeFirst().resume()
    }

    func stop() async {
        stopCalls += 1
        guard active else { return } // stream nil; capture queue drain completes
        await withCheckedContinuation { stopWaiters.append($0) }
        active = false
    }

    func finishStop() {
        precondition(!stopWaiters.isEmpty)
        stopWaiters.removeFirst().resume()
    }

    var pendingStarts: Int { startWaiters.count }
    var pendingStops: Int { stopWaiters.count }
}

@main
struct Check {
    @MainActor static func main() async {
        let capture = FakeCapture()
        var schedules = 0
        var gate: RemoteAudioCaptureLifecycle!
        gate = RemoteAudioCaptureLifecycle(onCleared: {
            schedules += 1
            if schedules == 1 { gate.scheduleStop { await capture.stop() } }
        })

        // A OFF schedules S0. B ON waits S0. Its completion is followed by
        // A OFF scheduling S1 before B resumes. B must not start through S1.
        capture.start()
        gate.scheduleStop { await capture.stop() }
        var bEnabled = true
        let b = Task { @MainActor in
            if await gate.waitToStart(if: { bEnabled }) { capture.start() }
        }
        for _ in 0..<100 where capture.waitingStops == 0 { await Task.yield() }
        precondition(capture.waitingStops == 1, "S0 did not reach fake capture")
        capture.finishStop()
        for _ in 0..<100 where capture.waitingStops == 0 { await Task.yield() }
        precondition(capture.waitingStops == 1, "S1 did not replace S0")
        precondition(capture.startCalls == 1, "B started while S1 was pending")
        // B OFF increments its action while S1 is draining. Its pending ON
        // must not create a new capture after S1 has stopped.
        bEnabled = false
        capture.finishStop()
        await b.value
        precondition(capture.startCalls == 1, "superseded B started capture")
        precondition(!capture.active, "capture remains active after B OFF")

        // A fresh ON can still start after the stop chain finishes.
        let freshAllowed = await gate.waitToStart(if: { true })
        precondition(freshAllowed)
        capture.start()
        precondition(capture.startCalls == 2, "fresh ON never started")

        // B OFF, and all subscribers are now absent. No capture may survive.
        gate.scheduleStop { await capture.stop() }
        for _ in 0..<100 where capture.waitingStops == 0 { await Task.yield() }
        precondition(capture.waitingStops == 1, "last OFF did not stop capture")
        capture.finishStop()
        await gate.waitUntilIdle()
        precondition(!capture.active, "capture remains active after last OFF")

        // A/B share T0. A can settle it and clear the slot, then S0 completes.
        // C installs T1. Late B must not clear C's T1 slot; C OFF must wait
        // for T1 before stopping even when no stream exists yet.
        let delayed = FakeDelayedCapture()
        let lifecycle = RemoteAudioCaptureLifecycle()
        let a = lifecycle.acquireStart { await delayed.start() }
        let oldB = lifecycle.acquireStart { await delayed.start() }
        precondition(a.id == oldB.id, "A and B did not share T0")
        lifecycle.scheduleStop { await delayed.stop() }
        for _ in 0..<100 where delayed.pendingStarts == 0 { await Task.yield() }
        precondition(delayed.pendingStarts == 1, "T0 not pending")
        delayed.finishStart()
        let aStarted = await lifecycle.settleStart(a)
        precondition(aStarted)
        for _ in 0..<100 where delayed.pendingStops == 0 { await Task.yield() }
        precondition(delayed.pendingStops == 1, "S0 did not stop T0")
        delayed.finishStop()
        await lifecycle.waitUntilIdle()

        let c = lifecycle.acquireStart { await delayed.start() }
        for _ in 0..<100 where delayed.pendingStarts == 0 { await Task.yield() }
        precondition(delayed.pendingStarts == 1, "T1 not pending")
        let oldBStarted = await lifecycle.settleStart(oldB)
        precondition(oldBStarted)
        lifecycle.scheduleStop { await delayed.stop() }
        for _ in 0..<100 { await Task.yield() }
        precondition(delayed.stopCalls == 1, "C OFF did not wait for T1")
        delayed.finishStart()
        let cStarted = await lifecycle.settleStart(c)
        precondition(cStarted)
        for _ in 0..<100 where delayed.pendingStops == 0 { await Task.yield() }
        precondition(delayed.pendingStops == 1, "S1 did not stop T1")
        delayed.finishStop()
        await lifecycle.waitUntilIdle()
        precondition(!delayed.active, "capture remains active after C OFF")
        print("remote audio lifecycle: replacement stop and shared-start checks passed")
    }
}
