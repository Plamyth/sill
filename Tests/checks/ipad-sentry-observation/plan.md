# iPad Sentry 공유 DTO 소비자 인계

작업 키는 `ipad-sentry-shared-dto-20261025`이다. 단독 워크트리는 `/Users/ambrion/.codex/worktrees/ccr-ipad-sentry-shared-dto-20261025`, 브랜치는 `codex/ipad-sentry-shared-dto-20261025`, 기준 커밋은 `3beab7f8abd337c082617a31e53224759e35719f`이다. 커밋, rebase, cherry-pick, SDK, 설치, 실제 기기, Host, UI, HAL, 네트워크, Keychain 조작은 이 담당 범위에 없다.

## Pstack Feature 절차

- [x] 1. `how` over the affected subsystem. 실제 `StreamClient`는 현재 peer를 확인한 뒤 main에서 같은 catalog를 관찰과 제어에 전달한다. `StreamClient+Sentry`는 기존 Mac 등록, 현재 pinned TLS와 공개 기기 지문을 검사한다. Store 저장과 readback 뒤에만 packet을 반환한다. MessageReader와 기존 영상 catalog, input epoch와 fence는 기준 소스를 유지한다.
- [x] 2. `architect` for parallel design exploration. 사용자 ARENA 금지를 우선하여 후보 경쟁은 실행하지 않았다. 기존 Phase와 public Store/Binding을 유지하고 공유 typed request, response, capability를 사용한다. Stored에 optional `priorRawRequest` 한 슬롯을 더한다. 관찰 adapter는 표준 JSONSerialization으로 control을 분리하며 v1 core도 공통 SentryState로 decode한다. 별도 Request/Reply/Control/Report와 자체 parser는 없다.
- [x] 3. Write the throughput checkpoint as four todo items.
  - **Blocking first steps.** 기준 HEAD/branch, AGENTS, 최신 결정과 저장 정책을 확인했다. 부모가 포트한 공유 5파일을 e17 exact blob과 handoff SHA에 대조했다.
  - **Independent workstreams.** 이 담당은 소비자와 이 검사를 작성한다. 부모는 다른 WT에서 계약 대조와 source-request 검사 3파일을 수정한다. 부모가 동결 후 독립 검수와 SDK를 수행한다.
  - **Shared mutable state.** 이 WT의 지정 소비자 3파일과 ipad-sentry-observation 검사만 수정한다. 공통 5파일은 읽기 전용이다. Host 배선, 실제 앱, 다른 담당 파일은 쓰지 않는다.
  - **Smallest safe decomposition.** 요청 상태와 저장 복원은 하나의 상태 계약이므로 단독 구현한다. 기존 closure store로 저장 실패를 주입하고 기존 stand-in으로 실제 frontend와 reader를 실행한다. 추가 parser, timer, history UI, 테스트 전용 query API를 만들지 않는다.
- [x] 4. Delegate code-writing to a subagent. 부모 Feature에서 단독 WT로 위임받은 실제 구현 담당이다. 중첩 spawn 도구는 없으며 직접 diff를 작성한다. 부모의 비작성 독립 검수를 별도 gate로 유지한다.
- [x] 5. Verify on the matching surface. `python3 -B Tests/checks/ipad-sentry-observation/run.py`로 공통 DTO, 소비자, 실제 frontend 함수와 MessageReader를 실행한다. Host 고정 fixture의 raw와 SHA를 읽고 추가 반례는 메모리에서만 만든다. 최종 실행 결과와 소스 SHA는 `.build/checks/ipad-sentry-observation/`에 기록한다.
- [ ] 부모 독립 검수. 이 담당의 검사와 자가 diff 검토를 독립 CLEAR로 세지 않는다.
- [ ] 부모 iOS SDK. 이 담당이 SDK를 실행하지 않는다.
- [x] 6. Rebase into small, ordered commits. skip. 직접 사용자 지시로 커밋, rebase, cherry-pick을 하지 않는다. 구현 diff와 sdk-ready marker를 인계한다.
- [x] 7. If the design is contested, `interrogate` before shipping. skip. 부모의 구체 계약과 추가 반례를 수용하며 ARENA를 간접 호출하지 않는다.
- [x] 8. Run **Opening a PR**. skip. 이 담당은 소스 동결까지 맡고 게시와 통합은 부모 범위다.

Ponytail full은 기존 공통 DTO, Foundation, Store/Binding, 원문 query 경로를 재사용하는 선택에 적용했다. Model the Domain 원칙은 공유 UUID/enum과 기존 Phase로 상태를 표현하는 선택에 적용했다. Test Behavior, Not Implementation 원칙은 반환 packet, 보존 raw, UI 상태, 재시작과 저장 실패를 실제 소비자에서 검증하는 데 적용했다.

## 확정 계약

Authoritative Host는 `e17ec2abec7d9ea47b6262531674fc17fe22c6af`, tree는 `667e2199977d0cc8ac600e79682095613284b9a2`다. 계약과 handoff는 `/Volumes/BT-Workspace/Development-Archives/CCR-Vision/sentry-control-v2-contract-20261025/`에 있다. 부모가 같은 바이트로 포트한 `Sentry.swift`, `SentryControl.swift`, `fixtures.json`, `request.schema.json`, `response.schema.json`을 수정하지 않는다. run.py와 freeze.py는 정확한 blob과 SHA를 다시 검사한다.

`SentryControlRequest(rawRequest:)`가 정확 7필드, 중복, 알 수 없는 필드, 타입, lowercase UUID와 512-byte cap을 검증한다. 편의 init은 새 명시 요청만 생성한다. immutable rawRequest를 저장하고 수동 query에는 재인코딩 없이 사용한다. `SentryControlResponse.decodePayload`가 정확 6필드와 4096-byte cap, typed operation/code를 검증한다. rejected의 accepted=true와 false는 모두 실패 결과이며 UI rejected로 표현한다.

기존 `Sill.sentryPending.v2`와 public Binding은 유지한다. priorRawRequest 없는 기존 Stored와 키순서가 임의인 정상 7필드 원문을 그대로 읽는다. pending-on에서 명시 off를 보낼 때 두 원문을 같은 저장 레코드에 영속화하고 readback한 뒤 packet을 반환한다. off 거절은 원 on을 active raw로, 거절 off를 prior raw로 저장 복원한 뒤 unknown으로 두고 수동 query를 허용한다. 거절 설명은 problem에 남긴다. 복원 저장 실패는 두 원문을 보존하고 unknown에서 새 요청을 막는다. off unknown과 재시작도 두 원문을 유지한다.

미응답 inFlight와 unknown은 새 요청을 차단한다. 유효한 pending 응답을 받은 원 요청이 on이며 현재 typed control.manualIntent가 on이면 명시 off만 허용한다. off pending에는 세 번째 명령을 허용하지 않는다. 새 peer의 새 session에서는 먼저 old raw 그대로 수동 query한다. receive가 현재 session 응답을 검증한 뒤 확인된 pending-on이면 새 current session/revision과 새 ID의 명시 off를 허용한다. old raw는 바뀌지 않는다. Host busy는 on 원문 복원 경로로 처리한다. applied와 superseded는 증거를 보존한 채 다음 명시 요청을 허용한다.

Host e17의 statusLocked는 pendingControl이 있으면 requested와 관계없이 phase.pending을 보고한다. prepareControl은 on일 때만 requested=true로 바꾼다. 따라서 pending/false는 합법적인 prepared-off이며 완료가 아니다. 관찰 문구는 `보호 전환 중`이다. inactive/true, userSessionProtected/false와 blocked/false는 계속 모순으로 거절한다. applied off는 inactive/false일 때만 수용한다.

Host 공통 정책은 trusted 정상 v1 state의 기존 v1 on-only 제어를 허용하고 off를 허용하지 않는다. 기준 iPad 3beab에는 v1 활성화 송신과 UI가 없으므로 이 iPad v2 소비자는 control capability가 없을 때 관찰만 지원한다. 이 지원 범위를 공통 legacy query-only 금지 정책으로 해석하지 않는다. 공유 SentryActivation과 SentryResponse의 원문을 보존하고 이번 작업에 별도 legacy 제어기를 추가하지 않는다.

잘못되거나 미래의 control은 catalog adapter에서 nil로 낮추고 v1 core 관찰을 유지한다. 유효한 shared control은 그대로 보존한다. 영상 catalog decode는 변경하지 않는다. 성공 reply의 잘못된 capability는 strict decoder가 거절하며 소비자는 원문을 unknown으로 보존한다.

## 원장 접수 확인 후속 교정

부모는 이전 소스 SHA `74af2f3bb2a48635492506a7c88c4e7c1c00db8a0cbd6203df8f015060ec002e`의 SDK BUILD SUCCEEDED와 프로세스 exit 0을 보고했다. 이전 독립 검수는 미접수 원문의 같은 session query P1 외에 추가 P1/P2가 없다고 보고했다. 이전 결과와 SDK 보고 출처를 `.build/checks/ipad-sentry-observation/previous-74af/`에 보존한다. 이 담당이 SDK 로그를 직접 읽거나 이 후속 버전의 SDK 통과를 확인한 것은 아니다. 부모는 SDK 종료 뒤 후속 변경을 승인했고 같은 WT의 쓰기·검사를 중단했다. 새 버전의 delta 독립 검수와 SDK는 부모가 다시 수행한다.

Stored에 optional `ledgerAccepted`, `priorLedgerAccepted`를 추가한다. 없는 값은 false로 취급해 이전 저장 형식과 호환한다. 새 명시 요청은 false이며 prior on을 보존할 때 그 원문의 접수 값도 같이 저장한다. 현재 peer와 binding, boot, auth, 현재 응답 session에 일치하고 공통 strict decoder를 통과한 accepted=true 응답만 해당 원문의 true를 저장한다. 저장과 readback이 확인되기 전에 가용성을 바꾸지 않는다. 저장 실패는 unknown이며 원문을 유지한다. accepted=false는 기존 true를 내리지 않는다. Host가 확정한 원장 128개 eviction은 revision을 옛값으로 복원하지 않으므로 접수된 old CAS의 같은 session 조회도 미등록이면 unknown과 최초 효과 0이다. 소비자 검사는 보존된 원문 조회에 eviction unknown 응답을 주입해 true를 eligibility로만 유지하고 완료·새 명령·CAS 수정을 허용하지 않는지 확인한다. flags는 원장 접수 증거이며 권한이나 완료 상태가 아니다. failed/rejected의 accepted=true도 접수 증거이고 완료는 아니다.

원장의 접수가 확인되지 않은 원문은 같은 TLS session에서 조회 재전송하지 않는다. 저장만 한 경우, 송신 직전 중단, contentProcessed 성공·실패, ACK 미확인, 응답 timeout도 true로 승격하지 않는다. 같은 binding/device/boot/auth의 새 session에서는 old session과 revision을 포함한 원문 그대로 수동 조회할 수 있다. 미등록 응답이 unknown이면 최초 효과와 접수 proof를 만들지 않는다. 저장된 true도 matches의 trust와 scope 검사를 통과해야 사용할 수 있다. BUSY 복원은 on true와 off false를 원문에 맞춰 교환하고 재시작 뒤에도 유지한다. 같은 session 미접수 상태에는 기존 상태 텍스트로 연결을 다시 맺은 뒤 확인하라는 안내만 표시한다. 새 wire kind, query kind, 재실행 버튼이나 history UI는 없다.

이번 후속 제품 변경은 IPadSentryControl.swift 한 파일에만 둔다. main.swift의 기존 302개 회귀 기대 중 미접수 같은 session query와 저장 키 기대를 canonical 계약에 맞게 교정하고 새 반례를 추가한다. Standins.swift에는 ACK 생략 시험을 위한 메모리 flag만 추가한다. 공통 5파일과 schema 및 실제 frontend/reader wiring은 보존한다. run.py의 기존 exact source·40개 정적 검사는 재사용하며 새 결과로 source SHA와 marker를 재발급한다.

## 검증과 완료 경계

원 Host fixture on/off bytes와 SHA, 공통 request/reply decode, 소비자의 실제 on/off 경로, accepted true/false rejected, pending-on 후 off, busy와 다른 거절 복원, 재시작, unknown, 저장 실패와 readback 실패, 늦은 peer와 session 및 Host/device/auth 경계를 검사한다. strict payload의 중복과 추가·누락 필드, 타입, UUID, capability와 operation/code 반례도 검사한다. 추가 fixture는 메모리에서 만들고 고정 Host fixture를 변경하지 않는다.

run.py의 과거 e88 guard는 기준3beab의 실제 불변 코드와 Host e17의 exact blob을 대조하도록 갱신했다. 부모의 비중복 `source-request/{run.py,transport.py,Client.swift}` 변경을 허용 목록에 명시했다. 이 담당은 그 파일을 수정하지 않는다.

`freeze.py`는 검사 입력과 현재 소스의 SHA가 같을 때만 `.build/checks/ipad-sentry-observation/sdk-ready.json`을 만든다. 결과, 로그, implementation.diff와 소스 SHA를 같은 디렉터리에 둔다. 소스와 DTO 수용은 실제 Host 배선·설치·기기·네트워크·보호 효과 수용이 아니다. producer가 없는 native Codex call은 unsupported로 유지한다.
