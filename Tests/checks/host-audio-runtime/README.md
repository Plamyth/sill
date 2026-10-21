# 호스트 오디오 런타임 격리 회귀

부모가 배정한 Mini 실행 경로에서 `python3 Tests/checks/host-audio-runtime/run.py`를 실행한다. 출력 경로를 생략하면 전용 임시 경로를 만들고 종료 시 정리한다. `/절대경로/새로운-격리-출력`을 인자로 지정하면 출력은 보존하고 기존 경로를 덮지 않는다. `--emit-only`는 Swift 실행 없이 컴파일 입력과 명령을 만든다. 맥북에서는 이 Swift 검사를 실행하지 않는다.

실제 `HostAudioForwardingRuntime`, `LocalAudioRelay`, `AudioForwardingCoordinator`, `AudioForwardingParticipants`, `AudioForwardingProtection`, `LocalAudioParticipantRegistry`, `NativeAudioStartup`, `HostAudioPrivacy`, `HostSentry`, `SentryAdmission`을 그대로 컴파일한다. context와 paired device는 실제 선언을 추출한다. OS 경계의 HAL과 Sentry 표면, 서명·실행 factory, relay의 외부 stdio 상대만 격리한다. 기존 보호 검사의 FakeHAL을 정확한 소스 범위로 재사용하고 protocol fallback은 기존 manifest의 SHA-256을 검사한다.

production runtime의 factory는 실제 `LocalAudioRelayLaunch.makeForwardingRelay(participants:)`다. 검사에서 같은 factory 이름의 OS 경계 fixture가 실제 LocalAudioRelay와 네트워크를 열지 않는 Python 자식 프로세스를 만든다. 배포 앱 경로·서명·runtime 패키지 및 외부 relay 상태기계 자체의 검증은 이 회귀의 범위가 아니다. 항상 true인 proof adapter나 coordinator 대역은 사용하지 않는다. HAL과 표면을 실패시키면 실제 Protection이 commit을 거부해야 한다. 실제 DN32 등 물리 장치의 보호 수용을 의미하지 않는다.

회귀는 observe 없는 submit 거절, 성공한 catalog v2와 동일 UUID attach, Hello 승격, 요청 만료·취소와 연결 생존의 분리, 두 UUID 중 하나의 종료와 OFF 보존, 실패한 최초 observe의 임시 attach 정리와 renew 부재, HTTP snapshot 관측, 5초 renew, 만료된 participant 작업과 보호·설정·boot·연결 무효화 이후 commit 거절, 소켓 종료와 전체 stop의 pipe 소유 범위, credential 로그 부재를 검사한다. 긴 native gate 검사는 participant의 5초 예산 만료 후에도 아직 배수 중인 작업이 관측·renew를 막지 않는지 확인한다. 그 만료 epoch의 성공 commit을 기대하지 않는다.

runtime은 같은 epoch를 중복 reconcile하지 않고, 긴 reconcile을 기다리는 동안 monitor나 per-connection renew를 직렬 대기시키지 않는다. 실제 relay FIFO와 RPC 자체의 제한 시간은 유지한다. FIFO를 점유한 단일 외부 RPC가 장시간 응답하지 않는 상황까지 renew를 보장한다고 주장하지 않는다.

생성자는 `init(privacy:sentry:prepareProtection:)`다. `prepareProtection: @MainActor () -> Bool`은 새 quiescing binding을 소비할 때 실제 privacy 또는 sentry readback이 없을 경우만 호출한다. 부모가 실제 admission, arm 또는 reconcile, sentry 활성화를 수행한다. runtime은 콜백 뒤에도 실제 모델의 proof를 다시 확인하며 arm으로 보호 세대나 설정이 바뀌면 이전 binding은 commit하지 않는다. 정상 active의 관측은 콜백을 재실행하지 않는다. catalog 조회는 보호 준비의 성공을 요구하지 않는다.

기존 `forwardingConfigure(privacyGeneration:)`와 `forwardingDisconnect(_:)`에는 caller admission 인자가 없다. runtime은 configure 동안 commit admission을 닫고 반환 후 controllerBoot/privacyGeneration/membership을 비교한다. disconnect는 정확한 bindingEpoch만 대상으로 한다. 이 두 API의 FIFO 대기 후 caller 세대를 송신 직전에 검사하려면 `admission: (@MainActor () -> Bool)?`가 필요하며, 이 작업의 허용 소스 범위에서는 추가하지 않았다. 이 경계는 전체 송신 계약의 미충족 항목으로 남는다.

이 작업자는 Swift 빌드·회귀를 실행하지 않는다. 부모의 Mini 실행과 통합 SDK 검사, 독립 검수 전에는 실행 통과나 실제 설치 수용으로 표시하지 않는다.
