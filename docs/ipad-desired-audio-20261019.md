# iPad desired audio reconnect sidecar

This source candidate remembers microphone and playback intent separately for each authenticated saved Mac ID and certificate fingerprint. Connection and source grants remain temporary. Explicit stop or chooser cancellation clears the relevant saved intent. Background, interruption, source changes, and connection loss close actual media while preserving the saved selection.

The direct user request authorizes this independent writer on `codex/ipad-audio-privacy-resume-20261019`, based on clean `0dd10d1f9463001531416f37d756214b0ff32456`. The user cites original human message `01a15019-92b8-7621-90ac-52f5b3182937`. This sidecar does not read or message another chat. Host privacy and Vision client code remain with their original owner. Parent native ink `62a5ba21a116fb049d1554ee299e45cc76476a88`, original scene data, tokens, and SDK execution remain outside this diff.

## Why the host owns silence

The host design was read from `/Volumes/BT-Workspace/Development-Archives/CCR-Vision/remote-audio-privacy-20261019/design.md`. The selected design combines a persistent host privacy latch with client desired intent. A client-only preference cannot keep a disconnected Mac muted. The host verifies built-in mute and BlackHole defaults. The iPad neither uses host HAL nor restores physical devices, and it makes no claim about arbitrary DN32-LIVE or HDMI muting.

`AudioPrivacyState` is public, Codable, Equatable, and Sendable. It contains `version: Int`, `protected: Bool`, and `reason: String?`, with defaults of version 1 and nil reason. `WindowList.audioPrivacy` is optional and its initializer defaults to nil. The type lives beside `WindowList` so existing fixtures that compile `Switcher.swift` directly keep its required definitions. Integration with the host owner's identical type must retain one definition.

## Automatic admission

`IPadDesiredAudio` is a pure state machine. It owns saved selection, privacy interpretation, direction revisions, and the attempt set. `IPadDesiredAudioStore` uses a separate versioned defaults record containing only Mac identity and desired booleans. Grants, connection objects, scopes, attempts, and permissions are never persisted.

All audio starts require the newest catalog on the current connection to contain version 1 and `protected == true`. Automatic admission additionally requires the existing authenticated Mac identity and saved pin, an active foreground app and key scene, a current source and input generation, actual display readiness, and current input authority. Microphone admission additionally requires the existing OS authorization and microphone availability. The adapter passes `allowPermissionPrompt: false` on the automatic path. False, unsupported version, and missing privacy block manual and automatic starts and revoke actual media. Legacy catalogs still decode, but cannot establish Mac physical privacy.

One automatic attempt is admitted per connection, identity, scope, and direction. A repeated catalog, failed attempt, privacy toggle, or foreground transition cannot renew that budget. A new connection or scope needs a fresh grant. Manual re-enable remains available. Reapplying ON is idempotent while a grant is pending. Explicit OFF rotates that direction's revision before closing frames and capture. A late grant, permission completion, or capture completion cannot reopen it.

A local source request retires the old scope immediately. Repeated catalogs describing that retired binding cannot restart audio before the host publishes the replacement binding. OS permission sheets may suspend an explicit manual permission request. That request resumes only after the app becomes active and its direction revision, request ID, peer, and scope still match.

The actual presented gate is `StreamClient+DesiredAudio.swift`, in `readDesiredAudioPresentation`. It reads the existing `HEVCDisplayView` backing `AVSampleBufferDisplayLayer`, key-window attachment, readiness, failure, and flush state. `IPadAudioPresentation` requires a not-ready/ready cycle and a current keyframe. The control gate uses the real sibling `InputOverlayView` returned by the window hit test, its video size, `inputPaused`, `moveUnderWay`, current source, and the same `inputGeneration` used by `StreamClient.sendInput`. A different overlay elsewhere in the window cannot establish this binding. `StreamScreen.contentArea` wires that overlay to `client.sendInput`. This base has no separate iPad `fullLease` or modern presentation-ticket API. The adapter checks this existing UI input binding rather than supplying a constant permission flag. Parent runtime verification must confirm that SwiftUI hosts these two existing views as siblings. If it inserts different parents, automatic admission stays closed.

The iPad base receives untagged legacy video. If a layer stays ready across a source or transport change, its old image cannot establish a new source. The adapter therefore waits for a fresh readiness cycle and keyframe. Manual controls remain usable when automatic presentation cannot be established. Parent runtime acceptance must check reconnect, source switching, keyboard and chooser overlays, and view reattachment on the integrated source.

## Ownership and pstack procedure

The `how` pass traced the current connection setter and handover, `microphoneObserve`, `receiveMacInfo`, window catalogs, existing source input, display layer, chooser, and audio lifecycle. `architect` compared host latch plus client intent with client-only preference. The direct no-nested-agent instruction limits this comparison to one sequential perspective. `Model the Domain` selected the state machine and identity-keyed store. `Prove It Works` limits the result to the artifact and checks actually inspected. `deslop` removed unused action mutation and kept the existing microphone policy unchanged.

The throughput checkpoint has these boundaries.

- Blocking first steps were owner, clean base, host design, and exact callback contracts.
- Independent workstreams remain with the host, Vision, and parent SDK owners.
- Shared mutable state is confined to this exclusive branch and main-thread adapter. Async media uses request, grant, scope, connection, and revision fences.
- The smallest safe decomposition is one pure intent model and one iOS adapter. There is no nested writer or cross-owner integration.

The pstack independent review gate is open work. Nested agents and other-chat actions are prohibited here, so this author's diff inspection is not an independent verdict. No merge, deployment, install, device run, or runtime acceptance is claimed.

## Verification and handoff

Run `python3 Tests/checks/ipad-desired-audio/static.py` for the source constraints. `plutil -lint iOSClient/Sill.xcodeproj/project.pbxproj`, `sh -n Tests/checks/ipad-desired-audio/run.sh`, and `git diff --check` validate project syntax, fixture shell syntax, and whitespace. These checks do not compile Swift.

All 24 source constraints, project plist lint, shell syntax, and whitespace checks passed on this sidecar. The final archive retains the exact file hashes, check time, and commit. These results establish source wiring only.

`Tests/checks/ipad-desired-audio/main.swift` contains the unexecuted pure fixture for persistence and pin isolation, independent directions, privacy downgrade, stale peer, foreground and presentation gates, attempt budgets, explicit-stop revisions, legacy decoding, fresh grants, and late microphone/playback callbacks. `run.sh` accepts an already approved volatile output directory. It does not allocate a RAM disk or choose a remote source location.

No Swift compiler, SDK, UI, physical device, emulator, Mini command, live audio, host default, HAL, app restart, install, Pages, or other chat was used. Runtime work returns to the parent after ownership handoff. The parent must use the Mini wrapper, safety and RAM-owner preflight, and a verified read-only or volatile source path. Streaming hashes alone do not pass the existing Git source-guard transfer gate. A future fixture run must be labeled as an independent check until the parent accepts the exact source and result.

The archive checklist and final source hashes are stored through `storage-route development-archive` for project `BT_CCR-Sill-Obsidian` at `/Volumes/BT-Workspace/Development-Archives/BT_CCR-Sill-Obsidian/ipad-audio-privacy-resume-20261019.md`. No Space report was written because the direct task excludes Pages.

## Parent review correction

Beauvoir returned NOT CLEAR for52c2dd6. The UIKit sibling geometry does not establish the actual input authority. The presentation model also waits for a not-ready transition that an identical-format handover need not produce. The original 24 static checks inspect wiring; their names did not prove either behavior. The two misleading static check labels now describe the heuristic they actually inspect. These findings remain open.

The parent compiled the pure model fixture on Mini RAM and all49 checks passed. A new legacy manual-start refusal assertion then reproduced the obsolete exception before its correction. Both manual and automatic starts now require protected version1 capability, and the chooser disables unsupported routes with a Korean explanation. This small correction does not resolve the two adapter findings. No SDK or installation of this candidate is accepted.
