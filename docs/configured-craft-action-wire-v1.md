# 공통 configured Craft action wire v1

2026-11-06 Root가 확정한 Host246 소스 계약이다. 실제 Host244/Core3337/iPad88의 설치·실행 수용 기록이 아니다. 구현 정본은 `Sources/StreamProtocol/ConfiguredCraftAction.swift`다.

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

Core 응답 공통 필드는 `op:"configuredCraftAction.reply"`, `schemaVersion:1`, 같은 `requestId`, `outcome`이다.

| outcome | 정확한 추가 필드 |
| --- | --- |
| `ok`, catalog | `catalog` exact6 |
| `ok`, invoke/query | `actionResult` exact6 + 그 내부 optional reason |
| `rejected` | `notSent:true`, `reason` |
| `unknown` | `notSent:false`, `reason` |

성공에 notSent/error/reason 등의 외피 필드를 추가하지 않는다. 잘못된 requestId, 잘못된 union 또는 다른 device/operation의 actionResult는 socket을 닫고 외부 응답을 보내지 않는다.

Core local rejected는 외부 error union의 reason으로 매핑한다. Core local unknown과 송신 후 transport timeout은 외부 result unknown으로 매핑하며 bindingSha256은 null, invoked는 false, effectConfirmed는 false다. catalog의 unknown은 외부 error다. Core ok actionResult는 상관 device/operation을 확인한 뒤 그대로 운반한다.

Host의 결과 캐시는 최대 128개이며 오래된 항목부터 회수한다. terminal 결과는 같은 client9/pairing generation의 재요청에 재사용한다. 캐시에 남아 있는 unknown의 명시적 재요청은 같은 operationId의 Core query로 보낸다. Host가 timeout 뒤 자동 재시도하거나 새 ID를 생성하지 않는다. 캐시에서 회수된 ID의 명시적 invoke 재요청은 Core의 durable once journal이 원래 결과를 재사용해야 한다. 캐시는 durable once의 대체물이 아니다. Core 재시작/Host 재시작 및 캐시 회수 후 중복 효과 방지는 Core 원담당의 필수 계약이다.

같은 인증 deviceId와 pairing identity의 reconnect는 새 Host session generation으로 원래 operationId를 query할 수 있다. Host의 이전 session ID를 echo하거나 새 invoke를 보내지 않는다. 캐시에 원래 operation이 있으면 소유 deviceId/pairing generation도 확인하며, 오래된 session만을 이유로 조회를 거절하지 않는다. Host 캐시가 없으면 현재 TLS/session 외피로 Core durable query를 수행한다. Core는 원 operation 소유 deviceId를 검증하며 다른 device 또는 재페어링으로 바뀐 identity를 거절한다. query는 durable journal을 쓰거나 원 invoke를 재전송하지 않는다.

invoke는 fresh 오디오 선택 readback과 현재 admission을 확인한다. 이미 정리된 explicit both OFF에서도 기존 통화 종료 toggle이 가능하며 active call을 선행조건으로 요구하지 않는다. 선택이 다른 device이거나 quiescing이면 신규 호출을 거절하고 선택을 바꾸지 않는다. Host 호출 운반은 입력·출력 ON/OFF, 실제 선택 장치, 일반 연결 해제 Mac 복귀, Sentry 보호 상태를 변경하지 않는다.

Sentry 보호 중 Craft CGHID 키 주입의 수용은 확인되지 않았다. 이 후보는 invoke를 `sentry_protected`로 거절하고 보호 상태/revision 변경 시 진행 중 호출을 취소한다. Sentry를 끄거나 Craft PID를 포괄 허용하지 않는다. 보호 유지형 정식 Host 입력 재사용과 실제 수용은 별도 후속 범위다. catalog/query는 읽기 전용이다.

## 검증 경계

`Tests/checks/configured-craft-action/run.py`는 production codec/runtime의 격리 검사다. 실제 Core/Craft, Mac 입력·오디오, 원격기기, 설치와 registry를 조작하지 않는다. 기기 담당은 동일 소스 commit/tree와 이 문서 hash를 기준으로 수용하며 실제 UI·오디오 수용은 별도 기록한다.
