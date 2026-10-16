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


## Final code-unit evidence

Parent Mini source-generation-candidate03 passed98native/extracted-client/actual-codec/fence-algorithm checks,38previous behavioral checks, all17generic SessionLink loopback modes and6compiled runtime mutants. The mutants remove debt recording, connection admission, early generation capture, retained release generation, transport readiness and UI readiness; each failed at its specified runtime witness. Sender/receiver and memory/source hashes matched, isolated RAM/output were removed and child/transport processes reaped. Swap9822.19MB remained unchanged; free53→46%, observed Orca7PIDs unchanged. These are bounded observations, not a service-latency or frame-performance benchmark. The independent RAM run is not source-guard same-task transfer acceptance.

Mini02 failed to compile its fixture because Foundation.Published and fakeSwiftUI.Published were both visible. The one-line extraction adapter now qualifies only the copied property wrapper as SwiftUI.Published. Production source, type, binding initializer, access control, logic and mutants are unchanged. Raw production-piece hash and generated-fixture payload hashes remain separate. Planck independently inspected this adapter and found no new P1/P2. Original failure receipt is preserved outside this worktree. The fake wrapper tests stored values, not SwiftUI notification/render behavior.

The separately changed reconnect pointer packaging also compiled and passed46glue checks,43upstream-policy checks and38pointer checks with unchanged input hashes and successful cleanup. Those38repeat the same prior pointer suite and are not extra distinct coverage. Touchrig dependency packaging received shell syntax inspection, not simulator/device execution.

Exact clean production f7fdd1f953c9284a67f1de4226af285cf9f199aa passed XROS27/min2.5 Release build01 and codesign deep/strict, team/bundle verification. All173source/metadata snapshot hashes remained unchanged. Executable SHA-256 fbd48dee3a1fa03d94776d18e3570cbf68935021e522c8fc4bc8637c88c7be54. Compiler/terminal were reaped and the iPad owner received its lease back. Jobs1 was requested; both num-threads1 and num-threads12 occur in the log, so one effective frontend thread is not claimed. This final test/docs adapter changes no product inputs; the parent binds the build snapshot and reviewed blobs to the final commit, including Git symlink text and committed target content.

Planck's narrow source closure at f7fdd1(tree5a3541666d044d6852f3e6ec98ae7bc7b4fe597f) closes the P2 and finds no new P1/P2 in the follow-up. Capture/debt/protocol behavior from c624 remains unchanged. Its coverage limits remain full production retained-catalog dispatch, SwiftUI publication, physical behavior, actual host receive/injection, displayed-frame epoch and same-source geometry. No additional explanatory production comments were added; the new fixture sentinel and wrapper adapter were read-only reviewed.

Peer host148 and c02 were separately published with normal source captures; the parent verified each owner's exact worktree against its receipt. Peer then prepared host integration da9661b and follow-up3bd3c0b4cdf91a2b16f1fd68be9265700acaaff5. Peer reports product builds,41pointer/87source/lifecycle checks at their stated source versions and two narrow independent P2 closures; the one-line3bd3restartOf change has a product rebuild, while the preceding tests belong to da9661b. These host results are not this client's same-task runtime or physical acceptance. No host implementation was copied into this Vision candidate.

No PR, main/baseline merge, install, app/device launch, PC input, audio I/O, microphone or display change is part of this unit. The broader Goal remains active. Physical gestures/IME/off-LAN/reconnect/voice/original-call acceptance and the coordinated frame/geometry boundary remain open.
