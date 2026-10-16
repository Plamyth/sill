# Native Mac audio routing candidate

Work key `vision-audio-routing-20261017`. Sole writer branch `codex/vision-audio-routing-20261017` begins at `e11566df90bca876bd5a0d218647183f943d13e2`, the native 6730 source plus the exact host d5 wire dependency. Candidate project build is 9. Installed native build 8 and host installation remain outside this unit.

The controller holds one reviewed `MacAudioRouteSession` and a native scope of connection UUID, window UUID and window admission UUID. The chooser retains its displayed `CatalogToken` and endpoint snapshot. Picker changes edit that local draft; only Apply invokes `request(displayed:inputUID:outputUID:)`. The shared policy owns validation, CAS identity, fresh revision/full default readback, refusals and late-answer behavior. No second pure policy is retained.

`VisionMacAudioTransport` adds native scope binding and locking around the shared `MacAudioRouteTransport`. Its bind/reset cancels the shared requestID submissions before a new window/peer becomes current. It adds no submission queue or dictionary. The shared transport owns `SessionLink.onlyOn` and `Submission`. Main owns all controller methods and shared transport mutations; the network receiver reads the locked scope and rechecks the originating peer, authenticated scope and current TLS peer on main before delivery.

The actual `iOSClient/StreamClient.swift` contains the Vision-only stored fields, receive/reset/background hooks and same-file extension. The ordinary project generator references it directly. The iOS Debug and Release selected source is unchanged from the base. `VisionAppSession` refreshes authorization when verified Mac information or saved identity changes. Selection authority requires connected, saved verified Mac ID, matching saved and verified pin, matching current TLS peer pin, saved-home or remote session, current owner window and foreground. Video source/presentation epochs are independent.

The native controller sends one initial read-only 210 per trusted active context. It has an eight-second pending timeout and expires before processing any late data. Closing the chooser, leaving the foreground, releasing a window or changing peers cancels queued selection work. A request already submitted may still have an unknown host outcome. The UI never sends 209 on join, remembers a preferred route, starts microphone capture or issues a persistent grant. Current endpoints and their names/UIDs come from the physical Mac catalog. A missing 208 is displayed as `목록을 아직 받지 못했습니다.`. Virtual defaults absent from the physical list remain in the CAS token.

`Documents/CCRMacAudioStatus.json` is a separate redacted snapshot, written only when controller/context events change its value. It contains exactly build, trustedCurrentPeer, owningWindow, foreground, catalogAvailable, catalogValid, catalogCount, currentInputKnown, currentOutputKnown, pending, fixed outcome and selectionRequestCount. It contains no endpoint UID/name, pin, token, address, requestID or error text. The request counter increases only after explicit Apply creates a shared request; it never means the host applied it. The file uses the existing native status pattern with atomic replacement, mode 0600, complete file protection and backup exclusion. A locked device can prevent a write; a later state event can retry. There is no polling or recurring retry. Existing CCRAutoConnectStatus schema is unchanged.

The parent may use official device file retrieval to establish that installed native code received and validated a host 208 catalog. This status is not a screenshot, gaze, UI interaction, microphone or sound receipt. The writer performs no Documents IO in Foundation fixtures on macOS. Native fixtures inspect the redacted snapshot type and verify its allowlist and zero-before-Apply semantics; actual device protection and file retrieval remain parent checks.

`macAudioModalShown` inhibits the existing native input admission for both the first-offer prompt and chooser. The existing `allowed` setter invokes `releaseAll`. Opening the chooser clears the first-speaker confirmation; delayed speaker confirmation also rejects a route modal. Existing playback and microphone controls remain in place.

## Dependency evidence

`dependency.json` records the reviewed upstream commit `3c710f17f8568f13f9f046c6d5c838e944564c9d`, tree `54a02dcd424170de89f326a7d6ca8cab88ad2604`, original source SHA256 and candidate SHA256. Files came from exact Git objects, not dirty peer files.

* `MacAudioRouteSession.swift` is byte-identical, SHA256 `4d456c55afec33a7d82bce63c4559c0e18edf5a4169d5966257a2c05ec3532ad`.
* `MacAudioRouteTransport.swift` came from SHA256 `f0a72c2a2f1012d5575e0b6847e4e2efb924de95fcf5767195732268fa880073`. Its sole downstream change expands `#if os(iOS)` to `#if os(iOS) || os(visionOS)`; its body is unchanged.
* The shared policy `main.swift`, transport fixture `transport.swift`, original runner `shared/run.py` and inert `shared/Network.swift` are byte-identical upstream reference files. The copied runner retains its original paths and is an evidence reference. Use the native driver below, which runs those same 65/16 assertions without duplicating them.
* AudioRouting.swift matches both host d5 and the peer dependency. The peer StreamMessage.swift only reorders independent payload-limit switch cases. This candidate preserves its exact d5 version.

This is normal dependency adoption. It does not establish source-guard same-task transfer or import the peer's runtime results as this candidate's results.

## Parent validation recipe

Local source checks and fixture preparation require no Swift compiler:

```sh
python3 -B Scripts/make-vision-project.py
python3 -B Tests/checks/vision-audio-routing/static.py --output /private/tmp/vision-audio-routing-static.json
python3 -B Tests/checks/vision-audio-routing/run.py . /private/tmp/vision-audio-routing-emit --emit-only
git diff --check
```

Use a fresh output directory, or reconcile its prior result rather than overwriting evidence. The local static runner verifies non-Vision selected source equality, dependency hashes, source references and native boundary constraints. It does not type-check Swift or render SwiftUI.

After source/host checks and the parent's compiler lease, execute this driver on the parent's isolated Mini source input and output paths:

```sh
python3 -B Tests/checks/vision-audio-routing/run.py "$AUDIO_SOURCE_ROOT" "$AUDIO_TEST_OUTPUT"
```

No SSH, copying or network is performed by this driver. The parent must provide the verified input graph through its approved transient path. The driver requires Sources/StreamProtocol, both shared audio route files, SessionLink.swift, StreamClient.swift, VisionMacAudioController.swift, VisionMacAudioTransport.swift, VisionMacAudioStatus.swift, VisionCableBootstrap.swift, VisionInputSession.swift, SillVisionApp.swift, VisionAppSession.swift, the project/generator for static references, this test directory and Tests/checks/swift_platform.py. Preserve the source references checked by the generated project, or perform local static preparation and stream the complete selected input graph. No new permanent checkout is required. The driver skips only the local Git baseline recomparison in Git-free input and labels that explicitly; bind the parent's local static receipt separately.

The driver runs unchanged shared 65 policy checks and 16 exact-peer transport checks. Its native fixture exercises first fetch with zero selection, same-window new admission, held request cancellation, old drafts, foreground epoch changes, delayed main callbacks, eight-second timeout, new-peer fencing, actual authorization guard refusal, chooser-close cancellation and modal input release. It extracts the production adapter, fields, lease, modal predicates/actions and input setter. Only the factory clock argument is injected; method bodies are unchanged. Fake identity, TLS pin lookup and Network byte recording are declared stand-ins, not actual TLS cryptography, Apple UI or hardware proof. The native count is reported by actual execution, not presumed here.

Each compile/run is bounded and reaped. Original and emitted input hashes, exact extraction hashes, command statuses and source immutability are recorded in the external result.json. The driver permits 720 seconds total. Parent should execute it under the existing single heavy-work gate. The writer ran no Swift compiler/runtime, SDK build, device or network operation. Exact XROS SDK compilation, independent dependency/scope review and installed/physical acceptance remain parent gates.
