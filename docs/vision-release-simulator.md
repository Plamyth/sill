# Verify the isolated native Vision draft flow

Use `Scripts/vision-release-simulator.py` for the existing xrOS 27 simulator
`D354C526-248E-4C2E-A761-A2505C11F1DC`. This adapter prepares a separate
`dev.ambrion.SillVision.ReleaseTest` app from the actual Vision sources.
It never installs, uninstalls, launches, or replaces `dev.ambrion.SillVision`.
The protected original build 1 and its container remain outside the adapter's
mutation targets. Physical deployment behavior remains unchanged. Its shared
runner accepts explicitly named return codes; existing callers still require
exit 0. Only the lifecycle status reader permits its documented exit 2, then
validates the JSON and rejects violations in this simulator's singleton group.

The adapter supplies a native XCTest path for a bounded diagnostic. It does
not supply the missing complete remote integration driver. Successful output
uses `ccr.vision.simulator-diagnostic/v1`, `status=diagnostic-verified`,
`releaseStatus=held:full-remote-driver-missing`, `wholeProductTestAccepted=false`,
and `productionEnabled=false`. Do not use it as a global `testAccepted` receipt.
`production` and `upload` always fail closed.

## Prepare the exact source

The parent reviews and integrates the worker commit first. Publish only through
the parent's approved integration process. The adapter reuses the physical
adapter's clean Git, official remote/ref, exact commit/tree, storage routing,
hash, and evidence helpers. It refuses dirty, detached, mismatched, or moved
source. No independent checkout or simulator result replaces the owner lineage.

Obtain an output path using `storage-route path development-archive --project
CCR-Vision --filename <stable-output-name>`. Pass the returned JSON `path`
unchanged as `--output`. The adapter checks routing and owns its output with
an owner marker and a lock. It stores revisions separately by commit and tree.

Run this command from the exact clean source after independent review.

```sh
python3 -B Scripts/vision-release-simulator.py prepare \
  --repo <absolute-clean-integration-worktree> --remote origin \
  --ref <official-refs/heads/integration-ref> \
  --commit <exact-commit> --tree <exact-tree> --output <routed-path>
```

Prepare invokes `xcodebuild build-for-testing` on the shared
`SillVisionReleaseTest` scheme with Debug, `xrsimulator`, explicit source stamps,
and an ad hoc simulator signature. `NativeBuild.xcresult` retains first-build
diagnostics and its path and existence are recorded on failure. It checks the built bundle identifier,
platform, executable, Info.plist, CodeResources, complete file manifest and
signature. The `.xctestrun` must contain the actual UI test target. Missing or
unsupported SDK output is held. An incomplete build directory is preserved for
review instead of being silently rebuilt.

## Acquire the registered lease in the parent

The parent alone starts, renews, and releases the lease. The worker and adapter
never boot or shut down a simulator by hand.

```sh
~/.local/bin/bt-service-lifecycle start ccr-vision-xros27-d354 \
  --owner 01a13005-ff61-7780-b0e8-6dc171de1c9d \
  --ttl 1800 --generation <exact-commit>
```

Use the returned `leaseId`. Every simulator command rechecks the actual file
`~/.local/state/service-lifecycle/leases/<leaseId>.json`, the registered service,
owner, UDID, xrOS 27 runtime, generation, timestamps, and lifecycle `status`.
The status row must agree with the canonical file and say live, unexpired, and
not violated. A copied lease JSON cannot authorize operations. Renew using
the same lease ID before the remaining TTL falls below the native command budget.

Run `deploy` with the prepare arguments and `--lease-id <leaseId>`. Deployment
requires the registered simulator to be booted and available. It installs only
the separate test bundle when absent, writes an uncertain install intent before
installation, and refuses automatic reinstall after an uncertain attempt.
An existing different test bundle is held for parent recovery. Exact existing
bytes can be reused. No original app restoration or rollback is claimed.

Deploy launches the actual app with an explicit source/run context and reads
`Documents/CCRReleaseRuntime.json` from its actual data container. It compares
source, build, bundle, executable/Info/CodeResources hashes, fresh timestamp,
process boot UUID, and the live PID's exact installed executable path. It does
not manufacture a runtime file from expected values. Deploy alone records
`runtimeAccepted=false` and does not establish UI success.

## Run the actual native UI diagnostic

Run `accept` with the same arguments and lease ID. The name is retained as the
adapter action; the returned result is the narrow diagnostic described above.
The adapter rechecks installed test-bundle bytes before XCTest can replace them.
A mismatch is held for recovery. It copies the verified `.xctestrun`, retains its environment and path
bindings, injects the explicit context, and requires its target app path to be
the prepared test app. It runs the one native UI test without rebuilding or
parallel simulator clones, then reads the actual `.xcresult` summary and test
tree. Missing driver, unsupported result shape, failed or skipped assertions,
missing runtime, stale process, changed source, or mismatched fixture holds.

`VisionReleaseSimulatorUITests.testWorkspaceFixture` performs these steps.

1. Launch malformed context and assert the Korean refusal view appears.
2. Launch valid context into the actual `SillVisionWorkspace` with the existing
   DEBUG `MockCatalog` and its selected window.
3. Open the existing `VisionTextDraftPanel` and `VisionDraftEditor`.
4. Assert empty review fails, enter text, review, reopen editing, and review again.
5. Submit through the existing draft state machine and `submitVisionText` boundary.
6. Close the panel and assert the simulated provider display shows the text that
   the provider wrote and read from its private container. Attach a screenshot.
7. Use the actual disconnect control, reset the provider's stored draft, and
   assert the normal disconnected workspace appears.

There is no separate test draft form and no blanket workspace disable. The
provider substitutes only the boundary for a simulated legacy Mac input target.
It performs real private-container write, read/compare and removal, deduplicates
submission request IDs, and records source/run/process-bound events. The adapter
reads this actual receipt and independently checks the stored draft is absent.
It does not label the provider receipt as an actual remote Mac response.

Test activation requires the fixed test bundle, DEBUG, simulator, matching
embedded source stamps, and an explicit UUID context. Invalid context displays
the refusal view before any session is created. The text profile's client skips
identity/defaults startup and lifecycle callbacks. Its session never starts
Remote, autoconnect, Bonjour, stats, or audio reconciliation. `startBrowsing`,
`startRemote`, and typed pairing refuse the test bundle. No real connection,
pairing/keychain access, host probe, audio engine start, or permission prompt is
part of this provider. Existing unsupported audio capabilities remain visible
with their normal availability state.

Modern display selection, additional window admission, video decoding, physical
gaze, actual audio, HAL, Sentry and complete remote acceptance remain unverified.
All physical adapter required checks remain intact. This profile cannot remove
them, synthesize representative remote API success, enable production, or mark
the whole product accepted. The parent must implement and execute the remaining
drivers before release convergence can advance beyond this diagnostic.

## Run deterministic source checks

```sh
python3 -B Tests/checks/vision-release-simulator/test_simulator.py
python3 -B Tests/checks/vision-release-adapter/test_adapter.py
```

These Python checks mock SDK, signature, lifecycle and simulator boundaries.
They validate canonical lease refusal/revocation, installed bytes, actual
runtime file handling, stale/PID mismatch, protected bundle rejection, native
test result requirements, fixture source/run/reset, and physical check retention.
They do not run Swift, XCTest, an SDK, a simulator, a device, or a service.
The parent owns independent review and actual build, lifecycle, UI assertions,
screenshots, native command compatibility, runtime readback and cleanup receipts.

The Pstack Feature worker traced startup and the native evidence boundaries in
one scoped worktree. Model the Domain kept exact source and lifecycle identity
explicit. Ponytail full reuses stdlib helpers, MockCatalog and the existing native
draft editor. ARENA, Orca, competing exploration and nested workers are excluded.

## Bounded remote peer profile

`Context.profile` accepts `text` or `remote`. An omitted profile preserves the
text diagnostic above. Unknown or null profiles refuse before creating a
session. The fixed test app also refuses identity creation for invalid contexts
and never reads, creates, deletes or checks keys in the real keychain.

The `remote` profile creates a scene-owned listener bound to `127.0.0.1` on an
OS-assigned port. Both TLS peers use ephemeral `RemoteKey` and `RemoteIdentity`
keys with `RemoteTLS` mutual pins and the session ALPN. The production
`dialSaved`, `RemoteConnector`, `SessionLink`, `MessageReader`, signed Mac info,
modern input binding and `HEVCDisplayView` paths handle the connection. The
in-memory saved Mac row cannot persist. Discovery, pairing and reconnect are
closed for this test bundle. Scene leases and foreground/background observers
remain active. Audio uses a silent provider, unavailable microphone capability
and an empty audio intent context, with no OS permission request.

The simulated peer sends alternating 64 by 64 HEVC IDRs and a modern desktop
catalog with one display. It validates received `SourceInput` generation and
video epoch. A text event writes and reads its private provider file before the
UI reports that the peer received it. Reset removes that file and verifies
absence. Receipts remain in
`Documents/CCRRemoteFixture/<runID>/<window-admission>/receipt.json` and bind
source commit/tree, run, process boot, window admission and video epoch. The
listener stops and resets the provider on EOF, scene release, error, or its
120 second lifetime. Receipt metadata keeps `wholeProductTestAccepted=false`.

The parent runs the new native test on its exact prepared test app and existing
simulator lease. Select
`VisionReleaseSimulatorUITests/VisionReleaseSimulatorUITests/testRemotePeerFixture`
with the same `CCR_VISION_RELEASE_CONTEXT` source/run environment. The test adds
the explicit remote profile, verifies TLS and signed identity, waits for native
presentation, submits through the existing draft panel, checks the peer's real
input readback, resets the provider and disconnects. It retains a screenshot.
The Python adapter remains unchanged and continues to select the text test.
The parent must separately inspect the remote receipt and exact SDK/XCTest
result. Neither that adapter nor this source change claims full remote acceptance.

This unit does not exercise multi-display switching, other input classes,
physical gaze, audio capture/playback, HAL, Sentry, real Mac pairing or production
acceptance. The fixture status labels those limits in Korean. Source checks and
portable HEVC decoding do not prove Network.framework or the native simulator
renderer. The parent owns those exact SDK and runtime checks.
