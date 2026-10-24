import Foundation

@MainActor final class ReturnGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    var exited = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        exited = true
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class ReturnFixture {
    let startup = NativeAudioStartup()
    var registry: LocalAudioParticipantRegistry { startup.participants }
    let generation = UUID()
    var nativeGate: ReturnGate?
    var relayGate: ReturnGate?
    var nativeStopped = false
    var relayRequest: LocalAudioParticipantRequest?
    var unknownInspection = false
    var corruptInspection = false
    var inspectionGate: ReturnGate?
    var inspections = 0
    var nativeStops = 0
    var relayStops = 0
    var inspectHook: (() -> Void)?

    init() {
        startup.construct { () }
        startup.revoke = {
            self.nativeStops += 1
            if let gate = self.nativeGate { await gate.wait() }
            self.nativeStopped = true
            return true
        }
        startup.readFacts = { self.facts(self.nativeStopped) }
        registerRelay()
    }
    func facts(_ stopped: Bool) -> LocalAudioParticipantFacts {
        .init(admissionFenced: registry.isFenced, startsSettled: stopped, mediaDetached: stopped,
              callbacksDrained: stopped, buffersEmpty: stopped, workersExited: stopped)
    }
    func registerRelay() {
        registry.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: { request in
            self.relayStops += 1
            self.relayRequest = request
            if let gate = self.relayGate { await gate.wait() }
            return .init(request, state: .quiescent, facts: self.facts(true))
        }, inspect: { id in
            self.inspections += 1
            if let gate = self.inspectionGate { await gate.wait() }
            let hook = self.inspectHook; self.inspectHook = nil; hook?()
            guard let request = self.relayRequest, request.operationId == id else { return nil }
            if self.unknownInspection { return .init(request, state: .unknown, facts: .unknown) }
            let identity = self.corruptInspection ? LocalAudioParticipantRequest(schemaVersion: 1,
                operationId: UUID(), privacyGeneration: request.privacyGeneration,
                registryRevision: request.registryRevision, participantId: request.participantId,
                bootId: request.bootId, budgetMilliseconds: request.budgetMilliseconds) : request
            return .init(identity, state: .quiescent, facts: self.facts(true))
        }, supportsForwarding: true, forwardingPrepare: { _ in nil }))
    }
    func poisonInspection() async {
        let operation = UUID(), membership = registry.snapshot
        let ticket = registry.beginLocalReturn(operationId: operation, privacyGeneration: generation, membership: membership)!
        check(await registry.fenceAndQuiesce(operationId: operation, privacyGeneration: generation,
            membership: membership, budgetMilliseconds: 2000), "initial quiescence succeeds")
        unknownInspection = true
        check(!(await registry.inspectAll(operationId: operation, privacyGeneration: generation,
            membership: membership)), "unknown inspection fails closed")
        registry.endLocalReturn(ticket)
        check(registry.authenticatedLocalReturnUnavailableReason == "이전 로컬 복귀의 실제 종료를 확인할 수 없습니다.", "observed UI reason reproduced")
        unknownInspection = false
    }
}

@MainActor var assertionCount = 0
@MainActor func check(_ value: Bool, _ label: String) {
    guard value else { print("FAIL \(label)"); exit(1) }
    assertionCount += 1
    print("PASS \(label)")
}
@MainActor func settle(_ ready: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !ready(), ContinuousClock.now < deadline { await Task.yield() }
    check(ready(), "bounded callback observation")
}

@MainActor func runChecks() async {
    let authentication = ReturnFixture()
    await authentication.poisonInspection()
    let hal = ReturnHAL()
    var authenticationCalls = 0
    let privacy = HostAudioPrivacy(hal: hal, latched: true,
        localState: try! LocalAudioState(hal.snapshot), authenticateLocal: { _ in
            authenticationCalls += 1
            return false
        }, nativeStartup: authentication.startup)
    privacy.inspectForLocalReturn = { authentication.facts(authentication.nativeStopped) }
    check(!(await privacy.requestLocalReturn(budgetMilliseconds: 2000)), "declined authentication retains local protection")
    check(authenticationCalls == 1, "settled operation is re-inspected before a fresh OS authentication request")
    check(privacy.latched && hal.writes == 0 && hal.restores == 0, "recovery never supplies authentication approval or restores audio")
    privacy.stop()

#if RECOVERY
    let f = ReturnFixture()
    await f.poisonInspection()
    let membership = f.registry.snapshot
    let blocked = f.registry.beginLocalReturn(operationId: UUID(), privacyGeneration: f.generation, membership: membership)
    check(blocked == nil, "uncertain operation cannot be erased by a new ticket")
    let recovered = await f.registry.recoverClosedLocalReturn(until: .now.advanced(by: .seconds(2)))
    check(recovered, "fresh inspection of settled operation allows a new authentication")
    check(f.registry.isFenced && f.registry.authenticatedLocalReturnUnavailableReason == nil,
          "recovery retains media fence and clears only proven uncertainty")
    check(f.nativeStops == 1 && f.relayStops == 1 && f.inspections == 2,
          "recovery reads receipts without repeating effects")
    check(f.registry.beginLocalReturn(operationId: UUID(), privacyGeneration: f.generation, membership: membership) != nil,
          "new local return still requires its own ticket")

    for failure in ["unknown", "identity", "membership", "cancel", "timeout"] {
        let f = ReturnFixture()
        await f.poisonInspection()
        switch failure {
        case "unknown": f.unknownInspection = true
        case "identity": f.corruptInspection = true
        case "membership": f.inspectHook = { f.registerRelay() }
        default: break
        }
        let gate = ReturnGate()
        if failure == "cancel" || failure == "timeout" { f.inspectionGate = gate }
        let work = Task { await f.registry.recoverClosedLocalReturn(until: .now.advanced(by:
            failure == "timeout" ? .milliseconds(50) : .seconds(2))) }
        if failure == "cancel" { await settle { gate.entered }; work.cancel() }
        check(!(await work.value), "\(failure) recovery fails closed")
        if gate.entered {
            check(f.registry.authenticatedLocalReturnUnavailableReason != nil, "pending inspection retains uncertainty")
            gate.release()
            await settle { gate.exited }
        }
        check(f.registry.isFenced && f.registry.authenticatedLocalReturnUnavailableReason != nil,
              "\(failure) never clears uncertainty or media fence")
        if failure == "cancel" || failure == "timeout" {
            f.inspectionGate = nil
            for _ in 0..<20 { await Task.yield() }
            check(await f.registry.recoverClosedLocalReturn(until: .now.advanced(by: .seconds(2))),
                  "\(failure) terminal callback requires fresh inspection before recovery")
            check(f.registry.isFenced, "recovery after \(failure) keeps media fenced")
        }
    }

    let late = ReturnFixture(), gate = ReturnGate()
    late.nativeGate = gate
    let operation = UUID(), snapshot = late.registry.snapshot
    let ticket = late.registry.beginLocalReturn(operationId: operation, privacyGeneration: late.generation, membership: snapshot)!
    check(!(await late.registry.fenceAndQuiesce(operationId: operation, privacyGeneration: late.generation,
        membership: snapshot, budgetMilliseconds: 50)), "late native callback times out")
    late.registry.endLocalReturn(ticket)
    check(!(await late.registry.recoverClosedLocalReturn(until: .now.advanced(by: .milliseconds(50)))),
          "active stop cannot be recovered")
    gate.release()
    await settle { gate.exited }
    for _ in 0..<20 { await Task.yield() }
    check(!(await late.registry.recoverClosedLocalReturn(until: .now.advanced(by: .seconds(2)))),
          "late native termination alone cannot prove an unprepared relay stopped")
    check(late.registry.isFenced && late.relayStops == 0, "unprepared participant remains fenced")

    let relay = ReturnFixture(), relayGate = ReturnGate()
    relay.relayGate = relayGate
    let relayOperation = UUID(), relaySnapshot = relay.registry.snapshot
    let relayTicket = relay.registry.beginLocalReturn(operationId: relayOperation,
        privacyGeneration: relay.generation, membership: relaySnapshot)!
    check(!(await relay.registry.fenceAndQuiesce(operationId: relayOperation, privacyGeneration: relay.generation,
        membership: relaySnapshot, budgetMilliseconds: 50)), "relay terminal callback outlives original deadline")
    relay.registry.endLocalReturn(relayTicket)
    check(!(await relay.registry.recoverClosedLocalReturn(until: .now.advanced(by: .seconds(2)))),
          "pending relay stop cannot be recovered")
    relayGate.release()
    await settle { relayGate.exited }
    for _ in 0..<20 { await Task.yield() }
    check(await relay.registry.recoverClosedLocalReturn(until: .now.advanced(by: .seconds(2))),
          "late relay completion plus fresh native and relay inspection permits new authentication")
    check(relay.registry.isFenced && relay.nativeStops == 1 && relay.relayStops == 1,
          "late completion never repeats stops or opens the media fence")
#endif
    print("PASS \(assertionCount) authentication-return checks; actual LA/HAL/UI/journal/device actions 0")
}

@MainActor final class ReturnHAL: HostAudioPrivacyHAL {
    let snapshot = PrivacyAudioSnapshot(devices: [
        .init(id: 1, uid: "fixture-input", transport: .builtIn, plugin: nil,
              inputChannels: 1, outputChannels: 0, inputMuted: false, outputMuted: nil),
        .init(id: 2, uid: "fixture-output", transport: .builtIn, plugin: nil,
              inputChannels: 0, outputChannels: 2, inputMuted: nil, outputMuted: false)
    ], input: 1, output: 2, systemOutput: 2)
    var writes = 0, restores = 0
    func read() throws -> PrivacyAudioSnapshot { snapshot }
    func write(_ change: PrivacyAudioWrite) -> Bool { writes += 1; return false }
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool { true }
    func restoreLocal(_ state: LocalAudioState) -> Bool { restores += 1; return false }
}

Task { @MainActor in await runChecks(); exit(0) }
dispatchMain()
