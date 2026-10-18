# HOST audio privacy unit

Task remote-audio-privacy-20261019 HOST, base 0dd10d1f9463001531416f37d756214b0ff32456.
Exclusive branch codex/remote-audio-privacy-20261019. Changes remain dirty for parent review.

The implementation has not been compiled or executed by this worker. The parent owns all
builds, test execution, hardware observation, app installation and integration with its
separate server/coordinator recovery patch. No client files changed.

## Architecture and contract

StreamCoordinator owns admission and active subscriptions. SillVirtualMicrophoneOwner owns
only virtual microphone grants and a single lease. HostAudioPrivacy owns the durable latch,
verified status, listeners and bounded repair. CoreAudioPrivacyHAL hides CoreAudio identity,
master mute controls and all three default selectors behind injected operations.
PrivacyAudioSnapshot derives the allowed writes. No write can unmute or select a physical target.

The architect alternatives were a host-owned guard shared by admission/owner/route boundaries,
and per-feature checks with a separate persistence owner. The shared guard was chosen because
per-feature checks allow the route writer or lease cleanup to bypass the invariant.
This was a sequential design comparison. No children or independent reviewers were run.

Caller sequence is AppModel loads branded defaults, reconciles an existing latch before
constructing the server, then an authorized connection arms and persists before its catalog.
Audio/mic admission re-reads all required state. A failure closes existing ingress/render and
subscription transport gates synchronously, invalidates pending starts and asynchronously
tears down capture. A repair never resumes a subscription or reuses a revoked grant.

HostAudioPrivacy exposes package armAndVerify(), verify(), reconcile(), stop(), latched and
state. Its internal HAL and persistence closure are injected. Native operations are opted into
only by the installed /Applications/CCR Sill.app, bundle com.ambrion.sillcanvas.mac, without
--synthetic. Other hosts default to nil privacy, publish no privacy status/microphone grant,
and refuse remote audio. Legacy CLI physical route behavior remains available when unlatched.
The production UserDefaults key is CCRHostAudioPrivacyLatched.v1. synchronize() and immediate
readback are required before HAL writes. No random suite or CLI defaults are created.

The only new wire field is optional WindowList.audioPrivacy. AudioPrivacyState is public,
Codable, Equatable and Sendable with version:Int=1, protected:Bool, reason:String?=nil.
protected=true verifies current built-in master input/output mutes plus default input
BlackHole2ch_UID and both output/system-output BlackHole16ch_UID. Both devices must uniquely
belong to their exact audio.existential.BlackHole2ch/BlackHole16ch plugins, resolve by UID,
be alive, virtual, have exact 2/16 input/output channels and use 48 kHz. Korean reasons report
failure. Older catalogs decode without the field. No remote sender or client resume is added.

While latched, every physical route selection is refused before AudioHardwareRoutes.select,
including its rollback logic. Already selected BlackHole2 is valid for microphone acquisition
only after fresh privacy verification and no active owner lease. A call app consuming the
virtual input is expected. runningSomewhere no longer rejects it. Lease cleanup and shutdown
retire ownership without changing defaults or unmuting anything.

System/default, built-in master mute and selected device properties have owner-scoped listeners.
Events revoke on failed readback and coalesce into a single delayed reconciliation pass.
Each pass attempts at most the missing mute/default writes once. There is no recurring retry
or polling task. A later event or new admission can retry a failure. Listener installation,
readback, identity and setter failures all prevent protected=true.

## Parent verification

emit.py only prepares a new package at a parent-selected approved path. It does not build,
launch audio, create a RAM disk, connect to Mini, or run anything. The parent can transport
that exact package as volatile input and run `swift run HostPrivacyChecks` there using its
normal source hashes, resource routing and cleanup receipts. Keep manifest.json with results.
An emitted package is a narrow independent injected check, not source-guard transfer acceptance.

The suite includes failed setters/readbacks at each of five writes, absent defaults/mutes,
persistence failure, already safe defaults, restart with a latch, exact plugin/UID/transport,
ambiguous devices, observer failure, default changes, hotplug and bounded repair. The real
microphone owner is used with a fake output unit to check already-selected input, active lease
exclusion, stale cleanup and no physical restore. Exact coordinator method bodies are extracted
with only the connection type substituted. They check physical-route refusal, catalog grant
suppression, synchronous cancellation of existing subscriptions/microphone and stale completion.

Required parent gates remain full host/app compile, injected suite execution, independent review,
integration with the other coordinator patch, actual HAL readback and approved paired-device
acceptance. Existing microphone-uplink/audio-routing extraction suites do not yet include the
new privacy dependencies/fixture field; parent must adapt their extraction if running those.
There is no claim of strict silence for DN32/HDMI or apps opening physical devices directly,
no acoustic/physical speech proof, and no crash/hotplug leak guarantee. OS changes can occur
between a readback and an audio callback. No production build, runtime, release or commit occurred.

## Exact standalone native-probe compile inputs

Compile the current `Sources/StreamProtocol/*.swift` as module/library StreamProtocol first.
Then compile these exact production files together with the parent's probe entry point as one
executable module using `-parse-as-library -package-name Sill`, the protocol module's `-I`/`-L`
paths and `-lStreamProtocol`. Add that library directory as an rpath for the probe.

- Sources/SillHost/HostAudioPrivacyModel.swift
- Sources/SillHost/HostAudioPrivacy.swift
- Sources/SillHost/HALMicrophoneSink.swift
- Sources/SillHost/HostMicrophoneGrant.swift
- Sources/SillHost/HostMicrophoneReceiver.swift

Those five files are sufficient. They import Foundation, CoreAudio, AudioToolbox, AVFAudio,
Network and os. Their native audio-unit definitions are dependencies, but the guard never
constructs an audio unit. SillVirtualMicrophoneOwner, StreamCoordinator, StreamServer, AppKit
and a host app are not probe dependencies. The parent can instantiate
`HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: .native), latched: ..., persist: ...)` inside the
same executable module. A production persistence probe must explicitly use the branded app
preference domain `com.ambrion.sillcanvas.mac` and keep `CCRHostAudioPrivacyLatched.v1=true`.
The `HostAudioPrivacy(defaults:)` convenience initializer writes that key on armAndVerify.
No native probe is generated or run by this suite. Read-only inventory, approved apply/readback,
listener observation and acoustic/device acceptance remain distinct parent gates.

The parent may run `python3 -B Tests/checks/host-audio-privacy/run.py --output ABSOLUTE_NEW_PATH`
inside its approved compute/scratch context. run.py emits the package, builds/runs only the
injected tests, writes checks.log/result.json and verifies input hashes before/after execution.
It does not select a host, transfer source, create RAM disks or invoke the native probe. The
worker did not execute either emit.py or run.py.

HDMI input configurations with zero bytes or zero buffers are accepted as zero input channels.
The fake HAL suite exercises both shapes. Plug-in device-list and bundle-ID listeners supplement
the device/default/control listeners. All UID translation, plugin translation, membership,
transport, liveness and format reads still flow through the injected registry operations.
