# Core Renderer peer 검증

`ProviderPeerPolicy.core`는 `/Applications/Obsidian.app`의 main과 정확한 경로의 `Obsidian Helper (Renderer).app`만 허용한다. Renderer의 식별자는 `md.obsidian.helper.Renderer`이며 Team은 부모와 같은 `6JSW4SJWN9`다. 다른 Helper를 허용하는 접두사 규칙은 없다.

Renderer를 선택하면 canonical 부모 앱의 경로와 `md.obsidian` 식별자, Team, strict 서명을 검증한다. 실제 연결의 audit token에서 얻은 동적 코드에도 strict 요구사항을 적용하고 설치된 Renderer의 strict 서명과 CDHash를 대조한다. 검증 마지막의 audit token, 동적 서명, 소켓 생존 검사도 유지한다. PID는 검증 결과에만 기록한다.

`ProviderPeerPolicy(application:identifier:team:)` 호출과 `.installed`의 경로·식별자·Team은 유지한다. 추가된 `renderer` 인자는 기본값이 `nil`이다. 반환 스키마는 1이며 Renderer를 검증하면 `application`과 `bundleIdentifier`가 실제 Renderer를 나타낸다. Host의 기존 심볼릭 링크는 같은 원본을 사용한다. 소켓 소유권, endpoint 모드, fd 복제·잠금과 기한은 기존 `ProviderCallSocket` 코드가 담당한다.

## 실제 Core의 데이터 없는 검사

`actual.py --output 승인된_보관경로 --expected verified`는 로컬 SDK로 작은 probe만 컴파일한다. 연결 전에 `lsof`, UID, 디렉터리 `0700`, 소켓 `0600`을 확인하고 연결 뒤에도 같은 inode와 listener인지 확인한다. `ActualCore.swift`는 같은 연결에서 OS audit peer와 서명 정보, Core 판정, 잘못된 정책 5개의 거절을 읽고 소켓을 닫는다. 소켓에는 바이트를 보내지 않는다. 출력 JSON은 파일과 stdout에만 기록한다.

실제 probe의 양성은 Core peer predicate의 양성이다. 서명된 Host 설치·통화·음성·키·AX·UI 수용을 증명하지 않는다. 실제 앱의 디스크 코드와 서명은 변경하지 않는다.

## Mini 격리 검사

`mini-ephemeral-source run --source 작업트리 --owner 원담당 --job core-peer-checks -- python3 Tests/checks/provider-core-peer/run.py`로 실행한다. 전체 SDK 빌드는 별도 작업 키에서 `xcrun swift build --target ProviderPeerVerifier`로 수행한다.

`Checks.swift`의 20건은 실제 소켓 syscall과 결정적 Security API 대역을 사용한다. 생산 원본의 Security import를 대역으로 바꾸고 `getsockopt`만 fault 주입 wrapper로 바꾼다. strict 검증 호출, Renderer와 main, 기존 custom policy, 부모의 식별자·Team·서명·경로, CDHash 교체, 토큰 변경, fd 교체와 peer 종료를 검사한다. 서명 대역의 양성을 실제 서명 수용으로 표시하지 않는다.

`NativeChecks.swift`의 4건은 수정 없는 생산 원본과 실제 Security.framework를 사용한다. 익명 프로세스가 Core 또는 Sill로 수용되지 않는지, 종료된 소켓과 잘못된 fd를 거절하는지 검사한다. 기존 `provider-peer-anchor/fixture-verifier.swift`도 수정 없이 컴파일한다. 서명 키를 사용하지 않는다.

Mini에 Git checkout을 만들지 않으며 한시적 사본의 부재는 도구의 `cleanup_verified` 영수증으로 확인한다. 이 결과는 exact 파일 SHA에 대한 독립 검사다. `codex-source-guard`의 원격 Git 동일성 수용이나 설치된 Host 수용으로 확대하지 않는다. 독립 검수, 공식 통합과 공유 호스트 반영은 부모 담당이 수행한다.
