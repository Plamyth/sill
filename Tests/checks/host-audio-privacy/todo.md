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
