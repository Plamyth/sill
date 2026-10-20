# 호스트 소스 선택의 자동 복원 검사

Pstack Bug fix 절차로 생산 수신부의 메타데이터 유실과 캡처 대기 중의 잘못된 확정을 먼저 재현했다.
Ponytail 최소성에 따라 iPad `4f681c1`의 `SourceRequest` DTO, 기존 ingress ticket, 기존 대기 큐와 `SourceSelectionAdmission`을 재사용한다.
새 선택 원장이나 프로토콜 번호는 없다. 독립 검수와 통합은 부모 담당의 후속 단계다.

자동 요청은 `selectionOrigin=automatic`과 원래 `selectionRevision`을 포함한다. revision은 호스트의 `launchID:sourceRevision`이며 실제 선택 변화와 ABA에서 바뀌고 동일 소스 재시작에서는 유지된다.
수신 시 원래 revision을 발행된 revision 및 실제 revision의 거울과 비교한다. 미완료 예약이 있으면 자동 요청을 거부한다.
사람과 Dock의 새 예약은 기존 ticket을 선점하며, 완료와 peer 종료는 자기 미완료 예약만 해제한다.
자동 복원은 현재 선택이 `.none`일 때만 허용한다. 최종 확정은 기존 ingress lock 안에서 ticket, 원래 revision, 빈 선택 및 연결 상태를 다시 확인한다.
메타데이터 없는 기존 enum 요청은 사람 입력으로 처리하며 Dock 전용 암호화 권한을 요구하지 않는다.

다음 명령으로 외장 출력 경로를 확인한 뒤 실행한다. 각 실행에는 비어 있는 하위 경로를 사용한다.

```sh
/Users/ambrion/.local/bin/storage-route path development-archive --project CCR-Vision
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B Tests/checks/source-selection-admission/run.py "$PWD" /Volumes/BT-Workspace/Development-Archives/CCR-Vision/host-native-dock-20261021/pipeline-checks/source-admission-final
```

검사는 기존 pipeline fixture의 비활성 어댑터를 재사용한다. 실제 생산 `selectSource` 수신 분기, 대기·완료 처리, admission, `select`, `startPipeline`과 ingress를 컴파일하고 실행한다.
active observer에서는 revision 증가와 ingress 거울 전달 부분만 추출한다. 기존 Dock factory 추출 marker는 한 곳으로 유지한다.
맥북 로컬 실행은 실제 설치된 macOS SDK와 지정 워크트리의 정확한 생산 소스를 확인하기 위한 것이다.
실제 OS 캡처·AX·오디오·HAL·기기·설치·서비스·정본 통합은 실행하지 않는다. 이 검사는 해당 동작의 수용 증거가 아니다.

`result.json`은 실행 명령과 종료 코드, source commit/tree, 작업트리 상태, 입력 파일 SHA-256, 개별 결과와 실행 전후 불변성을 남긴다.
실패 재현 영수증은 `pipeline-checks/source-admission-red/result.json`에 있다. 기존 nativeDock·reader·rollback 검사 파일은 수정하지 않는다.
