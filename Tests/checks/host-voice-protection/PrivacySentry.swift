import Foundation
import StreamProtocol

@MainActor private final class PrivacySentryBridge {
    final class Server { let sentryAdmission = SentryAdmission() }
    let server = Server()
    let privacy: HostAudioPrivacy
    var sentry: HostSentry?
    var notifications = 0

    init(_ privacy: HostAudioPrivacy, protected: Bool) {
        self.privacy = privacy
        sentry = HostSentry(admission: server.sentryAdmission, initiallyLatched: protected,
            persistenceHealthy: true, persist: { _ in true },
            surfaces: .init(engage: { true }, verify: { true }, release: { true },
                reason: { nil }, restoreCurtains: { true }), prepareRelease: { true },
            localReturnUnavailableReason: { privacy.localReturnUnavailableReason })
        __PRIVACY_CHANGED__
        __PRIVACY_ACTIVITY__
    }

    func audioPrivacyChanged(_ state: AudioPrivacyState) { notifications += 1 }
    __SENTRY_PRIVACY_CHANGED__
}

@MainActor func privacySentryAdmissionChecks() async {
    for protected in [true, false] {
        let hal = PrivacyFakeHAL(), startup = NativeAudioStartup(), peer = NSObject()
        startup.construct { () }
        startup.participants.register(.relay, bootId: UUID(), control: .init(
            fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
        var bridge: PrivacySentryBridge!
        var calls = 0
        let privacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: hal.operations), latched: true,
            localState: try! LocalAudioState(hal.snapshot), authenticateLocal: { _ in
                calls += 1
                expect(!bridge.server.sentryAdmission.allowsActions(ObjectIdentifier(peer)),
                       "실제 privacy 연결은 첫 인증 await 전에 메뉴·창 명령 인가를 동기 철회")
                await Task.yield()
                expect(!bridge.server.sentryAdmission.allowsActions(ObjectIdentifier(peer)),
                       "별도 reconcile 호출 없이 인증 대기 중 원격 명령 인가 유지 차단")
                return false
            }, nativeStartup: startup)
        bridge = PrivacySentryBridge(privacy, protected: protected)
        let admission = bridge.server.sentryAdmission
        admission.register(ObjectIdentifier(peer), externalRoute: false)
        bridge.sentry?.start()
        bridge.sentry?.joined(ObjectIdentifier(peer))
        expect(admission.allowsActions(ObjectIdentifier(peer)), "검증된 기존 원격 명령 인가 재현")
        let first = await privacy.requestLocalReturn()
        expect(!first && privacy.latched && calls == 1, "첫 인증 거부는 복귀하지 않음")
        expect(admission.allowsActions(ObjectIdentifier(peer)), "인증 종료 통지 후 기존 안전한 명령 인가 복원")
        let state = privacy.state, notifications = bridge.notifications
        let second = await privacy.requestLocalReturn()
        expect(!second && privacy.state == state && calls == 2,
               "같은 공개 오디오 상태의 빠른 재시도도 인증 1회와 독립 인가 차단")
        expect(bridge.notifications == notifications,
               "공개 상태 중복 제거를 유지하면서 인증 진행 통지만 별도로 전달")
        privacy.stop()
    }
}
