# iPad 단일 정상 앱 테스트 경로 준비

현재 adapter의 **deploy·accept·harness와 저수준 install은 held**다. CLI는 설정을 읽거나 source/device 조회·빌드·설치·relay 시작을 하기 전에 종료 코드 2와 `single_app_runtime_held` 사유를 반환한다. 이 중단을 해제하는 설정 스위치는 없다. 기존 진단 앱이나 XCTest runner를 삭제하지 않는다.

이번 단위는 소스 준비와 격리 경계 검사다. 정상 앱 설치나 실제 제품 기능 수용을 완료했다고 표시하지 않는다.

## 확인한 현재 경로

- 정상 앱 `SillApp`의 Debug `--ccr-test-runtime UUID` 분기는 `CanvasWorkspace`를 직접 열며 `ContentView`와 그 `StreamClient`를 만들지 않는다. 잘못된 context는 오류 화면으로 끝난다.
- `CanvasRuntime.resolve`는 앱의 exact commit/tree와 시험 context를 대조하고 UUID 아래 state만 허용한다. scene/recovery/checkpoint/workspace와 새 `CanvasPreferences.json`이 그 경로를 사용한다.
- `CanvasRelay.loadConnection`은 isolated에서 context 주소·token을 반환하고 invalid에서는 nil을 반환한다. 정상 Documents의 이전 연결과 keychain 읽기·이관은 그 뒤 normal 분기에 있다. 요청 역시 context의 주소·token·origin을 강제한다. 이 소스 추적을 실기기의 keychain·relay 왕복 수용으로 확대하지 않는다.
- Store의 기본 지우개 설정은 isolated에서 시험 JSON으로 읽고 쓴다. 명시적으로 넘긴 UserDefaults도 isolated/invalid에서는 사용하지 않는다. invalid는 일반 defaults로 복귀하지 않으며 손상된 시험 설정 파일도 덮지 않는다. normal에서는 기존 UserDefaults 주입과 기본 standard 경로를 유지한다.

## 정상 설치를 계속 막는 이유

1. 기존 deploy는 `com.ambrion.rea.ipad-runtime`을 만들고 버전을 1로 고정하며 합성 OwnerBootstrapFixture를 넣는다. bundle 이름만 `com.ambrion.sillcanvas.ipad`로 바꾸면 안 된다. 현재 정상 설치 버전·서명·Team `ZPTXHJ866D`·keychain entitlements를 대조하지 않은 낮은 버전 재설치는 금지한다.
2. snapshots는 일부 Application Support 파일과 설치 앱 metadata를 한 dict로 비교한다. Documents·전체 Preferences·마지막 Mac/오디오 의도 등의 전체 바이트 보호가 아니며, 정상 버전 갱신에 따른 metadata 변화와 사용자 데이터 불변을 분리하지 않는다. 새 정상 설치 후보를 수용할 근거가 아니다.
3. 정상 앱의 `SillAppDelegate.buildMenu`는 isolated 분기 밖에서도 실행될 수 있다. `MacMenuBar.build`가 먼저 `UserDefaults.standard`의 Debug 설정을 읽는다. 이 파일은 이번 쓰기 범위 밖이므로 수정하지 않았다. Store 설정 분리만으로 앱 전체의 일반 Preferences 접근 차단을 완료했다고 하지 않는다.
4. 기존 harness는 `CanvasBridge.xcodeproj`를 build-for-testing한다. UI target의 `TEST_TARGET_NAME=CanvasBridge`, PBXTargetDependency와 `UITargetAppPath`/DependentProductPaths가 prototype `CanvasBridge.app`에 연결될 수 있다. XCUIApplication의 bundle 환경값만 정상 앱으로 바꿔도 test-without-building이 prototype을 추가 설치하거나 덮을 위험은 없어지지 않는다. 기존 설치된 runner 한 개의 identity·xctestrun 전체 target/dependency·실제 설치 효과를 확인하기 전에는 실행하지 않는다.
5. Debug 격리 테스트 종료 후 플래그 없는 정상 실행으로 돌아갈 때 기존 keychain 참조·마지막 Mac·원래 연결/오디오 의도와 전체 사용자 데이터가 그대로임을 아직 검증하지 않았다. 실제 설치·정상 복귀의 공유 구간은 부모가 소유한다.

## 기존 공개 bootstrap 참조

부모가 제공한 공개 리소스는 `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/owner-mac-bootstrap-20261022/public-profile-from-ipad-saved.json`이며, SHA-256은 `7bcf8ce74bf4292d1a20b07d45bfa0c040957e1ade3d80dd4be37c5eb96cf8c7`이다. 원본을 변경하거나 키를 복사하지 않는다.

`owner_bootstrap_identity`는 후보 설정의 `ownerBootstrapProfile`과 `ownerBootstrapSHA256`를 읽기 전용으로 대조하고 기존 provisioner의 공개 schema 검사를 재사용한다. 값의 본문·인증정보는 반환하지 않는다. 이 검사는 설치나 현재 Host 일치의 승인·수용이 아니다. 정상 bundle 설치 후보는 반드시 이 승인된 실제 공개 리소스 identity와 기존 keychain 참조를 보존해야 한다. synthetic bootstrap은 미설치 단위/SDK 검사에만 허용한다. 현재 legacy deploy는 이 실제 리소스 경로에 연결되지 않아 계속 held다.

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
