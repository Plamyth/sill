# Pointer button disconnect check

Run `python3 Tests/checks/pointer-buttons/run.py` from the repository root.
The runner compiles the unchanged injector and its dependencies against the actual StreamProtocol module.
Every injector uses `dryRun = true`. The check captures the existing synthetic event log.
It starts no host, opens no connection, and posts no input.

The coordinator queue methods and source-switch drop loop are extracted verbatim into a test class.
Only app activation logging is stubbed. The runner checks that the disconnect callback calls this cleanup
and that both paths without a source pass the device to the release check.
This tests queue ordering without starting capture, pairing, networking, or app activation.
The complete coordinator is type-checked separately. A real network disconnect is outside this check.

`python3 Tests/checks/pointer-buttons/run.py --baseline` compiles the two original host files from
v0.5.1 at `d669a813454603f76074491724ecb4339ad2185c`. The same expectations must fail there.
The runner checks input file hashes after each run. Build products stay in `.build/checks/pointer-buttons`.

The task uses pstack poteto-mode, how, and architect guidance with sequential design exploration.
Subagent tools are unavailable in this session. The Model the Domain principle replaces a global down
flag with an optional owner per button. A set of owners per button would require a new policy for merging
multiple clients' presses. The selected model accepts the first down and ignores other downs until its up.
Moves keep the existing global drag and coordinate behavior. Disconnect cleanup follows buffered input.

The work key is `host-release-on-loss`. The assigned branch is `codex/host-release-on-loss` at the base above.
Only InputInjector.swift, StreamCoordinator.swift, and this check change.
The throughput checkpoint batches source changes and one focused compile/run before targeted regression checks.
There is one writer. No publication or deployment step is authorized.

The bug-fix checklist records this bounded sidecar.

- [x] Reproduce it yourself on the matching surface via the driver skill. The original injector fails 23 of 35 synthetic checks, including both missing disconnect ups.
- [x] Binary-search the cause. The disconnect callback releases keys only; buttons have no client owner.
- [x] Plan the fix. Compare per-button ownership with a set of pressing clients, then implement the narrow model.
- [x] Verify on the same surface. The patched injector and buffered-input methods pass all 37 synthetic checks.
- [x] Stage the commits so the failing repro lands before the fix in git history. Skip separate commits for this bounded sidecar; retain the executable baseline reproduction.
- [x] Run Opening a PR. Skip because the user forbids pushing and requests a local commit only.

Architect phases Ground and Sketch are complete. Agree uses the user's assigned scope.
Implement passes the requested synthetic cases. Scrap was unnecessary.
Independent review is blocked because this session exposes no subagent tool. No independent verdict is claimed.

Verification on 2026-10-16 used the assigned worktree and Swift 6.4 for arm64 macOS.

- `python3 Tests/checks/pointer-buttons/run.py --baseline` reproduced 23 failures among 35 checks.
- `python3 Tests/checks/pointer-buttons/run.py` passed all 37 checks, including held left and right drags,
  two-client ownership, repeated disconnects, late ups, host exit, activation buffering with source loss,
  and same-button handoff when the first client disconnects before the second client presses.
- `bash Tests/checks/key-strokes/run.sh` passed 329 checks. Its random event counts describe a model.
- `bash Tests/checks/pointer-control/run.sh` passed 156 checks.
- `swiftc -typecheck -module-name SillHostCore -package-name sill -module-cache-path .build/checks/pointer-buttons/module-cache -I .build/checks/pointer-buttons Sources/SillHost/*.swift` passed without diagnostics.
- `git diff --check` passed.

No installed application, host lifecycle, pairing state, or remote branch was changed.

The 37-check result includes a follow-up fix. An independent review found that a separate
`leftWhileHeld` cleanup list delayed the first client's release past the second client's input.
The coordinator now records disconnect as a typed item in the held input queue. It releases
the first client's buttons at the disconnect's position in the queue. The same ordering applies
when a source switch discards held pointer downs.
