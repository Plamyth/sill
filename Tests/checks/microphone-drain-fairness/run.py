"""Compile the production drain body against inert ingress/admission seams; no devices or IO."""
import hashlib
import json
import pathlib
import subprocess
import sys

root, output = (pathlib.Path(p).resolve() for p in sys.argv[1:3])
assert output != root and root not in output.parents
output.mkdir(parents=True, exist_ok=True)
assert not (output / 'result.json').exists()
coordinator = (root / 'Sources/SillHost/StreamCoordinator.swift').read_text()
receiver = (root / 'Sources/SillHost/HostMicrophoneReceiver.swift').read_text()
marker = 'private func drainMicrophoneIngress() async {'
start = coordinator.index(marker)
end, depth = start + len(marker), 1
while depth:
    depth += (coordinator[end] == '{') - (coordinator[end] == '}')
    end += 1
body = coordinator[start:end].replace('private func ', 'func ', 1)
flag = 'private var microphoneIngressDraining = false'
assert coordinator.count(flag) == 1
assert 'await self.drainMicrophoneIngress()' in coordinator
def boundary(marker):
    begin = coordinator.index(marker)
    opening = coordinator.index('{', begin)
    finish, nesting = opening + 1, 1
    while nesting:
        nesting += (coordinator[finish] == '{') - (coordinator[finish] == '}')
        finish += 1
    return coordinator[begin:finish].replace('private func ', 'func ', 1)
facts = boundary('private func localAudioReturnFacts(')
prepare = boundary('private func prepareLocalAudioReturn(')
# Removing the redundant caller check is safe only while the receiver retains its own live guard.
assert 'current?(owned.request.scope, owned.owner.fingerprint) == true' in receiver
frame_body = receiver[receiver.index('    func frame('):receiver.index('    func revoke(')]
assert 'live(owned)' in frame_body and 'owned.render.offer(' in frame_body
source = r'''
import Foundation
@MainActor var assertions = 0
@MainActor func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    assertions += 1
    if !value() { print("FAIL \(label)"); exit(1) }
}
struct Peer { let id: Int; let connection: Int; let fingerprint: Int }
struct Request { enum Operation { case start, stop }; let operation: Operation; let scope: Int }
struct Control { let peer: Peer; let request: Request }
struct Payload { let sequence: Int; let scope: Int }
struct Frame { let peer: Peer; let frame: Payload; let arrived: UInt64 = 1 }
@MainActor final class Ingress {
    var batches: [([Control], [Frame], [Int])] = []
    var peerID = 1
    var localReturnDetached: Bool { batches.isEmpty }
    func revoke() { batches.removeAll() }
    func peer(_ connection: Int) -> Peer? { Peer(id: peerID, connection: connection, fingerprint: 1) }
    func take() -> ([Control], [Frame], [Int]) {
        batches.isEmpty ? ([], [], []) : batches.removeFirst()
    }
}
@MainActor final class Receiver {
    var current: (Int, Int) -> Bool = { _, _ in true }
    var onFrame: (Int) -> Void = { _ in }
    var attempted: [Int] = [], admitted: [Int] = [], controls: [Request.Operation] = []
    var events: [String] = []
    var retirementComplete = true
    func waitForRetirement() async -> Bool { retirementComplete }
    func forgetCapabilities() { events.append("forget-local") }
    func revoke(reason: String) { events.append("revoke-local") }
    func frame(_ value: Payload, fingerprint: Int, arrived: UInt64) -> Bool {
        attempted.append(value.sequence)
        let allowed = current(value.scope, fingerprint)
        if allowed { admitted.append(value.sequence) }
        onFrame(value.sequence)
        return allowed
    }
    func control(_ value: Request, fingerprint: Int) { controls.append(value.operation); events.append("control") }
    func forgetCapabilities(peer: Int) { events.append("forget") }
    func revoke(peer: Int, reason: String) { events.append("revoke") }
}
struct LocalAudioParticipantFacts {
    let admissionFenced, startsSettled, mediaDetached, callbacksDrained, buffersEmpty, workersExited: Bool
    var quiescent: Bool { admissionFenced && startsSettled && mediaDetached && callbacksDrained && buffersEmpty && workersExited }
}
struct Lifecycle { var isIdle = true }
struct Capture { var retirementConfirmed = true; var hasStream = false }
struct Participants { var isFenced = true }
struct Privacy { var participants = Participants() }
@MainActor final class Server {
    func drainRemoteAudio(_ completion: (Bool) -> Void) { completion(true) }
}
@MainActor final class Harness {
    let microphoneIngress = Ingress(), microphoneReceiver = Receiver()
    var microphoneIngressDraining = false
    var microphoneIngressDrainTask: Task<Void, Never>?
    var shuttingDown = false
    var physicalAudioRoutesRetired = false, localAudioReturnDrained = false, remoteAudioRunning = false
    var remoteAudioLifecycle = Lifecycle(), remoteAudioCapture = Capture()
    var remoteAudioSubscribers: [Int] = [], remoteAudioRequests: [Int] = [], remoteAudioActions: [Int] = []
    var audioPrivacy: Privacy? = Privacy()
    let server = Server()
    func revokeRemoteAudio(reason: String) async {}
    var controlAllowed = true
    var outerChecks = 0
    func microphoneScopeIsCurrent(_ scope: Int, fingerprint: Int) -> Bool {
        outerChecks += 1
        return controlAllowed
    }
    // PRODUCTION_DRAIN
    // PRODUCTION_FACTS
    // PRODUCTION_PREPARE
}
@MainActor func batch(_ values: [Int], scope: Int = 1) -> [Frame] {
    values.map { Frame(peer: Peer(id: 1, connection: 1, fingerprint: 1), frame: Payload(sequence: $0, scope: scope)) }
}
@MainActor func settle() async { for _ in 0..<100 { await Task.yield() } }
@main struct Check {
    @MainActor static func main() async {
        do {
            let h = Harness()
            h.microphoneIngress.batches = [([], batch(Array(1...6)), [])]
            var responseAt = 0, checks = 0
            h.microphoneReceiver.current = { _, _ in checks += 1; return true }
            h.microphoneReceiver.onFrame = { value in
                if value == 1 { Task { @MainActor in responseAt = h.microphoneReceiver.attempted.count } }
            }
            await h.drainMicrophoneIngress(); await settle()
            expect(h.microphoneReceiver.admitted == Array(1...6), "ordered-frame-admission")
            expect(responseAt > 0 && responseAt < 6, "ready-response-runs-between-frames")
            expect(checks == 6 && h.outerChecks == 0, "one-fresh-receiver-check-per-frame")
            expect(!h.microphoneIngressDraining, "drain-released-after-empty")
        }
        do {
            let h = Harness()
            h.microphoneIngress.batches = [([], batch(Array(1...6)), []), ([], batch([7]), [])]
            var nestedReturned = false
            h.microphoneReceiver.onFrame = { value in
                if value == 1 { Task { @MainActor in await h.drainMicrophoneIngress(); nestedReturned = true } }
            }
            await h.drainMicrophoneIngress(); await settle()
            expect(nestedReturned && h.microphoneReceiver.attempted == Array(1...7), "single-consumer-no-new-batch-overtake")
        }
        do {
            let h = Harness(); var allowed = true
            h.microphoneIngress.batches = [([], batch(Array(1...6)), [])]
            h.microphoneReceiver.current = { _, _ in allowed }
            h.microphoneReceiver.onFrame = { value in
                if value == 1 { Task { @MainActor in allowed = false } }
            }
            await h.drainMicrophoneIngress(); await settle()
            expect(h.microphoneReceiver.attempted.count == 6 && h.microphoneReceiver.admitted.count < 6,
                   "revocation-rechecked-after-yield")
            expect(h.microphoneReceiver.admitted.first == 1 && h.microphoneReceiver.admitted.last! < 6,
                   "no-batch-wide-authority-cache")
        }
        do {
            let h = Harness()
            h.microphoneIngress.batches = [([], batch([1], scope: 99), [])]
            h.microphoneReceiver.current = { scope, fingerprint in scope == 1 && fingerprint == 1 }
            await h.drainMicrophoneIngress()
            expect(h.microphoneReceiver.admitted.isEmpty, "foreign-scope-still-refused-by-receiver")
        }
        do {
            let h = Harness(); h.shuttingDown = true
            h.microphoneIngress.batches = [([], batch([1]), [])]
            await h.drainMicrophoneIngress()
            expect(h.microphoneReceiver.attempted.isEmpty && !h.microphoneIngressDraining,
                   "shutdown-releases-consumer-without-admission")
        }
        do {
            let h = Harness(); h.controlAllowed = false
            let peer = Peer(id: 1, connection: 1, fingerprint: 1)
            h.microphoneIngress.batches = [([Control(peer: peer, request: Request(operation: .start, scope: 1)),
                Control(peer: peer, request: Request(operation: .stop, scope: 1))], [], [1])]
            await h.drainMicrophoneIngress()
            expect(h.microphoneReceiver.controls == [.stop], "start-authority-and-stop-cleanup-preserved")
            expect(h.microphoneReceiver.events == ["forget", "revoke", "control"], "closed-peer-before-controls")
        }
        do {
            let h = Harness(); h.microphoneIngress.peerID = 2
            let peer = Peer(id: 1, connection: 1, fingerprint: 1)
            h.microphoneIngress.batches = [([Control(peer: peer, request: Request(operation: .stop, scope: 1))], [], [])]
            await h.drainMicrophoneIngress()
            expect(h.microphoneReceiver.controls.isEmpty, "displaced-peer-control-refused")
        }
        do {
            let h = Harness()
            await h.drainMicrophoneIngress()
            h.microphoneIngress.batches = [([], batch([1]), [])]
            await h.drainMicrophoneIngress()
            expect(h.microphoneReceiver.admitted == [1] && !h.microphoneIngressDraining, "later-wake-not-lost")
        }
        do {
            let h = Harness()
            h.microphoneIngress.batches = [([], batch(Array(1...6)), [])]
            h.microphoneReceiver.current = { _, _ in !h.physicalAudioRoutesRetired }
            var heldBatchBlockedFacts = false, joined = false, framesAtReturn = 0
            var returning: Task<Void, Never>?
            h.microphoneReceiver.onFrame = { value in
                if value == 1 {
                    returning = Task { @MainActor in
                        h.physicalAudioRoutesRetired = true; h.localAudioReturnDrained = true
                        heldBatchBlockedFacts = !h.localAudioReturnFacts().quiescent &&
                            !h.localAudioReturnFacts().buffersEmpty
                        joined = await h.prepareLocalAudioReturn()
                        framesAtReturn = h.microphoneReceiver.attempted.count
                    }
                }
            }
            let draining = Task { @MainActor in await h.drainMicrophoneIngress() }
            h.microphoneIngressDrainTask = draining
            await draining.value; await settle(); await returning?.value
            expect(heldBatchBlockedFacts, "mailbox-empty-does-not-hide-held-batch")
            expect(joined && framesAtReturn == 6 && h.localAudioReturnFacts().quiescent,
                   "local-return-joins-consumer-before-quiescence")
            expect(h.microphoneReceiver.admitted.count < 6, "local-return-fence-rechecked-between-held-frames")
        }
        print("RESULT_SCENARIOS 9")
        print("RESULT_ASSERTIONS \(assertions)")
    }
}
'''.replace('// PRODUCTION_DRAIN', body).replace('// PRODUCTION_FACTS', facts).replace('// PRODUCTION_PREPARE', prepare)
generated = output / 'Main.swift'
generated.write_text(source)
commands = [
    ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(generated), '-o', str(output / 'check')],
    [str(output / 'check')],
]
results = []
for index, command in enumerate(commands):
    run = subprocess.run(command, text=True, capture_output=True, timeout=180 if index == 0 else 15)
    (output / f'{index}.log').write_text(run.stdout + run.stderr)
    results.append({'exitCode': run.returncode, 'stdout': run.stdout, 'stderr': run.stderr})
    if run.returncode:
        break
result = {'scope': 'extracted production drain, inert ingress/receiver; not HAL, network, or device latency proof',
          'sourceSHA256': hashlib.sha256(coordinator.encode()).hexdigest(),
          'drainSHA256': hashlib.sha256(body.encode()).hexdigest(),
          'receiverSHA256': hashlib.sha256(receiver.encode()).hexdigest(), 'commands': results,
          'passed': len(results) == 2 and all(x['exitCode'] == 0 for x in results)}
(output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
sys.exit(0 if result['passed'] else 1)
