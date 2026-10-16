# Vision audio player component

Work key `vision-audio-playback-20261016`. This component belongs to the parent Vision audio integration. Its exclusive branch is `codex/vision-audio-playback-20261016`, based on `8ef216d121ac3e98fb3c098814c10b7d6cc2dd1b`. Writes are limited to the two Vision audio files, `Tests/checks/vision-audio-player`, and this document. The parent owns consent, transport, common wire, final native compilation, and independent review.

## Procedure

- [x] 1. `how` over the affected subsystem.
- [x] 2. `architect` for parallel design exploration.
  Sequential analysis only. This delegate owns the assigned diff and has no subagent dispatch. Parent independent review stays open.
- [x] 3. Write the throughput checkpoint as four todo items.
  Blocking first steps. Confirm clean branch and exact AAC source before implementation. Wait for the parent's Mini lease release.
  Independent workstreams. This delegate owns only playback. Consent and common wire remain in their existing parent and peer worktrees.
  Shared mutable state. Put grant, format version, mailbox, and render state under one lock. A process lease serializes session ownership across windows.
  Smallest safe decomposition. Keep one pure domain file and one native adapter. Tests never import or construct audio engines or sessions.
- [x] 4. Delegate code-writing to a subagent using your configured feature model with a specific scope.
  This is the parent's exclusive component delegation. The delegate owns the diff directly and returns it for parent review.
- [ ] 5. Verify on the matching surface.
  Pure checks run through bounded Mini RAM. Native compilation and device playback require the parent's final lease and review.
- [ ] 6. Rebase into small, ordered commits. Stack follow-ups.
  Preserve test-first scaffold and subsequent implementation as clean local commits.
- [ ] 7. If the design is contested, `interrogate` before shipping.
  No contested design. Parent independent review remains required.
- [ ] 8. Run **Opening a PR**.
  Skip under the user's explicit no push and no PR instruction.

## Domain and design

The existing committed player dispatches every packet to a decode queue, grows an array, locks the render thread, and activates a shared session during restart. It treats engine startup as playback readiness and has no per-window session owner. Only the AAC converter algorithm is reused.

`Model the Domain` selects a bounded mailbox, finite PCM ring, grant ticket, and process lease. An actor with a queue of audio callbacks would serialize admission but leave render revocation and queued message volume outside that actor. The chosen lock state makes stop, decoded admission, and render epoch checks share one revocation point. The renderer tries the lock once and emits prezeroed silence on contention. It never calls the controller.

Caller usage is `begin(grant:onEvent:)`, then `receive(_:grant:)`, then `stop()`. The caller supplies an authenticated subscription ACK before begin. Begin establishes a ticket and takes a session lease without constructing audio objects. A second begin refuses while the first lease exists. Stop clears admission and PCM synchronously. The main queue owns actual engine and session cleanup for the exact retiring ticket.

## Validation ledger

Scoped TDD writes behavioral checks before the PCM admission implementation. The first Mini run exercises a compiling empty-admission scaffold. The implementation follows that failing receipt. Total execution budget is one run and two diagnostic corrections. No local compiler, native build, launch, audio I/O, browser, service mutation, remote checkout, push, or PR is authorized in this unit.

The Mini helper follows `Tests/checks/reconnect-glue/mini.py` without editing it. It hashes the streamed input, verifies every received file, uses a 64MiB RAM source volume, compiles only pure domain code, rechecks source hashes, reaps children, removes isolated outputs, and detaches RAM. It observes memory pressure, swap, Orca, AVD process identity, and container status. This is independent component validation, not same-task cross-host transfer acceptance.

## Provenance

AAC source is read only through `git show 89f955072e520b6b0aaa00b1e19c26afc3d9fdb3:iOSClient/RemoteAudioPlayer.swift` in `/Users/ambrion/Documents/ChatGPT/BT_CCR-Sill-iPad`. The source blob is `ffdbfc457feb82e94bfbdffc79006de5a99049a7`. No dirty peer files or peer tests supply evidence. Parent supplies the existing `AudioPacket` declaration from the same commit. This component adds no wire declaration.
