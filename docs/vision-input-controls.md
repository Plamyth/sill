# Native remote input controls

Work key vision-input-controls-20261016. Original owner01a13005-ff61-7780-b0e8-6dc171de1c9d. Base05251937779bb91568248ce3c4df0ddd1fdec0d6, exact remote codex/vision-sill-audio-20261016 was checked before creating this local branch. The iPad owner retains common wire/host and input-sidecar148090e ownership. No new wire or host patch belongs to this unit.

## Checklist

- [x] Ground. Native pointer, KeyChord/KeyModifiers, hardware-key release and Unicode paths, client connection setter/handover/source lifetime.
- [x] Sketch. Compare view-owned latch/closure A with weak client-bound observable input session B.
- [x] Agree. Proceed under the existing autonomous native-control instruction, without a human checkpoint.
- [x] Implement. Supplemental keys and one-shot modifiers, modified pointer interactions, old-connection release and cancelled-drag suppression.
- [x] Scrap. Rework ownership if release requires a view-retaining callback or duplicated held-key state.
- [x] Verify. Exact pure events and host key-state effects with stand-ins, native build, independent review, original Page.

Throughput checkpoint. Parent owns this exclusive MacBook worktree and expected files VisionPointer, native input session/key catalog/palette, SillVisionApp, HIDKey, native project generator and guarded StreamClient hooks. Pure checks use one Mini heavy RAM stream with immutable input hashes and isolated output cleanup. MacBook XROS compilation follows compiler lease exchange. No device/app launch, PC input injection, service restart, audio or display route change, new remote checkout, heartbeat or repeated authentication. One initial attempt and at most two diagnostic corrections per path.

## Ground

Current native UI exposes Command and Escape, but not Control/Option/Shift or navigation/function keys. VisionPointer emits unmodified pointer events. Existing Sill KeyChord already presses modifier keys around a chord; InputInjector/KeyStrokes tracks ownership and releases a disconnected client's keys. Reuse that contract. InputOverlay keeps Unicode/IME commits as text and treats Command/Control/Option combinations as keys. Shift-only text must not be reinterpreted as a host-layout physical key.

Connection handover can keep connected=true. Holding a pointer/modifier stroke across it therefore needs an explicit before-replacement release, not only the view's connected onChange. The ordinary connection setter and finishMove are the connection replacement points; the latter calls SessionLink directly. Releases must precede those mutations. A cancelled drag must stay suppressed until its gesture ends. These are source requirements; physical Vision gestures and actual handover remain unaccepted.

## Usage and sketch

The view presents a compact native key palette, one-shot modifiers and editing shortcuts. The existing system keyboard remains the text/IME path. An input release button remains outside the subtree disabled by a pending input fence. A standard SwiftUI gesture passes normalized coordinates to the input owner; it never accesses raw gaze.

Candidate A leaves pointer and modifiers in the view and registers a release closure with StreamClient. It is small at the call site but captures view/StateObject lifetime and splits network-triggered release across owners. Candidate B puts pointer, latch and keyboard proxy in one observable session, which holds its client weakly; the client holds that session weakly and asks it to release synchronously before a connection changes. It concentrates held-input ownership and prevents a retaining binding cycle. Linnaeus independently grounded B and identified the required asynchronous transport contract. B was selected under the existing autonomous instruction. This was one model family and parent candidate A, not a diverse-model panel.

## Evidence references

[Apple buttons guidance](https://developer.apple.com/design/human-interface-guidelines/buttons) describes60-point visionOS target regions. The palette will use native buttons with at least60-point regions and accessible modifier names/state. This is a layout constraint, not a physical gaze-selection result. [Apple Mac shortcuts](https://support.apple.com/en-ie/102650) supplies conventional editing combinations; the active original app decides their effect. No shortcut is executed during development.

## Accepted transport refinement

Main-thread reset alone is insufficient because StreamClient previously resolved its route after queueing input. Native send captures its originating connection, and SessionLink checks identity under its send lock. Native input bypasses the iPad move coalescer so no unscoped pending move can survive. The existing iPad coalescer and admission behavior remain behind the non-Vision compile branch. Spatial gesture callbacks provide the move rate; no latency or throughput improvement is claimed.

A normal connection replacement releases and replaces under one SessionLink lock. A viable handover pauses new native admission, drains queued input and releases on the old route, then returns asynchronously to main to recheck the old connection and move ticket before handOver. There is no main/network synchronous wait cycle. Cancellation discards waiting input messages while preserving non-input messages. Abrupt loss still requires the peer-owned c02 host mouse cleanup and physical validation. Cancellation does not prove delivery to a dead connection.

Pointer stroke states include cancelled-until-end. Pointer modifiers are snapshotted at accepted stroke start and released after mouse-up/scroll-end. Exclusive tap-or-drag recognition prevents a cancelled drag becoming a trailing click. Supplementary keyboard actions release pointer/hardware ownership before the new balanced chord. Original Unicode/IME text handling is unchanged. The key palette has 26 unique HID usages and explicit conventional shortcuts. The original application determines their effect.

Finite acceptance for this unit is exact fake-transport/session/host-key-state behavioral checks, a signed XROS build bound to immutable product input hashes, and independent narrow source review. Device gestures, raw gaze precision, original app IME, off-LAN work and original calls remain separate acceptance gates. No install or device wake is part of this unit.

## Review correction

Dalton found P1 queued terminal-release deletion and P2 fence bypass plus successive palette key loss. The rejected premise was that local held state reconstructs everything already transmitted. VisionInputDebt now records only actual submissions under SessionLink's lock, including delayed flushes. Cancellation derives owed releases from that ledger, not from the view. Unsent downs create no debt and therefore cannot trigger an early release across an old fence. Ordinary palette preparation preserves completed queued text/chords and sends its live-stroke release in order. Only explicit cancellation/context/path replacement discards pending input. Callback captures are weak to avoid a client-link-buffer retain cycle.

Mini01 failed to compile because the fake SwiftUI module omitted its Foundation export. Mini02 crashed because raw transport marker bytes were reused as decoded JSON; its old max(exitCodes) runner also masked a negative crash exit behind zero compiler exits. Both receipts are retained and neither is a passing test result. The fixture now separates peer identities and treats every nonzero exit as a failure. Mini03 ran46/46 actual session/pointer/debt and extracted native-client checks with identical sender/receiver hashes, unchanged sources, stable swap and cleanup. This is independent RAM validation, not source-guard same-task transfer acceptance. Additional mutation and existing generic-fence regressions are pending.

## Unit result

Final Mini05 passed46 native/session/extracted-client checks,38 existing pointer/fence/transition checks and all17 existing generic SessionLink loopback modes. Two separately compiled runtime mutants failed at the required witnesses when debt recording or scoped-route validation was removed. The generic nofence mode also observed the expected inversions. Marker-only checks did not stand in for those runtime failures. Every final command and posthash guard passed. RAM input and isolated output were removed; child/transport processes were reaped. Swap decreased9830.19→9822.19MB, reported free percentage remained53%, and the seven observed Orca process IDs were unchanged. These are bounded health observations, not a full service latency or resource benchmark.

Mini04 had the same payload hash as05 and all runtime results passed, but a harness variable shadowed the posthash dictionary and made the overall envelope fail. Its original receipt remains rejected. Mini05 fixed that bookkeeping and repeated the exact inputs through cleanup. The reconnect-glue runner's inherited negative-exit masking was also corrected alongside its newly required KeyChords fixture dependency.

XROS Release build02 compiled37 product Swift files with product/metadata input173 hashes unchanged and passed codesign deep/strict, bundle dev.ambrion.SillVision, team ZPTXHJ866D, SDK27/min2.5. Executable SHA-256 effec75b42048fd4c29077baddf57de5518ef6b00d71e6ad816fcd9e878fac9b. Jobs1 was requested; the log contains both num-threads1 and num-threads12 and does not prove one effective frontend thread. Compiler/terminal were reaped and the lease returned to the iPad owner. Build01 was pre-correction and is preserved as a rejected historical artifact.

Dalton's independent narrow closure verified all9 source hashes in manifest fc0315143d645767318a7d75369cd1ae53c3d79bd2ef70b88a97b5bcd43c5a74, closed all3 findings and found no new P1/P2 on these paths. It was static review, not a reviewer test rerun. New-comment review found no actionable false constraint. Parent deslop removed unused HIDKey imports without changing its table. No wire/host/input148/c02 integration, install, device launch, original Mac input, audio I/O or display change occurred. The broader Goal remains active and physical/off-LAN/IME/microphone/original-call gates remain open.
