# Vision 공통 Craft 음성 명령 소스 준비

최초 UI 기준은 `b997a824bf9b6b0730f148ac0da386a8f5850356`이다. 준비 모델 `e6c41ead57280aed44e990e661591b96424dac12` / tree `8e27f333e6da0878b7c9da0e9ed6909f8ac3b520`의 전체 Release xros 빌드 1834가 성공한 뒤, 이 후속 계약 정정을 같은 WT/브랜치에 반영한다. 1834가 후속 정정 소스까지 검증한 것은 아니다. 기존 체크리스트 두 개는 사용자 지시에 따라 검증 사본과 이동 원본을 외장에 보존했다. 이 문서는 이전 native prepared-producer 방향을 공통 shortcut으로 대체하며 실제 제품 연결 완료를 뜻하지 않는다.

## 확정된 의미와 데이터

- 기존 Craft 사용자 할당을 재사용하는 500ms longPress다. 키 조합·새 native producer·appserver·대화·endpoint·wire 번호는 만들지 않는다.
- `CatalogRequest`는 `schemaVersion:1`, `operation:get-configured-craft-action` 두 필드다. positive Catalog는 schemaVersion·supported·UUID expectedProfileId·inputID·trigger·lowercase expectedAssignmentSha256 여섯 필드를 요구한다. Catalog에는 session이나 settings SHA가 없다.
- `Request`는 확정된 아홉 필드 schemaVersion·operation·단일 operationId·deviceId·inputID·trigger·UUID expectedProfileId·expectedAssignmentSha256·issuedAt를 인코딩한다. operation은 `invoke-configured-craft-action`, issuedAt는 UTC epoch milliseconds JSON 정수다. deviceSessionId는 client DTO와 Binding에서 제거했으며 생성·요청·echo하지 않는다. 실제 sender는 미구현이다.
- `Result`는 outcome·operationId·deviceId·bindingSha256·invoked·effectConfirmed 여섯 필드와 선택 reason을 받는다. bindingSha256 키는 필수지만 비교 전 거절의 JSON null을 허용한다. outcome이나 nullable 키 자체의 생략, 통화 started ACK를 허용하지 않는다. `effectConfirmed=true`는 유효한 shortcut 결과로 수용하지 않는다.
- null 또는 다른 반환 hash 때문에 요청·기기·현재 scope가 맞는 응답 전체를 폐기하지 않는다. 거절·unknown과 raw hash를 보존하며, hash가 맞지 않는 invoked도 실제 실행 성공으로 표시하지 않는다.
- `unknown + invoked=false/true` 양쪽을 그대로 보존한다. journal 기록이나 executor 인계를 실제 executor 실행·통화 효과로 승격하지 않는다. 자동 재토글은 없고 사용자의 새 500ms 동작만 새 operationId를 만들 수 있다.
- assignment SHA는 호스트가 광고한 불투명 값이다. Core의 실제 KeyAssignment 다섯 필드(id/inputID/trigger/requiredModifiers/action) hash를 Vision에서 재계산하지 않는다. 축약 세 필드 hash, 소문자 정규화, 별도 canonicalizer는 없다. profile UUID와 opaque assignment SHA만 기기·기존 scope/selection revision에 결속한다. settings SHA 필수 조건은 제거했다.

## 최소 상태와 선택 보존

`VisionConfiguredCraftAction`은 순수 값 상태다. `idle → preparing → ready → awaiting → completed/unknown`과 취소만 관리하며 통화 세션·오디오 엔진·타이머·네트워크를 소유하지 않는다.

한 operation의 client fence는 인증된 host, 기존 connection/window/admission/video/foreground, deviceId·profile UUID·assignment SHA, local route generation과 선택 revision을 고정한다. Host는 자신의 현재 ForwardingClient.generation을 서버 내부에서 별도로 확인한다. 클라이언트가 Host session을 광고받거나 echo하는 조건은 없다. `takeInvocation`은 실제 sender 직전 다시 확인해야 하는 단일 소비 지점이다. 같은 후보를 두 번 소비할 수 없다. 준비 8초·응답 10초 기한이 끝나면 같은 operation의 취소/unknown이 되며 poll은 새 명령이나 ID를 만들지 않는다.

사용자가 저장한 `VisionRemoteAudioIntent.Desire`와 기존 방향별 revision을 읽는 getter를 재사용한다. 명시 선택이 없을 때만 기본 양방향을 준비하도록 요청한다. 명시된 각 OFF는 그대로 유지한다. 기존 Mac 장치 선택 요청 이력이 있으면 Vision 양방향을 기본 ON으로 강제하지 않고 그 장치 목록 revision을 결속한다. 장치 controller에는 기존 선택 카운터의 읽기 전용 getter만 추가했다.

fresh `providerCallSnapshot`의 방향이 선택과 같아야 한다. 선택된 ON은 기존 입출력 준비 상태를, OFF는 정리된 로컬 상태와 현재 원장의 OFF 방향을 확인한다. 양쪽 OFF도 현재 `.off` snapshot이 확인되면 허용하며 configured toggle에 native activeCall을 요구하지 않는다. 새 shortcut과 기존 통화 원장은 분리하고, 기존 activeCall이 남아 있는 경우의 명시적 종료 경로는 보존했다.

준비를 실제 수행할 adapter는 자신이 만든 방향 revision을 `recordPreparedSelection`에 연결해야 한다. 이 메서드는 요청 ID·동일 fence·현재 선택·정확 revision만 수용하고 요청 ID와 기한을 바꾸지 않는다. 준비 중 새 사용자 OFF·장치 선택·창/연결 변화가 오면 취소한다. 정리 directive에는 해당 operation의 선택/fence/revision이 들어 있으며 새 사용자 의도를 덮는 전역 초기화는 허용하지 않는다.

## 현재 연결되지 않은 부분

UI `configuredContext`는 기존 인증·입출력·선택 readback만 읽고, descriptor binding과 route generation은 nil, capability와 route 구현 표시는 false로 남는다. 따라서 현재 주 버튼은 실행 불가이며 operation 발급·새 미디어 준비·전송이 모두 0이다. 짧은 Button 동작은 비어 있고 longPress gesture만 연결했다.

`prepare/invoke/cancelPreparation`은 순수 상태의 directive다. 현재 UI에는 이를 실행하는 adapter가 없으며 실제 준비/취소/전송이 연결됐다고 주장하지 않는다. Core는 기존 COMMAND_SOCKET의 `configured-craft-action.catalog/.invoke` adapter를 소유하고 Node를 추가 경유하지 않는다. Host는 TLS peer·서버 session·audio freshness 외피를 소유한다. 아직 UI sender 번호와 Host TLS Catalog result envelope는 미정이다. 정확 handoff 뒤에만 다음을 연결한다.

1. 광고 binding/지원 상태를 해당 현재 문맥에 넣는다.
2. 선택을 보존하는 기존 미디어 준비와 operation별 revision 영수증을 연결한다.
3. await 경계와 실제 sender 직전에 fence를 재검사하고 `takeInvocation`을 단 한 번 소비한다.
4. 취소·timeout의 해당 준비 자원만 정리하고 새 사용자 선택을 보존한다.
5. Core 결과는 invoked/rejected/unknown으로만 표시한다. timeout/unknown을 자동 재전송하지 않는다.

## 실행 근거

Pstack Feature/how/TDD와 Ponytail full로 기존 구조를 재사용했다. ARENA·새 순정 Goal·추가 모델 분할은 실행하지 않았다. Root의 독립 검수는 별도다.

- 수정 전 새 검사는 `FAIL 음성 주 동작에 500ms longPress가 없습니다. 짧은 누름과 통화 ACK 경로가 남아 있습니다.`로 실패했다.
- `e6c41e` 준비 모델은 Mini 순수 검사 146개와 제한 xros `[0,0,0]`이 통과했다. 이후 실제 앱 소스 96개·StreamProtocol 26개를 사용하는 stub 대체 0의 전체 Release xros 빌드 1834가 성공했다. 원본 775개 전후 manifest·commit/tree 메타데이터 일치, CodeSign·설치·실행·기기 조작 0이다.
- 후속 nullable 검사는 먼저 `FAIL 비교 전 거절의 필수 nullable bindingSha256를 보존함`으로 실패했다. 확정 client9/Catalog6·nullable/result 수정 후 Mini 순수 검사 186개가 통과했다. 양쪽 unknown, null/다른 hash 보존, 정확 9필드·epoch-ms 정수, Catalog 필수성, 기존 선택·취소·세대 검사를 포함한다. source 불변·scratch 제거·Mini 정리 true, 실제 Host/Core/기기/오디오/입력 효과 0이다.
- e6 준비 모델의 최초 Mini SSH 시도는 exit 255였고 cleanup은 true였다. 저비용 접속 확인 후 같은 owner/job으로 재시도했다. 실패 영수증을 덮지 않고 보존했다. 사용자 선택 정정 뒤 e6 모델 검사 146개가 통과했고, 후속 코덱 검사는 별도 186개다.
- 기존 `vision-simple-call-controls/run.py --static-only`의 구조 검사 5개가 통과했다.
- Xcode 일반·release-test 두 source phase와 생성기의 파일 등록은 유지한다. 후속 코덱 정정은 Mini production 모델 실행과 xros 구문 검사 범위이며 전체 앱 빌드 1834에 포함되지 않는다. 후속 소스의 전체 앱 빌드·서명·설치·실기 입력은 미실행이다.

세대별 근거 폴더는 `vision-configured-craft-action-20261106`(e6c 준비 모델), `vision-configured-craft-full-build-20261106`(e6c 전체 빌드 1834와 audit 보존), `vision-craft-catalog-delta-20261106`(후속 코덱)이며 모두 `/Volumes/BT-Workspace/Development-Archives/CCR-Vision` 아래다. 각 `handoff.json`의 commit/tree·파일 SHA·검사 범위를 사용한다. 제품 연결·실제 명령 효과·가청 입출력은 미검증이다. CUA 안전 거절을 우회하지 않으며 최종 실제 버튼 동작은 사용자 직접 행동으로 남긴다. Root/Host/Core/기기/키/권한/원장 쓰기는 0이다.
