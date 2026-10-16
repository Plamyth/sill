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
- [x] 5. Verify on the matching surface.
  Pure checks pass through bounded Mini RAM. Native compilation and device playback remain unverified and require the parent's final lease and review.
- [x] 6. Rebase into small, ordered commits. Stack follow-ups.
  Test-first scaffold is `618bf706257d5298e5accce1ead05d687d19e9ab`. Failing receipts precede the implementation commit. No rebase is needed on this exclusive branch.
- [x] 7. If the design is contested, `interrogate` before shipping.
  Skip. No contested design. Parent independent review remains required.
- [x] 8. Run **Opening a PR**.
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

`Tests/checks/vision-audio-player/provenance.json` preserves SHA-256 for the original committed file, original decoder block, adapted decoder block, and both delivered component files. The original file SHA-256 is `830a816957ceb2a464c7dc2d099a609213afe55b9d9acaa1b5fb3f96b0413c4a`. Decoder adaptation adds format, packet, output-frame, and converter-error guards. The converter's AAC-ELD description, cookie setup, compressed input callback, and interleaved float output follow the committed algorithm.

The parent subsequently reports importing common wire at clean peer `d962c090`. This delegate has not tested that integration. Its blocked ordinary source capture is not accepted here as task-transfer proof. Parent checks the final adapter against those exact shared declarations.

## Delivered behavior

| Boundary | Component behavior |
| --- | --- |
| Begin and default off | Begin takes a process lease and records a fresh internal epoch. No session, engine, decoder, or polling timer starts. Default-off stop has no ticket and returns without audio API access. Begin's initial waiting callback is asynchronous on main. |
| Ingress | At most eight queued packets and 128KiB total. Each packet is at most 32KiB. Queue overflow drops the oldest packets. Queued packets expire after 100ms. One scheduled drain owns at most one in-flight decode. Grant, age, and gap are checked again before decoded admission. |
| Decoder discontinuity | Drops and expiry advance a discontinuity counter. The next work resets AAC state. Stop or a new internal epoch invalidates every prior decode result. Unsupported formats and decoder errors close admission with an explicit failure. |
| PCM | Mono or stereo at 8 to 96 kHz. One allocation holds 14,400 frames with two float slots per frame. No render allocation or array growth occurs. Prefill is 40ms. More than 150ms buffered trims to the newest 60ms. Rendered PCM also expires after 150ms without admission. Main activation requires PCM admitted within 100ms. |
| Render and notification | Output is zeroed first. `withLockIfAvailable` tries once. A busy lock leaves silence. Ticket and format version are checked under the same lock as revoke. Only actual sample consumption sets rendering. The next empty block sets waiting. Main polls every 20ms after engine startup and coalesces equal states. The render thread dispatches no events. |
| Stop and cleanup | Stop clears admission, mailbox, PCM, and render state synchronously. Main stops the exact engine and then deactivates only its own attempted session. Foreign and late cleanup cannot release a new owner's lease. Main cleanup must finish before a new begin can obtain the lease. |
| Session policy | Playback uses only `mixWithOthers` with the default playback mode. This component adds no microphone, routing, device selection, ducking, or interruption observer. Parent owns interruptions. |

The renderer and activation share the admission lock. Session activation and engine start run on main under that lock so a completed synchronous stop cannot be followed by an already queued stale restart. Render contention returns silence. Controller callbacks run outside that lock and never synchronously read controller state. The parent always dispatches callbacks asynchronously to main and rejects stale callback grants. A callback already crossing the delivery boundary can therefore be discarded by the parent after revoke.

If deactivation throws, cleanup retains the process lease and reports the error. Failure cleanup adds the cleanup error to the failed callback. Cleanup after explicit stop logs the error because stop has revoked callbacks. Retaining the lease prevents another window from inheriting a potentially active session. A failed playback ticket permits one subsequent explicit stop to retry cleanup. This OS error path remains a native integration check, including recovery after failure during explicit stop.

## Final evidence

Updated 2026-10-16. `poteto-mode`, `how`, `architect`, Model the Domain, scoped TDD, deslop, unslop, and technical-writing were applied. Domain modeling replaced scattered queue and playback flags with mailbox, ring, epoch, and lease types. Scoped TDD committed executable checks and a compiling empty-admission scaffold before the implementation. Sequential design inspection is not independent review.

| Attempt | Result |
| --- | --- |
| `01-red` | Exit 1 at preflight because Mini has no Docker CLI. No RAM volume or compiler started. Transport 64544 was reaped. Container observation moved to the existing `cargo24-mini` context on the MacBook. |
| `02-red` | Pure code compiled. 147/162 assertions passed and 15 failed. Failures include `40ms starts rendering`, `overflow trims to newest 60ms`, and `100ms freshness inclusive`. The time boundary then changed from subtraction to an absolute expiration comparison. RAM source and output were removed. Transport 65634 and children 19959 and 20039 were reaped. |
| `03-green` | Exit 0. Pure checks 172/172, including 100 wrap-bound assertions. Coverage includes format and finite-sample rejection, prefill and underrun, ceiling and newest trim, stereo order, queued and in-flight age, mailbox byte and packet limits, single work ownership across revoke, stale render and decode, and two-owner lease behavior. The actual pure revocation state and nonblocking lock compile and run against the installed macOS SDK. |
| `static.json` | 12/12 source constraints pass. These inspect ownership and forbidden operations. They do not compile or execute the native adapter. |

The green payload SHA-256 is `b7f52f6e36c839a5754aca5148d30af3197478fc3bed50b09f72168a2ee6b75a`. Sender, receiver, final RAM hashes, and source-before-after match. Both production files are included in the stream manifest, but only `VisionAudioBuffer.swift` and the pure fixture are compiled. Final component hashes are buffer `ff661390cdefcb660b8b55d882079d2bbb0ab02807af11cc17d336e997108781` and player `2d960236964b9c2376012aefb7db65ffe84b90f16c1cc80067d16e5c2e160e4e`.

Green observations show unchanged swap at 9830.19MB, memory free percentage 59% before and after, unchanged Orca process identities, no matching AVD process, and the same thirteen running container identities and statuses. These are bounded observations, not a service latency or performance claim. The transport PID 76323 was reaped and terminal session 5586 returned exit 0. Compiler and test children 20642 and 20723 were reaped. RAM detached with exit 0, isolated outputs were removed, and the heavy slot was returned to the parent. No live handles remain from this component validation. All three permitted attempts are consumed. No additional Mini run is authorized by this unit.

## Parent integration gates

The clean implementation commit is the delivery unit after the test scaffold and failure-receipt commits. This branch adds no project membership, common wire, iPad, or core changes. The parent adds the two Swift files to its native target and provides `AudioPacket`. Parent reports controller and route adapter tests separately.

Native player compilation, AAC conversion against real packets, audio session errors, source-node consumption, audible playback, interruptions, and multi-window OS behavior have not run here. Parent holds the final native build lease and independent review. Passing pure checks is not native playback acceptance. No install, launch, audio I/O, keychain, browser, cloud, service mutation, permanent remote checkout, push, PR, or peer messaging occurred. The report stays in this allowed local document for parent-owned source integration and any parent Space update.
