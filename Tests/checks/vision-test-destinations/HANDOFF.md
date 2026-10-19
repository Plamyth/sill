# Vision project test destinations — source return

Original owner: `01a13005-ff61-7780-b0e8-6dc171de1c9d`.
Base: `0d6749c6ef9c5645162a04dab683bace722089c7`.
Branch: `codex/vision-test-destinations-20261020`.
Shared Entry first commit: `908bcf890037547b05100f79ac1ac5a892a32040`.

## Source freeze

- Optional `WindowList.testDestinations` carries the raw validated projection. Bad optional values
  decode to unavailable catalog without rejecting the window list. Existing init calls remain valid.
- The existing authenticated TLS peer helper supplies identity; a connection generation binds the
  catalog. Disconnect, handover, authentication revocation, malformed list and unavailable/invalid
  projection clear selection and rotate the device login store scope.
- Native opening and navigation revalidate the exact catalog entry, project ID/label, HTTPS origin,
  registered redirect origins and injected clock. `checkedAt` must be neither future nor older than
  45 seconds. iframe headers remain informational. HTTP stays compatible in the shared legacy
  schema but cannot open in this native viewer.
- Korean workspace entry and sheet use per-project nonpersistent WebKit stores. Closing/reopening
  within the same paired scope reuses device login; different projects and peer generations use
  different stores. No host cookies, credentials or tokens are imported.
- Explicit protocol compiler lists now include the new shared source and its current dependency
  closure. The Vision project membership and generator include the new adapter.

The producer currently has **zero live entries**, as reported by the owner. `catalog.json` is an
offline reserved-domain test fixture, not a proposed live destination. This work does not implement
the parent-owned Host canonical reader. Its reported 2,471,968-byte snapshot and planned 16 MiB
reader bound are not changed here. No voice contract, endpoint or stub was added.

## Verification for parent after return

No build, test, generator, runtime, network, browser, audio/HAL, Mini or device command was run by
this writer. Source review and Git commits are the only completion evidence here.

On the parent's approved execution host and new RAM output path, run:

```sh
python3 -B Tests/checks/vision-test-destinations/run.py SOURCE_ROOT NEW_PARENT_RAM_OUTPUT
```

The runner compiles actual shared contract, model and adapter sources. It extracts production
storage, view delegate and store bodies verbatim and uses inert Network/WebKit shapes. Assertions
cover wire compatibility, malformed optional carriers preserving stream fields, exact project and
origin/time validation, 45-second boundary, future time, peer/disconnect/authentication invalidation,
unregistered redirects, HTTP/display/failure states and isolated project login store lifetime.
It records source hashes, commands, results and source immutability in `result.json`. It does not
prove platform API compatibility, real TLS authentication or real WebKit/device behavior.

The parent must compile the complete native target against the installed **XROS 27.0 SDK**, run
the affected regression fixtures with the exact returned source, and independently review the diff.
Real device login persistence, rendering, focus and line wrapping remain device acceptance work.
The writer does not claim these gates passed.

## Workflow

Pstack Feature: reused the existing contract/model/view, peer trust helper, current window lease,
input admission and project generator patterns; implementation followed by direct source review.
Ponytail: standard URL/Foundation/WebKit APIs, existing optional projection boundary and an injected
clock; no extra protocol scope fields or dependencies. User restrictions replace nested-agent and
execution stages with the parent's exact-source review/compile/test gates. ARENA and Orca were not
used. This is the final source checkpoint, not runtime acceptance.
