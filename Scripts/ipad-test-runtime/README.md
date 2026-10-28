# iPad 단일 정상 앱 테스트 경로 준비

기존 **deploy·accept·harness와 저수준 install은 held**다. 부모가 준비한 정상 서명 Debug artifact에 한정한 `deploy-prepared`는 아래 사전조건을 실제로 검사하고 통과하면 같은 정상 bundle 설치와 격리 실행까지 진행한다. 기존 두 CLI phase는 설정을 읽거나 source/device 조회·빌드·설치·relay 시작을 하기 전에 종료 코드 2와 `single_app_runtime_held` 사유를 반환한다. 새 phase는 누락·불일치를 상수 목록으로 대체하지 않고 구체 검사 실패로 held를 반환한다. 이 중단을 해제하는 설정 스위치는 없다. 기존 진단 앱이나 XCTest runner를 삭제하지 않는다.

이번 구현·검사는 소스와 mock 경계에 한정한다. 실제 기기 조회·설치·실행은 수행하지 않았다. 정상 앱 설치나 실제 제품 기능 수용을 완료했다고 표시하지 않는다.

## 확인한 현재 경로

- 정상 앱 `SillApp`의 Debug `--ccr-test-runtime UUID` 분기는 `CanvasWorkspace`를 직접 열며 `ContentView`와 그 `StreamClient`를 만들지 않는다. 잘못된 context는 오류 화면으로 끝난다.
- `CanvasRuntime.resolve`는 앱의 exact commit/tree와 시험 context를 대조하고 UUID 아래 state만 허용한다. scene/recovery/checkpoint/workspace와 새 `CanvasPreferences.json`이 그 경로를 사용한다.
- `CanvasRelay.loadConnection`은 isolated에서 context 주소·token을 반환하고 invalid에서는 nil을 반환한다. 정상 Documents의 이전 연결과 keychain 읽기·이관은 그 뒤 normal 분기에 있다. 요청 역시 context의 주소·token·origin을 강제한다. 이 소스 추적을 실기기의 keychain·relay 왕복 수용으로 확대하지 않는다.
- Store의 기본 지우개 설정은 isolated에서 시험 JSON으로 읽고 쓴다. 명시적으로 넘긴 UserDefaults도 isolated/invalid에서는 사용하지 않는다. invalid는 일반 defaults로 복귀하지 않으며 손상된 시험 설정 파일도 덮지 않는다. normal에서는 기존 UserDefaults 주입과 기본 standard 경로를 유지한다.

## legacy 설치 차단과 새 경로의 검사 경계

1. 기존 deploy는 `com.ambrion.rea.ipad-runtime`을 만들고 버전을 1로 고정하며 합성 OwnerBootstrapFixture를 넣는다. bundle 이름만 `com.ambrion.sillcanvas.ipad`로 바꾸면 안 된다. 현재 정상 설치 버전·서명·Team `ZPTXHJ866D`·keychain entitlements를 대조하지 않은 낮은 버전 재설치는 금지한다.
2. normal68의 기존 보존 절차를 재사용해 snapshots에 note recovery·Legacy·workspace와 Documents/전체 Preferences의 파일 트리 SHA를 추가했다. `same_user_data`는 설치 metadata를 사용자 바이트와 분리해 비교하므로 정상 버전 갱신 자체를 데이터 손상으로 판정하지 않는다. metadata의 bundle/team/버전은 별도 exact 검사가 필요하다. 추가된 디렉터리 copy/readback은 이번 단위에서 mock과 실제 로컬 파일로 검증했으며 최신 기기의 최신 후보 수용을 대신하지 않는다.
3. 정상 앱의 `SillAppDelegate.buildMenu`는 isolated 분기 밖에서도 실행될 수 있고 Debug 메뉴 표시 설정을 standard defaults에서 읽는다. 관측된 이 경로는 읽기이며, 이번에 수정한 Store 쓰기 누수와 구분한다. 이 파일은 쓰기 범위 밖이므로 그대로 두었다. 앱 전체의 일반 Preferences 읽기 차단까지 완료했다고 하지 않으며, 이 읽기 관측만을 영구 설치 차단 사유로 삼지 않는다.
4. harness의 build-for-testing fallback을 제거했다. 공식 `xcodebuild.xctestrun(5)`의 `UseDestinationArtifacts=true`는 목적지의 기존 artifacts를 사용하고 테스트 artifacts를 설치하지 않는다. `destination_artifacts_run`은 v1/v2에서 단일 UI target만 허용하고 TestHostPath/TestBundlePath/UITargetAppPath/DependentProductPaths를 제거한 뒤 기존 runner와 정상 앱 bundle identifier로 연결한다. 새로운 runner/app 설치를 요구하는 local product 경로를 넘기지 않는다. 정상 Debug runtime readback과 기존 runner identity 영수증·입력 xctestrun의 고정 SHA가 없으면 진행하지 않는다. 이 전환의 실제 기기 실행은 부모의 공유 구간에 남긴다.
5. Debug 격리 테스트 종료 후 플래그 없는 정상 실행으로 돌아갈 때 기존 keychain 참조·마지막 Mac·원래 연결/오디오 의도와 전체 사용자 데이터가 그대로임을 아직 검증하지 않았다. 실제 설치·정상 복귀의 공유 구간은 부모가 소유한다.

## 기존 공개 bootstrap 참조

부모가 제공한 공개 리소스는 `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/owner-mac-bootstrap-20261022/public-profile-from-ipad-saved.json`이며, SHA-256은 `7bcf8ce74bf4292d1a20b07d45bfa0c040957e1ade3d80dd4be37c5eb96cf8c7`이다. 원본을 변경하거나 키를 복사하지 않는다.

`owner_bootstrap_identity`는 후보 설정의 `ownerBootstrapProfile`과 `ownerBootstrapSHA256`를 읽기 전용으로 대조하고 기존 provisioner의 공개 schema 검사를 재사용한다. 값의 본문·인증정보는 반환하지 않는다. 이 검사는 설치나 현재 Host 일치의 승인·수용이 아니다. 정상 bundle 설치 후보는 반드시 이 승인된 실제 공개 리소스 identity와 기존 keychain 참조를 보존해야 한다. synthetic bootstrap은 미설치 단위/SDK 검사에만 허용한다. legacy deploy는 계속 held다. deploy-prepared는 이 승인된 SHA를 독립 상수와도 대조하고 signed app 안의 동일 리소스·기존 설치 서명 참조와 일치해야 진행한다.

## 자동 검사

```sh
python3 -B Scripts/ipad-test-runtime/test_adapter.py
```

Apple SDK 검사는 storage-route가 확인한 외장 증거 디렉터리를 지정한다.

```sh
CCR_NATIVE_ADAPTER_TEST_DIR=/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/adapter-evidence/native \
python3 -B Scripts/ipad-test-runtime/test_adapter.py
```

실제 CLI subprocess가 held로 끝나는지와 deploy/accept/harness/install 경계에서 devicectl·xcodebuild·relay·파일 덮어쓰기가 시작되지 않는지 검사한다. 기존 parser·PNG·review 기능의 단위 검사에서는 held 함수를 mock하여 순수 로직만 계속 검사하며 운영 우회 옵션은 만들지 않는다. native Debug 검사는 실제 flagged context와 잘못된 context에서 일반 defaults 읽기/쓰기를 실패시키는 객체를 전달하고, 격리 설정 저장→새 Store 재열기와 비어 있지 않은 전체 Preferences fixture의 바이트 불변을 확인한다.

기존 descriptor·release 등록은 그대로이며 이 후보를 testAccepted로 승격하지 않는다. 기존 진단 앱 강제 제거, 새 앱·runner 설치, 실기기 조회·Host·오디오·키·권한·계정 변경은 하지 않는다.

## 기존 normal68 보존 절차의 재사용

`normal68-device-20261026/normal68-install-preservation.json`, `normal68-observation.json`, `normal68-post-reconnect-preservation.json`, `normal68-preferences-delta.json`을 읽기 전용으로 확인했다. 당시 정상 설치의 보호 파일·note recovery·Preferences 바이트 보존과 재연결 뒤 `Sill.savedMacs.infoIssuedAt` 변경 관측은 과거 세대의 구체 근거다. snapshots의 원본별 byte hash와 metadata 분리를 이번 소스에 재사용했다. 이 timestamp 변화를 일반적인 Preferences 변경 허용으로 확장하지 않으며 최신 후보는 최신 before/after와 정확한 설치 버전·원본 bundle/team을 다시 확인해야 한다.

## 기존 runner만 사용하는 준비 입력

`existingXctestrun`/`existingXctestrunSHA256`, `existingRunnerReceipt`/`existingRunnerReceiptSHA256`가 필요하다. runner 영수증 schema는 `ccr.existing-xctest-runner/v1`, `installed=true`, `team=ZPTXHJ866D`, `bundleIdentifier=com.ambrion.rea.appaudit.UITests.xctrunner`, `testBundleRelativePath=__TESTHOST__/PlugIns/CanvasBridgeUITests.xctest`다. 이는 새 runner 생성 권한이나 실제 identity 관측을 대신하는 자가 선언이 아니다. 부모가 기존 설치의 정확한 readback으로 준비해야 한다.

`deployment.json`도 정상 `bundleIdentifier=com.ambrion.sillcanvas.ipad`, `configuration=Debug`, `sourceReadbackVerified=true`와 실제 시험 UUID를 요구한다. 원본 xctestrun을 수정하지 않고 `ExistingRunner.xctestrun`만 만든다. 실제 검증은 정확한 요청 method가 한 번 실행·통과했는지 xcresult까지 확인한다. 기존 runner에 없는 새 test method를 빌드·설치해서 보충하지 않는다. 기존 UI accept/harness gate는 유지한다. deploy-prepared는 정상 설치와 격리 source readback만 담당하며 이 UI 검사를 자동 실행하지 않는다. 일반 정상 실행 복귀도 부모의 명시 단계로 남긴다.

공식 로컬 근거는 `/Applications/Xcode.app/Contents/Developer/usr/share/man/man5/xcodebuild.xctestrun.5`의 destination artifacts 절이다. legacy 빌드는 정상 후보 경로로 전환하지 않는다. 새 경로는 부모가 이미 준비한 signed artifact를 읽고, 현재 설치 build보다 높은 버전과 실제 owner bootstrap identity를 검사하며 metadata를 바꾸거나 재서명하지 않는다.

## 준비된 정상 artifact 설치

```sh
python3 -B Scripts/ipad-test-runtime/adapter.py deploy-prepared --config PRIVATE_JSON
```

실행은 부모가 lease와 공유 기기·미디어 구간을 조율한 뒤 수행한다. 이 단위에서는 실행하지 않았다. `repo`는 clean 공식 integration이고 기존 source guard를 통과해야 한다. `outputRoot`는 기존 storage-route 외장 하위 경로다. 일반 설정의 deviceUDID/developmentTeam/leaseFile/relayHost/relayPort 외에 다음 입력을 요구한다.

- `preparedArtifact`: 부모가 이미 서명한 정상 Sill.app. 이 함수는 빌드·재서명·Info.plist 갱신을 하지 않는다.
- `preparedArtifactReceipt`와 `preparedArtifactReceiptSHA256`: 부모 빌드/검사 원본 영수증과 정확한 파일 SHA.
- `installedIdentityReceipt`와 `installedIdentityReceiptSHA256`: 현재 설치와 기존 서명·entitlement의 부모 readback 영수증과 SHA.
- `preparedContext`와 `preparedContextSHA256`: 기존 격리 relay의 준비된 시험 context 파일과 SHA. 함수가 인증 token이나 relay 서버를 새로 만들지 않는다.
- `ownerBootstrapProfile`와 `ownerBootstrapSHA256`: 위 승인된 실제 공개 리소스와 SHA.

artifact 영수증 schema는 `ccr.signed-ipad-artifact/v1`이다. commit/tree, bundleIdentifier, team, build, configuration, ownerBootstrapSHA256, entitlementsSHA256, files, manifestSHA256, buildSettings를 포함한다. files는 app 하위 모든 regular file의 상대 경로→SHA mapping이며 symlink는 거부한다. manifestSHA256은 files의 UTF-8 canonical JSON(sort_keys=True, separators=(',', ':'), ensure_ascii=False)의 SHA다. entitlementsSHA256은 실제 codesign에서 추출한 plist를 `plistlib.dumps(sort_keys=True)`로 직렬화한 SHA다.

buildSettings는 CONFIGURATION=Debug, SWIFT_ACTIVE_COMPILATION_CONDITIONS 배열의 DEBUG, PRODUCT_BUNDLE_IDENTIFIER, DEVELOPMENT_TEAM, CURRENT_PROJECT_VERSION을 포함한다. signed executable과 이 부모 빌드 증거를 같은 artifact manifest로 묶는다. metadata에 Debug라고 적었다는 이유만으로 임의 Release artifact를 허용하지 않는다. source commit/tree와 source identity verified가 signed Info와도 일치해야 한다.

코드 서명은 strict 검증과 Apple anchor/정상 identifier/Team requirement를 확인한다. 실제 entitlements의 application identifier·team·get-task-allow를 대조하며 embedded provisioning의 서명 해석·Team·만료·기기 등록·app/keychain 허용 범위도 검사한다. keychain을 읽거나 복사하지 않고, 기존 보안 entitlement map과 비교해 get-task-allow 이외 변경을 거부한다. 새 인증서·프로파일·페어링·권한을 만들지 않는다.

현재 설치 영수증 schema는 `ccr.ipad-installed-identity/v1`이다. signingReadbackVerified=true, deviceUDID, deviceIdentifier, bundleIdentifier, team, build, ownerBootstrapSHA256, securityEntitlements와 metadataSHA256을 요구한다. securityEntitlements는 기존 서명 entitlement 전체에서 get-task-allow만 제외한 map이다. 값의 본문을 출력하지 않는다. metadataSHA256은 현재 devicectl info apps의 정상 앱 row를 위 canonical JSON 형식으로 직렬화한 SHA다. 실제 현재 metadata와 영수증이 맞아야 하며 후보 build는 현재 build보다 엄격하게 커야 한다. 과거 normal68 영수증을 최신 설치 참조로 대신 넣으면 거부된다.

시험 context는 기존 `ccr.ipad-test-context/v1` schema, exact source, UUID, private IPv4의 8793 relay와 준비된 test token을 가진다. 사용자 실사용 relay 8791은 허용하지 않는다. 원본 context 내용이나 token을 stdout·일반 로그에 남기지 않는다.

흐름은 로컬 artifact/서명 검증 → 현재 앱 metadata/보호 파일/전체 Documents·Preferences snapshot → private artifact 사본과 동일 SHA 검증 → 직전 lease/source/입력·상태 재검사 → 시도 영수증 원자 기록과 fsync → 정상 bundle install → 새 metadata/기존 사용자 바이트 대조 → UUID context/state만 앱 컨테이너에 복사 → --ccr-test-runtime launch → source/executable/build/launch PID/실제 실행 경로 대조 → 최종 사용자 바이트와 새 metadata 대조다. 실제 쓰기는 설치와 UUID 시험 경로에 한정한다. 원본 폴더 초기화·keychain 접근·정상 실행은 하지 않는다.

`prepared-install-attempt.json`이 있으면 같은 의도를 자동 재설치하지 않는다. 결과 불명확·설치 후 데이터 변화·runtime 불일치는 held로 보존하며 자동 rollback, 버전 내림, 앱 삭제, 일반 Sill launch를 하지 않는다. 결과는 `normalReturnRequired=true`, `functionalAcceptance=false`다. 부모가 미디어·포커스 구간을 확보해 정상 복귀를 명시적으로 수행해야 한다.

PreparedInstallContract는 완전한 fixture가 실제 install/격리 launch 명령을 생성하는 경로와 사전조건 실패·중간 입력 변조·설치 결과 미확인·설치/격리 후 데이터 변화·잘못된 runtime/PID 경로의 차단을 검사한다. commands와 devicectl copy는 mock이며 실기기 성공을 뜻하지 않는다.
