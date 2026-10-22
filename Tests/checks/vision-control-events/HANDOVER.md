# Vision 이벤트 소비 작성 인계

전용 작업공간 `/Volumes/BT-Workspace/Development-Archives/CCR-Vision/source-events-20261023/source`, 브랜치 `codex/vision-source-events-20261023`, 기준 `8393aa3f6fa5dc6b0bd851a3bbe5ffd877ac0493`에서 작성했다. 커밋·push·PR·설치·배포는 수행하지 않았다. 이 문서 이후 최종 독립 검수와 SDK 빌드는 부모 담당이다.

## 데이터와 설계

Pstack Feature → how → architect → Model the Domain 경로를 적용했다. ARENA와 추가 모델 호출은 사용자 금지에 따라 실행하지 않았다. 단일 작성자로 기존 창별 `VisionAppSession` 수명주기를 재사용했다. Ponytail의 기존 구조·표준 라이브러리 우선 원칙으로 Foundation/Combine/SwiftUI와 등록용 Security만 사용하고 새 의존성은 추가하지 않았다.

- [x] 기존 창 소유권·입력 허용 가드를 확인했다.
- [x] envelope enum, 순수 reducer, 바이트 SSE parser를 먼저 구성했다.
- [x] 공통 계약과 모바일 projector의 확정 필드로 맞췄다.
- [x] 단일 작성자 작업으로 공유 쓰기를 분리했다. 별도 fan-out은 금지되어 생략했다.
- [x] 생산 Swift 파일을 실제 컴파일하는 합성 검사를 작성·실행했다.
- [ ] 최종 독립 검수와 Vision SDK 빌드는 부모에게 인계했다.
- [ ] 커밋·통합·설치는 부모 소유이므로 수행하지 않았다.

공통 wire는 `ccr.control-events/v1`의 snapshot/patch/heartbeat다. snapshot 원본 JSON 전체와 문자열 ID를 보존하고 root set/unset, threads/catalog ID별 변경을 적용한다. generation(UUID), JS safe integer revision, baseRevision+1, SSE id를 검사한다. heartbeat는 cursor 일치만 확인하고 관측·권한을 갱신하지 않는다. gap과 새 세대 patch는 복구를 요구한다. 다른 세대 snapshot은 교체하며 동일 세대 역순 snapshot은 무시한다.

실제 모바일 adapter는 `unifiedControl.schema=1, rows`와 `sourceConnections`다. iPad currentGrid나 미확정 relay adapter를 추정하지 않는다. fallback threads/catalog는 명시 source=codex만 수용한다. ID는 provider·원본 ID·session/run·row key·host·로컬 instance/startedAt/workspaceIdentity를 구별한다. 원담당 미확인은 nil이며 소스 요약 권한을 행 권한으로 사용하지 않는다. Codex 원본 status, Cursor 명시 executionStatus+statusSource, agentStatus를 분리한다. 로컬 실행 근거가 없으면 실행은 미확인이며, 추후 명시 근거가 제공되면 보존한다. 원본 capability·readOnly 보고는 보존하지만 이 구현에는 메시지나 run 명령 API가 없다.

SSE 수신·UTF-8 프레이밍·JSON decode는 detached 작업에서 수행한다. 완성 envelope만 메인 액터에 전달하고 projection도 detached 작업에서 계산한다. UI에는 source/session/run/owner/실행 관측/연결 관측/명령권한을 구별한다. 구독은 창별로 하나이며 전경+상태 패널 표시 중에만 동작한다. 배경·패널 닫힘·창 반환은 구독과 backoff를 취소한다. 구독 UUID와 작업 UUID를 모두 검사해 이전 콜백을 차단한다.

공통 parser 기본 한도는 32MiB, 확정 모바일 gateway 한도는 8MiB이며 JSON 본문은 8192byte 여유를 둔 한도다. 완성 envelope 대기열은 최대 4개이며 초과 시 연결을 종료한다. 정상 상태 polling은 없다. EOF·명시된 일시 네트워크 오류만 1/2/4초, 최대 3회 재시도한다. 같은 오류가 연속 2회면 중단한다. 새 순차 patch는 진전으로 간주해 한도를 초기화한다. 인증·payload/schema·TLS·redirect 실패는 자동 재시도하지 않는다. 재접속은 Last-Event-ID 없이 full snapshot을 요청한다.

## 공식 등록

서명 빌드가 제공한 공개 서버 주소만 폼에 표시한다. 기본 소스에는 개인 Tailnet 주소를 저장하지 않는다. 자동 등록이나 코드 발급은 없다. 사용자가 SecureField의 공백 없는 24hex를 직접 제출하면 HTTPS POST `/v1/enroll`, 정확한 `Content-Type: application/json`, `{code}` 본문(128byte 이하)을 한 번 전송한다. 200 JSON의 64hex token만 수용하고 응답은 4096byte로 제한한다. 등록 timeout·전송 중 취소 등은 결과 미확인으로 표시하고 POST를 자동 재시도하지 않는다.

검증한 HTTPS origin과 token은 이 Vision 앱 자신의 `AfterFirstUnlockThisDeviceOnly` Keychain 항목에 함께 보관한다. 앱 시작 시 자신의 기존 항목만 복원하고 동일 origin의 Bearer GET `/v1/events`에 공급한다. Sill 키·CanvasRelay 토큰·Android 토큰·서버 토큰 파일은 읽거나 복사하지 않는다. 인증 정보가 없으면 연결 정보 미제공과 등록 폼을 표시한다. 임의 nonloopback HTTP, credentials/query/fragment origin, endpoint 변경과 redirect를 차단하고 OS 기본 TLS 신뢰를 유지한다. 코드·토큰을 로그나 UserDefaults에 저장하지 않는다.

## 실제 검사와 경계

작성 중 로컬 macOS에서 `python3 Tests/checks/vision-control-events/run.py`를 실행해 186개 assertion과 공통·모바일 golden 각각 6단계의 Node/Swift 전체 상태 동등성을 확인했다. 처음 테스트 컴파일의 비 throwing autoclosure·응답 tuple 순서를 수정한 뒤 통과했다. 원본 fixture의 SHA256은 `60facc67e1435383dfd6ef78cfcf7ea6393529ca1b399742d8f03a8273c350be`다. 별도의 생산 Foundation 파일 typecheck도 통과했다. 최종 인계 직전 추가한 창 소멸 시 취소와 row key/host ID 검증, runner 호환 수정은 부모 검사 대상이다.

검사는 UTF-8 모든 분할 위치, CR/LF/CRLF·BOM·다중 data·comment/id/retry·잘린 프레임·크기 제한, 순서/세대/heartbeat·기존 구독 callback, source별 원본 ID/권한 보존, EOF backoff 취소, URLProtocol 등록 응답·형식·오류·한 번 POST·timeout 중복 없음·다른 origin 결박·redirect 차단, 메모리 저장과 복원을 포함한다. 실제 Keychain 읽기/쓰기, 실물/호스트 UI·음성·등록 code 발급·실제 등록·외부 SSE·새 run·모델 호출은 실행하지 않았다.

Mini에서는 아래 명령으로 부모가 ephemeral 실행하고 전체 stdout 영수증을 맥북 정본 Node와 대조할 수 있다. Xcode 경로가 있을 때만 기본 DEVELOPER_DIR를 설정하고 기존 환경을 보존한다. 외부 정본 Node 모듈이 없으면 별도 미실행으로 기록하며 소스를 Mini에 복제하지 않는다.

```sh
python3 Tests/checks/vision-control-events/run.py --full-receipt --skip-node
```

로컬 재검사 명령은 `python3 Tests/checks/vision-control-events/run.py`다. 영수증은 `.build/receipt.json`이며 full 모드는 commonGolden/mobileGolden 전체와 생산 파일·fixture SHA를 stdout에 출력한다. Vision SDK 빌드와 실제 SwiftUI 표시·접근성·줄바꿈·실제 TLS/등록/재접속 수용은 미검증이다. generator는 새 생산 파일 9개를 정규 SillVision·SillVisionReleaseTest에 모두 등록했고 총 86개 source를 생성했다.

부모 후속 변경은 8MiB 큰 목록과 후속 변경, 등록 갱신·잠금 복원, 대문자 코드 정규화, 한국어 문구를 검증한다. 최종 수용 결과는 소스 외부의 원담당 영수증으로 확정한다.


## 2026-10-23 개별 sourceConnection 계약 후속 핸드백

전용 작업 키는 `vision-session-connection-20261023`이다. 작업공간은 `/Volumes/BT-Workspace/Development-Archives/CCR-Vision/source-events-20261023/session-connection`, 브랜치는 `codex/vision-session-connection-20261023`, 기준 HEAD는 `bf644337c9dd731ea919b6a78b6444983a488b7d`다. 부모 모델을 그대로 사용하고 추가 에이전트를 만들지 않았다. 이 절의 검증 범위가 위 과거 작성 기록과 구분되는 이번 변경의 실제 상태다.

- [x] Pstack poteto-mode와 Model the Domain을 읽고 기존 DTO를 재사용하는 상태 enum으로 결박 판정을 모았다. Ponytail full의 기존 구조·표준 라이브러리 우선 선택으로 새 type 파일이나 의존성을 만들지 않았다.
- [x] Android 정본 `server/mobile-control.js`의 `codexSourceState` 및 fixture를 직접 읽었다. 읽은 작업공간 HEAD는 `f15ccefbc6203b5180596c3e4147b8c9c732e583`, 해당 JS 파일 SHA256은 `a288f396c7f99cd66e56e731cbcdc8d9faeda507ddb7dff47ef845c9ae785620`다. 전달받은 `be5b9ba...`와 현재 읽기 HEAD를 동일 커밋이라고 주장하지 않는다.
- [x] fixture를 exact 바이트로 복사하고 runner expected SHA를 `9fb6288d6ac3d68f4d743d8703b091f263664d239248b53e6ba82d8cb554b319`로 갱신했다. 복사 후 SHA readback과 `git diff --check`를 수행했다.
- [x] `ControlEventsWork.sourceConnection`을 `unavailable / mismatched(observation) / current(observation) / stale(observation)`로 구성했다. DTO는 `ControlEventsSourceObservation`을 재사용하며 root 제공자 요약과 UI 표시를 구분한다.
- [x] provider, 원본 세션 및 모든 제공된 Codex UUID 별칭, 실행 별칭을 검증한다. `connected=true`, `state=connected`, 공백이 아닌 runtime owner, 0 이상 JS safe integer revision, 행 stale 아님을 모두 만족할 때만 current다. 시각 TTL과 `fresh`는 quiet 세션의 연결을 낮추지 않는다.
- [x] 원담당 `ownerThreadId`와 runtime `sourceConnection.owner`, 행 capability와 observer capability, 실행 관측과 연결 관측을 독립 보존·표시한다. 결박 거부 시 수신 document JSON을 수정하지 않는다. root 요약과 flat 연결값으로 개별 연결을 복원하지 않는다.
- [x] 합성 반례를 기존 Main.swift에 추가했다. runtime owner 분리, root 연결 중 개별 단절, stale 실행 상태·시각 보존, 오래된 quiet 관측 유지, wrong session/run/provider, UUID 별칭 충돌·형식, invalid revision, 누락·legacy 개별 객체, 빈 owner, observer send=false와 기존 행 send=true의 독립성, threads/catalog fallback을 포함한다. 4002행 및 후속 patch 검사에 개별 연결 없는 Codex 행 전체의 미확인 보존 단언을 추가했다.
- [ ] Swift 합성 검사, Node golden 동등성, 기존 206 검사 수 및 새 합계, 128 workspace 검사, 최종 독립 검수와 Vision SDK 빌드는 이번 자식 작업에서 실행하지 않았다. 기존 검사를 삭제하거나 축소하지 않았으며 부모가 exact 변경본에서 실행한다.
- [ ] 커밋·push·PR·Mini 최종 실행은 부모 소유다. 위 과거 `60facc67...`, PR 14, `bf6443...` 및 서명 1760은 새 개별 필드 수용 근거가 아니다.

변경 파일은 `visionOSClient/ControlEventsModel.swift`, `ControlEventsProjection.swift`, `ControlEventsPanel.swift`, `Tests/checks/vision-control-events/Main.swift`, `mobile-control-events-v1.json`, `run.py`, 이 HANDOVER뿐이다. Streaming/controller/enrollment/audio/SillVisionApp/generator는 수정하지 않았다. 실기기·음성·호스트·등록·Keychain·실제 SSE·네트워크 서비스·SDK·Mini 실행은 하지 않았으며 외부 효과는 0이다. 독립 검수 및 실제 UI 수용은 부모에게 남겨 두며 이 핸드백 뒤 쓰기를 중지한다.
