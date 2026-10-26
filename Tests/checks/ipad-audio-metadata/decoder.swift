import AVFoundation
import Foundation

@main struct DecoderChecks {
    @MainActor static func main() throws {
        let log = IPadMicrophoneDiagnostics(fileURL: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("decoder-events.json"))
        let diagnostics = log.attempt(UUID())
        if let decoder = RemoteAACDecoder(rate: 48_000, channels: 1, cookie: Data()) {
            let decoded = decoder.decode(Data([0xff]), diagnostics: diagnostics)
            precondition(decoded == nil || decoded!.isEmpty, "invalid synthetic AAC must not yield audio")
        } else { diagnostics.count(.decoderUnavailable) }
        let runtime = IPadMicrophoneDiagnostics.Runtime(connected: false, foreground: true,
            sourceKind: nil, sourceID: nil, generation: nil, videoEpoch: nil,
            microphoneDesired: false, playbackDesired: false, microphonePhase: "off", playbackPhase: "off",
            capturePresent: false, captureRunning: nil, cachedAudioPrivacyProtected: nil,
            forwardingPhase: "unknown", sentryPhase: nil, sentryRequested: nil, hostBootID: nil, hostSessionID: nil)
        log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:]); log.flush()
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String: Any]
        let entries = doc["attempts"] as! [[String: Any]]
        let counters = entries[0]["counters"] as! [String: Int]
        precondition((counters["decodeErrors"] ?? 0) + (counters["decoderUnavailable"] ?? 0) + (counters["emptyDecodedPackets"] ?? 0) > 0,
                     "decoder failure or empty input-ran-dry output must be observable")
        print("actual offline AAC decoder error/empty-output metadata passed; no audio engine or sample logging")
    }
}
