# 보호 중 기존 음성 동작의 Host 송신 계약

작업: `sentry-configured-voice-egress-20261106`. 통합 책임자는 Vision 원담당
`01a13005-ff61-7780-b0e8-6dc171de1c9d`다. Host 기준은 f01a6faa,
Craft 기준은 ccd9dfc, Core 기준은 ad9ff1d다. Core 원담당은 현재 PR291에서
configured-craft-action-adapter.js를 수정하지 않으며 별도 소스 작업의 파일 분리를 확인했다.
현재 Host247/Craft3/Vision1839 후보와 실제 설치본은 이 작업에서 바꾸지 않는다.

## 기존 구조와 선택

Craft의 저장된 STOP/PLAY longPress 선택, 5필드 hash, 검증과 durable once journal을
재사용한다. 실제 키 송신만 Host InputInjector에 넘긴다. 기존 local invoke는 그대로다.
Craft에 Host 태그를 붙이거나 Craft PID를 허용하지 않는다. 별도 producer, 음성 서버,
통화 세션, 자동 재시도, 새 endpoint와 외부 wire 번호를 만들지 않는다.

Craft가 action을 executor에 인계했다는 기존 invoked 의미를 유지한다. Host용 executor는
구조화된 한 번의 실행 계획을 반환하며 로컬 focus/CGEvent를 호출하지 않는다.
reserve-before-execute와 완료 journal은 같은 공통 invoke 함수에서 처리한다.
인계 계획 응답 유실, journal 실패, 중복 요청에는 계획을 다시 발급하지 않는다.
UNKNOWN과 query-only 복구를 유지한다. invoked는 실제 키나 통화 효과가 아니며
effectConfirmed는 항상 false다. 따라서 별도 준비/확정/ACK journal 프로토콜은 필요 없다.

## 내부 wire

외부 client9와 kind225/226, catalog 및 actionResult 형식은 불변이다.
서명된 Host→Core의 새로운 내부 op만 `configuredCraftAction.prepareHost`다.
기존 COMMON6 + client + sentryState의 정확한 8개 필드를 사용한다.
`sentryState`는 실제 `userSessionProtected`일 때만 허용한다. 기존 invoke의 inactive-only
검사는 그대로 유지한다. Core는 기존 signed peer/current/session/deadline 검사를 재사용한다.

Core→Craft는 기존 outer6과 같은 필드 집합을 사용하되 operation은
`prepare-host-configured-craft-action`이다. Craft 내부에서 공통 invoke request로
정규화하므로 같은 operationId의 local invoke와 Host 인계가 같은 journal 예약을 공유한다.
클라이언트가 plan, bundle, keyCode, modifier, Host session을 지정하지 않는다.

Craft 응답은 정확히 다음 네 필드다.

```text
schemaVersion: 1
operation: "host-configured-craft-action"
actionResult: 기존 응답
execution: null 또는 아래 계획
```

execution의 정확한 필드는 다음 여덟 개다.

```text
operationId: 원래 operation UUID, 소문자
deviceId: 인증된 device hex64
deviceSessionId: Host가 준 현재 session UUID, 소문자
bindingSha256: 실제 저장된 assignment hash
bundleIdentifier: "com.openai.codex"
keyCode: 실제 저장된 macOS virtual keyCode 정수, 0...127
modifiers: 실제 Craft ModifierSet rawValue 정수, 0...31
expiresAt: executor 인계 시각 + 1500ms, 안전한 epoch 정수
```

execution은 이번 요청에서 공통 invoke의 executor가 딱 한 번 호출됐고 journal 결과가
`outcome=invoked, invoked=true`인 경우에만 존재한다. 중복·query·UNKNOWN에는 null이다.
Core는 모든 필드와 request/result 상관관계, 1500ms 이하 남은 기한을 검증한다.
Core→Host는 기존 reply ok + actionResult에 `hostExecution`을 추가한다.
prepareHost에만 이 nullable 필드를 허용한다. 일반 invoke/query/catalog에는 추가하지 않는다.
Host는 이 계획을 외부 클라이언트에 노출하지 않는다.

## 실제 효과 경계

Host는 현재 peer의 Sentry admission, 정확히 같은 Sentry state/revision, source/window epoch,
TLS/pairing/session, foreground 및 동일 오디오 선택을 마지막 post 직전까지 재확인한다.
pending/blocked/unknown/local-return-auth는 계속 거절한다. inactive-only 경로는 약화하지 않는다.
현재 보호 허용과 직렬화되는 별도 prepared-host write admission을 사용한다.

Host만 이미 실행 중인 유일한 com.openai.codex process를 선택·focus하고 정확한 PID와
process identity 및 실제 foreground를 재확인한다. 준비되지 않으면 거절하며 앱/대화 생성이나
global fallback을 하지 않는다. focus 대기 중에도 취소·기한을 확인한다.
InputInjector의 Host PID/tag stamping, Sentry target/filterAnnotated 검사를 유지한다.
Craft modifier 비트는 기존 CG flags로 명시 변환하고 virtual keyCode를 HID usage로 해석하지 않는다.
가능하면 기존 chord 생성 및 owned key-release debt를 재사용한다. 취소 후 새 down은 0이며,
이미 나간 down의 up만 같은 operation 소유 범위에서 정리한다. 다른 기기의 키는 건드리지 않는다.

한 번만 받은 계획이라도 기한·권한이 바뀌면 post하지 않는다. Craft 인계 이후 효과가
불명확하거나 취소됐으면 invoked 사실을 지우거나 rejected로 바꾸지 않고 UNKNOWN으로 남긴다.
plan이 없는 기존 결과와 query 결과는 절대로 실행하지 않는다. 로컬 경로 fallback도 없다.

## 지원 표시와 시험

Host 전 경로가 구현된 경우에만 configuredCraftActions=2를 광고한다. Vision은 버전2와
현재 userSessionProtected의 owner admission을 확인한 경우에만 이 버튼을 허용한다.
버전1/미지원/불명 상태는 기존 거절을 유지한다. iPad/Android 소비 변경은 각 원담당에게
같은 계약으로 전달한다. 이번 소스 시험을 기기 수용으로 대신하지 않는다.

공통 허용표는 cap1이면 `inactive && !requested`의 기존 invoke만 허용하고, cap2이면
동일한 inactive 기존 invoke 또는 `userSessionProtected && requested`이며 현재 ownerControl과
known state가 확인된 보호 경로만 허용한다. pending/blocked/unknown 상태는 두 버전 모두 거절한다.

Craft: 임시 journal과 fake executor/clock으로 local/Host 교차 중복, 저장 hash/target 변조,
구형 요청 보존, stale 및 journal 실패, 재시작 query에서 재발급0을 시험한다.
Host: 실제 프로토콜·admission과 fake target/sink로 같은 state만 허용, 마지막 post 전
모든 세대 변경의 down0, 부분 post의 owner-up만 정리, raw modifier 변환과 중복/query0을 시험한다.
Core: inert transport/peer/clock으로 exact shape, 상관관계, deadline, unsupported와
sent/UNKNOWN/query-only 경계를 시험한다. 실제 socket/CGEvent.post/앱 focus/음성/기기 호출은 0이다.
실제 Codex 자동 제어의 도구 거절을 다른 경로로 우회하지 않는다.

Pstack의 Ground→Sketch→Agree→Implement를 기존 조사와 이 계약으로 진행한다.
ARENA와 그 대체 후보 경쟁은 사용자 금지로 생략한다. Ponytail은 공통 producer/journal과
기존 입력/검사 구조를 재사용하고 새 2단계 ACK 서비스 대신 기존 인계 의미를 유지하는 데 적용한다.
