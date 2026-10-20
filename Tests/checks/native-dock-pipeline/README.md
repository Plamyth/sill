# Dock 파이프라인 취소 검사

`StreamCoordinator.swift`의 `select`, `startPipeline`, `PipelineEpochError`, `epochGeometry`, `SourceSelectionAdmission`, `dockPeerIsCurrent`와 Dock admission 생성 closure를 실행 때 추출한다. 본문이나 가드를 바꾸지 않고 검사 객체 안에서 컴파일한다. `DockSelectionIngress.swift` 전체와 `Sources/StreamProtocol` 전체도 실제 소스를 컴파일한다.

`Capture`와 `SyntheticCapture`는 정수 프레임과 continuation만 다룬다. encoder, server, status, 창·화면 목록, 가상 화면과 AX 동작 경계는 메모리 객체다. `CoreGraphics`의 사각형·크기 값만 사용한다. 캡처·AX·앱·기기·서비스·오디오·HAL API를 호출하지 않는다.

실행 명령은 다음과 같다. 출력 경로는 실행기가 `storage-route`의 JSON 경로와 외장 상태를 확인한다.

```sh
python3 -B Tests/checks/native-dock-pipeline/run.py . \
  /Volumes/BT-Workspace/Development-Archives/CCR-Vision/host-native-dock-20261021/pipeline-checks/run-final
```

실행기는 실제 함수의 SHA-256, 입력 파일 전체 해시, Git 기준 commit과 tree, 컴파일·실행 명령과 종료 코드, 사례별 결과를 `result.json`에 기록한다. 추출 파일, 실행파일, 모듈 캐시와 로그는 지정한 외장 출력 디렉터리에만 쓴다. 종료 코드 `0`은 모든 동작 검사와 변이 검출의 통과, `1`은 동작 실패 또는 변이 미검출, `2`는 검사 도구·컴파일·소스 불변성 오류다. 발견한 생산 결함도 실패로 유지한다.

검사는 캡처 시작 continuation을 보류하고 실제 ingress에서 peer를 제거하거나 유효한 새 ticket을 발급한다. ingress에는 peer가 남은 상태에서 연결 객체만 `cancelled`로 바꾸는 사례도 포함한다. 카탈로그 조회 시점과 admission commit callback 직전에도 같은 무효화를 넣는다. 취소 뒤에는 source·입력 세대·epoch·encoder·전송 catalog가 확정되지 않고 양쪽 캡처와 출력 콜백이 정리되는지 확인한다. 성공 사례는 준비한 epoch와 전송 catalog의 일치, 정확히 한 번의 확정, 기존 `admission=nil` 호출과 동일 소스의 세대 유지도 확인한다.

외장에 생성한 함수 사본에서 commit 가드, 후보 정리, peer 확인 가드를 각각 제거한 세 변이도 실행한다. 기준 실행에서 통과한 지정 취소 사례가 변이에서 실패해야 검출로 센다. 생산 소스와 기존 검사는 변경하지 않는다.

Pstack의 Feature 경로를 적용했다. `how`로 실제 호출 흐름을 읽고 `Model the Domain`에 따라 취소 이유와 주입 시점을 enum으로 표현했다. `Test Behavior, Not Implementation`과 `Prove It Works`에 따라 확정 결과와 정리 결과를 실행해서 비교한다. Ponytail은 기존 실제 타입과 Python·Swift 기본 기능을 재사용하는 데 적용했다.

진행 절차와 분업 범위는 다음과 같다.

- [x] 선행 조건으로 지정 branch·HEAD·clean worktree와 저장 경로를 확인했다.
- [x] 실제 호출 흐름과 자료형을 읽고 단일 검사 구조를 선택했다.
- [x] 독립 작업은 별도 디렉터리의 검사 작성뿐이다. 공유 생산 파일에는 쓰지 않는다.
- [x] continuation으로 캡처 대기 시점을 제어한다. 실제 OS와의 공유 상태는 없다.
- [x] 최소 분업은 이 담당 한 명이다. 사용자 지시에 따라 ARENA와 중첩 에이전트를 실행하지 않는다.
- [x] 사용자 지시에 따라 architect의 ARENA 탐색과 하위 구현 위임을 생략하고 직접 구현했다.
- [ ] 독립 검수는 부모 담당이 수행한다. 자체 점검을 독립 검수로 세지 않는다.
- [ ] PR·병합·SDK 전체 검사·앱 실행은 부모 담당의 범위다.

`handleDockRequest`와 `focusedDockSource`의 AX 조회는 실행하지 않는다. 해당 조회 뒤의 오래된 요청이 실제 `select` 진입 가드에 거부되는 경계부터 확인한다. `listMessage`, geometry 조회, 프레임 처리, 네트워크와 상태 공개는 어댑터이므로 실제 화면·전송·SDK 전체 수용의 증거가 아니다. 커밋한 `result.json`과 `RESULT.md`에 기준 실행 결과와 생산 결함을 기록한다.
