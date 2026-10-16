# Vision reconnect P2 review fixes

Work key `vision-reconnect-reviewfix-20261016`. Exclusive worktree `work/sill-vision-reconnect-reviewfix`, branch `codex/vision-reconnect-reviewfix-20261016`, base `8aa995cf0d08fe290b4268fc7fa5767d2cfc1df0`. The previous writer is closed. This owner writes only the three allowed client files, this document, and `Tests/checks/reconnect-glue`. The original reconnect and signed-source worktrees are read-only.

The procedure checklist below is for this fresh unit. The older report is retained under Historical candidate evidence. Its completed checks and receipts apply only to `8aa995c`, not these review fixes. Independent Avicenna reported two P2 findings. Parent core and kind changes remain open for independent review.

## Procedure

- [x] 1. Reproduce it yourself on the matching surface via the driver skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
- [x] 2. Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Claude Code's `loop` skill. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
- [x] 3. Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default in poteto-mode's Models section) with a specific scope.
- [x] 4. Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
- [x] 5. Stage the commits so the failing repro lands before the fix in git history. See the **tdd** skill for the failing-test-first cadence when the bug has a cheap local test path. Skip it when the test would be expensive, integration-heavy, or unclear.
- [ ] 6. Run **Opening a PR**.
  skip: User prohibits push and PR. Deliver owned local commits for parent review.

Throughput checkpoint. Preserve a failing two-row reproduction and a cancellation mutation receipt before any production edit, then commit them. Apply one typed listing budget change. Run glue, policy, cancellation mutation, and the prior 38 Vision checks in one sequential Mini heavy job using `mini.py`. Run one final unsigned XROS build with one compiler job for the changed production source. Each specific path permits the first attempt and two hypothesis-driven fixes. Reap all owned transport, runner, compiler, and test processes and remove RAM inputs and isolated Mini outputs. No application launch or installation is part of this unit.

Ground. `reconnectIfListed` chooses the first matching row and compares only its timestamp with `Reconnect.rowListing`. Selection changes therefore erase the prior count and due time even while both rows remain listed. `cameForward` clears the selected counters. The lifecycle calls `cancelRemoteDial`, whose production body cancels the connector then clears its reference. The old fixture duplicated that helper and its cancellation scenario never reached the first dial at loss plus three seconds.

Sketch and synthesis. A stable selection until disappearance would preserve the cap but suppress a legitimate alternate endpoint when discovery order changes. A typed `RowListing` containing `FoundMac.id` and optional listing timestamp, mapped to a `RowBudget` containing starts and last start time, preserves independent failover budgets. Select the map design. A new generation discards only that row's old budget. Foreground clears all row budgets. A computed selected `rowDials` preserves read compatibility without a second mutable counter. The existing due timer and remote loss window keep their owners.

`poteto-mode`, bug-fix, `how`, `architect`, TDD, deslop, technical-writing, unslop, and Model the Domain apply. This runtime exposes no subagent dispatch. Grounding and the two design alternatives are sequential analysis, not independent review. The parent review gate remains open. Agree proceeds under the user's specified approach. Scrap is unnecessary unless the bounded fix contradicts the sketch.

The strengthened cancellation fixture retains the active connector before background at time 103. It checks the retained connector's cancellation flag and cleared client reference immediately after background, before advancing the clock. The actual production cancellation helper is extracted verbatim. The connector and callback are stand-ins, so this covers lifecycle cancellation wiring and invocation only. It makes no network cancellation claim.

`review-repro-02` was rejected before the runner by the occupied Mini heavy slot, exit 75. It created no RAM input or compiler. Another owner held the slot with a `CCRVerify` runner. Its work was left running. The corrected reproduction follows once the slot is free.

`review-repro-01` compiles and demonstrates the exhausted-row restart and the targeted cancellation mutation. Its new in-flight row reorder assertions were invalid because production blocks selection while a home connection prepares. The corrected fixture sets the same nonremote session shape as production `connect` and calls the extracted `sessionEnded` failure branch before selecting the alternate row. This tests real failure-to-backoff behavior instead of manufacturing an automatic home session. No production change followed the first repro run.

`review-repro-03` is the corrected failing reproduction on unchanged `8aa995c` production bytes. Glue reports `34/46 passed, 12 failed`. The decisive failures are `reorder cannot revive either exhausted listing, observed 25 starts` and `A to B to A reorder retains A five second backoff, observed [100.0, 101.0, 102.0]`. Policy remains 43/43. The mutation passes the active-connector precondition at 103, then fails `background immediately cancels retained active remote connector`, adding exactly that assertion to the baseline failures. Sender and receiver hashes match, production and RAM inputs are unchanged, RAM and output are removed, and all children were reaped. Mini swap moved from 9720 to 9748.12 MB while Orca process identities remained unchanged. This is an observation, not a performance attribution.

## P2 closure evidence for this unit

Updated 2026-10-16T09:08:06.239849+09:00. Failing repro commit `c8cecbf` precedes every production edit. The first product hypothesis passes the focused runtime fixture. No extra product fix attempt was needed. One fixture correction was needed to exercise row failure before reordering. One Mini slot rejection created no test execution. The one final native build in `review-xros-01` succeeded. Its terminal returned exit 0.

| Finding | Change and evidence | Scope |
| --- | --- | --- |
| P2 listing reorder resets cap and backoff | `Reconnect.RowListing` holds exact `FoundMac.id` and listing timestamp. Its map holds one budget per current listing. Selecting A, B, then A retains both budgets. A real renewal retires only that row's previous generation. Foreground clears the map. `rowDials` reads the selected budget and stores no counter. `review-fix-01` passes same-Mac two-row exhaustion, reorder, five and ten second due times, alternate failover, equal-timestamp distinct identities, renewal isolation, and foreground reset. | Actual extracted reconnect, timeout, row failure, and lifecycle methods run with supplied rows and a deterministic clock. Bonjour and network behavior remain outside the fixture. |
| P2 remote cancellation assertion was vacuous | The test advances from loss at 100 to the first dial at 103, asserts a live uncancelled connector, retains it, enters background, then asserts cancellation before advancing time. `cancelRemoteDial` is now extracted verbatim from production. Removing only the production lifecycle's actual call causes exactly `FAIL background immediately cancels retained active remote connector`. | The connector records `cancel()` invocation. This is wiring coverage, not full Network.framework or socket cancellation proof. |

`review-fix-01` reports `Reconnect glue: 46/46 passed, 0 failed`, `Upstream sleep policy subset: 43/43 passed, 0 failed`, and `Vision input: 38 behavioral checks passed`. Its cancellation mutant reports `45/46 passed, 1 failed`, with the active-connector precondition still passing. `review-static.json` records 8/8 static constraints. The production policy remains byte-identical to `8aa995c`, preserving 12 attempts and 5/10/20/30 second starts. The original 120 second remote loss window, one due timer owner, and background gates remain covered by the extracted glue checks.

Mini sender and receiver input hashes match. Production and RAM source hashes remain unchanged during validation. `review-fix-01` observes 9748.12 MB swap before and after and unchanged Orca process identities. Its helper reaped every compiler and test child, removed isolated outputs, and detached RAM successfully. This stream is independent RAM validation. It does not pass the `codex-source-guard` transfer acceptance gate.

Model the Domain changed the representation from one selected mutable counter to a map of typed listing identities and budgets. The bug-fix playbook and TDD preserved the failing executable reproduction first. Architect compared a fixed selection with independent listing budgets and selected the latter to retain alternate endpoint failover. Deslop review keeps the production diff in two allowed files. Parent independent review, including core and kind changes, remains open. No tests or self-inspection are counted as that review.

## Final receipts and handoff for this unit

Updated 2026-10-16T09:09:44.521975+09:00.

| Receipt | Result |
| --- | --- |
| `review-repro-01` | Fixture compiles and exposes the cap bypass. Some new in-flight row scenarios use the wrong failure precondition, corrected before the product patch. |
| `review-repro-02` | Heavy slot rejected with exit 75. No runner, RAM volume, or compiler started. |
| `review-repro-03` | Corrected glue 34/46. Policy 43/43. Mutation adds the immediate cancellation failure. These failing tests are in `c8cecbf`. |
| `review-fix-01` | Glue 46/46, policy 43/43, Vision input 38/38. The cancellation mutant alone has 45/46 and exactly the intended failure. Source and RAM hashes agree and remain unchanged. |
| `review-fixture-hashes.json` | Full reconstructed fixture hashes reproduce the exact transmitted payload SHA-256. Includes the mutant and prior input test files. |
| `review-static.json` | 8/8 constraints pass. |
| `review-xros-01` | `BUILD SUCCEEDED`, exit 0. Xcode 27.0, unsigned Release XROS 27, jobs 1, Swift num-threads 1. 216 tracked input hashes remain unchanged. |
| `review-artifact.json` | All seven Mini-tested production input hashes match native build inputs. The pointer test main is a fixture, excluded from the native target. Binary SHA-256 `ea88197ca81014b329d7b7b79b7257da8971d455a7024c7127d3af37ba264096`. Bundle `dev.ambrion.SillVision`, SDK `xros27.0`, minimum OS 2.5. No signature directory. |
| `review-cleanup.json` | All 18 recorded Mini runner/compiler/test PIDs and all five recorded local compiler/transport PIDs are absent. All four yielded terminal handles have completed. Heavy slot is free. No reconnect RAM volume or isolated output remains. This owner's native build directory and temporary console copies are removed. Compiler lease is released. |
| `review-readonly-baseline.json` | Both original worktrees are clean at their supplied heads. Final cleanup rechecks those heads, status, production hashes, and untouched prior receipt hashes. |

Native compilation does not prove installation, physical reconnect, actual Bonjour renewal, socket cancellation, or UI behavior. This unit did not install or launch an app or interrupt the movie. Parent independent review of this exact fix candidate, plus the still-open core and kind changes, remains required. This unit makes no `codex-source-guard` transfer acceptance claim. No push or PR was performed. The report remains in this allowed existing document for the parent owner to link into its existing project Page.

Only `StreamClient.swift` and `StreamClient+Remote.swift` change in production. `DiscoveryPolicy.swift`, host, wire, iPad UI, native input targets, and project files are unchanged. The source hash receipts bind the Mini tests and native build to these exact product bytes. A receipt assembly check initially tried to match the test-only pointer main against native production inputs and raised `KeyError` before any cleanup or artifact write. Comparing the seven production inputs and labelling the fixture exclusion fixed the receipt check. No test or native compilation was repeated for that bookkeeping correction.

## Historical candidate evidence

### Original reconnect candidate

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
