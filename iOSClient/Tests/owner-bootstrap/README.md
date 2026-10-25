# iPad 소유 Mac 최초 자동 등록

Pstack Feature/how/architect 흐름에서 기존 전송과 저장 모델을 재사용했다. ARENA는 사용자 지시로 사용하지 않았다. Ponytail full에 따라 공통 `OwnerMacBootstrap`, 기존 `DeviceIdentity`, 순차 `RemoteConnector`, `SavedMacs`, `rememberPreferredMac`과 `dialSaved`를 연결하며 별도 서명키나 인증 프레임워크를 추가하지 않았다.

## 계약과 공유 호출면

- `OwnerBootstrapState.arm`: `startRemote`의 저장 정리 전에 원시 저장 키·선호 키의 부재와 기록 부재를 확보한다. 빈 배열·손상값·비문자열 키도 기존 저장소다. `knownMissing` 정리, revoked/newKey, 선호 오류는 최초 자격을 만들지 않는다.
- `OwnerBootstrapState.begin/exchange/finish/cancel/foreground`: 등록 세대와 준비·진행·종료를 제어한다. 준비 상태의 background는 대기하고 foreground에서 이어간다. 진행 중 취소는 소켓을 닫고 늦은 저장을 막는다. 전송 실패·비활성화는 다음 foreground 또는 재실행에서만 새 세대를 허용한다. 사용자 명시취소·다른 연결 선택은 `stopped`로 구분해 같은 앱 실행의 foreground에서는 되살리지 않으며 재실행에서만 최초 자격을 다시 평가한다. 소비 표시를 영속 저장하지 않는다.
- `OwnerBootstrapState.accepts`: UIKit 없는 공통 응답 검증이다. 실제 협상 `sill-owner/1`, profile peer pin, 성공, 같은 method/macID, canonical 32-byte recognitionKey, proof 부재를 요구한다.
- `RemoteConnector.Mode.ownerBootstrap(pin:)`: 기존 순차 dial, TCP timeout와 취소를 사용하고 owner ALPN과 실제 peer pin을 확인한다. 기존 session/code/QR ALPN 및 HMAC 교환은 유지한다.
- `OwnerBootstrapExchange`: winner의 실제 연결을 별도로 소유한다. 전용 응답 deadline, 제한된 kind 20 읽기, 실제 TLS metadata 재확인, 취소와 중복 callback 억제를 수행한다. 소켓 작업은 하나의 network queue에 둔다.
- `StreamClient+OwnerBootstrap`: 앱 수명주기만 연결한다. 기존 identity를 먼저 사용하고 `knownMissing`일 때만 `loadOrCreate`를 호출한다. 잠금/권한 오류는 생성·삭제 없이 보류한다. 검증 후 profile 주소/port를 저장하고 기존 정식 세션으로 연결한다. `homeTLS=true`는 향후 plaintext downgrade 금지 정책이며 home 관측 증거가 아니다. 주소 갱신은 기존 SignedMacInfo 검증 경로가 담당한다.

호스트의 same-user, machineAuthorized, nonexpired Tailnet 증명과 실제 socket/client certificate 결합은 호스트 원담당 소유다. 클라이언트의 profile은 공개 pin 기준이며 장치에 권한을 부여하는 비밀이 아니다.

## 서명 전 공개 리소스 공급

개인 Mac 값은 저장소에 넣지 않는다. 빌드에는 승인된 외부 파일의 정규 절대 경로와 SHA-256을 전달한다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project iOSClient/Sill.xcodeproj -scheme Sill \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /승인된/작업출력/sdk-build \
  CCR_OWNER_MAC_BOOTSTRAP_PROFILE=/승인된/외부/공개프로필.json \
  CCR_OWNER_MAC_BOOTSTRAP_SHA256=승인된_SHA256 \
  build
```

`Embed owner bootstrap` 단계는 공통 `Scripts/provision-owner-bootstrap.py`를 사용해 정확한 바이트를 bundle root `CCR-OwnerMacBootstrap.json`에 넣는다. 누락·다른 SHA·4KiB 초과·secret/unknown/duplicate field·비정규 주소·심볼릭 링크·쓰기 가능한 타인 입력·다른 기존 resource는 거절한다. 다른 프로필은 새 derivedData 경로를 사용한다. `/Applications`에 직접 쓰지 않는다. 프로젝트의 bundle ID `com.ambrion.sillcanvas.ipad`와 Team `ZPTXHJ866D`를 유지한다.

이 단계는 codesign 전에 실행된다. 앱 코드서명이 리소스를 보호한다. 별도 profile 암호서명은 없다. 런타임은 `Bundle.main` 리소스만 읽으며 환경변수·UserDefaults·HTTP를 profile 공급원으로 사용하지 않는다. SDK 빌드에서 signing을 끈 경우, 별도의 실제 Apple Development 코드서명 및 `codesign --verify --strict`와 Team/bundle ID/resource SHA readback이 필요하다. SDK 컴파일과 서명은 설치 또는 실물 연결 수용이 아니다.

## 검증

```sh
python3 iOSClient/Tests/owner-bootstrap/run.py
python3 Tests/checks/owner-mac-bootstrap/run.py
python3 Tests/checks/owner-bootstrap-provision/run.py
REMOTE_DEFAULT_OUTPUT="$(storage-route path development-archive --project BT_CCR-ipad --filename remote-default-checks | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')"
python3 iOSClient/Tests/remote-default/run.py --output "$REMOTE_DEFAULT_OUTPUT"
python3 iOSClient/Tests/remote-default/policies.py --focused
python3 iOSClient/Tests/remote-default/compare.py
```

순수 검사는 Mini의 `mini-ephemeral-source run --source <이 워크트리> --owner <원담당> --job <고유검사키> -- <명령>`으로 수행한다. 영구 Git 사본 없이 기존 비교를 실행할 때에는 `git show <정확한 기준>:<입력파일>`로 export한 snapshot을 함께 전달하고 `CCR_REMOTE_BASELINE_DIR`과 정확한 `CCR_REMOTE_BASELINE_REV`를 지정한다. 비교 성공은 기존 실패 목록과 같다는 뜻이며 기존 suite 전체 통과가 아니다.

검사는 실제 startup 메서드, owner 등록/교환 구현, 수명주기 메서드와 수동 연결/새 페어링 진입부를 추출한다. 공통 프로토콜·SavedMacs·OwnerBootstrapState는 실제 소스다. 별도 검사에서는 실제 RemoteConnector를 컴파일한다. 시계·소켓·Keychain은 deterministic 대역이므로 실제 TLS, Tailnet 권한, 실기기 네트워크·Pencil·UI 수용 증거가 아니다.

## 기존 테스트 빌드 호출

일반 CI의 simulator 빌드와 unsigned TestFlight 검사는 `Scripts/owner-bootstrap-fixture.py`가 checkout 밖의 작업 디렉터리에 합성 profile을 만들고 경로·SHA를 build setting으로 전달한다. iPad 격리 테스트 adapter도 같은 생성기를 사용하며 서명 후 번들의 resource SHA를 다시 확인한다. 실제 Mac profile을 격리 빌드에 자동 주입하지 않는다.

`Scripts/release-ios.sh`와 TestFlight export/upload에는 승인된 실제 공개 리소스의 외부 경로·SHA가 필요하다. 이 경로의 과거 release script는 다른 제품의 team/bundle 검증도 포함하므로 이 작업에서 실행·수정하지 않았다. 해당 배포 담당이 정확한 앱·팀·외부 리소스 공급을 연결하기 전에는 필수 phase에서 중단된다. 합성 프로필로 운영 배포 관문을 통과시키지 않는다. CI 원격 실행과 기기 adapter 배포는 이 작업에서 실행하지 않았다.

## owner 전용 제품 UI 회귀

`python3 iOSClient/Tests/owner-bootstrap/ui.py`는 실제 iOS 정책·상태 표현·`dial`의 `.ask` 분기·`handleOpenURL` 본문을 추출해 Release/DEBUG로 컴파일한다. 11개 수동 등록 진입의 첫 guard도 실행하며, SwiftUI 연결 지점과 iPhone 공통 소스 참조는 구조 검사로 보조한다. iOS target parse는 문법 검사이며 SDK typecheck나 실제 GUI 수용이 아니다.

제품 iOS의 수동 등록 통신은 DEBUG에서도 금지한다. 기존 `mockDiscovery` 합성 화면은 레이아웃 검사를 위해 수동 UI를 표시할 수 있지만 이 정책을 바꾸지 못한다. `run.py`의 대역 `manualPairingEnabled=true`는 기존 허용 경로의 취소 계약을 검사하기 위한 주입값이다. 추가한 false 시나리오는 코드 입력과 Home/Remote 진입이 진행 중 자동 등록 교환을 취소하지 않고 정상 저장·재접속을 유지하는지 검사한다. 실제 Release 정책은 `ui.py`가 생산 소스 그대로 컴파일한다.

키·소켓·시계는 대역이다. 공유 Host·기기·키체인·등록·설치·음성·화면 조작은 실행하지 않는다. 최종 Sill/SillPhone SDK, 독립검수와 소유 커밋은 부모가 수행한다.
