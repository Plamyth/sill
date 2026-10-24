# OS 인증창으로 제한한 로컬 입력

이 변경은 실제 owner authentication challenge가 활성일 때 공식 Apple 인증 UI를 대상으로 하는 물리 타이핑과 왼쪽 클릭만 통과시킨다. 실제 OS 인증 성공 결과와 오디오 복귀 조건은 기존 `LocalAudioAuthentication`과 `HostAudioPrivacy`가 소유한다. 관측한 UI를 인증 성공으로 취급하지 않는다. `physicalPasswordAccepted`는 사람이 실기기에서 검증하기 전까지 `false`다.

`localAuthenticationWillBegin(requestID)`는 기존 실제 evaluate 호출 전 준비 훅이다. 정책은 이 ID와 이벤트마다 다시 읽은 `localAuthenticationChallengeID`를 대조한다. 기존 getter는 실제 evaluate 발급, 취소, 기한, 참여자 변경을 반영한다. 이전 준비 ID나 이전 창 관측만으로 허용하지 않는다.

`LocalAuthenticationInputPolicy`는 PID와 생성시각, 창 ID와 영역, 요청 ID, 250ms 관측기한, 요청과 대상별 전달표식을 보관한다. 관측은 MainActor에서 100ms 간격으로 수행한다. 공개 창 메타데이터만 사용하며 제목, AX, 텍스트, 스크린샷은 읽지 않는다. OS가 재사용한 창 ID는 현재 owner와 가림 상태를 다시 검증해 수용한다.

허용한 실행 파일은 파일 메타데이터로 확인한 두 경로다.

- `com.apple.LocalAuthentication.UIAgent`의 `/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha`.
- `com.apple.SecurityAgent`의 `/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent`.

관측기는 bundle ID, 정규 설치 실행 경로, 실제 프로세스 실행 경로, `anchor apple and identifier` live-code 서명, 조회 전후의 동일한 프로세스 생성시각을 확인한다. `UserNotificationCenter`, 다른 Apple 앱, 경로 위조, 서명 실패, 프로세스 종료, 여러 후보 창, 가려진 창은 거절한다. 프로세스 종료 알림도 해당 proof를 폐기한다.

session tap은 현재 challenge, 검증한 OS owner의 관측 proof, 기한과 두 tap 상태를 확인한 뒤 원래 PID0·HID1·tag0인 제한된 물리 입력만 수용한다. `refreshInputObservation`은 callback 밖에서 현재 요청·proof 태그에 묶인 HID source 두 개를 준비한다. 하나는 proof 태그, 하나는 clear0이며 공개 후 태그를 바꾸지 않는다. `HostSentryPlatform.stampEventSource`는 준비된 source의 태그와 state를 확인한 뒤 `event.setSource`를 호출한다. 태그, 원래 source state, 원래 PID 또는 현재 Host PID의 readback이 맞아야 반환한다.

annotated tap은 정확히 PID0 또는 현재 Host PID, HID1, 같은 요청·대상의 proof 태그, 현재 challenge, 관측 기한, 최종 `eventTargetUnixProcessID`와 현재 PID 생성시각을 검사한다. 클릭은 현재 window ID 두 필드와 bounds도 일치해야 한다. 다른 PID, 원격 태그, 대상 PID나 창 메타데이터 0·unknown은 거절한다. 통과 후 같은 native helper로 clear0을 수행하고 readback한다. clear는 앞선 요청·출처·대상 검사를 대신하지 않는다.

전달표식과 기존 원격 표식은 기존 `1...Int32.max` 범위를 유지한다. 이는 SDK의 64비트 범위 제한을 뜻하지 않는다. MacBook 27.0.1/26A434와 Mini 26.6.2/25G83의 무게시 관측에서 큰 64비트 값의 최초 setter 기록은 성공했고 후속 clear0은 반영되지 않았다. 명시적 userdata0도 후속 setter로 proof를 기록하지 못했다. 첫 기록과 재기록을 범위 문제로 묶지 않는다. native source API의 stamp·clear는 두 userdata0 준비 방식에서 각각 검사한다. 요청·대상이 바뀌면 기존 세대 관리로 다른 태그를 사용한다. 이 표식은 OS 대상 메타데이터의 암호학적 증명이 아니다.

`InputInjector.post(_:)`도 같은 native helper를 사용한다. 원래 source PID가 현재 Host여야 하며 이벤트 state가 InputInjector가 직접 소유한 source 객체의 state와 같아야 한다. 원격 태그는 source 생성 시 한 번 설정한다. InputInjector가 생성한 source는 `.hidSystemState`다. 같은 HID state와 현재 Host PID를 확인하고 외부 PID나 다른 state는 `setSource` 전에 거절한다. 마커와 출처 readback 실패 시 post와 성공 반환을 차단한다. 기존 dryRun, 보호 포인터 대상, 일반 원격 입력과 tap 게이트는 유지한다.

입력 callback은 캐시, `CFMachPortIsValid`, `ContinuousClock`, `proc_pidinfo(PROC_PIDTBSDINFO)`, 준비된 source의 getter와 `event.setSource`를 사용한다. source 생성과 태그 변경은 callback 밖에서 끝낸다. `CGEventSource(event:)`는 생산 경로에서 사용하지 않는다. Mini SDK 26.5에서 조작한 state를 가진 무게시 이벤트의 해당 생성자가 10초 안에 반환하지 않은 반례가 있어 제거했다. 이는 내부 IPC를 관측했다는 뜻이 아니다. `proc_pidinfo`는 프로세스 생성시각과 종료 상태를 읽는 커널 메타데이터 syscall이다. WindowServer, Security, AX, NSWorkspace 관측은 callback 밖에서 수행한다. OS tap 중단 callback은 먼저 허용 상태를 폐기하고 UI 갱신은 별도 MainActor 작업으로 넘긴다.

Command, Control, Option, Fn, function key, media, 창 전환 단축키, unknown source, 원격 tagged credential, 타 입력 종류는 인증 UI로 전달하지 않는다. Shift 문자 입력, 텍스트·편집 키, 숫자 키패드, 왼쪽 클릭만 지원한다. 인증 밖의 원격 tagged 입력은 MainActor에서 확인한 전경 일반 앱 PID와 생성시각으로만 최종 전달한다. 인증 UI와 UserNotificationCenter를 일반 원격 대상으로 관측하지 않으며, 직접 PID에 보내는 기존 포인터 경로에도 UserNotificationCenter 거절을 명시한다. 일반 앱 물리 입력은 두 필터에서 계속 거절한다. 취소 직전 in-flight 이벤트와 이전 요청의 표식도 annotated 단계에서 거절한다. 두 tap은 Sentry 해제 단계에서 함께 제거한다. 해제 readback 실패 시 차단용 tap 재설치를 시도한다.

오디오의 로컬 복귀 busy 상태가 Sentry 전역 검증을 무효화하더라도 실제 challenge가 있을 때 이미 설치한 두 tap과 커튼을 재검증해 인증 입력을 유지한다. 이 과정에서 tap을 새로 만들거나 오디오·원격 admission을 승인하지 않는다. 인증 중 timer는 전역 reconcile을 반복 호출하지 않는다.

이 정책은 공개 API의 관찰 범위를 사용한다. 요청과 창의 암호학적 1:1 attestation이나 같은 owner 프로세스 내부의 독점 인증 세션을 증명하지 않는다. 창·서명·tap 활성 상태는 MainActor 관측 시점의 증거다. callback은 OS가 annotated 단계에서 채운 최종 대상 PID와 프로세스 생성시각을 다시 검사한다. 이미 문서화된 시스템 보안 화면·secure input 한계는 유지한다. OS가 해당 이벤트나 target metadata를 제공하지 않으면 fail-closed이며 실제 암호 성공을 주장하지 않는다.

검사는 생산 정책·관측기·두 callback·공유 native helper·InputInjector post 본문을 추출한다. OS 관측·서명·identity는 inert 경계다. dictionary Event 검사는 정책·배선 검사이며 SDK 재기록 보증이 아니다. `SDKChecks.swift`는 실제 CGEvent로 명시적 userdata0과 미설정 getter0, 허용·거절, 취소·새 요청·PID 재사용·만료, 키·modifier·Unicode·type·timestamp·mouse payload 보존을 검사한다. Unicode는 합성한 검사 데이터만 읽는다. 원격 post는 기록 배열로 대체하고 실제 외부 전송은 하지 않는다. SDK typecheck에는 생산 Platform과 InputInjector 전체를 사용한다. 실제 OS 인증 시작, OS UI·AX 조회, 이벤트 post, Host 설치·실행, HAL, 기기·음성·서비스 효과는 0이다.

```sh
python3 -B Tests/checks/sentry-targeted-input/run.py \
  --suite all \
  --archive /Volumes/BT-Workspace/Development-Archives/CCR-Vision/auth-event-source-fix-20261025 \
  --label auth-event-source-all
```

`--suite local-auth-window`는 inert 인증 입력 검사, `--suite local-auth-sdk`는 실제 SDK 무게시 인증 입력 검사다. `--suite control`은 기존 제어 계약을 검사한다. 소스는 Mini stdin으로 전달하고 영구 checkout을 만들지 않는다. 독립 검수, PR, 공식 통합과 실제 설치는 부모 담당이다.

실제 물리 HID의 필드 형태, OS tap 사이 source 메타데이터와 Secure Input 동작, 실제 비밀번호 수용·인증 성공은 미검증이다. `physicalPasswordAccepted=false`를 유지한다. 순정 통화 producer 부재는 본체 원담당의 별도 장벽이며 이 소스 수정으로 해소하지 않는다.
