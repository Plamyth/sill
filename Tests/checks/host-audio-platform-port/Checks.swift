import CoreAudio
import Foundation
@testable import SillHostCore

@main
struct Checks {
    @MainActor
    static func main() {
        let reads = HALMicrophoneOperations(
            objectGet: { _, _, _, _, _, _ in fatalError("비활성 검사에서 HAL을 읽으면 안 됩니다.") },
            objectSize: { _, _, _ in fatalError("비활성 검사에서 HAL 크기를 읽으면 안 됩니다.") },
            create: { fatalError("비활성 검사에서 오디오 유닛을 만들면 안 됩니다.") })
        let operations = HostAudioPrivacyOperations(read: reads,
            settable: { _, _, _ in fatalError("비활성 검사에서 HAL 쓰기 권한을 읽으면 안 됩니다.") },
            set: { _, _, _, _ in fatalError("비활성 검사에서 HAL을 쓰면 안 됩니다.") },
            addListener: { _, _, _, _ in fatalError("비활성 검사에서 감시를 등록하면 안 됩니다.") },
            removeListener: { _, _, _, _ in fatalError("비활성 검사에서 감시를 해제하면 안 됩니다.") })
        let hal = CoreAudioPrivacyHAL(ops: operations)
        let privacy = HostAudioPrivacy(hal: hal)
        precondition(!privacy.latched && !privacy.state.protected)
        precondition(!privacy.verify())
        precondition(!privacy.forwardingHealth())
        precondition(hal.observe(nil, changed: nil))

        let nativeFactory: (UserDefaults, NativeAudioStartup) -> HostAudioPrivacy = {
            HostAudioPrivacy(defaults: $0, nativeStartup: $1)
        }
        _ = nativeFactory

        let platform = HostSentryPlatform()
        precondition(platform.reason == nil && platform.curtainWindowIDs.isEmpty)
        precondition(!platform.verify())
        let surfaces = SentrySurfaceOperations(
            engage: { platform.engage() }, verify: { platform.verify() },
            release: { platform.release() }, reason: { platform.reason },
            restoreCurtains: { platform.restoreCurtains() })
        let admission = SentryAdmission()
        let sentry = HostSentry(admission: admission, initiallyLatched: false, persistenceHealthy: true,
            persist: { _ in fatalError("비활성 검사에서 보호 원장을 쓰면 안 됩니다.") },
            surfaces: surfaces,
            audioReady: { fatalError("비활성 검사에서 네이티브 오디오를 검사하면 안 됩니다.") })
        sentry.start()
        precondition(!admission.isRequested && sentry.forwardingProof() == nil)
        precondition(!platform.verify() && platform.curtainWindowIDs.isEmpty)
        print("PASS: 현재 보호 모델과 플랫폼 API의 비활성 계약을 확인했습니다.")
    }
}
