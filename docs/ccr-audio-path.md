# CCR Sill audio path

## Intended behavior

The iPad plays the Mac's sound while the Mac keeps its current output device and volume. The iPad user turns remote sound on or off. Audio must stop when the Sill session ends. A later microphone path must bind input to the intended Codex voice session or an explicit Mac input device.

## Current source

Commit `89f9550` adds kind 33 `AudioPacket` decoding and `RemoteAudioPlayer` to the iPad fork. That iPad target built with a valid signature, but this source has not been installed or heard on the iPad. The installed iPad build still has working video, touch, Pencil, and recipient selection. The current host candidate compiles and the 200 protocol checks pass; no host audio candidate is installed yet.

## Host capture choice

Two routes were considered. Adding audio to the video `WindowCapture` stream would share its capture filter, but every source switch would stop the audio stream. A window filter may also omit audio from other apps on the Mac. A separate ScreenCaptureKit audio stream keeps sound stable while video sources change. It can capture without changing the Mac output route or muting apps. Use that route for the first host implementation.

The host advertises `WindowList.remoteAudio = 1`. The device sends kind 200 `RemoteAudioSubscription {enabled, requestID}` only after a user action. The host echoes that ID in kind 201 `RemoteAudioState`; a revocation caused by source change or capture failure has no request ID and never grants sound. The iPad must ignore a late enable answer whose ID no longer matches its pending user action. On every new connection and source change, sound returns to off and requires a new opt-in. Backgrounding stops the iPad player and sends off where possible; reconnection never resumes sound automatically.

The host captures with a separate ScreenCaptureKit stream and leaves the Mac's output route and mute state unchanged. The server sends kind 33 only to currently subscribed connections, drops audio for a client with more than 512 KiB of pending network data, and increments a capture epoch on source change. A callback from an old stream is discarded if its epoch differs. Subscription changes and state answers use the same ordered network queue, so an old packet cannot be sent after the new enable answer. The iPad clears its jitter buffer on disconnect and format change. Captured samples and microphone data are never written to disk by this path.

Do not merge the whole upstream Sill PR #66 audio path. Its process tap uses `mutedWhenTapped`, which would mute the Mac output. The upstream packet shape and AAC-ELD decoder are reusable; the host capture and user control need separate implementation.

## Remaining proof

1. Check the host capture callback with consented local sound and inspect its permission behavior. Compilation and protocol checks do not prove audible sound.
2. Add an explicit iPad sound control and a capability-bound subscription. Prove that older Sill hosts and clients keep video and input working.
3. Install a separate host candidate only after source and input review. On the physical iPad, hear the Mac sound, check that the Mac still plays through its chosen output, then switch video sources and reconnect.
4. Measure sound delay and test a slow link. Verify that audio drops instead of piling up and that video remains responsive.
5. Design the microphone destination with an exact voice-session or input-device binding. Test microphone permission, route changes, echo cancellation, and reconnect before calling two-way sound complete.
