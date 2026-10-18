# Handwriting proposal races

This executable compiles the production `CanvasStore.swift` and `CanvasModel.swift`
with macOS 27 PencilKit. It runs `proposeHandwriting()` with real SDK drawings.
A suspended async recognition closure controls completion order and returns known
text. The test does not copy the method or replace PencilKit or the scene model.
The default closure still calls `PKStrokeRecognizer.updateDrawing()` and
`recognizedText()`.

On this Mac with Xcode installed, resolve an archive directory before running:

```sh
storage-route path development-archive --project BT_CCR-Sill-Obsidian --filename handwriting-race-20261018
```

Pass that JSON path plus a new run subdirectory as the first argument:

```sh
python3 Tests/checks/handwriting-race/run.py /ABSOLUTE/RESOLVED/PATH/review --sdk-smoke
```

The executable verifies its application support path is inside the isolated
`CFFIXED_USER_HOME` before constructing a store. The embedded bundle identifier
lets PencilKit persist replica metadata without its command-line bundle-ID crash.
This does not launch or install an app.

The first commit, `54058ca`, adds the seam and failing reproduction. Its runtime
reported `RESULT 18 assertions, 11 failures`. Ink mutation, import, overlapping
requests, user selection and text edits, tool changes, and stale empty results
all changed state after their input became obsolete.

The fix uses an optional request UUID. Every new request replaces it. Changes to
the drawing, scene, selected node, proposal editor, or tool invalidate it. Only
the current request can publish a result or an empty-result status. The drawing
value captured at request start supplies the recognizer input, bounds, and source
stroke IDs. Recognition leaves the original ink intact.

Two designs were considered with the `pstack:how` and `pstack:architect` procedures:
capturing and comparing all scene and editor values on completion, or invalidating
the request at their mutation points. Invalidation also handles importing the same
scene and superseding a request before either one publishes. Serializing recognizer
calls would still require invalidation when users change their input. The chosen
design adds one private token and keeps the async closure as the only test seam.
Nested design agents were excluded by the subtask instructions.

The corrected runtime reports `RESULT 18 assertions, 0 failures`. With
`--sdk-smoke`, it also invokes the real recognizer through the default method path
and reports `RESULT 19 assertions, 0 failures`. The synthetic stroke produced no
text candidate in that smoke run. This proves that the SDK path executes and
preserves ink; recognition accuracy and iPad UI behavior remain unverified.
Both production source files also typecheck against the iOS 27 SDK with target
`arm64e-apple-ios27.0`.

An obsolete SDK operation is allowed to finish and its result is discarded.
The parent task owns independent review, integration, and device acceptance.
