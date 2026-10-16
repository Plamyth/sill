# CCR Sill audio path

## Intended behavior

The iPad plays the Mac's sound while the Mac keeps its current output device and volume. The iPad user turns remote sound on or off. Audio must stop when the Sill session ends. A later microphone path must bind input to the intended Codex voice session or an explicit Mac input device.

## Current source

Commit `89f9550` adds kind 33 `AudioPacket` decoding and `RemoteAudioPlayer` to the iPad fork. That iPad target built with a valid signature, but this source has not been installed or heard on the iPad. The installed iPad build still has working video, touch, Pencil, and recipient selection. The current host candidate compiles and the 200 protocol checks pass; no host audio candidate is installed yet.

## Host capture choice

Two routes were considered. Adding audio to the video `WindowCapture` stream would share its capture filter, but every source switch would stop the audio stream. A window filter may also omit audio from other apps on the Mac. A separate ScreenCaptureKit audio stream keeps sound stable while video sources change. It can capture without changing the Mac output route or muting apps. Use that route for the first host implementation.

The host advertises `WindowList.remoteAudio = 1`. The device sends kind 200 `RemoteAudioSubscription {enabled, requestID}` only after a user action. The host echoes that ID in kind 201 `RemoteAudioState`; a revocation caused by source change or capture failure has no request ID and never grants sound. The iPad must ignore a late enable answer whose ID no longer matches its pending user action. On every new connection and source change, sound returns to off and requires a new opt-in. Backgrounding stops the iPad player and sends off where possible; reconnection never resumes sound automatically.

The host captures with a separate ScreenCaptureKit stream and leaves the Mac's output route and mute state unchanged. The server sends kind 33 only to currently subscribed connections, drops audio for a client with more than 512 KiB of pending network data, and increments a capture epoch on source change. A callback from an old stream is discarded if its epoch differs. Each new opt-in takes a serial capture-queue boundary, discards a partial PCM packet, and admits only packets captured after that boundary for that client. Subscription changes and state answers use the same ordered network queue. Capture failure and normal stop both drain the PCM queue before another opt-in can start. Every ON or OFF advances a host action serial even if the client reuses the same request ID, so a delayed ON cannot undo a later OFF. An idle stop checks for new subscribers before stopping; a pending stop also bars a new enabled answer until the stop finishes and capture is checked again. The iPad clears its jitter buffer on disconnect and format change. Captured samples and microphone data are never written to disk by this path.

Do not merge the whole upstream Sill PR #66 audio path. Its process tap uses `mutedWhenTapped`, which would mute the Mac output. The upstream packet shape and AAC-ELD decoder are reusable; the host capture and user control need separate implementation.

## Remaining proof

1. Check the host capture callback with consented local sound and inspect its permission behavior. Compilation and protocol checks do not prove audible sound.
2. Add an explicit iPad sound control and a capability-bound subscription. Prove that older Sill hosts and clients keep video and input working.
3. Install a separate host candidate only after source and input review. On the physical iPad, hear the Mac sound, check that the Mac still plays through its chosen output, then switch video sources and reconnect.
4. Measure sound delay and test a slow link. Verify that audio drops instead of piling up and that video remains responsive.
5. Design the microphone destination with an exact voice-session or input-device binding. Test microphone permission, route changes, echo cancellation, and reconnect before calling two-way sound complete.

## Microphone owner decision, 2026-10-16

The current source has a host receiver and a virtual-device HAL sink, but the production `SillMenuBar` coordinator is created without a `HostMicrophoneOriginalOwner`. Its `WindowList.microphone` capability is therefore absent. The receiver checks the paired peer, encrypted route fingerprint, source, input generation, video epoch, destination, call generation, and expiry before admitting PCM. The sink also verifies the approved virtual device UID, plug-in, channel layout, and 48 kHz format. These checks do not identify which Codex voice call owns that device.

Two owner shapes were considered:

1. Infer ownership from the Control Room `activeVoiceSession` snapshot and CoreAudio's Codex process input state. This can observe a candidate call and current input device, but neither read is an atomic authorization. A closed call and a new call in the same process could occur between reads. This shape must not mint a host grant.
2. Have the original voice-call owner issue a lease containing its exact call generation, approved input device, and revocation event. A single Mac-side owner object would expose only `microphoneGrant(...)` to `StreamCoordinator`; it would synchronously revoke all issued `HostLocalOwnerGrant`s before a call, route, or device generation changes. The CoreAudio process probe can independently reject a mismatched route, but cannot create the lease. This is the selected integration shape.

Caller usage is `StreamCoordinator(..., microphoneOwner: owner)` only after that owner is backed by a live original-call lease and the virtual input route is explicitly approved. With no lease, the provider returns `nil`, the catalog advertises no microphone capability, and the iPad cannot start capture. Tests must prove no lease means no capability, a changed call or route revokes an old render grant, and a new call cannot inherit the prior peer or packet sequence. The read-only `Tests/checks/microphone-route/ProcessProbe.swift` currently reports the Codex process input state and device UIDs; its idle result is not a voice-call receipt.

The missing input is an authoritative call-generation/revocation event from the Codex voice owner. Until it exists, keep production microphone routing off. Audit the existing BlackHole devices' S23 and system-output users before dedicating any virtual input to Sill. The original Sill installation and Mac sound routes remain untouched.

## Host continuous-voice candidate, 2026-10-16

The first host receiver retained only the latest microphone frame, so five 20 ms frames arriving together could lose four before the MainActor drain. The candidate now preserves up to six ordered frames in ingress and six packets in the render buffer. A normal 100 ms five-packet burst can begin playout after a 50 ms application delay and finish before the 160 ms per-packet residence limit. The buffer supports partial HAL pulls across packet boundaries. On overflow it discards the oldest packet and increments saturating local counters; on expiry it discards stale packets. Stop, grant revocation, peer loss, and source change close the render gate and remove queued audio.

The exact candidate source built as `SillHost`; the inert host harness passed 356 assertions and caught all 16 compiled fault variants with source unchanged. The harness used distinct sample values to check five 960-frame packets in order, a delayed start, partial reads, ring wraparound, overflow, expiry, and post-stop silence. This is source and fake-device evidence, not a native audio or Codex call receipt. The independent review found a remaining real-time tradeoff: rendering uses a nonblocking lock and can output silence if a producer happens to hold the ring lock. Decoding is outside that lock and the protected copy is bounded, but no zero-glitch guarantee is claimed. TCP/OS buffering and the original-call owner route still require separate measurement and approval.
