# 실제 보호 모델의 읽기 전용 증명

모델 네 파일은 Sill Git 객체 `2b4ce0da95cb819b1fc20985480622cd3f5f7bec`에서 포팅했다. 현재 결합 기준은 `470e1154ad574ac3021d086a531c549877130af8`이다. 부모가 포팅할 `AudioPrivacy.swift`와 `Sentry.swift`의 정확한 입력을 fixtures와 SHA-256 manifest로 고정한다. 정본에 두 파일이 있으면 정확한 바이트 일치를 확인하고, 없으면 이 입력으로 protocol 모듈을 만든다.

검사는 실제 `HostAudioPrivacy`, `HostSentry`, `SentryAdmission`, 참여자 등록부와 새 어댑터를 호출한다. HAL·표면·인증만 합성 구현이다. 기존 정상 `verify`의 전송 차단 조건은 그대로 두며, 참여자가 차단된 동안 실제 HAL read/plan과 표면 verify를 통한 별도 증명이 가능한지 확인한다. 증명 API는 HAL 쓰기·표면 engage/release·원장 저장을 호출하지 않는다. 모델 초기화의 합성 보호 활성화 이후 쓰기 카운터를0으로 재설정해 이를 확인한다.

`HostAudioPrivacy.forwardingPrivacyGeneration`은 실제 configure에 사용할 보호 세대다. `forwardingInvalidated` 관찰자는 HAL 변경·참여자 변경·로컬 인증 시작·보호 활성화/중지 등 기존 세대 무효화 이벤트를 전달한다. 같은 protected 상태가 유지돼도 이 이벤트에서 coordinator를 invalidate하고 구성을 다시 관측해야 한다. 증명 조회 자체는 이 관찰자를 호출하지 않는다. 참여자 willChange에서는 즉시 차단하고, 새 구성의 발급은 실제 didChange 이후에 해야 한다. `forwardingProof()`는 현재 HAL 상태를 직접 읽고 `plan().isEmpty`와 감시·저장·원래 로컬 상태·로컬 복귀 부재·동일 멤버십/세대를 확인한다. `forwardingProofCurrent`는 관측 세대만 대조하며 정상 미디어 admission을 열지 않는다. `HostSentry`의 같은 API는 실제 `surfaces.verify()` 전후 표면·세션·보호 세대를 확인한다.

`AudioForwardingProtection.readback(scope, until:)`와 `current(readback)`를 coordinator의 protection/protectionCurrent에 연결한다. 현재 configuration 콜백은 실제 단일 실행 인스턴스의 구성만 반환해야 한다. 콜백이 끝난 뒤 순수 세대 비교가 마지막이다. invalidate와 세션 등록·제거 왕복, HAL·표면·참여자·로컬 복귀의 변경은 이전 증명을 되살리지 않는다. 실제 호스트 소유자는 기존 관찰자가 해당 모델의 변경 경로를 호출하도록 연결해야 한다.

전용 runner는 실제 모델을 컴파일하며 legacy `LocalAudioRelayLaunch`는 링크 의존성으로만 포함한다. 필요한 `LocalAudioRelayRuntimeExpectation` 타입은 실제 `LocalAudioRelay.swift`의 정확한 선언을 임시 컴파일 입력으로 추출하며 파일의 전후 해시를 검사한다. relay 객체나 프로세스를 시작하지 않는다. 실행 factory·서명·실제 HAL·실제 표면·앱 설치·기기 수용은 이 검사로 증명하지 않는다. 전체 SDK는 원담당의 최종 결합 버전에서 한 번 검증한다.
