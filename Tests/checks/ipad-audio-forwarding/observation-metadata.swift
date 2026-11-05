import Foundation

@main struct ObservationMetadataCheck {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let log = IPadMicrophoneDiagnostics(fileURL: folder.appendingPathComponent("events.json"))
        var runtime = IPadMicrophoneDiagnostics.Runtime(connected: true, foreground: true,
            sourceKind: "desktop", sourceID: nil, generation: nil, videoEpoch: nil,
            microphoneDesired: false, playbackDesired: false, microphonePhase: "off", playbackPhase: "off",
            capturePresent: false, captureRunning: nil, cachedAudioPrivacyProtected: nil,
            forwardingPhase: "blocked", sentryPhase: nil, sentryRequested: nil, hostBootID: nil, hostSessionID: nil)
        precondition(runtime.forwardingLastReceived == nil, "optional diagnostic defaults to nil for old callers")
        precondition(runtime.forwardingContextReadiness == nil, "old runtime callers need no guard map")
        let legacy = try JSONEncoder().encode(runtime)
        let decoded = try JSONDecoder().decode(IPadMicrophoneDiagnostics.Runtime.self, from: legacy)
        precondition(decoded.forwardingLastReceived == nil,
                     "old runtime records decode without a new field")
        precondition(decoded.forwardingContextReadiness == nil, "old runtime records decode without guards")
        let summary = ["operation":"submit", "result":"refused", "code":"binding_mismatch",
                       "binding.phase":"active", "binding.epoch":UUID().uuidString, "observedUptimeSeconds":"1.0"]
        runtime.forwardingLastReceived = summary
        let guards = ["contextPresent":false, "contextMatchesForwardingState":false,
                      "wirePresent":true, "pendingPresent":false, "forwardingFaulted":true]
        runtime.forwardingContextReadiness = guards
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:]); log.flush()
        let first = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String:Any]
        precondition((first["runtime"] as! [String:Any])["forwardingLastReceived"] as? [String:String] == summary,
                     "real metadata encoder preserves the map without samples or raw response")
        precondition((first["runtime"] as! [String:Any])["forwardingContextReadiness"] as? [String:Bool] == guards,
                     "real metadata preserves failed guards as booleans")
        precondition((first["forwardingContextReadinessScope"] as? String)?.contains("not authentication, media authority") == true,
                     "scope mismatch observations are explicitly not authority")
        log.attempt(UUID()).record("explicit_stop_requested", guards.mapValues { String($0) }); log.flush()
        let eventLog = try JSONSerialization.jsonObject(with: Data(contentsOf: log.fileURL)) as! [[String:Any]]
        precondition(eventLog.last?["fields"] as? [String:String] == guards.mapValues { String($0) },
                     "existing event encoder preserves only stop guard booleans")
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:])
        Thread.sleep(forTimeInterval: 1.05); log.flush()
        let second = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String:Any]
        let attempts = second["attempts"] as! [[String:Any]]
        precondition(attempts.count == 1 && (attempts[0]["scopeAtFirstObservation"] as! [String:Any])["forwardingLastReceived"] == nil,
                     "historical attempts do not retain the current scope summary")
        precondition((attempts[0]["scopeAtFirstObservation"] as! [String:Any])["forwardingContextReadiness"] == nil,
                     "historical attempts do not inherit current guards")
        log.connectionChanged()
        runtime.forwardingLastReceived = nil
        runtime.forwardingContextReadiness = nil
        runtime.connected = false
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:])
        Thread.sleep(forTimeInterval: 1.05); log.flush()
        let final = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String:Any]
        precondition((final["runtime"] as! [String:Any])["forwardingLastReceived"] == nil,
                     "connection replacement discards persisted current summary")
        precondition((final["runtime"] as! [String:Any])["forwardingContextReadiness"] == nil,
                     "connection replacement discards persisted guard map")
        print("audio-metadata 실제 추출 본문 검사 12개 통과; 엔진·마이크·네트워크 0")
    }
}
