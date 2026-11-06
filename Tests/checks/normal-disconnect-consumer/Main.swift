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
        #if NORMAL_CONSUMER
        if CommandLine.arguments.contains("--failed-preparation-only") { await failedPreparationChecks();return }
        #endif
        let f = Fixture(), peer = Peer()
        let started = await f.runtime.start(); check(started && f.privacy.armAndVerify(), "자동복귀 실제 모델 fixture 보호")
        f.install(peer);peer.live = false;f.runtime.disconnected(peer.connection)
        await settle()
        print("CONSUMER_REPRO restores=\(f.hal.restores) normalDrains=\(f.consumer.normalDrains) manualDrains=\(f.consumer.manualDrains) nodeIntentClears=\(f.relay.localReturns)")
        check(f.hal.restores == 1 && !f.privacy.latched, "마지막 현재 native owner detach readback 뒤 실제 모델 자동 복귀")
        check(f.consumer.normalDrains > 0 && f.consumer.manualDrains > 0 && f.authentications == 0 && f.intentClears == 0 && f.relay.localReturns == 0 && f.relay.value.intent != nil, "normal 전용 quiesce와 인증0 및 Node 재연결 intent 보존")
        f.runtime.stop();f.privacy.stop()
        #if NORMAL_CONSUMER
        for mode in ["other-device", "same-device-window", "stale-peer", "failed-detach", "binding-remains", "new-enrollment", "new-intent", "sentry-on", "sentry-failure", "sentry-returning", "new-background-window", "revived-connection", "live-disconnect-call"] {
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
                if mode == "new-background-window" || mode == "revived-connection" { f.consumer.normalDrainHook = { await gate.wait() } }
                owner.live = mode == "live-disconnect-call";f.runtime.disconnected(owner.connection)
                await settle()
                if mode == "new-enrollment" { await f.runtime.fixtureEnrolling(other.context);gate.release() }
                if mode == "new-intent" {
                    let old = f.relay.value.intent!
                    let next = try! AudioForwardingSnapshot.Intent(pairedDeviceId: other.peer.id, intentId: UUID(), intentRevision: .init(old.intentRevision.value + 1), intentGeneration: UUID(), inputDesired: true, outputDesired: true)
                    f.relay.value = try! .init(revision: .init(f.relay.value.revision.value + 1), intent: next, binding: nil);gate.release()
                }
                if mode == "revived-connection" { owner.live = true;gate.release() }
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
        let windows = Fixture(), first = Peer(), second = Peer()
        _ = await windows.runtime.start();check(windows.privacy.armAndVerify(), "같은 기기 두 창 fixture 보호")
        windows.install(first)
        let secondContext = AudioForwardingConnectionContext(peer: first.peer, principal: first.context.principal,
            role: first.context.role, connectionID: second.connection, connectionIsCurrent: { second.live }, isCurrent: { second.live })
        windows.runtime.fixtureAdditional(secondContext)
        first.live = false;windows.runtime.disconnected(first.connection);await settle()
        check(windows.hal.restores == 0, "같은 기기 첫 창 disconnect는 다른 창 입출력 유지")
        second.live = false;windows.runtime.disconnected(second.connection);await settle()
        check(windows.hal.restores == 1 && windows.relay.localReturns == 0, "같은 기기 마지막 창 detach 뒤에만 자동 복귀")
        windows.runtime.stop();windows.privacy.stop()
        await failedPreparationChecks()
        await sentryProofChecks()
        #endif
    }
}

#if NORMAL_CONSUMER
@MainActor func sentryProofChecks() async {
 let disabled = SentryAdmission()
 check(disabled.beginNormalOffReturn() == nil, "미설정 Sentry authority는 정상 off로 추정하지 않음")
 let pending = SentryAdmission(), peer = NSObject()
 pending.configure(latched: false, persistenceHealthy: true)
 let identity = ObjectIdentifier(peer)
 pending.register(identity, externalRoute: true);pending.admit(identity)
 let grant = pending.grantControl(to: identity, verifiedOwner: .init(deviceID: String(repeating: "a", count: 64), encryptedTLS: true, currentPairedOwner: true)!)!
 let state = pending.status(for: identity)!
 let request = try! SentryControlRequest(hostBootID: state.hostBootID, sessionID: state.sessionID, revision: state.revision, authorizationGeneration: grant, desired: false)
 if case .prepared = pending.prepareControl(request, from: identity) {} else { check(false, "Sentry pending fixture 진입") }
 check(pending.status(for: identity)?.phase == .pending && pending.beginNormalOffReturn() == nil, "실제 Sentry control pending은 normal off proof 거절")
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
 let ordered = SentryAdmission(), orderedPeer = NSObject()
 ordered.configure(latched: false, persistenceHealthy: true)
 let orderedProof = ordered.beginNormalOffReturn()!
 let orderedDone = DispatchSemaphore(value: 0)
 DispatchQueue.global().async { ordered.register(ObjectIdentifier(orderedPeer), externalRoute: true);orderedDone.signal() }
 check(orderedDone.wait(timeout: .now() + 2) == .success, "background register enqueue 완료")
 ordered.admit(ObjectIdentifier(orderedPeer))
 check(ordered.allowsActions(ObjectIdentifier(orderedPeer)) && !ordered.normalOffMatches(orderedProof),
       "MainActor admit은 먼저 enqueue된 register를 추월하지 않고 기존 normal proof 취소")
 ordered.endNormalOffReturn(orderedProof)
 let detached = SentryAdmission(), detachedPeer = NSObject()
 detached.configure(latched: false, persistenceHealthy: true)
 let detachedProof = detached.beginNormalOffReturn()!
 let detachDone = DispatchSemaphore(value: 0)
 DispatchQueue.global().async { detached.register(ObjectIdentifier(detachedPeer), externalRoute: true);detachDone.signal() }
 check(detachDone.wait(timeout: .now() + 2) == .success, "lease 종료 전 register enqueue 완료")
 detached.endNormalOffReturn(detachedProof)
 DispatchQueue.global().async { detached.remove(ObjectIdentifier(detachedPeer));detachDone.signal() }
 check(detachDone.wait(timeout: .now() + 2) == .success, "lease 종료 후 remove enqueue 완료")
 await settle()
 let drained = detached.beginNormalOffReturn()
 check(drained != nil, "lease 종료를 사이에 둔 register/remove 순서 보존으로 유령 session 0")
 if let drained { detached.endNormalOffReturn(drained) }
 let b = SentryAdmission();b.configure(latched: false, persistenceHealthy: true)
 let old = b.beginNormalOffReturn()!;b.setLocalReturnRequestActive(true)
 check(!b.normalOffMatches(old) && b.beginNormalOffReturn() == nil, "로컬 인증 pending은 기존 normal proof 취소")
 b.endNormalOffReturn(old)
}
#endif

#if NORMAL_CONSUMER
@MainActor func failedPreparationChecks() async {
 for mode in ["responsible", "past-other-device", "unattributed", "new-intent-generation"] {
  let f = Fixture(), owner = Peer(), other = Peer("cd")
  _ = await f.runtime.start();check(f.privacy.armAndVerify(), "rev32 \(mode) fixture 보호")
  let intent = try! AudioForwardingSnapshot.Intent(pairedDeviceId: mode == "past-other-device" ? other.peer.id : owner.peer.id,
      intentId: UUID(), intentRevision: .init(32), intentGeneration: UUID(), inputDesired: false, outputDesired: false)
  let value = try! AudioForwardingSnapshot(revision: .init(32), intent: intent, binding: nil)
  f.relay.value = value
  f.runtime.fixtureFailed(owner.context, value: value, proven: mode != "unattributed")
  if mode == "new-intent-generation" {
   let next = try! AudioForwardingSnapshot.Intent(pairedDeviceId: owner.peer.id, intentId: UUID(), intentRevision: .init(33), intentGeneration: UUID(), inputDesired: false, outputDesired: false)
   f.relay.value = try! .init(revision: .init(33), intent: next, binding: nil)
   f.runtime.fixtureObserve(f.relay.value)
  }
  owner.live = false;f.runtime.disconnected(owner.connection);await settle()
  print("FAILED_PREPARATION_REPRO mode=\(mode) input=false output=false localMuted=true restores=\(f.hal.restores) localReturnClears=\(f.relay.localReturns)")
  check(f.hal.restores == (mode == "responsible" ? 1 : 0) && f.relay.localReturns == 0 && f.relay.value.intent != nil,
        "rev32 \(mode): 실패한 현재 책임 세대만 자동 복귀하고 과거·미확인·새 intent는 유지")
  f.runtime.stop();f.privacy.stop()
 }
}
#endif
