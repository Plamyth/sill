# 제스처 지연 큐의 컨텍스트 검사

## 합성 Desktop의 빈 물리 inventory 회귀 P2

기준 생산 소스는 `3ddfd943fb1b44b07d9bc18a9e17807378feab09`이다. 사용자 인계에서 확인된 기존 **394개·0실패**는 이 기준의 이전 실행 증거로 보존한다. 이번 작성자는 이를 재실행하지 않았다. 기존 검사 본문과 단언은 유지하고 그 누적 결과를 새 합성 검사 직전에 별도로 출력한다.

Pstack Bug fix의 테스트 우선 커밋 → 최소 수정 커밋 순서를 따른다. Ponytail 재사용 원칙으로 기존 생산 함수 추출기·fixture·검사 함수만 확장한다. 사용자 지정 단일 설계를 따르며 추가 에이전트·ARENA·Goal과 설계 탐색은 수행하지 않는다. 실행·전체 앱 컴파일·서명 후보·독립 검수는 부모의 Mini 단계다.

Fixture는 `synthetic`와 빈 inventory를 주입받고 합성일 때 `gesturesDry`도 켠다. `Stats.bump`는 이름별 횟수를 기록한다. 실제 생산 수신·큐·컨텍스트·최종 chord 수행·held 재생과 `GestureChords`를 추출하여 다음을 검사한다.

- 빈 물리 inventory인 합성 Desktop에서 6종 행동 각각의 즉시 실행과 held 재생, 주입 0, `in.gestureDry`, `open/repeated`.
- 물리 inventory만 생겨도 합성 컨텍스트의 scope는 nil이고 대기 행동은 그대로 실행됨. 실제 `displaysChanged`의 토큰 무효화와 구분한다.
- 열린 상태·반복 상태를 먼저 만든 뒤 연결 종료 또는 TTL 경계 만료 시 drain·held 모두 카운터와 상태 변화 0.
- 실제 모드에서 빈 inventory이면 6종 모두 수신 거부, 주입·상태·카운터 변화 0.

기존 394개에 새 단언 100개를 추가해 총 494개가 예상된다. 이 수는 코드상 예상이며 Mini 실행 결과가 아니다. 기준은 새 합성 정상 경로에서 행동 실패, 수정본은 전체 통과가 기대된다. 파싱 성공이나 컴파일 오류를 red/green 행동 증거로 취급하지 않는다.

아래 명령은 **같은 최신 작업트리의 검사·fixture·생성기**로 생산 소스만 바꾼다. `--ref`는 생산 소스에만 적용되므로 기준 commit에 새 테스트가 없어도 비교할 수 있다. stdout은 저장 없이 파이프로 전달할 수 있고 stderr의 SHA-256으로 동일 검사 입력을 대조한다.

```sh
python3 -B Tests/checks/gesture-drain-scope/run.py --emit-only --ref 3ddfd943fb1b44b07d9bc18a9e17807378feab09
python3 -B Tests/checks/gesture-drain-scope/run.py --emit-only
```

작성 범위는 Python AST 파싱, 위 두 생성 결과와 변경 생산 파일의 `swiftc -frontend -parse`, `git diff --check`까지다. 부모는 생성 명령의 종료 코드와 Swift 파싱 코드를 각각 확인해야 하며 단순 파이프의 마지막 종료 코드만으로 생성 성공을 추정하지 않는다. Mini 행동 실행·타입검사·전체 앱 컴파일·서명 후보·독립 검수 결과는 이번 작성 범위에서 미확인이다. 기기·UI·실제 입력·오디오·HAL·설치·재시작은 수행하지 않는다.

## 창에서 Desktop으로 전환하는 순정 클라이언트의 P2 수정

이번 기준은 `22c04fd33b8c10f61432a18ec21b595afc9d0f7e`, tree `69ad10bc8a90e74034cd147ded11d137339f7029`이다. `iOSClient/StreamClient.swift`의 순정 `sendGesture`는 창 화면에서 Desktop 선택을 보낸 직후 kind 28을 보낸다. 기존 후보가 전환 중 수신을 모두 거부해 이 정상 순서를 잃었다. iOS 클라이언트와 wire 계약은 변경하지 않는다.

Pstack Bug fix의 원인 추적과 재현 검사 보강을 수행했다. `Model the Domain`에 따라 원 연결·참여·요청 당시 화면·검증 토큰·만료 시각과 실제 선택 작업 UUID를 묶는 `DesktopGestureSelection`을 사용한다. Ponytail full에 따라 기존 fence와 세대·epoch·지연 큐를 재사용하고 의존성을 추가하지 않는다. 작업의 다음 실행 병목은 부모의 Mini 타입검사와 실제 합성 실행이다. 새 하위 에이전트·ARENA·실제 UI 재현은 사용자 금지 범위다.

선택 요청은 `handleSourceSelection` → `handlePick` → `select`의 동일 티켓으로 연결한다. 파이프라인의 실제 `active`·세대·epoch 대입 직후 완료 후보를 캡처하고, 원래 선택의 defer에서 검증한 경우에만 완료한다. 대기 제스처와 마지막 `Held.chord`는 이 티켓의 완료 결과만 참조한다. 원래 선택 작업의 정상 상태 대입만 검증 토큰 변경을 허용하며, 다른 상태 변경은 ABA 복원 후에도 티켓을 취소한다. 기존 캡처·오디오·마이크 대입과 호출 순서는 유지한다.

티켓은 유휴 상태의 창 화면에서 같은 참여자가 명시적으로 요청한 Desktop 선택 하나에만 발급한다. 다른 요청·실패·취소·겹친 선택·디스플레이 변경·기존 전환·restart·원 연결 종료·재가입은 대기 제스처를 승격하지 않는다. 대기 만료는 수신 후 2초와 선택 요청 후 2초 중 빠른 시각이다. 이미 Desktop인 클라이언트는 기존 수신 시점의 컨텍스트를 그대로 보존한다.

`run.py --ref`는 지정한 Git commit의 생산 소스와 현재 작업트리의 동일 검사를 결합한다. ref는 시작 시 commit으로 고정한다. stderr에는 생산 파일·검사·fixture·생성기와 추출부의 SHA-256을 출력한다. 부모가 아래 두 stdout을 각각 Mini의 승인된 입력 스트림으로 전달해 같은 컴파일·실행 명령으로 비교한다.

```sh
python3 -B Tests/checks/gesture-drain-scope/run.py --emit-only --ref 22c04fd33b8c10f61432a18ec21b595afc9d0f7e
python3 -B Tests/checks/gesture-drain-scope/run.py --emit-only
```

추출 범위에는 실제 selectSource/selectDisplay 수신 case, 요청 처리기, 선택 wrapper, 선택 본문의 진입과 defer 완료 코드, desktop preflight, restart 중 보류한 pick 처리, 실제 파이프라인의 최종 상태 대입과 완료 캡처가 포함된다. 전체 `select`의 미디어 부작용 본문은 실행하지 않는다. `catalog.refreshWindows` 의존성을 continuation으로 멈춰 실제 선택에 진입한 뒤 kind 28을 수신한다. 검사에서 티켓·operation·완료 상태를 직접 설정하지 않는다. `Test Behavior, Not Implementation`에 따라 실제 chord 대상과 기존 open/repeated 상태를 확인한다.

새 검사는 순정 창→Desktop의 정상 수신, 완료 전 drain 대기, 완료 후 held, 선택 실패·취소·TTL, 원 참여 해제·재가입, 중첩 요청, 다른 연결·디스플레이, 세대·epoch·source·switch의 ABA, 디스플레이 ABA 알림, 이미 진행 중인 전환과 restart 뒤 보류 선택을 포함한다. 이미 Desktop인 Android 세대 1의 optional nil도 유지 검사한다. `run.py`의 설명 주석 두 개와 `Fixture.swift` 첫 설명 주석을 제거했다.

- [x] 소스에서 순정 송신 순서와 거부 지점 추적.
- [x] 실제 선택 경계와 정상·부정 경로 검사 추가.
- [x] 수정본·기존 후보·원본 068 생성 및 Swift 구문 확인.
- [x] Python AST 구문 확인과 `git diff --check`.
- [ ] 부모 Mini에서 동일 최신 검사의 기준/수정 비교 실행.
- [ ] 부모 Mini에서 전체 `SillHostCore` SDK 컴파일.
- [ ] 수정된 head의 독립 검수. Pstack의 `BLOCKED: independent review`를 유지하며 clean commit 반납을 배포·통합 승인으로 표시하지 않는다.

이 작성자는 맥북에서 생성·파싱만 수행했다. 사용자 인계에 적힌 기존 244개·후보 0실패·전체 SDK 컴파일 통과는 이전 후보의 증거이며 이번 수정의 통과 결과가 아니다. 실제 UI·입력·캡처·오디오·HAL·기기·설치·재시작·배포는 실행하지 않았다. 아래는 이전 작업의 보존 기록이다.

## 이전 지연 큐 수정 기록

원 담당은 `01a13005-ff61-7780-b0e8-6dc171de1c9d`이다. 전용 브랜치는 `codex/gesture-drain-scope-20261021`, 기준은 `068be8f4a50444716aefe86347e7ae5dfa947f5d`이다. 변경 범위는 제스처 수신, 두 지연 큐와 입력 참여 식별이다.

Pstack Bug fix 절차를 적용한다. 실행 증거는 부모가 Mini에서 생성한다. 이 구현 담당은 생성과 파싱까지만 수행한다. Ponytail full에 따라 기존 fence, 세대와 영상 epoch를 사용하고 별도 프레임워크나 wire 계약을 추가하지 않는다. 데이터 모양은 원 연결, 참여 토큰, source, desktopScope, 입력 세대, 영상 epoch, 무효화 토큰과 만료 시각을 묶은 대기 제스처다.

- [ ] 1. Reproduce it yourself on the matching surface via the driver skill (Non-negotiables).
  skip: 실제 UI 금지. 부모가 아래 생산 함수 추출 경로에서 합성 red를 실행했다. 이 구현 담당은 직접 실행하지 않았다.
- [ ] 2. Binary-search the cause.
  소스에서 연결·세대가 사라지는 첫 큐와 동작 상태를 먼저 바꾸는 held 큐를 확인했다. 부모의 원본 red 실행은 아래에 별도로 기록한다.
- [x] 3. Plan the fix.
  단독 구현 범위와 ARENA 금지를 우선한다. 기존 함수와 fence에 필요한 상태만 추가한다.
- [ ] 4. Verify on the same surface.
  수정 후 같은 합성 검사의 green 실행은 부모 담당이 수행한다.
- [x] 5. Stage the commits so the failing repro lands before the fix in git history.
  테스트 커밋 후 수정 커밋으로 분리한다. red를 실행하기 전에는 실패 확인으로 보고하지 않는다.
- [ ] 6. Run **Opening a PR**.
  skip: 이 작업은 clean 커밋 반납까지만 담당한다. PR·통합과 독립 검수는 부모 담당의 범위다.

## 생성과 파싱

전용 작업트리 루트에서 실행한다. stdout은 생성된 Swift이고 stderr는 입력 파일 및 추출부 SHA-256이다. 맥북에서는 아래 생성·파싱 명령만 사용한다.

```sh
python3 -B Tests/checks/gesture-drain-scope/run.py --emit-only --baseline | swiftc -frontend -parse -
python3 -B Tests/checks/gesture-drain-scope/run.py --emit-only | swiftc -frontend -parse -
swiftc -frontend -parse Sources/SillHost/StreamCoordinator.swift Sources/SillHost/SourceInputFence.swift
```

## 부모의 Mini 실행

원본 red는 맥북의 `--emit-only --baseline` 출력을 부모의 승인된 한시 실행 입력으로 전달한다. Mini에서 `swiftc -parse-as-library -package-name Sill - -o "$작업별_임시실행파일"`의 stdin으로 받아 컴파일하고 해당 파일을 실행한다. 원본 Git 객체를 Mini에 복사할 필요가 없다. 실패 단언과 종료 코드 1이 기대값이며, 컴파일 오류는 red 증거가 아니다. green은 같은 방식으로 `--baseline` 없이 생성한다. 부모가 한시 소스 사본을 사용하면 그 안에서 `python3 -B Tests/checks/gesture-drain-scope/run.py --run`도 가능하다. 이 생성기는 원격 연결이나 실행을 자동 시작하지 않는다. `--run`은 임시 실행 파일을 컴파일하고 실행한 뒤 자신이 만든 파일만 정리한다.

네이티브 타입검사는 부모의 한시 소스 실행 경로에서 `swift build --target SillHostCore`로 수행한다. 이 명령은 호스트를 실행하거나 설치하지 않는다. 기존 SDK·컴파일 경로의 제약은 별도로 기록한다.

생성된 원본·수정본과 생산 변경 파일은 이 구현 담당의 맥북에서 `swiftc -frontend -parse`가 통과했다. 타입검사·green 실행·독립 검수는 부모 담당의 단계이며, 파싱 결과를 그 증거로 사용하지 않는다. 별도 하위 에이전트 도구가 없어 독립 검수를 직접 완료했다고 주장하지 않는다.

## 증거와 한계

`run.py`는 생산 `TrackpadGesture`, `VideoEpoch`, `SourceInputFence`, `DisplayInventory`, `GestureChords`와 `StreamCoordinator`의 제스처 수신 case, queue/drain 콜백, 수행 함수, held 재생 함수, 관련 속성 observer를 추출한다. 생산 분기를 재구현하지 않는다. 접근 수준, enclosing type의 정적 참조와 Task 실행기만 합성용으로 교체한다. 입력·연결·키 테이블·시간·스케줄러는 부작용 없는 의존성이다. 입력 참여 join/leave는 실제 fence를 호출하는 fixture이다. 전체 네트워크 연결 콜백이나 실제 NWConnection의 스케줄링을 실행하는 검사는 아니다.

초기 테스트 준비 커밋 `a340d0b013bcdbb77e137b1d6e60012c8eb76e6f`는 부모의 Mini에서 컴파일 준비 오류가 확인됐다. red 동작 증거가 아니다. 그 실행의 정리 확인 영수증은 `/Users/ambrion/Library/Application Support/Mini Ephemeral Source/receipts/20261021T135815.140037Z-gesture-drain-scope-red-20261021.json`이다. 타입 이름, actor 전역 상태, CoreGraphics와 실행 방법을 후속 테스트 커밋에서 보완한다. 수정된 생성기의 실행 결과는 별도 영수증이 필요하다.

부모는 테스트 준비 커밋 `4f223f1c7328558f01ec6f6cf729c693323a26fd`의 불변 테스트와 원본 `068be8f4a50444716aefe86347e7ae5dfa947f5d`의 생산 소스를 Mini에서 실행했다고 전달했다. 결과는 `COMPILE_EXIT 0`, `FAIL 193 assertions, 139 failures`, `BEHAVIOR_EXIT 1`, `cleanup_verified=true`이다. 영수증은 `/Users/ambrion/Library/Application Support/Mini Ephemeral Source/receipts/20261021T140040.868245Z-gesture-drain-scope-red-20261021.json`이다. 결정적인 실패는 `drain 연결 종료 주입 없음`, `drain 연결 종료 상태 오염 없음`, `held 연결별 유효성 및 상태 격리`, `최종 단축키 조회 후 컨텍스트 취소 주입 없음`이다. 이 구현 담당의 직접 실행 결과는 아니다.

현재 후보는 scope 단독 변경, 만료 경계, 선택 ABA, 기존 open/repeated 보존과 마지막 단축키 조회 중 취소 검사를 추가했다. 부모의 원본 red 193개와 이 추가 검사의 수·실행 결과를 혼합하지 않는다. 동일 193개 경로의 수정 후 green, 현재 후보의 전체 합성 실행, 네이티브 컴파일과 독립 검수는 아직 별도 확인이 필요하다.

검사는 원 연결 종료·취소·재가입·교체, 다른 연결 유지, 세대·영상·선택·전환과 ABA, 두 큐 만료, 잘못된 이름·손가락 및 optional nil, 마지막 held 지연, 상태 오염, 기존 키 해제 순서, window 전환 후 주입 금지를 포함한다. 단축키 조회 의존성에서도 컨텍스트를 바꿔 마지막 주입 전 검증을 확인한다.

kind 28 JSON에는 송신 시점의 세대가 없다. 수신 전에 지연된 패킷이 이미 바뀐 유효 desktop에 도착하는 경합은 이 수정으로 식별할 수 없다. `gestures=1`이나 호스트 내부 토큰으로 그 경합을 해결했다고 주장하지 않는다. 이 검사는 실제 UI·입력·캡처·오디오·HAL·기기·설치·재시작·사람 수용 증거를 만들지 않는다.
