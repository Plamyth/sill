# Bounded native remote fixture

Owner 01a13005-ff61-7780-b0e8-6dc171de1c9d. Base 18063c5dcf41f0867f7b26fc339bc10824793af2. Exclusive branch codex/vision-remote-test-peer-20261021. Pstack Feature/how/architect, inherited model, Ponytail full. User excludes ARENA, candidate competition, new chats, SDK builds and runtime/device/host changes.

## Ground and sketch

The existing text fixture seeds MockCatalog and bypasses SessionLink. Production remoteWinner adopts a pinned ready NWConnection, sends hello, reads framed messages through MessageReader and becomes connected only on WindowList. Modern input remains blocked until HEVCDisplayView admits the matching video epoch through its native display layer. SignedMacInfo must match TLS and saved pin. Keep these production checks.

Context.Profile = text | remote. Missing profile decodes as text for the existing adapter. Invalid explicit profile/source/run context refuses before session creation. DeviceIdentity in the fixed test bundle never enters keychain paths, including invalid contexts. A valid remote profile generates one memory-only device identity.

VisionReleaseRemotePeer owns one serial queue, loopback-only TLS listener, accepted connections/readers, immutable ephemeral Mac identity, current epoch/catalog, small prerecorded 64x64 changing HEVC IDRs, received SourceInput and private provider receipts. start(client, lease) installs only an in-memory saved pin and dials the listener. StreamClient adopts only after TLS ALPN/pin verification. Normal scene lease, presentation and text submission controllers continue; text-only shortcuts match only .text. No discovery, pairing, autoconnect or real audio provider. The fixture never injects presentation success or trusted=true.

Receipts bind commit/tree/runID/process boot/window admission/epoch. TLS readiness, client verified identity, native presentation and peer-observed source-scoped input are separate facts. Provider writes/readbacks/removes a private run/window file. UI shows simulated-peer scope and unsupported physical gaze/audio/HAL/Sentry. The XCTest checks connection, native presentation, real text path, actual peer receipt and reset. Whole acceptance stays false.

## Throughput checkpoint

- Blocking first steps. Confirm clean exact base, switch requested branch, read client/wire/display flow before edits. Done.
- Independent workstreams. n/a. One coupled profile/session/peer unit with exclusive writable checkout.
- Shared mutable state. Peer state on its queue; UI/client state on main; per-window private provider storage; real host and integration untouched.
- Smallest safe decomposition. Reuse RemoteKey/RemoteIdentity/RemoteTLS, framing/MessageReader/SessionLink and native display. No new dependency, certificate implementation or alternate input controller.

## Phases and verification

- [x] Ground.
- [x] Sketch and agree within user override.
- [x] Implement.
- [x] Deslop and self review.
- [x] Narrow source checks and owned commit prepared.
- [ ] Parent independent review and exact native SDK/XCTest run. No spawn_agent tool available in this session; independent review remains a parent gate.

Fixture HEVC generation used existing ffmpeg/libx265 for two 64x64 YUV420 solid luma frames (40/180), all IDR, no dependencies added. Mini has no ffmpeg at its existing standard paths; this subsecond source-fixture preparation ran locally without SDK build, files, devices or audio.

## Implementation review

The peer is fixture-owned and uses the actual production dial and message paths. Test-only silent playback and an empty audio intent context avoid native audio operations and permission queries; scene/app lifecycle observers still run. No code seeds text, bypasses review, forces connected/presented state, or sets a trust boolean. Remote trust is a memory-only pin row with a loopback-only address. DeviceIdentity intercepts all four public key access paths in the fixed test bundle. Invalid contexts cannot create a session or runtime receipt.

The peer supports one modern desktop/display and records the received SourceInput, epoch and generation. Listener and connections stop on scene release, EOF, error or 120 second expiry. The private provider reset is verified; evidence remains. The timer and listener handlers use weak captures and cleanup clears listener callbacks. Audio, HAL, Sentry, other input classes and multiple-display transitions remain outside this unit.

The parent's 180 native text test reached the draft editor but typeText left its value empty. Both native scenarios now assert editor.value immediately after typing. This worker did not inspect or operate the simulator. No telemetry or programmatic filling was added.

## Checks actually run

- python3 -B Scripts/make-vision-project.py regenerated the project with 73 sources.
- python3 -B Tests/checks/vision-release-simulator/test_simulator.py passed 26 tests.
- python3 -B Tests/checks/vision-release-adapter/test_adapter.py passed 35 tests.
- Swift frontend parse with DEBUG and arm64-apple-xros2.5-simulator passed for changed Swift files. The compiler warned that its selected sysroot was macOS 27.0. This was syntax parsing only, not an xrOS typecheck or build.
- ffmpeg decoded the embedded two IDRs to two 64x64 YUV420 frames with luma values 40 and 180. No files, audio or device access occurred.
- vision-input-controls/test_extract.py ran 4 tests and errored in 2 at unsupported Swift fixture condition DEBUG && targetEnvironment(simulator). Both errors also reproduce using exact base 18063c5 StreamClient source in memory. No Python fixture or adapter was changed.
- git diff --check passed during review.

Exact xrOS compilation, Network.framework handshake, native layer decode/display, XCTest keyboard routing, source/run/boot/window receipt readback and independent review remain parent gates. The unchanged Python adapter selects the text test; the parent must explicitly select testRemotePeerFixture for the remote scenario. No official ref, runtime, installed app, physical device or host was changed.

Parent steering added testDraftKeyboardDelivery. It launches explicit text profile, opens the production draft, types through XCTest and asserts UITextView.value immediately. A mismatch attaches app.debugDescription. Both complete text and remote scenarios keep their immediate value assertion. No product telemetry, requested-text seeding or input/review bypass was added.

The parent reported official integration ad272f34cf1afb3b369faf31c87a0ec4f594b8d8 after its independent Python driver fixes and tests. This worker remains based on 18063c5 with no Python changes and no cherry-pick, push or official integration mutation. The parent retains simulator and lifecycle ownership.

The generated-project membership check passed. VisionReleaseRemotePeer.swift occurs once in the sources of each Vision app target. Final Swift frontend parse of the added keyboard diagnostic passed with the same sysroot warning. BLOCKED: independent review. Parent review and exact native execution are required before integration or acceptance.
