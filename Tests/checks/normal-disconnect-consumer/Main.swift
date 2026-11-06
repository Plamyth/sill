import Foundation
import StreamProtocol

@MainActor final class Peer {
    let peer: AudioForwardingPairedDevice
    let connection = UUID()
    var live = true
    init(_ byte: String = "ab") { peer = .init(id: AudioForwardingDeviceID(hex: String(repeating: byte, count: 32))!, pairingGeneration: UUID()) }
    var context: AudioForwardingConnectionContext {
        .init(peer: peer, principal: .init(kind: .tailnet, id: peer.id, authorizationGeneration: peer.pairingGeneration),
              role: .viewer, connectionID: connection, connectionIsCurrent: { self.live }, isCurrent: { self.live })
    }
}
@MainActor final class Fixture {
    let hal = InertHAL(), startup = NativeAudioStartup()
    var privacy: HostAudioPrivacy!
    var relay: LocalAudioRelay!
    var runtime: HostAudioForwardingRuntime!
    var consumer: Consumer!
    var authentications = 0, intentClears = 0
    init() {
        hal.original = hal.snapshot
        privacy = HostAudioPrivacy(hal: hal, clearLatch: { true }, authenticateLocal: { [unowned self] _ in authentications += 1; return false }, nativeStartup: startup)
        startup.construct { () }
        privacy.inspectForLocalReturn = { .init(admissionFenced: true, startsSettled: true, mediaDetached: true, callbacksDrained: true, buffersEmpty: true, workersExited: true) }
        relay = LocalAudioRelay(startup.participants)
        runtime = HostAudioForwardingRuntime(relay: relay, privacy: privacy, fenceMedia: {}, commitMedia: { _ in })
        consumer = Consumer(privacy, runtime)
        consumer.server.sentryAdmission.configure(latched: false, persistenceHealthy: true)
        privacy.forwardingInvalidated = { [unowned self] in runtime.evidenceWillChange();runtime.invalidate() }
        privacy.authenticatedLocalReturnWillCommit = { [unowned self] current in intentClears += 1; return await runtime.returnToLocal(admission: current) }
    }
    func install(_ peer: Peer) {
        let configuration = relay.forwardingConfiguration(privacyGeneration: privacy.forwardingPrivacyGeneration)!
        let intent = try! AudioForwardingSnapshot.Intent(pairedDeviceId: peer.peer.id, intentId: UUID(), intentRevision: .init(1), intentGeneration: UUID(), inputDesired: true, outputDesired: true)
        let binding = AudioForwardingBinding(pairedDeviceId: peer.peer.id, intentGeneration: intent.intentGeneration, bindingEpoch: UUID(), transportId: UUID(), transportKind: .native, operationId: UUID(), phase: .quiescing, configuration: configuration)
        let value = try! AudioForwardingSnapshot(revision: .init(2), intent: intent, binding: binding)
        relay.value = value;runtime.fixtureInstall(peer.context, value: value)
    }
}
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { print("FAIL \(message)");exit(1) }; print("PASS \(message)")
}
@MainActor func settle() async { for _ in 0..<200 { await Task.yield() } }
@MainActor final class Gate {
 var waiters: [CheckedContinuation<Void, Never>] = []
 var entered = false
 func wait() async { entered = true; await withCheckedContinuation { waiters.append($0) } }
 func release() { let current = waiters; waiters.removeAll(); current.forEach { $0.resume() } }
}
@main struct Checks {
    @MainActor static func main() async {
        let f = Fixture(), peer = Peer()
        let started = await f.runtime.start(); check(started && f.privacy.armAndVerify(), "자동복귀 실제 모델 fixture 보호")
        f.install(peer);peer.live = false;f.runtime.disconnected(peer.connection)
        await settle()
        print("CONSUMER_REPRO restores=\(f.hal.restores) normalDrains=\(f.consumer.normalDrains) manualDrains=\(f.consumer.manualDrains) nodeIntentClears=\(f.relay.localReturns)")
        check(f.hal.restores == 1 && !f.privacy.latched, "마지막 현재 native owner detach readback 뒤 실제 모델 자동 복귀")
        check(f.consumer.normalDrains > 0 && f.consumer.manualDrains == 0 && f.authentications == 0 && f.intentClears == 0 && f.relay.localReturns == 0 && f.relay.value.intent != nil, "normal 전용 quiesce와 인증0 및 Node 재연결 intent 보존")
        f.runtime.stop();f.privacy.stop()
        #if NORMAL_CONSUMER
        for mode in ["other-device", "same-device-window", "stale-peer", "failed-detach", "binding-remains", "new-enrollment", "new-intent", "sentry-on", "sentry-failure", "sentry-returning", "new-background-window"] {
            let f = Fixture(), owner = Peer(), other = Peer(mode == "same-device-window" ? "ab" : "cd")
            _ = await f.runtime.start();check(f.privacy.armAndVerify(), "\(mode) fixture 보호")
            f.install(owner)
            let gate = Gate()
            if ["other-device", "same-device-window"].contains(mode) { f.runtime.fixtureAdditional(other.context) }
            if mode == "stale-peer" { f.runtime.fixtureAdditional(other.context);other.live = false;f.runtime.disconnected(other.connection) }
            else {
                if mode == "failed-detach" { f.relay.detachAccepted = false }
                if mode == "binding-remains" { f.relay.detachReadbackBinding = true }
                if ["new-enrollment", "new-intent"].contains(mode) { f.relay.detachGate = { await gate.wait() } }
                if mode == "sentry-on" { _ = f.consumer.server.sentryAdmission.requireProtection(explicit: true) }
                if mode == "sentry-failure" { f.consumer.server.sentryAdmission.update(verified: false, persistenceHealthy: false, reason: "fixture") }
                if mode == "sentry-returning" { f.consumer.server.sentryAdmission.fenceForLocalReturn() }
                if mode == "new-background-window" { f.consumer.normalDrainHook = { await gate.wait() } }
                owner.live = false;f.runtime.disconnected(owner.connection)
                await settle()
                if mode == "new-enrollment" { await f.runtime.fixtureEnrolling(other.context);gate.release() }
                if mode == "new-intent" {
                    let old = f.relay.value.intent!
                    let next = try! AudioForwardingSnapshot.Intent(pairedDeviceId: other.peer.id, intentId: UUID(), intentRevision: .init(old.intentRevision.value + 1), intentGeneration: UUID(), inputDesired: true, outputDesired: true)
                    f.relay.value = try! .init(revision: .init(f.relay.value.revision.value + 1), intent: next, binding: nil);gate.release()
                }
                if mode == "new-background-window" {
                    check(gate.entered, "정상 revoke의 비동기 경계 진입")
                    let peer = NSObject(), admission = f.consumer.server.sentryAdmission
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().async { admission.register(ObjectIdentifier(peer), externalRoute: true);continuation.resume() }
                    }
                    await settle();gate.release()
                }
            }
            await settle()
            check(f.hal.restores == 0 && f.privacy.latched && f.relay.localReturns == 0, "\(mode)은 자동 복귀와 전체 intent 삭제를 거절")
            f.runtime.stop();f.privacy.stop()
        }
        await sentryProofChecks()
        #endif
    }
}

#if NORMAL_CONSUMER
@MainActor func sentryProofChecks() async {
 let a = SentryAdmission();a.configure(latched: false, persistenceHealthy: true)
 check(a.inactiveSnapshot() == nil, "automatic off는 기존 manual owner grant proof가 아님")
 let proof = a.beginNormalOffReturn()!
 check(a.normalOffMatches(proof), "automatic off 전용 authoritative proof")
 let completed = DispatchSemaphore(value: 0)
 DispatchQueue.global().async { a.configure(latched: true, persistenceHealthy: true);completed.signal() }
 check(completed.wait(timeout: .now() + 2) == .success, "background writer는 MainActor drain을 막는 lock 대기 없이 반환")
 check(a.normalOffMatches(proof) && !a.isRequested, "최종 순수 snapshot부터 동기 commit 사이 background state 변경0")
 a.endNormalOffReturn(proof)
 await settle()
 check(a.isRequested && !a.normalOffMatches(proof), "queued 권한 변경은 다음 MainActor 구간에서 proof를 취소하고 적용")
 a.configure(latched: false, persistenceHealthy: true)
 // configure preserves an explicit request, so use a fresh automatic-off authority.
 let b = SentryAdmission();b.configure(latched: false, persistenceHealthy: true)
 let old = b.beginNormalOffReturn()!;b.setLocalReturnRequestActive(true)
 check(!b.normalOffMatches(old) && b.beginNormalOffReturn() == nil, "로컬 인증 pending은 기존 normal proof 취소")
 b.endNormalOffReturn(old)
}
#endif
