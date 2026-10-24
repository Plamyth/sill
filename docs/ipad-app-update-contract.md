# CCR iPad 앱 내 공식 업데이트 계약

Core 원담당이 수용한 최소 클라이언트 계약이다. 실제 승인 피드·공개 키·App Store Connect 레코드·배포 그룹·초대·가용 빌드는 아직 연결하지 않았다. 현재 기본 상태는 **배포채널 준비중**이다. 발행자·배포 서비스·키 생성·업로드는 이 변경에 포함하지 않는다. Android와 `/v1/update`는 변경하지 않는다.

## 앱에 고정하는 구성

서명된 앱의 Info.plist에 선택적으로 넣는 `CCRUpdateFeedURL`과 `CCRUpdatePublicKey`만 신뢰한다. 기본값은 없다. 피드는 HTTPS이며 유효한 명시 포트를 허용한다. 키는 base64로 표현한 32바이트 Ed25519 공개 키다. 사용자 입력·UserDefaults·호스트 연결·최초 접속 결과를 신뢰 구성으로 승격하지 않는다.

## 공통 fetch 계약 `ccr-apple-release-fetch-v1`

호환 진입점은 기존 원형과 익명 GET 동작을 유지한다. iPad 앱의 기본 호출은 아래 명시 인증 진입점에 `authenticatedRequest: nil`을 전달한다.

```swift
static func fetch(_ configuration: IPadAppUpdateConfiguration,
                  sessionConfiguration: URLSessionConfiguration = .ephemeral) async throws -> Data
static func fetch(_ configuration: IPadAppUpdateConfiguration, authenticatedRequest: URLRequest?,
                  sessionConfiguration: URLSessionConfiguration = .ephemeral) async throws -> Data
```

명시 요청이 nil이거나 아래 조건을 만족하지 않으면 네트워크 전에 `authentication` 오류를 반환한다.

- 요청 URL은 앱에 고정한 `configuration.feedURL`과 정확히 같다. 기존 HTTPS·credential·fragment 거부 규칙을 유지한다.
- 피드 URL의 원래 `percentEncodedPath`는 `/v1/releases/latest`, 원래 `percentEncodedQuery`는 `platform=ipadOS`와 정확히 같다. `IPadAppUpdatePolicy.platform`을 경로 검증과 서명 identity 검증에 함께 사용한다. 인코딩 별칭·중복 쿼리·URL 토큰·다른 경로를 거부한다.
- method는 정확히 `GET`, body와 body stream은 nil이며 `httpShouldHandleCookies`는 false다. 대소문자와 관계없이 `Cookie` 헤더가 있으면 거부한다.
- 명시 `Authorization` 헤더 하나에 정확히 `Bearer `와 64자리 소문자 16진수 토큰이 있다. 토큰은 서버의 32바이트 hex 계약이다. 공백·개행·다른 scheme·관측 가능한 중복 Authorization과 결합된 값을 거부한다. Foundation은 dictionary에 대소문자만 다른 키를 지정하면 함수 진입 전에 한 키로 축약한다. 이때 사라진 중복 원본은 공통 API에서 판별할 수 없다. adapter는 정규 헤더 하나를 만들며 `addValue`로 결합된 중복은 거부한다.

검증 뒤 새 GET 요청을 만들고 검증한 Authorization 하나만 복사한다. 관계없는 명시 헤더와 session의 `httpAdditionalHeaders`는 전달하지 않는다. 호환 진입점도 전역 인증을 전용하지 않는다. private 공통 실행 helper에서 두 진입점의 HTTP 바이트 읽기를 공유한다.

session 구성은 복사한 뒤 쿠키·URLCredentialStorage·캐시·전역 헤더를 제거한다. 실제 `timeoutIntervalForRequest=15`, `timeoutIntervalForResource=30`, 요청 timeout 15초를 고정한다. SSE용 86,400초 구성을 빌려도 이 한도를 유지하며 호출자의 구성은 변경하지 않는다. 모든 HTTP 리다이렉트와 TLS 서버 신뢰 외의 인증 challenge를 거부하고 최종 응답 URL이 피드와 다르면 거부한다. 503 본문은 최대 32,768바이트까지 읽은 뒤 분류하며 초과 스트림은 실패한다.

`401`과 `403`은 최종 응답 URL을 확인한 직후 본문 길이 검사·버퍼링 전에 `authentication` 오류로 반환한다. 큰 본문이나 끝나지 않는 본문도 인증 오류를 가리지 않는다. `503`의 schema는 CFBoolean과 부동소수 표현을 표준 CoreFoundation API로 거부한다. `1`만 수용하며 Bool·`1.0`·`1e0`·`2`·누락은 실패다. `503`은 정확히 아래 네 필드가 맞을 때만 `unconfigured`로 처리한다. 다른 키·대소문자·플랫폼·schema·추가 필드와 다른 HTTP 오류는 실패다.

```json
{"schemaVersion":1,"status":"notConfigured","code":"release_not_configured","platform":"ipadOS"}
```

이 응답은 배포채널 준비중 안내와 재시도를 허용한다. 최신·설치 확인·pending 저장·Apple URL 열기의 근거가 아니다. `200`으로 온 unsigned `notConfigured`는 서명 봉투 검증에서 계속 실패한다. 성공 `200`은 원문 Data를 그대로 반환하고 기존 policy가 원 payload 서명을 검증한다. Apple 설치 URL은 앱에서 다운로드하거나 리다이렉트를 따라가지 않고 OS에 전달한다.

현재 실제 피드 URL과 공개 키는 nil이다. iPad에는 HTTP Bearer 등록 저장소·수신 경로가 없으므로 기본 명시 요청도 nil이며 네트워크 0으로 차단한다. 앱 구성 자체가 nil이면 기존 `unconfigured` 상태를 유지한다. Sill TLS DeviceIdentity, SavedMac, Canvas의 `X-Canvas-Token`을 전용하지 않으며 새 token 저장소·Keychain 항목·입력 화면을 만들지 않는다. Vision의 기존 Keychain과 gateway 같은 origin 승인 adapter는 별도 원담당이 구현하며 이 워크트리에는 Vision 분기를 추가하지 않는다.

## 서명 봉투와 payload

봉투는 JSON 객체 `{"payload":"base64(raw UTF-8 JSON)","signature":"base64(Ed25519 signature)"}`다. 서버는 상위 `keyID` 진단 필드를 추가할 수 있다. 클라이언트는 이를 무시하며 신뢰 근거로 사용하지 않는다. 원래 payload 바이트의 서명을 먼저 확인한다. JSON 재인코딩·필드 정렬·문자열 정규화를 거쳐 서명을 검증하지 않는다.

| 필드 | 수용 값 |
| --- | --- |
| `schemaVersion` | JSON 정수 `1` |
| `releaseID` | 공백 없는 출력 가능한 ASCII, 1~128바이트. 같은 ID의 모든 필드는 불변 |
| `platform` | `ipadOS` |
| `bundleID` | `com.ambrion.sillcanvas.ipad` |
| `teamID` | `ZPTXHJ866D` |
| `version` | 문자열. 점으로 구분한 1~3개의 정규 십진수 |
| `build` | 양의 정규 십진 정수 문자열 |
| `sourceCommit`, `sourceTree` | 각각 소문자 16진수 Git SHA 40자리 |
| `approvedAt`, `expiresAt` | RFC3339 UTC `Z`. 초 또는 1~9자리 분수초. Node의 `.000Z` 수용 |
| `channel` | `appStore` 또는 `testflight`. `development` 등 다른 값은 지원 불가 |
| `appleAppID` | 양의 정규 십진 정수 문자열. upstream Sill ID `6816359860` 거부 |
| `installURL` | 아래 채널별 정확한 HTTPS URL |

숫자 구성요소는 최대 18자리이며 선행 0을 허용하지 않는다. 버전의 생략한 뒷부분은 비교할 때 0으로 취급한다. 버전을 숫자로 먼저 비교하고 같은 버전에서 빌드를 비교한다. 예를 들어 `0.5.1 (61)`에서 `0.6 (1)` 또는 `0.6 (61)`로 갱신할 수 있다. 현재 앱 또는 이전 승인보다 낮은 버전·빌드 조합은 거부한다.

승인 시각과 만료 시각은 Date로 비교한다. 새 설치 전달에는 `approvedAt <= now < expiresAt`가 필요하다. 이전 승인보다 과거인 승인을 거부한다. 같은 버전·빌드의 다른 소스나 다른 Apple 대상도 거부한다. 새로운 `releaseID`로 같은 정확한 아티팩트를 새 시각에 재승인하는 것은 허용한다. 같은 아티팩트란 플랫폼·bundle·team·version·build·source commit/tree·channel·Apple ID·설치 URL이 모두 같은 경우다.

## Apple 설치 URL과 책임

App Store는 `https://apps.apple.com/app/id<appleAppID>`만 수용한다. URL의 숫자 ID와 서명된 `appleAppID`가 정확히 같아야 한다.

TestFlight는 발행자가 공급한 정확한 `https://testflight.apple.com/join/<code>`를 수용한다. 이 클라이언트의 허용 코드는 ASCII 영문 대소문자와 숫자 8자리다. 이 길이는 클라이언트의 좁은 허용 규칙이며 Apple의 모든 초대 형식에 대한 보장은 아니다. 문서화되지 않은 앱 대상 URL을 만들지 않는다. 다른 메일 링크 형식과 임의 경로는 지원하지 않는다.

두 채널 모두 명시 포트·사용자명·비밀번호·쿼리·fragment·인코딩 우회·추가 경로를 허용하지 않는다. upstream Sill의 앱 ID를 CCR fallback으로 사용하지 않으며 Debug URL override도 제거했다.

Core와 합의한 발행자의 책임은 실제 App Store Connect CCR 레코드의 bundle/team/Apple ID, 배포 그룹, 가용 빌드와 공식 TestFlight 초대 URL의 관계 확인 영수증을 `releaseID`·소스·버전·빌드에 결박한 뒤 서명하는 것이다. iPad는 서명·고정 identity·시간·버전·초대 URL 형식을 검사한다. URL이나 Apple 호스트만으로 앱 ID의 관계를 독자 확인했다고 표시하지 않는다. 참여 자격·최종 빌드 선택·다운로드·패키지 서명 검증·설치는 Apple이 담당한다.

[Apple TestFlight 설치 안내](https://testflight.apple.com/)와 [Apple Developer TestFlight 안내](https://developer.apple.com/testflight/)는 공식 초대에서 Apple의 Install/Update로 이어지는 흐름의 근거다. 이 클라이언트는 Apple 화면의 자동 탭, 임의 IPA 설치, 앱 강제 종료를 수행하지 않는다.

## 상태와 전용 저장 기록

`unconfigured`, `checking`, `upToDate`, `available`, `handoffPending`, `verifiedInstalled`, `failed`를 사용한다. `upToDate(nil)`은 아직 조회하지 않았다는 안내이며 최신 확인 성공을 뜻하지 않는다.

앱 내 버튼을 한 번 누르면 새 피드를 조회하고 검증한 다음 정확한 Apple URL을 연다. 캐시만으로 다시 설치 전달하지 않는다. 열기 대기 중에는 `available`이며, OS의 열기 성공 응답을 받은 뒤에만 `handoffPending`으로 바꾼다. 이 상태도 설치 완료는 아니다.

`CCR.IPadAppUpdate.pending.v1` 한 키에 서명 봉투, 요청·프로세스 ID, `observed/opening/opened/openFailed/interrupted` 단계만 저장한다. 마지막 승인 봉투는 재생 방지 기준으로 남긴다. 페어링·로그인·그림·초안은 읽거나 수정하지 않는다. OS 응답 후에도 요청 ID와 저장 기록의 소유권을 다시 확인한다. 취소와 화면 닫기는 진행 중 요청을 무효화한다. 이미 OS에 보낸 열기 요청을 취소했다고 주장하지 않는다.

열기 실패는 재활성화·재시작 후에도 실패다. `opening` 중 종료된 요청은 열기 결과 미확인이다. 취소된 요청의 늦은 성공 응답은 상태를 바꿀 수 없다.

설치 확인은 `opened` 기록이 있고 다음 앱 프로세스에서 Bundle의 bundle ID·정확한 version/build·`CCRSourceCommit/Tree`가 승인과 일치할 때만 한다. 이 사실 확인에는 서명·identity를 재검증하되 승인 만료는 새 설치 권한과 구분한다. 따라서 만료 후 완료된 정확한 새 설치는 확인할 수 있다. 만료된 미설치는 만료로 표시하며 자동으로 URL을 열지 않는다. 현재 프로세스로 돌아온 것만으로 완료를 확인하지 않는다.

## 일반 Archive의 소스 식별값

iPad 타깃의 `Prepare iPad source identity` 단계가 `Scripts/ipad-source-identity.py`로 Derived Files의 Info.plist를 만들고 Xcode가 이를 최종 앱 Info.plist로 처리한다. Git HEAD/tree와 전체 작업트리의 clean 상태를 확인한다. Release에서 확인할 수 없으면 빌드를 실패시킨다. Debug의 dirty 소스는 `CCRSourceIdentityVerified=false`로 표시하고 commit/tree를 넣지 않는다. 앱도 명시적 false를 설치 완료 근거로 수용하지 않는다.

기존 외부 custom Info.plist는 수정하지 않는다. 이미 주입된 commit/tree가 clean Git과 일치해야 하며 불일치 또는 미확인은 거부한다. 격리 adapter의 기존 custom Info 경로와 값은 유지하고 읽기 입력 선언만 추가했다. Script sandbox는 유지한다. 별도 Git worktree에서는 Xcode에 `CCR_SOURCE_GIT_COMMON_DIR`로 실제 common Git 디렉터리를 지정한다. 외부 custom Info를 사용하는 호출자는 `CCR_SOURCE_EXTERNAL_INFO_FILE`에 그 파일을 지정한다. 기존 격리 adapter에는 두 값을 직접 연결했다.

실제 빌드 또는 export의 Info.plist 검사는 `python3 -B Scripts/ipad-source-identity.py --repo <clean repo> --verify-built <앱의 Info.plist>`로 수행한다. 이 검사 자체는 서명·업로드·설치를 하지 않는다. 기존 signed61 후보는 개발 프로필이며 배포 준비 완료 증거가 아니다.

## 재현 검사와 미검증 범위

`bash Tests/checks/ipad-app-update/run.sh <외장 검사 출력 경로>`가 실제 production 모델·컨트롤러·URLSession delegate를 컴파일해 실행하고 실제 metadata 스크립트를 검사한다. production 소스의 복제 구현은 쓰지 않는다. URL 열기, 저장소, 시간, 프로세스 ID는 컨트롤러의 주입 지점에서 검사한다. 서명 검사는 공개 RFC 8032 고정 seed의 synthetic fixture만 사용한다. `.example.test` 주소·64자리 synthetic Bearer·숫자 앱 ID는 격리 fixture다. URLProtocol이 모든 요청을 가로채며 실제 endpoint·token 파일·Keychain·계정에는 접근하지 않는다. `run.sh` 실행 권한을 유지한다.

실제 iOS SDK 타입 검사와 기존 테스트 대상의 배치·취소 검사를 별도로 실행한다. 단위·계약 검사, SDK 컴파일, Xcode 빌드 계획, 전체 Archive, 코드 서명, export, 설치와 실물 UI 수용은 서로 다른 증거다. 이 작성자 작업에서는 실제 UI·기기·호스트·테스트 서비스·배포·업로드·외부 설치를 수행하지 않는다. 독립 검수·최종 통합·서명 후보·실물 검증은 부모 원담당의 후속 범위다.
