# iPad audio intent and actual grants

This candidate starts at `f854ad27f0b7e629bad3df453d0fdcaa22f895d3` on the exclusive `codex/ipad-audio-intent-grants-20261019` branch. It supports speaking or dictating while the iPad painting screen is foreground, including when the Mac video and pointer overlay are absent. Audio routing continues through the existing chooser and real audio policies.

## Decision and ownership

The direct user correction identifies full video input control and current video presentation as an assumption added by the parent, rather than the original user's requirement. Two designs were compared. A shared video input lease would suspend audio when painting hides that overlay. Existing authenticated audio intent plus the real microphone grant and playback ACK supports drawing while speaking. This candidate chooses the latter and removes the video dependency from audio admission. It adds no replacement `fullControl = true` value.

The previous video/input implementation is preserved as WIP commit `fd0d4c4b8dffc7e4e8a469045d752886a2911f57` in the original `ipad-audio-privacy-resume-20261019` worktree. Its external snapshot is `ipad-video-authority-wip-20261019.tar`, SHA256 `043c88b02d0e0de8ca6623f70271a4cefbbfa01334af425ddd7f40341beeac73`. All 24 archived files were restored into an isolated external temporary directory and verified against their hashes. Originals were unchanged. That WIP is not completion and is excluded from this release.

No HEVC renderer, input overlay, StreamScreen, SessionLink, host, Vision, painting, wire schema, or project file change is included here. The only StreamClient change removes the obsolete presentation state and removes its keyframe argument from an existing audio reconciliation callback.

## Authority and lifecycle

Both manual and automatic admission require the authenticated Mac identity and saved pin, a current peer with a fresh protected version-1 privacy catalog, saved explicit desired state, foreground application state, and the existing valid source/generation/videoEpoch audio scope. The epoch identifies the audio session scope. It does not require displayed video. Missing, legacy, false, or unsupported privacy blocks both paths as in f854.

The unchanged typed microphone policy requires the exact peer, scope, request, and fresh host grant before capture and frames open. Capture completions also check the direction revision. The unchanged playback controller requires its actual subscription request ACK before receiving audio, and ignores old request IDs. This change does not substitute a local preference for either host response.

A changed scope, identity, peer, or lifecycle closes actual IO and invalidates late work while preserving desired intent. Foreground return establishes a new lifecycle attempt budget, and changed OS microphone authorization establishes a new microphone permission cycle. Repeated callbacks in one lifecycle or permission cycle cannot retry a failed attempt. Source and peer changes retain their existing fresh-request boundaries. Explicit OFF persists false and invalidates delayed callbacks. Automatic starts retain `allowPermissionPrompt: false` and require existing OS microphone permission. Manual permission completion and microphone stop/grant replies reconcile through the same bounded admission path, so resumption does not require a video frame.

## Review history and evidence

The independent NOTCLEAR on `52c2dd6` is preserved. F1's geometry inference is removed because pointer ownership no longer defines audio authority. The actual audio request/grant/ACK policies define it. F2's readiness latch is deleted, so a same-format handover no longer waits for a renderer to report not-ready. These are source changes under the corrected contract, not a self-issued CLEAR. A new independent review is required.

`intent-source.py f854ad27f0b7e629bad3df453d0fdcaa22f895d3` reproduces the two new-contract source failures. The current probe passes. `static.py` checks 24 source constraints and retains honest source-only labels. The pure fixture adds foreground renewal, permission-cycle renewal, explicit OFF across lifecycle changes, and drawing without presentation arguments.

The parent can run these against its verified read-only or owner-approved volatile source input on Mini, with OUTPUT already allocated in an approved volatile location:

```sh
sh Tests/checks/ipad-desired-audio/run.sh OUTPUT
python3 -B Tests/checks/ipad-desired-audio/intent-adapters.py OUTPUT
```

The second check extracts the actual desired-audio extension and executes reconciliation with inert audio effects and no video or overlay objects. It checks both-direction requests while drawing, bounded failure behavior, foreground renewal, explicit OFF, and unknown privacy. It requires the protocol library produced by the first command. Neither Swift check was compiled or executed in this source-only session. SDK, UI, device, installed behavior, acoustic privacy, and parent Result acceptance remain separate gates.

Pstack poteto/how/architect and Model the Domain traced the actual policies and compared both designs against drawing while speaking. Ponytail full reuses the existing grant and ACK policies, removes the presentation workaround, and adds only lifecycle and authorization attempt cycles. The owned diff receives a deslop pass. Prove It Works limits claims to source checks actually executed. Independent review is pending. No SDK, Mini execution, UI, devices, HAL, install, restart, live effect, Pages, nested agents, or other chats were used.
