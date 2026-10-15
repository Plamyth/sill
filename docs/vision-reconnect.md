# Vision reconnect candidate

Work key `vision-sill-reconnect-20261016`. Owner is this bounded reconnect worker. Exclusive worktree `work/sill-vision-reconnect`, branch `codex/vision-sill-reconnect-20261016`, base `62bc4c5884bf54f4eb729b71e082d0fa8d7d8609`. Updated 2026-10-16 08:54 KST.

Production writes are limited to `iOSClient/StreamClient.swift`, `iOSClient/StreamClient+Remote.swift`, and `iOSClient/DiscoveryPolicy.swift`. Test artifacts stay in `Tests/checks/reconnect-glue`. The parent checkout and installed signed app are outside this unit.

## Procedure

- [x] 1. Reproduce it yourself on the matching surface via the driver skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
- [x] 2. Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Claude Code's `loop` skill. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
- [x] 3. Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default in poteto-mode's Models section) with a specific scope.
- [x] 4. Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
- [x] 5. Stage the commits so the failing repro lands before the fix in git history. See the **tdd** skill for the failing-test-first cadence when the bug has a cheap local test path. Skip it when the test would be expensive, integration-heavy, or unclear.
- [ ] 6. Run **Opening a PR**.
  skip: User prohibits push and PR. Deliver owned local commits for parent review.

Physical native reproduction is unavailable by user constraint. The fixture executes extracted production Swift methods with a deterministic clock and network stand-ins. It does not prove real mDNSResponder recovery or Vision lifecycle behavior. Each extraction has a SHA-256 receipt. No production method is rewritten inside the fixture.

`poteto-mode`, bug-fix, `how`, `architect`, and `principle-model-the-domain` guide the work. No subagent tool is exposed, so exploration and design comparison are sequential. Independent review remains blocked until a separate reviewer examines the exact candidate. No review approval is inferred from tests.

Throughput checkpoint. Extract and compile one focused fixture on Mini RAM, commit its failing receipt, apply one coherent backport, run the fixture and existing 38 Vision checks in one sequential heavy job, then run one unsigned XROS compiler job on MacBook. Each failed path permits the first attempt and two hypothesis-driven fixes. All Mini children, RAM inputs, and isolated outputs must be reaped before handoff.

## Grounding

`how` traced browser callbacks and due timers into `discoveryChanged` and `reconnectIfListed`. That method selects a trusted network row, a qualified Direct row, or saved remote addresses. The reconnect value owns loss time and remote retry timing. The original timer stops after a look that dials. A preparing connection times out after five seconds and tears down without another look. Browser creation runs only once; foreground only resets liveness.

The actual local upstream diffs `83f96bac3b64210114a7ca95ab53ecb64195f133` and `03ca390b3ce7fcd05d81794b396e20d02ea56258` were read. They add listed-row budgets, browser lifetime state, browser rebuilds, failure row retention, and a continuing periodic timer. The native candidate must also gate remote attempts and stop timers after exhaustion. Upstream Desktop auto-selection, iPad UI, and MockCatalog changes are excluded.

Model the Domain places listing identity, dial count, and last start in the existing `Reconnect` value. Browser lifetime owns kept and fresh rows, failure time, and cancellable work. These states remain main-thread-owned. The smallest interface lets `reconnectIfListed` schedule only its next due event.

## Evidence

`repro-01` is a fixture assembly failure, not runtime evidence. Stored properties were emitted in an extension and `startPathMonitor` lacked a stand-in. `repro-02` corrects only fixture assembly and compiles the original source. It reports `FAIL listed sleeping host receives exactly 12 dials, observed 2`, `FAIL native background gate also prevents remote attempts`, and `FAIL foreground rebuilds browser even without a reported mDNS failure`. Overall `Reconnect glue: 5/11 passed, 6 failed`. The two baseline row-retention assertions do not exercise a replacement because the original browser never rebuilds. They are retained for comparison but prove no baseline recovery.

`receipts/repro-02.json` records original production hashes, verbatim extraction hashes, sender and receiver input agreement, unchanged memory and MacBook inputs, removed RAM volume and outputs, and unchanged 9736 MB swap. Orca process identities match before and after. No application network connection is made by the fixture. The only network transport is the approved Mini SSH stream.

## Design comparison

Candidate A keeps upstream's generation-numbered 2/4/8/10 second polling chain and adds foreground and budget checks. It duplicates the due scheduling already owned by `reconnectIfListed`, and needs a second cancellation owner. Candidate B removes the polling chain. The row timeout and failed dial explicitly re-enter `reconnectIfListed`, which owns one cancellable due timer for the listed budget or remote window. Candidate B is selected. There is no poll after budget exhaustion. Browser failure recovery retains upstream's separate per-browser backoff because it responds to a failed browser, not a reconnect poll.

Usage sketch. A lost session calls `scheduleReconnectRetry`, now a single evaluation. A listed attempt records its listing and start before dialing. Its timeout or failed-session path preserves `Reconnect` and evaluates again. Background cancels pending evaluation and incomplete automatic attempts. Foreground resets only listed-row count, rebuilds existing browsers, and evaluates again. The original remote loss deadline remains unchanged. A new listing or tap provides the other explicit restart evidence.

Initial runtime reproduction is complete and is committed before production changes. Physical reproduction and independent review remain open. Architect ground and sketch are complete as sequential analysis. Agree has no user checkpoint. Implementation and hermetic verification are complete. Scrap was not needed. The checkmarks refer to the authorized headless work, not physical acceptance. The first commit is `c76983726ecf30c453972155eb9eb001f599e867`, containing the failing repro and receipts. The next owned commit contains the fix and validation artifacts.


## Final validation

The three production file hashes are identical across `fix-02`, `fix-policy-03`, `fix-policy-04`, and `xros-01`. The source receipt in each run records HEAD before the fix commit plus the actual dirty production file hashes. `xros-01.json` preserves hashes for all 216 tracked build input files. `artifact.json` confirms that those build hashes match the Mini-tested candidate.

| Receipt | Observed result | Meaning |
| --- | --- | --- |
| `repro-01` | Fixture compile failed | Stored-property assembly and missing stand-in. Not product evidence. |
| `repro-02` | 5/11 passed, 6 failed | Original extracted glue dials a stable listed host twice, dials remote in background, and retains the foreground browser. |
| `fix-01` | Fixture compile failed | `wentToBackground` was extracted twice. No product change followed this fixture failure. |
| `fix-02` | Glue 29/29, Vision input 38/38 passed | Corrected extraction, original regression assertions, added state transitions, and unchanged native input logic. |
| `fix-policy-03` | Glue 28/29, upstream policy 43/43 | Browser identity assertion retained only a deallocated object's numeric address. An allocator can reuse that address. Receipt retained. |
| `fix-policy-04` | Glue 29/29, upstream policy 43/43 | Test retains the replaced browser strongly and compares object identity. Production source is unchanged from `fix-02`. |
| `static.json` | 8/8 passed | Scope, native lifecycle wiring, common gate placement, no recurring poller, original native ACK and window-list delivery, and absent Clipboard dependency. |
| `xros-01` | BUILD SUCCEEDED, exit 0 | One unsigned XROS Release build, Xcode 27.0 build 27A266a, jobs 1 and Swift num-threads 1. Source unchanged, compiler reaped. |

The supplemental policy test extracts the actual browser and reconnect portions of upstream `03ca390`'s `Tests/checks/policy/sleep.swift` verbatim. Only the final closing brace is supplied. Desktop auto-selection tests are excluded with their production changes. Both the selected-byte and full-file hashes are in the extraction receipt. Its policy model is supporting evidence only. It does not replace execution of the 29 extracted-glue checks. The fixture and transport scripts exceed the product patch's size, so their coverage is deliberately limited to these extracted methods and upstream policy cases.

The unsigned artifact reports `dev.ambrion.SillVision`, SDK `xros27.0`, platform `xros`, supported platform `XROS`, and minimum OS 2.5. Its executable SHA-256 is `ef7f59c30f4809e6bbfdb43ea9af2596ccbba003a0a8c5233ff72e8a2501d427`. This is compiler and artifact evidence only.

## State and field coverage

| State or field | Executed or inspected evidence | Remaining limit |
| --- | --- | --- |
| `appInForeground` | Extracted `reconnectIfListed` rejects both row and remote attempts in background. Extracted background and foreground methods cancel and resume. | UIApplication notification delivery and a real native scene were not driven. Active initialization and notification wiring are static checks plus native compilation. |
| `rowListing`, `rowDials`, `lastRowDialAt` | Actual row glue starts at 0/5/15/35 seconds, then every 30 seconds, exactly 12 dials. Repeated same-listing calls cannot reset it. New sighting time and new foreground resume. | Sightings and row construction are supplied by the fixture, not real Bonjour. A new reconnect value represents explicit user intent; the actual tap UI is not driven. |
| `lostAt`, `nextRemoteAt`, `remoteAllowed` | Actual dispatch method obeys original 120-second window, no attempt in background, resumes within the window, and does not extend the loss deadline on foreground. | Network connectors are stand-ins. `remoteFailures` updates and failure delivery are simulated. Real remote callbacks, trust failures, and address routing are not exercised. |
| `reconnectCheck` and retry entry | Due timer cancels on background. Exhaustion leaves zero pending timers. Entry is a single evaluation without a recursive chain. | Dispatch is deterministic. No claim about real suspended-queue wake timing. |
| Unready row timeout and failed-session branch | Verbatim timeout and selected `sessionEnded` branch preserve loss time and consumed count, then evaluate when due. | Full `connect`, TLS first-window-list handling, home rejection handling, and real socket state callbacks are not executed by the fixture. |
| `BrowserLife` and current browser identity | Actual rebuild, fail, settle, and callback guards retain rows through three failures, expire kept rows after successful settle, ignore replaced callbacks, and stop rebuilds in background. | Network.framework and mDNSResponder behavior remain physical/runtime gates. |
| Vision input ACK, input guards, `noAutoDesktop` | Existing 38 native input checks pass independently in Mini RAM. Static comparison shows the complete window-list delivery function and Vision ACK references match the base. | Physical gaze, pinch, IME, and host input release acceptance remain outside this unit. |

## Resource and handle reconciliation

`fix-02` observed swap 9736 MB before and after. `fix-policy-04` observed 9728 MB before and after, with reported free percentage 36 percent at both ends. These are observations, not an attributed resource saving. Orca process identities match within each run. A read-only Docker snapshot showed 13 existing Cargo24 containers running, including the separate management-device DB. No container, model, AVD, host stream, or service was started or stopped.

`cleanup.json` confirms all 12 recorded Mini runner/compiler/test PIDs are gone, all recorded local transport PIDs are gone, the heavy slot is free, no `CCRReconnect*` RAM volume remains, and no isolated output directory remains. Each individual run also records successful detach and output removal. XROS compiler PID 40896 is gone, and its terminal handle completed with exit 0. All yielded worker terminal handles have completed. The compiler lease was returned to the parent before its separate probe. No further worker compilation is pending.

The parent worktree was read back at `62bc4c5884bf54f4eb729b71e082d0fa8d7d8609` with empty status during final cleanup. The signed installed application was not modified. This unit created no permanent Mini or Cloud checkout.

## Handoff and remaining gates

This is an independent local candidate. Parent independent review of the exact clean fix commit, the proper local integration gate, and later physical native reconnect acceptance remain open. `codex-source-guard` transfer acceptance is not claimed. The parent's reported `remote_ref_unknown` remains outside this worker's resolution scope. No push, PR, installation, pairing, keychain change, device/browser operation, audio activity, or wire/host/iPad UI/project edit was performed by this worker.

`poteto-mode` selected failing-repro-first commits. `how` traced the actual callback and timer ownership. `principle-model-the-domain` kept listing budget in `Reconnect` and browser state in `BrowserLife`. Architect compared two scheduling designs and selected one due-timer owner. TDD preserved the failing baseline before the product patch. Deslop inspection retained the focused diff. The full `why` cross-service investigation and no-comments independent agent were unavailable or outside the user's bounded local scope. Local git history and the two upstream diffs provide the historical evidence used here. Independent review is not inferred from this worker's inspection.

The original owner can integrate this report into the existing project Page after reviewing the candidate. This worker's durable report and evidence remain in this allowed document and focused receipts directory.

Re-run the focused checks from this worktree with `python3 -B Tests/checks/reconnect-glue/mini.py <new-receipt-label> --pointer` only when there is a concrete new validation need. It streams inputs into one Mini RAM volume, uses the heavy gate, preserves hashes and logs, and removes remote inputs and outputs. `static.py` is a browser-free local check. The unsigned native build is already successful for the exact candidate and does not need repeating for these report changes.
