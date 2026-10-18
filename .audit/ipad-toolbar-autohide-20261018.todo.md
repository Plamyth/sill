# iPad toolbar and audio acknowledgment

Task key ipad-toolbar-autohide-20261018. Parent owns device, builds, installs, independent review and Result acceptance. Exclusive branch codex/ipad-toolbar-autohide-20261018 at base 62fa3f44958395547b414611c1a9fd7bd1aff714. No host, protocol, trust, native resolution or media grant edits.

- [x] Read AGENTS, diagnosis, poteto-mode 0.9.93, how and model-the-domain.
- [x] Trace layout, first responder, viewport, route offer, verified identity and teardown.
- [x] Sequential design comparison. Parent's two design spawns failed at global capacity. No model diversity or independent design verdict is claimed.
- [x] Blocking first steps. Verify exclusive clean branch and exact base before edits. Native UI and full build reserved to parent.
- [x] Independent workstreams. Toolbar and audio policies can be tested independently; shared StreamScreen/chooser integration has one writer.
- [x] Shared mutable state. This worker owns the exclusive worktree. Canonical and parent checkout are untouched.
- [x] Smallest safe decomposition. One delegated implementation owner handles coupled UI state and pure models. Nested spawn prohibited.
- [x] Implement typed toolbar state and identity-scoped acknowledgment.
- [x] Run focused policy/adapter checks, syntax and self diff review.
- [x] Prepare the owned, self-reviewed changes for commit and handoff. The final reply supplies the exact commit. Parent acceptance remains pending.
- [ ] BLOCKED: independent review. Parent must obtain reviewer after combined build. Self-review and policy tests do not satisfy it.

## Sequential comparison, no diversity

| Candidate | Tradeoff | Decision |
| --- | --- | --- |
| Remove/recreate the entire layout when hidden; persist a global chooser Boolean | Risks changing the input node and transfers acknowledgment between Macs | Rejected |
| Collapse only the mounted toolbar row; use a small visibility state and a versioned acknowledgment keyed to verified Mac ID plus pin | Preserves stream child position and separates UI acknowledgment from media grants | Selected |

The idle interval is 4 seconds. Passive touch observation must not recognize, delay, cancel or prevent remote gestures. No layout change while any touch is held. Open drawer, settings, window lights, Mac menu, display picker, scale, tour, pairing, canvas, audio chooser and VoiceOver pin the row. A 44 pt Korean button over the picture provides reveal and manual hide without a reserved row. Portrait reclaims only windowBar plus its following gap, leaving the keys and trackpad allocation intact. iPhone retains its existing layout and display menu.

Only acknowledgment is persisted. Unsupported or unverified hosts have no automatic offer. Close, apply and interactive dismissal acknowledge the identity captured when opening, only while it still matches the current verified connection. Scene dismissal, teardown or identity change do not acknowledge. Manual opening stays available. Existing explicit consent, permission denial, stale context and audio failure handling remain authoritative. The unrelated parent CUA -3801 capture targeting MarginNote is not repaired by this patch.

## Parent acceptance checklist

- [ ] Full combined iPad SDK build and independent diff review.
- [ ] Landscape hide reclaims actual video height; stream and responder remain the same node.
- [ ] Reveal/hide touch never forwards a Mac click; ongoing finger/Pencil/trackpad drag is uninterrupted, including a second-finger reveal.
- [ ] Portrait only window bar plus gap reclaimed; keys/trackpad remain usable; keyboard responder/viewport fix retained.
- [ ] Every pin, scene transition, disappearance, rotation, VoiceOver and Reduce Motion.
- [ ] First verified supported host offers once; repeated activation/catalog callbacks deduplicate.
- [ ] Close/apply/swipe, reconnect and cold launch suppress only same Mac+pin. Changed pin/identity and malformed store offer afresh; unsupported host offers no forced off-only sheet.
- [ ] Manual routes, permission denial, source failure, stale response and explicit full duplex remain accurate. No opening/reconnect restores capture or playback.
- [ ] Preserve installed bundle/team/pairing and native resolution. Parent installs a single combined build and records its exact version and physical acceptance.
- [ ] Parent updates existing ChatGPT Space report with this local artifact and actual acceptance. Worker does not duplicate parent report ownership.

## Verification receipt

Verified on 2026-10-18 in this exclusive worktree. `pstack:how` traced layout and authorization ownership. `principle-model-the-domain` selected the explicit shown/pinned/hidden/deferred visibility state and the versioned identity acknowledgment. `deslop` self-review kept the diff inside these feature paths. The no-comments independent agent cannot run under the no-spawn assignment; parent review remains required.

- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 iOSClient/Tests/toolbar-visibility/run.py` passed 36/36 checks.
- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 iOSClient/Tests/audio-routes/run.py` passed 172/172 route checks, the existing microphone owner/cancellation suite, and the audio lease suite. Full output is in `ipad-audio-route-checks.log` next to this report.
- `swiftc -frontend -parse` passed for changed Swift UI files, StreamClient and its audio adapter. This is syntax validation, not an iOS SDK type/link check.
- `plutil -lint iOSClient/Sill.xcodeproj/project.pbxproj` and `git diff --check` passed.

The initial CLT-based test attempt exceeded 120/180 second limits without results. Its remaining compiler process was terminated; another had already exited. The successful tests used the Xcode developer directory per command, without changing system selection. No full build, app, device, host source, permissions, signing, pairing, protocol, network, push or PR operation ran.

Self-review caught the need to restart idle after a pinned panel closes. The typed pinned state now does that without a timer under an open panel. It also caught that disappearance alone cannot identify user acknowledgment. The sheet binding now handles user dismissal using the displayed identity/peer; scene code closes the sheet directly, without acknowledging it. Both distinctions have focused tests.

The passive toolbar observer reuses the existing nonrecognizing, nonpreventing TouchWatchRecognizer with a delegate that also observes remote touches. The tour keeps its existing filter. The iPad display picker uses an explicitly tracked popover so an open picker pins its anchor; the iPhone keeps its existing Menu. Parent must validate UIKit behavior, popover placement, inherited animations, physical drag continuity and installed persistence.

The acknowledgment identity uses the existing authenticatedMacAudioRoutePeer boundary, which checks saved Mac identity, verified info, TLS fingerprint and session trust. The focused adapter suite substitutes that trust boundary; it does not establish a physical TLS or OS permission receipt. A separate process does read the real UserDefaults record and suppress onboarding with zero media requests.
