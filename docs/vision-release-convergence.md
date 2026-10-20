# CCR Vision release convergence adapter reference

Status: **onboarding-required**. The adapter implements source, signed build,
native readback, and receipt validation. It does not implement the physical
acceptance driver or provide an isolated host/data/provider environment.
Production, App Store upload, registry mutation, and remote publication are
disabled or outside this worker's scope. No deployed or accepted state is
established by the unit fixtures.

The original owner is `01a13005-ff61-7780-b0e8-6dc171de1c9d`. The implementation
base is `8690e56436deaee554ffa58959ad80015d5e811c`, tree
`d9c6c17ce17f17a85d593753ef3fcaff32dde17d`, on the exclusive worktree branch
`codex/vision-release-convergence-20261020`. The parent reports that this base
is published at `origin/codex/vision-test-destinations-20261020` with a passing
source-guard capture. The adapter verifies the remote ref itself at execution.
The separate shared Mac host 141 / source `482754c` is not integrated into this
Vision base. This change does not modify host or audio behavior.

## Invocation and output ownership

`Scripts/vision-release-adapter.py` uses Python's standard library. The executable
in a convergence command array can be `/usr/bin/python3`, followed by `-B`, the
absolute script path, action, and arguments. `bt-release-convergence run_adapter`
reads the last JSON object on stdout. Success exits 0. A held result exits 2
and includes a reason. Actions are `prepare`, `deploy`, and `accept`.
`production` and `upload` always return held before doing any work.

Required arguments are `--repo`, `--remote`, `--ref`, and `--output`.
`--commit` and `--tree` are an optional pair of exact pins. Without pins, the
adapter captures clean local HEAD/tree once, verifies exact `ls-remote` equality,
and compares later checks with that immutable starting Source. A stable registry
command therefore works after a new reviewed integration commit is published.
The official remote URL must be `https://github.com/Plamyth/sill.git` or its
`git@github.com:Plamyth/sill.git` equivalent. The ref must be a full branch ref.
The upstream Saffsanity repository is refused.

The parent selects the official integration ref and global descriptor. An
example static argument array is:

```json
[
  "/usr/bin/python3", "-B", "<absolute-script-path>", "deploy",
  "--repo", "<clean-official-integration-checkout>",
  "--remote", "origin",
  "--ref", "refs/heads/codex/vision-test-destinations-20261020",
  "--output", "<storage-route-returned-absolute-base>",
  "--lease", "<absolute-owner-lease-path>",
  "--budget-seconds", "600"
]
```

The routed base is the exact `path` returned by
`storage-route path development-archive --project CCR-Vision --filename NAME`.
The adapter invokes that router and checks equality before writing. A new name
such as `release-convergence-runtime-20261020` separates actual adapter output
from existing onboarding observations. A nonempty directory without the
adapter's ownership marker is refused. The base marker binds repository,
owner, remote/ref, project, and environment; it does not pin a revision.

Each source gets a directory named `COMMIT-TREE-UDID`, with its own source
ownership marker. Each action gets a separate attempt directory, including
held results and native JSON files. `prepare.json` binds the signed bundle and
all bundle file hashes. `deployment.json` is a latest successful readback pointer
within that revision. Each successful deployment also has an immutable receipt
in its attempt directory. The base's `last-good.json` hashes that immutable
receipt. Old native files and previous revision directories are retained.
An advisory lock rejects concurrent use of the base. No global registry is
written.

Defaults are `--project-id ccr-vision`, `--environment vision-device-test`, and
`--device D7C456D4-F34F-5DA1-A078-EC69DB34098A`. The parent must use those same
project/environment values in its descriptor or pass explicit matching values.
`--budget-seconds` bounds the complete subprocess budget with a monotonic clock.
Timed out child process groups are killed and reaped. Commands use argument
arrays and child-only `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
The global Xcode selection and parent environment are not changed.

## Prepare

Prepare refuses dirty/untracked sources, detached HEAD, incorrect pins, wrong
remote identity, and an unpublished or moved remote ref. It builds the existing
`SillVision.xcodeproj` / `SillVision` Release target for generic visionOS in an
owned DerivedData directory. It does not regenerate the project, select a
device, launch Xcode UI, download dependencies, or request provisioning updates.
An incomplete owned build directory is held for review rather than silently
reused or removed.
`-resultBundlePath` writes native compiler diagnostics to the owned revision's
`Build.xcresult`, including SDK failures. The adapter does not print environment
values or keys and does not retry the failed build automatically.

The default developer build is full Git revision count +1000. Shallow history is
refused. `--build-number` can pin a configured integer >=22. The build setting
`CURRENT_PROJECT_VERSION` prevents the generator's default 14 from downgrading
legacy installed build 20. Deployment also refuses any numeric installed build
greater than the prepared build. Build equality never establishes source
identity.

The build sets bundle `dev.ambrion.SillVision`, team `ZPTXHJ866D`, and generated
Info.plist keys `BTSourceCommit` / `BTSourceTree` before signing. Prepare checks
the actual built plist, XROS platform, `codesign --verify --deep --strict`,
identifier, team, CDHash, application identifier and team entitlements, and all
bundle file hashes. Later actions verify the signed bundle again. Source/ref
checks run again after the build and action; a source or remote move is held.

## Device lease and native deployment

The only target is UDID `00008112-0001051A36C1A01E`, canonical CoreDevice
`D7C456D4-F34F-5DA1-A078-EC69DB34098A`. `--lease` is required before **any**
device operation, including queries and acceptance readback. The lease is
rechecked before every native command. `deviceId` must equal the actual
`--device` argument, using either configured identifier. Its schema is:

```json
{
  "schema": "ccr.vision.device-lease/v1",
  "ownerThread": "01a13005-ff61-7780-b0e8-6dc171de1c9d",
  "deviceId": "D7C456D4-F34F-5DA1-A078-EC69DB34098A",
  "expiresAt": "<future-ISO8601-time-with-timezone>",
  "permitted": {"install": true, "launch": true}
}
```

This example is not a lease grant. The actual owner supplies the live file.
Missing, expired, mismatched, or malformed leases return held with zero device
calls. Installation needs both install and launch permission before it starts.
Readback can run with both flags false for an already running, proven app.

The parent reported one permitted lock query at
`/Volumes/BT-Workspace/Development-Archives/CCR-Vision/release-convergence-20261020/target-lock.json`.
It returned `passcodeRequired=true`, `unlockedSinceBoot=true`. Deployment remains
held pending a new condition and owner lease; this worker performs no further
query or installation. The adapter requires explicit false `passcodeRequired`
and true `unlockedSinceBoot`. Unknown state or unavailable native operations hold
the attempt. There is no unlock bypass, wear prompt, polling, or retry loop.

Deployment queries exactly `apps --bundle-id dev.ambrion.SillVision`. Existing
nondeveloper installations are included with `--include-default-apps` so an
existing app cannot be mistaken for an empty target by that default filter.
Existing
app replacement is held with
`existing_app_replacement_held:verified_recovery_baseline_and_driver_required`.
A configured same-bundle/team signed recovery artifact, verified prior
source/native baseline, and reliable bounded recovery driver are not implemented
in this scope. In particular, legacy build 20 has no new runtime file and lacks
that verified recovery baseline. It is held before install, without attempting
to copy its missing runtime file. A same-version app must provide its runtime
file before the adapter makes an identity decision.
An absent file, transfer error, ambiguous app, or unknown version holds that
case. A different source at the same version is also held for the recovery
barrier. Matching source additionally requires matching signed bytes before
returning unchanged.

Only a confirmed empty target can receive a first installation through
`xcrun devicectl device install app`. Launch uses `device
process launch` without terminate-existing or app arguments, with an explicit
empty child environment dictionary. It never uninstalls, resets permissions,
changes pairing, or falls back to a local/simulator target. Native errors or
unknown JSON shapes fail closed. An install intent is saved as uncertain before
the install command. An uncertain attempt cannot automatically install again.
A later successful exact readback can settle it. Previous verified receipts
remain intact. No existing runtime is replaced; no rollback or restoration is
claimed. This restriction must remain until the parent implements and validates
the recovery artifact, baseline, and bounded rollback behavior. It prevents this
adapter from registering an unsafe existing-app replacement path.

The only copied app data is this exact file:

```text
device copy from --domain-type appDataContainer
  --domain-identifier dev.ambrion.SillVision
  --source Documents/CCRReleaseRuntime.json --destination <owned-file>
```

No general Documents directory, preferences, pairing keys, microphone content,
host state, or other app container is copied. The runtime schema is
`ccr.vision.runtime/v1`: commit, tree, bundleId, build, PID, process-stable
bootUUID, observedAt, and SHA-256 of the signed executable, built Info.plist,
and `_CodeSignature/CodeResources`. These hashes bind the installed app's signed
bytes to the locally verified signature. They are developer source evidence,
not hardware attestation.

The Swift writer captures the immutable bundle identity and hashes once per
process. App initialization and existing status callbacks attempt protected
atomic writes. Successful duplicate writes within the same observation second
are suppressed. Denied Documents I/O can retry on the next existing callback;
there is no timer or heartbeat. Files use mode 0600, complete protection, and
backup exclusion, reusing the existing protected writer.

A successful deployment requires a runtime observation no older than 120
seconds and no more than 5 seconds in the future. Its source, build, and signed
bytes must match; its PID must appear in native `runningProcesses` with the
executable path under the exact installed app URL. The runtimeId hashes the
configured physical UDID, source commit/tree, and process bootUUID. Both
`applied` and `unchanged` require this readback. A stale receipt or a mismatched
running process stays held. Launch/file-write races are not retried
automatically.

## Accept

`accept --acceptance-evidence ABSOLUTE_PATH` reads a real
`bt.test-acceptance/v1` JSON receipt. It checks project, exact source, runtimeId,
environment, `externalEffects: "zero"`, nonempty `dbIdentity`, `storageIdentity`,
`providerMode` in `isolation`, and `fixtureReset.status: "pass"`.

Every required check has `status: "pass"` and a nonempty `evidence` array of
`{"path": "/absolute/file", "sha256": "<actual-file-hash>"}` rows. Symlinks,
including ancestor symlinks, missing files, and changed hashes are refused.
The complete check set is:

- runtime-source-readback
- readiness
- representative-api
- representative-ui
- isolated-data-provider
- fixture-reset
- external-effects-zero
- native-input
- audio-privacy
- sentry

The runtime-source check must reference the exact hashed runtime file from the
deployment. Acceptance validates that saved receipt chain, then obtains a fresh
native source/process readback and requires the same runtimeId. A restarted app
needs a new deployment observation and matching acceptance evidence.
Missing physical evidence returns `missing-check:NAME`, `check-not-pass:NAME`,
or `missing-check-evidence:NAME`; it is never synthesized from unit tests,
build completion, a PID, an open port, or the older source-guard receipt.

Accepted output returns the original acceptance receipt path in `evidence`, as
the global tool requires. A separate validation receipt retains fresh native
evidence. The external physical driver remains responsible for generating
truthful UI/input/audio/sentry/isolation/fixture evidence. The adapter validates
its identity and file integrity; it cannot infer physical success from file
contents alone. `productionEnabled` remains false even for accepted fixtures.

## Verification and remaining gates

The bounded local check is:

```text
python3 -B Tests/checks/vision-release-adapter/test_adapter.py
```

The final worker run passed 33 tests in 3.710 seconds, exit 0, under an explicit
60-second subprocess timeout. An earlier expanded run exceeded its 120-second
budget and was terminated; it is retained as a failed attempt, not a pass. The
final suite replaces repeated local Git processes with deterministic boundary
fixtures and keeps the narrow real Git check described below.

Tests mock Git, network, routing, build, signature, and native tool boundaries.
One narrow test uses a tiny real local Git repository for HEAD/tree binding and
dirty refusal, with remote lookup stubbed. They exercise dirty/mismatched
source, moving refs, multi-revision output, monotonic builds, lease refusal
before calls, unknown lock state, recovery refusal, exact readback, idempotency,
uncertain install, signed-byte tampering, stale runtime, live-process identity,
and missing/false/changed acceptance evidence. Legacy replacement without
recovery is asserted to make zero install calls and preserve previous-good
receipts. Valid acceptance in this suite
is an explicitly isolated fixture, never a real device receipt.

The parent still owns independent review, SDK compilation and signing, actual
devicectl JSON compatibility, initial lease and device availability, installed
source readback, protected-file/cache behavior on visionOS, full native input,
audio privacy and sentry checks, complete isolated test environment, fixture
reset/external-effects evidence, official remote identity/publication and global
descriptor integration. No local build, actual device query/install/launch,
Mini/Cloud source copy, store operation, or push is part of this worker run.
The application must remain onboarding-required until actual deployment and
all acceptance checks are validated by the parent.
The existing installed build 20 additionally requires a verified recovery
baseline and supported rollback driver before any replacement can be enabled.

Pstack `poteto-mode` and `how` traced the global command contract through the
build, native container, and acceptance boundaries. `model-the-domain` produced
one immutable Source and explicit lease/runtime/receipt shapes. Ponytail full
keeps the adapter in one standard-library module and reuses the existing
protected atomic writer. ARENA, Orca, competing design loops, and nested agents
are excluded by the user's direct instruction. Review here is a direct scoped
review; the parent supplies the independent verdict.
