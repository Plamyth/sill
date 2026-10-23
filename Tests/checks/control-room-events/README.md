# iOS 관제 이벤트 Foundation 검사

원담당은 `01a13ace-e372-7ed1-9946-149df37ee1c3`이며 기준 후보는 `4f1c566`입니다. 기존 `ControlRoomProjection.swift` 전체와 `CanvasModel.swift`의 실제 `VoiceSession` 선언을 검증용 입력으로 추출합니다. Swift 앱 소스나 프로젝트 파일을 생성하지 않습니다.

```sh
python3 Tests/checks/control-room-events/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/ios-native-events-validation-20261023
```

출력 경로는 `storage-route`가 확인한 개발 보관 경로 안이어야 합니다. 순수 Foundation 컴파일·실행은 `mini-ephemeral-source`의 원담당·고정 작업 키를 사용합니다. 반환 로그에 종료 코드와 Mini 임시 사본의 `cleanup_verified` 영수증이 포함됩니다. 이 검사는 Git 체크아웃 이전이나 실기기 수용을 증명하지 않습니다.

`fixture.json`은 relay 통합 후보의 `relay/vendor/control-events/control-events-v1.json`과 같은 바이트입니다. 원본 공통 계약은 commit `f94f712e5c337a6415af2d33490aa6db285f9d2f`이며 fixture SHA-256은 `a026a9f697a88ebe2838e02c24b980774572683e35189962f4900eb059609454`입니다.

검사는 snapshot·patch·heartbeat, 세대·순서·중복·누락, 필드 제거, legacy 디코딩, 초기 unavailable, 원본 관측 시각과 30초 신선도, 4,002개 카드와 마지막 Cursor 두 카드, UTF-8·LF·CRLF·CR 프레임과 본문·전체 크기 제한을 확인합니다. URLProtocol 합성 전송으로 재연결 cursor, 오류, 미지원 응답, 취소, 최신 한 개 버퍼, 정책 삭제 뒤 단절 시 카드 비노출을 확인합니다. 연결 세대의 소유권도 검사합니다. 실제 HTTP 서버·UDS·앱·기기·오디오·키·모델·메시지를 사용하지 않습니다.

앱 빌드와 독립 검수는 별도 영수증입니다. UI 표시·OS 인증서 검증의 실제 연결·설치 앱과 실제 기기의 수용은 이 Foundation 검사로 주장하지 않습니다.

## 소스·세션 조회 선택

작업 키는 `ipad-source-sessions-20261023`, 전용 브랜치는 `codex/ipad-source-sessions-20261023`, 기준 커밋은 `cedd0c526a21b67764de4471211e75de8bc8200f`입니다. 앱 변경은 `ControlRoomProjection.swift`와 `ControlRoomViews.swift`에만 있습니다. 공통 iPad·phone 뷰의 기존 3×3 안에 접을 수 있는 `소스·세션` 패널을 추가합니다.

패널은 relay projection root의 optional `unifiedControl: {schema:1,rows,truncated,error}`와 `sourceConnections`만 디코딩합니다. 비공개 payload, `items`, `sessions`, private binding을 해석하거나 합성하지 않습니다. 소스 요약, 개별 Codex 연결과 행 capability는 별도 정보입니다. 원본 `status`, `executionStatus`, `agentStatus`, 연결 상태와 관측 시각도 별도로 표시합니다. 모든 선택은 조회용이며 명령·전송 API가 없습니다.

선택 식별자는 `(source,key,externalId,sessionId,runId,hostId,instanceId,startedAt,workspaceIdentity,ownerThreadId)`입니다. 제목으로 병합하지 않습니다. 소스 전환은 남아 있는 해당 소스의 선택만 보존합니다. 사라지거나 식별자가 바뀐 선택과 중복된 복합 식별자는 제거하며, 이전 식별자가 다시 나타나도 자동 선택하지 않습니다. 원본 owner는 보존하고 `ownerVerified`와 함께 표시합니다.

`android-mobile-control-events-v1.json`은 Android 저장소 commit `e5f931657dba5b2d3d4c04b547a7a17da3ac660b`의 `tests/fixtures/mobile-control-events-v1.json`과 정확히 같은 28,543바이트입니다. SHA-256은 `9fb6288d6ac3d68f4d743d8703b091f263664d239248b53e6ba82d8cb554b319`이며 출처는 `android-fixture-provenance.json`에 기록합니다. 기준 DTO 함수는 같은 커밋 `server/mobile-control.js`의 `projectControl`과 `codexSourceState`입니다. Vision `bf7f7ef`의 전용 모델과 projection은 참고만 했으며 가져오지 않았습니다.

Android fixture의 모바일 snapshot은 iPad relay의 SSE root가 아닙니다. `SourceSessions.swift`는 해당 fixture의 허용 DTO 필드만 합성 relay root에 넣어 검사합니다. 기존 `fixture.json`의 공통 reducer 계약 검사와 구분합니다. `threads`와 `catalog`의 빈 배열을 요구하는 relay strict 계약은 유지합니다.

```sh
python3 Tests/checks/control-room-events/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/ios-source-sessions-20261023/validation
```

Pstack Feature 적용에서는 기존 reducer에서 projection 디코딩을 거쳐 공통 `ControlRoomGrid`로 표시되는 흐름을 확인하고, typed DTO·복합 식별자·소스별 선택 모델을 먼저 정했습니다. Ponytail은 기존 parser, reducer, Foundation 실행 도구와 SwiftUI menu·scroll을 재사용했습니다.

- 선행 조건은 전용 워크트리의 기준 커밋·clean 상태, exact DTO, 외장 저장 경로 확인입니다.
- 독립 작업은 Mini의 Foundation 검사와 맥북 Apple SDK 컴파일이며, 각 출력 경로를 분리합니다.
- 공유 쓰기는 이 워크트리의 단일 작성자에게만 허용합니다. 설치·실물 UI·실서비스·호스트·음성·키 변경과 push는 수행하지 않습니다.
- 가장 작은 분해는 두 앱 파일과 기존 검사 확장을 한 작성자가 처리하는 것입니다. ARENA와 하위 에이전트는 사용자 지시에 따라 사용하지 않습니다.

검증은 4,000개 Codex 뒤 Cursor 두 행, 같은 제목과 ID의 교차 provider, 모든 복합 식별자 변경, 개별 연결 결박·오래된 관측, summary 권한으로 행 권한을 올리지 않는 조건, 필드 제거와 unavailable, 소스 전환 선택 보존을 포함합니다. 순수 Foundation은 기존 ephemeral 도구의 원담당 `01a13ace-e372-7ed1-9946-149df37ee1c3`, 고정 작업 키 `ipad-source-sessions-foundation`을 사용하고 `cleanup_verified`를 확인합니다.

Apple SDK 검증은 전용 `validation/DerivedData`에서 `Sill`과 `SillPhone`을 `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`로 빌드합니다. 공개 bootstrap profile의 SHA-256 `7bcf8ce74bf4292d1a20b07d45bfa0c040957e1ade3d80dd4be37c5eb96cf8c7`을 대조합니다. 설치·실물 화면·현재 relay runtime 수용과 독립 검수는 이 검사에 포함하지 않습니다. relay allowlist 반영과 독립 검수는 부모 담당입니다.

부모 relay의 숨김 보정은 exact Android fixture를 바꾸지 않습니다. 별도 합성 검사에서 숨긴 session·owner·run을 참조하는 provider 요약의 `unavailable`, null 식별자·관측값, 읽기 전용과 거부 capability, 일반 한국어 안내를 그대로 수용합니다. 행 제거는 선택을 해제하며 provider 요약을 남은 행의 연결·권한과 섞지 않습니다.

이번 후보의 Mini Foundation 검사는 종료 코드 0이며 임시 사본 삭제 확인도 통과했습니다. `Sill`과 `SillPhone`의 generic iOS 무서명 빌드도 각각 종료 코드 0입니다. 증거는 전용 `validation` 폴더의 `foundation.log`, `foundation-result.json`, `Sill-generic-ios-result.json`, `SillPhone-generic-ios-result.json`에 있습니다. 실기기 UI와 실제 relay 연결은 미검증이며 설치는 0회입니다. 독립 검수는 부모 담당이 수행합니다.

## Cloud 현재 응답과 공개 보호 fixture

작업 키는 `ipad-public-source-result-20261023`, 브랜치는 `codex/ipad-public-source-result-20261023`, 기준은 `1db9057682c8f47c12f1de1cfcc0356aa0fcafa2`입니다. Pstack Feature와 Model the Domain으로 기존 optional DTO·복합 ID·선택 모델에 기능을 배치했습니다. Ponytail full로 기존 reducer와 패널을 재사용했습니다. 추가 에이전트와 ARENA를 사용하지 않으며 독립 검수는 부모 담당의 후속 작업입니다.

`ControlRoomSourceSession.result`는 optional 문자열입니다. `ControlRoomSourceSelection.currentResult`는 현재 선택된 Cloud 행의 `capabilities.read == true`, 정확한 복합 ID, 같은 external/session ID와 비어 있지 않은 run ID, 행 `fresh/stale`, projection 최신성, UTF-8 12,000바이트 한도를 확인합니다. 행 관측 시각이 제공되면 그 시각도 확인합니다. producer가 정상 공개 행에 관측 시각 null을 반환할 수 있으므로 이 경우 최신 projection을 사용합니다. owner 확인·전송 권한·source summary는 읽기 권한을 대신하지 않습니다.

응답은 매 projection에서 전체 교체합니다. null·필드 제거는 미제공, 빈 문자열은 빈 응답입니다. 별도 본문 캐시와 history/messages 호출이 없습니다. UI는 한국어 안내와 `Text(verbatim:)`으로 표시합니다. Codex와 Cursor 로컬 본문은 미지원입니다. stale·disconnect·잘못된 프레임은 기존 projection 연결 상태로 이전 응답의 현재 표시를 차단합니다.

`public-fixtures.json`은 제공받은 public-only 6case 파일의 정확한 복사본입니다. producer는 Android commit `9a91483f5e054ad8f30e9a1d43d8e7fd91740c6a`, tree `4f7581661680f466a363ad7199ae1db54874163e`입니다. SHA-256은 `e40d4eaaf634854ff62612bf8c4fad2d33248c2aabf2b93213275713ce4da1fc`이며 `public-fixture-provenance.json`으로 확인합니다. raw 원본은 복사하지 않습니다. producer의 `server/mobile-control.js` 150~179행을 읽었으며 private binding reader를 실행하지 않았습니다.

`PublicResults.swift`는 정상 Cloud와 Codex child를 선택한 뒤 hidden ancestor, unverified child, missing target, retained placeholder, duplicate root로 전환합니다. 목록·선택·본문·관련 summary 제거, 공개 형제 유지와 정상 복귀 후 자동 재선택 금지를 snapshot과 patch 양쪽에서 검사합니다. provider·key·external/session/run 변경, read 취소, same-ID 응답 교체, null·empty, UTF-8 한도, malformed result, URLProtocol 격리 invalidframe·disconnect를 검사합니다.

native fixture의 top-level `slots`와 relay `currentGrid`는 서로 다른 계약입니다. native placeholder identity는 JSON에서 직접 확인합니다. source DTO 두 필드만 합성 relay envelope에 넣어 기존 strict reducer로 소비합니다. 이 검사는 실제 relay projection 변환·배포·서비스 연결의 end-to-end 수용이 아닙니다. 부모가 `relay-normalized-before.json`에서 확인한 relay 후보의 result 누락·보호 행 잔류도 이 합성 통과로 해결됐다고 판단하지 않습니다. 실제 relay 공개 프레임 검증은 부모의 별도 relay 수정 결과를 사용해야 합니다.

```sh
python3 Tests/checks/control-room-events/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/public-source-result-validation-20261023/foundation
python3 Tests/checks/control-room-events/sdk.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/public-source-result-validation-20261023/sdk
```

Foundation은 공개 fixture와 필요한 순수 Swift 선언만 `mini-ephemeral-source`의 원담당·고정 작업 키로 전송합니다. `foundation-result.json`은 입력별 전후 해시, 실행 영수증과 `cleanupVerified`를 기록합니다. SDK 검사는 기존 `linked-obsidian-notes/run.py`의 iOS 소스 목록과 타입 검사 명령을 재사용합니다. 앱 빌드·서명·설치를 생성하지 않습니다. 이번 실행은 Foundation 종료 코드 0, Mini 삭제 확인 true, iOS SDK 두 단계 종료 코드 `[0, 0]`입니다. 실제 서비스·기기 수용과 독립 검수는 별도입니다.
