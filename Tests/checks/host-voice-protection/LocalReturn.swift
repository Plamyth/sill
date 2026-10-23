import Foundation
import StreamProtocol

@MainActor
private final class ReturnHAL: HostAudioPrivacyHAL {
    var snapshot = PrivacyFakeHAL().snapshot
    var restoreCalls = 0
    var restoreSucceeds = true
    func read() throws -> PrivacyAudioSnapshot { snapshot }
    func write(_ change: PrivacyAudioWrite) -> Bool {
        switch change {
        case .mute(let id, let scope):
            guard let index = snapshot.devices.firstIndex(where: { $0.id == id }) else { return false }
            if scope == .input { snapshot.devices[index].inputMuted = true }
            else { snapshot.devices[index].outputMuted = true }
        case .select(let kind, let id):
            switch kind { case .input: snapshot.input = id; case .output: snapshot.output = id; case .systemOutput: snapshot.systemOutput = id }
        }
        return true
    }
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool { true }
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
    let facts = LocalAudioParticipantFacts(admissionFenced: true, startsSettled: true, mediaDetached: true,
        callbacksDrained: true, buffersEmpty: true, workersExited: true)

    init(relay: Bool = true) {
        privacy = HostAudioPrivacy(hal: hal, persist: { [unowned self] in durable = true; return true },
            saveLocal: { [unowned self] state in original = state; return true },
            clearLatch: { [unowned self] in commits += 1; durable = false; return true },
            authenticateLocal: { [unowned self] _ in authCalls += 1; authHook?(); return accepted },
            nativeStartup: startup)
        _ = startup.construct { true }
        privacy.revokeForLocalReturn = { [unowned self] in quiescent }
        privacy.inspectForLocalReturn = { [unowned self] in quiescent ? facts : .unknown }
        if relay {
            startup.participants.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: { [unowned self] request in
                relayRequest = request
                return .init(request, state: quiescent ? .quiescent : .unknown, facts: quiescent ? facts : .unknown)
            }, inspect: { [unowned self] id in
                guard let request = relayRequest, request.operationId == id else { return nil }
                return .init(request, state: quiescent ? .quiescent : .unknown, facts: quiescent ? facts : .unknown)
            }))
        }
    }
    var relayRequest: LocalAudioParticipantRequest?
}

@MainActor
func localReturnChecks() async {
    let success = ReturnFixture()
    expect(success.privacy.armAndVerify(), "복귀 전 주입 장치 전체 차단")
    let original = success.original!
    let succeeded = await success.privacy.requestLocalReturn()
    expect(succeeded, "본인 인증과 두 참여자 종료 뒤 로컬 복귀")
    expect(!success.privacy.latched && !success.durable && success.commits == 1 && original.matches(success.hal.snapshot),
           "원래 장치와 음소거 readback 뒤에만 영속 latch 해제")
    success.privacy.stop()

    let denied = ReturnFixture(); denied.accepted = false
    expect(denied.privacy.armAndVerify(), "인증 거부 fixture 차단")
    let deniedResult = await denied.privacy.requestLocalReturn()
    expect(!deniedResult && denied.hal.restoreCalls == 0 && denied.privacy.latched,
           "인증 거부 시 장치 복원과 latch 해제 없음")
    denied.privacy.stop()

    let missing = ReturnFixture(relay: false)
    expect(missing.privacy.armAndVerify(), "참여자 누락 fixture 차단")
    let missingResult = await missing.privacy.requestLocalReturn()
    expect(!missingResult && missing.authCalls == 0 && missing.privacy.latched,
           "실제 relay 미연결은 인증과 복원을 열지 않음")
    missing.privacy.stop()

    let unsettled = ReturnFixture(); unsettled.quiescent = false
    expect(unsettled.privacy.armAndVerify(), "미완료 종료 fixture 차단")
    let unsettledResult = await unsettled.privacy.requestLocalReturn()
    expect(!unsettledResult && unsettled.hal.restoreCalls == 0 && unsettled.privacy.latched,
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
    coupled.privacy.localReturnDidComplete = { _ in false }
    let coupledResult = await coupled.privacy.requestLocalReturn()
    expect(!coupledResult && coupled.privacy.latched && coupled.commits == 0,
           "Sentry commit 거부는 오디오 영속 복귀를 완료하지 않음")
    expect((try? coupled.hal.snapshot.plan().isEmpty) == true, "결합 실패 뒤 주입 장치 보호 재적용")
    coupled.privacy.stop()

    let native = PrivacyFakeHAL(), participant = ReturnFixture()
    let nativeOriginal = try! LocalAudioState(native.snapshot)
    let nativePrivacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: native.operations), clearLatch: { true },
        authenticateLocal: { _ in true }, nativeStartup: participant.startup)
    nativePrivacy.revokeForLocalReturn = { true }
    nativePrivacy.inspectForLocalReturn = { participant.facts }
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
