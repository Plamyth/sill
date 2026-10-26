import Foundation

private func waitForWriter(_ semaphore: DispatchSemaphore) {
    precondition(semaphore.wait(timeout: .now() + 3) == .success)
}

@main struct LifecycleChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        func runtime(_ connected: Bool, _ foreground: Bool = true, _ phase: String = "off") -> IPadMicrophoneDiagnostics.Runtime {
            .init(connected: connected, foreground: foreground, sourceKind: nil, sourceID: nil,
                generation: nil, videoEpoch: nil, microphoneDesired: false, playbackDesired: false,
                microphonePhase: phase, playbackPhase: "off", capturePresent: false, captureRunning: nil,
                cachedAudioPrivacyProtected: nil, forwardingPhase: "unknown", sentryPhase: nil,
                sentryRequested: nil, hostBootID: nil, hostSessionID: nil)
        }
        func check(_ ok: Bool, _ label: String) throws {
            guard ok else { throw NSError(domain: label, code: 1) }
            print("PASS " + label)
        }
        func document(_ log: IPadMicrophoneDiagnostics) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String: Any]
        }
        func wait() async throws { try await Task.sleep(nanoseconds: 1_150_000_000) }
        let log = IPadMicrophoneDiagnostics(fileURL: root.appendingPathComponent("events.json"))
        func sample(_ connected: Bool, _ foreground: Bool = true, _ phase: String = "off") {
            log.snapshot(runtime: runtime(connected, foreground, phase), render: nil, playbackRunning: false, session: [:])
        }
        log.received(.catalog, hostTimestamp: 123)
        sample(true); log.flush()
        let initial = try document(log)
        try await wait()
        log.connectionChanged()
        sample(true); log.flush()
        sample(true)
        sample(false)
        let sampledAt = Date().timeIntervalSince1970
        log.flush()
        try await wait(); log.flush()
        let final = try document(log)
        try check((final["runtime"] as! [String: Any])["connected"] as? Bool == false,
            "teardown final connected=false persists after timers stop")
        try check(final["connectionObservationID"] as? String != initial["connectionObservationID"] as? String &&
            (final["receivedObservations"] as! [String: Any]).isEmpty, "teardown resets old peer observations")
        try check(abs((final["appObservationSampledAt"] as! Double) - sampledAt) < 0.2,
            "trailing write preserves actual main observation time")
        sample(false); log.flush()
        sample(false, false, "failed")
        try await wait(); log.flush()
        let failed = try document(log)["runtime"] as! [String: Any]
        try check(failed["foreground"] as? Bool == false && failed["microphonePhase"] as? String == "failed",
            "foreground and failed latest request survives rate window")
        sample(false, false, "failed")
        log.connectionChanged()
        log.received(.catalog, hostTimestamp: 456)
        sample(true)
        try await wait(); log.flush()
        let replacement = try document(log)
        let replacementBytes = try Data(contentsOf: log.snapshotURL)
        try check((replacement["runtime"] as! [String: Any])["connected"] as? Bool == true &&
            replacement["connectionObservationID"] as? String != final["connectionObservationID"] as? String,
            "new connection supersedes pending old final")
        try await wait(); log.flush()
        try check(try Data(contentsOf: log.snapshotURL) == replacementBytes, "old final cannot overwrite new connection later")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        log.holdWriter(entered, release)
        waitForWriter(entered)
        sample(false)
        for _ in 0..<100 { sample(false, false, "failed") }
        log.connectionChanged()
        log.received(.catalog, hostTimestamp: 789)
        sample(true)
        release.signal()
        log.flush()
        let pending = try document(log)
        let pendingRuntime = pending["runtime"] as! [String: Any]
        let catalog = (pending["receivedObservations"] as! [String: Any])["catalog"] as! [String: Any]
        try check(pendingRuntime["connected"] as? Bool == true && catalog["hostTimestamp"] as? Double == 789,
            "busy serial writer coalesces to replacement peer and latest request")
        let pendingBytes = try Data(contentsOf: log.snapshotURL)
        try await wait(); log.flush()
        try check(try Data(contentsOf: log.snapshotURL) == pendingBytes, "busy writer leaves no older final queued")
        log.holdWriter(entered, release)
        waitForWriter(entered)
        sample(false)
        log.connectionChanged()
        release.signal()
        log.flush()
        try check(try Data(contentsOf: log.snapshotURL) == pendingBytes,
            "connection reset discards pending producer when no replacement sample exists")
        log.snapshot(runtime: runtime(false), render: nil, playbackRunning: false, session: {
            log.connectionChanged()
            return [:]
        }())
        log.flush()
        try await wait(); log.flush()
        try check(try Data(contentsOf: log.snapshotURL) == pendingBytes,
            "producer sampled before connection change cannot publish under a new observation")
        print("PASS lifecycle trailing-write regression; no device, media engine or timers")
    }
}
