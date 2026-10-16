# Vision source generation

Work key `vision-source-generation-20261016`. Original owner `01a13005-ff61-7780-b0e8-6dc171de1c9d`. Exclusive writing branch `codex/vision-source-generation-20261016` starts at `b403986efa84a0741400da2153d0d09b3b00bc81`. Peer component `148090e35780274bab73198c6ac3b645f12fa051` is read-only. Component reuse is semantic integration, not `codex-source-guard` same-task transfer acceptance. Host148 and c02 implementations are outside this change.

## Work checklist

- [x] `how` over the affected subsystem.
- [x] `architect` for parallel design exploration. Sequential A/B comparison under the explicit no-nested-agents instruction. No independent panel verdict.
- [x] Write the throughput checkpoint as four todo items.
  - Blocking first steps. Confirm exact branch, clean HEAD, component Git blobs, and full design finite gates before writing.
  - Independent workstreams. This writer owns coupled native/client/protocol/fixture files. Parent owns Mini execution, compiler lease, and independent review outside this worktree.
  - Shared mutable state. Main owns catalog binding. Captured input owns its generation. SessionLink's existing send lock owns actual-send debt changes.
  - Smallest safe decomposition. One writer keeps admission, queueing, debt, catalog lifecycle, and fixture extraction consistent.
- [x] Delegate code-writing to a subagent using your configured feature model. This delegated writer owns the exclusive diff directly. No nested agents.
- [ ] Verify on the matching surface. Parent must execute actual Swift scenarios and XROS compilation. This writer runs static checks only.
- [x] Rebase into small, ordered commits. Stack follow-ups. This candidate is one coherent commit based on the assigned immutable base. No unrelated commit is merged.
- [ ] If the design is contested, `interrogate` before shipping. No contested design so far. Independent review belongs to the parent.
- [ ] Run **Opening a PR**. Skip. Push, PR, network, and deployment are outside this writer's authorization.

Architect phases Ground, Sketch, Agree, and Implement are complete for the candidate. Scrap was unnecessary because implementation retained B's ownership and ordering contracts. Runtime acceptance remains open.

## Problem and existing flow

The b403 native client sends raw InputEvent and advertises no scoped-input capability. Peer148 rotates an opaque generation for every source identity change and uses SourceInputFence to reject stale input before injection. An unnegotiated connection keeps its legacy source pin, so adding only the codec does not let this native connection follow another source.

Native input is admitted on main, serialized before entering the network queue, and sent through SessionLink's locked `onlyOn` method. Its weak actual-send callback records debt only after Network receives the bytes, including delayed hold/fence flushes. Cancellation discards unsent inputs and derives releases from transmitted downs. Ordinary chord preparation preserves queued complete chords. The connection setter replaces and releases under one lock. A viable move drains asynchronously before its fence ping. These contracts remain required.

## Usage and shape

The caller still invokes `client.sendInput(event)`. On Vision, admission creates `CapturedVisionInput(event:generation:)` before enqueueing. Serialization uses the peer's `SourceInput.payload`; nil generation preserves old-host raw input. The actual-send callback records the captured value. Debt synthesizes terminal events by replacing the event while retaining the down's generation.

`applyVisionInputCatalog(_:from:)` checks the originating peer, drains local held ownership and queues transport cancellation before publishing a changed generation or active source. It applies the current catalog only. Connection replacement, move, and teardown clear the binding. No extra generation is invented by the client. Model the Domain determines the event value and debt ownership instead of optional generation arguments at each release call site.

## Alternatives and synthesis

| Candidate | Caller and state ownership | Release behavior | Decision |
| --- | --- | --- | --- |
| A | Pass an optional generation through send; release paths read the catalog again. | A held down can become a release stamped with B, including after A returns with a new token. | Reject. Small signatures expose temporal coordination to every caller and split ownership. |
| B | Capture event and generation in one native value before queueing; retain it in actual-send debt. | Synthesized up retains the corresponding down's token. Catalog drain is ordered before new admission. | Select and refine. Existing send API stays small while the value and ledger hide scope preservation. |

B passed the architect screen for split ownership, temporal decomposition, pass-through layers, and hand-synced protocol policy. The peer codec remains the sole wire policy. B adds no wire kind. Optional inputGeneration is composed with this branch's remoteAudio field. Only Vision advertises Hello.sourceInput=1. The shared iPad path remains legacy and unadvertised.

We accept raw fallback for older hosts in exchange for compatibility. This provides weaker protection and establishes no safety result for oldhost563. We accept asynchronous cancellation ordered on the existing serial queue in exchange for preserving the b403 nonblocking main/network contract.

## Baseline witness

Parent `source-generation/baseline02.log` compiled the actual b403 Hello closure with peer148's exact SourceInputFence and codec on Mini RAM. It passed 2 of 3 assertions and exited 1 at `FAIL scoped Vision releases legacy source pin`. The envelope exited 0 because it expected that precise failure witness. This is a reproduced baseline defect, not a candidate pass. Baseline01's missing Data helper compile error remains a separate fixture-assembly failure. Evidence lives under `work/verification/vision-remote-spatial-20261016/source-generation/baseline02.{json,log}` outside this worktree.

## Boundaries and verification plan

Frames and ParameterSets carry no generation. The host can emit frames before the corresponding catalog; unchanged parameter sets do not flush the client's display. This input change proves no video or presentation fence. Same-source geometry changes remain unsupported by a source identity token. Physical gestures, off-LAN behavior, original application IME, original calls, host installation, and c02 physical acceptance remain open.

The candidate fixture must use actual Input, Switcher/Wire, StreamMessage/Data helpers, Compatibility/Hello, and peer148 SourceInputFence. Fake Network only records transmitted bytes. Deterministic scenarios cover retained-generation releases, capture before enqueue, A-to-B-to-A stale rejection, raw fallback, current-peer catalogs, lifecycle reset, ordinary chords, stop controls, and actual-transmitted debt. Parent runs a finite Mini attempt and at most two corrections per unchanged hypothesis, then signed XROS compilation under its lease and independent review. This writer executes no compiler, runtime test, app, device, audio, browser, messaging, or push action.

## Implementation reconciliation

The native value lives in the existing VisionInputDebt product file, so the project and generator need no new product entry. Held keys retain their captured input. Pointer moves update coordinates while preserving the down's generation. Scroll and key terminal events also retain the original token. Native admission serializes the captured value before queueing, and the existing weak actual-send callback records it under SessionLink's lock. No SessionLink or normal-chord implementation changed.

The catalog method owns the native binding and active/list mutation. It refuses a replaced peer, drains local pointer/keyboard ownership, and queues cancellation before publishing the next generation and source. Earlier queued sends finish before that cancellation; later admission follows it. This preserves the existing nonblocking main/network contract and does not assert a synchronous transport ACK. Connection setter replacement still releases atomically on the old peer. Move and teardown clear the generation through their existing drain paths.

The test fixture includes exact peer148 SourceInputFence as test-only code. Its Git blob is `17918baec9691e5118000c42e348717bb29ef341`. Input and Compatibility blobs are `82b454edc3cc818a7c8ccd372a3861c897161864` and `8bd6f3d0b3dcdea6bff2f855f6af6153d48b1223`. Peer owner subsequently reported publication and capture of commit148/tree `888d2b2aef151844f1f4eff08df6f9df0ca92f04`; parent owns receipt verification. This writer verified the reused local blob identities and did not treat that reuse as a Vision source-transfer receipt.

The fixture now uses actual Wire, WindowList, Hello, and 14-byte StreamMessage framing. Its fake Network has a separate module and only records sends. The controls runner builds Input, Switcher, StreamMessage, and Compatibility together with whole-module optimization to emit one module object. Reconnect's optional pointer runner and the existing touch rig also include the added Wire/Data helper dependencies. None of these runners was executed here.

New deterministic Swift scenarios cover the real native Hello releasing the real legacy source pin, non-Vision Hello retaining that pin, old-host raw fallback, remoteAudio composition, held-source releases, queue capture before a catalog change, A-to-B-to-A rejection, current-peer refusal, connection/move/teardown resets, source-change cancellation of unsent downs, queued terminal releases, and a delayed actual-send callback after binding publication. Debt checks cover right button coordinates, scroll scope, reverse key release flags, wrong-peer refusal, and idempotence. Four runtime mutants target debt recording, route admission, late generation capture, and generation loss in synthesized releases. These are prepared tests, not candidate runtime results.

The 22 checks in `Tests/checks/vision-input-controls/static.py` pass. They verify exact peer blobs, unchanged iPad input branch, unchanged SessionLink, StreamMessage, and normal chord/stop code, limited Switcher composition, native capture/drain ordering, fixture extraction, mutation application, dependency packaging, and Python syntax. `bash -n Tests/touchrig/run.sh` and `git diff --check` also pass. The local diff received a deslop pass. No independent source or comment review ran in this writer; parent review remains required. Pstack poteto-mode and Feature organized the gates, architect compared A and B, and Model the Domain determined captured-event ownership.

An initial local Git object lookup in the Vision repository triggered Git's implicit promisor fetch for the absent peer commit and failed. It did not retrieve that commit. Subsequent component reads used `git --no-lazy-fetch show` in the peer repository, and static baseline reads also disable lazy fetching. This was an unintended network attempt under the writer's no-network constraint. No push, PR, host install, app/device launch, audio, or browser action occurred.

## Parent execution handoff

From this exact committed worktree, the parent can run these commands after its source/host and compiler-lease checks:

```sh
python3 -B Tests/checks/vision-input-controls/static.py
python3 -B Tests/checks/vision-input-controls/mini.py source-generation-candidate01
python3 -B Tests/checks/reconnect-glue/mini.py source-generation-pointer01 --pointer
```

The Mini controls runner includes candidate scenarios, four runtime mutants, the prior pointer suite, and the 17 existing SessionLink modes. Labels must be reconciled before reuse. The run streams hashed inputs to RAM with isolated output and cleanup evidence. A passing RAM run remains independent validation, not source-guard same-task transfer acceptance. Parent must compile/sign the exact XROS candidate under its lease, independently review it, and update the original project Page. No runtime or XROS result is claimed here. The baseline02 expected-failure envelope remains separate from candidate evidence.
