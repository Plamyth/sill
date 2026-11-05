# CCR iPad 연결 UI XCTest 후보

이 후보는 정상 앱의 일상 메뉴를 XCTest로 관측하기 위한 독립 테스트 묶음이다. 소유 범위는 이 폴더뿐이다. 앱·Runtime·Host·registry·기존 연결 원장은 변경하지 않는다. 설치된 TestFlight 78과 runner 미설치 상태는 사용자 인계 정보이며 이번 작업에서 기기를 조회해 재확인하지 않았다.

## 대상과 허용 행동

- 기준은 `origin integration/ccr-ipad`의 `ff98f3c05361ee9a6777704c80783e3c30413f04`, tree `1de78b48752e3821130eea50f7b258a08f2b09fe`다.
- 정상 앱은 `com.ambrion.sillcanvas.ipad`다. 이미 실행 중일 때만 `activate()`한다. `launch`, `terminate`, launch arguments/environment 변경은 없다. 상태 확인과 activate 사이 앱이 종료되는 경합까지 원천 방지하는 공식 API는 없으므로 향후 Root가 안정된 기기 구간에서 검증해야 한다.
- 두 테스트는 모니터 AX가 보이지 않을 때 `iPadToolbarToggle`의 유일성·hittable·정확한 ‘상단 메뉴 표시’ 라벨을 확인해 각 테스트당 최대 한 번만 누른다. ‘상단 메뉴 숨기기’ 라벨 반영과 모니터 AX의 유일성·hittable을 검사하고 전후 캡처를 남긴다. 반복 탭이나 스와이프는 없다. 실기 AX 반영 성공은 아직 미검증이다.
- `test01ReadDefaultMonitorAX`는 `macDisplayChooser`의 label/value와 앱 스크린샷을 첨부한다. 모니터를 선택하지 않는다. 관측한 이름이 요구된 기본 모니터인지는 원본과 대조해야 한다.
- `test02OpenNativeAudioChooserOnly`는 native menu bar의 ‘오디오’가 유일하고 hittable이면 ‘입력·출력 선택…’ 경로를 쓴다. 그 조건을 만족하지 않으면 소스의 정확한 앱 native AX 경로 `workspaceOverflow` → UIKit 메뉴 ‘설정’ → `openAudioRoutes`이면서 라벨이 ‘오디오 입력·출력 선택…’인 버튼을 쓴다. 모든 탭은 유일성·hittable 검사를 통과해야 한다. 메뉴 항목은 정확 라벨의 button 또는 menuItem만 허용한다. 마지막 ‘오디오 입력·출력’ 창 표시를 확인하고 캡처한다. 원격 영상·좌표·스와이프·키·오디오 toggle은 누르지 않는다. native 경로를 누른 뒤 실패했을 때 다른 경로를 재시도하지 않는다.
- 오디오 창을 열면 기존 앱의 presentation/offer 상태가 바뀌고 Mac 장치 목록을 조회한다. 마이크·출력 활성화 호출은 하지 않는다. 테스트는 이름의 01 → 02 순서로 관측 후 창을 열며 순서를 무작위화하지 않는다. 선택·적용·닫기는 누르지 않는다. 특히 기존 `close()`가 오디오 승인 상태를 변경하므로 자동 복구 조작을 넣지 않았다. 창은 열린 채 남는다. 실패 시 열린 메뉴도 남을 수 있다.
- 마이크·스피커 전환 메서드, 원격 영상 터치, 텍스트 입력, 제출, 그림, 키·권한 변경은 구현하지 않았다. 스크린샷에는 현재 앱 콘텐츠가 포함될 수 있으므로 향후 xcresult는 기존 비공개 근거 경로에서만 관리한다.

## 빌드

프로젝트는 단일 `com.apple.product-type.bundle.ui-testing` target이다. 정상 앱이나 REA 앱 target·의존성이 없다. 공유 scheme에는 LaunchAction이 없다. Apple이 생성하는 `ConnectionUITests-Runner.app`만 테스트 host다.

먼저 `storage-route path development-archive --project BT_CCR-ipad --filename ipad-connection-ui-20261105`의 JSON path를 얻어 그 경로를 아래 `ARCHIVE`에 전달한다. 이는 이미 검증된 외장 UUID가 있을 때만 수행한다.

```sh
ARCHIVE=/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/ipad-connection-ui-20261105
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build-for-testing \
  -project Tests/ipad-connection-ui/ConnectionUI.xcodeproj -scheme ConnectionUI \
  -destination 'generic/platform=iOS' -derivedDataPath "$ARCHIVE/DerivedData" \
  CODE_SIGNING_ALLOWED=NO
python3 Tests/ipad-connection-ui/prepare_destination.py \
  "$ARCHIVE/DerivedData/Build/Products/ConnectionUI_iphoneos27.0-arm64.xctestrun" \
  "$ARCHIVE/ConnectionUI-destination.xctestrun"
```

출력 파일이 이미 있으면 변환기는 덮어쓰지 않는다. 빌드 명령만으로 설치·테스트가 실행되지는 않는다. 생성된 원본 xctestrun으로 기기 시험하지 않는다. 이 문서는 기기 실행 명령을 제공하지 않는다.

## 향후 runner만 설치하는 계약

Apple Xcode 27.0에 포함된 `Contents/Developer/usr/share/man/man5/xcodebuild.xctestrun.5`의 `UseDestinationArtifacts` 정의를 적용했다. 이 옵션은 실행 시 artifact 설치를 하지 않는다. runner를 설치하는 옵션이 아니다.

| 필드 | 값 |
| --- | --- |
| `UseDestinationArtifacts` | `true` |
| `UseUITargetAppProvidedByTests` | `true`, Xcode가 생성한 독립 테스트 동작 유지 |
| `TestHostBundleIdentifier` | `com.ambrion.rea.appaudit.UITests.xctrunner` |
| `TestBundleDestinationRelativePath` | `__TESTHOST__/PlugIns/ConnectionUITests.xctest` |
| `UITargetAppBundleIdentifier` | `com.ambrion.sillcanvas.ipad` |
| runner의 `CCR_CONNECTION_UI_APPROVED` | `0`, 두 테스트 모두 skip |

`TestHostPath`, `TestBundlePath`, `UITargetAppPath`, `DependentProductPaths`, 정상 앱의 arguments/environment는 변환 결과에 없다. 테스트 두 개만 allowlist에 둔다. 설치할 유일한 후보 경로는 `DerivedData/Build/Products/Debug-iphoneos/ConnectionUITests-Runner.app`이다. 정상 앱 artifact는 생성하지 않는다.

Root가 향후 독립 검수, 실제 기기 단일 소유자 조율, runner 서명/provisioning·entitlements·OS 호환성, 정상 TestFlight 버전·데이터 보존을 확인한 후 runner만 한 번 설치한다. 이때 정상 앱이나 옛 REA 앱 설치는 하지 않는다. 설치 후 runner ID와 내부 test bundle을 readback하고, 별도 실행용 xctestrun 복사본의 runner 승인 값만 `1`로 변경한 뒤 새 SHA를 남겨야 한다. 앱을 테스트 제공 대상으로 지정한 동작과 destination artifacts 계약의 실제 호환성은 아직 미검증이다. 자동 앱 launch/재설치가 없음을 첫 실행에서 별도로 관측해야 한다.

최초 `ipad-connection-ui-20261105` artifact는 서명을 끈 빌드의 이력이다. 후속 서명 후보는 아래 새 경로에서 별도로 빌드·검증하며 이전 unsigned SHA를 사용하지 않는다. 정상 앱·옛 REA 앱을 생성하지 않는 단일 UITest target은 유지한다.

## 검증 및 Pstack 적용

Pstack Feature 순서를 사용했고 ARENA 설계 탐색은 사용자 금지에 따라 제외했다. Ponytail full의 기존 구조와 표준 도구 우선 원칙으로 XCTest·Python 표준 라이브러리만 사용했다. 새 의존성·앱 target·mic/speaker 제어는 추가하지 않았다.

1. `how` over the affected subsystem. 완료. `StreamScreen.swift`의 `macDisplayChooser`, `SillAppDelegate.swift`의 오디오 메뉴, `IPadAudioRouteChooser.swift`의 표시와 close 동작을 읽기 대조했다. 옛 integration 프로젝트는 읽기만 했다.
2. `architect` for parallel design exploration. skip. ARENA는 금지되어 단일 독립 UITest target과 destination-artifacts 변환만 설계했다.
3. Write the throughput checkpoint as four todo items.
   - Blocking first steps. 기준 HEAD/tree·원격 ref·clean·사용자 정책·라우팅 경로 확인 완료.
   - Independent workstreams. 부모가 API/PCM·원장·Root를 소유하고 이 후보는 독립 경로만 쓴다. Apple 빌드는 Mac, 정적 검사는 Mini 메모리 입력에서 수행한다.
   - Shared mutable state. 기기·USB·Host·오디오·registry·기존 원장 쓰기는 0이다.
   - Smallest safe decomposition. 테스트 묶음 하나이므로 단일 writer가 소유한다. 추가 후보 경쟁·중복 담당은 만들지 않았다.
4. Delegate code-writing to a subagent. 현재 하위 에이전트 도구가 없어 본 담당이 독점 경로에서 구현했다. `BLOCKED: independent review`. 부모의 독립 검수 전 merge-ready·shipping 상태는 닫혀 있다.
5. Verify on the matching surface. 최초 unsigned 및 후속 signed generic iOS build-for-testing, project plist lint, Mini의 행동 범위·scheme·변환 성공/runner ID 거부·설치 경로 제외 계약 검사까지 수행했다. 정적 검사는 source snapshot 해시와 함께 외장 `mini-static.json`에 기록했다. 이는 Git source-guard 이전 수용이 아닌 좁은 독립 검사다.
6. Rebase into small, ordered commits. 요청한 정확 기반의 단일 변경만 커밋한다. 다른 파일을 합치지 않는다.
7. If the design is contested, `interrogate` before shipping. n/a. 단일 후보이며 shipping은 범위 밖이다.
8. Run Opening a PR. skip. 사용자 지시대로 push·PR·병합·서버 반영은 0이다.

빌드 성공은 실행 성공이 아니다. AX 노출, 실제 activation, native menu/오디오 창 표시, 기본 모니터 일치, 실음성, 제품 수용과 정상 앱 데이터 보존은 모두 미검증이다. Root가 일회 최소 XCTest 경로를 수용했다는 사용자 인계를 받았다. 기기 설치는 부모가 직접 하며 Fold 구간 반납과 이 수정본에 대한 부모 독립 검수 완료 전에는 진행하지 않는다. 기존 원장은 부모가 업데이트하며 이 문서는 후보 사용 계약이다.


## 2026-11-05 후속 서명 후보

`14cf57d3`를 부모가 읽은 뒤 상단바 숨김·native menuBar 부재를 지적했다. 실제 iPad 78 화면에는 우상단 토글만 보인다는 부모 관측을 사용했고 새 기기 조회는 하지 않았다. `StreamScreen.swift`의 `toolbarToggle`, `IPadToolbarVisibility.swift`의 4초 유휴 숨김, `workspaceOverflow`의 UIKit UIMenu ‘설정’, `HostSettingsPanel.swift`의 `openAudioRoutes` 버튼을 읽기 대조했다. 실제 호출은 `client.showAudioRoutes`다. 제품 소스는 변경하지 않았다.

라우팅 도구가 반환한 새 root는 `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/signedcandidate`다. 첫 signed 빌드는 그 root에 보존하고, 추가 AX 대체 경로를 포함한 최종 후보는 **`signedcandidate/ax-fallback`**에 분리한다. 최초 unsigned 산출물이나 중간 signed 후보를 최종 후보로 사용하지 않는다.

기존 identity의 공개 SHA-1은 `BCE70A14D3C226755973F5FFBF5617CCED211569`이며 Apple Development identity다. profile은 기존 Xcode 관리형 `iOS Team Provisioning Profile: *`, UUID `40b0d631-e2f5-48bb-b79d-8fb083507835`, Team `ZPTXHJ866D`, 만료 `2027-02-18 10:23:27 UTC`다. 수동 지정 첫 시도는 Xcode 관리형 profile과 Manual 설정 충돌로 실패했고 이력 로그를 보존했다. `-allowProvisioningUpdates` 없이 Automatic 모드로 기존 profile을 선택한다. 키 추출·ACL 변경·새 인증서/profile 발급은 하지 않는다.

```sh
SIGNED=/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/signedcandidate/ax-fallback
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build-for-testing   -project Tests/ipad-connection-ui/ConnectionUI.xcodeproj -scheme ConnectionUI   -destination 'generic/platform=iOS' -derivedDataPath "$SIGNED/DerivedData"   CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=ZPTXHJ866D   CODE_SIGN_IDENTITY='Apple Development'
```

서명 검증은 runner와 내부 test bundle에 각각 `codesign --verify --deep --strict`를 적용한다. runner의 entitlement는 exact runner application identifier, Team, `get-task-allow=true`, runner 자체 keychain group이다. 정상 앱의 keychain group·마이크·오디오 entitlement를 추가하지 않는다. test bundle entitlement는 비어 있다. 기존 profile의 6개 UDID와 embedded profile·파일 SHA·서명 결과는 새 artifact의 영수증에서 확인한다. generic 빌드는 특정 UDID를 선택하지 않는다. 실물 iPad UDID와 profile 포함 여부의 최종 대조는 부모가 기존 승인된 설치 경로에서 수행해야 한다.

빌드/서명 및 Mini 정적 검사는 실제 AX 노출·activation·오디오 창 표시·음성·제품 수용을 증명하지 않는다. 이 수정본에 대한 부모 독립 검수는 아직 대기다. 설치·XCTest 실행·USB 조작·Host·오디오·기기 UI 조작은 수행하지 않았다.

최종 AX 대체 경로 후보는 Xcode 27.0 generic iOS `build-for-testing`과 runner/test bundle 각각의 strict deep 서명 검증을 통과했다. embedded profile UUID는 사전 확인한 기존 값과 일치한다. Mini의 최종 정적 검사와 전송 전후 소스 SHA 대조, project/xctestrun plist lint도 통과했다. 정상 앱 artifact가 없고 runner.app 하나만 생성된 것을 확인했다. 증거는 `signedcandidate/ax-fallback/build-final.log`, `signature-verification.json`, `mini-static-final.json`, `candidate-receipt.json`, `runner-files-sha256.json`이다.
