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

## 이번 작업
- Blocking first steps. 기준 bf89ec30 clean 확인, typed 계약과 쓰기 경계 대조.
- Independent workstreams. 부모의 TCC/Host213·Core pin과 runtime writer는 별도 WT.
- Shared mutable state. RemoteAccess 소유 파일은 부모가 후속 composition 때 통합. 실제 UI·TLS·서비스 쓰기 0.
- Smallest safe decomposition. 단일 writer가 기존 owner socket/registry/signer 경로 재사용. 하위 agent·ARENA·Goal 금지.
- Feature 1/2 설계 탐색은 고정 계약의 직접 흐름 조사만. 사용자 금지에 따라 fan-out 없음.
- Feature 4 이 writer가 직접 구현. 독립 검수는 부모 소유, 이 writer의 검사는 독립 검수로 세지 않음.
- Feature 6 기준 ref 이동/rebase는 부모 통합 범위. scoped commit만.
- Feature 8 push/PR/통합/설치는 부모 소유.
- [x] RED → GREEN 계약 검사. 최초 missing API와 반환 직전 취소 반례 RED, 최종 116개 계약 및 기존 owner 회귀 1077개 통과.
- [x] 전체 Host 및 3 SDK 타입 검사. HostCore debug 검사와 생산 SillMenuBar Release 빌드, StreamProtocol macOS/iOS/visionOS 통과.
- [x] diff/sourcehash/commit/tree/API 인계. 범위 검사 후 scoped commit, exact 값은 외장 handoff.json에 기록.
- BLOCKED: independent review. 부모의 비작성 검수 필요.
