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
- [x] Rebase into small, ordered commits. Stack follow-ups. Initial candidate c624 is preserved; the catalog-wait correction follows it as a separate coherent commit. No unrelated commit is merged.
- [ ] If the design is contested, `interrogate` before shipping. No contested design so far. Independent review belongs to the parent.
- [ ] Run **Opening a PR**. Skip. Push, PR, network, and deployment are outside this writer's authorization.

Architect phases Ground, Sketch, Agree, and Implement are complete for the candidate. Scrap was unnecessary because implementation retained B's ownership and ordering contracts. Runtime acceptance remains open.

## Problem and existing flow

The b403 native client sends raw InputEvent and advertises no scoped-input capability. Peer148 rotates an opaque generation for every source identity change and uses SourceInputFence to reject stale input before injection. An unnegotiated connection keeps its legacy source pin, so adding only the codec does not let this native connection follow another source.

Native input is admitted on main, serialized before entering the network queue, and sent through SessionLink's locked `onlyOn` method. Its weak actual-send callback records debt only after Network receives the bytes, including delayed hold/fence flushes. Cancellation discards unsent inputs and derives releases from transmitted downs. Ordinary chord preparation preserves queued complete chords. The connection setter replaces and releases under one lock. A viable move drains asynchronously before its fence ping. These contracts remain required.

## Usage and shape

The caller still invokes `client.sendInput(event)`. VisionInputBinding distinguishes awaitingCatalog, confirmedLegacy, and scoped(generation). Its capture method refuses awaitingCatalog, admits a raw captured event for confirmedLegacy, and admits a generation-bearing captured event for scoped. Only a current-peer catalog can confirm legacy or scoped input. Admission captures before enqueueing. Serialization uses the peer's `SourceInput.payload`. The actual-send callback records the captured value. Debt synthesizes terminal events by replacing the event while retaining the down's generation.

`applyVisionInputCatalog(_:from:)` checks the originating peer, drains local held ownership and queues transport cancellation before publishing a changed source or binding. It applies the current catalog only and confirms admission after the active/list update. Connection replacement, move, and teardown invalidate the binding to awaitingCatalog. Both VisionInputSession.canSend and native StreamClient.sendInput require catalog confirmation. No extra generation is invented by the client. Model the Domain determines the binding and event value instead of optional generation arguments at each release call site.

## Alternatives and synthesis

| Candidate | Caller and state ownership | Release behavior | Decision |
| --- | --- | --- | --- |
| A | Pass an optional generation through send; release paths read the catalog again. | A held down can become a release stamped with B, including after A returns with a new token. | Reject. Small signatures expose temporal coordination to every caller and split ownership. |
| B | Capture event and generation in one native value before queueing; retain it in actual-send debt. | Synthesized up retains the corresponding down's token. Catalog drain is ordered before new admission. | Select and refine. Existing send API stays small while the value and ledger hide scope preservation. |

B passed the architect screen for split ownership, temporal decomposition, pass-through layers, and hand-synced protocol policy. The peer codec remains the sole wire policy. B adds no wire kind. Optional inputGeneration is composed with this branch's remoteAudio field. Only Vision advertises Hello.sourceInput=1. The shared iPad path remains legacy and unadvertised.

We accept raw fallback after a current-peer legacy catalog in exchange for compatibility. This provides weaker protection and establishes no safety result for oldhost563. An unresolved binding never means legacy. We accept asynchronous cancellation ordered on the existing serial queue in exchange for preserving the b403 nonblocking main/network contract.

## Baseline witness

Parent `source-generation/baseline02.log` compiled the actual b403 Hello closure with peer148's exact SourceInputFence and codec on Mini RAM. It passed 2 of 3 assertions and exited 1 at `FAIL scoped Vision releases legacy source pin`. The envelope exited 0 because it expected that precise failure witness. This is a reproduced baseline defect, not a candidate pass. Baseline01's missing Data helper compile error remains a separate fixture-assembly failure. Evidence lives under `work/verification/vision-remote-spatial-20261016/source-generation/baseline02.{json,log}` outside this worktree.

## Boundaries and verification plan

Frames and ParameterSets carry no generation. The host can emit frames before the corresponding catalog; unchanged parameter sets do not flush the client's display. This input change proves no video or presentation fence. Same-source geometry changes remain unsupported by a source identity token. Physical gestures, off-LAN behavior, original application IME, original calls, host installation, and c02 physical acceptance remain open.

The candidate fixture must use actual Input, Switcher/Wire, StreamMessage/Data helpers, Compatibility/Hello, and peer148 SourceInputFence. Fake Network only records transmitted bytes. Deterministic scenarios cover retained-generation releases, capture before enqueue, A-to-B-to-A stale rejection, raw fallback, current-peer catalogs, lifecycle reset, ordinary chords, stop controls, and actual-transmitted debt. Parent runs a finite Mini attempt and at most two corrections per unchanged hypothesis, then signed XROS compilation under its lease and independent review. This writer executes no compiler, runtime test, app, device, audio, browser, messaging, or push action.

## Initial implementation reconciliation at c624

The native value lives in the existing VisionInputDebt product file, so the project and generator need no new product entry. Held keys retain their captured input. Pointer moves update coordinates while preserving the down's generation. Scroll and key terminal events also retain the original token. Native admission serializes the captured value before queueing, and the existing weak actual-send callback records it under SessionLink's lock. No SessionLink or normal-chord implementation changed.

The catalog method owns the native binding and active/list mutation. It refuses a replaced peer, drains local pointer/keyboard ownership, and queues cancellation before publishing the next generation and source. Earlier queued sends finish before that cancellation; later admission follows it. This preserves the existing nonblocking main/network contract and does not assert a synchronous transport ACK. Connection setter replacement still releases atomically on the old peer. Move and teardown clear the generation through their existing drain paths.

The test fixture includes exact peer148 SourceInputFence as test-only code. Its Git blob is `17918baec9691e5118000c42e348717bb29ef341`. Input and Compatibility blobs are `82b454edc3cc818a7c8ccd372a3861c897161864` and `8bd6f3d0b3dcdea6bff2f855f6af6153d48b1223`. Peer owner subsequently reported publication and capture of commit148/tree `888d2b2aef151844f1f4eff08df6f9df0ca92f04`; parent owns receipt verification. This writer verified the reused local blob identities and did not treat that reuse as a Vision source-transfer receipt.

The fixture now uses actual Wire, WindowList, Hello, and 14-byte StreamMessage framing. Its fake Network has a separate module and only records sends. The controls runner builds Input, Switcher, StreamMessage, and Compatibility together with whole-module optimization to emit one module object. Reconnect's optional pointer runner and the existing touch rig also include the added Wire/Data helper dependencies. None of these runners was executed here.

New deterministic Swift scenarios cover the real native Hello releasing the real legacy source pin, non-Vision Hello retaining that pin, old-host raw fallback, remoteAudio composition, held-source releases, queue capture before a catalog change, A-to-B-to-A rejection, current-peer refusal, connection/move/teardown resets, source-change cancellation of unsent downs, queued terminal releases, and a delayed actual-send callback after binding publication. Debt checks cover right button coordinates, scroll scope, reverse key release flags, wrong-peer refusal, and idempotence. Four runtime mutants target debt recording, route admission, late generation capture, and generation loss in synthesized releases. These are prepared tests, not candidate runtime results.

At c624, the 22 checks in `Tests/checks/vision-input-controls/static.py` passed. They verified exact peer blobs, unchanged iPad input branch, unchanged SessionLink, StreamMessage, and normal chord/stop code, limited Switcher composition, native capture/drain ordering, fixture extraction, mutation application, dependency packaging, and Python syntax. `bash -n Tests/touchrig/run.sh` and `git diff --check` also passed. The local diff received a deslop pass. No independent source or comment review ran in this writer. Pstack poteto-mode and Feature organized the gates, architect compared A and B, and Model the Domain determined captured-event ownership.

An initial local Git object lookup in the Vision repository triggered Git's implicit promisor fetch for the absent peer commit and failed. It did not retrieve that commit. Subsequent component reads used `git --no-lazy-fetch show` in the peer repository, and static baseline reads also disable lazy fetching. This was an unintended network attempt under the writer's no-network constraint. No push, PR, host install, app/device launch, audio, or browser action occurred.

## Planck P2 and catalog-wait correction

Parent reports candidate01 at c624 passed 88 controls/source scenarios, the prior 38 pointer checks, 17 SessionLink modes, and four runtime mutants. Those results are retained as evidence for c624. They did not cover the unresolved-catalog admission defect and do not prove this follow-up.

Planck's independent source review found one new P2 and no other P1 or P2. The move path reset the generation to nil, then restored moving=false while connected and active still described the old source. Retained catalogs reach main later through deliver. Both the UI and core admitted raw input during that gap. A Hello1 host rejects it, so keys could disappear. Setter and teardown resets had the same nil ambiguity, and several fixture expectations encoded the wrong raw fallback.

Parent reproduced the move gap with actual extracted move wrapper/reset and VisionInputSession. `source-generation/catalog-wait01.log` fails at `awaiting fresh catalog keeps native controls disabled`, runtime exit -5. Its envelope exits 0 because it expects that specific failure; source/stdin hashes and RAM/output cleanup passed. The receipt explicitly limits its fake Network/finish-body dependency and does not prove physical or transport acknowledgment behavior. Evidence remains under `work/verification/vision-remote-spatial-20261016/source-generation/catalog-wait01.{json,log}` outside this worktree.

Parent and Planck accepted de-ambiguating B's binding as awaitingCatalog, confirmedLegacy, or scoped(generation). Pstack correct puts this distinction in the domain type rather than adding a second boolean beside optional generation. CapturedVisionInput, serialization, weak didSend, and actual-transmitted debt remain identical to c624. Protocol blobs, audio fields, SessionLink, host code, and project entries also remain unchanged in this follow-up.

The client publishes one typed binding. Connection replacement, accepted move, and teardown set awaitingCatalog. The ordinary validated retained-catalog delivery path remains unchanged; a move can restore moving=false while admission stays closed. Only applyVisionInputCatalog for the current peer confirms legacy or scoped readiness, after enqueueing old debt cleanup and applying active/list. Retained catalogs from a peer replaced before delivery fail the same guard. The workspace shows a waiting message beside the available release control. Palette presentation also reads the published binding, so catalog readiness changes update its disabled state. Pointer, keyboard, palette, and direct native sends remain gated separately from release/stop controls.

The controls fixture now extracts the actual published binding declaration and uses the same model as the product. Its fake finish body retains supplied messages until an explicit delivery step, modeling the delayed main catalog without replacing admission logic. Tests exercise the actual move wrapper/reset, VisionInputSession, native send admission, and peer148 SourceInputFence. They require no admitted bytes or pointer notes before a current-peer catalog, accepted SourceInput afterward, and raw fallback only after a separate confirmed legacy catalog. Prior controls scenarios explicitly seed legacy catalogs; their event count assertions remain intact. Reset tests that previously expected premature raw input now require blocked admission.

Two additional prepared mutants remove UI readiness and core readiness separately. Their required failure witnesses are `awaiting fresh catalog keeps native controls disabled` and `awaiting fresh catalog blocks native transport before enqueue`. The core witness also checks SessionLink's queued-input count and native pointer notes, so a fence hiding an admitted raw packet cannot make it pass. The late-capture mutant uses the typed binding capture method. No mutant, Swift suite, compiler, or XROS build was executed by this writer.

The updated 29 static checks pass, including typed binding, both gates, published UI readiness, lifecycle invalidation, normal retained delivery, exact wire blobs, unchanged capture/debt, and six applied mutant sources. `git diff --check` passes. Independent closure, the six runtime mutant results, the updated controls suite, and XROS compilation/signing remain parent gates. This follow-up uses only local reads with lazy fetching disabled and makes no network, host, device, audio, frame epoch, microphone, push, or deployment change.

## Parent execution handoff

From this exact committed worktree, the parent can run these commands after its source/host and compiler-lease checks:

```sh
python3 -B Tests/checks/vision-input-controls/static.py
python3 -B Tests/checks/vision-input-controls/mini.py source-generation-candidate02
```

The Mini controls runner includes updated candidate scenarios, six runtime mutants, the prior pointer suite, and the 17 existing SessionLink modes. Parent controls the compiler lease; host compilation currently owns it and this writer does not start a competing run. Labels must be reconciled before reuse. The run streams hashed inputs to RAM with isolated output and cleanup evidence. A passing RAM run remains independent validation, not source-guard same-task transfer acceptance. Parent must compile/sign the exact XROS candidate under its lease, independently close Planck's P2, and update the original project Page. No follow-up runtime or XROS result is claimed here. The baseline02 and catalog-wait01 expected-failure envelopes remain separate from candidate evidence.
