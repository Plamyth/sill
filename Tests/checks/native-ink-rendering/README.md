# Native ink rendering

Owner01a13ace-e372-7ed1-9946-149df37ee1c3. Source0dd10d1 in an exclusive
worktree. The original PencilKit drawing is the authority for appearance.
Current canvas and exported PNG redraw every structural control point as an
unmasked polyline. A precise erasure can therefore be covered by visible old ink.

The controlled iPad probe constructs one synthetic stroke and a two-part mask.
It compiles the exact production SceneRenderer inside the existing diagnostic
app and compares native and exported pixels on both visible sides and the gap.
No user drawing is imported or edited. UIKit, PencilKit, maskedPathRanges and
the actual image renderer execute on the approved physical iPad.

Two designs were compared sequentially. Reconstructing appearance from sampled
visible vector segments would require a new projection contract and coordinated
agent consumers. Drawing the canonical PKDrawing directly preserves its brush,
mask and transform without that approximation. Choose the native appearance
path, retain structural-only legacy rendering, and refuse malformed nonempty
drawing data rather than resurrecting a raw polyline. Remove the redundant
canvas polyline layer when a native drawing is present.

This unit does not fix the separate missing visibility projection in agent-facing
InkStroke JSON. Raw points do not prove that every segment is currently visible.
The original drawing remains lossless; exact agent-visible partial erasure and
glyph edit correspondence require another explicit model/consumer change.

Before product edits, the native pixel control must show ink on both sides and
no ink in the gap, while the production PNG incorrectly fills that gap. After
the fix, the same test and structural-only legacy/invalid-data controls must
pass. Independent review, full accepted-source build and installed UI remain
parent gates. Host source-request admission is in another worktree and is not
part of this drawing result.


The foreground iPad97 execution supplies a valid red control. Native image
alpha is present at x25 and x95, and absent at x60. The production PNG fills
x60, accepts malformed and invalid nonempty drawings, and revives points for
an empty native drawing. Four product assertions fail. Run96 used a white
brightness control on the transparent native image and failed two fixture
controls. Those two failures are not product evidence.

The native image control reads alpha because PencilKit adapts monochrome ink
to the current appearance. The fixed black canvas uses literal base colors. PKCanvasView therefore
uses a light interface override and async native CGContext drawing uses
darkUserInterfaceStyle=false. The surrounding app UI remains dark. This
preserves masks, brush and transforms without inverting existing white ink. Structural-only legacy input remains
a polyline. This is an appearance correction, not an agent-visible glyph map.

A second native design agent was refused at the global agent capacity limit.
Architecture comparison remains a labeled sequential pass. Native raster
rendering is smaller than reconstructing maskedPathRanges and brushes in a
second vector renderer. No independent acceptance is claimed.

The diagnostic project is /tmp/rea-ios-ui-20261017/CanvasBridge.xcodeproj,
scheme CanvasBridge, on approved iPad00008112-00116854362BC01E. ProbeApp.swift
replaces only the diagnostic app entry, and the exact product SceneRenderer
replaces the diagnostic renderer. UITests.swift is the focused test body.
Run xcodebuild test with only-testing
CanvasBridgeUITests/CanvasBridgeUITests/testNativeInkRenderingMask, the existing
DerivedData, DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer and a
fresh resultBundlePath obtained through storage-route. Keep normal diagnostic
source backups and restore them after the final experiment.

Red receipts are IpadNativeInkRender97.xcresult and
ipad-native-ink-render97-20261019.log under the routed project archive.


The rendering contract is async png(scene:). Both production callers freeze a
CanvasScene value and await it. Native async drawing owns its bitmap context;
no UIGraphics global context remains pushed across suspension. The product
iPad target is iOS27, while the public draw API is available since iOS26.

Runs98 through102 preserved masks but showed that dark native rendering turns
white base ink black; black becomes white and red remains red. Run103 passed
the ten original pixel controls after using literal base colors. Run104 moved
the stroke to y30 and found a vertical inversion at y70. A second manual
CoreGraphics flip was the cause. The strengthened fixture checks the native
coordinates, red color, both mask sides, erased gap, malformed/invalid drawing,
empty-native-versus-stale-points, and structural-only legacy input.

ProbeApp's two-argument synchronous overload returns nil only to compile the
unentered old diagnostic CanvasWorkspace. The test calls the one-argument
actual async production method. It is not a compatibility shim in the product.


Final foreground iPad105 passed all12 pixel/format assertions. Native controls
show both mask sides and no gap. The exported white stroke is [255,255,255,255]
at y30, the erased gap is [0,0,0,255], mirrored y70 is empty, and red remains
[255,0,0,255]. Empty-native and invalid-data controls pass. This is the exact
production renderer in the diagnostic app. CanvasWorkspace/PencilCanvas are
source changes still requiring independent review, full target compile and
installed UI acceptance. The user drawing was not read or changed by the probe.

The native API already maps drawing coordinates into the bitmap. The extra
manual vertical flip found by run104 was removed, rather than adjusting the
expected coordinates. Run105 is the final candidate proof, not an installation.


Independent review of0ad7726 found that the new render suspension could save
sceneA through a newly selected connectionY and mutate its checkpoint. The
owned lifecycle correction captures connection/address/token/scene and CAS,
checks cancellation and identity after every await, and checks busy before
resetting shared synchronization state. Same-scene editing may retain a valid
frozen earlier revision; changed-scene/connection/enable/CAS work is refused.

VaultLifecycle.swift extracts the actual production method into a controlled
iPad runner fixture. Remote calls, render and checkpoint writes are recording
boundaries. Run110 of rejected0ad7726 executes40 assertions and fails17,
including old render writes after scene/address/token changes, cancellation,
disabling, CAS change, superseded read and response. Run109 had an invalid
fixture baseline and was stopped; it is not product red. No live relay or
Obsidian file is written by this controlled fixture. Run111 applies the same
fixture to the correction and passes all40 assertions. The model and boundary
stand-ins do not certify real network cancellation or full SwiftUI view timing.
