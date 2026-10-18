# HOST worker checklist

- [x] Ground. Read affected owner, coordinator, protocol and app boundaries using pstack how.
- [x] Sketch. Compare shared guard with distributed checks using architect.
- [x] Agree. Existing design.md and parent wire contract govern the selected shape.
- [x] Implement. Use PrivacyAudioSnapshot and a single latch owner per model-the-domain.
- [x] Scrap. No repeated structural deviations required a replacement design.
- [x] Blocking first steps. Exact base, clean exclusive worktree, policy and design confirmed before writes.
- [x] Independent workstreams. n/a: parent forbids children and owns other branches and clients.
- [x] Shared mutable state. Main actor guard and owner, no writes outside this exclusive worktree.
- [x] Smallest safe decomposition. One guard plus pure snapshot model and injected HAL adapter.
- [x] Source inspection and diff verification per prove-it-works.
- [ ] Compile and run injected package. skip: parent explicitly owns all execution after handback.
- [ ] Actual HAL/device acceptance. skip: parent explicitly prohibits worker hardware/runtime access.
- [ ] Independent review. BLOCKED: independent review belongs to parent; no children permitted.
- [ ] Commit/rebase/PR/deploy. skip: parent requested no commit until review.

## Endpoint coverage unit at base 47617430f7c70c40525072532eea3880128159c4

- [x] Ground. Trace plan, native read/write, observation, admission, and existing RED tests with pstack how.
- [x] Sketch. Compare existing optional master mute fields with a separate channel coverage model using architect.
- [x] Agree. Follow the parent's master-only coverage contract and version 2 steering.
- [x] Implement. Reuse the domain snapshot, error enum, native master controls, and observation generations.
- [x] Scrap. No structural deviation needs a replacement design.
- [x] Throughput checkpoint. One worker changes the exclusive branch. Parent owns all execution and independent review.
- [x] Deslop. Inspect the scoped diff, retain existing types, add no dependencies or new source files.
- [x] Comments. No new implementation comments or suppressions. Updated public wire contract matches version 2.
- [ ] No-comments independent agent. skip: spawn_agent is unavailable; parent owns independent review.
- [ ] Compile and execute tests. skip: explicitly prohibited in this CODE unit; parent owns exact Mini suite and full SDK.
- [ ] Physical and OS acoustic proof. OPEN. No hardware, HAL, device, or network execution is authorized here.
- [x] Local commit preparation. Scoped files and diff inspected. Parent authorizes the local commit. No push or release.
