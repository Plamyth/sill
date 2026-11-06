# iPad 공통 Craft 사용자 동작 소비 모델

기준은 clean `5728401b7ff0139eaa08376bb6e1197030b6d3c1`, 브랜치는 `codex/ipad-configured-craft-action-20261106`이다. 이 작업의 단일 writer는 위임받은 모델 작성자이며 부모가 Host245 독립 준비·Core 계약·독립 검수·통합을 소유한다. 제품88/source7c, 제품 UI, StreamProtocol, Host, registry, 기기, 네트워크, 설치, 키, 권한은 변경하지 않는다.

## 계약과 사용

`IPadConfiguredCraftAction`은 Foundation만 사용한다. `bind(context)` 후 인증된 현재 연결의 catalog와 endpoint 지원 여부, 사용자 의도에 따른 입출력 readiness를 `observe`에 전달한다. 첫 명시 동작에서 장치 선택이 미확정일 때만 기본 iPad 입출력을 준비하고, 이후 사용자의 OFF와 선택 장치는 보존한다. 이 준비는 부모의 후속 연동 소유다.

`inputReady`/`outputReady`는 선택한 의도와 fresh readback이 일치한다는 뜻이다. ON이면 active, 명시 OFF이면 실제 OFF가 관측되어야 한다. 두 경로의 active를 강제하지 않는다. mute/off를 unready로 바꿔 STOP 길게 누르기를 막지 않도록 선택 상태와 readiness를 구분한다. 회귀의 `activate(input:output:)`도 이 일치 여부만 주입하며 ON/OFF 자체를 의미하지 않는다. 이 모델은 통화 상태 판별이나 종료 보장을 하지 않는다.

endpoint 지원 기본값은 false다. `begin`에는 같은 context/catalog, 별도 명시적 길게 누르기의 `userActionID`, 관측한 500ms 이상 누르기, epoch 밀리초 정수 `issuedAt`를 전달한다. 모델이 반환하는 `Request`만 향후 어댑터의 전송 대상이며 현재 전송 경로는 없다. 호출자는 한 물리 사용자 동작에 하나의 userActionID를 부여하고 같은 모델 인스턴스를 유지해야 한다. 모델 자체는 UIKit 입력이나 인증 사실을 관측하지 않는다.

요청의 정확한 9필드는 `schemaVersion`, `operation`, `operationId`, `deviceId`, `inputID`, `trigger`, `expectedProfileId`, `expectedAssignmentSha256`, `issuedAt`다. 값은 schemaVersion 1, operation `invoke-configured-craft-action`, inputID `speed.button.stop-play`, trigger `longPress`다. UUID profileID와 lower64hex assignment hash는 서버 catalog 식별값 그대로다. `issuedAt`는 0 이상 JavaScript 안전 정수 범위의 number다. 클라이언트 payload에는 `deviceSessionId`가 없다. Host가 인증된 현재 TLS peer의 서버 session에서 채우며 클라이언트가 권한을 합성하지 않는다.

아래는 main.swift가 실제 Request Codable로 읽는 독립 합의 fixture다. 실제 begin 인코딩 결과에서 매번 달라지는 operationId와 fixture catalog의 profileId만 정규화해 아래 9필드 객체와 직접 비교했다. 이전 `issuedAtUTC` key는 추가 key 반례로 거절한다. 아래 값은 격리 검사 식별값이며 설치 Craft profile이나 실제 장치 식별값이 아니다.

```json
{
  "schemaVersion": 1,
  "operation": "invoke-configured-craft-action",
  "operationId": "11111111-2222-3333-4444-555555555555",
  "deviceId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "inputID": "speed.button.stop-play",
  "trigger": "longPress",
  "expectedProfileId": "66666666-7777-8888-9999-000000000000",
  "expectedAssignmentSha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "issuedAt": 1794000000123
}
```

2026-11-06 후속 확정에 따라 Core fingerprint는 실제 KeyAssignment의 전체 5필드 `{id,inputID,trigger,requiredModifiers,action}`를 `.sortedKeys` JSONEncoder로 인코딩한 UTF-8 바이트의 SHA256이다. profileId와 settings 전체 hash는 별도 descriptor다. 이 모델은 assignment 원문·키·modifier를 받거나 생성하지 않으며 fingerprint를 계산하지 않는다.

응답의 필수 6필드는 `outcome`, `operationId`, `deviceId`, `bindingSha256`, `invoked`, `effectConfirmed`다. 선택 `reason`은 공백만으로 구성되지 않은 최대 UTF-8 256바이트 문자열로 제한한다. 누락·추가 key, 잘못된 타입/UUID/64hex, `effectConfirmed:true`를 실제 JSONDecoder에서 거절한다. nil hash는 JSON null로 명시되어야 한다. invoked는 true와 예상 hash 일치가 필요하다. rejected는 false이고 비교 전 null 또는 실제 다른 hash가 가능하다. unknown은 true/false와 null hash를 모두 허용하고, nonnull hash는 원 요청과 대조한다.

`unknown + invoked:true`는 검증된 저장 action을 ActionExecutor에 정확히 한 번 넘겼지만 후속 결과 관측/응답이 불명확하다는 Core 확정 사실을 그대로 보존한다. false는 호출 전 실패다. 두 경우 모두 effectConfirmed는 false이며 통화 시작·종료·가청 입출력 성공을 의미하지 않는다. 클라이언트의 local timeout은 executor 호출 여부를 모르므로 wire 응답을 꾸미지 않고 `Resolution.invoked == nil`인 unknown으로 남긴다.

상태는 idle, pending, resolved다. pending 중 새 UUID 생성과 중복 begin은 없고 같은 userActionID는 한 번만 소비한다. known invoked/rejected 이후에는 별도 명시 사용자 행동으로 새 operation이 가능하다. unknown은 timeout·disconnect·bind·인증 복귀 뒤에도 원 operation과 결과를 보존하고 신규 begin을 차단한다. pending 중 context/catalog/capability가 폐기되어도 원 operation은 unknown으로 남는다. bind는 같은 connection UUID여도 admission을 폐기하고 이전 응답을 거절한다. 모델의 단조 시계 기한은 10초이며 잘못된 시계도 unknown으로 닫는다.

operationID 지속과 서버 dedupe는 서버 어댑터 소유다. 이 모델에는 자동 재시도, executor, 네트워크, query protocol 또는 unknown 초기화 API가 없다. unknown 이후 허용될 후속 조회는 원 operationID에 한정되며, 미확정 조회 wire를 새로 만들지 않았다. 앱 재시작 durable 저장, 실제 transport/capability catalog 연결, 인증 복귀, 서버 영수증 조회·조정과 실제 길게 누르기 UI 연결은 부모의 후속 범위다. 앱 재시작으로 새 모델을 만들어 unknown을 우회하는 통합은 허용하지 않는다.

기존 `IPadProviderCall`의 connection·pending·단조시계 대조 패턴을 재사용했다. 해당 모델의 재연결 초기화나 자동 query는 가져오지 않았다. 장치 ID는 `IPadEnrollmentProtocol.hex64`의 ASCII 검증식을 재사용하되 crypto/StreamProtocol 의존을 끌어오지 않도록 이 파일 안에 둔다.

## 실행과 근거

```sh
python3 -B Tests/checks/ipad-configured-craft-action/run.py
```

표준 swiftc 한 번에 production 모델 파일과 main.swift를 직접 컴파일한다. compiler 예산은 180초, 검사 실행 예산은 10초다. 실제 Codable와 모델 메서드에 독립 wire 반례를 넣는다. 모듈 캐시·실행파일은 자기 TemporaryDirectory에만 만들고 성공·실패 뒤 정리한다. 입력 7파일의 전후 SHA256과 자기 scratch 부재를 확인한다. SDK 앱 빌드·실기·음성 성공 검사가 아니다.

Pstack Feature 작성 역할과 Ponytail full을 적용했다. `how`에서 기존 모델/장치 검증을 읽고 Model the Domain에 따라 상태 enum과 context/catalog를 골랐다. ARENA·순정 Goal·추가 하위 agent·네트워크는 사용하지 않는다. 사용자 후속 지시에 따라 추가 설계 탐색 없이 이 범위를 직접 구현했다. 독립 비작성 검수는 부모에게 남긴다.

- 선행 차단: clean 기준·소유 범위·확정 Core 계약·기존 패턴 확인을 마쳤다.
- 독립 작업: 부모의 Host/Core 준비와 이 모델을 병렬 진행한다. 이 범위 안은 모델과 검사가 결합되어 한 writer가 수행한다.
- 공유 쓰기: 제품·Host·기기·registry 쓰기는 0이다. project.pbxproj에는 새 소스 등록만 한다.
- 최소 분해: production 1파일, 검사 main/run/README와 소스 등록으로 제한한다. push/PR/통합·SDK 빌드·설치는 부모 소유다.

2026-11-06 정정된 `issuedAt` 모델과 독립 fixture에서 179개 검사가 통과했다. `INPUT_SOURCES_UNCHANGED=true; SCRATCH_REMOVED=true`, project.pbxproj의 `plutil -lint`도 통과했다. 최종 실행 중 입력 7파일의 SHA256은 불변이었다. 그 뒤 README에만 최신 readiness 설명·fixture·이 결과를 기록했고, 실행 코드와 검사 코드는 바꾸지 않았다. 첫 컴파일은 issuedAt key 정정 때문에 자기 프로세스만 종료했고 scratch 정리를 확인했다. 정정본은 180초 compiler 예산 내 한 번 컴파일해 통과했으며 동일 suite를 재실행하지 않았다.

검사 표면은 standalone Foundation 모델이며 iOS SDK 앱 빌드가 아니다. 부모의 독립 검수·통합·제품 빌드·설치·실기 수용은 이 결과에 포함하지 않는다. 최종 commit/tree/clean은 부모에게 반환한다.

## iPad 공통 Craft catalog 소비

`iOSClient/IPadConfiguredCraftAction.swift`의 `encodeCatalogRequest()`는
`{"schemaVersion":1,"operation":"get-configured-craft-action"}`의 정확한 2필드만 인코딩한다.
`Catalog(context:data:)`는 typed DTO와 `JSONDecoder`로 응답을 읽고 기존 Catalog 검증을 적용한다.
응답은 `schemaVersion:1`, `supported:true`, UUID `expectedProfileId`,
`inputID:"speed.button.stop-play"`, `trigger:"longPress"`, lower64hex
`expectedAssignmentSha256`의 정확한 6필드다. UUID 문자열은 소문자도 허용한다.
누락·추가 key, null, 잘못된 타입·값을 거절한다. action·key·modifier·session·host identity는 wire에 없다.
`supported:false`와 오류 응답의 미확정 wire를 새로 정의하지 않는다.

`observeCatalog(_:from:authenticated:endpointSupported:inputReady:outputReady:)`는
현재 context와 외부에서 확인한 인증·endpoint 지원 여부를 받아 기존 `observe`로 연결한다.
endpoint 지원 기본값은 false이며 파싱 성공으로 지원이나 인증을 합성하지 않는다.
다른 connection·host·device의 관측은 현재 상태를 바꾸지 않는다.
현재 context의 malformed·미인증·미지원 catalog는 이전 admission을 폐기하고 pending을 unknown으로 닫는다.
정상 catalog가 복귀해도 unknown을 초기화하거나 재호출하지 않는다.
readiness는 선택한 mic·speaker 의도와 fresh 관측의 일치 여부다. 사용자 명시 OFF도 실제 OFF 관측과 일치하면 ready다.
관측은 전송·operation을 생성하지 않으며 별도의 명시적 500ms 길게 누르기만 기존 `begin`으로 이어진다.

`python3 -B Tests/checks/ipad-configured-craft-action/run.py`는 기존 179검사에 codec과
부정 catalog의 admission 폐기·잘못된 세대의 상태 보존 반례를 더해 production 모델을 직접 컴파일한다.
기존 180초 compiler 예산·10초 검사 예산·입력 소스 불변·scratch 정리를 유지한다.
이 단위는 모델·검사·이 문서만 변경한다. Host·StreamProtocol·UI·endpoint·socket·기기·키·설치·네트워크·registry와
앱 재시작 durable 복구는 연결하지 않는다. 실제 producer bytes 교차검증·SDK 검사·독립 검수·통합은 부모 담당이다.

이 추가 단위의 기준은 `28327ba8278708865f38448fa59982dfd50c833b`, 소유 브랜치는
`codex/ipad-craft-catalog-20261106`이다. Pstack Feature 작성 역할과 Ponytail 기존 모델 재사용을 적용했다.
부모가 Core 조율·SDK 검사·독립 검수·통합을 병렬 진행하고 이 writer는 소유 세 파일만 수정한다.
추가 설계 탐색·ARENA·순정 Goal·추가 agent와 push는 실행하지 않는다.
2026-11-06T03:19:18Z 확인 시 309검사가 통과했고 `INPUT_SOURCES_UNCHANGED=true; SCRATCH_REMOVED=true`였다.
기존 179검사 본문과 run.py는 그대로다. 그 뒤 root README의 본인 추가분만 이 문서로 옮겼으며 모델·검사 코드는 바꾸지 않았다.
