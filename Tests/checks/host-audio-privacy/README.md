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

## Endpoint coverage correction, 2026-10-19

This section supersedes the built-in-only coverage and version descriptions above.
The earlier 86 passing checks on the built-in-only implementation do not prove protection of
all audio endpoints. Parent-reported Mini receipt `endpoints-red-01` reproduced the failures
in tests at `47617430f7c70c40525072532eea3880128159c4`. The worker did not rerun that receipt.

`AudioPrivacyState` retains the legacy default version 1. The host privacy model explicitly
publishes version 2 after endpoint verification. The optional catalog field and schema stay
the same. An encoded version 1 remains version 1 after decoding and only describes
the previous built-in coverage. Version 2 covers audio endpoint master mutes and validated
BlackHole defaults. It does not describe Sentry, display protection, or input protection.

`PrivacyAudioSnapshot.plan()` exempts only the exact validated BlackHole 2-channel and
16-channel devices. Every other live endpoint with input or output channels needs a readable,
writable master mute for each active direction. This includes USB, HDMI, and other virtual or
aggregate devices. A nil mute prevents any planned writes and returns a Korean reason with
the offending UID and direction. CoreAudio reads external master controls and installs their
mute, identity, stream-configuration, and device-change listeners. Existing H1 observation
generation checks remain in place. The final guarded write still re-reads the current plan
and checks writability before setting a master mute.

The existing optional mute fields represent verified writable master control readback.
The architect comparison considered those fields versus a new per-channel coverage model.
Ponytail full chose the existing fields and native master mute operations. No channel fallback,
volume-zero fallback, new dependency, or separate protection owner is introduced.

The parent's read-only native probe found no master or per-channel mute or volume control on
DN32 input32/output32 or HDMI output2. Those endpoints must report `protected=false`.
Refusing protection does not silence existing hardware, and the guard does not partially
apply a plan when an unsupported direction is present. Physical and OS acoustic proof remain
OPEN, including timing gaps between property readback, OS changes, and audio callbacks.

The added injected tests cover external input and output mute listeners, unmute revocation and
repair, failed/read-only/missing master controls, unsuccessful setter readback, stale commands,
other virtual endpoint coverage, and stale external observation callbacks. They also pin the
explicit version 2 host publication and preserve legacy default version 1 decoding. The worker only inspected
source and diffs. All test execution, the exact Mini suite, full SDK compilation, and independent
review belong to the parent. No native HAL, device, network, build, test, or push was executed
by this worker. Local return, muted taps, and shield changes are outside this unit.

## Accepted local-return review corrections, 2026-10-19

This correction starts at `20121ea` on `codex/authenticated-local-audio-20261019`.
The worker exclusively owns this checkout until return. The parent owns exact Mini execution,
SDK compilation, native/device observations, and a fresh independent review. Earlier 121/139
check receipts and the earlier full SillMenuBar compile apply only to their original sources.
No new test or compilation result is claimed here.

Pstack uses the Bug fix path with sequential how/architect source analysis. The compared
persistence designs were compensating independent preference keys and a single typed envelope.
Model the Domain selected the envelope. Ponytail full reuses UserDefaults, DispatchGroup,
the existing capture lifecycle, HAL registry, authentication generation, and test extractor.
No dependency or new runtime is added.

The scoped playbook disposition is recorded here because there is no task-list tool.

1. Reproduce it yourself on the matching surface via the driver skill. Skip runtime reproduction
   under the explicit no HAL/device/test/build instruction. The seven accepted source findings
   define the adversarial triggers below.
2. Binary-search the cause. Complete by tracing the actual guard, coordinator and server bodies.
3. Plan the fix. Complete with sequential design comparison. Children and messages are prohibited.
4. Verify on the same surface. Pending parent execution. The worker only inspects source and diffs.
5. Stage the commits so the failing repro lands before the fix in git history. Skip separate red
   execution and commits because this worker may not run tests. Regression sources accompany fixes.
6. Run Opening a PR. Skip under the no network/push instruction. Return one clean local commit.

`requestLocalReturn()` requires an acknowledged native ownership boundary. Its authenticated generation,
latch and persistence health are checked again after the await. `prepareLocalAudioReturn()`
revokes microphone authority and pending subscriptions, retires physical-route authority, and
awaits `StreamServer.drainRemoteAudio()`. That method closes the network epoch and waits for
all already-submitted audio `.contentProcessed` callbacks. A five-second timeout returns failure.
No restore setter is permitted before a successful acknowledgement. Capture teardown uses the
existing lifecycle. This boundary does not prove that device playback or acoustic buffers are empty.

Restore operations store UID, master scope and default selector rather than future numeric IDs.
Each step resolves the UID again and compares the complete observed snapshot with the preceding
authorized snapshot. After a setter, only its exact expected single-property delta is accepted.
UID reuse, unrelated default/mute changes, transport/plugin changes or hotplug stop the restore
before another restore setter. Failure retains the latch and attempts protection only when its
original journal and durable state remain valid.

`LocalAudioState` version 2 retains transport/plugin identity in addition to original UIDs,
master input/output mutes, channel counts and all three defaults. Identity-incomplete version 1
originals are refused rather than silently upgraded from the protected hardware state.
`CCRHostAudioPrivacyJournal.v2` is the authoritative single preference value. Its typed envelope
contains the latch and original state together. Old keys are read only as migration input when
no envelope exists. Missing/malformed original state under a latch cannot reach HAL writes,
on startup, reconciliation, or another arm. A failed clear reasserts the original protected
envelope and synchronizes it before any repair may advertise ready. Failed reassertion leaves
an explicit persistence fault with readiness and hardware repair disabled.

Every fresh unlatched arm captures current originals, even if an old completed journal remains.
A successful clear records local mode and discards the original together. Cleanup failure cannot
make the next arm reuse stale mutes. Failed listener removal marks observation unhealthy before
calling HAL, keeps the latch, and schedules one bounded repair. It never treats the invalidated
listener generation as healthy.

Existing paired peers cannot select physical routes after local return. A new explicitly trusted,
encrypted paired connection may arm remote protection again; existing remote audio requests
cannot do so. The physical-route denial remains active across local return and rearm.

The extractor now includes actual server `setRemoteAudio`, `resetRemoteAudio`, `drainRemoteAudio`,
`broadcastRemoteAudio`, and raw `send` bodies, plus actual coordinator preparation, revocation,
stop and state methods. Only connection/send-completion and capture adapters are substituted.
The fixture holds an actual extracted send completion across the local-return request, then
releases it to exercise the acknowledgement. Added injected cases cover post-await generation
changes, setter UID reuse, hotplug, unrelated selector change, transport replacement, failed
clear and failed durable rollback, failed first capture/restart, stale completed journals,
listener removal/repair, and post-return paired physical-route refusal. The manifest records
hashes for the extracted server bodies as well as coordinator bodies and full copied sources.

BLOCKED independent review until the parent reviews the new exact commit. No children, messages,
network, HAL calls, device operations, tests, builds or pushes ran in this correction. No Space
report was sent under the explicit network prohibition. DN32/HDMI without writable master mute
still refuse complete protection. Sentry overlay, input protection and independent display
monitoring remain unimplemented. No acoustic zero-gap guarantee is claimed.

## Native startup ownership and participant coverage correction

Base `d52cd9d0abbe9c1dbb3f9cd95021de85b34f4c33`. This exclusive local codeunit uses
Pstack poteto Bug fix and architect with a sequential design comparison under the explicit
no-children restriction. Ponytail full reuses the existing coordinator callback and drain barrier.
An AppModel-only catch callback was rejected because cold requests would still lack an explicit
initializing owner. The selected small `NativeAudioStartup` lives in the existing return file.

AppModel owns startup from initialization, passes that same owner to production privacy, and
wraps only the throwing coordinator constructor. A cold request with verified participant coverage
waits asynchronously before authentication. Successful construction still requires the actual
coordinator callback. Proven failure before native participants is the sole empty-native
acknowledgement. A missing callback after successful construction remains a refusal.

Native quiescence does not cover S23's independent `audio-session.js` / `audio-router.py` path.
Coverage defaults to unknown. The production factory explicitly declares native-coordinator-only
coverage. Both refuse local return before OS authentication or HAL access in the request, and
the production menu displays the Korean unavailability reason. Startup reconciliation continues
to enforce existing protection. No common registration service or S23 protocol was added.
Production remains closed until actual S23 participant authority and proof are connected.

Existing injected checks explicitly declare verified all-fake-participant coverage without changing
their assertions or version 2 physical endpoint rules. Added fixtures exercise both construction
outcomes, a pending cold request, a real extracted coordinator/server drain on success, missing
callback refusal after construction, and unknown/native-only coverage refusal. The emitter asserts
actual AppModel/factory/menu wiring and extracts the production callback assignment.

Source/diff inspection only. Tests, builds, HAL, devices, network, messages, children and pushes
are prohibited for this codeunit and were not run. Parent Mini/full-SDK execution and fresh
independent review remain required for the returned exact commit. The reported 174-pass baseline
belongs to the base revision and is not a result for this correction. No product was deployed.

## Accepted source and host integration

The integration starts at `f8540b97f453b6edff3231cd1261aba762b4c265` and merges exact
shared-host commit `5162bd504a64dc9b435e714e901ceabe146f2f63`. `AudioPrivacy.swift` owns
the single public state definition. `WindowList` retains both `selectionRevision` and
`audioPrivacy`. Host state constructors explicitly emit v2, while implicit construction
remains v1 and the iPad continues to require exact v2 protection.

Source publication still requires the original admission through queued send and replay.
The send boundary still strips an epoch that differs from the server's committed epoch.
Privacy failure revokes microphone and remote audio authority, and local return still waits
for submitted audio completions and capture teardown. Production coverage remains
`nativeCoordinatorOnly`, so S23 participant authority must join before authentication or
HAL restoration can run. DN32 physical silence remains unresolved.

Integrated checks passed in Mini-owned volatile RAM: host source transport 68, desktop
recovery 164, privacy 187, publication 20, and joint catalog codec 4. The publication
checks cover privacy revocation and source revision together at the actual send boundary.
Native Mac and full iPad SDK builds passed locally without signing, installation or launch.
These results require parent independent review before canonical integration and do not
establish physical silence, S23 coverage, source-guard migration or live acceptance.
