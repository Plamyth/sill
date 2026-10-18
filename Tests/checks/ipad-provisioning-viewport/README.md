# Native allocation with the original handover lifecycle

`Viewport.width`, `height` and `scale` describe measured panel geometry and Aa sizing. A replay can use the original saved panel snapshot. Optional `extendedDesktop` holds finite native Mac-point dimensions, with width 320...2048 and height 240...2048. Invalid present dimensions reject wire decode. Absent or null dimensions preserve legacy decode and panel allocation. The original host ignores the field and allocates from the actual panel dimensions.

The product change from `7ade74d` is limited to the optional field, the host allocation adapter, `StreamScreen` initial-surface measurement, and retention of native intent in `lastViewport`. `StreamClient.swift` and `StreamCoordinator.swift` are byte-identical to `7ade74d`. There is no capability negotiation or quality-policy change.

The original move home copies `lastViewport` and changes only FPS. At ready, it sends this ordinary home frame directly after hello and before probing. The frame carries actual panel dimensions and Aa, plus optional native allocation. Final replay uses the original snapshot through `SessionLink`. Rescue and cable keep their original hold, adopt and fence behavior. Session teardown clears native intent with `lastViewport`.

The mixed-version regression runs the original host registration, one-second timeout, viewport dispatch, quality policy and restart effects extracted from source. The rejected `745718c` client delays its first home viewport behind a fence. With the original host and a 120 fps limit, this yields pipelines at 60 and then 120 fps. The restored client sends its ordinary home frame before the fence and commits quality and rate in one restart. Checks cover limits of 60 and 120 fps, with native intent present and absent. Capture, audio, network and display adapters are fixtures.

Baseline observations are distinct from native allocation assertions. The original home snapshot can replay height 890 after the measured panel changes to 540. Held panel messages can also retain their earlier route FPS. These are preexisting lifecycle behaviors. The feature preserves them and does not promise the latest panel geometry during a handover. Native allocation must remain 1350x976 across those messages. Without the field, replacement allocation follows the original first ordinary panel. Initial, rescue, home, cable, Wi-Fi and direct replacement paths are checked with both forms.

Run from this worktree:

```sh
python3 -B Tests/checks/ipad-provisioning-viewport/run.py
python3 -B Tests/checks/ipad-provisioning-viewport/run.py --baseline
python3 -B Tests/checks/ipad-provisioning-viewport/run.py --host-policy
python3 -B Tests/checks/ipad-provisioning-viewport/run.py --client-ref 745718c --host-ref 7ade74d --quality-only
```

The last command must fail with pipelines `[60, 120]`. It substitutes only the named client lifecycle and host coordinator. The schema, screen measurement and allocation adapter remain current. The other commands must pass. Decoder and allocation checks also compile the actual `7ade74d` viewport type and dimensions adapter. Staged geometry uses actual panel 1350x890 at Aa 1.5, producing 900x593 even when native allocation is 1350x976.

The protected untracked `extended-viewport-safety` checks remain byte-identical. Their observations about first-viewport caching, topology invalidation and callbacks are baseline evidence, not newly fixed behavior.

The runner streams hashed inputs through `mini heavy` into an owned RAM volume, then verifies sender and receiver hashes, source immutability, child termination, RAM removal and existing container state. These are independent pure extracted-source checks. They do not satisfy the Git-checkout source-guard transfer gate or prove an SDK product build, real display, installed UI, host restart, pairing or device behavior. Parent owns independent review and integration. This correction does not publish a branch or create a PR or Page.
