# iPad remote audio opt-in

This sidecar starts at `951af410413493816d10a40acf8fc3e93cabe6f2`. Its owned paths are `iOSClient` and this directory. Host, shared protocol, relay, and Vision code are outside its scope.

The settings panel shows Mac audio only after the current connection advertises `WindowList.remoteAudio == 1`. A tap sends kind200 ON with a fresh UUID. The controller discards kind33 until the same connection returns kind201 ON with that UUID. Pending consent has a six-second deadline. OFF, deadline expiry, source selection, observed source change, capability loss, connection loss, and handover revoke local consent. OFF has a separate UUID and stops the player immediately. A new connection starts without capability or consent.

`IPadRemoteAudioController` owns the consent states and effects on main. `StreamClient+Audio` passes actual message origin into that controller. Audio commands use the original NWConnection directly because SessionLink migrates held ordinary input to another connection. The decoder epoch remains locked through sample append. OFF clears samples and stops the engine before it returns, so an old decode cannot refill a stopped player.

## Reproduce the checks

Run `Tests/checks/iPad-remote-audio/run.sh --mutants` from this worktree.

The check compiles the actual production controller. `fixture.py` extracts the real StreamClient controller initialization and connection setter and compiles the entire audio adapter with fake peer, transport, and player objects. The resulting executable tests capability, explicit consent, current peer identity, matching ACK, stale ACK, packet admission, distinct OFF UUIDs, deadline, source changes, replacement, and disconnect. Eleven supplementary textual checks confirm that the main client and settings panel call these components. Those textual checks are not the behavior proof.

`player-fixture.py` compiles the real player receive, stop, and append methods. It replaces the AVAudioEngine setup and AAC decoder with fakes. A semaphore holds an encoded decode across OFF, then verifies that its late samples cannot refill or restart playback. This tests queue invalidation and immediate stop, not AAC fidelity, AVAudioSession routing, render callbacks, or audible output.

The mutation run removes individual consent, origin, source, deadline, packet, and stop protections. Each mutant must compile and fail a behavior assertion. Compiler failure and unrelated crashes do not count as caught mutants.

For an unsigned iOS build, run the following command. It does not install or launch the app.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project iOSClient/Sill.xcodeproj -scheme Sill -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ipad-remote-audio -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

## Design and verification limits

The pstack how pass traced the existing network queue, main-thread publication, connection handover, player queue, and shared settings panel. The architect pass compared a reducer plus effect interpreter with one callback controller. A sequential exploration was used because nested agent tools are unavailable. The callback controller keeps request ownership and the actual effects in one testable object. Model the Domain shaped the status enum. Test Behavior, Not Implementation shaped the packet and transport assertions. Prove It Works requires the executable tests and the real unsigned iOS build.

The work is disjoint from main's host changes. One owner keeps the iPad control, network origin, player invalidation, and UI changes coherent. The Mac build slot was idle before the unsigned iOS build. No nested independent reviewer is available. Independent review belongs to the integrating owner and remains pending.

Physical installation, audible playback, speaker and microphone routing, background behavior, network performance, and Mac video and touch interaction on a device remain unverified here. Video and input handlers remain in the build. The adapter's behavior check confirms that frame messages bypass the audio handler. This sidecar does not close any open host lifecycle review.
