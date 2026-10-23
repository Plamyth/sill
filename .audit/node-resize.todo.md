### Feature

**You own the design. Plan, review, verify.** Delegate implementation. Stay in the lead.

1. `how` over the affected subsystem.
2. `architect` for parallel design exploration.
3. Write the throughput checkpoint as four todo items. A dimension that genuinely does not apply (single file, no fan-out) keeps its item with `n/a: <reason>` rather than being dropped:
   - **Blocking first steps.** Gates run before fan-out.
   - **Independent workstreams.** Disjoint files, services, or layers parallelize. Shared writes serialize.
   - **Shared mutable state.** Default to splitting the target (the **separate-before-serializing-shared-state** principle skill). Serialize only for real invariants.
   - **Smallest safe decomposition.** If one worker is best, name why.
4. Delegate code-writing to a subagent using your configured feature model (default in poteto-mode's Models section) with a specific scope (file paths, named data shape and its organizing structure per **principle-model-the-domain**, a state machine over scattered booleans, a table/registry over branching, a typed model over repeated shape assumptions, chosen before the delegate writes logic, and success criteria). Pick each subagent's reasoning level for the job, per the Subagents section. When the implementation admits multiple valid shapes (error handling, abstraction layer, test structure), delegate via the **arena** skill instead so the runners surface the alternatives and the cross-judge guards the pick. Mandatory: no skip-with-reason escape, and Laziness Protocol does not override it (the gain is review separation, not lines saved). A subagent forbidden to spawn satisfies this by owning the diff directly with the same review separation. No "standing by" reply that waits on a nested agent. **Give every file-writing delegate its own worktree** (spawn it with `isolation: "worktree"`, or hand it an exclusive branch), and do not write files or run a suite in a worktree a delegate still holds. On Claude Code, `isolation: "worktree"` branches from the remote default branch unless the `worktree.baseRef` setting is `"head"`. When the delegate builds on commits the default branch lacks, commit them, create its worktree with `git worktree add <path> -b <delegate-branch> HEAD`, and name that base commit in the brief. Fencing a file in the brief's prose is not a lock (**principle-separate-before-serializing-shared-state**). Comments per **Comments**. Surgical edits, re-ground against the source for upstream-derived files. Port shared-primitive improvements to all consumers and verify each. Commit liberally.
5. Verify on the matching surface. "Inconclusive" or wrong-surface is not a pass. Flag it.
6. Rebase into small, ordered commits. Stack follow-ups.
   Use the **sequence-verifiable-units** principle skill, building, verifying, and committing each small unit before the next.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

Code-coupled work (one feature, one migration) goes to a single owner with the checkpoint inline. That owner fans out internally after the blocking phase. Parent-level fan-out is for slices that produce independent artifacts (audits, cross-subsystem investigations, competing experiments). Rewrite the checkpoint at phase boundaries. Spawn a fresh owner rather than chaining interrupts.

**Reply:** what you built, what you chose and why, the throughput checkpoint, open decisions. Tables for design alternatives.


# 이번 구현 범위
기준 integration/ccr-ipad 0c59370020c8b39a67098167027bff21b6d77570, 소유 대화01a13ace. 원앱 MyScript 도표 선택의 크기 조절 손잡이 관측과 기존 CanvasRect를 바탕으로 선택 구조 요소의 우하단 크기 조절을 구현한다. 기존 자유 잉크를 임의 확대하거나 원앱의 전체 도형 인식으로 표시하지 않는다.

ARENA 금지 사용자 지시에 따라 기존 EndpointDrag의 미리보기/확정과 graphUndo를 재사용하는 단일 최소 설계를 적용한다. frame과 normalized link anchor가 정본이고 sourceStrokeIds·원본PKDrawing·vault reference·텍스트는 수정하지 않는다. 드래그당 한 번 확정하며 검증에 실패하면 미리보기만 폐기한다. 새 프로토콜·의존성·모델계층은 추가하지 않는다.

- Blocking first steps. 공식 로컬 HEAD/원격2823 차이와 다른 작성자 소유 확인. workflow 권한 게시 장벽은 별도 기록.
- Independent workstreams. 작업자는 새 전용 WT 제품 구현, 부모는 독립 REA 원앱 관측과 음성 현황 회수.
- Shared mutable state. Mac host149·오디오·Obsidian UI·사용자 보관함을 변경하지 않는다. 작성자는 전용 WT만 소유한다.
- Smallest safe decomposition. 한 작업자가 Store와 노드 UI/같은 데이터·관련 검사를 함께 작성하고 새 비작성 검수에서 검증한다.

검증은 production Store에서 정상확대/축소·확대좌표·연결점추종·Undo/Redo·stale노드/장면/모드/접힘거부·invalid/nonfinite·원본잉크와vault/sourceID보존·JSON/로컬재열기이며 iOS SDK 타입검사를 포함한다. 실제Pencil·정상앱설치·개인Obsidian왕복은 따로 미수용으로 남긴다.

## 구현 결과
5c32c64749e33dcf46b4f724e9994b0cc15e55c1에서 두 제품 파일과 전용 검사 두 파일을 확정했다. production Store 크기조절107개, 기존 연결점248개와Store회귀, 전체Canvas iOS SDK27 타입검사, diffcheck가통과했다. 원본22개입력해시와커밋바이트일치를확인했다. 독립검수는새비작성담당에게반환한다.

공유 단계와 정확한 장벽. iPad UI는조사용앱의UIAutomation enabling timeout으로보안확인대기다. 정상Sill59·Mac149·전역오디오·개인보관함은바꾸지않았다. GitHub공식integration게시시OAuth workflow scope부족으로ci.yml변경을거부했다. 인증파일·workflow를지우거나승인없는토큰복사로우회하지않는다. 원격integration/testAccepted/실물동등성/실제Obsidian왕복을완료로표시하지않는다.

검증영수증 /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/node-resize-20261024/implementation-result.json. 새독립검수뒤안전한후속통합을진행하며 ARENA와순정Goal은사용하지않는다.

## 접근성 검수 후속
74d190f의 독립 검수는 NR-A11Y-01 P2로 HOLD였다. 손잡이의 드래그만으로 기능을 실행할 수 있어 보조 기술 대체 동작이 없었다. 기존 Store 트랜잭션을 재사용하는 너비/높이 증감 액션과 현재 크기 읽기를 추가했다. 단일 동작당 Undo/Redo와 stale·다른 장면·invalid·진행 중 드래그 소유권 보존을 검사했다.

첫 추가 검사 실패는 fault-injection 테스트에서 바뀐 storedDrawing을 새 양성 fixture 전에 복원하지 않은 원인이다. 제품 결함으로 세지 않고 실제 테스트 입력을 원래 drawing으로 복원했다. 최종 native 크기조절128개, 연결점248개, 기존 Store 회귀와 전체 iOS SDK27 검사·diffcheck는통과했다. 이전HOLD영수증은변경하지않고보존하며 새 exact HEAD의 독립 재검수를 회수한다.
