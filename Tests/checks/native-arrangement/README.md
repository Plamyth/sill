# Native display arrangement checks

Owner task `ipad-native-arrangement-20261018` remains on branch
`codex/ipad-native-arrangement-20261018`, based on
`5c4c4d4b791e21d7a9a1b594d9ca2b876f088c90`.
The parent owns independent review, native UI, device validation, integration and installation.

The parent's native repro moved only the CCR display from the far right to the left
of the internal display. The host retired it at 23:12:45.063, followed by SCK error
3815. The actual `valid()` algorithm reproduced four failures out of ten checks
under controlled CG responses in Mini RAM. The failing tests were committed first
as `9791241afc663254ff68fea0ae204c6171bcbf5c`.

## Design and scope

The pstack 0.9.93 bug-fix playbook, `how`, `architect` and
`principle-model-the-domain` guided this change. Subagent tools are unavailable in
this worker, so two designs were compared sequentially. This is reduced design
diversity and does not count as independent review.

The selected design lets macOS own arrangement persistence. `configure()` returns
without a configuration transaction when the restored display already passes its
mode, active, mirror and physical overlap checks. An invalid initial arrangement
still uses the existing rightmost fallback. The alternative was a separate saved
origin keyed by display identity, with an explicit restore transaction. That
duplicates macOS state and can restore stale coordinates after physical topology
changes. No additional origin storage was introduced.

`ExtendedDesktop` validates placement in every direction. Each successful check
refreshes its owned cleanup bounds. Cleanup also samples the currently valid
display to handle a move followed by disconnect before the next callback, and
falls back to the last validated bounds after actual display loss.

The `how` pass found a second necessary path. `WindowCatalog` invalidates the
inventory for topology events, and its old signatures combine UUID and frame.
That would clear the active selection even after the placement rejection was
fixed. `DisplayInventory` now stores identity signatures separately from frames.
Only the selected, owned CCR ID can be suspended across a refresh. It is restored
with a new revision only when the complete display metadata and nonempty UUIDs
still match. Removed displays, reused IDs, mode changes, main changes and physical
display selections retain the existing explicit selection protection. This is the
Model the Domain decision: pending selection is a stored ID, distinct from a
validated current selection and from a required new selection.

`StreamCoordinator` blocks the old input epoch and pointer geometry immediately.
It keeps an owned selection pending until refresh completes, then restarts the
desktop through the existing pipeline, which obtains current global bounds,
prepares a new epoch and resets pointer geometry when the active source commits.
This requires bounded edits to `DisplayInventory.swift`, `WindowCatalog.swift`
and `StreamCoordinator.swift` in addition to `ExtendedDesktop.swift`.

## Run

Obtain a fresh archive path with `storage-route path development-archive --project
BT_CCR-Sill-Obsidian --filename NAME`, then pass the returned JSON `path` to:

```sh
python3 Tests/checks/native-arrangement/run.py --output ABSOLUTE_ROUTED_PATH
python3 Tests/checks/native-arrangement/run.py --suite monitor-selection --output ANOTHER_ROUTED_PATH
```

The first suite extracts actual `valid`, `configure`, `recoveryBounds`,
`originRight` and coordinator `displaysChanged` methods. Only CG boundary symbols
are remapped. `DisplayInventory` and the wire display types are actual source.
The coordinator's dependencies and `select` are controlled fixtures; this proves
the restart decision, not a real SCK pipeline or native pointer movement.
The second suite runs the inventory, input fence and wire portion of the existing
monitor-selection checks against actual source. The unrelated trailing audio
fixture uses an older callback arity and is excluded, rather than changing its
owner's test. No audio controller, device or live audio route is used.

Sources, executable and compiler cache use the existing runner's owned RAM volume
on Mini. Receipts include transport and input hashes, source hashes before and
after execution, process cleanup and RAM unmount. They are independent pure checks,
not `codex-source-guard` transfer acceptance or a host application build.

The final native suite reports `ARRANGEMENT_CHECKS total=39 failed=0` and the
existing inventory, input fence and wire suite reports
`MONITOR_SELECTION_CHECKS total=39`. Their receipts are under
`/Volumes/BT-Workspace/Development-Archives/BT_CCR-Sill-Obsidian/` in
`native-arrangement-final-native-20261018` and
`native-arrangement-final-monitor-20261018`. Both preserve sender source hashes,
match the transport/input hashes and confirm RAM cleanup.

## Remaining parent gates

Independent review must cover all four product files and the test diff before
integration onto the parent's current source. The pure suite does not establish
native callback ordering, CGVirtualDisplay UUID availability, SCK restart success,
HiDPI output on device, window recovery through AX, Pencil mapping or reconnect
persistence across a real host lifecycle. In particular, the existing lifecycle
still calls `checkDisplay()` during topology callbacks; native begin/end callbacks
must confirm that transient CG state does not trigger the genuine loss path.

No UI, device, application build, installation, restart, privilege, pairing,
canonical source, CanvasStore or other chat action belongs to this worker.


## Recovery fix round from c7770dc

Task `native-arrangement-recovery-20261018` uses an exclusive worktree and branch
`codex/native-arrangement-recovery-20261018`. Product changes are limited to
`StreamCoordinator.swift`. `DisplayInventory` and `SourceInputFence` are unchanged.

Red commit `0c4c10b` runs the production `select` entry guards, stop/audio-revoke
prefix and complete defer, production `handlePick` and `displaysChanged`, and the
production post-capture desktop-selection/geometry validation. Inventory and
legacy input fences are actual source. Encoder/filter creation, capture start,
commit publication and failure reporting are controlled boundaries. A continuation
holds capture startup while real inventory revisions and user requests change.
This is an extracted control-flow test, not a full coordinator or native SDK build.
The red run compiled successfully and reported `RECOVERY_CHECKS total=11 failed=2`.
The failures were live capture/audio after a legacy scope refusal, and no restart
after a retained geometry refresh during suspended capture startup.

The how pass traced invalidation to a new inventory revision, then to the legacy
pin refusal before capture stop. It also traced selection rejection after the
capture await to `.none`, after the topology callback had dropped recovery.
The architect comparison rejected reuse of the source-only pick slot because it
cannot carry the inventory revision and conflates recovery with later user intent.
Model the Domain produced `OwnedDesktopRecovery`: idle, pending a validated
`DisplaySelection`, or restarting. The switching tail drains pending recovery.
A restart refused before cleanup explicitly selects `.none`, using the existing
stop and audio-revoke path. No input-fence rule is relaxed.

The restarting state also identifies restoration from `.none` as a desktop restart.
User window/none picks cancel recovery and use the existing latest-pick queue,
including picks received during restoration itself. Another geometry revision
while restoring queues its new token. Last-client departure and actual inventory
loss cancel restoration. The focused suite covers these boundaries.

Run the recovery suite with a fresh routed archive path:

```sh
python3 Tests/checks/native-arrangement/run.py --suite recovery --output ABSOLUTE_ROUTED_PATH
```

The original native suite retains its select stub and covers adapter/lifecycle
and restart decisions only. The recovery suite supplies the production guards
and controlled delayed pipeline that the original fixture lacked. This round
performs no full SDK build, native UI/device test, install, restart, real audio
operation, source transfer acceptance, independent agent review, push or PR.
The parent retains those review/integration and physical validation gates.

The final recovery suite reports `RECOVERY_CHECKS total=18 failed=0`, including
later user picks during the original restart and during restoration from `.none`.
The native regression reports `ARRANGEMENT_CHECKS total=39 failed=0`.
Receipts are in the routed Development-Archives folders named
`native-arrangement-recovery-final-20261018`,
`native-arrangement-recovery-native-20261018` and
`native-arrangement-recovery-monitor-20261018`.

## Recovery premise round 2

Task `recovery-premise-round2-20261018` starts at
`a5a958b5e0dff487855d68522b4fe49ac3cd1b60` in the exclusive branch
`codex/recovery-premise-round2-20261018`. The parent owns independent Feynman
review, full SDK validation, native UI, integration and release. This worker uses
pstack 0.9.93 poteto-mode, its Bug fix playbook, Attack the Premise, How,
Architect and Model the Domain. The user prohibits nested agents, so grounding
and the two design sketches are sequential and are not independent review.

The tested premise is that owned recovery intent can be inferred from
active/current after asynchronous topology and cleanup, and queued user picks
need retention only while restartOf is nonnil. Red commit `d62533a` precedes all
product edits. Its compiled run reports `RECOVERY_CHECKS total=23 failed=2`.
The two failing terminal assertions are:

- `invalidation then startup return then refill preserves owned recovery intent`
- `failed refresh queued window pick survives suspended audio shutdown`

The first trace invalidates inventory, holds capture startup at a continuation,
lets startup return and reject its stale revision, then completes inventory
refill. Invalidation removed current before the callback recorded intent. After
startup sets active to none, the refill callback no longer recognizes its owner.
The second trace holds refresh, queues a scoped window pick, returns refresh
failure, suspends cleanup, and observes the previous select defer delivering its
queued task during that suspension. Cleanup has nil restartOf, so the old rule
drops the pick. These traces directly contradict both parts of the premise.

The Architect comparison considered a unified serial transition queue against
durable intent plus wider pick admission. A unified queue requires migrating the
other select callers and still needs durable intent because inventory callbacks
change state independently. The smaller design extends OwnedDesktopRecovery
with awaitingInventory. That state survives active becoming none until refill,
explicit user intent, actual display loss, or departure cancels recovery.
No DisplayInventory or store edit is needed.

A failed intermediate experiment retained restarting through cleanup. Its
23-check run still failed the queued-pick assertion because the explicit pick
correctly cancels recovery during refresh. That lifecycle change was removed.
The final rule removes the restartOf admission condition for window and none
picks across transitions, including owned cleanup. The production selectSource
handler documents that clients only emit automatic Desktop requests. Desktop
requests retain the existing restart-only queue rule. This adds no boolean and
preserves the existing authentication and SourceInputFence behavior.

The fixture extracts production select guards, the entire audio/capture stop
prefix and defer, handlePick, displaysChanged, recoverOwnedDesktop, and the
post-capture desktop selection/geometry validation. Inventory, wire types and
SourceInputFence are actual source. The unchanged handler has a wrapper that
observes task delivery without changing its logic. Continuations control capture
startup, refresh, audio shutdown, capture shutdown and queued-pick observation.
Terminal assertions use the existing bounded actor-yield drain. Encoder/filter
creation, platform capture, source selection tail and epoch publication are
controlled boundaries. The auth ingress, full SDK and native callback machinery
are outside this fixture.

Final results are `RECOVERY_CHECKS total=104 failed=0`,
`ARRANGEMENT_CHECKS total=39 failed=0` and `MONITOR_SELECTION_CHECKS total=39`.
Recovery covers both failure orders, failed refresh with audio/capture shutdown,
scoped and legacy peers, explicit none, disconnect, no pick, latest human pick,
actual display loss and ordinary-switch automatic Desktop suppression. Sender
and receiver hashes match, input source is unchanged, children are reaped and
all owned RAM volumes are removed. These are independent pure checks in Mini
RAM, not codex-source-guard transfer acceptance or native SDK/application proof.

Receipts under `/Volumes/BT-Workspace/Development-Archives/BT_CCR-Sill-Obsidian/`
are `recovery-round2-red-20261018`, `recovery-round2-green-20261018` for the
rejected intermediate experiment, `recovery-round2-matrix-20261018` for the
84-check matrix, and final `recovery-round2-final-20261018`,
`recovery-round2-native-20261018`, `recovery-round2-monitor-20261018`.
The final product and harness hashes are verified against these receipts before
commit. The commit itself does not claim a new SDK or native run.

The original a5 worktree and canonical checkout were never written by this
worker. Mac 137, Sill 14, Family 2 ink transform, CanvasStore, installed apps,
devices, live audio and other chats are outside this worker's effects. No push,
PR, merge, SDK build, native UI, installation or independent review is performed.
The parent must test this exact source in its SDK/native paths and conduct the
next independent review before integration or release.
