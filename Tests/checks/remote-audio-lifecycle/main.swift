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

@main
struct Check {
    @MainActor static func main() async {
        let capture = FakeCapture()
        var schedules = 0
        var gate: RemoteAudioStopGate!
        gate = RemoteAudioStopGate(onCleared: {
            schedules += 1
            if schedules == 1 { gate.schedule { await capture.stop() } }
        })

        // A OFF schedules S0. B ON waits S0. Its completion is followed by
        // A OFF scheduling S1 before B resumes. B must not start through S1.
        capture.start()
        gate.schedule { await capture.stop() }
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
        gate.schedule { await capture.stop() }
        for _ in 0..<100 where capture.waitingStops == 0 { await Task.yield() }
        precondition(capture.waitingStops == 1, "last OFF did not stop capture")
        capture.finishStop()
        await gate.waitUntilIdle()
        precondition(!capture.active, "capture remains active after last OFF")
        print("remote audio lifecycle: 2 checks passed")
    }
}
