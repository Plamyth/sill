# 제스처 지연 큐의 컨텍스트 검사

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
