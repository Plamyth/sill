# Delayed input across source switches

Confirmed on 2026-10-16 KST against base `cb9c743391a5b75525af94cd21de864fae5bad5c`, branch `codex/ipad-canvas-bridge-v0.5.1`. This chat owns sidecar branch `codex/sidecar-delayed-input-source` in `/Users/ambrion/Documents/ChatGPT/BT_CCR-Sill-delayed-input`. The original checkout was clean at that commit. The reproduction precedes the fix in commit `a9a3a53`.

The actual release handler decodes a normalized InputEvent and calls `currentSourceRect()` when the packet arrives. The selection is global across clients. A packet created over A can therefore target B after another connection selects B. Host-held input cleanup does not cover packets still queued by a client or its connection.

## Reproduction and fix

A has bounds `(100,200,400,200)` and B `(1000,800,800,600)`. A click at fractions `(0.25,0.75)` belongs at `(200,350)` on A. The harness retains that packet, commits B, then delivers it on the first client's connection. The base handler records:

```text
TRACE A→B delayed click: points=[(1200.0, 1250.0)], raises=1
FAIL: delayed A click must not hit B (1200,1250) or activate B; got [(1200.0, 1250.0)], raises=1
1/2 checks passed; 1 failed
```

The candidate gives each active source selection an opaque generation. The catalog advertises it; the client captures it before entering the network queue and retains it with coalesced moves. The host rejects stale, unscoped or switching-time input before focus changes or injection. An owed key/button up still uses the existing null-rectangle release path. Generation changes on source identity changes, including A→B→A. Same-source live geometry continues to follow `currentSourceRect()`.

```text
TRACE A→B delayed click: points=[], raises=0
54/54 checks passed; 0 failed
```

Source ID alone cannot reject an old A packet after A→B→A. A receipt-time snapshot also comes too late. An arbitrary delay timeout cannot prove which source an event belongs to. The token records that missing information without relying on client clocks.

## Files

| File | Change |
| --- | --- |
| `Sources/StreamProtocol/Input.swift` | SourceInput payload and old-host fallback encoder |
| `Sources/StreamProtocol/Switcher.swift` | Optional catalog inputGeneration |
| `Sources/SillHost/StreamCoordinator.swift` | Generation rotation, catalog publication, guard before focus/injection |
| `Sources/SillHost/PointerControl.swift` | Classify pointer motion in both input formats |
| `iOSClient/StreamClient.swift` | Catalog/reset binding, event-time snapshot, retain serialized payload through coalescing |
| `Tests/checks/delayed-source-input/run.py` | Isolated Swift harness, baseline selection and in-memory mutations |
| `Tests/checks/delayed-source-input/evidence.json` | Captured baseline, candidate and mutation output with source/input hashes |
| `Tests/checks/delayed-source-input/README.md` | Findings, commands and limits |

## Verification

Run from this worktree:

```sh
python3 Tests/checks/delayed-source-input/run.py --ref cb9c743391a5b75525af94cd21de864fae5bad5c
python3 Tests/checks/delayed-source-input/run.py
python3 Tests/checks/delayed-source-input/run.py --mutant unguarded-generation
python3 Tests/checks/delayed-source-input/run.py --mutant no-generation-rotation
python3 Tests/checks/delayed-source-input/run.py --mutant late-client-stamp
python3 Tests/checks/delayed-source-input/run.py --mutant ignore-switching
```

The baseline and mutations must exit 1 with the predicted behavioral assertion failures. The candidate must exit 0. `--emit-swift` shows the exact program without executing it. `--ref` reads Git objects without moving HEAD or editing the worktree.

| In-memory mutation | Result | Decisive failure |
| --- | --- | --- |
| Remove generation guard | 25 of 54 fail | Delayed click reaches `(1200,1250)`, raises=1 |
| Remove generation rotation | 23 of 54 fail | A→B→A accepts old A generation |
| Stamp on network queue | 2 of 54 fail | Generation was not captured before queue delay |
| Remove switching guard | 2 of 54 fail | Matching-generation click acts during switching |

The 54 checks cover unchanged/fresh source mapping, stale pointer/scroll/scroll-phase/text/key rejection, A→B→A, switching, source loss, owed releases, desktop mapping, same-source live geometry, actual catalog encoding, old catalogs, old-host payload fallback, immediate/coalesced/queued moves, move-before-text ordering and pointer ownership classification. Malformed payloads are dropped.

The harness compiles the real Input.swift types, the catalog types/Wire codec, and extracted Swift bodies for the host input case, currentSourceRect, point mapping, generation rotation, catalog encoding, client send/coalescing and pointer classification. Window lookup, focus, injection, queue timing and held-release eligibility are inert stubs. Source transitions and scheduling are explicit, with no sleeps, network jitter, real windows or posted input.

It runs one small `swift -` process on Mac mini over the existing `mini run` SSH path. Both hosts are checked for active compiler jobs before each run. One attempt deferred because a MacBook swift-frontend job was active. No full host/iPad build was started. Source hashes before/after match; each received stdin hash matches the sent hash. No remote checkout or source file is created by the harness. The remote process releases its input and exits. This is an independent streamed experiment, not codex-source-guard same-task transfer acceptance or Control Room acceptance.

Pstack applied: bug-fix reproduction → root-cause trace → minimal source-generation design → same reproduction after the fix → deliberate regression mutations; Prove It Works requires actual Swift output, and Laziness Protocol keeps the patch within input routing. Subagent tools are unavailable, so design comparison and diff review were sequential. No independent reviewer verdict is claimed.

## Compatibility and remaining limits

**Updated host and updated client must be released together for input.** The candidate host drops ordinary legacy/unscoped input, including current Python tooling that sends raw InputEvent. Allowing that fallback on the new host would preserve the reproduced defect. Legacy owed ups remain accepted. A new client connected to an old host sends the original payload; that old host remains vulnerable. The candidate does not raise release version floors or add an update notice, so compatibility/release policy remains an integration decision before installation.

This is selection-generation safety, not proof that the displayed video frame and catalog are synchronized. Same-source geometry/viewport changes, gestures, window commands, menu actions, physical input delivery, real transport ordering, UIKit integration, runtime latency and full host/iPad builds are outside this test. Real held-input/key/button ownership is stubbed, not independently revalidated. No installed-host, physical-device, production or human acceptance claim is made.

The separate `codex/host-release-on-loss` work is not included. Integration with its overlapping coordinator changes still needs owner review. The plain Git worktree could not be attached to the Codex UI because the attachment tool requires a managed worktree; it remains available at the path above. No remote branch was published, PR opened, merge performed or other chat messaged. Audio files and audio hunks were unchanged; no running app or device was controlled.
