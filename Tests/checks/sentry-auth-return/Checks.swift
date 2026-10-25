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
    var relayQuiesceHook: (() -> Void)?
    var inspectionReceipt: ((LocalAudioParticipantRequest) -> LocalAudioParticipantReceipt)?

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
            self.relayQuiesceHook?()
            return .init(request, state: .quiescent, facts: self.facts(true))
        }, inspect: { id in
            self.inspections += 1
            if let gate = self.inspectionGate { await gate.wait() }
            let hook = self.inspectHook; self.inspectHook = nil; hook?()
            guard let request = self.relayRequest, request.operationId == id else { return nil }
            if self.unknownInspection { return .init(request, state: .unknown, facts: .unknown) }
            if let inspectionReceipt = self.inspectionReceipt { return inspectionReceipt(request) }
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
    for outcome in ["settle", "deadline", "cancel", "membership"] {
        let fixture = ReturnFixture(), hal = ReturnHAL(), queuedStop = ReturnGate()
        let lifecycle = RemoteAudioCaptureLifecycle()
        var stops = 0, intentClears = 0, latchClears = 0, finished = false
        hal.restoreSucceeds = true
        let privacy = HostAudioPrivacy(hal: hal, latched: true,
            localState: try! LocalAudioState(hal.snapshot),
            clearLatch: { latchClears += 1; return true }, authenticateLocal: { _ in true },
            nativeStartup: fixture.startup)
        privacy.revokeForLocalReturn = {
            stops += 1
            await lifecycle.waitUntilIdle()
            return lifecycle.isIdle
        }
        privacy.inspectForLocalReturn = {
            .init(admissionFenced: fixture.registry.isFenced, startsSettled: lifecycle.isIdle,
                  mediaDetached: lifecycle.isIdle, callbacksDrained: lifecycle.isIdle,
                  buffersEmpty: true, workersExited: lifecycle.isIdle)
        }
        fixture.relayQuiesceHook = {
            check(stops == 1 && lifecycle.isIdle, "relay 중지 전 native 첫 종료는 실제 idle")
            lifecycle.enqueueStop { await queuedStop.wait() }
        }
        privacy.authenticatedLocalReturnWillCommit = { admission in
            guard admission() else { return false }
            intentClears += 1
            return true
        }
        let task = Task {
            let result = await privacy.requestLocalReturn(budgetMilliseconds: outcome == "deadline" ? 100 : 2_000)
            finished = true
            return result
        }
        await settle { queuedStop.entered && (stops >= 2 || finished) }
        print("첫 재조회 경계 outcome=\(outcome) stops=\(stops) finished=\(finished) idle=\(lifecycle.isIdle) buffersEmpty=true HAL=\(hal.restores) latch=\(latchClears)")
        check(!finished && stops == 2 && !lifecycle.isIdle,
              "뒤 참여자가 예약한 native Stop을 첫 재조회 전에 기다림")
        check(hal.restores == 0 && latchClears == 0 && intentClears == 0 && fixture.registry.isFenced,
              "첫 재조회 전 Stop 대기 중 HAL·latch·intent 해제는 0")
        if outcome == "cancel" { task.cancel() }
        if outcome == "membership" { fixture.registry.unregister(.relay) }
        if outcome != "deadline" { queuedStop.release() }
        let result = await task.value
        if outcome == "settle" {
            check(result && lifecycle.isIdle && hal.restores == 1 && latchClears == 1 && intentClears == 1,
                  "후속 Stop 종료·새 증거 확인 뒤 같은 인증 요청으로 한 번만 복귀")
        } else {
            check(!result && privacy.latched && hal.restores == 0 && latchClears == 0 && intentClears == 0,
                  "\(outcome) 변경은 새 barrier 뒤에도 보호 해제 거절")
            if outcome == "deadline" { queuedStop.release() }
            await settle { queuedStop.exited }
            check(privacy.latched && hal.restores == 0 && latchClears == 0,
                  "\(outcome) 이후 늦은 native 종료는 HAL·latch를 해제하지 않음")
        }
        privacy.stop()
    }
    for expire in [false, true] {
        let fixture = ReturnFixture(), hal = ReturnHAL(), newlyQueuedStop = ReturnGate()
        var stops = 0, intentClears = 0, latchClears = 0
        hal.restoreSucceeds = true
        let privacy = HostAudioPrivacy(hal: hal, latched: true,
            localState: try! LocalAudioState(hal.snapshot),
            clearLatch: { latchClears += 1; return true }, authenticateLocal: { _ in true },
            nativeStartup: fixture.startup)
        privacy.revokeForLocalReturn = {
            stops += 1
            if stops == 2 { await newlyQueuedStop.wait() }
            fixture.nativeStopped = true
            return true
        }
        privacy.inspectForLocalReturn = { fixture.facts(fixture.nativeStopped) }
        privacy.authenticatedLocalReturnWillCommit = { admission in
            guard admission() else { return false }
            intentClears += 1
            fixture.nativeStopped = false
            return true
        }
        let task = Task { await privacy.requestLocalReturn(budgetMilliseconds: expire ? 100 : 2_000) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !newlyQueuedStop.entered, ContinuousClock.now < deadline { await Task.yield() }
        check(newlyQueuedStop.entered, "intent 해제가 새로 예약한 native Stop을 최종 검사 전에 기다림")
        check(intentClears == 1 && latchClears == 0 && hal.restores == 0 && fixture.registry.isFenced,
              "새 Stop이 진행 중인 동안 HAL·latch·입력 복귀로 진행하지 않음")
        if expire {
            check(!(await task.value), "intent 후 Stop 대기가 기한을 넘으면 복귀 거절")
            newlyQueuedStop.release()
            for _ in 0..<30 { await Task.yield() }
            check(privacy.latched && latchClears == 0 && hal.restores == 0,
                  "늦게 끝난 Stop은 만료된 복귀의 HAL·latch를 해제하지 않음")
        } else {
            newlyQueuedStop.release()
            check(await task.value, "같은 요청의 실제 native Stop 종료 후 로컬 복귀 완료")
            check(stops == 2 && latchClears == 1 && hal.restores == 1 && !privacy.latched,
                  "검증된 두 번째 종료 뒤 HAL과 latch는 한 번만 복귀")
        }
        privacy.stop()
    }
    for unavailable in ["participants", "startup", "original", "recovery"] {
        let fixture = ReturnFixture(), hal = ReturnHAL()
        if unavailable == "participants" { fixture.registry.unregister(.relay) }
        if unavailable == "recovery" {
            await fixture.poisonInspection()
            fixture.unknownInspection = true
        }
        let startup = unavailable == "startup" ? NativeAudioStartup() : fixture.startup
        if unavailable == "startup" {
            startup.participants.register(.relay, bootId: UUID(), control: .init(
                fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
        }
        var calls = 0, commits = 0, clears = 0
        let privacy = HostAudioPrivacy(hal: hal, latched: true,
            localState: unavailable == "original" ? nil : try! LocalAudioState(hal.snapshot),
            clearLatch: { clears += 1; return true }, authenticateLocal: { _ in
                calls += 1
                check(hal.restores == 0 && clears == 0 && commits == 0,
                      "\(unavailable) starts authentication before any release")
                return false
            }, nativeStartup: startup)
        privacy.authenticatedLocalReturnWillCommit = { _ in commits += 1; return true }
        check(!(await privacy.requestLocalReturn(budgetMilliseconds: 50)), "\(unavailable) declined authentication retains protection")
        check(calls == 1, "\(unavailable) requests owner authentication exactly once despite unavailable preparation")
        check(privacy.latched && hal.restores == 0 && clears == 0 && commits == 0,
              "\(unavailable) never treats an authentication request as approval")
        privacy.stop()
    }

    for unavailable in ["participants", "startup", "original", "recovery"] {
        let fixture = ReturnFixture(), hal = ReturnHAL()
        if unavailable == "participants" { fixture.registry.unregister(.relay) }
        if unavailable == "recovery" {
            await fixture.poisonInspection()
            fixture.unknownInspection = true
        }
        let startup = unavailable == "startup" ? NativeAudioStartup() : fixture.startup
        if unavailable == "startup" {
            startup.participants.register(.relay, bootId: UUID(), control: .init(
                fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
        }
        var calls = 0, commits = 0, clears = 0
        let privacy = HostAudioPrivacy(hal: hal, latched: true,
            localState: unavailable == "original" ? nil : try! LocalAudioState(hal.snapshot),
            clearLatch: { clears += 1; return true }, authenticateLocal: { _ in calls += 1; return true },
            nativeStartup: startup)
        privacy.authenticatedLocalReturnWillCommit = { _ in commits += 1; return true }
        check(!(await privacy.requestLocalReturn(budgetMilliseconds: 50)), "\(unavailable) authenticated preparation still fails closed")
        check(calls == 1 && privacy.latched && hal.restores == 0 && clears == 0 && commits == 0,
              "\(unavailable) authentication success alone cannot release protection")
        check(privacy.localReturnStatusReason?.contains("인증은 완료") == true,
              "\(unavailable) explains post-authentication preparation failure separately")
        privacy.stop()
    }

    let duplicateFixture = ReturnFixture(), duplicateHAL = ReturnHAL(), authenticationGate = ReturnGate()
    var duplicateCalls = 0
    let duplicatePrivacy = HostAudioPrivacy(hal: duplicateHAL, latched: true,
        localState: try! LocalAudioState(duplicateHAL.snapshot), authenticateLocal: { _ in
            duplicateCalls += 1; await authenticationGate.wait(); return false
        }, nativeStartup: duplicateFixture.startup)
    let firstRequest = Task { await duplicatePrivacy.requestLocalReturn() }
    await settle { authenticationGate.entered }
    check(!(await duplicatePrivacy.requestLocalReturn()) && duplicateCalls == 1,
          "duplicate button click does not issue another authentication")
    authenticationGate.release()
    check(!(await firstRequest.value) && duplicatePrivacy.latched && duplicateHAL.restores == 0,
          "declined first authentication retains protection after duplicate click")
    duplicatePrivacy.stop()

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
    let expired = ReturnFixture()
    let expiredOperation = UUID(), expiredMembership = expired.registry.snapshot
    let expiredTicket = expired.registry.beginLocalReturn(operationId: expiredOperation,
        privacyGeneration: expired.generation, membership: expiredMembership)!
    check(await expired.registry.fenceAndQuiesce(operationId: expiredOperation, privacyGeneration: expired.generation,
        membership: expiredMembership, budgetMilliseconds: 2000), "relay stops before its receipt expires")
    expired.inspectionReceipt = { .init($0, state: .blocked, facts: expired.facts(true), reason: "budget_exhausted") }
    check(!(await expired.registry.inspectAll(operationId: expiredOperation, privacyGeneration: expired.generation,
        membership: expiredMembership)), "expired relay receipt is never ordinary inspection proof")
    expired.registry.endLocalReturn(expiredTicket)
    check(await expired.registry.recoverClosedLocalReturn(until: .now.advanced(by: .seconds(2))),
          "expired terminal relay receipt closes only the previous uncertain return")
    check(expired.registry.isFenced && !expired.registry.proofCurrent(operationId: expiredOperation,
        privacyGeneration: expired.generation, membership: expiredMembership), "closure neither opens media nor revives the old proof")
    check(expired.nativeStops == 1 && expired.relayStops == 1, "expired closure does not repeat participant stops")
    let ordinaryExpired = LocalAudioParticipantReceipt(expired.relayRequest!, state: .blocked,
        facts: expired.facts(true), reason: "budget_exhausted")
    check(!ordinaryExpired.proves(expired.relayRequest!), "ordinary proves still rejects expired terminal relay receipts")
    check(expired.registry.beginLocalReturn(operationId: UUID(), privacyGeneration: expired.generation,
        membership: expiredMembership) != nil, "closure permits only a fresh local return ticket")

    let invalidExpired = ["schema", "operation", "generation", "revision", "participant", "boot", "state", "reason"] +
        LocalAudioParticipantFacts.CodingKeys.allCases.flatMap { [$0.rawValue + ".false", $0.rawValue + ".nil"] }
    for failure in invalidExpired {
        let f = ReturnFixture()
        await f.poisonInspection()
        f.inspectionReceipt = { request in
            let identity = LocalAudioParticipantRequest(schemaVersion: failure == "schema" ? 2 : request.schemaVersion,
                operationId: failure == "operation" ? UUID() : request.operationId,
                privacyGeneration: failure == "generation" ? UUID() : request.privacyGeneration,
                registryRevision: failure == "revision" ? "999" : request.registryRevision,
                participantId: failure == "participant" ? .native : request.participantId,
                bootId: failure == "boot" ? UUID() : request.bootId, budgetMilliseconds: request.budgetMilliseconds)
            func fact(_ name: String) -> Bool? { failure == name + ".nil" ? nil : failure != name + ".false" }
            let facts = LocalAudioParticipantFacts(admissionFenced: fact("admissionFenced"), startsSettled: fact("startsSettled"),
                mediaDetached: fact("mediaDetached"), callbacksDrained: fact("callbacksDrained"),
                buffersEmpty: fact("buffersEmpty"), workersExited: fact("workersExited"))
            return .init(identity, state: failure == "state" ? .unknown : .blocked, facts: facts,
                reason: failure == "reason" ? "private-reason-must-not-be-logged" : "budget_exhausted")
        }
        check(!(await f.registry.recoverClosedLocalReturn(until: .now.advanced(by: .seconds(2)))),
              "invalid expired \(failure) retains uncertainty")
        check(f.registry.isFenced && f.registry.authenticatedLocalReturnUnavailableReason != nil,
              "invalid expired \(failure) never admits another return")
    }

    let nativeExpired = ReturnFixture()
    var nativeRequest: LocalAudioParticipantRequest?, nativeReceiptExpired = false
    nativeExpired.registry.register(.native, bootId: UUID(), control: .init(fenceAndQuiesce: { request in
        nativeRequest = request
        return .init(request, state: .quiescent, facts: nativeExpired.facts(true))
    }, inspect: { _ in
        nativeRequest.map { .init($0, state: nativeReceiptExpired ? .blocked : .quiescent,
            facts: nativeExpired.facts(true), reason: nativeReceiptExpired ? "budget_exhausted" : nil) }
    }, supportsForwarding: true, forwardingPrepare: { _ in nil }))
    await nativeExpired.poisonInspection()
    nativeReceiptExpired = true
    check(!(await nativeExpired.registry.recoverClosedLocalReturn(until: .now.advanced(by: .seconds(2)))),
          "native participant cannot use the relay-only expired closure")
    check(nativeExpired.registry.isFenced && nativeExpired.registry.authenticatedLocalReturnUnavailableReason != nil,
          "native expiry retains uncertainty and the media fence")

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
    var restoreSucceeds = false
    func read() throws -> PrivacyAudioSnapshot { snapshot }
    func write(_ change: PrivacyAudioWrite) -> Bool { writes += 1; return false }
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool { true }
    func restoreLocal(_ state: LocalAudioState) -> Bool { restores += 1; return restoreSucceeds }
}

Task { @MainActor in await runChecks(); exit(0) }
dispatchMain()
