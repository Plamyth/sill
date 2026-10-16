# Delayed input across source switches

## Current staged rollout

The correction after `19b672bc7485c4b79f2c6f0b356307fe53896796` keeps legacy Sill input functional by pinning the host's source while any legacy or unnegotiated connection remains. The host accepts that connection's original InputEvent payload only for the pinned source. A different source selection is refused before capture or focus changes, and the current catalog is re-sent. Stopping a stream preserves the pin. Same-source restarts remain available.

The host can therefore be updated before the clients. Updated clients advertise `Hello.sourceInput: 1`, keep the generation capture implemented in 19b672b, and use the scoped input format. A matching scoped packet also promotes a connection from that first candidate, which did not advertise a capability. Once every remaining peer supports scoped input, global source switching resumes with the generation check. Missing or unknown capability values stay in legacy mode. A promoted connection cannot downgrade to raw input.

An idle host accepts a legacy client's first source selection and pins that source when it commits. A connection joining during an asynchronous source transition is cancelled before receiving an old catalog; it can retry after the transition settles. Broadcasts, including catalogs and frames, are withheld until the coordinator's first direct catalog marks the connection admitted. This also covers a network registration whose coordinator callback runs only after the source transition. Disconnected and unadmitted peers cannot inject even an owed release after a new source is selected.

An unrestricted legacy fallback cannot solve this: the same raw packet bytes could describe a delayed A click or a fresh B click. A timeout or source chosen at receipt would guess. The staged policy prevents that ambiguous cross-source transition instead of discarding all ordinary legacy input.

### Current evidence

The updated deterministic check executes the pure SourceInputFence and extracts the real coordinator admission prefix, selection guard, input handler, generation lifecycle and hello/leave calls, alongside the existing actual Swift codec, geometry and client-queue paths. It also extracts the server's broadcast recipient predicate and direct-catalog admission marker. Dependencies remain inert. Against 19b672b, the compatibility regression fails at runtime: `FAIL: legacy ordinary click remains functional on A`, with **57/63 passed, 6 failed**. The corrected source passes **87/87**.

```text
TRACE A→B delayed click: points=[], raises=0
TRACE legacy delayed A→B attempt: active=window(1), points=[(200.0, 350.0)]
87/87 checks passed; 0 failed
```

The ordinary legacy click remains on A when another client requests B. The scoped-client case still allows A→B and rejects the delayed A packet. Coverage includes legacy click/text/key/scroll/scroll-phase input, multiple legacy peers, source loss, capability upgrade and downgrade attempts, initial idle selection, rejected mid-switch admission, reconnecting on settled B, queued packets from peers that left, and withholding old A broadcasts before admitting a legacy peer onto settled B. `rollout-evidence.json` preserves the captured outputs and source/stdin hashes. The final successful PTY record contains its output tail and the separately observed matching stdin hash. The original `evidence.json` remains the historical 54-check result for 19b672b.

```sh
python3 Tests/checks/delayed-source-input/run.py --ref 19b672bc7485c4b79f2c6f0b356307fe53896796
python3 Tests/checks/delayed-source-input/run.py
python3 Tests/checks/delayed-source-input/run.py --mutant no-legacy-pin
python3 Tests/checks/delayed-source-input/run.py --mutant no-membership
python3 Tests/checks/delayed-source-input/run.py --mutant pre-catalog-broadcast
```

The prior candidate and deliberate mutants must exit 1 with behavioral assertion failures; the corrected candidate must exit 0. The other four mutation commands below still apply to current source. Compiler admission checks remain in place on both hosts. No full app build or installation is part of this experiment.

All seven mutation variants were caught. The six generation/lifecycle/pin mutations ran on the 83-check precursor before the broadcast gate was added; the admission-gate mutation ran on the final 87-check source and failed exactly the two broadcast-ordering assertions (85/87 passed). Each record retains its own source hashes. The final successful 87-check record matches all committed input-source files.

Changes since 19b672b: `Sources/SillHost/SourceInputFence.swift`, coordinator connection lifecycle/input/selection paths, broadcast admission in `Sources/SillHost/StreamServer.swift`, the optional Hello capability in `Sources/StreamProtocol/Compatibility.swift`, its client announcement in `iOSClient/StreamClient.swift`, the catalog comment in `Sources/StreamProtocol/Switcher.swift`, and this harness/report/evidence. Audio files, audio hunks and installed apps are unchanged. Work remains in `codex/sidecar-delayed-input-source`; it is not merged or published.

### Current limits

- While a legacy peer remains, all clients and host controls share the same source pin. Switching to another source requires all legacy peers to disconnect or upgrade. If the pinned source closes, an alternate source stays blocked until that condition is met. This intentionally stages source switching while preserving legacy interaction.
- Connections attempted during a source transition retry after it settles. This can cause brief reconnect churn; real reconnect timing is untested.
- An old host still has the original defect, including when a new client uses its old-host fallback. Deployment must start with this host candidate to obtain the staged protection. No version floor is raised.
- This fences StreamSource identity and kind 8 input. It does not synchronize displayed video frames with the catalog, freeze same-source geometry, or fence gesture/menu/window commands. Full app builds, real transport, physical input, actual held-key/button ownership and independent review remain unverified.
- Swift inputs were streamed to one short-lived Mac mini process with source/stdin hashes checked. This remains an independent isolated check, not codex-source-guard transfer acceptance. Installed apps, devices and other chats were not operated.

Pstack Fix Root Causes drove the source-pinning invariant; Prove It Works drove the previous-candidate failure and the executable regressions. The record below describes the initial candidate and its former compatibility restriction, retained as history.

## Initial candidate 19b672b

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
