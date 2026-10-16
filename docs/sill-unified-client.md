# Sill unified client integration

Work key `sill-unified-client-20261016`. This writer exclusively owns `work/sill-unified-client` on `codex/sill-unified-client-20261016`. The original worktrees are frozen. The first parent is `f331d8d307fb301e1c0f2bfd71e4a83a76d62dbc`. The authorized peer is `3bd3c0b4cdf91a2b16f1fd68be9265700acaaff5`. Their merge base is `d669a813454603f76074491724ecb4339ad2185c`. All object reads disable lazy fetch. No canonical source, peer worktree, remote branch, or service is changed.

## Grounding before code

`StreamClient` owns transport, discovery, connection identity, delivery, and catalog application. `SessionLink` serializes sends and handover. The Vision connection setter drains actual submitted input debt before replacement. `VisionInputBinding` distinguishes an unresolved catalog, a confirmed legacy host, and a scoped source generation. `CapturedVisionInput` captures that decision before queue submission. `VisionInputDebt` records accepted sends on their actual peer. The Vision finishMove wrapper drains before adopting the new connection.

The peer iPad path captures `SourceInput.payload` before queue submission. Its coalescer retains serialized `Data`, so a queued move cannot acquire a newer source generation. The iPad audio controller owns consent and passes the actual originating peer through the adapter. Vision owns its independent opt-in controller and route. Neither audio policy may consume the other platform's messages. A catalog queued on an old connection cannot update either input binding or audio capability.

The caller still uses `sendInput`, `select`, and the existing platform audio controls. The organizing data shapes remain `VisionInputBinding`, `CapturedVisionInput`, and iPad's captured payload `Data`. No new engine or generic policy type is needed.

## Structure alternatives

| Candidate | Structure | Decision |
| --- | --- | --- |
| A | Fork the complete StreamClient for Vision and iPad. | Reject. Connection identity, reconnect, and handover would have two owners and diverging implementations. |
| B | Keep one transport and use narrow compile-time branches at input, audio, and catalog policy boundaries. | Choose. Reuses both existing controllers and each platform's input representation without expanding the caller API. |
| C | Add an erased shared audio or input policy protocol. | Reject. Adds interfaces and indirection without removing a required platform difference. |

The design screen checks split state ownership, shallow wrappers, copied transport, and source lists that can drift. B retains the existing state owners. The native generator remains independent of iPad UI and player files. The iPad Xcode project remains exactly the peer project.

## Chosen contract

- Preserve peer host sources, existing probes, host tests, iPad Canvas, UI, store, audio player, controller, and project byte for byte. The audio adapter may gain only a compile-time Vision exclusion.
- Preserve all protocol files exactly as both parents. Advertise `Hello.sourceInput = 1` on both paths only with their real scoped codecs present.
- Preserve the Vision application, input binding, capture, debt, session, audio controller and player, fence, transitions, normal release, discovery, remote, viewport, and HEVC guards from f331.
- Reconcile the connection setter, finishMove and drain, teardown and loss, request, actual-origin delivery, catalog, and input branches. Keep Vision debt and readiness admission and the peer iPad generation and coalesced payload semantics.
- Keep native source choice explicit and native viewport writes disabled. The parent found a preexisting latent compatibility P2 in reconnect restoration. Clear `resumeSource` as before, then require `!Self.noAutoDesktop` before any automatic resume request. With the policy false, iPad keeps the peer behavior, including the missing-window desktop fallback. Add an actual extracted branch fixture with no host effects.
- Select platform conditionals in fixtures before extraction. Keep qualified `@SwiftUI.Published` in the fake native module. Keep the actual iPad scenePhase OFF body.

## Procedure and throughput checkpoint

The pstack poteto-mode Feature procedure, how, architect, and Model the Domain guide this integration. A/B exploration is a labelled sequential pass because nested agents are forbidden. This writer owns the delegated diff directly. Parent review is independent and remains a separate gate.

- [x] `how` over the affected subsystem.
- [x] `architect` for parallel design exploration. Sequential A/B alternatives above honor the no-nested-agents instruction.
- [x] Blocking first steps. Exact heads, clean branch, Git remote, merge base, parent contract, and ownership checked before writing code.
- [x] Independent workstreams. Parent owns Mini, SDK builds, and independent review outside this tree. This writer owns the coupled merge and static fixtures.
- [x] Shared mutable state. Keep SessionLink, Vision binding and debt, and each platform's audio controller as their existing sole owners.
- [x] Smallest safe decomposition. One writer resolves the common client and extraction together because both depend on the same compile-time branches.
- [x] Delegate code-writing to a subagent. This delegated exclusive writer owns the diff directly under Feature step 4's no-nested-agent clause.
- [ ] Verify on the matching surface. Static checks here. Runtime, Mini, Apple SDK compilation, and independent review belong to the parent.
- [x] Rebase into small, ordered commits. Preserve the actual two-parent merge and stack fixture or documentation followups as needed. Do not rebase away either parent.
- [x] If the design is contested, `interrogate` before shipping. Skip. No design contest and no shipping in scope.
- [x] Run Opening a PR. Skip. Network, messages, push, and publication are forbidden for this writer.

## Bounds and acceptance

Each static failure gets one diagnosis and at most two corrections per unchanged hypothesis. Allowed commands are Git, Python source inspection and extraction, generators, and shell syntax checks. No compiler, build, runtime suite, network, app, browser, device, audio, message, push, or deployment is run here.

The preservation manifest records exact blobs and changed boundaries. Static success establishes composition only. Parent Mini checks, exact SDK builds, independent review, source provenance, canonical integration, and publication remain pending. The full Goal is not complete. Frame epoch, geometry epoch, off-LAN, physical device, microphone, and original-call acceptance remain separate.

## Static handback

The source checks pass. The preservation manifest contains 352 exact files in five groups. The rerunnable unified check reports 739 assertions including manifest equality. Native input composition has 34 checks, reconnect composition has 9, native audio consent has 18, and native audio player has 12. The iPad audio extractor passes 11 wiring assertions. Host audio lifecycle wiring catches 8 deletion variants by source inspection. These are static results, not executed Swift behavior.

`python3 -B Tests/checks/sill-unified-client/static.py` checks the preservation manifest. The native input and reconnect `static.py` scripts check actual extraction and source invariants. The audio consent and player `static.py` scripts accept `--output-dir` so historical receipts remain unchanged. The iPad `fixture.py` and `player-fixture.py` produce the actual selected setter, constructor, adapter, scenePhase OFF body, and player fixture. `delayed-source-input/run.py --emit-swift` emits the selected iPad input path. Native input extraction produces 39 files, including six existing source mutants and the new actual resume branch witness. Swift execution of the resume witness is pending with the parent.

The native project generator reproduces the exact f331 project bytes with 37 source files and excludes iPad player, UI, and adapter. Three affected shell entry points pass `bash -n`. `git diff --check` passes. Static assembly exposed stale historical assertions for unadvertised iPad input, pre-wrapper handover, UI sibling spacing, the original four-component snapshot before source generation, and pre-origin reconnect delivery. They now compare the current frozen parents and keep source, debt, readiness, and origin checks.

The localized P2 changes only the resume condition. The actual extracted branch tests a consumed pending choice with no requests under `noAutoDesktop = true`, preserved iPad missing-window fallback and surviving-window restore under `false`, and no replacement when the host already streams. No new automatic source effect is added. The `9011fae` dictation successor is out of scope.

Parent retains Mini execution, Apple SDK builds, independent review, provenance, canonical merge verification, Space reporting, and publication. No source-guard receipt for canonical f331 is changed or claimed here. No full Goal completion is claimed.
