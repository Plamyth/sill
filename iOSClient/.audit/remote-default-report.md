# CCR Sill iPad remote startup and original-record retirement

Owner is this chat. Task key is `ipad-remote-default-20261016`. Base is `codex/ipad-canvas-dictation-20261016` at `7e0cc53e8eb13a02d07211d11bd86370a028dc0d`. Changes are local and uncommitted. Production edits are limited to three iOSClient files. All new tests and evidence are below iOSClient.

## Startup behavior

`StreamClient.swift` previously required an exact tagged Bonjour network row before attempting an automatic connection. A formally paired remote Mac with no Bonjour row remained waiting forever. A wired dial also fell back to Bonjour rather than the saved remote addresses.

Startup now gives discovery its existing three-second grace. A matching tagged wired row with a pinned TLS door wins immediately. Otherwise startup calls the existing `dialSaved` path once. Local-network denial skips the discovery grace. The original eligible saved-Mac selection and preferred identity rules are unchanged.

The startup state records a wired attempt. Failure, waiting, or the existing 2.5-second wired deadline consumes that attempt once and starts the existing pinned remote dial. A TLS-ready connection that has not delivered its first window list also falls back. An admitted session and callbacks belonging to a replaced connection are protected. A fallback deferred in the background resumes once through remote when the app returns.

`StreamClient+Remote.swift` offers the same fallback when a startup wired connection closes before admission. Existing authenticated removal, changed-key, pairing-required, and host-goodbye handling retain their precedence. Explicit manual connection behavior, established-session path optimization, remote address ordering, and TLS construction retain their existing behavior. This patch does not force an established remote session to remain on a VPN when the existing policy can move it home.

## CCR original record retirement

`RemoteDialPolicy.swift` adds `retiringCCROriginal`. Ordinary `successors` still requires identical names. The new CCR policy requires all of the following.

- The current record is the eligible preferred pairing and its fingerprint matches the authenticated TLS key.
- The current pairing method is cable. The original pairing method is QR. Both records have valid, distinct identities.
- The current name is exactly the original name plus ` · CCR Sill`.
- The original last connection is known, is no earlier than its pairing, and precedes the CCR pairing.
- A Tailscale address appears in the current session's signed MacInfo and both saved records. No third saved record claims that address. A LAN, loopback, or generic internet address never qualifies, even if labelled VPN.
- Exactly one original record qualifies.

The integration method in `StreamClient.swift` additionally requires an admitted pinned session, the stored preferred ID, current signed MacInfo from that key, and no pairing, pairing ask, or pending link. Signed information older than the saved information is rejected. It runs after authenticated connection and when verified MacInfo arrives, so address information arriving after the first list can supply the proof.

Only the old record is removed through the app's normal `persistSavedMacs` path. The CCR record, its fingerprint and preference, unrelated records, and active connection are preserved. Running the policy again makes no change. No preferences plist is edited externally. If proof is missing, both records remain. No device data was changed by this task.

## Verification

Before the startup fix, the initial extracted-method reproduction reported `9/17 checks passed; 8 failed`. After the fix, those same checks passed. The expanded startup suite reports `35/35 checks passed; 0 failed` in `remote-default-after.log`.

The focused real-policy and extracted-integration suite reports `52 passed, 0 failed` in `remote-default-security.log`. It covers the supplied original pairing time 1792107647, original last connection 1792126432, and CCR cable pairing time 1792138802. It also covers missing proof, wrong pin, chronology, ambiguous/shared addresses, unrelated Macs, idempotence, preference preservation, and active pairing.

The existing suites have English text expectations against the already localized Korean client. The HEAD and candidate comparison has identical results and identical failure lists. `policy` has 382 passing and 10 failing assertions. `home-device` has 143 passing and 39 failing assertions. `remote-rules` has 121 passing and 2 failing assertions. `remote-default-comparison.json` records the exact source hashes and the unchanged 51 failures. Separate baseline/candidate logs preserve every assertion. These are existing failing tests, not a green test result.

The three changed production files pass an iOS-target Swift syntax parse. The parser warns that the selected sysroot is macOS. This is a syntax check, not an iOS typecheck or build. `xcrun --sdk iphoneos --show-sdk-path` reports that the SDK cannot be located. No physical device, simulator, signing, installation, Mac host, or Vision file operations were performed.

`pstack:poteto-mode` supplied the reproduction-first procedure. `how` and `architect` were applied through the documented sequential fallback. Model the Domain kept startup ownership in the existing state machine. Laziness Protocol reused `dialSaved` and normal preference persistence. Fix Root Causes removed the Bonjour prerequisite. Test Behavior, Not Implementation guided the connection decisions and preserved-record assertions. No independent reviewer tool is available. Independent review and native/device acceptance remain open.

## iPad audio feasibility

The current iPad controls already support Mac audio to iPad and iPad microphone to Mac. `HostSettingsPanel.swift` exposes both toggles. `IPadRemoteAudioController` binds consent to one peer and stream source. `IPadMicrophoneCapture` uses the current AVAudioEngine input. `IPadAudioSession` owns shared playback/microphone leases and restores the previous configuration.

A connection-time chooser and a menu entry can reuse those two controllers and preserve their explicit consent. This is a client implementation option inferred from these interfaces. It has not been implemented or tested here.

Local iPad input/output route selection would require new route UI and coordination through the existing audio-session owner, including route-change and lease recovery tests. Physical routing cannot be verified within the current device restriction.

Choosing among Mac hardware input/output devices is not supported by the current messages. `RemoteAudioSubscription` carries enabled and requestID; `MicrophoneControl` carries stream scope and grants. Neither message contains a hardware-device inventory or target ID. That capability requires a separate protocol and host change owned by the host task. No host or audio code was changed in this patch.

## Follow-on audio task

The subsequent bounded iPad audio task implements the supported-path chooser described above. Its current source, native build evidence, focused tests, and remaining physical acceptance are recorded in `audio-routes-report.md`. The earlier feasibility and default SDK observations above describe the prior task's state.
