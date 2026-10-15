# Vision reconnect candidate

Work key `vision-sill-reconnect-20261016`. Owner is this bounded reconnect worker. Exclusive worktree `work/sill-vision-reconnect`, branch `codex/vision-sill-reconnect-20261016`, base `62bc4c5884bf54f4eb729b71e082d0fa8d7d8609`.

Production writes are limited to `iOSClient/StreamClient.swift`, `iOSClient/StreamClient+Remote.swift`, and `iOSClient/DiscoveryPolicy.swift`. Test artifacts stay in `Tests/checks/reconnect-glue`. The parent checkout and installed signed app are outside this unit.

## Procedure

- [ ] 1. Reproduce it yourself on the matching surface via the driver skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
- [ ] 2. Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Claude Code's `loop` skill. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
- [ ] 3. Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default in poteto-mode's Models section) with a specific scope.
- [ ] 4. Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
- [ ] 5. Stage the commits so the failing repro lands before the fix in git history. See the **tdd** skill for the failing-test-first cadence when the bug has a cheap local test path. Skip it when the test would be expensive, integration-heavy, or unclear.
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

Initial runtime reproduction is complete and is committed before production changes. Physical reproduction and independent review remain open. Architect ground and sketch are complete as sequential analysis. Agree has no user checkpoint. Implement is next. Scrap applies only if the selected ownership fails a concrete check.
