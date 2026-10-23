# iPad 공통 음성 계약 소비

원담당 01a13ace-e372-7ed1-9946-149df37ee1c3. 기준 4eff2c0bd2fa70de9acdd1fdf25d19c97f307012. 공통 계약 a14842b3a3a794f51d8ae0d90dbb8182a57ad8ea. 정상 앱59와 호스트149는 이 구현 구간에서 변경하지 않는다.

1. `how` over the affected subsystem.
2. `architect` for parallel design exploration.
3. Write the throughput checkpoint as four todo items.
4. Delegate code-writing to a subagent using your configured feature model with a specific scope.
5. Verify on the matching surface.
6. Rebase into small, ordered commits. Stack follow-ups.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

- [x] Blocking first steps. iPad 정본·clean HEAD·원격2823을 확인했다. 기존 workflow scope 장벽은 공식 게시와 설치에만 적용한다.
- [x] Independent workstreams. 한 작성자가 iPad DTO·상태·전송·media gate를 소유한다. 부모는 공통 호스트 계약 확인과 비작성 검증을 병렬로 수행한다.
- [x] Shared mutable state. 호스트·기기 설치·화면·마이크·권한·키·보관함은 변경하지 않는다. 테스트는 inert fixture만 사용한다.
- [x] Smallest safe decomposition. request/resume/update/stop과 media gate는 동일한 상태를 공유하므로 한 작성자가 맡는다. ARENA 및 후보 경쟁은 사용자 금지에 따라 실행하지 않는다.

## 데이터와 설계

공통 AudioForwarding DTO 원본 바이트를 복사해 소비한다. iPad의 독립 상태 모델이 현재 연결·인증된 Mac·기존 기기 SPKI·요청 ID·intent와 binding revision을 소유한다. 기존 마이크·스피커 구현은 유지하고 단일 permits 경계에서 native active 및 현재 기기/연결/transport 일치와 protected·foreground·권한을 함께 확인한다. 기존 IPadDesiredAudio는 로컬 desired와 저장을 담당하고 새 모델은 호스트 공통 소유권을 담당한다. 독립 상위 작업 관리자는 만들지 않는다.

임시 수동 선택은 제출 전 background/대상 변경에서 폐기한다. disconnect는 로컬 media를 닫고 같은 자기 intent만 resume한다. 다른 기기의 intent를 자동 request로 빼앗지 않는다. 오류·불일치·timeout은 unknown/blocked이며 media0이다. credentials·사용자 자료는 로그에 쓰지 않는다.

## 수용

- [x] exact DTO 468줄 바이트 동일. SHA-256 `5667ceac9a01cb80ca7a5bd3ecf88a0b7906088fb647a9b116141632fa93b843`. 공식 217/218은 4096/16384 및 역방향 거부. 읽기 원본 예약 kind는 219/220이며 215/216 선언은 없다.
- [x] 순수 상태 검사 158개, 실제 어댑터 38개, held-main-queue/frame/player 57개 통과. 실제 Xcode 27 iOS SDK의 서명 없는 Sill 앱 빌드 성공.
- [ ] 비작성 독립 검수와 통합 커밋. 부모가 기존 호스트 원담당 `01a13005-ff61-7780-b0e8-6dc171de1c9d`에게 작성자 checkpoint HEAD/tree/해시를 전달해 회수한다. 작성자는 추가 spawn하지 않았다.
- [ ] 공식 게시·등록 테스트 설치·실제 양방향 음성. 공통 호스트 교체 구간 및 기존 workflow 인증 장벽과 분리한다.

## 작성자 실행 결과

Pstack Feature 하위 작성자로 지정된 독점 WT에서 직접 구현했다. 부모는 이 WT에서 검사하거나 쓰지 않았다. Ponytail full의 기존 모델/저장/lock/frame/player 경계 재사용을 선택했다. ARENA, 순정 Goal, 하위 spawn은 실행하지 않았다.

- 공식 fixture와 호스트 확인에 맞춰 resume는 같은 자기 intent ID/revision/generation/input/output을 유지하고 binding revision만 올린다. request/update/stop은 own intent/binding cursor를 각각 올리고 관측한 snapshot revision으로 CAS한다.
- 실제 송신 시각을 기록하고 한 peer의 217은 하나만 유지한다. 배경 복귀/소스 왕복의 옛 218은 drain만 하며 현재 scope 증거로 쓰지 않는다. 해당 회귀의 최대 동시 217은 1이다.
- active는 1Hz observe 및 송신 시각 기준 3초 freshness를 요구한다. 10초 응답 대기와 구분한다. 만료·오류·거절·잘못된 ID/operation/peer·binding/configuration 불일치는 media0이며 자동 unsafe 재시도하지 않는다.
- 선택 지원과 media admission을 분리했다. 인증된218 이후 명시 입력 선택은 capability 전에 가능하다. 204는 active 후 새 microphone catalog와 기존 privacy v2 protected/전경/권한을 확인한 뒤에만 허용한다.
- 수동 off의 stop ACK 전 disconnect/timeout에서 이전 durable on을 자동 resume하지 않는 저장소 회귀를 추가했다. 기존 `IPadDesiredAudio`의 business state machine과 `IPadMicrophonePolicy.swift` 원본은 유지했다.
- blocked 뒤 같은 인증 범위의 지원 정보는 보존한다. 기존 chooser에서 명시 재선택하면 fresh observe로 복구하고, 그 자체가 자동 request/resume나 media 허가는 아니다.
- 기존 dynamic 회귀는 desired 49개, 실제 desired 어댑터 5개, 권한/notification 75개, 기본 microphone frame gate, 기존 playback 106개가 통과했다. supplementary wiring 11개도 통과했다. 구 static 문자열 검사 전체 정비는 하지 않았다.
- 새 held-main-queue 검사의 앞선 timeout/SIGTRAP은 성공으로 세지 않았다. 가짜 send의 동기 completion 재진입, 이전 decode 세마포어 소진/불균형을 확인해 inert send와 별도 decode permit/반환으로 수정한 뒤 57개가 통과했다. 제품 gate는 완화하지 않았다.
- 출력은 `storage-route`로 확인한 외장 루트의 `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/ipad-native-forwarding-20261024/worker-validation`만 사용했다. iOS SDK/AppKit/AVFoundation 본문 검사는 Mac SDK가 필요해 허용된 로컬 compact 경로로 수행했다. Mini에 소스를 복제하거나 서비스 작업을 추가하지 않았다.

최종 근거: 외장 `model.log`, `adapter.log`, `admission-held.log`, `nearby.log`, `desired.log`, `intent-adapters.log`, `ios-build.log`, `source-audit.json`, `admission-fixture-diagnosis.json`, `checkpoint-receipt.json`. source hash와 checkpoint commit/tree는 마지막 영수증에 기록한다.

미실행: 비작성 독립 검수, 원 통합/테스트 설치, 실제 호스트 TLS 왕복, 실기기/공유 UI/마이크/스피커 수용, 원격 push. 정상 기기/host 설치 0을 유지했다. 기존 게시·설치 장벽을 우회하지 않았으며 부모의 검수/통합 단계와 구분한다.
