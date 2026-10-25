import Foundation
import PencilKit
import AppKit

@main struct InkTransformCheck {
    @MainActor static func main() throws {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"))
        var failures = 0
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let points = [CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 50), CGPoint(x: 70, y: 80)]
            .enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                    size: CGSize(width: 3 + index, height: 5 + index), opacity: 0.3 + Double(index) * 0.2,
                    force: 0.25 + Double(index) * 0.1, azimuth: 0, altitude: 1)
            }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1))
        for (name, transform) in [
            ("identity", CGAffineTransform.identity),
            ("translated", CGAffineTransform(translationX: 100, y: -50)),
            ("rotated", CGAffineTransform(rotationAngle: .pi / 2)),
            ("scaled", CGAffineTransform(scaleX: 2, y: 0.5))
        ] {
            let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path, transform: transform)
            let drawing = PKDrawing(strokes: [stroke])
            let store = CanvasStore()
            store.scene = CanvasScene()
            store.drawing = PKDrawing()
            store.updateDrawing(drawing)
            let raw = Data(base64Encoded: store.scene.drawingBase64)!
            let restored = try PKDrawing(data: raw)
            let exported = store.scene.strokes[0]
            let source = restored.strokes[0]
            let expected = source.path.map { $0.location.applying(source.transform) }
            check(zip(exported.points, expected).allSatisfy {
                abs($0.x - Double($1.x)) < 0.0001 && abs($0.y - Double($1.y)) < 0.0001
            }, "\(name) exported coordinates match serialized drawing world coordinates")
            check(exported.id == source.id && exported.createdAt == source.path.creationDate,
                "\(name) stable stroke identity and time preserved")
            check(zip(exported.points, source.path).allSatisfy { abs($0.pressure - Double($1.force)) < 0.0001 },
                "\(name) pressure preserved")
            check(store.drawing == drawing && restored == drawing,
                "\(name) original PencilKit drawing preserved")
            let style = exported.style!
            check(style.version == 1 && style.inkType == source.ink.inkType.rawValue &&
                  style.samples.count == source.path.count,
                  "\(name) native ink type and point index correspondence preserved")
            check(style.color.map { $0.red == 0 && $0.green == 0 && $0.blue == 0 && $0.alpha == 1 } == true,
                  "\(name) native color projected in sRGB")
            let t = source.transform
            check(style.transform == .init(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty),
                  "\(name) original path transform projected separately from world coordinates")
            check(zip(style.samples, source.path).allSatisfy {
                abs($0.width - $1.size.width) < 0.0001 && abs($0.height - $1.size.height) < 0.0001 &&
                abs($0.opacity - $1.opacity) < 0.0001
            }, "\(name) path-local size and point opacity preserved")
            let encoded = try JSONEncoder().encode(store.scene)
            let decoded = try JSONDecoder().decode(CanvasScene.self, from: encoded)
            check(decoded.strokes == store.scene.strokes, "\(name) structured scene round trip")
        }
        let store = CanvasStore()
        store.scene = CanvasScene()
        store.drawing = PKDrawing()
        let mask = NSBezierPath(rect: CGRect(x: 0, y: 0, width: 45, height: 100))
        let nativeStroke = PKStroke(ink: PKInk(.marker, color: NSColor(srgbRed: 0.2, green: 0.7, blue: 0.9, alpha: 0.6)),
            path: path, transform: .identity, mask: mask)
        check(store.updateDrawing(PKDrawing(strokes: [nativeStroke])), "masked styled fixture accepted")
        let before = store.scene
        let native = store.drawing
        let manager = UndoManager()
        manager.groupsByEvent = false
        store.inkHistory.attach(manager)
        let generation = store.inkHistory.generation
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: store) { _ in }
        manager.endUndoGrouping()
        let desired = CanvasPenSettings(color: .cyan, width: 2)
        let command = CanvasPenSettingsChange(expected: .default, settings: desired)
        func refused(_ expected: CanvasPenSettingsError, _ label: String) {
            do {
                _ = try store.setPenSettings(command, sceneID: before.id, baseRevision: before.revision)
                check(false, label)
            } catch { check(error as? CanvasPenSettingsError == expected && store.scene == before, label) }
        }
        store.inkHistory.setUsingTool(true)
        refused(.inkBusy, "native tool busy rejects settings")
        store.inkHistory.setUsingTool(false)
        let traceOwner = UUID()
        store.setPencilTraceActive(true, owner: traceOwner)
        store.setPencilTraceActive(false, owner: UUID())
        check(store.inkBusy, "late teardown from another canvas cannot release an active trace")
        refused(.inkBusy, "trace busy before native callback rejects settings")
        store.setPencilTraceActive(false, owner: traceOwner)
        let agent = AgentRevision(sceneId: before.id, baseRevision: before.revision,
            annotations: [], proposedNodes: [], setPenSettings: command)
        check(store.applyAgentRevision(agent), "actual Store agent entry applies next-pen settings")
        let applied = store.scene
        check(applied.effectivePenSettings == desired && applied.schemaVersion == 2,
              "agent applies selected settings and upgrades writer version")
        check(applied.drawingBase64 == before.drawingBase64 && applied.strokes == before.strokes &&
              store.drawing == native && native.strokes[0].mask != nil &&
              applied.strokes[0].visibility?.kind == .masked,
              "settings keep original native bytes, metadata, masks and projection")
        check(store.inkHistory.generation == generation && manager.canUndo,
              "settings preserve the existing native undo manager and history generation")
        check(store.penTool.inkType == .pen && store.penTool.color.isEqual(NSColor.cyan) && store.penTool.width == 2,
              "native tool uses the stored next-pen settings")
        check(!store.applyAgentRevision(agent) && store.scene == applied && store.status.hasPrefix("stale_revision"),
              "Store exposes stale revision without graph or ink changes")
        let noop = AgentRevision(sceneId: applied.id, baseRevision: applied.revision,
            annotations: [], proposedNodes: [], setPenSettings: .init(expected: desired, settings: desired))
        check(store.applyAgentRevision(noop) && store.scene == applied, "Store no-op does not advance revision")
        store.saveNow()
        let reopened = CanvasStore()
        check(reopened.scene == applied && reopened.drawing == native && reopened.penTool.width == 2,
              "a new Store reopens saved settings and original masked native drawing")
        let source = native.strokes[0]
        let color = applied.strokes[0].style!.color!
        check(applied.strokes[0].style!.inkType == source.ink.inkType.rawValue &&
              abs(color.red - 0.2) < 0.001 && abs(color.green - 0.7) < 0.001 &&
              abs(color.blue - 0.9) < 0.001 && abs(color.alpha - 0.6) < 0.001,
              "marker type and translucent sRGB color remain read-only projections")
        var missingNative = applied
        missingNative.drawingBase64 = ""
        do { try reopened.importScene(missingNative); check(false, "missing native must reject") }
        catch { check(reopened.scene == applied, "styled structured-only import cannot replace the native drawing") }
        var unsupported = applied
        unsupported.strokes[0].style!.version = 2
        do { try reopened.importScene(unsupported); check(false, "future projection must reject") }
        catch { check(reopened.scene == applied, "unsupported projection preserves the open scene") }
        var unreadable = applied
        unreadable.drawingBase64 = Data("invalid native".utf8).base64EncodedString()
        reopened.scene = unreadable
        do {
            _ = try reopened.setPenSettings(.init(expected: desired, settings: .default),
                sceneID: unreadable.id, baseRevision: unreadable.revision)
            check(false, "unreadable native must reject")
        } catch {
            check(error as? CanvasPenSettingsError == .unreadableDrawing && reopened.scene == unreadable,
                  "unreadable drawing refuses settings without replacing original bytes")
        }
        reopened.scene = applied
        store.inkHistory.detach(manager)
        print("INK_TRANSFORM_CHECKS total=\(checks) failed=\(failures)")
        if failures > 0 { exit(1) }
    }
}
