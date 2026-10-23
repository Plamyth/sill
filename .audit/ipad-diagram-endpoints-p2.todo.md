# 연결점 독립검수 P2 수정

기준은 `1710ea23cadba64bdeecacb6706acf53ad74aeb1`, 전용 WT 쓰기 소유자는 이번 수정 담당 `01a16655-4ba0-7bb3-ac49-5245892cf1a4`다. 원담당 `01a13ace-e372-7ed1-9946-149df37ee1c3`의 계보를 유지한다. 부모가 후속 독립검수를 수행한다.

- [x] 1. Reproduce it yourself on the matching surface via the driver skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
  기기·UI는 사용자 금지 범위다. 실제 Store·Codable과 격리 파일을 사용하는 기존 EndpointChecks에서 재현한다.
- [x] 2. Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Claude Code's `loop` skill. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
- [x] 3. Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default in poteto-mode's Models section) with a specific scope.
  skip: ARENA와 후보 경쟁은 사용자 금지다. spawn_agent도 제공되지 않아 how·설계를 순차 수행한다. 단독 WT 구현을 위임받은 현재 담당이 직접 수정한다.
- [x] 4. Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
- [x] 5. Stage the commits so the failing repro lands before the fix in git history. See the **tdd** skill for the failing-test-first cadence when the bug has a cheap local test path. Skip it when the test would be expensive, integration-heavy, or unclear.
- [x] 6. Run **Opening a PR**.
  skip: push와 PR은 사용자 금지다. 독립검수는 부모가 수행하며 자체 확인을 독립검수로 세지 않는다.

## 조사와 단일 설계

`how` 순차 조사에서 CanvasLinkAnchor Codable이 알 수 없는 키를 버리고, Store begin이 활성 드래그를 교체하며, restoreScene의 try?가 파일 없음과 해석 실패를 합치는 경로를 확인했다. CanvasWorkspace의 핸들은 begin 성공 여부 없이 started를 설정한다. 장면 파일 쓰기는 saveNow 외에 노트·문단 복구 checkpoint 두 곳에도 있다.

Model the Domain을 적용해 드래그마다 UUID 토큰을 두고 begin/update/end/cancel 모두 같은 토큰으로 검증한다. 핸들은 포인터 주기별 시도 토큰을 보유하며 실패한 begin을 다시 시도하지 않는다. 새 토큰으로 새 드래그가 시작돼도 과거 end/disappear는 무효다.

Ponytail full에 따라 새 JSON 라이브러리·값 트리를 만들지 않는다. Anchor의 알 수 없는 키를 경계에서 거부한다. 중첩 vendorMeta를 가진 scene/expected/replacement/proposal은 typed 읽기가 거부되고 원본은 보존된다. 일반 CanvasLink 메타데이터는 범위 밖이다.

restoreScene은 파일이 없을 때만 nil, 나머지는 throws로 구분한다. 복원 실패는 영속 한국어 안내와 저장 차단으로 유지한다. saveNow와 두 checkpoint가 같은 guard를 통과한다. 기존 importScene은 복원 실패 후 자동 저장 권한을 되살리지 않는다. 정상 파일 복구 후 새 Store가 성공적으로 읽어야 저장 가능하다.

## 처리량 체크포인트

- Blocking first steps. 최신 결정·스킬·정확한 HEAD·clean·저장 경로를 확인했다.
- Independent workstreams. 부모의 REA 분석과 격리된 소스·harness 수정만 수행한다.
- Shared mutable state. 전용 WT와 신규 verification-p2 출력만 쓴다. 기존 검증 영수증은 보존한다.
- Smallest safe decomposition. 실패 재현, 최소 모델·Store·핸들 수정, 관련 Store/typed encoder/SDK 검사와 소스 해시 대조, 로컬 커밋 순서다.

기기·UI·설치·공유 호스트·알림·릴레이·외부효과·Goal 실행은 모두 제외한다.

## 회귀 검사 조정 이력

수정 전 동일 Store/파일 경로에서 P2-1·P2-2·P2-3이 모두 FAIL이었다. 이 재현은 `61358d6`에 먼저 커밋했고 `../verification-p2/baseline-result.json`과 `baseline-endpoints-run.log`를 보존했다.

첫 수정 검사에서 P2 세 재현은 PASS였으나 추가한 임의 PencilKit 이진 문자열의 실패 가정이 macOS SDK 동작과 맞지 않았다. PKDrawing이 이 입력을 거부하지 않아 해당 추가 검사를 실제로 검출 가능한 잘못된 base64로 바꿨다. 임의 PencilKit 이진 데이터 검증을 제품 변경으로 확대하지 않았다.

다음 검사에서 10개 손상·미지원 파일의 exact bytes, 실제 읽기 권한 실패, checkpoint 거부·정상 복구가 통과했다. 마지막 보관 fixture는 정렬된 encoder 결과와 기존 비정렬 파일의 바이트를 비교하고 있었다. 실제 저장 직후 바이트를 잡아 비교하도록 고쳤다. 두 시도는 candidate-1 및 candidate-2 영수증에 보존했다. 같은 실패를 조건 변화 없이 반복하지 않았다.

## 영향 범위와 검사 선택

새 `--diagram-endpoints-p2`는 기존 EndpointChecks, StoreChecks, NativeSceneEncoder와 전체 CanvasBridge iOS SDK typecheck를 수행한다. 드래그 API·앵커 Codable·자동 저장·노트 및 문단 checkpoint와 양성 복구를 직접 실행한다. 처음 기동의 파일 없음과 기존 파일 읽기 실패는 별도 검증한다.

이전 17개 중 일반 Pele 모델·revision·hierarchy·fold suite와 프로젝트 형식 검사는 반복하지 않는다. 계층 알고리즘·접힘·Mermaid 변환·프로젝트 설정은 수정하지 않았고, 영향을 받는 graph expected/replacement·AI 재수신·Undo·Redo·저장은 EndpointChecks와 StoreChecks가 실행한다. relay와 WebKit을 실행하지 않는다. 모든 SDK 입력 파일의 검사 전후 SHA256을 영수증에 남긴다.

P3는 공통 geometry라는 기존 문구를 linkEndpoints 양끝점 공유로 정정했다. 화면 화살촉 20·0.45와 PNG 18·pi/7의 기존 차이는 유지한다. 화면·PNG 픽셀 및 실제 동시 터치·PencilKit 기기 동작은 이번 범위 밖이다.

자체 deslop·diff 확인은 수행하지만 후속 독립검수와 no-comments의 독립 판정은 부모 소유다. 현재 런타임에는 spawn_agent가 제공되지 않는다. 자동 검사로 독립 CLEAR를 대신하지 않는다.

세 번째 검사에서는 두 번째 시도의 정상 문단 checkpoint fixture가 출력 폴더에 남아 복구 원장이 이미 있는 상태였다. 제품은 기존 복구 원장을 보존하며 새 편집을 거부했다. P2 EndpointChecks의 모든 복구 fixture를 매 실행의 독립 CFFIXED_USER_HOME 아래로 옮겨, 같은 실행 내 재열기만 공유하도록 격리했다. candidate-3 영수증을 보존했다.

## 최종 검사 결과

`python3 Tests/checks/pele-live/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/diagram-endpoints-20261023/verification-p2 --diagram-endpoints-p2`의 8개 실행 항목이 모두 exit 0이다. `ENDPOINT_CHECKS assertions=248`이며 P2 재현 3개가 모두 PASS다. 10개 실패 파일은 실제 저장 경로에서 명시 저장·예약 자동 저장·importScene 이후에도 exact bytes를 유지했다. 실제 파일 권한 read 실패와 최초 파일 없음, 정상 복구·노트·문단 checkpoint도 통과했다.

StoreChecks·NativeSceneEncoder 전체 typed 장면 왕복·전체 CanvasBridge iOS SDK typecheck가 통과했다. 입력 SHA256은 검사 전후 동일하며 최종 커밋 고정 뒤 git 객체와 다시 대조한다. iOS SDK의 기존 deprecated 경고 2개만 남았다. 새 제품 코드 주석은 0개이고 불필요한 라이브러리·서비스·호스트 변경이 없다. git diff --check가 통과했다.

독립검수와 실제 UI·기기·PNG 픽셀 수용은 수행하지 않았다. 부모가 이 정확한 수정 커밋을 후속 독립검수한다. 알 수 없는 앵커는 보존형 편집 지원이 아닌 명시적 읽기 거부 정책이다. 일반 CanvasLink의 다른 unknown metadata 보존은 범위 밖이다.
