# Ink visibility unit

Owner iPad01a13ace-e372-7ed1-9946-149df37ee1c3. Task ipad-ink-visibility-20261019. Base 2ebd263cf06843b92893ca3b1344ef271dc0a2d8. Budget 25 minutes from 2026-10-18T20:13:39Z.

- [ ] 1. Reproduce it yourself on the matching surface via the driver skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
- [ ] 2. Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Claude Code's `loop` skill. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
- [ ] 3. Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default in poteto-mode's Models section) with a specific scope.
- [ ] 4. Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
- [ ] 5. Stage the commits so the failing repro lands before the fix in git history. See the **tdd** skill for the failing-test-first cadence when the bug has a cheap local test path. Skip it when the test would be expensive, integration-heavy, or unclear.
- [ ] 6. Run **Opening a PR**.

User override. No nested agents. Named sequential architecture passes replace design fan-out. Parent performs subsequent independent review. No PR, Pages, device, host UI, relay or full-app builds.

Architect phases

- [x] Ground
- [ ] Sketch
- [ ] Agree
- [ ] Implement
- [ ] Scrap

Throughput checkpoint. One writer in dedicated exact-base worktree. Production edits only CanvasModel, CanvasStore, CanvasWorkspace, SceneRenderer. Actual SDK Model/Store executable only on this MacBook. Preserve native renderer; no source transfer claims.

Grounding. PencilCanvas supplies authoritative PKDrawing to Store.updateDrawing. Store serializes raw bytes and projects transformed full control points to InkStroke. Agent packets encode CanvasScene under the existing 1 MiB ceiling. Native PNG uses raw PKDrawing. Only structure-only PNG and SwiftUI currently draw InkStroke.points. Those consumers must share visible runs.

Sequential design A, Parametric ranges. Optional SDK parameter ranges on InkStroke avoid coordinate growth. Counterexample: a consumer without PencilKit cannot reconstruct a fractional spline endpoint from integer control points, and connecting retained points crosses an erased gap. Rejected for agent usability.

Sequential design B, Explicit visibility. InkStroke.visibility optional. nil means unverified legacy. Known full reuses points without coordinate duplication. Masked carries SDK range bounds plus worldPoints including fractional endpoints and integer interior control points. Full provenance points remain unchanged. A shared model accessor supplies separate fallback polylines; nil produces no verified visible points. Counterexample: two islands cannot be one polyline; an empty mask cannot fall back to full points. No pixel or glyph equivalence claim. Pending actual SDK range diagnostics before synthesis.

Independent review. BLOCKED: independent review. Parent owns follow-up at final exact HEAD. Self diff review and SDK checks are not an independent verdict.
