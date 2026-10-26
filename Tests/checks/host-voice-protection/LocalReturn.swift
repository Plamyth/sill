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
    var durable = false
    var commits = 0
    var original: LocalAudioState?
    var intentCommits = 0
    var intentAccepted = true
    var intentHook: ((@escaping @MainActor () -> Bool) async -> Bool)?
    let facts = LocalAudioParticipantFacts(admissionFenced: true, startsSettled: true, mediaDetached: true,
        callbacksDrained: true, buffersEmpty: true, workersExited: true)

    init(relay: Bool = true, forwarding: Bool = false) {
        privacy = HostAudioPrivacy(hal: hal, persist: { [unowned self] in durable = true; return true },
            saveLocal: { [unowned self] state in original = state; durable = state != nil; return true },
            clearLatch: { [unowned self] in commits += 1; durable = false; return true },
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
    let expiredRemoval = ReturnFixture()
    expect(expiredRemoval.privacy.armAndVerify(), "감시 종료 중 기한 만료 fixture 보호")
    expiredRemoval.hal.beforeObservationStop = { Thread.sleep(forTimeInterval: 0.15) }
    let expiredRemovalResult = await expiredRemoval.privacy.requestLocalReturn(budgetMilliseconds: 100)
    expect(!expiredRemovalResult && expiredRemoval.hal.restoreCalls == 0 && expiredRemoval.commits == 0 && expiredRemoval.durable,
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
