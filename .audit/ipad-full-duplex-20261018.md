# iPad full duplex — 2026-10-18

Owner: this writer chat; exclusive worktree ipad-full-duplex-20261018, base 7792a8268809d8abc39989c71369b772ae561f1c. No Mac/protocol changes, device use, or Xcode build.

## Architect checklist
- [x] Ground: chooser currently applies playback before the microphone permission prompt. Scene inactive revokes playback. Remote playback controller calls ACK listening while local engine failures are swallowed.
- [x] Sketch: compared below; agent fan-out unavailable in this session, so sequential comparison only, not independent review.
- [x] Agree: user authorized implementation without checkpoint.
- [ ] Implement and verify in Mini volatile input.
- [ ] Scrap: revisit only if chosen shape cannot preserve boundaries.

## Usage and shape
`await client.applyAudioRoutes(.init(input: .iPadMicrophone, output: .iPadPlayback), context: displayed)`.
Authorization is an identity plus displayed peer/source/microphone context. It owns only the pending permission await. Playback uses requesting -> starting -> listening, with a subscription ID and player epoch/version fencing local results.

## Candidates
1. Pending desired-route coordinator retains selection and progresses permission, microphone grant, capture, playback ACK and engine states. It centralizes sequencing but duplicates existing microphone/playback ownership and adds lifecycle transitions and foreground-resume decisions.
2. Preauthorize permission, validate the retained action and current context, then apply existing independent operations. The permission prompt cannot revoke newly requested playback because neither direction was requested yet. Cancellation/background/source/peer changes invalidate authorization; foreground return never executes it.

Choose 2. No capture/engine recovery or retained desired-on state. Local player reports engine success/failure only for the active subscription and epoch/version. All renderer and transport logic remain owned by their existing modules.

## Verification boundary
Use Mini RAM input, exact hashes before/after, fake audio engine/session and real production adapter/controller/player restart body. No engine/device/network opened. Parent owns SDK build, installed UI, audible playback, input and Codex dictation diagnosis. No consumer fix claimed.
