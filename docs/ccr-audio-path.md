# CCR Sill audio path

## Intended behavior

The iPad plays the Mac's sound while the Mac keeps its current output device and volume. The iPad user turns remote sound on or off. Audio must stop when the Sill session ends. A later microphone path must bind input to the intended Codex voice session or an explicit Mac input device.

## Current source

Commit `89f9550` adds kind 33 `AudioPacket` decoding and `RemoteAudioPlayer` to the iPad fork. The protocol check passed 195 cases and the iPad target built with a valid signature. No host sends kind 33, and this build has not been installed or heard on the iPad. The installed iPad build still has working video, touch, Pencil, and recipient selection.

## Host capture choice

Two routes were considered. Adding audio to the video `WindowCapture` stream would share its capture filter, but every source switch would stop the audio stream. A window filter may also omit audio from other apps on the Mac. A separate ScreenCaptureKit audio stream keeps sound stable while video sources change. It can capture without changing the Mac output route or muting apps. Use that route for the first host implementation.

The host starts the audio stream only while an authenticated client explicitly subscribes. The host advertises this fork's audio capability in `WindowList`. Older clients ignore the optional field and kind 33. The server sends audio only to subscribed clients and drops stale audio when its send queue grows; audio must not make video wait behind a long backlog. The iPad clears its jitter buffer on disconnect and format change. Captured samples and microphone data are never written to disk by this path.

Do not merge the whole upstream Sill PR #66 audio path. Its process tap uses `mutedWhenTapped`, which would mute the Mac output. The upstream packet shape and AAC-ELD decoder are reusable; the host capture and user control need separate implementation.

## Remaining proof

1. Build a host audio stream with no output-device or mute changes. Check its capture callback with synthetic or consented local sound and inspect its permission behavior.
2. Add an explicit iPad sound control and a capability-bound subscription. Prove that older Sill hosts and clients keep video and input working.
3. Install a separate host candidate only after source and input review. On the physical iPad, hear the Mac sound, check that the Mac still plays through its chosen output, then switch video sources and reconnect.
4. Measure sound delay and test a slow link. Verify that audio drops instead of piling up and that video remains responsive.
5. Design the microphone destination with an exact voice-session or input-device binding. Test microphone permission, route changes, echo cancellation, and reconnect before calling two-way sound complete.
