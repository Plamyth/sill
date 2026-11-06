# 공통 configured Craft action wire v1

2026-11-06 Root가 확정한 Host246 소스 계약이다. 실제 Host245/Core551 및 연결기기의 설치·실행 수용 기록이 아니다. 구현 정본은 `Sources/StreamProtocol/ConfiguredCraftAction.swift`다.

## 전송과 식별

기존 Sill authenticated TLS의 viewer 연결만 사용한다. control은 kind **225**, device → Host, 최대 4096 bytes다. state는 kind **226**, Host → device, 최대 16384 bytes다. 역방향은 거절한다. 기존 221/222 provider start/stop과 223/224 SentryReturn 예약은 유지한다.

`WindowList.configuredCraftActions`는 optional 정수이며 1이 이 계약의 route 지원을 뜻한다. 생략된 Host에는 새 kind를 보내지 않는다. route 지원과 Core catalog 조회 성공은 별도다. catalog 성공 전 profile이나 assignment를 추정하지 않는다.

모든 UUID 문자열은 소문자 canonical UUID다. deviceId는 현재 Host TLS 등록 peer fingerprint의 소문자 64자리 hex다. SHA-256은 소문자 64자리 hex다. UTF-8 JSON의 중복 키, 알 수 없는 키, 누락 키, alias, 배열, 비정수 숫자 토큰, 과대 프레임을 거절한다. `issuedAt`은 UTC epoch milliseconds JSON 정수다. 문자열·소수·지수·boolean·음수·0·JavaScript 안전 정수 범위 초과를 거절한다. raw bytes는 production `ConfiguredCraftActionControl.decode` 또는 `ConfiguredCraftActionState.decode`로 검증한다.

## control exact union

catalog는 다음 세 필드만 가진다.

```json
{"schemaVersion":1,"requestId":"01234567-89ab-4cde-8fab-0123456789ab","operation":"catalog"}
```

invoke는 `schemaVersion`, `requestId`, `operation:"invoke"`, `client`만 가진다. client는 다음 정확한 9필드다.

```json
{"schemaVersion":1,"operation":"invoke-configured-craft-action","operationId":"11234567-89ab-4cde-8fab-0123456789ab","deviceId":"abababababababababababababababababababababababababababababababab","inputID":"speed.button.stop-play","trigger":"longPress","expectedProfileId":"21234567-89ab-4cde-8fab-0123456789ab","expectedAssignmentSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","issuedAt":1793910000000}
```

query는 `schemaVersion:1`, `requestId`, `operation:"query"`, `operationId`의 정확한 4필드다. query는 기존 operation의 readback이며 새로운 invoke를 만들지 않는다. client가 session을 발급하거나 echo하지 않는다.

## state exact union

공통 필드는 `schemaVersion:1`, `requestId`, `operation`, `deviceId`다. requestId와 operation은 control과 일치하고 deviceId는 Host가 인증한 현재 peer다. 공통 필드에 다음 payload 중 정확히 하나만 추가한다.

| operation | payload |
| --- | --- |
| catalog 성공 | `catalog` |
| invoke 또는 query 성공 | `result` |
| 실패 | `error`라는 stable code 문자열 |

error는 `^[a-z][a-z0-9_]{0,79}$` 형식이다. catalog 미지원·조회 불가는 `unsupported` 또는 `unavailable` error union으로 반환한다. 로컬 Craft의 supported:false 응답을 외부 catalog 성공으로 노출하지 않는다.

catalog는 다음 정확한 6필드다. `settingsSHA`와 session 필드는 없다.

```json
{"schemaVersion":1,"supported":true,"expectedProfileId":"21234567-89ab-4cde-8fab-0123456789ab","inputID":"speed.button.stop-play","trigger":"longPress","expectedAssignmentSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
```

result는 `outcome`, `operationId`, `deviceId`, `bindingSha256`, `invoked`, `effectConfirmed`의 필수 6필드와 optional `reason`만 가진다. outcome은 `invoked`, `rejected`, `unknown`이다. bindingSha256은 비교 전 `null`이거나 소문자 SHA-256 문자열이다. invoked는 boolean이며 executor 인계 사실만 표현한다. effectConfirmed는 항상 false다. nested result.reason이 있으면 공백만으로 구성되지 않은 UTF-8 최대 256바이트 문자열이며 원문을 보존한다. `prior-operation-result-unknown`, `executor-submitted-result-unknown` 같은 producer reason을 허용한다. outer state.error와 local bridge 외피 reason은 기존 `^[a-z][a-z0-9_]{0,79}$` stable code 규칙을 유지한다. result operationId는 invoke.client.operationId 또는 query.operationId와 일치하고 result.deviceId는 공통 deviceId와 일치한다.

```json
{"outcome":"unknown","operationId":"11234567-89ab-4cde-8fab-0123456789ab","deviceId":"abababababababababababababababababababababababababababababababab","bindingSha256":null,"invoked":false,"effectConfirmed":false,"reason":"invocation_uncertain"}
```

키 입력 인계나 invoked를 음성 시작·종료·가청 입출력으로 추론하지 않는다. unknown/timeout은 자동 재시도하지 않고 새 operationId로 재발행하지 않는다. 같은 요청은 기존 결과를 재사용하거나 read-only query로 확인한다. 연결별 ticket과 Host 내부 현재 peer·pairing generation·ForwardingClient.generation을 매 비동기 경계에서 확인한다.

## Host와 Core 경계

신뢰 경로는 Sill authenticated TLS peer → 기존 Core COMMAND_SOCKET → Obsidian 서명 전용 Craft socket이다. Host는 Craft socket에 직접 연결하거나 Node/LocalAudioRelay RPC를 추가하지 않는다. Core가 Craft에 넘기는 내부 JSON은 Core 소유다.

Core COMMAND_SOCKET 요청의 공통 필드는 정확히 `op`, `schemaVersion:1`, `requestId`, `deviceId`, `deviceSessionId`, `acceptedAt`이다. 여기의 deviceId는 Host가 인증한 deviceId이며 `authenticatedDeviceId`라는 추가 키는 보내지 않는다. deviceSessionId는 Host의 현재 ForwardingClient.generation이다. pairing generation은 Host 내부 fence다.

| op | 추가 필드 |
| --- | --- |
| `configuredCraftAction.catalog` | 없음 |
| `configuredCraftAction.invoke` | `client` exact9, `sentryState:"inactive"` |
| `configuredCraftAction.query` | `operationId` |

Host는 기존 ProviderCallSocket.open의 설치된 Core 서명 peer 검증을 마친 뒤 현재 TLS 등록·연결·pairing·Sentry inactive와 fresh 선택을 다시 검사하고 sender 호출 직전에 acceptedAt을 stamp한다. Core는 Host 서명 peer 및 acceptedAt의 500ms 이내 freshness를 확인한다. inactive가 아닌 Sentry 상태나 미확인은 invoke를 허용하지 않는다. Core query는 기존 operationId에 대한 읽기만 수행하고 조회 자체로 journal을 쓰지 않는다.

configured Craft는 socket의 writable 대기와 Core peer 재검사 뒤 MainActor의 현재 admission을 평가한다. 첫 nonblocking send는 서버 connection/ticket queue와 Sentry inactive 잠금 안에서 실행하고 그 구간에서 acceptedAt을 stamp한다. 최초 fresh snapshot의 intent·binding·selection revision을 실제 pre-write 구간에서 현재 HostAudioForwardingRuntime.snapshot과 비교한다. 같은 기기로 돌아왔어도 revision이 바뀌면 거절한다. 이 동기 검사와 첫 write 사이에는 await가 없으며 오디오 선택·소유권·pairing 변경은 MainActor와, 연결 변경은 서버 queue와, Sentry 전환은 같은 잠금과 직렬화된다. audio.admitted()만으로 선택의 현재성을 대신하지 않는다. 송신 표시는 첫 send가 양수 byte를 반환한 뒤에만 설정한다. 0-byte EAGAIN/EINTR은 admission과 stamp를 다시 확인한다. 아직 byte를 보내지 않은 요청만 현재성 변경으로 취소한다. 첫 send 뒤 결과가 모호하면 원 operation의 UNKNOWN 또는 해당 TLS 종료로 남기며 재invoke하지 않는다. 기존 provider의 일반 exchange/JSON 규칙은 유지한다.

Core 응답 공통 필드는 `op:"configuredCraftAction.reply"`, `schemaVersion:1`, 같은 `requestId`, `outcome`이다.

| outcome | 정확한 추가 필드 |
| --- | --- |
| `ok`, catalog | `catalog` exact6 |
| `ok`, invoke/query | `actionResult` exact6 + 그 내부 optional reason |
| `rejected` | `notSent:true`, `reason` |
| `unknown` | `notSent:false`, `reason` |

성공에 notSent/error/reason 등의 외피 필드를 추가하지 않는다. 잘못된 requestId, 잘못된 union 또는 다른 device/operation의 actionResult는 socket을 닫고 외부 응답을 보내지 않는다.

configured Core reply도 raw JSON 토큰부터 검증한다. `schemaVersion:1e0`, `1.0`, 중복 키와 깨진 JSON은 typed decode 실패와 동일하게 해당 요청 TLS를 닫는다. 다만 read-only query에서 이미 소유권을 확인한 캐시 결과가 있으면 불명 결과를 새로 해석하지 않고 기존 결과를 반환할 수 있다. 기존 provider의 일반 JSON decoder를 전역 변경하지 않는다.

확정 pre-dispatch 실패와 최초 invoke에 대한 Core local rejected/notSent:true는 원 operationId/deviceId의 typed result.rejected로 종결한다. invoked=false, effectConfirmed=false이며 bindingSha256은 아직 검증 전이면 null이다. socket open·실제 first-write admission 실패도 여기에 포함한다. 첫 byte 전에 이전 TLS가 만료되면 그 연결에는 응답하지 않되 확정 거절을 캐시에 남겨 같은 identity의 재접속에서 회수할 수 있게 한다. TLS/등록 identity·상관이 유효하지 않으면 해당 TLS를 닫거나 outer error로 거절하며 다른 operation의 종결 결과를 만들지 않는다.

첫 byte를 보낸 뒤 Core local unknown 또는 transport timeout은 typed result.unknown으로 반환한다. 처음 불명이면 bindingSha256=null, invoked=false, effectConfirmed=false다. 잘못된 응답·상관 실패는 해당 TLS만 닫을 수 있다. catalog의 rejected/unknown은 outer error다. Core ok actionResult는 상관 device/operation을 확인한 뒤 그대로 운반한다.

기존 operation의 내부 query 또는 명시 query가 rejected/notSent:true, unknown 또는 transport/decode 실패가 되어도 이는 조회의 실패일 뿐 원 invoke의 미실행 증거가 아니다. 다른 현재 연결의 조회가 더 최신 invoked 사실을 확인했다면 늦은 이전 조회 실패로 그 결과를 덮지 않는다. Host가 소유권을 확인한 기존 결과를 가지고 있으면 그 결과를 보존하며, UNKNOWN의 이미 확인된 invoked=true·binding·reason을 false/null로 낮추지 않는다. query ok 결과도 이미 확인된 invoked 사실을 취소하지 않는다. 캐시가 없으면 조회 실패를 outer error로 반환하거나 해당 TLS를 닫고 원 invoke 결과를 추정하지 않는다. 기기는 기존 UNKNOWN과 알고 있는 invoked 값을 유지한다. query 실패로 새 invoke를 자동 발행하지 않는다.

runtime이 잘못된 Core 응답·상관 실패·현재성 상실 등으로 nil을 반환하면 Coordinator는 unavailable error로 치환하지 않고 해당 요청의 TLS 연결만 닫는다. 다른 연결은 유지한다. 외부 error에는 Core local의 notSent 필드가 없으므로 외부 error만으로 미송신·미실행을 증명할 수 없다. invoke 송신 뒤 결과가 모호하면 기기는 UNKNOWN을 보존하고 원 operationId의 query로 확인한다. 새 ID 발급이나 자동 재invoke를 하지 않는다. Core의 명확한 local rejected/notSent:true와 송신 후 모호한 결과는 구분한다.

Host의 결과 캐시는 최대 128개이며 오래된 항목부터 회수한다. 확정 미송신의 typed rejected를 포함한 terminal 결과는 같은 client9/pairing generation의 재요청에 재사용하며 새 invoke/query를 만들지 않는다. 진행 중인 invoke 항목은 다른 busy 거절의 캐시 회수로 제거하지 않는다. 캐시에 남아 있는 unknown의 명시적 재요청은 같은 operationId의 Core query로 보낸다. Host가 timeout 뒤 자동 재시도하거나 새 ID를 생성하지 않는다. 캐시에서 회수된 ID의 명시적 invoke 재요청은 Core의 durable once journal이 원래 결과를 재사용해야 한다. Host에서 송신 전에 종결된 rejected가 캐시 회수된 뒤 Core query에 operation_not_found가 나와도 이전 거절이나 UNKNOWN을 다른 결과로 추정하지 않는다. 기기는 terminal operation을 새 ID나 재invoke로 복구하지 않는다. 캐시는 durable once의 대체물이 아니다. Core 재시작/Host 재시작 및 캐시 회수 후 중복 효과 방지는 Core 원담당의 필수 계약이다.

같은 인증 deviceId와 pairing identity의 reconnect는 새 Host session generation으로 원래 operationId를 query할 수 있다. Host의 이전 session ID를 echo하거나 새 invoke를 보내지 않는다. 캐시에 원래 operation이 있으면 소유 deviceId/pairing generation도 확인하며, 오래된 session만을 이유로 조회를 거절하지 않는다. Host 캐시가 없으면 현재 TLS/session 외피로 Core durable query를 수행한다. Core는 원 operation 소유 deviceId를 검증하며 다른 device 또는 재페어링으로 바뀐 identity를 거절한다. query는 durable journal을 쓰거나 원 invoke를 재전송하지 않는다.

invoke는 fresh 오디오 선택 readback과 현재 admission을 확인한다. 이미 정리된 explicit both OFF에서도 기존 통화 종료 toggle이 가능하며 active call을 선행조건으로 요구하지 않는다. 선택이 다른 device이거나 quiescing이면 신규 호출을 거절하고 선택을 바꾸지 않는다. Host 호출 운반은 입력·출력 ON/OFF, 실제 선택 장치, 일반 연결 해제 Mac 복귀, Sentry 보호 상태를 변경하지 않는다.

Sentry 보호 중 Craft CGHID 키 주입의 수용은 확인되지 않았다. 이 후보는 invoke를 `sentry_protected`로 거절하고 보호 상태/revision 변경 시 진행 중 호출을 취소한다. Sentry를 끄거나 Craft PID를 포괄 허용하지 않는다. 보호 유지형 정식 Host 입력 재사용과 실제 수용은 별도 후속 범위다. catalog/query는 읽기 전용이다.

## 검증 경계

`Tests/checks/configured-craft-action/run.py`는 production codec/runtime의 격리 검사다. 실제 Core/Craft, Mac 입력·오디오, 원격기기, 설치와 registry를 조작하지 않는다. 기기 담당은 동일 소스 commit/tree와 이 문서 hash를 기준으로 수용하며 실제 UI·오디오 수용은 별도 기록한다.


## iPad capability 2 소비 (2026-11-06, 별도 소스 후보)

공개 `client` 9필드, kind225/226, catalog 6필드, result 6필드는 바꾸지 않는다. 이 문서의 기존 capability 1 및 inactive invoke 계약은 유지한다. Host의 별도 `configured-craft-host-egress-v1` 계약(4235ce4f)에 따라 capability 2는 같은 inactive 경로와 보호된 현재 소유자 경로를 함께 지원한다. 보호 실행의 내부 `prepareHost`와 PID/tag 실행 계획은 Host/Core만 소유하며 iPad에는 추가하지 않는다.

- capability 1: 알려진 `inactive`와 `requested=false`만 실행 준비를 허용한다.
- capability 2: 위 경로 또는 정확한 `userSessionProtected`, `requested=true`, 현재 TLS/기기 binding의 검증된 owner control, 알려진 Sentry 상태가 모두 있어야 한다.
- unknown/pending/blocked, 권한이 미확인·퇴역된 세대, 진행 중이거나 결과 미확인인 현재 소유자의 인증 복귀는 실행을 거절한다. 복귀를 로컬에서 취소했어도 Host terminal 확인 전까지 같은 거절을 유지한다.

준비와 exchange는 capability의 정확한 버전, 전체 Sentry 상태(revision/authorizationGeneration 포함), network admission ticket을 메모리에 묶는다. 네트워크 큐가 관측한 catalog의 Sentry/capability/소스 세대 변경은 main 발행 전 ticket을 폐기한다. main이 같은 catalog를 발행하기 전에는 새 ticket을 얻을 수 없다. Sentry 제어·복귀 응답도 먼저 폐기하고 새 catalog를 기다린다. revision UUID의 크기나 도착한 UI 상태만으로 신선도를 추정하지 않는다.

iPad는 이 동작을 기존처럼 `NWConnection.send`에 직접 제출한다. 최종 API 호출 직전의 짧은 별도 lock 구간에서 ticket을 다시 검사한다. gate lock 아래에서는 SessionLink/SentryControl/main sync/사용자 콜백을 호출하지 않는다. 유선·무선 인계도 새 peer로 gate와 Sentry 소비자를 먼저 바인딩한 뒤 새 catalog로 준비를 복구한다. 기존 peer의 ticket은 재활성화하지 않는다.

준비 중 변경은 실행을 만들지 않는다. durable operation을 만든 뒤 송신 거절·오류·세대 변경이 있으면 pending exchange를 닫고 원문과 같은 operationID를 UNKNOWN으로 보존한다. 확정 not-sent로 추정해 지우거나 새 invoke로 바꾸지 않는다. 같은 durable owner의 명시적 query는 보호 실행 권한과 분리하며, 늦은 옛 exchange 응답이 기록을 지우지 못한다. 호출 접수는 통화 시작·종료·가청 오디오 수용이 아니다.

이 변경은 source-only 검수 범위다. 기존 iPad90/QA108, Host246/247/Craft3의 설치·기기·오디오·키 효과를 만들지 않는다. 정확한 통합·테스트 적용 및 실물 수용은 원담당이 다음 공유 구간에서 별도로 수행한다.
