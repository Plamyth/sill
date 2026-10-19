import Foundation
import PencilKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
private final class InkUndoFixture {
    let store = CanvasStore()
#if canImport(UIKit)
    let canvas = CanvasInkView()
    lazy var coordinator = PencilCanvas.Coordinator(store: store)
    var manager: UndoManager { canvas.inkUndoManager }
#else
    let manager = UndoManager()
#endif

    init() {
        store.scene = CanvasScene()
        store.scene.width = 128
        store.scene.height = 100
        store.drawing = PKDrawing()
#if canImport(UIKit)
        coordinator.canvas = canvas
        canvas.delegate = coordinator
#endif
        manager.groupsByEvent = false
        store.inkHistory.attach(manager)
        replaceFromStore()
    }

    func replaceFromStore() {
#if canImport(UIKit)
        coordinator.replaceDrawingFromStore()
#endif
    }

    func apply(_ next: PKDrawing) {
#if canImport(UIKit)
        canvas.drawing = next
        coordinator.canvasViewDrawingDidChange(canvas)
#else
        store.updateDrawing(next)
#endif
    }

    func restore(_ next: PKDrawing) {
#if canImport(UIKit)
        let previous = canvas.drawing
#else
        let previous = store.drawing
#endif
        manager.registerUndo(withTarget: self) { $0.restore(previous) }
        apply(next)
    }

    func edit(_ next: PKDrawing) {
        manager.beginUndoGrouping()
        restore(next)
        manager.endUndoGrouping()
    }
}

@MainActor
enum InkUndoChecks {
    static func run(isolatedSupport: URL) async throws -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        guard support.standardizedFileURL == isolatedSupport.standardizedFileURL,
              Bundle.main.bundleIdentifier?.hasSuffix(".InkUndoCheck") == true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var checks = 0
        var failures = [String]()
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures.append(label) }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
        let fixture = InkUndoFixture()
        let store = fixture.store
        let manager = fixture.manager
        let history = store.inkHistory
        let controls = (0..<5).map { i in
            PKStrokePoint(location: CGPoint(x: 10 + i * 25, y: 40), timeOffset: Double(i) * 0.1,
                size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: 1)
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: 1))
#if canImport(UIKit)
        let mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 45, height: 100))
        mask.append(UIBezierPath(rect: CGRect(x: 75, y: 0, width: 53, height: 100)))
        let ink = PKInk(.pen, color: .white)
        let textEditor = UITextView()
        let editorManager = textEditor.undoManager!
        check(fixture.canvas.undoManager === manager && editorManager !== manager,
              "actual PKCanvasView override owns a manager separate from UITextView")
#else
        let mask = NSBezierPath(rect: CGRect(x: 0, y: 0, width: 45, height: 100))
        mask.appendRect(CGRect(x: 75, y: 0, width: 53, height: 100))
        let ink = PKInk(.pen, color: .white)
        let editorManager = UndoManager()
#endif
        editorManager.groupsByEvent = false
        editorManager.beginUndoGrouping()
        editorManager.registerUndo(withTarget: fixture) { _ in }
        editorManager.endUndoGrouping()
        let full = PKDrawing(strokes: [PKStroke(ink: ink, path: path)])
        let partial = PKDrawing(strokes: [PKStroke(ink: ink, path: path, mask: mask)])
#if canImport(UIKit)
        let activeFixture = InkUndoFixture()
        let activeRevision = activeFixture.store.scene.revision
        activeFixture.coordinator.canvasViewDidBeginUsingTool(activeFixture.canvas)
        activeFixture.apply(full)
        await settle()
        activeFixture.apply(partial)
        await settle()
        check(activeFixture.canvas.drawing == partial && activeFixture.store.drawing.strokes.isEmpty &&
              activeFixture.store.scene.revision == activeRevision,
              "native in-progress ink stays on canvas without serializing scene on each drawing callback")
        activeFixture.coordinator.canvasViewDidEndUsingTool(activeFixture.canvas)
        let committedBeforeSync = activeFixture.store.scene
        check(!activeFixture.store.inkHistory.usingTool && activeFixture.store.drawing == partial &&
              committedBeforeSync.revision == activeRevision + 1 &&
              committedBeforeSync.drawingBase64 == partial.dataRepresentation().base64EncodedString(),
              "tool-end publishes latest ink before an already-waiting vault refresh can resume")
        await settle()
        check(activeFixture.store.drawing == partial && activeFixture.store.scene.revision == activeRevision + 1,
              "tool end commits the latest native drawing once with partial eraser mask intact")
        activeFixture.coordinator.canvasViewDidBeginUsingTool(activeFixture.canvas)
        activeFixture.apply(full)
        activeFixture.coordinator.flushPendingDrawing(save: true)
        let activeSaved = try JSONDecoder().decode(CanvasScene.self,
            from: Data(contentsOf: support.appendingPathComponent("CanvasScene.json")))
        check(activeFixture.store.drawing == full && activeSaved == activeFixture.store.scene,
              "background flush saves unfinished native ink through the existing autosave format")
        activeFixture.apply(partial)
        activeFixture.store.drawing = PKDrawing()
        activeFixture.coordinator.flushPendingDrawing(save: true)
        await settle()
        check(activeFixture.store.drawing.strokes.isEmpty,
              "external replacement rejects old unfinished ink at the background flush boundary")
        PencilCanvas.dismantleUIView(UIView(), coordinator: activeFixture.coordinator)
#endif
        fixture.apply(full)
        await settle()
        let fullPNG = await png(scene: store.scene)
        fixture.edit(partial)
        await settle()
        let partialScene = store.scene
        let partialJSON = try JSONEncoder().encode(partialScene)
        let partialPNG = await png(scene: partialScene)
        check(history.availability == .init(canUndo: true, canRedo: false), "registered ink edit enables only undo")
        check(partialScene.strokes.first?.visibility?.visibleSegments.count == 2,
              "partially masked drawing exports two disjoint visible intervals")
        check(fullPNG != nil && partialPNG != nil && fullPNG != partialPNG,
              "native PNG renders distinguish full and partially erased ink")
        let generation = history.generation
        history.setUsingTool(true)
        history.undo()
        history.redo()
        check(history.availability == .init() && store.drawing == partial,
              "active Pencil tool disables availability and guards both commands")
        history.setUsingTool(false)
        await settle()
        history.undo()
        await settle()
        check(store.drawing == full && history.availability.canRedo,
              "undo restores actual PKDrawing through the local drawing update path")
        check(await png(scene: store.scene) == fullPNG, "undo PNG matches the original full ink")
        history.redo()
        await settle()
        let decoded = try JSONDecoder().decode(CanvasScene.self, from: partialJSON)
        check(store.drawing == partial && store.scene.drawingBase64 == partialScene.drawingBase64,
              "redo restores identical authoritative PKDrawing bytes")
        check(store.scene.strokes == decoded.strokes,
              "redo preserves JSON visible ranges, endpoint provenance, identity and dates")
        check(await png(scene: store.scene) == partialPNG, "redo PNG matches the partially erased ink")
        check(try PKDrawing(data: Data(base64Encoded: store.scene.drawingBase64)!) == partial,
              "redo serialized PKDrawing decodes with the same partial mask")
        check(history.generation == generation && store.scene.revision == partialScene.revision + 2,
              "local undo and redo preserve history generation and advance scene revisions")
        let node = store.scene.addNode(kind: .note, at: CanvasPoint(x: 1000, y: 1000), text: "external note")
        history.undo()
        await settle()
        history.redo()
        await settle()
        check(store.scene.nodes.first?.id == node && store.scene.nodes.first?.text == "external note" &&
              history.generation == generation, "ink undo and redo preserve concurrent scene structure without snapshots")
        try await Task.sleep(for: .milliseconds(300))
        let autosaved = try JSONDecoder().decode(CanvasScene.self,
            from: Data(contentsOf: support.appendingPathComponent("CanvasScene.json")))
        check(autosaved == store.scene, "drawing delegate update schedules the existing autosave path")
        store.saveNow()
        let saved = try JSONDecoder().decode(CanvasScene.self,
            from: Data(contentsOf: support.appendingPathComponent("CanvasScene.json")))
        check(saved == store.scene, "existing save path persists the redo scene in isolated support")
        await settle()
        check(CanvasStore().scene == store.scene, "new Store restores the persisted redo scene")

        history.undo()
        await settle()
        fixture.edit(PKDrawing())
        await settle()
        check(history.availability.canUndo && !history.availability.canRedo && !manager.canRedo,
              "a new ink edit after undo discards the native redo branch")

        manager.beginUndoGrouping()
        manager.beginUndoGrouping()
        history.scheduleRefresh()
        await settle()
        history.undo()
        history.redo()
        check(history.availability == .init() && manager.groupingLevel == 2,
              "nested native groups are unavailable and neither command raises a grouping exception")
        manager.endUndoGrouping()
        manager.endUndoGrouping()
        await settle()
        check(history.availability.canUndo, "closing native groups refreshes undo availability")

        var checkpoints = 0
        let observation = NotificationCenter.default.addObserver(forName: .NSUndoManagerCheckpoint,
            object: manager, queue: .main) { _ in
                MainActor.assumeIsolated { checkpoints += 1 }
            }
        history.scheduleRefresh()
        await settle()
        let firstCount = checkpoints
        await settle()
        NotificationCenter.default.removeObserver(observation)
        check(firstCount > 0 && checkpoints == firstCount && checkpoints < 5,
              "canRedo emits checkpoint but does not schedule a recursive availability loop")

        store.drawing = partial
        fixture.replaceFromStore()
        await settle()
        check(history.generation != generation && !manager.canUndo && !manager.canRedo &&
              history.availability == .init(), "external drawing assignment invalidates both history branches")
        check(editorManager.canUndo, "external replacement preserves the independent text editor history")
        fixture.edit(full)
        await settle()
        let remote = partialScene
        let importGeneration = history.generation
        try store.importScene(remote)
        fixture.replaceFromStore()
        history.undo()
        await settle()
        check(store.drawing == partial && history.generation != importGeneration &&
              !manager.canUndo && !manager.canRedo, "same-scene remote/import replacement cannot undo back to local ink")
        fixture.edit(full)
        await settle()
        let sameDrawingGeneration = history.generation
        try store.importScene(store.scene)
        fixture.replaceFromStore()
        await settle()
        check(history.generation != sameDrawingGeneration && !manager.canUndo,
              "even equal-drawing imports clear previous session history")
        fixture.edit(partial)
        await settle()
        store.scene.id = UUID()
        fixture.replaceFromStore()
        await settle()
        check(!manager.canUndo && !manager.canRedo, "switching scene identity invalidates prior ink history")

#if canImport(UIKit)
        fixture.apply(full)
        try store.importScene(remote)
        fixture.replaceFromStore()
        await settle()
        check(store.drawing == partial && fixture.canvas.drawing == partial,
              "queued old delegate drawing cannot overwrite an imported scene")
        fixture.apply(full)
        try store.importScene(remote)
        PencilCanvas.dismantleUIView(UIView(), coordinator: fixture.coordinator)
        await settle()
        check(store.drawing == partial, "teardown cannot flush stale local ink over an external replacement")
        fixture.coordinator.canvas = fixture.canvas
        fixture.canvas.delegate = fixture.coordinator
        history.attach(manager)
        fixture.replaceFromStore()
        fixture.apply(full)
        PencilCanvas.dismantleUIView(UIView(), coordinator: fixture.coordinator)
        let beforeDetach = store.scene
        await settle()
        let closedScene = try JSONDecoder().decode(CanvasScene.self,
            from: Data(contentsOf: support.appendingPathComponent("CanvasScene.json")))
        check(store.drawing == full && closedScene == beforeDetach &&
              store.scene == beforeDetach && fixture.canvas.delegate == nil,
              "dismantle saves current pending ink once and fences its queued delegate update")
#endif
        let nextManager = UndoManager()
        nextManager.groupsByEvent = false
        history.attach(nextManager)
        nextManager.beginUndoGrouping()
        nextManager.registerUndo(withTarget: fixture) { _ in }
        nextManager.endUndoGrouping()
        history.detach(manager)
        await settle()
        check(nextManager.canUndo && history.availability.canUndo,
              "late detach of an old canvas cannot erase the new canvas history")
        history.detach(nextManager)
        await settle()
        check(!nextManager.canUndo && history.availability == .init() && editorManager.canUndo,
              "canvas teardown clears only the attached canvas manager")
        let eventFixture = InkUndoFixture()
        eventFixture.manager.groupsByEvent = true
        eventFixture.edit(full)
        await settle()
        check(eventFixture.store.inkHistory.availability.canUndo,
              "native automatic event grouping enables undo")
        eventFixture.store.inkHistory.undo()
        await settle()
        check(eventFixture.store.drawing.strokes.isEmpty && eventFixture.store.inkHistory.availability.canRedo,
              "undo closes the automatic top-level group and exposes redo")
        eventFixture.store.inkHistory.redo()
        await settle()
        check(eventFixture.store.drawing == full,
              "redo works with the manager's default automatic event grouping")
        eventFixture.store.inkHistory.detach(eventFixture.manager)
        let result = "INK_UNDO_CHECKS total=\(checks) failed=\(failures.count) controlledRegistrations=true"
        print(result)
        if !failures.isEmpty {
            throw NSError(domain: "InkUndoChecks", code: failures.count,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
        return result
    }

    private static func png(scene: CanvasScene) async -> Data? {
#if canImport(UIKit)
        return await SceneRenderer.png(scene: scene)
#else
        guard let data = Data(base64Encoded: scene.drawingBase64),
              let drawing = try? PKDrawing(data: data),
              let context = CGContext(data: nil, width: 128, height: 100, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        await drawing.draw(in: context, frame: CGRect(x: 0, y: 0, width: 128, height: 100),
            from: CGRect(x: 0, y: 0, width: 128, height: 100), darkUserInterfaceStyle: false)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
#endif
    }
}
