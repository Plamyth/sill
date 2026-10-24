# OS 인증창으로 제한한 로컬 입력

이 변경은 실제 owner authentication challenge가 활성일 때 공식 Apple 인증 UI를 대상으로 하는 물리 타이핑과 왼쪽 클릭만 통과시킨다. 실제 OS 인증 성공 결과와 오디오 복귀 조건은 기존 `LocalAudioAuthentication`과 `HostAudioPrivacy`가 소유한다. 관측한 UI를 인증 성공으로 취급하지 않는다. `physicalPasswordAccepted`는 사람이 실기기에서 검증하기 전까지 `false`다.

`localAuthenticationWillBegin(requestID)`는 기존 실제 evaluate 호출 전 준비 훅이다. 정책은 이 ID와 이벤트마다 다시 읽은 `localAuthenticationChallengeID`를 대조한다. 기존 getter는 실제 evaluate 발급, 취소, 기한, 참여자 변경을 반영한다. 이전 준비 ID나 이전 창 관측만으로 허용하지 않는다.

`LocalAuthenticationInputPolicy`는 PID와 생성시각, 창 ID와 영역, 요청 ID, 250ms 관측기한, 요청과 대상별 전달표식을 보관한다. 관측은 MainActor에서 100ms 간격으로 수행한다. 공개 창 메타데이터만 사용하며 제목, AX, 텍스트, 스크린샷은 읽지 않는다. OS가 재사용한 창 ID는 현재 owner와 가림 상태를 다시 검증해 수용한다.

허용한 실행 파일은 파일 메타데이터로 확인한 두 경로다.

- `com.apple.LocalAuthentication.UIAgent`의 `/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha`.
- `com.apple.SecurityAgent`의 `/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent`.

관측기는 bundle ID, 정규 설치 실행 경로, 실제 프로세스 실행 경로, `anchor apple and identifier` live-code 서명, 조회 전후의 동일한 프로세스 생성시각을 확인한다. `UserNotificationCenter`, 다른 Apple 앱, 경로 위조, 서명 실패, 프로세스 종료, 여러 후보 창, 가려진 창은 거절한다. 프로세스 종료 알림도 해당 proof를 폐기한다.

session tap은 유효한 실제 challenge, 관측 proof, 설치·활성을 확인한 annotated tap이 있을 때 제한한 물리 이벤트에 전달표식을 붙인다. annotated tap은 같은 요청과 대상의 표식, 현재 challenge, `eventTargetUnixProcessID`, 현재 PID 생성시각을 다시 확인한다. 클릭은 현재 window ID 두 필드와 bounds도 일치해야 한다. 통과 시 표식을 지운다. 대상 PID나 창 메타데이터가 0 또는 unknown이면 거절한다.

전달표식과 기존 원격 표식은 `1...Int32.max` 범위를 사용한다. 실제 inert CGEvent 검사에서 큰 64비트 값은 기록되지 않았고 이 범위의 값은 기록·재조회됐다. 요청과 대상이 바뀔 때 표식이 재사용되지 않도록 Sentry 수명 안에서 순차 세대를 사용한다. OS가 채우는 대상 메타데이터의 진위를 이 표식만으로 증명하지 않는다.

입력 callback은 캐시, `CFMachPortIsValid`, `ContinuousClock`, `proc_pidinfo(PROC_PIDTBSDINFO)`만 사용한다. `proc_pidinfo`는 프로세스 생성시각과 종료 상태를 읽는 커널 메타데이터 syscall이다. WindowServer, Security, AX, NSWorkspace 관측은 callback 밖에서 수행한다. OS tap 중단 callback은 먼저 허용 상태를 폐기하고 UI 갱신은 별도 MainActor 작업으로 넘긴다.

Command, Control, Option, Fn, function key, media, 창 전환 단축키, unknown source, 원격 tagged credential, 타 입력 종류는 인증 UI로 전달하지 않는다. Shift 문자 입력, 텍스트·편집 키, 숫자 키패드, 왼쪽 클릭만 지원한다. 인증 밖의 원격 tagged 입력은 MainActor에서 확인한 전경 일반 앱 PID와 생성시각으로만 최종 전달한다. 인증 UI와 UserNotificationCenter를 일반 원격 대상으로 관측하지 않으며, 직접 PID에 보내는 기존 포인터 경로에도 UserNotificationCenter 거절을 명시한다. 일반 앱 물리 입력은 두 필터에서 계속 거절한다. 취소 직전 in-flight 이벤트와 이전 요청의 표식도 annotated 단계에서 거절한다. 두 tap은 Sentry 해제 단계에서 함께 제거한다. 해제 readback 실패 시 차단용 tap 재설치를 시도한다.

오디오의 로컬 복귀 busy 상태가 Sentry 전역 검증을 무효화하더라도 실제 challenge가 있을 때 이미 설치한 두 tap과 커튼을 재검증해 인증 입력을 유지한다. 이 과정에서 tap을 새로 만들거나 오디오·원격 admission을 승인하지 않는다. 인증 중 timer는 전역 reconcile을 반복 호출하지 않는다.

이 정책은 공개 API의 관찰 범위를 사용한다. 요청과 창의 암호학적 1:1 attestation이나 같은 owner 프로세스 내부의 독점 인증 세션을 증명하지 않는다. 창·서명·tap 활성 상태는 MainActor 관측 시점의 증거다. callback은 OS가 annotated 단계에서 채운 최종 대상 PID와 프로세스 생성시각을 다시 검사한다. 이미 문서화된 시스템 보안 화면·secure input 한계는 유지한다. OS가 해당 이벤트나 target metadata를 제공하지 않으면 fail-closed이며 실제 암호 성공을 주장하지 않는다.

검사는 실제 생산 정책, 관측기와 두 callback 본문을 추출해 가짜 OS 경계에서 실행한다. SDK typecheck에는 생산 Platform과 InputInjector 전체를 사용한다. 실제 OS 인증 시작, OS UI 조회, 이벤트 post, Host, HAL, 기기와 서비스 효과는 0이다.

```sh
python3 -B Tests/checks/sentry-targeted-input/run.py \
  --suite all \
  --archive /Volumes/BT-Workspace/Development-Archives/CCR-Vision/local-auth-window-input-20261025 \
  --label owner-auth-regressions-09
```

`--suite local-auth-window`로 인증 입력 검사만 실행할 수 있다. `--suite control`은 기존 제어 계약을 검사한다. 소스는 Mini stdin으로 전달하고 영구 checkout을 만들지 않는다. 독립 검수, PR, 공식 통합과 실제 설치는 부모 담당이다.
