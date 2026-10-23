# 선택 노드 회전 · 2026-10-24

원담당 01a13ace-e372-7ed1-9946-149df37ee1c3. 기준 f29c7c257a81e1ed58840d350c03938f7bda5c21. 사용자 요청은 회전·연결선 추종 구현과 Obsidian 저장·재열기·양방향 실기기 검증이며 원앱 REA 조사를 병행한다.

1. `how` over the affected subsystem.
2. `architect` for parallel design exploration.
3. Write the throughput checkpoint as four todo items.
4. Delegate code-writing to a subagent using your configured feature model with a specific scope.
5. Verify on the matching surface.
6. Rebase into small, ordered commits. Stack follow-ups.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

- [x] Blocking first steps. 정본·HEAD·dirty·원격 확인. OAuth workflow scope 부재는 공식 게시 장벽으로 유지한다.
- [x] Independent workstreams. 구현은 독점 워크트리 한 작성자, 부모는 원앱 REA와 기기·게시 경로 준비를 병렬 소유한다.
- [x] Shared mutable state. 정상 사용자 그림·host149·음성·공유 Mac UI는 변경하지 않는다. 진단 전용 앱과 격리 보관함만 사용하며 실제 기기 점유는 조율한다.
- [x] Smallest safe decomposition. Model/Store/SwiftUI/PNG 연결은 하나의 기하 계약이므로 한 작성자가 소유한다. 독립 검수는 별도 비작성자로 수행한다.

## 구조와 실행 경로

CanvasNode.frame은 회전 전 로컬 직사각형의 위치·크기다. CanvasLinkAnchor는 노드 로컬 경계의 side/offset이다. CanvasScene.linkEndpoints가 SwiftUI와 SceneRenderer PNG의 공통 연결점 계산이다. CanvasStore는 owner UUID/generation/revision/expected node로 드래그를 확인하고 displayedScene 복사본만 미리보기로 만든다. 확정 한 번만 revision과 Undo에 기록하며 기존 save/import/vault checkpoint가 JSON 전체를 보존한다. relay는 scene JSON을 원본 그대로 저장하고 Mermaid는 관계 의미 투영이다.

## 선택한 최소 설계

기존 optional 노드 필드 방식으로 rotationDegrees를 추가한다. nil은 옛 문서의 0도다. 중심 기준 정방향/역방향 좌표 변환을 공통 모델에 둬 명시 연결점·자동 경계 교점·끝점 드래그가 같은 회전 모델을 사용한다. SwiftUI와 PNG가 같은 각도로 노드를 그린다. 회전은 원본 PKDrawing·sourceStrokeIds·텍스트·vault reference를 바꾸지 않는다. 새 서비스·의존성·프로토콜은 추가하지 않는다. 드래그 중 쓰기 0, 확정 1, 취소·stale·소유권·한 번 Undo/Redo는 기존 resize 패턴을 재사용한다. 회전 후 resize는 역회전된 이동량과 회전된 손잡이 위치를 사용한다.

ARENA와 후보 경쟁은 사용자 금지에 따라 실행하지 않는다. architect의 기존 구조 재사용과 최소 타입·호출 경로 설계만 적용했다. 원앱 근거는 rea-automation-no-prompt-20261024/myscript-rotation-observed-spec.md다.

## 완료 증거

- [x] 회전 모델·Store·SwiftUI·PNG 구현과 관련 회귀/SDK 검사. 통합본 a95fcb2에서 회전140·resize128·endpoint248 및 SDK 검사 통과.
- [ ] 격리 Obsidian JSON/PNG/Markdown 저장·재열기·Mac 수정 재수신·충돌 보존.
- [x] 독립 검수 CLEAR 및 로컬 integration a95fcb2 통합. 공식 원격 게시는 아래 인증 장벽으로 미완료.
- [ ] 등록 테스트 런타임 반영, iPad 실제 회전·선 추종·열린 화면 양방향 갱신 수용.
- [x] 원앱 REA 추가 결과와 남은 범위 기록. MyScript 회전·연결선 추종과 실제 종료 후 재열기 유지, MarginNote 발췌 메뉴 조사 근거를 보존했다. 전체 두 앱 조사는 미완료다.

단순 컴파일·소스 검사를 실기기 수용으로 바꾸지 않는다. remote 권한·실기기 보안 장벽이 있으면 그 단계만 미완료로 유지한다.

## 작성자 구현·검사 영수증

- 작성 범위: 지정한 Model/Store/Workspace/Renderer 네 파일과 `Tests/checks/node-rotation`, 이 원장만 변경했다. base `f29c7c257a81e1ed58840d350c03938f7bda5c21`, branch `codex/ipad-node-rotation-20261024`. 부모의 validation 워크트리·호스트·오디오·CI·정상 앱·개인 vault·공유 UI·원격 push는 변경하지 않았다.
- Pstack Feature: 부모가 수행한 how/기존 구조 재사용 결정을 수용하고 위 네 checkpoint를 그대로 사용했다. Feature 4의 하위 작성자가 직접 diff를 소유하는 경로이며 추가 하위 에이전트는 0이다. 후보 경쟁·ARENA·순정 Goal은 실행하지 않았다. Ponytail full에서 기존 Codable optional 필드, 공통 모델 기하, resize owner/generation 패턴, graph Undo/Redo, 저장 경로와 기존 검사 runner를 재사용했다. 새 의존성·서비스·schema 버전은 없다. 독립 검수·공식 integration·게시·실기기 수용은 부모가 별도 수행한다.
- 구현 완료: `rotationDegrees: Double?`의 nil은 0도이며 nil 그대로 encode에서 생략한다. 중심 기준 회전과 역회전을 명시·자동 연결점, 끝점 nearest, UI와 PNG에서 공유한다. 회전은 원본 PKDrawing·stroke transform/mask·sourceStrokeIds·node/link/vault identity·텍스트를 바꾸지 않는다.
- Store: 미리보기는 displayedScene만 바꾸며 scene/revision/save/Undo 쓰기 0, 확정 scene 쓰기와 revision 증가 각 1이다. 기존 graph Undo/Redo로 한 번 복원한다. scene generation/revision/expected UTF-8 node/selection/mode 검사를 사용하고 다른 owner, stale/cancel, resize/endpoint 배타를 보존한다. 회전 후 resize는 화면 이동량을 역회전하고 회전된 좌상단을 고정하며 손잡이가 화면 이동을 추종한다. 접근성 resize는 기존 로컬 너비/높이 의미를 유지한다. 본문 드래그는 canvasScene 좌표계를 사용해 회전에 따른 이동축 변화를 막았다.
- UI API: `canvasNodeRotate-<UUID>`; label `선택한 요소 회전`; value `회전 0도`/`회전 45도`; 44pt hit 영역. 핸들은 회전 전 frame의 `(center.x, bottom + 44 / zoom)`을 노드 중심으로 회전한 위치다. `canvasNodeResize-<UUID>`는 기존 이름을 유지한다. 시계/반시계 15도와 회전 원위치 동작 모두 `rotateNode`를 사용한다.
- Store API: `beginNodeRotation(_:sceneID:owner:)`, `updateNodeRotation(owner:degrees:)`, `updateNodeRotation(owner:from:to:)`, `finishNodeRotation(owner:)`, `cancelNodeRotation(owner:)`, `rotateNode(_:sceneID:to:)`; 공개 읽기 상태 `nodeRotationDrag`; 모델 `rotationRadians`, `hasValidRotation`, `scenePoint(_:inverse:)`, `rotatedVector(_:inverse:)`, `endpoint(anchor:toward:)`.
- 경계: 회전 입력의 type mismatch, nonfinite, 각도→radian overflow, 회전 좌표 overflow를 Codable decode/encode에서 거부한다. import는 현재 scene/drawing을 바꾸기 전에 회전을 검사한다. agent apply는 proposedNodes와 expected node의 invalid 회전을 먼저 거부한다. 저장 encode 실패는 마지막 정상 파일을 보존하고, restore 실패는 기존 sceneReadable fail-closed 경로로 원본 JSON 자동 덮어쓰기를 막는다.

### 검사

명령: `python3 Tests/checks/node-rotation/run.py` (사용자 승인 SDK27 MacBook local 경로, 다른 호스트 소스 복사 0).

성공 원장: `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/node-rotation-20261024/verification-01mggk1g/result.json`.

- production Model/Store 회전 140 assertions 통과: 옛 JSON/nil, 명시·자동 anchor, nearest 역변환, preview0write/commit1, stale/다른 owner/취소/no-op, Undo/Redo, 원본 PKDrawing, JSON 실제 저장·재열기, agent/import 유지와 invalid 거부, 회전 후 resize.
- 기존 production resize 128 assertions, Store 회귀, Endpoint 248 assertions 모두 통과.
- 전체 Canvas + `NodeRotationRendererChecks.swift`의 arm64 iOS27 SDK typecheck 통과; macOS27 production Model/Store 격리 실행 통과.
- SwiftUI 회전·공통 radians·PNG CGContext 회전/복원·44pt·한국어·gesture cancel 정적 연결 검사와 `git diff --check` 통과.
- 첫 시도 `verification-0g10ifm6`은 저장 JSON의 키 순서를 잘못 가정한 검사에서 실패했다. 실제 마지막 저장 바이트를 기준으로 검사하도록 수정한 뒤 위 최종 시도에서 통과했다. 이전 출력 원장과 기존 resize suite 출력은 덮지 않았다.
- 기존 warning: CanvasDictation의 iOS27 `installTap`, SceneRenderer의 `UIScreen.main` deprecated 경고만 관측했다. 이 작업 범위에서 오디오나 화면 scale API를 바꾸지 않았다.

### 저장·agent 호출 조사와 호환 한계

- `CanvasStore.persistScene/restoreScene/importScene`, Workspace의 파일 import·remote canvas decode·remoteCanvasIsPrefix, `SceneFile.fileWrapper/init`, `CanvasRelay.saveVaultCanvas`, `CanvasPacket.init/frozenScene/existing`, `CanvasScene.editGraph/confirmNode/apply`, Store `applyAgentRevision`, graph Undo/Redo와 vault 캐시 갱신을 조사했다. 저장/packet은 CanvasScene 전체 Codable을 쓰고, 편집/캐시는 기존 노드를 복사·수정하므로 회전 필드를 유지한다. agent text edit의 expected node에 회전이 누락되면 equality 충돌로 거부한다. relay 서버 코드는 이 checkout 밖에 있으므로 실제 relay 왕복은 부모 검증 범위다.
- schemaVersion은 1을 유지한다. 회전 미지원 구형 소비자는 알 수 없는 optional 필드를 읽고 재저장할 때 회전을 유실할 수 있다. 구형 소비자와의 혼합 편집을 안전하다고 주장하지 않는다. Mermaid/diagram은 관계 의미 자동 배치이며 회전 레이아웃은 scene JSON에만 유지한다.
- 각 드래그는 시작 방향에 대한 -180...180도 차이를 사용하며 여러 차례 드래그로 누적할 수 있다. 한 손동작의 여러 바퀴 연속 추적이나 스냅 규칙은 추가하지 않았다.
- iOS 실제 PNG probe 준비: 진단 iOS 타깃에 `Tests/checks/node-rotation/NodeRotationRendererChecks.swift`를 포함하고 `try await NodeRotationRendererChecks.run()` 호출. production SceneRenderer의 0/90도 PNG 픽셀과 두 번째 노드 변환 누수 부재를 검사하고 `[String:Data]` PNG 두 개를 반환한다. 타입 검사는 통과했으나 이 작성자는 UIKit 실행·실기기 PNG 픽셀·손가락/Pencil·VoiceOver·44pt hit·Obsidian relay 양방향 왕복·설치·공유 테스트 런타임을 실행하지 않았다. 부모의 원래 Result 계보에서 수용해야 한다.

작성자 구현/필수 로컬 검사는 완료했다. 위 전체 완료 증거의 실기기·relay·독립 검수·integration 항목은 아직 체크하지 않는다.

## 원담당 통합·실행 결과

- Pstack Feature의 작성자 위임, 부모의 별도 adapter 작성, 비작성자 독립 검수 경로를 사용했다. 두 번째 작성자 생성은 세션 수 제한으로 실패해 부모가 독점 validation worktree에서 구현했다. 첫 검수의 PNG 헤더만 검사하던 허점과 UI 연결선 존재만 검사하던 두 P2를 수정하고 새 비작성자가 CLEAR를 반환했다.
- 통합 코드 a95fcb2030fb8eb678bdb94b3da596493aba9206, tree d188f44bcae1d221428e89e7e03a3fa0fb7d0b47. capture-local/verify-local을 통과했고 검수된 validation tree와 동일하다. author branch와 이전 통합 계보는 보존했다.
- 통합본 실제 검사 결과는 node-rotation-20261024/verification-syww9q5a/result.json이며 모든 입력 해시 불변, exit0이다. adapter 단위15개와 XCTest harness 실기기용 빌드도 통과했다. 실제 PNG 검사 전용 앱은 iPad에서 production Model/SceneRenderer를 실행해 0/90도 노드 픽셀·다른 노드 변환 누수 검사를 통과했다. 근거 rotation-device-20261024/renderer-receipt.json. 정상 앱59·host149·음성·사용자 그림을 설치나 API로 바꾸지 않았다.
- 공식 testDeployed/testAccepted와 iPad 실제 회전 UI·개인/격리 Obsidian relay 왕복은 아직 미완료다. 원격 integration은 2823a151c8233542d23d4a5a93fed27bc61e44a7이며 source guard는 remote_commit_mismatch를 반환했다. workflow scope가 없는 기존 GitHub CLI를 같은 로그인으로 공식 갱신 중이지만 Space8/CAM6의 Authorize 버튼이 disabled다. 같은 인증 한 건을 유지하고 handOff했으며 보호 대상 Space6/CAM4와 공유 Mac 포커스는 바꾸지 않았다. disabled 강제 해제·직접 폼 제출·소스 게이트 우회·새 인증 반복은 하지 않는다.
- REA 실제 추가 관측은 rea-rotation-followup-20261024/myscript-rotation-persistence-observed.json에 있다. ev_c6f0f1bfd0add85fb2572956df78bd933f6f8d76307229f60b55dbf83b7ffbaf. XCTest 손가락으로 회전한 자체 조사 도형·연결선이 원앱 종료·재실행 후 유지됨을 전후 PNG로 직접 확인했다. 실제 Pencil 회전과 스냅·저장 패키지 각도 필드는 미확인이다. 첫 시도는 원앱 idle 대기로 회전 전에135초를 초과했고 이미 선택된 상태를 재사용한 360초 예산 실행은189.9초 후 통과했다.
