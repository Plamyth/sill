# Vision 음성 제어 UI 인계

Vision에서 기존 Mac 음성 대화와 마이크·스피커를 한 영역에서 제어하도록 UI를 간소화한 소스 후보다. OFF에서 음성 시작 한 번으로 양방향을 준비하는 필수 경로는 아직 미구현이며, 아래 계약 차단을 Root가 먼저 해결해야 한다. 제품 완료나 실기 수용으로 기록하지 않는다.

- 작업: `vision-simple-call-controls-20261106`
- 담당: `01a1ae9f-9a2b-7a10-9df5-b5aa0c885b32`
- 통합 책임자: Root. Host244 진단·오디오 복귀·최종 빌드·서명·설치·독립 검수는 Root 범위다.
- 워크트리: `/Users/ambrion/.codex/worktrees/vision-simple-call-controls-20261106`
- 브랜치: `codex/vision-simple-call-controls-20261106`
- 기준: `dd1fd1c8b8ab75c83851a1add729f250e7e676fc`, tree `28dbc4f9eba8347d59472e2f194c3a5c9a530cf2`
- 시작 dirty: 없음. 다른 작업의 파일·Root 원장은 수정하지 않았다.

## 재사용과 변경

`VisionWindowLease`의 owner 검사, `VisionRemoteAudioIntent`의 독립 microphone/playback 의도, `VisionRemoteAudioAuthority`의 실제 실행 권한, forwarding binding, `VisionProviderCall`의 pending/result/activeCall을 그대로 사용한다. 새 mutable 통화 상태나 권한 모델은 만들지 않았다. 통화 결과와 미디어 상태는 합쳐서 성공 처리하지 않는다.

세 패널·상단 중복 오디오 메뉴·자동 오디오 제안·provider picker를 제거했다. 시작/종료·Vision 마이크·Vision 스피커·장치를 한 영역에 놓았다. 마이크와 스피커는 각각 끌 수 있고 기존 실패·미지원·정리 재시도 경로를 유지한다. 장치 선택은 기존 chooser를 480pt 팝오버로 재사용하며 Mac 전체 기본 장치를 바꾸는 고지는 보존한다.

읽기 전용 `VisionProviderCall.Controls`는 기존 `canStart`와 현재 창·원장·신선한 준비 결과를 함께 검사한다. 준비 producer가 없어도 기존 activeCall은 지우지 않으며 종료는 기존 `canStop`으로 판단한다. 기존 통화 API·wire·authority는 변경하지 않았다. Dots·Grok을 새 시작 경로로 대체하지 않는다.

iPad 비교는 `7c2fd6858783de6b1d938b3a6531c7f6094053c5`의 `IPadAudioRouteChooser`와 `prepareAndStartIPadProviderCall`을 읽기만 했다. 그 비동기 준비 계약을 Vision에서 지원한다고 추정하지 않았다.

## OFF에서 한 번에 시작하는 경로의 차단

2026-11-06 추가 지시를 대조했다. 사용자 최종 요구는 지원되는 환경에서 명시적 시작 한 번으로 Vision 기본 입출력을 준비한 뒤 같은 통화를 한 번 시작하는 것이다. 현재 UI 후보는 이 전체 경로를 완성하지 못한다. 마이크·스피커 선행 조작을 제품 수용 조건으로 제안하지 않는다.

1. 기존 `visionProviderCanStart`는 owner·`forwarding.binding`을 요구한다. OFF에서는 이 권한이 없다.
2. `consumeVisionNativePreparedTarget`도 owner·보호·native 원장의 fence를 요구한다. OFF에서 준비 가능 여부를 독립적으로 증명하는 producer 계약은 이 작업에서 확인되지 않았다. 현재 0.166의 producer/지원 부재는 사용자와 Root가 제공한 사실이며, 이 담당은 실제 Host를 조회하거나 조작하지 않았다.
3. `performVisionProviderCall`의 시작 요청은 lease revision·device·input/output 의도와 outer selector를 보낸다. 준비 target의 thread·voice session을 이 요청에 결속하는 필드는 없다. UI에서 추정 native API를 만들거나 다른 대화·새 appserver로 대체하지 않았다.
4. `setVisionAudioDesired`는 저장 의도를 바꾸고 기존 실제 미디어를 revoke한 뒤 재조정한다. 이 시작 시도가 만든 두 방향만 revision·이전 host/window 세대에 따라 회수하는 전용 API는 없다. 취소·owner 상실 때 새 사용자의 의도를 덮지 않고 예약 의도를 회수하는 경로를 확인하기 전 자동 준비를 붙이지 않았다.

Root가 계약을 확정한 뒤 필요한 후속 범위는 `명시 start intent → 지원 확인 → 기존 desired 양방향 준비 → 기한 내 fresh binding/prepared target → 같은 start 1회`와 취소·owner 상실·세대 변경 시 해당 의도만 정리하는 동작이다. 현재 미지원 시작 버튼은 비활성이고, 버튼을 그린 사실이나 기존 `canPerform` capability 광고를 작동하는 통화로 기록하지 않는다. 이번 변경에 새 미디어 자동 시작은 없다.

## 검사와 근거

Pstack Feature/how/architect/TDD 경로를 적용했고 ARENA는 실행하지 않았다. 부모가 분리한 UI 작업을 단일 writer로 수행했다. Ponytail full과 Model the Domain에 따라 기존 모델에 읽기 전용 표시만 추가했다. Test Behavior, Not Implementation에 따라 실제 production 모델을 기존 계약 fixture에서 실행했다. Root의 독립 검수는 아직 남아 있다.

먼저 `python3 -B Tests/checks/vision-simple-call-controls/run.py`가 기존 분리 패널·자동 제안·provider picker 때문에 실패함을 확인했다. 실패 출력은 `Audio control panels observed=2; expected one unified surface without automatic offers`였다. 이후 같은 검사가 통과했다.

- `python3 -B Tests/checks/vision-simple-call-controls/run.py`: 구조 검사 5개와 기존 production 계약 runner 통과. 출력 `165 selector and client checks`, `ACTUAL_METHOD_CHECKS 214`, `WINDOW_HANDOFF_CHECKS 55`, `SOURCE_UNCHANGED=true; SCRATCH_REMOVED=true`.
- 표시 모델 회귀: 준비 부재·기한·다른 창·숨김·보호 상실·revision/binding epoch 변경·pending·기존 종료·실패 후 명시 재시도·다른 provider의 기존 종료를 검사했다. 네트워크·기기·미디어는 실행하지 않는다.
- 장치 팝오버 조정 후 구조 검사만 `--static-only`로 재확인했다. 모델·계약 코드는 이 조정에서 바뀌지 않았다.
- SDK 도구는 전역 `xcode-select`를 바꾸지 않고 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 사용한다. 프로젝트의 실제 minimum target은 xros 2.5다. 최초 제한 검사에서 2.0을 사용해 기존 RemoteTLS availability 오류가 났으며, 프로젝트 값 2.5로 교정했다. 전체 앱 빌드는 하지 않았다.
- `python3 -B Tests/checks/vision-simple-call-controls/sdk.py <근거 폴더>/sdk-final`: 실제 XROS 27.0 SDK에서 protocol module·추출한 통합 SwiftUI 제어/순수 모델 타입 검사·변경 파일 구문 검사가 `[0, 0, 0]`으로 통과했다. `sourceUnchanged=true`, `scratchRemoved=true`다. 장치 chooser는 구문 검사 범위이며 전체 chooser/앱 타입 검사를 주장하지 않는다.

검사 로그·SDK 결과·최종 source/commit/tree 영수증은 `/Volumes/BT-Workspace/Development-Archives/CCR-Vision/vision-simple-call-controls-20261106`에 둔다. SDK 검사는 실제 SwiftUI와 production 순수 모델을 사용하되 StreamClient와 audio controller를 실행하지 않는 stub으로 제한한다. 앱 전체 타입 검사·링크·설치·실제 창 배치 수용은 증명하지 않는다.

## 남은 단계와 보호 범위

현재 단계는 UI 소스·순수 검사·작업 커밋 후보다. Root 통합·독립 검수·전체 빌드·서명·설치·착용 검증·실제 Mac 통화·실제 마이크/스피커·OFF 원클릭 준비·취소/세대 회수는 미검증 또는 미구현이다. Root의 기존 call API 검수와 겹치는 구현은 만들지 않았다.

실제 Host/Core 접속·오디오 장치 변경·권한·키·페어링·설치·기기 조작·외부 효과·Root 원장 쓰기는 모두 0이다. 빌드·설치는 Root 통합 검수 이후, physical wearing 검증은 사용자 후속 지시 범위다.
