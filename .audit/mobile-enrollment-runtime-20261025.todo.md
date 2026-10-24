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

## 이 writer의 적용 상태
- 1. how. ProviderCallSocket/ProviderPeerAnchor, typed 계약, 실제 Node adapter를 직접 읽었다. 자식 생성 금지에 따라 순차 분석했다.
- 2. skip. 부모가 확정한 bounded 설계를 구현한다. ARENA 및 경쟁 설계는 사용자 금지다.
- 3. Blocking first steps. exact HEAD/tree와 clean 상태, 저장 정책, Node와 typed 계약 일치 확인을 끝냈다.
- 3. Independent workstreams. 부모는 Host213·Core pin·TCC·생산 배선을 소유한다. 이 writer는 별도 WT의 신규 runtime/socket와 신규 검사만 소유한다.
- 3. Shared mutable state. 실제 UI/음성/command.sock/서비스에 접근하지 않는다. Node adapter는 읽기 전용이다.
- 3. Smallest safe decomposition. 한 writer가 channel actor·자기 fd lifetime·타입 계약을 함께 구현한다. 독립 검수는 부모 담당이다.
- 4. 부모가 위임한 writer가 직접 구현한다. 자식 생성 금지다.
- 5. 완료. 최종 14개 묶음, 4128건 TTL 창 회귀, 실제 Node adapter 서명 수용, Mac SDK 타입 검사가 통과했다. 실제 OS socket·command.sock·Host·기기·LA·권한·화면·입력·음성 효과는 0이다.
- 6. 최종 검사를 통과한 승인 범위의 신규 파일만 커밋한다. 재배치·rebase는 부모 지시에 따라 하지 않는다.
- 7. skip. 계약/설계 선택은 부모 확정 범위다.
- 8. skip. push/PR/통합/설치는 부모 소유다.
- 독립 검수. 부모 소유이며 이 writer의 자기 검사를 독립 검수로 세지 않는다.

Ponytail 선택. 기존 typed decoder/signer와 ProviderPeerAnchor(.core)를 재사용한다. 기존 단발 ProviderCall transport는 바꾸지 않고, 동일 보안 경계의 duplex 클라이언트만 추가한다. 새 의존성·listener·daemon·worker는 없다.

## 부모 후속 지시 수용
- 8회 연결 예산은 제거했다. Remote Access lifecycle 안에서 transport 부재/EOF만 30초 상한 backoff로 계속 재시도한다. 10회 부재 뒤 Core 등장 자동 연결을 검사했다.
- 평생 누적 요청/nonce/세대 상한을 제거했다. 요청/nonce는 현재 소켓 coreGeneration과 요청 deadline에 묶인 창으로 제한한다. 실제 4128건 처리와 만료 원래 frame 거부를 확인했다.
- Date 변환은 finite/음수/JS safe integer를 확인한 뒤에만 Int64로 바꾼다.
- Node에는 ready/ACK가 없다. identity write 뒤 즉시 active challenge 수신으로 전환한다.
- 설치된 Host213에는 이 runtime이 없다. 실제 registry·생산 lifecycle·Core pin 배선과 설치는 부모 소유다.

## 자기 검토
- deslop. 사용하지 않는 lifetime clear 인자를 제거했다. 기존 구현·데이터·설정을 바꾸지 않았다.
- model-the-domain. Pending 큐, 현재 handshake 세대, 채널별 TTL replay 창, fd 소유 lifetime으로 상태를 나눴다.
- no-comments의 별도 자식 검수는 부모의 자식 생성 금지에 따라 수행하지 않았다. 자기 코멘트 점검은 독립 검수로 세지 않는다.
- 독립 검수 gate는 부모에게 남긴다. 이 브랜치에서 push·PR·통합·설치·서버 변경을 하지 않는다.

## 최종 검증 영수증
- 실행 명령은 `python3 Tests/checks/mobile-enrollment-runtime/run.py --output /Volumes/BT-Workspace/Development-Archives/CCR-Vision/mobile-enrollment-runtime-20261025`다.
- `report.json`은 최종 14개 묶음의 실제 통과 내역을 담는다. SDK 타입 검사와 정확한 소스 전후 SHA는 `source-evidence.json`에 있다.
- `node-compat.json`은 읽기 전용 실제 Node adapter의 SHA와 원문 불변, Swift attach/identity/active 서명 수용을 기록한다. Node socket과 peer verifier는 inert다.
- 실제 fd peer 검증은 production 코드와 SDK 타입 검사로만 확인했으며 실제 OS socket을 연결해 시험하지 않았다. full Host target 빌드·설치·물리 수용도 이 writer의 검사 범위가 아니다.
- 같은 기기 fingerprint의 요청마다 관측 closure를 다시 호출한다. active/revoked 등 6개 typed reason, unknown 결과 재발행 0, stop/start 경쟁을 검사했다.
- 독립 검수는 수행하지 않았다. 부모가 별도 진행해야 하며 merge-ready 또는 production-ready를 주장하지 않는다.
