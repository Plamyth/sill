import Foundation
import StreamProtocol

@MainActor
private final class ReturnHAL: HostAudioPrivacyHAL {
    var snapshot = PrivacyFakeHAL().snapshot
    var restoreCalls = 0
    var restoreSucceeds = true
    var readFailures = 0
    var writes = 0
    var beforeObservationStop: (() -> Void)?
    var afterRestore: (() -> Void)?
    func read() throws -> PrivacyAudioSnapshot {
        if readFailures > 0 { readFailures -= 1; throw PrivacyAudioFailure.readback }
        return snapshot
    }
    func write(_ change: PrivacyAudioWrite) -> Bool {
        writes += 1
        switch change {
        case .mute(let id, let scope):
            guard let index = snapshot.devices.firstIndex(where: { $0.id == id }) else { return false }
            if scope == .input { snapshot.devices[index].inputMuted = true }
            else { snapshot.devices[index].outputMuted = true }
        case .select(let kind, let id):
            switch kind { case .input: snapshot.input = id; case .output: snapshot.output = id; case .systemOutput: snapshot.systemOutput = id }
        case .deactivateStream:
            guard let next = snapshot.applying(change) else { return false }
            snapshot = next
        }
        return true
    }
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool {
        if changed == nil { beforeObservationStop?() }
        return true
    }
    func restoreLocal(_ original: LocalAudioState) -> Bool {
        restoreCalls += 1
        guard restoreSucceeds else { return false }
        for index in snapshot.devices.indices {
            guard let saved = original.devices.first(where: { $0.uid == snapshot.devices[index].uid }) else { return false }
            snapshot.devices[index].inputMuted = saved.inputMuted
            snapshot.devices[index].outputMuted = saved.outputMuted
        }
        snapshot.input = snapshot.devices.first { $0.uid == original.inputUID }!.id
        snapshot.output = snapshot.devices.first { $0.uid == original.outputUID }!.id
        snapshot.systemOutput = snapshot.devices.first { $0.uid == original.systemOutputUID }!.id
        afterRestore?()
        return true
    }
}

@MainActor
private final class ReturnFixture {
    let hal = ReturnHAL()
    let startup = NativeAudioStartup()
    var privacy: HostAudioPrivacy!
    var accepted = true
    var authCalls = 0
    var authHook: (() -> Void)?
    var quiescent = true
    var stored: Data?
    var journal: LocalAudioJournal!
    var durable: Bool { journal.latched }
    var commits = 0
    var original: LocalAudioState? { journal.original }
    var intentCommits = 0
    var intentAccepted = true
    var persistenceAccepted = true
    var clearAccepted = true
    var clearHook: (() -> Void)?
    var intentHook: ((@escaping @MainActor () -> Bool) async -> Bool)?
    let facts = LocalAudioParticipantFacts(admissionFenced: true, startsSettled: true, mediaDetached: true,
        callbacksDrained: true, buffersEmpty: true, workersExited: true)

    init(relay: Bool = true, forwarding: Bool = false) {
        journal = LocalAudioJournal(data: nil, store: { [unowned self] in if persistenceAccepted { stored = $0 } },
            load: { [unowned self] in stored }, synchronize: { [unowned self] in persistenceAccepted })
        let journal = journal!
        // PRODUCTION_JOURNAL_CALLBACKS
        privacy = HostAudioPrivacy(hal: hal,
            // PRODUCTION_JOURNAL_ARGUMENTS
            authenticateLocal: { [unowned self] _ in authCalls += 1; authHook?(); return accepted },
            nativeStartup: startup)
        _ = startup.construct { true }
        privacy.revokeForLocalReturn = { [unowned self] in quiescent }
        privacy.inspectForLocalReturn = { [unowned self] in quiescent ? facts : .unknown }
        privacy.authenticatedLocalReturnWillCommit = { [unowned self] admission in
            expect(authCalls == intentCommits + 1 && privacy.participants.isFenced && hal.restoreCalls == 0 && commits == 0 && admission(),
                   "원격 의도 commit은 실제 인증·참여자 drain 뒤 로컬 복원 전에 실행")
            expect(!privacy.forwardingIntentAllowed && !privacy.armAndVerify(),
                   "비동기 원격 의도 commit 중 새 intent와 arm 거부")
            intentCommits += 1
            if let intentHook { return await intentHook(admission) }
            return intentAccepted
        }
        if relay {
            startup.participants.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: { [unowned self] request in
                relayRequest = request
                return .init(request, state: quiescent ? .quiescent : .unknown, facts: quiescent ? facts : .unknown)
            }, inspect: { [unowned self] id in
                guard let request = relayRequest, request.operationId == id else { return nil }
                return .init(request, state: quiescent ? .quiescent : .unknown, facts: quiescent ? facts : .unknown)
            }, supportsForwarding: forwarding, forwardingPrepare: { [unowned self] preparation in
                .init(preparation.request, state: quiescent ? .quiescent : .unknown,
                      facts: quiescent ? facts : .unknown)
            }))
        }
    }
    var relayRequest: LocalAudioParticipantRequest?
}

@MainActor
func localReturnChecks() async {
    armRecoveryChecks()
    await normalDisconnectReturnChecks()
    let expiredRemoval = ReturnFixture()
    expect(expiredRemoval.privacy.armAndVerify(), "감시 종료 중 기한 만료 fixture 보호")
    var observationStopEntered = false
    var observationStopElapsed = Duration.zero
    expiredRemoval.hal.beforeObservationStop = {
        observationStopEntered = true
        let start = ContinuousClock.now
        Thread.sleep(forTimeInterval: 0.6)
        observationStopElapsed = start.duration(to: ContinuousClock.now)
    }
    let expiredRemovalResult = await expiredRemoval.privacy.requestLocalReturn(budgetMilliseconds: 500)
    expect(observationStopEntered && observationStopElapsed >= .milliseconds(500) && !expiredRemovalResult &&
           expiredRemoval.hal.restoreCalls == 0 && expiredRemoval.commits == 0 && expiredRemoval.durable,
           "감시 종료 중 기한이 만료되면 실제 복원 시작 전 거부")
    expiredRemoval.hal.beforeObservationStop = nil
    expiredRemoval.privacy.stop()
    let success = ReturnFixture()
    expect(success.privacy.forwardingIntentAllowed, "인증 전 원격 intent 허용")
    success.authHook = {
        expect(!success.privacy.forwardingIntentAllowed && !success.privacy.armAndVerify(),
               "LA 인증 시작 즉시 원격 intent와 arm 차단")
    }
    expect(success.privacy.armAndVerify(), "복귀 전 주입 장치 전체 차단")
    let original = success.original!
    let succeeded = await success.privacy.requestLocalReturn()
    expect(succeeded, "본인 인증과 두 참여자 종료 뒤 로컬 복귀")
    expect(!success.privacy.latched && !success.durable && success.commits == 1 && success.intentCommits == 1 &&
           success.privacy.forwardingIntentAllowed && original.matches(success.hal.snapshot),
           "원래 장치와 음소거 readback 뒤에만 영속 latch 해제")
    success.privacy.stop()

    let denied = ReturnFixture(); denied.accepted = false
    expect(denied.privacy.armAndVerify(), "인증 거부 fixture 차단")
    let deniedResult = await denied.privacy.requestLocalReturn()
    expect(!deniedResult && denied.hal.restoreCalls == 0 && denied.privacy.latched && denied.intentCommits == 0 &&
           denied.privacy.forwardingIntentAllowed,
           "인증 거부 시 장치 복원과 latch 해제 없음")
    denied.privacy.stop()

    let missing = ReturnFixture(relay: false)
    expect(missing.privacy.armAndVerify(), "참여자 누락 fixture 차단")
    let missingResult = await missing.privacy.requestLocalReturn()
    expect(!missingResult && missing.authCalls == 1 && missing.privacy.latched &&
           missing.hal.restoreCalls == 0 && missing.intentCommits == 0,
           "실제 relay 미연결에도 인증은 요청하고 복원은 차단")
    missing.privacy.stop()

    let unsettled = ReturnFixture(); unsettled.quiescent = false
    expect(unsettled.privacy.armAndVerify(), "미완료 종료 fixture 차단")
    let unsettledResult = await unsettled.privacy.requestLocalReturn()
    expect(!unsettledResult && unsettled.hal.restoreCalls == 0 && unsettled.privacy.latched && unsettled.intentCommits == 0,
           "unknown 종료 영수증은 로컬 복귀 불가")
    unsettled.privacy.stop()

    let race = ReturnFixture()
    expect(race.privacy.armAndVerify(), "인증 세대 경합 fixture 차단")
    race.authHook = { race.startup.participants.unregister(.relay) }
    let raceResult = await race.privacy.requestLocalReturn()
    expect(!raceResult && race.hal.restoreCalls == 0 && race.privacy.latched,
           "인증 중 참여자 교체는 늦은 인증 결과를 무효화")
    race.privacy.stop()

    let coupled = ReturnFixture()
    expect(coupled.privacy.armAndVerify(), "Sentry 결합 실패 fixture 차단")
    coupled.privacy.localReturnDidComplete = { _, _, _ in false }
    let coupledResult = await coupled.privacy.requestLocalReturn()
    expect(!coupledResult && coupled.privacy.latched && coupled.commits == 0,
           "Sentry commit 거부는 오디오 영속 복귀를 완료하지 않음")
    expect((try? coupled.hal.snapshot.plan().isEmpty) == true, "결합 실패 뒤 주입 장치 보호 재적용")
    coupled.privacy.stop()

    let refused = ReturnFixture(); refused.intentAccepted = false
    expect(refused.privacy.armAndVerify(), "원격 의도 CAS 실패 fixture 보호")
    let refusedResult = await refused.privacy.requestLocalReturn()
    expect(!refusedResult && refused.hal.restoreCalls == 0 && refused.commits == 0 && refused.privacy.latched &&
           refused.privacy.forwardingIntentAllowed && (try? refused.hal.snapshot.plan().isEmpty) == true,
           "원격 의도 CAS 실패는 로컬 음소거와 latch를 유지")
    refused.privacy.stop()

    let missingIntent = ReturnFixture()
    missingIntent.privacy.authenticatedLocalReturnWillCommit = nil
    expect(missingIntent.privacy.armAndVerify(), "의도 콜백 미연결 fixture 보호")
    let missingIntentResult = await missingIntent.privacy.requestLocalReturn()
    expect(!missingIntentResult && missingIntent.hal.restoreCalls == 0 && missingIntent.commits == 0,
           "원격 의도 콜백이 연결되지 않으면 복귀 거부")
    missingIntent.privacy.stop()

    let changed = ReturnFixture()
    changed.intentHook = { admission in
        changed.startup.participants.unregister(.relay)
        expect(!admission(), "CAS 큐 전후 admission은 참여자 변경 즉시 무효")
        return true
    }
    expect(changed.privacy.armAndVerify(), "콜백 세대 경합 fixture 보호")
    let changedResult = await changed.privacy.requestLocalReturn()
    expect(!changedResult && changed.hal.restoreCalls == 0 && changed.commits == 0,
           "원격 의도 콜백의 늦은 성공은 바뀐 참여자와 세대에 commit하지 않음")
    changed.privacy.stop()

    let expired = ReturnFixture()
    var releaseIntent: CheckedContinuation<Void, Never>?
    var savedAdmission: (@MainActor () -> Bool)?
    expired.intentHook = { admission in
        savedAdmission = admission
        await withCheckedContinuation { releaseIntent = $0 }
        return true
    }
    expect(expired.privacy.armAndVerify(), "콜백 시간 초과 fixture 보호")
    let expiredResult = await expired.privacy.requestLocalReturn(budgetMilliseconds: 100)
    expect(!expiredResult && expired.hal.restoreCalls == 0 && expired.commits == 0 &&
           expired.privacy.forwardingIntentAllowed && savedAdmission?() == false,
           "콜백 시간 예산 만료 뒤 admission 무효와 로컬 음소거 유지")
    releaseIntent?.resume()
    await Task.yield()
    expect(expired.hal.restoreCalls == 0 && expired.commits == 0, "시간 초과 콜백의 늦은 반환은 로컬 commit 불가")
    expired.privacy.stop()

    let cancelled = ReturnFixture(forwarding: true)
    var oldCallbackCompleted = false
    var releaseCancelled: CheckedContinuation<Void, Never>?
    var cancelledAdmission: (@MainActor () -> Bool)?
    cancelled.intentHook = { admission in
        cancelledAdmission = admission
        await withCheckedContinuation { releaseCancelled = $0 }
        oldCallbackCompleted = true
        return true
    }
    expect(cancelled.privacy.armAndVerify(), "콜백 취소 fixture 보호")
    let cancelTask = Task { await cancelled.privacy.requestLocalReturn() }
    for _ in 0..<1000 {
        if releaseCancelled != nil { break }
        await Task.yield()
    }
    expect(releaseCancelled != nil, "취소 전 CAS 대기 경계 진입")
    cancelTask.cancel()
    expect(cancelledAdmission?() == false, "요청 취소 직후 다른 Task에서도 CAS admission 거부")
    let cancelledResult = await cancelTask.value
    expect(!cancelledResult && cancelledAdmission?() == false && cancelled.hal.restoreCalls == 0 &&
           cancelled.commits == 0 && cancelled.privacy.forwardingIntentAllowed,
           "요청 취소는 CAS admission을 닫고 로컬 복원·commit을 막음")
    cancelled.intentHook = { admission in
        expect(cancelledAdmission?() == false, "다음 복귀 시도 중에도 이전 admission은 영구 무효")
        return admission()
    }
    let retriedCancellation = await cancelled.privacy.requestLocalReturn()
    expect(retriedCancellation && cancelled.commits == 1, "취소한 원본과 분리된 새 인증 복귀 성공")
    releaseCancelled?.resume()
    let oldCallbackDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !oldCallbackCompleted && ContinuousClock.now < oldCallbackDeadline { await Task.yield() }
    expect(oldCallbackCompleted, "늦은 이전 콜백의 실제 종료 확인")
    expect(cancelled.commits == 1 && cancelledAdmission?() == false, "늦은 이전 콜백은 새 복귀에 영향 없음")
    cancelled.privacy.stop()

    let native = PrivacyFakeHAL(), participant = ReturnFixture()
    let nativeOriginal = try! LocalAudioState(native.snapshot)
    let nativePrivacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: native.operations), clearLatch: { true },
        authenticateLocal: { _ in true }, nativeStartup: participant.startup)
    nativePrivacy.revokeForLocalReturn = { true }
    nativePrivacy.inspectForLocalReturn = { participant.facts }
    nativePrivacy.authenticatedLocalReturnWillCommit = { admission in admission() }
    expect(nativePrivacy.armAndVerify(), "실제 플랫폼 어댑터를 주입 HAL로 보호")
    let nativeResult = await nativePrivacy.requestLocalReturn()
    expect(nativeResult && nativeOriginal.matches(native.snapshot) && !nativePrivacy.latched,
           "실제 플랫폼 restoreLocal의 UID별 복원·setter별 readback 완료")
    nativePrivacy.stop()

    var stored: Data?
    let corrupt = LocalAudioJournal(data: Data([0]), store: { stored = $0 }, load: { stored }, synchronize: { true })
    expect(corrupt.latched && corrupt.original == nil, "손상된 영속 원장은 보호 latch를 유지")
    expect(corrupt.write(latched: true, original: nativeOriginal), "완전한 원래 장치 상태의 영속 write/readback")
    let restoredJournal = LocalAudioJournal(data: stored, store: { _ in }, load: { stored }, synchronize: { false })
    expect(restoredJournal.latched && restoredJournal.original == nativeOriginal, "재시작 시 원래 로컬 상태와 latch 복원")
    expect(!restoredJournal.write(latched: false, original: nil) && restoredJournal.latched,
           "영속 저장 실패는 로컬 복귀 완료로 인정하지 않음")

    let wire = PrivacyFakeHAL()
    wire.snapshot.devices.append(.init(id: 80, uid: "DN32-LIVE", transport: .other, plugin: nil,
        inputChannels: 32, outputChannels: 32, inputMuted: nil, outputMuted: nil))
    let privacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: wire.operations))
    expect(!privacy.armAndVerify() && !privacy.state.protected && privacy.latched,
           "DN32-LIVE 기본값과 hog 추정 없이 전체 보호 거부")
    expect(wire.snapshot.devices[0].inputMuted == true && wire.snapshot.devices[0].outputMuted == true &&
           wire.snapshot.input == 20 && wire.snapshot.output == 30 && wire.snapshot.systemOutput == 30,
           "DN32 차단 실패와 별개로 지원되는 내장 양방향 차단 및 가상 기본값 적용")
    let coverage = privacy.state.coverage!.filter { $0.uid == "DN32-LIVE" }
    expect(coverage.count == 2 && coverage.allSatisfy { $0.channels == 32 && !$0.protected && $0.method == "unsupported" },
           "DN32 양방향 전체 32채널 미지원 coverage 공개")
    let list = WindowList(macName: "시험", windows: [], active: .none, audioPrivacy: privacy.state)
    expect(Wire.decode(WindowList.self, from: Wire.encode(list))?.audioPrivacy?.coverage == privacy.state.coverage,
           "실제 카탈로그 wire에 v2 상세 coverage 보존")
    privacy.stop()
    expect(privacy.latched, "연결 및 감시 종료 뒤에도 보호 latch 유지")
}

@MainActor
private final class NormalDisconnectAuthority {
    var sentry = false
    var voiceSessions: Set<UUID> = []
    var generation = UUID()

    func admission() -> @MainActor () -> Bool {
        let disconnectedGeneration = generation
        return { !self.sentry && self.voiceSessions.isEmpty && self.generation == disconnectedGeneration }
    }
}

@MainActor
private func normalDisconnectReturnChecks() async {
    await normalDisconnectJournalFailureChecks()
    await normalDisconnectStreamChecks()
    let success = ReturnFixture(forwarding: true)
    success.accepted = false
    success.intentAccepted = false
    var surfaceCommits = 0
    var sentryReturnActivity = false
    var activityNotifications = 0
    success.privacy.localReturnActivityChanged = {
        activityNotifications += 1
        sentryReturnActivity = success.privacy.localReturnInProgress
    }
    success.privacy.localReturnDidComplete = { _, _, _ in surfaceCommits += 1; return false }
    success.hal.snapshot.devices[0].inputMuted = true
    expect(success.privacy.armAndVerify(), "일반 disconnect 원본 장치와 비대칭 mute 저장")
    let original = success.original!
    let returned = await success.privacy.requestNormalDisconnectReturn { !sentryReturnActivity }
    expect(returned && original.matches(success.hal.snapshot) && !success.privacy.latched &&
           !success.durable && success.authCalls == 0 && success.intentCommits == 0 && surfaceCommits == 0 && activityNotifications == 0,
           "일반 disconnect는 인증·Node intent·Sentry 해제 없이 연결 전 입출력과 mute 복원")
    expect(success.privacy.armAndVerify(), "자동복귀 뒤 재접속 오디오 보호 재진입")
    let returnedAgain = await success.privacy.requestNormalDisconnectReturn { true }
    expect(returnedAgain && original.matches(success.hal.snapshot), "이전 원본으로 재접속 후 두 번째 일반 복귀")
    success.privacy.stop()

    for reason in ["Sentry", "같은 기기의 다른 Vision 창", "다른 owner", "이전 disconnect 세대"] {
        let refused = ReturnFixture()
        let authority = NormalDisconnectAuthority()
        let admission = authority.admission()
        switch reason {
        case "Sentry": authority.sentry = true
        case "이전 disconnect 세대": authority.generation = UUID()
        default: authority.voiceSessions.insert(UUID())
        }
        expect(refused.privacy.armAndVerify(), "\(reason) 최초 admission 거절 fixture")
        let result = await refused.privacy.requestNormalDisconnectReturn(while: admission)
        expect(!result && refused.hal.restoreCalls == 0 && refused.commits == 0 && refused.authCalls == 0 &&
               refused.privacy.verify(), "\(reason)은 복원·인증·latch 변경 없이 보호 유지")
        refused.privacy.stop()
    }

    for reason in ["Sentry 활성화", "새 owner", "늦은 세대"] {
        let race = ReturnFixture()
        let authority = NormalDisconnectAuthority()
        let admission = authority.admission()
        race.privacy.revokeForLocalReturn = {
            await Task.yield()
            switch reason {
            case "Sentry 활성화": authority.sentry = true
            case "새 owner": authority.voiceSessions.insert(UUID())
            default: authority.generation = UUID()
            }
            return true
        }
        expect(race.privacy.armAndVerify(), "drain 중 \(reason) fixture")
        let result = await race.privacy.requestNormalDisconnectReturn(while: admission)
        expect(!result && race.hal.restoreCalls == 0 && race.commits == 0 && race.privacy.latched &&
               (try? race.hal.snapshot.plan().isEmpty) == true,
               "drain 중 \(reason)이 admission을 취소하면 복원 거절")
        race.privacy.stop()
    }

    let membership = ReturnFixture()
    membership.privacy.revokeForLocalReturn = {
        membership.startup.participants.unregister(.relay)
        return true
    }
    expect(membership.privacy.armAndVerify(), "일반복귀 참여자 세대 교체 fixture")
    let membershipResult = await membership.privacy.requestNormalDisconnectReturn { true }
    expect(!membershipResult && membership.hal.restoreCalls == 0 && membership.commits == 0 && membership.privacy.latched,
           "외부 admission이 참이어도 내부 참여자 세대 변경은 복원 거절")
    membership.privacy.stop()

    for phase in ["drain", "restore", "readback", "restore admission", "commit admission", "persistence"] {
        let failure = ReturnFixture()
        var admitted = true
        expect(failure.privacy.armAndVerify(), "일반복귀 \(phase) 실패 fixture")
        switch phase {
        case "drain": failure.quiescent = false
        case "restore": failure.hal.restoreSucceeds = false
        case "readback": failure.hal.afterRestore = { failure.hal.readFailures = 1 }
        case "restore admission": failure.hal.afterRestore = { admitted = false }
        case "commit admission": failure.clearHook = { admitted = false }
        default:
            failure.clearAccepted = false
            failure.clearHook = { failure.persistenceAccepted = false }
        }
        let result = await failure.privacy.requestNormalDisconnectReturn { admitted }
        expect(!result && failure.privacy.latched && (try? failure.hal.snapshot.plan().isEmpty) == true &&
               failure.authCalls == 0 && failure.intentCommits == 0,
               "\(phase) 실패 시 로컬을 유지하지 않고 보호 상태 복구")
        if phase == "persistence" {
            expect(!failure.privacy.state.protected && !failure.privacy.forwardingHealth(),
                   "영속 복구 실패는 물리 보호를 재적용해도 성공·원격 admission으로 승격하지 않음")
        }
        failure.privacy.stop()
    }

    let cancelled = ReturnFixture()
    var releaseDrain: CheckedContinuation<Void, Never>?
    var drainCompleted = false
    cancelled.privacy.revokeForLocalReturn = {
        await withCheckedContinuation { releaseDrain = $0 }
        drainCompleted = true
        return true
    }
    expect(cancelled.privacy.armAndVerify(), "일반복귀 취소 fixture")
    let task = Task { await cancelled.privacy.requestNormalDisconnectReturn { true } }
    let enteredDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while releaseDrain == nil && ContinuousClock.now < enteredDeadline { await Task.yield() }
    expect(releaseDrain != nil, "일반복귀 비동기 drain 진입")
    task.cancel()
    let result = await task.value
    releaseDrain?.resume()
    let settledDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !drainCompleted && ContinuousClock.now < settledDeadline { await Task.yield() }
    expect(!result && drainCompleted && cancelled.hal.restoreCalls == 0 && cancelled.commits == 0 && cancelled.privacy.latched,
           "취소된 disconnect의 늦은 drain 성공은 로컬 복원 불가")
    cancelled.privacy.stop()
}

@MainActor
private func normalDisconnectJournalFailureChecks() async {
    var protectedEveryCase = true
    var retainedEveryOriginal = true
    for hotplug in [false, true] {
        let failure = ReturnFixture()
        var admitted = true
        expect(failure.privacy.armAndVerify(), "저널 보상 반례 fixture 보호")
        let original = failure.original!
        let writes = failure.hal.writes
        failure.clearHook = {
            admitted = false
            failure.persistenceAccepted = false
            if hotplug {
                let format = PrivacyAudioStream.Format(sampleRate: 48_000, formatID: 0x6c70636d, flags: 12,
                    bytesPerPacket: 8, framesPerPacket: 1, bytesPerFrame: 8, channels: 2, bitsPerChannel: 32, reserved: 0)
                failure.hal.snapshot.devices.append(.init(id: 40, uid: "new-usb", transport: .other, plugin: nil,
                    inputChannels: 2, outputChannels: 2, streams: [
                        .init(id: 41, ownerID: 40, direction: .input, startingChannel: 1,
                              virtualFormat: format, physicalFormat: format, active: true, activeSettable: true),
                        .init(id: 42, ownerID: 40, direction: .output, startingChannel: 1,
                              virtualFormat: format, physicalFormat: format, active: true, activeSettable: true)]))
            }
        }
        let result = await failure.privacy.requestNormalDisconnectReturn { admitted }
        let restarted = LocalAudioJournal(data: failure.stored, store: { _ in }, load: { failure.stored }, synchronize: { true })
        let protected = (try? failure.hal.snapshot.plan().isEmpty) == true
        let retained = restarted.latched && restarted.original == original
        print("JOURNAL_REPRO hotplug=\(hotplug) returned=\(result) compensationWrites=\(failure.hal.writes - writes) physicalProtected=\(protected) restartLatched=\(restarted.latched) restartHasOriginal=\(restarted.original != nil)")
        protectedEveryCase = protectedEveryCase && protected && failure.hal.writes > writes
        retainedEveryOriginal = retainedEveryOriginal && retained
        expect(!result && failure.privacy.latched && !failure.privacy.forwardingHealth() && failure.authCalls == 0,
               "admission 상실과 저장 실패는 자동 복귀 성공·인증·원격 승인으로 바뀌지 않음")
        failure.privacy.stop()
    }
    expect(protectedEveryCase, "P1: 새 stream 원본 저장 실패와 분리해 가능한 보호 쓰기를 적용")
    expect(retainedEveryOriginal, "P2: 최종 확정 전 실패하면 재시작 저널의 latch와 연결 전 원본 보존")
}

@MainActor
private func normalDisconnectStreamChecks() async {
    for uid in ["M32R", "AppleUSBAudioEngine:KLARK TEKNIK:DN32-LIVE:02D37313455564310:1,2"] {
        let fake = PrivacyFakeHAL(), participant = ReturnFixture()
        let format = PrivacyAudioStream.Format(sampleRate: 48_000, formatID: 0x6c70636d, flags: 12,
            bytesPerPacket: 128, framesPerPacket: 1, bytesPerFrame: 128, channels: 32, bitsPerChannel: 32, reserved: 0)
        fake.snapshot.devices.append(.init(id: 126, uid: uid, transport: .other, plugin: nil,
            inputChannels: 32, outputChannels: 32, streams: [
                .init(id: 127, ownerID: 126, direction: .input, startingChannel: 1,
                      virtualFormat: format, physicalFormat: format, active: false, activeSettable: true),
                .init(id: 128, ownerID: 126, direction: .output, startingChannel: 1,
                      virtualFormat: format, physicalFormat: format, active: true, activeSettable: true)]))
        fake.snapshot.input = 126; fake.snapshot.output = 126; fake.snapshot.systemOutput = 126
        let original = try! LocalAudioState(fake.snapshot)
        let privacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: fake.operations), clearLatch: { true },
            authenticateLocal: { _ in expect(false, "일반복귀는 인증을 호출하지 않음"); return false },
            nativeStartup: participant.startup)
        privacy.revokeForLocalReturn = { true }
        privacy.inspectForLocalReturn = { participant.facts }
        expect(privacy.armAndVerify() && fake.snapshot.devices.last?.streams?.allSatisfy({ !$0.active }) == true,
               "\(uid) 양방향 32채널 가짜 HAL 보호")
        let result = await privacy.requestNormalDisconnectReturn { true }
        expect(result && original.matches(fake.snapshot) && !privacy.latched,
               "\(uid) 실제 HAL 어댑터가 연결 전 장치·음소거·비대칭 stream active를 자동 복원")
        privacy.stop()
    }
}

@MainActor
private func armRecoveryChecks() {
    for failure in ["read", "synchronize", "readback"] {
        let hal = ReturnHAL()
        let original = try! LocalAudioState(hal.snapshot)
        var stored: Data?
        var accepted = false
        var envelopes: [LocalAudioJournal.Envelope] = []
        let journal = LocalAudioJournal(data: nil, store: {
            envelopes.append(try! JSONDecoder().decode(LocalAudioJournal.Envelope.self, from: $0))
            stored = $0
        }, load: { failure == "readback" && !accepted ? nil : stored },
           synchronize: { failure != "synchronize" || accepted })
        if failure == "read" { hal.readFailures = 1 }
        let privacy = HostAudioPrivacy(hal: hal,
            persist: { journal.write(latched: true, original: journal.original) },
            saveLocal: { journal.write(latched: $0 != nil, original: $0) })
        expect(!privacy.armAndVerify() && !privacy.latched && hal.writes == 0,
               "최초 \(failure) 실패는 원본 없는 latch와 장치 쓰기를 만들지 않음")
        expect(envelopes.allSatisfy { !$0.latched || $0.original == original },
               "실패한 저장도 원본과 latch를 한 envelope로 기록")
        accepted = true
        expect(privacy.armAndVerify() && privacy.latched && journal.original == original,
               "최초 \(failure) 실패 후 명시적 재시도로 보호 회복")
        let recovered = LocalAudioJournal(data: stored, store: { _ in }, load: { stored }, synchronize: { true })
        expect(recovered.latched && recovered.original == original,
               "회복 뒤 재시작해도 최초 원본 보존")
        expect(privacy.armAndVerify() && journal.original == original,
               "이미 보호한 장치를 재시도해도 새 원본으로 덮지 않음")
        privacy.stop()
    }

    let hal = ReturnHAL()
    var saves = 0
    let missing = HostAudioPrivacy(hal: hal, latched: true,
        persist: { saves += 1; return true }, saveLocal: { _ in saves += 1; return true })
    for _ in 0..<2 {
        expect(!missing.armAndVerify() && missing.latched && !missing.verify() && saves == 0 && hal.writes == 0,
               "기존 원본 없는 latch는 현재 장치를 원본으로 오인하지 않음")
    }
    missing.stop()

    var stored: Data?
    let journal = LocalAudioJournal(data: nil, store: { stored = $0 }, load: { stored }, synchronize: { true })
    expect(!journal.write(latched: true, original: nil) && stored == nil,
           "저널은 원본 없는 새 latch 쓰기를 거부")
}
