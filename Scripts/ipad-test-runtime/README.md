# iPad 단일 정상 앱 테스트 경로 준비

legacy **deploy와 저수준 install은 계속 held**다. 부모가 준비한 정상 서명 Debug artifact에 한정한 `deploy-prepared`는 실제 사전조건을 검사하고 통과하면 같은 정상 bundle 설치와 격리 실행까지 진행한다. `accept`와 harness는 이 배포의 exact artifact·source·시도 영수증·최신 runtime/PID/metadata 및 기존 runner 이력이 확인될 때 기존 수용 core에 진입한다. 누락·불일치는 구체 사유와 종료 코드 2로 반환한다. 임의 override나 새 runner/app을 설치하는 fallback은 없다. 기존 진단 앱이나 XCTest runner를 삭제하지 않는다.

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

legacy CLI의 사전 차단과 준비 증거가 없는 accept/harness의 무부작용 종료를 검사한다. 정상 준비 fixture는 실제 production 사전검사 함수를 거쳐 install/격리 launch/test-without-building 명령과 xcresult 확인에 도달한다. source/metadata/서명/입력 변조, runner 미설치 이력·없는 method는 거부한다. core 검사는 실제 임시 파일의 CAS·scene/asset/note SHA·사용자 바이트·UUID 정리까지 확인하고, 이미 개별 검증하는 rotation/comment/review 하위 흐름만 별도 fixture로 격리한다. 명령·기기 copy/HTTP 경계는 mock이다. 순수 xctestrun 변환·xcresult parser 시험에서만 사전검사 의존성을 mock하며 운영 우회 옵션은 없다. native Debug 검사는 실제 flagged context와 잘못된 context에서 일반 defaults 읽기/쓰기를 실패시키는 객체를 전달하고, 격리 설정 저장→새 Store 재열기와 비어 있지 않은 전체 Preferences fixture의 바이트 불변을 확인한다.

기존 descriptor·release 등록은 그대로이며 이 후보를 testAccepted로 승격하지 않는다. 기존 진단 앱 강제 제거, 새 앱·runner 설치, 실기기 조회·Host·오디오·키·권한·계정 변경은 하지 않는다.

## 기존 normal68 보존 절차의 재사용

`normal68-device-20261026/normal68-install-preservation.json`, `normal68-observation.json`, `normal68-post-reconnect-preservation.json`, `normal68-preferences-delta.json`을 읽기 전용으로 확인했다. 당시 정상 설치의 보호 파일·note recovery·Preferences 바이트 보존과 재연결 뒤 `Sill.savedMacs.infoIssuedAt` 변경 관측은 과거 세대의 구체 근거다. snapshots의 원본별 byte hash와 metadata 분리를 이번 소스에 재사용했다. 이 timestamp 변화를 일반적인 Preferences 변경 허용으로 확장하지 않으며 최신 후보는 최신 before/after와 정확한 설치 버전·원본 bundle/team을 다시 확인해야 한다.

## 기존 runner만 사용하는 준비 입력

`existingXctestrun`/`existingXctestrunSHA256`, `existingRunnerReceipt`/`existingRunnerReceiptSHA256`가 필요하다. runner 영수증은 `ccr.known-installed-runner/v1`이며 `lineage`에 아래 `ccr.known-installed-artifact/v1` 참조를 넣는다. 로컬 runner의 서명·executable hash·설치 명령·설치 후 metadata와 최신 `devicectl device info apps --bundle-id …` metadata를 대조한다. `installed=true` 자가 선언을 입력으로 사용하지 않는다. 실제 보존 test binary를 nm/swift-demangle로 읽고 요청 method가 있는지도 검사한다.

가장 가까운 보존 입력은 `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/normal68-device-20261026/HarnessDerivedData/Build/Products/CanvasBridge_iphoneos27.0-arm64.xctestrun`이다. runner는 `com.ambrion.rea.appaudit.UITests.xctrunner`, 상대 test bundle은 `__TESTHOST__/PlugIns/CanvasBridgeUITests.xctest`다. 원 project의 `com.ambrion.rea.appaudit` 대상 경로는 파생 run에서 제거하고 정상 Sill bundle을 지정한다. 로컬 보존 binary의 서명과 22개 method를 실제 확인했다. `harness-build-result.json`은 `installed=false`인 빌드 근거이므로 runner 설치 이력으로 쓰지 않는다. 이후 보존 xcresult에서 공식 Xcode 설치·실행 이력과 10월28일 inventory의 동일 URL을 연결했다. 아래 Xcode 전용 분기를 사용하며 devicectl install JSON으로 꾸미지 않는다. 현재 기기 설치내용은 별도로 대조한다.

`deployment.json`은 정상 Debug 배포의 artifact manifest, 보호 baseline, 설치 후 metadata hash, source와 UUID를 묶는다. accept/harness는 원 signed artifact와 staged 사본 및 준비 context의 고정 SHA를 재검사하고 최신 앱 metadata·실행 PID/경로·runtime hash를 읽는다. 원본 xctestrun을 수정하지 않고 `ExistingRunner.xctestrun`만 만든다. 실제 검증은 정확한 요청 method가 한 번 실행·통과했는지 xcresult까지 확인한다. 기존 runner에 없는 새 method를 생성하지 않는다. fixture 교체 전에는 확인한 격리 PID만 중지한다. 정상 앱의 다른 PID가 보이면 중지·교체하지 않는다. 시험 state가 비워져 runtime.json이 없어진 경우에는 직전 중지 영수증과 최신 PID 부재를 함께 확인한 뒤 기존 runner로 다시 연다.

`accept`는 기존 source guard·release contract·native/vault/CAS/역방향/rotation/comments/review/xcresult/readback/보호 snapshot/fixture cleanup 검사를 유지한다. `deploy-prepared`는 설치와 격리 source readback만 담당하며 이 UI 검사를 자동 실행하지 않는다. 일반 정상 실행 복귀는 부모의 명시 단계다.

준비된 8793 relay를 빌리려면 `existingRelayReceipt`/`existingRelayReceiptSHA256`를 지정한다. schema `ccr.existing-ipad-test-relay/v1`의 필드는 testId/address, 기존 lifecycle의 leaseId/owner/serviceId/generation/pid/birth, vault, encoder/encoderSHA256/encoderSourceCommit, configurationPath/configurationSHA256다. 이것은 기존 lease와 설정 파일의 pinned 참조이며 별도 서비스 원장이 아니다. authoritative lease의 현재 process/birth/만료·8793 listener, source generation과 argv의 기존 relay.js/설정 경로, private config의 vault/token/host/port/relayRepo 및 시험 소유 store/snapshot/hidden/audit 경로를 대조한다. vault는 `work/isolated-vault/UUID`여야 하고 외부 symlink는 거부한다. 기존 encoder의 exact source/hash와 ready 응답도 요구한다. 서버 start/renew/release는 하지 않으며 cleanup은 기존 relay를 보존하고 이 UUID vault와 기기 state만 비운다. 준비된 서버가 이 namespace를 사용하지 않으면 부모가 기존 공유 구간에서 준비해야 하며 worker가 새 서버로 대체하지 않는다.

공식 로컬 근거는 `/Applications/Xcode.app/Contents/Developer/usr/share/man/man5/xcodebuild.xctestrun.5`의 destination artifacts 절이다. legacy 빌드는 정상 후보 경로로 전환하지 않는다. 새 경로는 부모가 이미 준비한 signed artifact를 읽고, 현재 설치 build보다 높은 버전과 실제 owner bootstrap identity를 검사하며 metadata를 바꾸거나 재서명하지 않는다.

## 준비된 정상 artifact 설치

```sh
python3 -B Scripts/ipad-test-runtime/adapter.py deploy-prepared --config PRIVATE_JSON
```

실행은 부모가 lease와 공유 기기·미디어 구간을 조율한 뒤 수행한다. 이 단위에서는 실행하지 않았다. `repo`는 clean 공식 integration이고 기존 source guard를 통과해야 한다. `outputRoot`는 기존 storage-route 외장 하위 경로다. 일반 설정의 deviceUDID/developmentTeam/leaseFile/relayHost/relayPort 외에 다음 입력을 요구한다.

- `preparedArtifact`: 부모가 이미 서명한 정상 Sill.app. 이 함수는 빌드·재서명·Info.plist 갱신을 하지 않는다.
- `preparedArtifactReceipt`와 `preparedArtifactReceiptSHA256`: 부모 빌드/검사 원본 영수증과 정확한 파일 SHA.
- `installedIdentityReceipt`와 `installedIdentityReceiptSHA256`: 기존 설치 artifact 이력 참조와 정확한 파일 SHA. 아래 schema를 따른다.
- `preparedContext`와 `preparedContextSHA256`: 기존 격리 relay의 준비된 시험 context 파일과 SHA. 함수가 인증 token이나 relay 서버를 새로 만들지 않는다.
- `ownerBootstrapProfile`와 `ownerBootstrapSHA256`: 위 승인된 실제 공개 리소스와 SHA.

artifact 영수증 schema는 `ccr.signed-ipad-artifact/v1`이다. commit/tree, bundleIdentifier, team, build, configuration, ownerBootstrapSHA256, entitlementsSHA256, files, manifestSHA256, buildSettings를 포함한다. files는 app 하위 모든 regular file의 상대 경로→SHA mapping이며 symlink는 거부한다. manifestSHA256은 files의 UTF-8 canonical JSON(sort_keys=True, separators=(',', ':'), ensure_ascii=False)의 SHA다. entitlementsSHA256은 실제 codesign에서 추출한 plist를 `plistlib.dumps(sort_keys=True)`로 직렬화한 SHA다.

buildSettings는 CONFIGURATION=Debug, SWIFT_ACTIVE_COMPILATION_CONDITIONS 배열의 DEBUG, PRODUCT_BUNDLE_IDENTIFIER, DEVELOPMENT_TEAM, CURRENT_PROJECT_VERSION을 포함한다. signed executable과 이 부모 빌드 증거를 같은 artifact manifest로 묶는다. metadata에 Debug라고 적었다는 이유만으로 임의 Release artifact를 허용하지 않는다. source commit/tree와 source identity verified가 signed Info와도 일치해야 한다.

코드 서명은 strict 검증과 Apple anchor/정상 identifier/Team requirement를 확인한다. 실제 entitlements의 application identifier·team·get-task-allow를 대조하며 embedded provisioning의 서명 해석·Team·만료·기기 등록·app/keychain 허용 범위도 검사한다. keychain을 읽거나 복사하지 않고, 기존 보안 entitlement map과 비교해 get-task-allow 이외 변경을 거부한다. 새 인증서·프로파일·페어링·권한을 만들지 않는다.

설치 참조 schema는 `ccr.known-installed-artifact/v1`이다. `artifact`(보존 app 경로), `artifactManifestSHA256`, `signingReadbackPath`/`signingReadbackSHA256`, `installRecordPath`/`installRecordSHA256`, `metadataPath`/`metadataSHA256`를 요구한다. manifest는 위 files map의 canonical digest다. signing readback의 CFBundleIdentifier/CFBundleVersion, executableSHA256, entitlements, signatureValid를 실제 app의 codesign·Info·binary와 대조한다. 정상 앱은 기존 CCRSourceCommit/Tree/IdentityVerified와 bootstrapSHA256도 일치해야 한다. install JSON의 성공 outcome·정확한 UDID·동일 보존 app 경로, 설치 결과 URL과 당시 metadata의 단일 bundle/build를 연결한다. 최신 metadata의 row canonical hash와 deviceIdentifier도 같아야 한다. 후보 build는 현재 build보다 엄격하게 커야 한다.

서명 entitlement는 **로컬 artifact에서 직접 계산**하고 get-task-allow만 제외해 후보와 비교한다. 실제 normal68에는 명시적 keychain-access-groups가 없으며 누락을 새 group 생성으로 보충하지 않는다. `signingReadbackVerified=true`나 부모가 작성한 securityEntitlements map을 설치 참조 입력으로 받지 않는다. 증거 종류는 `known-installed-artifact-lineage`, `remoteSignatureReadback=false`다. 최신 기기 서명 바이트를 직접 추출했다는 주장이 아니다. devicectl apps metadata에는 전체 entitlements가 없으므로 해당 명령으로 서명 검증을 대체하지 않는다.

로컬 실제 검사는 보존된 `build68-20261026/.../Sill.app`, `signed-source-readback.json`, `normal68-install.json`, `normal68-after-install-before-launch-installed-user-app.json`의 pinned SHA를 production validator에 전달해 수행했다. Apple requirement는 파일명 해석을 피하도록 `=anchor …` 리터럴로 전달하며 실제 codesign 통과와 mock 명령 검사를 구분한다. 공개 profile/서명/metadata의 과거 연결 확인은 최신 기기 설치/원본 보존 수용을 대신하지 않는다.

시험 context는 기존 `ccr.ipad-test-context/v1` schema, exact source, UUID, private IPv4의 8793 relay와 준비된 test token을 가진다. 사용자 실사용 relay 8791은 허용하지 않는다. 원본 context 내용이나 token을 stdout·일반 로그에 남기지 않는다.

흐름은 로컬 artifact/서명 검증 → 현재 앱 metadata/보호 파일/전체 Documents·Preferences snapshot → private artifact 사본과 동일 SHA 검증 → 직전 lease/source/입력·상태 재검사 → 시도 영수증 원자 기록과 fsync → 정상 bundle install → 새 metadata/기존 사용자 바이트 대조 → UUID context/state만 앱 컨테이너에 복사 → --ccr-test-runtime launch → source/executable/build/launch PID/실제 실행 경로 대조 → 최종 사용자 바이트와 새 metadata 대조다. 실제 쓰기는 설치와 UUID 시험 경로에 한정한다. 원본 폴더 초기화·keychain 접근·정상 실행은 하지 않는다.

`prepared-install-attempt.json`이 있으면 같은 의도를 자동 재설치하지 않는다. 결과 불명확·설치 후 데이터 변화·runtime 불일치는 held로 보존하며 자동 rollback, 버전 내림, 앱 삭제, 일반 Sill launch를 하지 않는다. 결과는 `normalReturnRequired=true`, `functionalAcceptance=false`다. 부모가 미디어·포커스 구간을 확보해 정상 복귀를 명시적으로 수행해야 한다.

PreparedInstallContract는 완전한 fixture가 실제 install/격리 launch 명령을 생성하는 경로와 사전조건 실패·중간 입력 변조·설치 결과 미확인·설치/격리 후 데이터 변화·잘못된 runtime/PID 경로의 차단을 검사한다. commands와 devicectl copy는 mock이며 실기기 성공을 뜻하지 않는다.


## 공식 Xcode runner 설치 이력 분기

`ccr.known-installed-artifact/v1`에 `installEvidenceKind=xcode-xcresult`를 넣으면 runner 전용 분기로 검증한다. 정상 Sill 설치 참조와 기존 devicectl 분기는 그대로다. 이 분기에는 fake installRecord/signingReadbackVerified 입력이 없다. 로컬 서명은 매번 직접 검증하며 `remoteSignatureReadback=false`를 유지한다.

최상위 입력은 artifact/artifactManifestSHA256, metadataPath/metadataSHA256이며 `xcode`에는 다음 필드를 넣는다.

- xcresultPath/xcresultManifestSHA256: 원본 보존 xcresult의 모든 regular file map을 canonical digest로 고정한다.
- invocationLogPath/invocationLogSHA256/invocationSHA256: 원본 Xcode stdout 파일 SHA와 유일한 xcodebuild argv를 shlex로 읽은 문자열 배열의 canonical digest다. exact test-without-building·UDID·method·결과 bundle 경로를 대조한다. 원본 xctestrun의 과거 실행 당시 SHA를 새로 추정하지 않는다.
- actionSHA256/sessionSHA256: 원본 xcresult에서 공식 xcresulttool로 다시 읽은 action JSON의 canonical digest와 export diagnostics의 유일한 Session-CanvasBridgeUITests 로그의 raw SHA다. 별도의 임의 JSON을 action 입력으로 받지 않는다.
- method: 이력을 연결하는 실제 단일 Passed method. 보존 사례는 testReviewReopen이다.
- compiledTestsSHA256: 설치 이력에 연결된 local signed runner 안의 실제 test binary SHA다.

validator는 action의 유일한 설치 group에서 성공 result/exitCode와 Successfully installed, 같은 group의 runner launch·AppInstallationResult·remote URL을 검증한다. 실제 testDetails.runnablePath와 local artifact는 samefile로 대조한다. Session 로그의 local bundle mapping과 기기 testBundleURL도 같은 경로여야 한다. summary는 전체 실행 1개·Passed 1개·실패/skip/expected failure 0개여야 하고, 기존 actual_xcresult의 exact method/단일 configuration/device 및 UDID 검사도 통과해야 한다. 보존 metadata의 공식 apps 명령/UDID/성공·bundle/build/URL도 연결한다.

현재 지원 대상은 formal-runtime/3e2bfd…의 실제 설치 이력과 연결된 21-method runner다. normal68의 별도 22-method artifact와 SHA가 다르다. 현재 accept core의 필수 16개를 모두 확인하며, testReviewSelectedGrade는 이 runner에 없다. 요청하면 최신 기기 metadata 조회 전에 `existing_runner_method_unavailable:testReviewSelectedGrade`로 거부한다. 새 method·runner 업데이트로 보충하지 않는다.

`xcode-runner-lineage.json`에는 artifact/xcresult/호출/action/session/compiled binary의 pinned SHA, 사용 가능한 method, wrapper/test bundle의 Xcode·SDK 값과 실제 로컬 도구 버전을 기록한다. 제품 기능의 source identity는 기존 정상 Sill 실행 executableSHA256·commit/tree/runtime readback이 정본이며 runner 증거로 대체하지 않는다.

부모의 다음 lease에서 공식 `devicectl device info apps --device <동일 UDID> --bundle-id com.ambrion.rea.appaudit.UITests.xctrunner --json-output <기존 증거 경로>`를 한 번 읽는다. 현재 CoreDevice identifier, 단일 runner row의 exact URL/build=1/containerAccessible=true 및 canonical SHA가 10월28일 보존 row와 같아야 한다. `verified_runner`가 이 비교를 유지한다. 증거 종류는 known-installed-artifact-lineage-from-xcode이며 현재 기기의 서명/파일 SHA 직접 추출 보장은 아니다. 다르면 held로 두고 새 설치나 자가 선언으로 보충하지 않는다.

검사 범위는 실제 보존 xcresult·로컬 codesign 읽기와 그 action/session/호출/metadata 필드의 상관관계 변조, 다른 normal68 artifact, 0 tests·복수 Passed/실행의 거부다. 도구 응답 변조 fixture는 원본 증거를 수정하지 않는다. 기기 조회·설치·GUI는 수행하지 않는다.


## Debug loader와 실제 구현 이미지 readback

`ccr.ipad-test-runtime/v1`에 `codeImages`와 `loadedCodeImagePaths`를 추가했다. 각 map의 key는 main executable 이름과, 존재할 때 `<executable>.debug.dylib`다. main의 기존 executableSHA256 필드는 유지한다. receipt는 MachO의 실제 dyld 이미지 목록에서 같은 파일 identity(device/inode)가 로드됐는지 확인한 뒤 해당 파일 바이트의 SHA와 실제 로드 경로를 기록한다. dylib 파일이 존재하지만 로드되지 않았거나 읽을 수 없으면 receipt를 갱신하지 않는다.

prepared 경로는 부모가 최종 서명한 app manifest에서 같은 image 집합과 SHA를 계산하고 runtime readback의 exact map·설치 URL 아래 실제 로드 경로를 대조한다. deployment에는 그 map과 canonical codeImagesSHA256을 보존하고 runtimeId에도 map digest를 쓴다. 재진입 및 최종 accept readback에서도 재검사한다. main loader가 같은 다른 구현 dylib, 빠진/추가 image, 다른 로드 위치 및 새 필드 없는 old runtime/deployment는 명시적으로 held다. 조용히 main-only 검증으로 fallback하지 않는다. dylib 자체가 없는 빌드는 명시적인 main-only map과 실제 로드 경로를 요구한다.

이 새 필수 readback은 prepared 후보에 적용한다. 기존 실제 signed68의 known-installed 설치 이력 참조에 새 runtime 필드를 요구하거나 과거 source를 새 검증 통과로 바꾸지 않는다. unsigned build4의 Info/버전을 수정하거나 설치 후보로 삼지 않는다. 부모가 최종 통합 후 실제 설치68보다 높은 CURRENT_PROJECT_VERSION으로 정식 Xcodebuild·서명을 수행하고 그 최종 signed manifest를 사용해야 한다.

NativeCodeImagesContract는 별도 Mac 명령행 fixture(정상 Sill 설치 후보가 아님)에서 실제 main/dlopen dylib의 파일 SHA·로드 경로와 실패 시 receipt 원바이트 보존을 확인하고 같은 Model을 iOS27 SDK로 typecheck한다. CanvasRuntime receipt 함수의 launchState 인자는 그 격리 fixture 주입용이며 기본은 기존 launch다. 실제 iPad 이미지/기기 readback·부모 제품 수용을 완료했다고 표시하지 않는다.
