import Foundation

@main struct MetadataChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let log = IPadMicrophoneDiagnostics(fileURL: directory.appendingPathComponent("microphone-diagnostics.json"))
        let first = UUID()
        let attempt = log.attempt(first)
        attempt.record("first_tap", ["frames": "960"])
        attempt.record("first_tap", ["frames": "960"])
        attempt.count(.tapFrames, 960)
        attempt.count(.tapFrames, 960)
        attempt.count(.decodeErrors, errorCode: -50)
        log.received(.catalog, hostTimestamp: 123, generation: UUID(), videoEpoch: UUID())
        let runtime = IPadMicrophoneDiagnostics.Runtime(connected: false, foreground: true,
            sourceKind: nil, sourceID: nil, generation: nil, videoEpoch: nil,
            microphoneDesired: false, playbackDesired: false, microphonePhase: "off", playbackPhase: "off",
            capturePresent: false, captureRunning: nil, cachedAudioPrivacyProtected: nil, forwardingPhase: "unknown", sentryPhase: nil,
            sentryRequested: nil, hostBootID: nil, hostSessionID: nil)
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:])
        log.flush()
        let bytes = try Data(contentsOf: log.snapshotURL)
        let snapshot = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        precondition(snapshot["commit"] is NSNull && snapshot["render"] is NSNull)
        precondition(snapshot["generatedAt"] is Double && snapshot["processID"] is Int)
        precondition(snapshot["observationID"] is String && snapshot["observedUptimeNanoseconds"] != nil)
        let attempts = snapshot["attempts"] as! [[String: Any]]
        let counters = attempts[0]["counters"] as! [String: Int]
        precondition(counters["tapFrames"] == 1920 && counters["admittedPlaybackPackets"] == nil)
        precondition(attempts[0]["lastErrorCode"] as? Int == -50)
        precondition((snapshot["receivedObservations"] as! [String: Any])["catalog"] != nil)
        let events = try JSONSerialization.jsonObject(with: Data(contentsOf: log.fileURL)) as! [[String: Any]]
        precondition(events.count == 1)
        for _ in 0..<100 { log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:]) }
        log.flush()
        let throttledBytes = try Data(contentsOf: log.snapshotURL)
        precondition(throttledBytes == bytes, "one-second rate cap")
        for _ in 0..<20 { log.attempt(UUID()).count(.capturePackets) }
        try await Task.sleep(nanoseconds: 1_050_000_000)
        log.connectionChanged()
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:])
        try await Task.sleep(nanoseconds: 1_050_000_000)
        log.flush()
        let bounded = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String: Any]
        precondition((bounded["attempts"] as! [Any]).count == 8)
        precondition((bounded["receivedObservations"] as! [String: Any]).isEmpty)
        precondition(bounded["connectionObservationID"] as? String != snapshot["connectionObservationID"] as? String)
        let boundedBytes = try Data(contentsOf: log.snapshotURL)
        precondition(boundedBytes.count <= 65_536)
        print("metadata identity, unknown counters, event dedupe, rate cap, attempt bound and connection reset passed")
    }
}
