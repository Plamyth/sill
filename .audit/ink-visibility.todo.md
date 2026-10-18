# Ink visibility unit

Owner iPad01a13ace-e372-7ed1-9946-149df37ee1c3. Task ipad-ink-visibility-20261019. Base 2ebd263cf06843b92893ca3b1344ef271dc0a2d8. Budget 25 minutes from 2026-10-18T20:13:39Z.

- [x] 1. Reproduce it yourself on the matching surface via the driver skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
- [x] 2. Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Claude Code's `loop` skill. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
- [x] 3. Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default in poteto-mode's Models section) with a specific scope.
- [x] 4. Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
- [x] 5. Stage the commits so the failing repro lands before the fix in git history. See the **tdd** skill for the failing-test-first cadence when the bug has a cheap local test path. Skip it when the test would be expensive, integration-heavy, or unclear.
- [x] 6. Run **Opening a PR**.
  skip: user requested an isolated local clean commit; no publication in this unit.

User override. No nested agents. Named sequential architecture passes replace design fan-out. Parent performs subsequent independent review. No PR, Pages, device, host UI, relay or full-app builds.

Architect phases

- [x] Ground
- [x] Sketch
- [x] Agree
- [x] Implement
- [x] Scrap

Throughput checkpoint. One writer in dedicated exact-base worktree. Production edits only CanvasModel, CanvasStore, CanvasWorkspace, SceneRenderer. Actual SDK Model/Store executable only on this MacBook. Preserve native renderer; no source transfer claims.

Grounding. PencilCanvas supplies authoritative PKDrawing to Store.updateDrawing. Store serializes raw bytes and projects transformed full control points to InkStroke. Agent packets encode CanvasScene under the existing 1 MiB ceiling. Native PNG uses raw PKDrawing. Only structure-only PNG and SwiftUI currently draw InkStroke.points. Those consumers must share visible runs.

Sequential design A, Parametric ranges. Optional SDK parameter ranges on InkStroke avoid coordinate growth. Counterexample: a consumer without PencilKit cannot reconstruct a fractional spline endpoint from integer control points, and connecting retained points crosses an erased gap. Rejected for agent usability.

Sequential design B, Explicit visibility. InkStroke.visibility optional. nil means unverified legacy. Known full reuses points without coordinate duplication. Masked carries SDK range bounds plus worldPoints including fractional endpoints and integer interior control points. Full provenance points remain unchanged. A shared model accessor supplies separate fallback polylines; nil produces no verified visible points. Counterexample: two islands cannot be one polyline; an empty mask cannot fall back to full points. No pixel or glyph equivalence claim. Selected after actual native masks proved visible interval semantics. Native ranges are copied exactly; no inferred mask geometry is substituted.

Independent review. BLOCKED: independent review. Parent owns follow-up at final exact HEAD. Self diff review and SDK checks are not an independent verdict.

Synthesis and contract

The caller reads `stroke.visiblePointSegments` for structure-only geometry. Both fallback consumers start a new path at every run. JSON consumers read `visibility` before interpreting `points`. `points` is full transformed control-point provenance and can include erased locations. `visibility == nil` is unverified legacy, never known full. Such strokes decode under schema 1 but structure-only fallback omits them. Raw-backed scenes continue using PKDrawing.

`visibility` is `{ "kind": "full", "visibleSegments": [] }` when SDK centerline ranges cover the full path or the SDK mask is nil. It reuses `points`. A masked stroke uses `{ "kind": "masked", "visibleSegments": [{ "lowerBound": ..., "upperBound": ..., "worldPoints": [{ "x": ..., "y": ..., "pressure": ... }] }] }`. Masked empty has an empty segment array. Bounds are exact Double conversions of SDK CGFloat values. Each run uses SDK-interpolated lower and upper points and strictly interior original control points, transformed once. Fractional bounds are never rounded. All original full points, stroke ID, creation time, force, original in-memory drawing and serialized raw bytes remain.

`full` describes centerline range coverage, not the entire glyph or filled stroke boundary. Structured paths approximate the centerline using endpoints and interior control points. Native/raw PNG is the final visual authority. A narrow native mask can trim edges while centerline coverage remains full. No pixel parity, glyph segmentation, text deletion or MyScript parity is claimed.

Ponytail full selected existing InkStroke, native SDK range/interpolation and standard Codable. One nested visibility value and one model accessor serve both fallback consumers. No dependency, framework wrapper, global setting, relay change or uniform stroke resampling was added. Model the Domain separated unknown, full and masked-empty. Test Behavior, Not Implementation drove the real CanvasStore with native masks and checked its scene JSON, raw drawing and isolated saved file.

SDK evidence and correction of test assumptions

macOS27 PencilKit exposes `mask: NSBezierPath?`, `maskedPathRanges: [ClosedRange<CGFloat>]` and `path.interpolatedPoint(at:)`. iPhoneOS SDK has the matching range/interpolation APIs. `nil` and a covering mask return `0...4`. A nonempty mask outside the path returns no ranges. Two world-space rectangles return `0.4000000059604645...1.399999976158142` and `2.5999999046325684...3.5999999046325684`, whose endpoint x coordinates are 10, 35, 65 and 90. The SDK normalizes an empty NSBezierPath to nil, so it must not be used as an erased-stroke fixture. The empty-visibility fixture uses a nonempty distant rectangle instead.

Initial transformed fixtures incorrectly kept masks in local coordinates. Runtime evidence showed masks are in world coordinates. Transforming the mask together with the stroke produces the same native intervals across translation, rotation, scale and combined affine transforms. Raw SDK readback quantizes some affine components; the test checks exact original in-memory transform and raw bytes, then SDK readback at numeric serialization precision. Product serialization was not changed to hide this behavior.

A rectangle beginning at x=25 returns lower bound 1.0003983974456787, not exactly 1. Product and test preserve this SDK result. A second mask supplies exact 0...3 endpoints, proving no endpoint duplication. Curved-path endpoints differ from linear interpolation and match actual SDK interpolation. These observations are recorded in the diagnostic logs, not replaced with guessed mask rules.

Verification

- Red at test-only commit de43e82. `INK_VISIBILITY_CHECKS total=8 failed=4`. All four failures were missing JSON visibility; original drawing controls passed.
- Initial same executable green. `INK_VISIBILITY_CHECKS total=8 failed=0`.
- Expanded native Model/Store check. `INK_VISIBILITY_CHECKS total=273 failed=0`. Includes masks, world transforms, fractional and integer endpoints, curved paths, force, identity/time, schema 1 legacy decode, unknown/full/empty distinction, unchanged drawing revision, isolated persistence and size.
- Synthetic 189-stroke, 6192-point scene serialized to 354960 bytes in the final run. Full metadata adds exactly 9450 bytes. Adding that metadata growth to the user-reported 616040-byte scene yields 625490 bytes. This arithmetic is not a readback of the user's real scene or a promise that arbitrarily many fragmented masks fit 1 MiB. Existing packet rejection at 1 MiB is unchanged.
- Native SceneRenderer prefix through the raw-backed drawing branch is byte-identical to exact base 2ebd263. Both structure-only fallback call sites use separate visiblePointSegments. This is source preservation/wiring evidence, not executed iOS UI or native PNG pixel acceptance.
- Final runner verifies CFFIXED_USER_HOME and Application Support inside its archive home, isolates compiler/runtime HOME and TMPDIR, hashes actual inputs before/after, records compiler and both SDK interface hashes, waits/reaps each child and verifies each process group disappeared.
- Final verification command `python3 Tests/checks/ink-visibility/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-Sill-Obsidian/ink-visibility-20261019/green-verified`.
- Evidence directory `/Volumes/BT-Workspace/Development-Archives/BT_CCR-Sill-Obsidian/ink-visibility-20261019`. Includes before/after receipts, source hashes, red/green logs, compiler result, process outcomes, final diff and commit patch.

Deslop and scope review

Reviewed the complete owned diff against exact base. Product edits are restricted to CanvasModel, CanvasStore, CanvasWorkspace and SceneRenderer. Test and audit edits are task-owned. The retained model comment explains why unknown legacy points are omitted from fallback. No independent no-comments reviewer ran because nested agents are forbidden. Parent review remains pending. No new PR, Pages, source replica, device action, SDK installation, host UI, HAL, relay write, host restart or source-guard transfer claim occurred.

Architect Scrap phase did not require a product redesign. SDK diagnostics corrected fixture assumptions; design B remained consistent. Parent audio598 integration and physical MyScript investigation remain separate. Next action is parent independent review of the exact final HEAD and scoped integration. Precision eraser UI, glyph deletion, physical-device validation, full-app SDK validation and the overall MyScript/Obsidian goal remain open.
