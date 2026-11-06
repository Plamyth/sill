import Foundation
import StreamProtocol

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
        let guards = try JSONDecoder().decode([String:Bool].self,
            from: Data(contentsOf: folder.appendingPathComponent("guards.json")))
        precondition(guards.count == 24 && guards.keys.filter { $0.hasPrefix("auth.") }.count == 10,
                     "all 24 product guard keys enter the actual encoder")
        runtime.forwardingContextReadiness = guards
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:]); log.flush()
        let first = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String:Any]
        precondition((first["runtime"] as! [String:Any])["forwardingLastReceived"] as? [String:String] == summary,
                     "real metadata encoder preserves the map without samples or raw response")
        precondition((first["runtime"] as! [String:Any])["forwardingContextReadiness"] as? [String:Bool] == guards,
                     "real metadata preserves failed guards as booleans")
        precondition((first["forwardingContextReadinessScope"] as? String)?.contains("not authentication, media authority") == true,
                     "scope mismatch observations are explicitly not authority")
        precondition(first["hostMediaCounters"] is NSNull, "no receipt means unknown, not zero counters")
        let receipt = MicrophoneReceipt(scope: MicrophoneScope(peer: UUID(), source: .desktop,
            inputGeneration: UUID(), videoEpoch: UUID(), destination: UUID(), capability: UUID()),
            grantID: UUID(), admittedPackets: 77, renderedFrames: 36960, applicationQueueAgeMilliseconds: 2.5)
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, hostMediaCounters: receipt, session: [:])
        var receiptSnapshot = first
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 0.05); log.flush()
            receiptSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String:Any]
            if receiptSnapshot["hostMediaCounters"] is [String:Any] { break }
        }
        let actualCounters = receiptSnapshot["hostMediaCounters"] as! [String:Any]
        let expectedCounters = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! NSDictionary
        precondition((actualCounters as NSDictionary).isEqual(expectedCounters), "existing receipt DTO scope, grant and counters survive the actual encoder")
        precondition(Set(actualCounters.keys) == ["scope", "grantID", "admittedPackets", "renderedFrames", "applicationQueueAgeMilliseconds"], "no samples or new wire fields")
        precondition((receiptSnapshot["hostMediaCountersScope"] as? String)?.contains("not signal level") == true,
                     "packet counters are not acoustic or transcription acceptance")
        let diagnosticID = UUID()
        let attempt = log.attempt(diagnosticID)
        attempt.recordForwardingGuards("explicit_stop_requested", guards)
        var sendGuards = guards
        sendGuards["isObserve"] = false
        sendGuards["isStopSubmission"] = true
        attempt.recordForwardingGuards("explicit_stop_first_217_submitted", sendGuards)
        log.flush()
        let eventLog = try JSONSerialization.jsonObject(with: Data(contentsOf: log.fileURL)) as! [[String:Any]]
        precondition(eventLog.count == 4, "request and send each persist distinct main and auth events")
        for (name, expected) in [("explicit_stop_requested", guards), ("explicit_stop_first_217_submitted", sendGuards)] {
            let main = eventLog.first { $0["event"] as? String == name }!
            let auth = eventLog.first { $0["event"] as? String == name + "_auth" }!
            let fields = main["fields"] as! [String:String]
            let authFields = auth["fields"] as! [String:String]
            precondition(fields.count == expected.count - 10 && fields.count <= 16 && authFields.count == 10,
                         "real prefix16 preserves every partition")
            precondition(Set(fields.keys).isDisjoint(with: authFields.keys) &&
                         fields.merging(authFields, uniquingKeysWith: { _, next in next }) == expected.mapValues { String($0) },
                         "stored partitions preserve all 24 or 26 fields without duplication")
            precondition(main["attempt"] as? String == diagnosticID.uuidString && auth["attempt"] as? String == diagnosticID.uuidString,
                         "partitions and send retain the same diagnostic ID")
            precondition(fields.values.allSatisfy { $0 == "true" || $0 == "false" } &&
                         authFields.values.allSatisfy { $0 == "true" || $0 == "false" },
                         "stored fields contain only product guard names and booleans, no secret values")
        }
        let stopFields = ["block.reason": "advance_freshness_expired", "block.phase": "active", "block.now": "4.2",
            "block.freshUntil": "4.2", "block.pendingSentAt": "2.2", "block.pendingOperation": "observe",
            "block.pendingRequestID": UUID().uuidString, "permissionFailure": "forwarding_phase_not_active",
            "stopPath": "applyAudioForwarding.microphonePolicy.backgrounded", "stopNow": "4.2",
            "forwardingPhase": "blocked", "phaseCanStop": "true", "captureTokenPresent": "true"]
        attempt.record("forwarding_microphone_stop", stopFields)
        attempt.record("forwarding_microphone_stop", ["block.reason": "later_failure"])
        log.flush()
        let stopEvents = (try JSONSerialization.jsonObject(with: Data(contentsOf: log.fileURL)) as! [[String:Any]])
            .filter { $0["event"] as? String == "forwarding_microphone_stop" }
        precondition(stopEvents.count == 1, "actual recorder keeps only the first stop event per microphone attempt")
        precondition(stopEvents[0]["fields"] as? [String:String] == stopFields,
                     "all 13 stop fields survive actual prefix16 serialization without later overwrite")
        precondition(stopEvents[0]["attempt"] as? String == diagnosticID.uuidString,
                     "stop event reuses the microphone attempt without creating a new identity")
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:])
        var second = first
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 0.05); log.flush()
            second = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String:Any]
            if (second["attempts"] as? [[String:Any]])?.count == 1 { break }
        }
        let attempts = second["attempts"] as! [[String:Any]]
        precondition(attempts.count == 1 && (attempts[0]["scopeAtFirstObservation"] as! [String:Any])["forwardingLastReceived"] == nil,
                     "historical attempts do not retain the current scope summary")
        precondition((attempts[0]["scopeAtFirstObservation"] as! [String:Any])["forwardingContextReadiness"] == nil,
                     "historical attempts do not inherit current guards")
        precondition(second["hostMediaCounters"] is NSNull, "next snapshot without a current receipt clears previous counters")
        log.connectionChanged()
        runtime.forwardingLastReceived = nil
        runtime.forwardingContextReadiness = nil
        runtime.connected = false
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:])
        var final = second
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 0.05); log.flush()
            final = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String:Any]
            if (final["runtime"] as? [String:Any])?["connected"] as? Bool == false { break }
        }
        precondition((final["runtime"] as! [String:Any])["forwardingLastReceived"] == nil,
                     "connection replacement discards persisted current summary")
        precondition((final["runtime"] as! [String:Any])["forwardingContextReadiness"] == nil,
                     "connection replacement discards persisted guard map")
        precondition(final["hostMediaCounters"] is NSNull, "reconnect snapshot cannot retain a retired grant receipt")
        print("audio-metadata 실제 추출 본문 검사 31개 통과; 엔진·마이크·네트워크 0")
    }
}
