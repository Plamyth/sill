# iPad 간단한 오디오 UI

- [x] 기존 지침·최신 결정·원장·exact base와 clean 상태 확인.
- [x] Feature 1–2: 부모가 계획·설계·독립검수 소유. 지정된 typed model 재사용, ARENA 금지.
- [x] **Blocking first steps.** 기존 route/provider/unknown/pending/catalog 검증 보존.
- [x] **Independent workstreams.** 부모 Host244와 독립 source 작업. 기기·Host·오디오·네트워크 조작 0.
- [x] **Shared mutable state.** 이 WT 단독 writer. 외장 CURRENT-RESUME은 부모만 작성.
- [x] **Smallest safe decomposition.** SwiftUI chooser와 기존 검사에 한정. 새 모델·의존성 없음.
- [x] Feature 4: 통화·마이크·스피커·작은 기기 sheet 및 8초 bounded 준비 구현.
- [x] Feature 5: 소스 파싱·기존 작은 검사. SDK/UI/실기 수용은 부모가 별도로 수행.
- [x] Feature 6: 자기 변경 네 파일만 확인 후 `6b82e77f` 커밋. 이 todo는 지시대로 WT에 미커밋 보존.
- [ ] Feature 7: 독립검수는 부모가 수행. 자기 검토로 대체하지 않음.
- [ ] Feature 8: push/PR/통합/설치는 부모 범위.

데이터 정본: IPadAudioRoutePolicy.Selection, IPadProviderCall, MacAudioRouteSession.CatalogToken.
Notion: 승인 가이드 fetch가 503 dependency_failure로 실패. 원격 저장 0.

검사: `python3 -B Tests/checks/ipad-provider-call/run.py` exit 0.
212 wire/model + 55 native model + 191 forwarding model + 107 forwarding adapter + 164 provider adapter + 69 admission = 798 assertions.
`SOURCE_UNCHANGED=true; SCRATCH_REMOVED=true` 확인. 첫 시도 actor 접근 오류는 UIApplication의 기존 상태 조회 방식으로 수정했고 두 번째 실행이 통과했다.
그 뒤 chooser 초기 토글을 실제 선택값으로 표시하고 시작 시 기본 iPad 입출력 준비, 오류 때만 조회 버튼 노출, 취소 전 Task 검사·현재 context의 권한만 해제하는 UI 수정 후 iOS target 소스 파싱과 `git diff --check` 재통과.
파싱은 macOS sysroot 경고가 있었으며 실제 iOS SDK typecheck/build가 아니다.

준비는 같은 peer/trusted key/provider connection/target/context와 기존 desired revision만 사용한다. 한 번의 apply 뒤 최대 8초이며 새 큐·자동 재시도 없음. 취소·정지·target/peer/source/foreground/provider generation/trust/blocked/supersession/timeout 뒤 provider start 0을 합성 어댑터로 확인했다. 준비·라우팅 성공은 통화 성공으로 표시하지 않는다.
Host/Core/privacy/권한·wire 모델 및 기존 앱87/runner 변경 0. 공유 Host/기기/UI/오디오/HAL/서명/네트워크 조작·설치·push/PR/통합 0.
부모 다음 단계: 비작성 독립검수 → `python3 -B Tests/checks/ipad-audio-forwarding/build-ios.py <부모가 배정한 출력 절대경로>` → 승인된 정확 후보의 UI·실기 수용. Native capability 미지원은 그대로 비활성이고 Dots/Grok으로 대신 실행하지 않는다.

## 부모의 최종 반환 지시 후 경계 조사 인계

현재 후보는 `6b82e77fcd63c90d99b48c1e7ae3f1992fa87798`, tree `5b27f04a3b1e65e4fe7b5d7af3f17dcc1d17e894` 그대로다. 새 소스 수정·검사·커밋 없음. 798개 통과는 앞서 나열한 합성 모델/어댑터 검사이며 아래 두 경계를 새로 재현·통과시킨 결과가 아니다.

1. 정상 scope 변화 경계 미수정. Host `StreamCoordinator.microphoneCatalog`는 보호 확인 전 microphone capability를 생략하고 보호 확인 후 추가한다. `SillVirtualMicrophoneOwner.microphoneGrant`는 같은 source/inputGeneration/videoEpoch/fingerprint/실제 destination이면 기존 grant를 재사용하므로 최초 nil→scope 추가와 이미 존재한 destination/capability 교체는 구분해야 한다. iPad `IPadMicrophonePolicy.observe`가 scope를 추가하면 `IPadDesiredAudio.observe`와 `desiredAudioObserve`가 revision을 무효화한다. 현재 helper의 전체 context 동등성·preparedRevisions 비교 및 chooser의 context onChange 취소는 정상 추가도 중단할 수 있다. 같은 TLS/hostKey/provider generation/target/forwarding source·generation·videoEpoch·lifecycle 검증은 보존해야 한다.
2. 권한 대기 기한 경계 미수정. 현재 helper는 기존 `applyAudioRoutes` 호출 전에 ContinuousClock 8초 deadline을 만든다. OS 권한 응답 시간이 8초를 넘으면 허용 후 준비 시작 전에 만료될 수 있다. chooser의 scenePhase != active 취소도 자체 권한 프롬프트의 일시적인 inactive를 취소한다. 기존 applyAudioRoutes/AudioResumeObserver는 자신의 Authorization을 유지한 inactive→active 복귀와 실제 background/취소/peer·source 변경을 구분하는 경로가 있으므로 이를 재사용하고 실제 준비 deadline은 권한 처리가 끝난 뒤 시작하는 최소 수리가 필요하다.
3. 현재 desired revision은 명시적 OFF/ON/취소와 정상 catalog 전이 양쪽에서 모두 갱신된다. context/revision 비교를 무조건 제거하면 supersession을 놓칠 수 있으므로 부모가 최소 변경을 판단한다. 이 작성자가 검토한 선택 변경 UUID 추가안은 아직 적용하지 않았다. microphone/wire/auth 모델 변경 0.

부모가 현재 필수 검사 이후 더 넓은 반복 검사를 만들지 말고 반환하라고 지시하여 여기서 source writer를 반환한다. SDK typecheck/build·비작성 독립검수·UI/실기/Host244·서명·공식 통합·설치는 부모가 이어받는다. native ancestor에 도구로 경계 조율을 전달하려던 호출은 `send_message_to_thread cannot send to your native ancestor`로 거절됐으며 전달 성공으로 기록하지 않는다. 새 대체 담당·실행은 만들지 않았다.

## 6b 미수용 후 부모가 직접 요청한 P2 후속 수정

- [x] 6b 보존, 같은 exclusive WT에서 후속 source writer 재개. Host/기기/권한/서명/실제 UI/네트워크 조작 0.
- [x] 준비 8초 기한을 applyAudioRoutes의 기존 권한 처리·active 복귀 완료 뒤로 이동.
- [x] 현재 operation/context의 audioRouteAuthorization이 있는 일시 inactive만 기존 권한 경로로 유지. background·관계없는 inactive는 취소.
- [x] 동일 trusted peer/provider generation/target/forwarding source·generation·videoEpoch·lifecycle을 고정하고 최초 nil→microphone scope 추가만 채택. 기존 nonnil scope 교체·소실은 거절.
- [x] 명시적 선택 setter의 UUID로 새 선택/OFF→ON/취소를 구분. catalog 갱신으로 무효화되는 media revision을 준비 취소 근거로 오용하지 않음. 기존 microphone/권한/wire 모델은 변경하지 않았고 iPad helper 필드와 setter만 최소 변경.
- [x] 제한된 preparation/permission/scope 회귀 검사와 6b baseline 재현.
- [x] 후속 커밋 입력 범위·검사·로컬 기록 정리. 이 todo도 커밋에 포함하고 commit/전체 clean readback 결과는 채팅으로 반환한다.

첫 제한 검사 실행은 테스트 본문 이전 StreamProtocol 컴파일이 240초에 종료되어 회귀 결과 없음. 자신의 정확한 scratch 경로를 가진 잔여 compiler PID 24256만 SIGTERM했고 이전 scratch 부재를 확인했다. 같은 제한 모드에만 whole-module compile과 600초 컴파일 예산을 적용해 다음 실행 중이다. 전체 기존 798검사/SDK/Host·기기 검사를 새로 반복하지 않는다.

후속 제한 실행 결과: `python3 -B Tests/checks/ipad-provider-call/run.py --preparation-boundaries` exit 0, `PASS 147 preparation/permission/scope checks, including baseline P2 reproductions; Host/device/audio/network effects0`, `SOURCE_UNCHANGED=true; SCRATCH_REMOVED=true`. 부모도 약 540초 컴파일 영수증을 확인했다. 이 통과 뒤 helper·모델은 수정하지 않았고 아래 chooser 동기화만 추가했으므로 같은 helper suite를 반복하지 않는다. fixture의 boundaries 분기에서 unreachable-code 경고가 있었으며 실패는 아니다.

## Godel stale 선택 P2 후속 수정과 최종 반환 자료

- 취소 시 cancelDesiredAudioRequest 뒤 chooser.selection을 현재 audioRouteSelection으로 맞춘다.
- start 준비 실패 catch에서도 기존 operation ID/Task cancellation guard 뒤 현재 actual selection으로 맞춘다. 늦은 이전 작업이 새 사용자 선택을 덮는 경로는 유지하지 않는다.
- 변경 두 줄을 역산한 chooser SHA256은 Godel 검수본 `28cc42875186520132205c9a9b10545b6766ed36ab3a9362780536ede4600e55`와 정확히 같다. 최종 chooser SHA256은 `cd2f085de8856f10fbd85e302257824e002979c364893c45f463865090d4d42d`다.
- `python3 -B Tests/checks/ipad-provider-call/chooser-selection.py` exit 0: 실제 startCall/cancelOperation/applySelection 및 실제 토글 setter 본문을 추출해 17개 검사 통과. 6b baseline의 취소 후/실패 후 스피커 OFF가 마이크를 재요청하는 두 반례를 재현했고 수정본은 재요청 0, 취소 뒤 새 마이크 선택·generation/error 상태 보존을 확인했다. 이 검사는 표준 Swift/합성 client만 사용하며 UIKit/AV/Host/기기 실행이 아니다. `SOURCE_UNCHANGED=true; SCRATCH_REMOVED=true`.
- 최종 Swift iOS target 소스 파싱, 관련 Python AST 파싱, git diff --check 통과. macOS sysroot 경고가 있는 파싱이며 iOS SDK typecheck/build를 대신하지 않는다.
- Host/StreamProtocol 및 기존 IPadMicrophonePolicy/IPadProviderCall/IPadDesiredAudio/IPadAudioForwarding/StreamClient+AudioRoutes/MacAudioRouteSession의 6b 대비 diff는 없다. 기존 모델·Host·wire 권한 가드 변경과 실제 OS 권한/기기/Host/서명 조작 0.

실제 UI 필수 수용 항목(부모 소유, 아직 모두 미검증):
- 같은 정확한 설치 후보에서 통화 시작 → 준비 취소 → 스피커 OFF. 마이크/스피커 표시와 실제 desired OFF/OFF, 새 마이크 요청·capture 재개 0을 확인한다.
- 실제 준비 실패 → 스피커 OFF. 오류가 유지되고 반대쪽 마이크가 재요청되지 않는지 확인한다.
- 준비 취소 → 새 마이크 ON 선택 → 늦은 이전 응답. 새 선택·세대가 유지되는지 확인한다.
- 정상 OS 권한 팝업이 가능한 승인 시험 환경에서는 긴 권한 대기·inactive→active와 이후 준비를 확인하고, 권한 거부/실제 background/peer 변경 시 late start 0을 확인한다. 권한 상태를 임의 초기화하지 않는다.
- 정상 nil→microphone capability 추가와 기존 capability 교체·소실/입력 세대·video epoch 교체를 구분하고, 실제 native provider 시작/종료 ACK와 가청 입출력은 별도 수용한다.

후속 변경 범위: iOSClient의 IPadAudioRouteChooser.swift, StreamClient+ProviderCall.swift, StreamClient+DesiredAudio.swift, StreamClient.swift; 기존 검사 adapter.py, intent-adapters.py, adapter-main.swift, run.py와 새 관련 chooser-selection.py; 이 audit todo. 새 제품 abstraction/의존성/큐 없음. SDK·독립검수·공식 통합·서명·설치·실기 수용은 부모가 이어받는다. 6b는 선행 커밋으로 보존한다.

부모의 마지막 이식성 검수에 따라 chooser-selection.py의 git show 호출을 제거했다. 현재 startCall/cancelOperation 메서드 추출을 재사용하고 해당 resync 줄만 제거한 mutant로 같은 취소·실패 반례를 검출한다. 레거시 제품 메서드 원본을 복제·보관하거나 새 의존성을 추가하지 않는다.
Git-free 최종 재검사: `python3 -B Tests/checks/ipad-provider-call/chooser-selection.py` exit 0, `PASS 17 actual chooser action/selection checks including resync mutation detection; Git/UI/Host/device/audio effects0`, `SOURCE_UNCHANGED=true; SCRATCH_REMOVED=true`. helper/모델은 147개 통과 뒤 변경 0이므로 부모 지시대로 helper 전체를 반복하지 않았다. 앞선 6b baseline 결과는 당시 영수증으로 구분한다.
기록 정정: 최초 6b 설명의 'apply 뒤 최대 8초'와 달리 실제 6b 코드는 apply/OS 권한 앞에서 deadline을 생성했다. 이 후속에서 실제 기한 생성 위치를 권한 처리 뒤로 이동했다.
이 파일은 부모의 명시적 승인에 따라 최종 소스 커밋에 포함한다. 유일 작업 기록 삭제·임의 ignore 변경은 하지 않는다.
