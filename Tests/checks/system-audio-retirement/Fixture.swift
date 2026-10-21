import Foundation
import Dispatch

enum TestFailure: Error { case injected }

actor Gate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Error>?

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            entered = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish(failing: Bool = false) {
        if failing { completion!.resume(throwing: TestFailure.injected) }
        else { completion!.resume() }
        completion = nil
    }
}

final class Plan: @unchecked Sendable {
    let startGate: Gate?
    let stopGate: Gate?
    let failStart: Bool
    let failStop: Bool
    var stream: SCStream?
    init(startGate: Gate? = nil, stopGate: Gate? = nil, failStart: Bool = false, failStop: Bool = false) {
        self.startGate = startGate; self.stopGate = stopGate
        self.failStart = failStart; self.failStop = failStop
    }
}
struct SCDisplay { let plan: Plan }
struct SCContentFilter {
    let plan: Plan
    init(display: SCDisplay, excludingWindows: [Int]) { plan = display.plan }
}
struct CMTime { init(value: Int, timescale: Int) {} }
final class SCStreamConfiguration {
    var width = 0, height = 0, sampleRate = 0, channelCount = 0
    var minimumFrameInterval = CMTime(value: 0, timescale: 1)
    var capturesAudio = false, excludesCurrentProcessAudio = false
}
enum SCStreamOutputType { case audio }
protocol SCStreamOutput {}
protocol SCStreamDelegate {}
final class SCStream: @unchecked Sendable {
    let plan: Plan
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, delegate: SCStreamDelegate) {
        plan = filter.plan
        plan.stream = self
    }
    func addStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue) throws {}
    func startCapture() async throws {
        if let gate = plan.startGate { try await gate.run() }
        if plan.failStart { throw TestFailure.injected }
    }
    func stopCapture() async throws {
        if let gate = plan.stopGate { try await gate.run() }
        if plan.failStop { throw TestFailure.injected }
    }
}
final class RemoteAudioPCM {
    func discardPending() {}
}

// PRODUCTION_CAPTURE

extension SystemAudioCapture {
    func holdQueue(entered: DispatchSemaphore, release: DispatchSemaphore) {
        queue.async { entered.signal(); release.wait() }
    }
    func waitUntilDetached() async {
        while hasStream { await Task.yield() }
    }
}

@MainActor final class CallbackCoordinator {
    let remoteAudioCapture = SystemAudioCapture()
    private(set) var revocations = 0
    init() {
        // PRODUCTION_STOP_CALLBACK
    }
    func revokeRemoteAudio(reason: String) async { revocations += 1 }
}

@main struct Checks {
    @MainActor static func main() async {
        var failures = 0
        var count = 0
        func check(_ value: Bool, _ name: String) {
            count += 1
            print("\(value ? "PASS" : "FAIL") \(name)")
            if !value { failures += 1 }
        }
        func start(_ capture: SystemAudioCapture, _ plan: Plan = Plan()) async {
            do { try await capture.start(display: SCDisplay(plan: plan)) }
            catch { check(false, "unexpected start failure") }
        }
        func cycle(_ capture: SystemAudioCapture) async {
            await start(capture)
            check(capture.hasStream, "ordinary remote audio still starts")
            await capture.stop()
        }

        let clean = SystemAudioCapture()
        check(clean.retirementConfirmed, "fresh capture is retired")
        await start(clean)
        check(!clean.retirementConfirmed, "active capture is not retired")
        await clean.stop()
        check(clean.retirementConfirmed, "successful stop confirms retirement after barrier")
        await clean.stop()
        check(clean.retirementConfirmed, "repeated empty stop remains retired")

        let failed = SystemAudioCapture()
        await start(failed, Plan(failStop: true))
        await failed.stop()
        check(!failed.retirementConfirmed, "failed stop is unresolved")
        await cycle(failed)
        check(!failed.retirementConfirmed, "new successful stop cannot erase old failed stop")
        await failed.stop()
        check(!failed.retirementConfirmed, "empty stop cannot erase unknown retirement")

        for failOld in [false, true] {
            let capture = SystemAudioCapture()
            let gate = Gate()
            await start(capture, Plan(stopGate: gate))
            let oldStop = Task { await capture.stop() }
            await gate.waitUntilEntered()
            await cycle(capture)
            check(!capture.retirementConfirmed, "new stop cannot confirm held older stop fail=\(failOld)")
            await capture.stop()
            check(!capture.retirementConfirmed, "empty stop cannot confirm held older stop fail=\(failOld)")
            await gate.finish(failing: failOld)
            await oldStop.value
            check(capture.retirementConfirmed == !failOld, "older stop result remains authoritative fail=\(failOld)")
            await cycle(capture)
            check(capture.retirementConfirmed == !failOld, "later generation preserves older stop result fail=\(failOld)")
        }

        let failedStart = SystemAudioCapture()
        do { try await failedStart.start(display: SCDisplay(plan: Plan(failStart: true))); check(false, "start must fail") }
        catch { check(!failedStart.retirementConfirmed, "failed start retirement is unknown") }
        await cycle(failedStart)
        check(!failedStart.retirementConfirmed, "new stop cannot erase failed start")

        let unsolicited = SystemAudioCapture()
        let oldPlan = Plan()
        var stoppedCallbacks = 0
        unsolicited.onStopped = { _, _ in stoppedCallbacks += 1 }
        await start(unsolicited, oldPlan)
        unsolicited.stream(oldPlan.stream!, didStopWithError: TestFailure.injected)
        check(!unsolicited.retirementConfirmed && !unsolicited.hasStream, "unsolicited stop is unresolved")
        await start(unsolicited)
        unsolicited.stream(oldPlan.stream!, didStopWithError: TestFailure.injected)
        check(unsolicited.hasStream && stoppedCallbacks == 1, "stale delegate cannot detach replacement or notify twice")
        await unsolicited.stop()
        check(!unsolicited.retirementConfirmed, "new stop cannot erase unsolicited error")

        let queued = SystemAudioCapture()
        await start(queued)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queued.holdQueue(entered: entered, release: release)
        entered.wait()
        let queuedStop = Task { await queued.stop() }
        await queued.waitUntilDetached()
        check(!queued.retirementConfirmed, "retirement waits for capture queue barrier")
        release.signal()
        await queuedStop.value
        check(queued.retirementConfirmed, "drained capture queue permits retirement")

        let starting = SystemAudioCapture()
        let startGate = Gate()
        let pendingStart = Task { await start(starting, Plan(startGate: startGate)) }
        await startGate.waitUntilEntered()
        await starting.stop()
        check(!starting.retirementConfirmed, "stop cannot confirm an unsettled start")
        await startGate.finish()
        await pendingStart.value
        await cycle(starting)
        check(!starting.retirementConfirmed, "new generation cannot erase start-stop overlap")

        let stale = CallbackCoordinator(), a = Plan(), b = Plan()
        await start(stale.remoteAudioCapture, a)
        stale.remoteAudioCapture.stream(a.stream!, didStopWithError: TestFailure.injected)
        await start(stale.remoteAudioCapture, b)
        for _ in 0..<10 { await Task.yield() }
        check(stale.revocations == 0 && stale.remoteAudioCapture.hasStream,
              "queued old capture failure cannot revoke the replacement subscription")
        await stale.remoteAudioCapture.stop()

        let current = CallbackCoordinator(), live = Plan()
        await start(current.remoteAudioCapture, live)
        current.remoteAudioCapture.stream(live.stream!, didStopWithError: TestFailure.injected)
        for _ in 0..<10 { await Task.yield() }
        check(current.revocations == 1 && !current.remoteAudioCapture.hasStream,
              "current capture failure still revokes its own subscription")

        print("RETIREMENT_RESULT assertions=\(count) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
