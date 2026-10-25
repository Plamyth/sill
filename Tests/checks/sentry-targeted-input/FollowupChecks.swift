import AppKit
import StreamProtocol

@MainActor private final class ReleaseOwner {
    let injector: InputInjector
    init(_ injector: InputInjector) { self.injector = injector }
    func barrier(_ platform: TargetPlatform) -> () -> Bool {
        __PRODUCTION_RELEASE_BARRIER__
    }
}

@MainActor private final class ReturnFixture {
    let input = Fixture(), admission = SentryAdmission()
    var journal = SentryJournalState.latched
    var effects: [String] = []
    var sentry: HostSentry!
    var owner: ReleaseOwner!
    var duringRelease: (() -> Void)?
    var releasingWriteOK = true
    init() {
        input.platform.curtainWindowIDs = []
        input.platform.rows = [input.row(10)]
        input.platform.changed = { [unowned self] in
            duringRelease?()
            input.injector.releaseAll()
        }
        input.platform.onDestroyTap = { [unowned self] in duringRelease?() }
        owner = ReleaseOwner(input.injector)
        let barrier = owner.barrier(input.platform)
        sentry = HostSentry(admission: admission, initiallyLatched: true, persistenceHealthy: true,
            persist: { [unowned self] value in
                effects.append(value.rawValue)
                if value == .releasing && !releasingWriteOK { return false }
                journal = value
                return true
            }, surfaces: .init(engage: { false }, verify: { true }, release: { [unowned self] deadline, current in
                effects.append("surface-release")
                await Task.yield()
                return await input.platform.release(until: deadline, current: current)
            }, reason: { nil }), prepareRelease: barrier, localReturnUnavailableReason: { nil })
        admission.register(input.owner, externalRoute: false)
        admission.admit(input.owner)
        admission.update(verified: true, persistenceHealthy: true, reason: nil)
        admission.capture(input.epochID)
        input.admissionCurrent = { [unowned self] in admission.allowsActions(input.owner) }
    }
    func complete() async -> Bool {
        await sentry.completeAuthenticatedLocalReturn { [unowned self] in effects.append("audio"); return true }
    }
}

extension Checks {
    @MainActor static func followupChecks() async {
        let uncovered = Fixture()
        uncovered.platform.state = .invalid("권한창이 가림 화면 위에 있습니다.")
        uncovered.platform.tap = nil
        check(uncovered.platform.prepareRemoteRelease(inputIdle: { !uncovered.injector.hasPendingInput },
                  cleanup: { uncovered.injector.prepareRelease() }) && uncovered.platform.posted.isEmpty,
              "입력 부채가 없는 승인 원격 해제는 권한창이나 tap 소실 상태에서 OS 입력 없이 준비")
        uncovered.platform.currentLocalAuthenticationChallenge = { UUID() }
        check(!uncovered.platform.prepareRemoteRelease(inputIdle: { true }, cleanup: { true }),
              "실제 OS 인증 진행 중에는 원격 보호 해제를 준비하지 않음")
        uncovered.platform.currentLocalAuthenticationChallenge = { nil }
        uncovered.platform.changingLifecycle = true
        check(!uncovered.platform.prepareRemoteRelease(inputIdle: { true }, cleanup: { true }),
              "다른 현장 보호 전환 중 원격 해제 거절")
        let remoteDebt = Fixture()
        remoteDebt.send(.leftDown)
        remoteDebt.platform.state = .invalid("권한창이 가림 화면 위에 있습니다.")
        check(!remoteDebt.platform.prepareRemoteRelease(inputIdle: { !remoteDebt.injector.hasPendingInput },
                  cleanup: { remoteDebt.injector.prepareRelease() }) && remoteDebt.debt(),
              "권한창 상태에서 원격 버튼 부채를 임의 폐기하거나 OS 창에 종료 입력을 전달하지 않음")
        let returned = ReturnFixture(); returned.input.send(.leftDown)
        check((await returned.complete()) && !returned.input.debt() && returned.journal == .inactive,
              "F1 복귀 성공 전에 still-protected tap에서 원 버튼 terminal 부채 정리")
        check(returned.effects == ["releasing", "surface-release", "audio", "inactive"] &&
              returned.input.platform.posted.map { $0.1.type } == [.leftMouseDown, .leftMouseUp],
              "원 대상 terminal 성공 뒤에만 releasing·surface 해제·audio·inactive 순서 진행")

        check(returned.input.platform.tap == nil && returned.input.platform.annotatedTap == nil,
              "검증된 정상 복귀 뒤 두 tap을 함께 종료")
        let reentrant = ReturnFixture(); reentrant.input.send(.leftDown)
        var fenced = false, nestedReturn = true
        reentrant.input.platform.onVerify = {
            reentrant.input.platform.onVerify = nil
            fenced = !reentrant.admission.allowsActions(reentrant.input.owner)
            reentrant.sentry.surfacesChanged()
            reentrant.input.send(.rightDown)
            Task { @MainActor in nestedReturn = await reentrant.complete() }
        }
        reentrant.duringRelease = { reentrant.sentry.surfacesChanged() }
        check((await reentrant.complete()) && fenced && !nestedReturn && !reentrant.input.debt() &&
              reentrant.input.platform.posted.count == 2,
              "prepare/release의 동기 changed 재진입은 새 down·중첩 복귀를 막고 원 cleanup만 허용")

        let failureMutations: [(String, (ReturnFixture) -> Void)] = [
            ("대상 창 소실", { $0.input.platform.rows = [] }),
            ("tap 소실", { $0.input.platform.tap = nil }),
            ("tap 비활성", { $0.input.platform.tap = InertTap(enabled: false) }),
            ("보호 상태 소실", { $0.input.platform.state = .invalid("검증 실패") }),
            ("cleanup post 거절", { $0.input.injector.protectedPointerEgress = { _, _ in false } }),
        ]
        for (label, mutate) in failureMutations {
            let blocked = ReturnFixture(); blocked.input.send(.leftDown); mutate(blocked)
            check(!(await blocked.complete()) && blocked.input.debt() && blocked.journal == .latched &&
                  blocked.effects == ["latched"] && blocked.admission.isRequested,
                  "\(label) 시 releasing·tap제거·audio commit 없이 원 버튼 부채와 latch 유지")
        }
        let noTap = ReturnFixture(); noTap.input.platform.tap = nil
        check(!noTap.input.platform.prepareRelease { true },
              "일반 보호 해제 준비는 기존 live tap 검증을 계속 요구")
        check((await noTap.complete()) && noTap.effects == ["releasing", "surface-release", "audio", "inactive"] &&
              noTap.journal == .inactive && noTap.input.platform.releaseVerified,
              "인증 완료 뒤 입력 부채 없는 tap0 복구 상태는 소유 tap 부재·커튼 제거 확인 후 복귀")
        let afterCleanup = ReturnFixture(); afterCleanup.input.send(.leftDown)
        var lostAfterCleanup = false
        afterCleanup.duringRelease = {
            if case .releasing = afterCleanup.input.platform.state {
                lostAfterCleanup = !afterCleanup.input.debt()
                afterCleanup.input.platform.tap = nil
            }
        }
        check((await afterCleanup.complete()) && lostAfterCleanup && !afterCleanup.input.debt() &&
              afterCleanup.effects == ["releasing", "surface-release", "audio", "inactive"] &&
              afterCleanup.input.platform.releaseVerified,
              "인증 후 terminal이 끝난 tap 소실은 OS 소유 필터 부재와 커튼 제거를 확인한 뒤 복귀")
        let storage = ReturnFixture(); storage.input.send(.leftDown); storage.releasingWriteOK = false
        check(!(await storage.complete()) && !storage.input.debt() && storage.journal == .latched &&
              storage.effects == ["releasing"] && storage.input.platform.tap != nil,
              "terminal 뒤 releasing 저장 실패도 live tap을 제거하거나 audio를 commit하지 않음")

        let split = ReturnFixture(); split.input.send(.leftDown); split.input.send(.rightDown, peer: split.input.other)
        split.input.injector.apply(.key(hidUsage: 0x04, down: true, modifiers: 0), in: split.input.rect, from: split.input.owner)
        split.input.injector.rejectedGlobalTypes = [.keyUp]
        check(!(await split.complete()) && !split.input.debt() &&
              !split.input.injector.isUpOfSomethingDown(.pointer(.rightUp, x: 0, y: 0), from: split.input.other) &&
              split.input.injector.isUpOfSomethingDown(.key(hidUsage: 0x04, down: false, modifiers: 0), from: split.input.owner) &&
              split.effects == ["latched"],
              "서로 다른 peer 좌우 cleanup 성공과 key-up 실패 부채를 구분하여 복귀 차단")
        split.input.injector.rejectedGlobalTypes = []
        check((await split.complete()) && !split.input.injector.isUpOfSomethingDown(.key(hidUsage: 0x04, down: false, modifiers: 0), from: split.input.owner),
              "동일 key-up 부채 재시도 성공 뒤에만 복귀 허용")

        let failedUp = ReturnFixture()
        let keyDown = InputEvent.key(hidUsage: 0x04, down: true, modifiers: 0)
        let keyUp = InputEvent.key(hidUsage: 0x04, down: false, modifiers: 0)
        failedUp.input.injector.apply(keyDown, in: failedUp.input.rect, from: failedUp.input.owner)
        failedUp.input.injector.rejectedGlobalTypes = [.keyUp]
        failedUp.input.injector.apply(keyUp, in: failedUp.input.rect, from: failedUp.input.owner)
        let postsBeforeOther = failedUp.input.injector.globalPosts.count
        failedUp.input.injector.releaseInput(of: failedUp.input.other)
        failedUp.input.injector.apply(keyUp, in: failedUp.input.rect, from: failedUp.input.other)
        let failedUpCompleted = await failedUp.complete()
        check(failedUp.input.injector.globalPosts.count == postsBeforeOther &&
              failedUp.input.injector.isUpOfSomethingDown(keyUp, from: failedUp.input.owner) &&
              !failedUp.input.injector.isUpOfSomethingDown(keyUp, from: failedUp.input.other) && !failedUpCompleted,
              "복귀 전 일반 key-up post 실패도 원 peer 부채로 보존하고 다른 peer cleanup으로 지우지 않음")
        failedUp.input.injector.rejectedGlobalTypes = []
        check((await failedUp.complete()) && !failedUp.input.injector.isUpOfSomethingDown(keyUp, from: failedUp.input.owner),
              "실패한 일반 key-up도 prepareRelease에서 원 terminal 재시도 뒤에만 복귀")

        let flags = ReturnFixture()
        let command = KeyStrokes.command
        flags.input.injector.apply(.key(hidUsage: 0xE3, down: true, modifiers: command), in: flags.input.rect, from: flags.input.owner)
        flags.input.injector.apply(.key(hidUsage: 0x04, down: true, modifiers: command), in: flags.input.rect, from: flags.input.owner)
        flags.input.injector.rejectedGlobalTypes = [.keyUp]
        flags.input.injector.apply(.key(hidUsage: 0x04, down: false, modifiers: command), in: flags.input.rect, from: flags.input.owner)
        flags.input.injector.rejectedGlobalTypes = []
        flags.input.injector.apply(.key(hidUsage: 0xE3, down: false, modifiers: 0), in: flags.input.rect, from: flags.input.owner)
        check((await flags.complete()) && flags.input.injector.globalPosts.last?.flags.rawValue == 0,
              "key-up 재시도는 이미 해제된 modifier의 예전 flags를 복원하지 않음")

        let scrollDebt = ReturnFixture(); scrollDebt.input.scroll(.began); scrollDebt.input.scroll()
        scrollDebt.input.injector.protectedPointerEgress = { _, _ in false }
        check(!(await scrollDebt.complete()) && scrollDebt.input.injector.protectedScrollPending && scrollDebt.effects == ["latched"],
              "실제 미종료 scroll terminal 실패 부채는 복귀를 차단")
        let endedScroll = ReturnFixture(); endedScroll.input.scroll(.began); endedScroll.input.scroll(); endedScroll.input.scroll(.ended)
        let endedScrollCompleted = await endedScroll.complete()
        check(!endedScroll.input.injector.protectedScrollPending && endedScrollCompleted,
              "이미 terminal인 gesture handoff는 미해제 부채로 세지 않아 로컬 복귀 허용")

        let momentum = Fixture(); momentum.source = .desktop
        momentum.scroll(.began); momentum.scroll(); momentum.scroll(.ended)
        momentum.platform.rows = [momentum.row(11, pid: 200), momentum.row(10)]
        momentum.platform.foreground = momentum.platform.apps[200]
        momentum.scroll(.momentumBegan); momentum.scroll(); momentum.scroll(.momentumEnded)
        check(momentum.platform.posted.count == 4 && momentum.platform.posted.allSatisfy { $0.0 == 100 },
              "F2 gesture 종료 뒤 전경 B로 바뀌어도 momentum 최초 대상 A 보존")
        check(!momentum.injector.protectedScrollPending && momentum.platform.posted.last?.1.getIntegerValueField(.scrollWheelEventMomentumPhase) == 3,
              "원 capture의 momentum terminal까지 보존하고 실제 부채 해제")
        momentum.scroll(.began); momentum.scroll()
        check(momentum.platform.posted.last?.0 == 200, "새 사람 gesture began에서만 현재 대상 B 취득")

        for mode in 0..<5 {
            let lost = Fixture(); lost.source = .desktop
            lost.scroll(.began); lost.scroll(); lost.scroll(.ended)
            if mode == 0 { lost.platform.rows = [lost.row(11, pid: 200)] }
            if mode == 1 { lost.platform.apps[100]?.launchDate = Date(timeIntervalSince1970: 999) }
            if mode == 2 { lost.epochID = UUID() }
            if mode == 3 { lost.source = .window(11) }
            lost.platform.foreground = lost.platform.apps[200]
            let peer = mode == 4 ? lost.other : lost.owner
            lost.scroll(.momentumBegan, peer: peer); lost.scroll(peer: peer)
            check(lost.platform.posted.count == 2 && !lost.injector.protectedScrollPending,
                  "창·launch·epoch·source·peer 변경은 momentum 새 target 권한이 아님 \(mode)")
        }
        let orphan = Fixture(); orphan.source = .desktop
        orphan.scroll(.momentumBegan); orphan.scroll(); orphan.scroll(); orphan.scroll()
        check(orphan.platform.posted.isEmpty && !orphan.injector.protectedScrollPending,
              "유효 gesture handoff 없는 momentum과 뒤따르는 delta 거절")
        let cancelled = Fixture(); cancelled.scroll(.began); cancelled.scroll(); cancelled.scroll(.ended)
        cancelled.current = false; cancelled.scroll(.momentumBegan); cancelled.scroll()
        check(cancelled.platform.posted.count == 2 && !cancelled.injector.protectedScrollPending,
              "종료된 scope 취소는 이전 handoff로 momentum 권한을 되살리지 않음")
    }
}
