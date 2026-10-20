# 실제 실행 결과와 부모 전달 사항

작업 키는 `host-dock-pipeline-checks-20261021`, 작업 branch는 `codex/host-dock-pipeline-checks-20261021`이다. 검사한 생산 소스 기준 commit은 `5f94dc61f3aa24681611826a87adfd7626dadaed`, tree는 `f39f0e47fc65f74347634e1e14aa52c777eeb6b4`다. 이 commit 뒤의 검사 커밋은 새 `Tests/checks/native-dock-pipeline`에만 파일을 추가한다.

최종 실행은 2026-10-21T05:03:49.872291+09:00부터 2026-10-21T05:04:51.778618+09:00까지였다. 도구는 Apple Swift 6.4, target은 `arm64-apple-macosx27.0.0`이다. 실제 실행 명령은 다음과 같다.

```sh
python3 -B Tests/checks/native-dock-pipeline/run.py . \
  /Volumes/BT-Workspace/Development-Archives/CCR-Vision/host-native-dock-20261021/pipeline-checks/run-admission-verified
```

36개 동작 검사 중 32개가 통과하고 4개가 실패했다. 생산 결함을 숨기지 않도록 기준 실행과 전체 실행의 종료 코드를 모두 `1`로 유지했다. 컴파일은 통과했다. 입력 파일 전후 해시가 같아 `sourceUnchanged=true`다. 원본 `result.json`을 바이트 그대로 이 디렉터리에 복사했다.

commit 가드, 양쪽 캡처 정리, 실제 Dock admission의 peer 가드를 각각 제거한 세 변이는 모두 컴파일되었고 지정 사례에서 실패했다. 기준 실행에서 같은 사례가 통과한 것도 확인했다. 따라서 변이 검출은 3개 중 3개다.

이전 P1의 늦은 확정 경계에서는 실패를 재현하지 못했다. peer 제거, ingress에는 peer가 남은 연결 종료, 새 ticket을 캡처 대기 중·Dock catalog 조회 시점·commit callback 직전에 넣어도 source, encoder, inputGeneration, videoEpoch, server.commitVideo가 확정되지 않았다. 후보 capture와 synthetic capture, 프레임·encoder 출력 콜백은 정리됐다. synthetic 경로와 실제 select 경로에서도 이를 확인했다.

유효한 요청은 같은 source와 준비한 epoch를 한 번 확정하고, 그 값과 같은 catalog를 한 번 전달했다. admission을 생략한 기존 select·startPipeline 호출과 명시적 nil의 synthetic 호출도 통과했다. 동일 source의 inputGeneration도 유지됐다. capture 시작 오류는 source를 확정하지 않고 전파되거나 select에서 처리됐다.

## 발견한 생산 결함

P2로 분류한 후보 정리 결함이다. `Sources/SillHost/StreamCoordinator.swift:1827`에서 capture.onFrame에 후보 encoder를 연결한 뒤 `1828`의 capture.start가 throw하면, `1850` 이후의 admission 거부 정리를 거치지 않고 함수를 빠져나간다. 무효화와 시작 오류가 함께 발생하는 다음 사례들이 실패했다.

- `capture-start-error-cleanup-peer-loss`.
- `capture-start-error-cleanup-new-ticket`.
- `capture-start-error-cleanup-transport-closed`.
- `select-start-error-cleanup`.

직접 startPipeline을 호출한 세 사례는 capture.stop=0, synthetic.stop=0, capture.onFrame=true, 후보 onEncoded=true, server=preparing을 관측했다. 실제 select를 거친 사례는 전환 전 stop이 각각 한 번 있었지만 오류 뒤 capture.onFrame=true, onEncoded=true, server=preparing 상태가 남았다. select의 switching은 해제됐고 active는 none이었으며 commitVideo 호출은 없었다.

`Sources/SillHost/WindowCapture.swift:62`의 catch도 읽었다. 이 catch는 SCStream과 privacy 참조를 정리하지만 onFrame을 해제하지 않는다. 실제 StreamCoordinator가 연결한 onFrame closure는 encoder를 강하게 참조하므로 다음 선택 때까지 후보를 붙잡을 수 있다. 이는 소스를 읽은 추론이며 실제 encoder 메모리나 OS 캡처의 잔존을 측정한 결과는 아니다.

부모가 검토할 수정 지점은 startPipeline의 시작 오류 경로다. 원래 오류를 보존하면서 후보 프레임·출력 콜백과 준비 중 epoch를 정리해야 한다. 이 담당은 생산 소스를 수정하지 않았다. 결함 기록과 실패 검사를 같은 전달물에 보존했다.

## 파일과 검증 한계

- `run.py`는 실제 함수와 admission closure를 추출하고 실제 StreamProtocol·DockSelectionIngress를 컴파일한다.
- `fixture.swift`는 비활성 객체와 continuation, 동작 검사 36개를 정의한다.
- `result.json`은 실제 명령·종료 코드·소스와 추출 SHA-256·사례별 결과다.
- `README.md`는 재실행 절차와 Pstack·Ponytail 적용 범위다.
- 이 문서는 실패 원인과 부모 전달 사항이다.

전체 로그와 생성 소스, 실행파일, 모듈 캐시는 `/Volumes/BT-Workspace/Development-Archives/CCR-Vision/host-native-dock-20261021/pipeline-checks/run-admission-verified`에 있다. `baseline-runtime.log`는 원본 동작 결과이고 각 변이의 compile·runtime 로그도 같은 폴더에 있다.

Pstack Feature 경로에서 실제 동작과 부작용을 검사했고, Ponytail에 따라 기존 생산 자료형과 표준 도구를 재사용했다. 한 담당이 지정 worktree와 새 검사 디렉터리만 사용했다. ARENA와 중첩 에이전트는 실행하지 않았다. 실제 화면 캡처·AX 조회나 액션·앱·기기·서비스·오디오·HAL 조작은 수행하지 않았다.

focusedDockSource의 실제 AX 조회와 handleDockRequest 전체는 이 실행 범위 밖이다. 조회 뒤의 무효 요청은 실제 select 진입부터 검사했다. geometry와 listMessage, capture·encoder·server·status는 비활성 어댑터다. SDK 전체 검사와 독립 검수는 부모 담당의 별도 단계다. 이 결과를 설치 앱·실기기·운영 수용으로 표시하지 않는다.
