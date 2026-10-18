# Transport correction

Owner source-request-transport-20261019. Exclusive branch codex/source-request-transport-20261019, clean base 67faf6ac9cc762435c8b0438204088fbaa42f483. Original acceptance owner 01a13ace-e372-7ed1-9946-149df37ee1c3. Budget 30 minutes from 2026-10-19 01:55 KST. No SDK, installation or native acceptance in this unit.

The adapted transport.py resolves its repository from its own location. It extracts current product methods on every run. It does not execute the old review driver's fixed checkout or reuse saved Swift inputs. Inputs, hashes and Mini RAM receipts are archived under the routed source-request-transport-20261019 directory.

The disproven premise was that main-actor checks and peer-bound sends extend admission through independent queues. Actual SessionLink and StreamServer methods disprove it. The first runtime run compiled successfully and produced client 26/2, host 55/1, reconnect 4/1 and ingress 3/1. The original 23 client and 53 host assertions passed. The audio observation proves a hook invocation only.

The client owns explicit intent and automatic eligibility. SessionLink owns send admission. The host main actor owns selection CAS. The network queue owns media publication. A handover must create an unconsumed opportunity bound to its new peer and local intent, then obtain its first revision from that peer's catalog. It must not mutate an older ticket.

Two sequential design candidates were considered because nested agents are prohibited. A carries a cancellable publication admission into the queue and uses SessionLink's existing Submission. B moves the entire selection revision behind a shared lock and makes client queue entries carry revision predicates. A keeps domain CAS under its existing owner and reuses the transport's cancellation contract. B splits CAS ownership and adds another transport mechanism. A is selected. Publication and invalidation must share one lock through actual catalog send, so a later admission cannot return before obsolete publication finishes or is refused.

Throughput checkpoint: one writer, four independent Mini RAM schedules, then the original regression suites. No nested fan-out or repeated SDK build. pstack how traced the actual queue boundaries. Architect compared both shapes. Model the Domain requires a distinct unconsumed connection opportunity. Attack the Premise replaced assumptions about queue admission with executable counterexamples.

- [x] Reproduce it yourself on the matching surface via the driver skill.
- [x] Binary-search the cause.
- [x] Plan the fix.
- [ ] Verify on the same surface. blocked: Mini SSH exit255 before compilation; Tailscale reports offline.
- [x] Stage the commits so the failing repro lands before the fix in git history.
- [ ] Run Opening a PR. skip: this unit is local corrections for parent independent review; no publish authorized.

Architect phases Ground and Sketch complete. Agree has no user checkpoint. Implement and final verification remain. Scrap only if the selected shape cannot preserve the contract. Independent CLEAR remains the parent's gate.

The root correction is a candidate pending runtime validation. How traced SessionLink.cancel/endedLocked, actual commitVideo, private send and HEVCEncoder.requestKeyframe. The publication body has no synchronous hop to the main actor. Model the Domain kept new-peer opportunity separate from revision-bearing ticket. Attack the Premise produced the first committed runtime reds. Architect retained main-actor CAS ownership and carried cancellation to the queue. Prove It Works prevents claiming success from Python syntax or the pre-fix baseline. Deslop and the scoped comments pass were sequential; no nested independent reviewer ran. The obsolete cancellation comment was removed, the public selectionRevision comment was corrected, and no new correctness suppression was added. The lock class uses unchecked Sendable because both private shared fields are protected by its NSLock.

Remaining source boundary: generic catalog/media publications outside commitVideo are not newly fenced by this patch. Runtime tests of revised Swift and the original 23/53/164/39/39 suites, actual NWConnection lifecycle, active-source side effects, full launch completion, controller-integrated effects and native acceptance are pending. No parent independent CLEAR is claimed. The budget is a limit, not acceptance evidence.
