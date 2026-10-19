# Bounded review fixes

Base 93fc02baa59861a4e1a0fe0420ad9fee66ebb211. Parent owns SDK, REA, relay and device observation.

- [x] `how` over the affected subsystem.
- [x] `architect` for parallel design exploration. skip: user forbids ARENA and spawned agents; reuse shared validation and native Menu directly.
- [x] Write the throughput checkpoint as four todo items.
- [x] Delegate code-writing to a subagent. This bounded sidecar owns the diff directly; parent retains independent review.
- [x] Verify on the matching surface. "Inconclusive" or wrong-surface is not a pass. Flag it. Narrow Swift policy, producer states, layout bounds and cancellation checks passed with unchanged input hashes. Screen Swift syntax parse passed. Final SDK and UI observation remain with parent.
- [x] Rebase into small, ordered commits. Stack follow-ups. One owned fix commit on the supplied shared branch; no rebase of parent history.
- [x] If the design is contested, `interrogate` before shipping. n/a: two accepted P2 corrections; no shipping.
- [x] Run **Opening a PR**. skip: bounded local commit only; parent owns integration and publication.

- Blocking first steps. PID 74537 absent before mutations. Parent SDK log for base ends BUILD SUCCEEDED; that is not the fixed-source SDK result.
- Independent workstreams. No fan-out; parent retains device, relay, REA and final SDK.
- Shared mutable state. Only shared TestDestinations.swift, toolbar portions of the two screens and this check directory. Existing untracked parent todo remains untouched.
- Smallest safe decomposition. One writer; reuse validatedURL for primary and redirect restrictions and native Menu for compact overflow.

BLOCKED: independent review of the fixed commit remains with parent. No merge, SDK or device acceptance is claimed by this sidecar.

The producer-state checks include the parent's dirty Policy as an input only. Tested Policy SHA-256 is 1cb9d42b5b2b0ffa59efd2051642205d1624c86422a43daf8ce138798cbd31b0. Parent must commit that dependency separately. Valid legacy omission and ready preserve empty and nonempty catalogs; unavailable raises catalogUnavailable; malformed, unknown, numeric, boolean, null, array and object states raise malformed.

Receipt and logs are in /Volumes/BT-Workspace/Development-Archives/BT_CCR-Sill-Obsidian/ipad-test-destinations-sidecar-20261020/checks.json and check-final.log. The 400 pt portrait keeps 272 pt of controls within 372 pt; 500 pt compact landscape keeps 380 pt within 472 pt. These are pure production layout calculations, not rendered UI measurements.
