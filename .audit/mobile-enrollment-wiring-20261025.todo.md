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

## 실행 범위와 처리량 점검

- 원담당 01a13005-ff61-7780-b0e8-6dc171de1c9d. 기준 bf89ec30ceb693d01d71b604a889254342fb5577. 후보 86dc8b2, e00eaa3을 이 작업공간에서만 cherry-pick했다.
- Blocking first steps. 최신 결정, 저장 경로 UUID, clean 기준과 두 후보 typed API를 확인했다.
- Independent workstreams. 후보 소스와 검사 계약은 병렬 읽기했다. 실제 배선과 full HostCore 링크는 같은 RemoteAccess를 소비하므로 변경 후 검사한다.
- Shared mutable state. 본 워크트리만 쓴다. 설치 Host213, Core 151개 파일, gateway, 실제 command.sock, 키체인, TLS, 기기, UI와 오디오를 변경하거나 실행하지 않는다.
- Smallest safe decomposition. 데이터 모양은 기존 HostProfile과 Observation이다. RemoteAccess가 단일 runtime을 소유하고 기존 Host lifecycle이 종료한다. 기존 profile helper와 current registry API를 그대로 재사용한다.
- how는 실제 apply/start/config/shutdown과 후보 관측·signer 경로를 순차로 읽었다. spawn_agent 도구가 없어 별도 탐색·구현 위임은 실행 불가다. 본 세션이 요청된 poteto-agent writer를 맡는다.
- architect는 기존 계약에 맞춘 단일 소유 스케치로 진행한다. ARENA와 같은 후보 경쟁은 사용자 금지로 생략한다.
- Ponytail은 runtime, HostIdentity, private profile helper, registry 재조회와 typed signer 재사용에 적용한다. 새 signer·domain·bundle·서명 계약은 없다.
- 독립 검수 BLOCKED. spawn_agent 도구가 없으며 부모 소유로 남긴다. 자체 검사 결과를 독립 검수로 바꾸지 않는다.
- PR, push, 설치와 공식 integration은 사용자 지정에 따라 부모 소유다.
- 완료. fake transport에서 실제 apply, off/on, duplicate apply, reconnect, current registry, weak lifetime을 검증했다.

## 배선 스케치와 검사 경계

기존 StreamCoordinator.start와 applyConfig가 호출하는 RemoteAccess.apply에서 remoteAccess 설정을 읽는다. RemoteAccess는 정본 identity로 private mobileEnrollmentHostProfile을 호출해 runtime 하나를 보유한다. currentRemoteAccess와 ObserveActive는 weak self를 캡처한다. ObserveActive는 의존 clock으로 현재 nowMS를 구해 실제 mobileEnrollmentObservation을 호출한다. enabled=false이면 runtime.stop, enabled=true이면 runtime.start다. 중복 start의 멱등성은 후보 runtime이 소유한다.

앱 종료 shutdownForExit와 CLI 종료 releaseKeysForExit가 같은 stopMobileEnrollment를 호출한다. runtime의 deinit은 자기 task와 transport만 종료한다. 테스트는 종료 hook의 stop 메서드까지 실행하며 StreamCoordinator 전체 종료나 Host 프로세스는 실행하지 않는다.

검사는 실제 RemoteAccess와 전체 SillHostCore를 링크한다. MemoryIdentityStore와 메모리 transport만 주입한다. OWNER_BOOTSTRAP_CONTRACT에서만 접근 가능한 skipsNetworkWatchersForTesting은 기존 Reachability의 실제 네트워크 관측을 끈다. apply의 설정 전환, 관측 API, signer와 runtime 배선은 실제 생산 코드다. runtime 전용 기존 검사는 같은 HostCore 객체를 링크해 반복한다.

Mac mini xcode-select가 /Library/Developer/CommandLineTools를 반환했다. iOS/visionOS SDK와 메뉴바 SwiftUI 매크로가 필요한 검사는 기존 맥북 /Applications/Xcode.app의 프로세스별 DEVELOPER_DIR로 실행한다. 전역 xcode-select는 바꾸지 않는다. 빌드 산출물·캐시는 본 작업공간 .build 안에 격리하며 실행·서명·설치하지 않는다.

Node 검사는 기존 실제 enrollment-host-adapter.js를 읽고 memory socket과 inert peer anchor로 Swift의 실제 attach/identity/active 서명을 검증한다. 이 fixture의 임시 pin은 본 작업공간 안의 격리 파일이며 설치된 pin이 아니다. 실제 peer 인증, command.sock, TLS, 키체인, Host 설치·실행과 HTTP 등록은 미수용이다.

## Deslop·검수 상태

명시한 bf89ec3 기준과 두 후보 뒤의 배선 diff를 대조했다. 새 상위 계층·서명 API·도메인·의존성을 추가하지 않았다. 새 생산 배선에는 설명용 주석이 없으며 nil runtime 하나가 수명주기를 표현한다. 기존 socket ENOENT 처리는 후보 그대로이고 중복 수정하지 않았다. no-comments의 독립 reviewer는 도구 미제공으로 실행하지 못했다. 이 자체 점검은 독립 검수 판정이 아니다.

최초 전체 메뉴바 Release 빌드는 성공했다. 새 fixture의 PairResult.qr 참조가 없어서 검사 소스 컴파일이 실패한 것을 PairRequest.qr로 수정했다. 같은 실패를 반복하지 않으며 initial-build.log에 이력을 보존했다. 검사는 실패 후 SDK 산출물을 다시 쓸 수 있게 본 WT .build 아래의 전용 scratch를 사용한다.

## 필수 검사 완료

- 실제 배선 8개 묶음 통과. 중복 apply 20회의 추가 connect/attach는 0이고 canonical identity를 다시 로드하지 않았다. off에서는 connect와 attach 0, 활성 채널과 재접속 대기 취소, on 재시작을 확인했다.
- 현재 signed registry와 paired의 이중 재조회, active·revoked·pending·QR·missing·store 오류와 disabled를 실제 관측 API로 확인했다. 메모리 원장만 변경했다.
- 기존 receipt 116개, owner 회귀 1077개, runtime 14개 묶음이 같은 전체 생산 HostCore 객체로 통과했다. runtime에는 4128건 TTL 창과 재생 거부·기한·중간 취소·빠른 stop/start 검사가 포함된다.
- 배선의 실제 서명 결과와 runtime 검사 결과를 각각 실제 Node adapter로 수용했다. 메모리 socket·inert peer verifier·격리 pin을 사용했다.
- StreamProtocol 전체를 macOS arm64 14.0, iOS arm64 17.0, visionOS arm64 2.5 SDK로 검사했다.
- SillMenuBar와 HostCore Release의 contract hook 구성 빌드가 통과했다. 테스트 전후 전체 생산 Swift 소스와 검사 소스 SHA가 같다.
- 실제 Node adapter SHA는 9652cd9ce33cbaf46a582eb14f00cff573eeeb76c6af3c44bda23680fc659019다. sibling 93개 파일의 전후 SHA가 같다.
- 일반 생산 Release도 통과했다. OWNER_BOOTSTRAP_CONTRACT와 enable-testing 플래그를 제거한 실제 SillMenuBar/HostCore를 빌드했고 실행·서명·설치하지 않았다. 최종 결과와 exact commit/tree는 본 WT .build/mobile-enrollment-wiring/handoff.json에 기록한다.

검증 명령은 `python3 Tests/checks/mobile-enrollment-wiring/run.py --output .build/mobile-enrollment-wiring`다. 결과는 같은 폴더의 verification.json, wiring/wiring-report.json, wiring/node-compat.json, runtime/report.json, runtime/node-compat.json과 verification.log에 있다. 일반 생산 Release의 정확한 명령·바이너리 SHA·소스 해시는 production-release.json에 별도로 남긴다. 실제 앱 서명·설치·Host 실행, command.sock, 실제 peer 검증, 키체인/TLS/HTTP, UI·오디오·기기 검증은 모두 이 작업 범위 밖이다.

필수 독립 검수는 부모 소유이며 미실행이다. spawn_agent와 no-comments reviewer 도구가 제공되지 않았으므로 자체 deslop 점검과 통과 검사를 독립 검수로 표시하지 않는다. PR·공식 integration·설치·실물 수용은 실행하지 않았다.
