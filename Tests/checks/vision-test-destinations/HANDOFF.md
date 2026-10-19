# Vision project test destinations — source return

Original owner: `01a13005-ff61-7780-b0e8-6dc171de1c9d`.
Base: `0d6749c6ef9c5645162a04dab683bace722089c7`.
Branch: `codex/vision-test-destinations-20261020`.
Shared Entry first commit: `908bcf890037547b05100f79ac1ac5a892a32040`.

## Source freeze

- Optional `WindowList.testDestinations` carries the raw validated projection. Bad optional values
  decode to unavailable catalog without rejecting the window list. Existing init calls remain valid.
- The existing authenticated TLS peer helper supplies identity; a connection generation binds the
  catalog. Disconnect, handover, authentication revocation, malformed list and unavailable/invalid
  projection clear selection and rotate the device login store scope.
- Native opening and navigation revalidate the exact catalog entry, project ID/label, HTTPS origin,
  registered redirect origins and injected clock. `checkedAt` must be neither future nor older than
  45 seconds. iframe headers remain informational. HTTP stays compatible in the shared legacy
  schema but cannot open in this native viewer.
- Korean workspace entry and sheet use per-project nonpersistent WebKit stores. Closing/reopening
  within the same paired scope reuses device login; different projects and peer generations use
  different stores. No host cookies, credentials or tokens are imported.
- Explicit protocol compiler lists now include the new shared source and its current dependency
  closure. The Vision project membership and generator include the new adapter.

The producer currently has **zero live entries**, as reported by the owner. `catalog.json` is an
offline reserved-domain test fixture, not a proposed live destination. This work does not implement
the parent-owned Host canonical reader. Its reported 2,471,968-byte snapshot and planned 16 MiB
reader bound are not changed here. No voice contract, endpoint or stub was added.

## Verification for parent after return

No build, test, generator, runtime, network, browser, audio/HAL, Mini or device command was run by
this writer. Source review and Git commits are the only completion evidence here.

On the parent's approved execution host and new RAM output path, run:

```sh
python3 -B Tests/checks/vision-test-destinations/run.py SOURCE_ROOT NEW_PARENT_RAM_OUTPUT
```

The runner compiles actual shared contract, model and adapter sources. It extracts production
storage, view delegate and store bodies verbatim and uses inert Network/WebKit shapes. Assertions
cover wire compatibility, malformed optional carriers preserving stream fields, exact project and
origin/time validation, 45-second boundary, future time, peer/disconnect/authentication invalidation,
unregistered redirects, HTTP/display/failure states and isolated project login store lifetime.
It records source hashes, commands, results and source immutability in `result.json`. It does not
prove platform API compatibility, real TLS authentication or real WebKit/device behavior.

The parent must compile the complete native target against the installed **XROS 27.0 SDK**, run
the affected regression fixtures with the exact returned source, and independently review the diff.
Real device login persistence, rendering, focus and line wrapping remain device acceptance work.
The writer does not claim these gates passed.

## Workflow

Pstack Feature: reused the existing contract/model/view, peer trust helper, current window lease,
input admission and project generator patterns; implementation followed by direct source review.
Ponytail: standard URL/Foundation/WebKit APIs, existing optional projection boundary and an injected
clock; no extra protocol scope fields or dependencies. User restrictions replace nested-agent and
execution stages with the parent's exact-source review/compile/test gates. ARENA and Orca were not
used. This is the final source checkpoint, not runtime acceptance.

## 2026-10-20 P1/P2 독립 소스 수정 반환

작업 키는 `vision-test-destinations-review-20261020`이다. 원 담당 대화는 위와 같다.
전용 브랜치는 `codex/vision-test-destinations-review-20261020`이며 기준 커밋은
`5cb051eefe4911dafc26ad72b7e9f3ccf9572725`이다. 이 워크트리에서만 수정했다.
공유 `Sources/StreamProtocol/TestDestinations.swift`의 URL 수정은 iPad 담당 소유이므로
변경하지 않았다. Host reader, 음성, 실제 URL이나 등록 항목을 추가하지 않았다.
생산자의 실시간 등록 항목 수는 원 담당이 전달한 0건이며 여기서 조회하지 않았다.

P1은 탐색 검사와 별도로 네이티브 `WKContentRuleList`를 비동기 컴파일한다.
전체 요청 차단 뒤 기본 HTTPS 출처와 명시된 HTTPS 리디렉션 출처만 허용한다.
호스트를 정규식으로 이스케이프하고 출처 경계와 시작·끝을 고정했다.
기본 443 포트는 생략·명시를 동등하게 허용하고, 비기본 포트는 등록된 포트만 허용한다.
컴파일 결과를 컨트롤러에 설치한 다음에만 첫 `load`를 실행한다.
오류·빈 결과·권한 만료·연결 해제·선택 교체·해체 뒤 늦은 콜백은 페이지를 로드하지 않는다.
해체 시 자신의 목록만 컨트롤러에서 제거한 뒤 자신의 고유 저장 식별자를 정리한다.
컴파일 중 해체된 경우 완료 콜백이 그 식별자를 정리한다.
모든 인증 방식에서 현재 선택과 HTTPS 출처·포트를 검사한다.
허용 출처의 서버 신뢰 요청만 자격 정보 없이 기본 처리로 전달한다.
TLS 인증서·신뢰 검증을 대체하거나 완화하지 않았다.

P2는 현재 카탈로그의 같은 ID 항목으로 권한과 최신 `checkedAt`을 재검증한다.
`projectId`, `projectLabel`, URL, owner, redirectOrigins가 같고 최신 관측이
도달 가능하며 유효하면 기존 선택 UUID, 페이지 상태, WebView, 폼과 프로젝트 저장소를 유지한다.
호환되는 embed·reason 관측 갱신도 선택을 해제하지 않는다.
권한 변경·만료·도달 불가·미확인은 선택을 해제한다. 페이지 콜백도 같은 검증을 사용하며
이미 해제한 선택은 새 관측이나 늦은 콜백으로 되살리지 않는다.

추가 픽스처는 실제 생성 JSON의 순서·정규식 문법·정확 출처 경계·443 정규화·비기본 포트·
제삼자 스크립트 차단, 등록 리디렉션과 외부·만료 신뢰 요청, 확인 시각 갱신 중 UUID·페이지·
저장소 유지, 권한 변경과 만료 해제, 컴파일 실패·빈 결과·첫 로드 대기·늦은 콜백 정리를 다룬다.
`run.py`는 기존 모델·어댑터·저장소·delegate에 더해 실제 `makeCoordinator`,
`makeUIView`, `updateUIView`, `dismantleUIView` 본문도 그대로 추출한다.
컴파일러·WebKit 형상은 격리 대역이다. JSON 평가는 Foundation 정규식 의미의 검사이며
실제 WebKit 규칙 컴파일·적용이나 TLS 검증의 통과 증거가 아니다.
보장 범위는 탐색 정책, 인증 요청 및 WebKit이 콘텐츠 규칙으로 필터링하는 리소스 요청이다.
가능한 모든 JavaScript 네트워크 경로의 격리를 보장한다고 주장하지 않는다.

설치된 `/Applications/Xcode.app/Contents/Developer/Platforms/XROS.platform/Developer/SDKs/XROS27.0.sdk/`
아래 `WebKit.framework/Headers`의 `WKContentRuleListStore.h`, `WKUserContentController.h`,
`WKNavigationDelegate.h`, `WKContentRuleList.h`를 읽었다.
비동기 compile, add/remove, 저장 식별자 제거와 기본 인증 처리 API 선언을 확인했다.
네트워크 문서 조회나 SDK 컴파일은 실행하지 않았다.

원 담당이 전달한 frozen `5cb051e`의 SDK17/XROS27 빌드·서명 통과와 바이너리 SHA
`12eeef1d64506922e3d6203ca4c010a5c029f55d511909335fb25ad357080f49`는
수정 전 버전의 별도 영수증이다. 이 패치의 통과 증거로 사용하지 않는다.
이번 작성자는 소스 검토와 `git diff --check`만 수행했다. TDD 회귀 픽스처를 먼저 작성했지만
사용자의 실행 금지에 따라 수정 전 실패와 수정 후 통과 모두 실행하지 않았다.
새 독립 검수, 실제 픽스처 실행, Mini 및 정확한 통합 소스의 SDK·서명 게이트는 부모가 수행한다.
실제 기기는 BA 소유이며 조작하지 않았다. 빌드·테스트·런타임·Mini·네트워크·기기·브라우저를
실행하지 않았다. 최종 수용·운영 반영은 주장하지 않는다.

Pstack 경로는 TDD/Feature이며 Ponytail은 기존 모델·주입 시계·네이티브 WebKit 재사용을 선택했다.
진행 체크포인트는 다음과 같다.

- 선행 조건은 전용 브랜치·기준 커밋·깨끗한 시작 상태 및 설치 SDK 헤더 확인이다.
- 독립 작업 분리는 해당 없음이다. 이 작업은 이미 분리된 소스 수정 단위이며 중첩 에이전트가 금지됐다.
- 공유 변경은 해당 없음이다. 다른 워크트리와 공유 프로토콜 파일에 쓰지 않았다.
- 최소 분해는 단일 작성자가 P1/P2와 관련 픽스처만 수정하는 것이다. 새 독립 검수와 실행은 부모가 맡는다.

ARENA·Orca·중첩 에이전트는 사용하지 않았다. 이 반환은 범위가 정해진 소스 패치다.

## 2026-10-20 SwiftUI Binding 재게시 P2 소스 수정 반환

작업 키는 `vision-webview-update-fix-20261020`이다. 원 담당 대화는 위와 같다.
전용 워크트리는 `work/sill-vision-update-fix`, 브랜치는
`codex/vision-webview-update-fix-20261020`, 기준 커밋은
`40a8e14bd4bf4493a24d35856b4910aaa8a13c5c`이다. 시작 시 브랜치·HEAD와
깨끗한 상태를 Git으로 확인했다. 사용자가 전달한 IndependentPascal review18c의
P2 원인을 실제 호출 소스와 대조했다. 해당 독립 검수를 이번 변경의 검수로 재사용하지 않는다.

`VisionTestDestinations`는 구조체이므로 Binding을 통해 mutating `revalidate`를 호출하면
건강한 선택을 검증했을 때도 setter가 호출된다. 실제 저장소는 StreamClient의
`@Published visionTestDestinations`이므로 `updateUIView`에서 이를 반복하면
SwiftUI reconciliation과 모델 게시가 반복될 수 있다. 생성·갱신·해체와 검증 전용
콜백은 기존 nonmutating `isCurrent`를 사용하도록 바꿨다. 모델의 `observe`, `report`,
`revalidate` 자체와 공통 권한·시간·출처 계약은 유지했다.

무효 화면은 즉시 로드를 멈추고 설치된 자기 콘텐츠 규칙과 저장 식별자를 정리한다.
진행 중 컴파일의 식별자는 완료 콜백이 정리한다. 선택 해제는 main queue에 예약하며,
실행 시 같은 Selection인지와 최신 카탈로그에서 여전히 무효인지 다시 확인한다.
예약 후 선택을 새로 열었거나 같은 선택의 최신 관측이 갱신됐으면 닫거나 게시하지 않는다.
반복 예약도 첫 해제 뒤 동일 선택 검사에서 멈춘다. 생성 중 규칙 JSON 준비 실패의
상태 보고도 예약하며, 보고 시 선택을 대조하고 모델의 기존 권한 재검증을 사용한다.

`stop`은 먼저 리소스 상태를 `.closed`로 바꾼다. `stopLoading` 중 콜백이 와도
상태 보고가 Binding을 쓰지 않는다. 컴파일 성공은 검증용 모델 쓰기를 하지 않는다.
이전 선택의 상태 콜백은 현재 선택의 UUID가 다르면 보고하지 않는다.
실제 페이지 상태 변경과 컴파일 실패 보고는 reconciliation 밖의 기존 이벤트 경로에 남는다.

`WebViewFixture.swift`에는 기존 custom Binding setter에 카운터를 연결했다.
실제 production `makeUIView`, `updateUIView`, `dismantleUIView`와 coordinator 본문을
기존 runner가 그대로 추출한다. 추가 검사 소스는 다음 조건을 다룬다.

- 건강한 생성과 반복 갱신 및 컴파일 완료에서 setter 호출이 없고 UUID·WebView·폼·저장소가 유지된다.
- 건강한 해체·반복 stop·동기 중지 콜백·늦은 컴파일 완료에서 모델 쓰기가 없고 자기 규칙만 정리한다.
- 만료 갱신은 즉시 로드를 중지하고 규칙을 제거하지만 예약 콜백 전에는 선택을 게시하지 않는다.
- 예약 콜백은 같은 만료 선택만 한 번 해제하며, 그전에 새로 연 선택과 같은 선택의 관측 갱신을 보호한다.
- update 이전에 선택이 교체돼도 이전 컴파일·실패·상태·stop 콜백이 새 선택을 쓰거나 변경하지 않는다.

기존 리소스·출처·인증·관측 갱신 검사와 그 기대 결과는 유지했다. 예약 콜백은
대역 스케줄러 대신 실제 main queue와 제한된 RunLoop 진행으로 확인하도록 작성했다.
이 fixture는 WebKit 대역과 Binding setter 호출 수를 검사한다. 실제 SwiftUI의
`@Published` 알림이나 기기 WebView 동작을 관측한 영수증은 아니다.

공유 동결 대상의 실제 경로는 `Sources/StreamProtocol/TestDestinations.swift`이다.
Git blob `b740be9a3608799f750405f409e4f9940b20b0a0`를 읽어 확인했으며 수정하지 않았다.
부모 소유 Host reader와 다른 워크트리에 쓰지 않았다.

Pstack TDD/Feature 경로로 회귀 검사 소스를 먼저 작성하고 구현했다.
Model the Domain 원칙에 따라 기존 Selection과 ResourceState를 재사용했고,
Laziness Protocol과 Ponytail full에 따라 기존 `isCurrent`와 main queue를 사용했다.
새 계층·의존성·프로토콜은 추가하지 않았다. 선행 조건은 전용 소유권·기준 커밋·clean 확인이며,
이 worker 내부의 병렬 분해는 해당 없음이다. 공유 쓰기는 없고 단일 P2 소스 단위로 반환한다.
ARENA·Orca·중첩 에이전트는 사용자 금지에 따라 실행하지 않았다.

이번 작성자의 검증 근거는 직접 소스 검토, `git diff --check`, 공유 blob 대조와 Git 상태뿐이다.
사용자의 SOURCE-ONLY 제한으로 수정 전 실패와 수정 후 통과를 실행하지 않았다.
테스트·빌드·Mini·네트워크·브라우저·기기·앱 런타임을 호출하지 않았다.
새 독립 검수도 실행하지 않았다. 부모가 반환된 정확한 소스로 실제 fixture와
matching SDK 검증 및 새 독립 검수를 수행한다. 기존 버전의 실행 영수증을
이 패치의 통과로 합치지 않으며, 통합·배포·실기기 수용은 미검증이다.
커밋 뒤 clean 상태로 소스 소유권을 부모에게 반환한다.
