import Foundation
import os

private func waitForPeer(_ semaphore: DispatchSemaphore) {
    precondition(semaphore.wait(timeout: .now() + 3) == .success)
}

final class NWConnection: @unchecked Sendable {}
struct Header { let timestamp: Double }
final class StreamClient: @unchecked Sendable {
    let binding = OSAllocatedUnfairLock(initialState: (peer: Optional<NWConnection>.none, trap: false))
    let captured = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    var connection: NWConnection? {
        let result = binding.withLock { value -> (NWConnection?, Bool) in
            let pause = value.trap && !Thread.isMainThread
            if pause { value.trap = false }
            return (value.peer, pause)
        }
        if result.1 { captured.signal(); resume.wait() }
        return result.0
    }
    var accepted = 0
    func sentryBinding(on peer: NWConnection) -> Int? { nil }
    func acceptIPadSentryReply(_ data: Data, from peer: NWConnection, binding: Int?) { accepted += 1 }
}
@main struct PeerChecks {
    @MainActor static func main() async throws {
        let log = IPadMicrophoneDiagnostics.shared
        let client = StreamClient(), old = NWConnection(), new = NWConnection()
        client.binding.withLock { $0 = (old, true) }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            client.deliverSentry(Header(timestamp: 123), Data(), from: old)
            done.signal()
        }
        if hasNetworkGuard {
            waitForPeer(client.captured)
        } else {
            waitForPeer(done)
        }
        client.binding.withLock { $0 = (new, false) }
        log.connectionChanged()
        client.resume.signal()
        if hasNetworkGuard { waitForPeer(done) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let runtime = IPadMicrophoneDiagnostics.Runtime(connected: true, foreground: true,
            sourceKind: nil, sourceID: nil, generation: nil, videoEpoch: nil,
            microphoneDesired: false, playbackDesired: false, microphonePhase: "off", playbackPhase: "off",
            capturePresent: false, captureRunning: nil, cachedAudioPrivacyProtected: nil,
            forwardingPhase: "unknown", sentryPhase: nil, sentryRequested: nil, hostBootID: nil, hostSessionID: nil)
        func document() throws -> [String: Any] {
            log.snapshot(runtime: runtime, render: nil, playbackRunning: false, session: [:]); log.flush()
            return try JSONSerialization.jsonObject(with: Data(contentsOf: log.snapshotURL)) as! [String: Any]
        }
        let first = try document()
        guard (first["receivedObservations"] as! [String: Any]).isEmpty, client.accepted == 0 else {
            throw NSError(domain: "old peer reception leaked into replacement connection", code: 1)
        }
        print("PASS actual network switch and main consumer reject old-peer envelope after replacement")
        client.deliverSentry(Header(timestamp: 456), Data(), from: new)
        try await Task.sleep(nanoseconds: 1_150_000_000)
        let current = try document()
        let received = (current["receivedObservations"] as! [String: Any])["sentryState"] as! [String: Any]
        guard received["messages"] as? Int == 1, received["hostTimestamp"] as? Double == 456,
              client.accepted == 1 else { throw NSError(domain: "current peer envelope not recorded once", code: 1) }
        print("PASS current-peer envelope count and original header timestamp recorded once")
    }
}
