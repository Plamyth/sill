import Foundation
import UIKit
import PencilKit

@MainActor private final class NativeEdits {
    let canvas: CanvasInkView
    let coordinator: PencilCanvas.Coordinator
    init(_ canvas: CanvasInkView, _ coordinator: PencilCanvas.Coordinator) {
        self.canvas = canvas
        self.coordinator = coordinator
    }
    func restore(_ next: PKDrawing) {
        let previous = canvas.drawing
        canvas.undoManager!.registerUndo(withTarget: self) { $0.restore(previous) }
        canvas.drawing = next
        coordinator.canvasViewDrawingDidChange(canvas)
    }
    func edit(_ next: PKDrawing, tool: Bool) {
        if tool { coordinator.canvasViewDidBeginUsingTool(canvas) }
        canvas.undoManager!.beginUndoGrouping()
        restore(next)
        canvas.undoManager!.endUndoGrouping()
        if tool { coordinator.canvasViewDidEndUsingTool(canvas) }
    }
}

@main struct RejectedDrawingChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        precondition(support.path.hasPrefix(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]! + "/"))
        var failures = [String]()
        var count = 0
        func check(_ pass: Bool, _ label: String) {
            count += 1
            if !pass { failures.append(label) }
            print("\(pass ? "PASS" : "FAIL") \(label)")
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(40)) }
        func drawing(_ amount: Int) -> PKDrawing {
            PKDrawing(strokes: (0..<amount).map { index -> PKStroke in
                let controls: [PKStrokePoint] = (0..<5).map { i -> PKStrokePoint in
                    let location = CGPoint(x: CGFloat(10 + i * 10), y: CGFloat(20 + index * 20))
                    return PKStrokePoint(location: location,
                        timeOffset: Double(i) * 0.1, size: CGSize(width: 4, height: 4),
                        opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
                }
                return PKStroke(ink: PKInk(.pen, color: .yellow),
                    path: PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: Double(index))))
            })
        }
        let first = drawing(1)
        let second = PKDrawing(strokes: first.strokes + drawing(1).strokes)
        let rejected = PKDrawing(strokes: second.strokes + drawing(12).strokes)
        for boundary in ["tool-end", "callback", "background"] {
            let tool = boundary != "callback"
            let store = CanvasStore()
            store.scene = CanvasScene()
            store.drawing = PKDrawing()
            let canvas = CanvasInkView()
            let coordinator = PencilCanvas.Coordinator(store: store)
            coordinator.canvas = canvas
            canvas.delegate = coordinator
            let manager = canvas.inkUndoManager
            manager.groupsByEvent = false
            canvas.undoManager!.groupsByEvent = false
            store.inkHistory.attach(manager)
            coordinator.replaceDrawingFromStore()
            let edits = NativeEdits(canvas, coordinator)
            edits.edit(first, tool: tool)
            await settle()
            edits.edit(second, tool: tool)
            await settle()
            check(store.drawing == second && manager.canUndo, "accepted edits have history tool=\(tool)")
            canvas.undoManager?.undo()
            await settle()
            check(store.drawing == first && canvas.undoManager?.canRedo == true,
                  "standard undo uses the accepted branch tool=\(tool)")
            store.inkHistory.undo()
            await settle()
            check(store.drawing.strokes.isEmpty,
                  "toolbar undo after standard undo never resurrects ink tool=\(tool)")
            canvas.undoManager?.redo()
            await settle()
            store.inkHistory.redo()
            await settle()
            check(store.drawing == second && canvas.drawing == second,
                  "mixed standard and toolbar redo restore both accepted edits tool=\(tool)")
            coordinator.canvasViewDidBeginUsingTool(canvas)
            check(canvas.undoManager?.canUndo == false && canvas.undoManager?.canRedo == false,
                  "standard availability is disabled during Pencil input tool=\(tool)")
            canvas.undoManager?.undo()
            check(store.drawing == second, "standard undo cannot interrupt Pencil input tool=\(tool)")
            coordinator.canvasViewDidEndUsingTool(canvas)
            await settle()
            var falseStyle = store.scene
            falseStyle.strokes[0].style!.transform.tx += 100
            check(await SceneRenderer.png(scene: falseStyle) == nil,
                  "production renderer refuses a false native projection tool=\(tool)")
            let generation = store.inkHistory.generation
            store.scene.annotations.append(.init(id: UUID(), nodeId: nil, text: "", author: "fixture"))
            let size = try JSONEncoder().encode(store.scene).count
            store.scene.annotations[0].text = String(repeating: "x", count: CanvasScene.localByteLimit - size - 128)
            store.saveNow()
            let accepted = store.scene
            check(try JSONEncoder().encode(accepted).count < CanvasScene.localByteLimit,
                  "last accepted scene fits 4 MiB tool=\(tool)")
            if boundary == "background" {
                coordinator.canvasViewDidBeginUsingTool(canvas)
                edits.edit(rejected, tool: false)
                coordinator.flushPendingDrawing(save: true)
                coordinator.canvasViewDidEndUsingTool(canvas)
            } else {
                edits.edit(rejected, tool: tool)
            }
            await settle()
            check(store.status.hasPrefix("scene_too_large") && store.scene == accepted && canvas.drawing == second,
                  "oversized edit is refused and actual PKCanvasView restored tool=\(tool)")
            check(manager.canUndo && !store.inkHistory.usingTool && store.inkHistory.generation == generation,
                  "rejection preserves prior history and ends tool busy tool=\(tool)")
            store.inkHistory.undo()
            await settle()
            check(store.drawing == first && canvas.drawing == first && manager.canRedo,
                  "undo after rejection restores the previous accepted native drawing tool=\(tool)")
            store.inkHistory.redo()
            await settle()
            check(store.drawing == second && canvas.drawing == second && !manager.canRedo,
                  "redo restores only the accepted edit and cannot resurrect rejection tool=\(tool)")
            store.inkHistory.undo()
            await settle()
            store.inkHistory.undo()
            await settle()
            check(store.drawing.strokes.isEmpty && canvas.drawing.strokes.isEmpty,
                  "earlier accepted edit remains undoable tool=\(tool)")
            store.inkHistory.redo()
            await settle()
            store.inkHistory.redo()
            await settle()
            check(store.drawing == second && canvas.drawing == second, "both accepted edits redo tool=\(tool)")
            store.inkHistory.undo()
            await settle()
            edits.edit(rejected, tool: tool)
            await settle()
            check(store.drawing == first && manager.canRedo,
                  "a rejected edit after undo preserves the accepted redo branch tool=\(tool)")
            store.inkHistory.redo()
            await settle()
            check(store.drawing == second && canvas.drawing == second,
                  "redo after a rejected edit restores the accepted branch tool=\(tool)")
            try store.importScene(store.scene)
            coordinator.replaceDrawingFromStore()
            check(!manager.canUndo && !manager.canRedo, "external import still resets history tool=\(tool)")
            canvas.delegate = nil
            store.inkHistory.detach(manager)
            print("BOUNDARY_PASS \(boundary)")
        }
        print("REJECTED_DRAWING_CHECKS total=\(count) failed=\(failures.count) actualPKCanvasView=true productionCoordinator=true windows=0 controlledNativeRegistrations=true")
        if !failures.isEmpty { throw NSError(domain: "RejectedDrawingChecks", code: failures.count,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}
