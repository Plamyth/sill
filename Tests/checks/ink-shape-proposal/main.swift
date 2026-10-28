import Foundation
import PencilKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@main struct ShapeChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(),label); checks += 1; print("PASS \(label)")
    }
    static func stroke(_ points: [CGPoint], transform: CGAffineTransform = .identity,
                       mask: NSBezierPath? = nil, force: CGFloat = 0.4) -> PKStroke {
        let path = PKStrokePath(controlPoints:points.enumerated().map { i,p in
            PKStrokePoint(location:p,timeOffset:Double(i)/100,size:CGSize(width:3,height:3),opacity:1,
                          force:force,azimuth:0,altitude:.pi/2)
        },creationDate:Date(timeIntervalSince1970:12345))
        return PKStroke(ink:PKInk(.pen,color:.white),path:path,transform:transform,mask:mask)
    }
    static func polyline(_ corners: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for (a,b) in zip(corners,corners.dropFirst()) {
            for i in 0..<25 {
                let t = CGFloat(i) / 25
                result.append(CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t))
            }
        }
        return result + [corners.last!]
    }
    static func scene(_ drawing: PKDrawing) -> CanvasScene {
        var s = CanvasScene(); s.schemaVersion = 2
        s.drawingBase64 = drawing.dataRepresentation().base64EncodedString()
        s.strokes = CanvasScene.nativeInkStrokes(drawing)
        return s
    }
    static func proposal(_ strokes: [PKStroke]) throws -> CanvasInkShapeProposal {
        let d = PKDrawing(strokes:strokes)
        return try .make(scene:scene(d),drawing:d,selection:Set(strokes.map(\.id)))
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("accepted \(label)") }
        catch { check(true,label) }
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        check(support.path.hasPrefix(home+"/"),"isolated file location")
        let line = stroke((0...40).map { .init(x:40+Double($0)*4,y:60+Double($0)*2+sin(Double($0))*0.5) })
        let box = stroke(polyline([.init(x:50,y:50),.init(x:210,y:50),.init(x:210,y:150),.init(x:50,y:150),.init(x:50,y:50)]))
        let oval = stroke((0...120).map { i in .init(x:150+80*cos(Double(i)*2 * .pi/120),y:130+55*sin(Double(i)*2 * .pi/120)) })
        for (stroke,kind) in [(line,CanvasNode.Kind.line),(box,.box),(oval,.ellipse)] {
            let p = try proposal([stroke])
            check(p.node.kind == kind,"native geometry \(kind.rawValue)")
            check(p.node.confidence == .proposal,"never auto confirm")
            check(p.source.nodes.isEmpty,"preview does not mutate scene")
            let s = try p.confirmed(in:p.source,selection:p.selection)
            check(s.nodes[0].confidence == .confirmed && s.nodes[0].sourceStrokeIds == [stroke.id],"explicit confirmation provenance")
            check(s.drawingBase64 == p.source.drawingBase64 && s.strokes == p.source.strokes,"original bytes pressure and IDs preserved")
            let file = support.appendingPathComponent("shape-\(kind.rawValue).json")
            try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true)
            try JSONEncoder().encode(s).write(to:file,options:.atomic)
            if kind == .box {
                let reopened = try JSONDecoder().decode(CanvasScene.self,from:Data(contentsOf:file))
                check(reopened == s,"actual JSON file reopen box")
            } else {
                rejects("schema2 new kind explicitly refused \(kind.rawValue)") {
                    _ = try JSONDecoder().decode(CanvasScene.self,from:Data(contentsOf:file))
                }
                rejects("Pele refuses incompatible kind instead of box fallback") { _ = try CanvasDiagramSnapshot(scene:s) }
            }
            rejects("duplicate/stale confirmation") { _ = try p.confirmed(in:s,selection:p.selection) }
            rejects("changed selection") { _ = try p.confirmed(in:p.source,selection:[]) }
            var changed = p.source; changed.revision += 1
            rejects("changed revision") { _ = try p.confirmed(in:changed,selection:p.selection) }
        }
        let translated = try proposal([stroke(polyline([.init(x:0,y:0),.init(x:160,y:0),.init(x:160,y:100),.init(x:0,y:100),.init(x:0,y:0)]),transform:CGAffineTransform(translationX:80,y:90))])
        check(abs(translated.node.frame.x-80)<2,"native affine translation")
        let sides = [[CGPoint(x:50,y:50),.init(x:210,y:50)],[.init(x:210,y:50),.init(x:210,y:150)],
                     [.init(x:210,y:150),.init(x:50,y:150)],[.init(x:50,y:150),.init(x:50,y:50)]]
        let four = try proposal(sides.map { stroke(polyline($0)) })
        check(four.node.kind == .box,"four native strokes rectangle")
        rejects("scribble rejected") { _ = try proposal([stroke(polyline([.init(x:0,y:0),.init(x:80,y:90),.init(x:0,y:90),.init(x:80,y:0),.init(x:0,y:0)]))]) }
        rejects("point rejected") { _ = try proposal([stroke([.zero,.zero])]) }
        rejects("short line rejected") { _ = try proposal([stroke([.zero,.init(x:5,y:0)])]) }
        rejects("singular transform rejected") { _ = try proposal([stroke([.zero,.init(x:100,y:0)],transform:.init(scaleX:0,y:1))]) }
        let mask = NSBezierPath(rect:NSRect(x:0,y:0,width:50,height:50))
        rejects("partial mask rejected") { _ = try proposal([stroke([.zero,.init(x:100,y:0)],mask:mask)]) }
        rejects("nonfinite transform rejected before interpolation") {
            try CanvasInkShapeProposal.validate(stroke([.zero,.init(x:100,y:0)],transform:.init(a:1,b:0,c:0,d:1,tx:.infinity,ty:0)))
        }
        let sanitized = stroke([.zero,.init(x:100,y:0)],force:.nan)
        check(sanitized.path.allSatisfy { $0.force.isFinite },"PencilKit normalizes NaN pressure before public readback")
        rejects("nonfinite persisted pressure projection rejected") {
            let drawing = PKDrawing(strokes:[line])
            var broken = scene(drawing)
            broken.strokes[0].points[0].pressure = .nan
            _ = try CanvasInkShapeProposal.make(scene:broken,drawing:drawing,selection:[line.id])
        }
        let pressureStroke = stroke([.init(x:10,y:10),.init(x:150,y:10)],force:1.7)
        let pressureProposal = try proposal([pressureStroke])
        let pressureConfirmed = try pressureProposal.confirmed(in:pressureProposal.source,selection:pressureProposal.selection)
        check(pressureConfirmed.strokes == pressureProposal.source.strokes,"numeric native pressure preserved without normalization")
        let d = PKDrawing(strokes:[line])
        rejects("empty selection") { _ = try CanvasInkShapeProposal.make(scene:scene(d),drawing:d,selection:[]) }
        rejects("unknown selection") { _ = try CanvasInkShapeProposal.make(scene:scene(d),drawing:d,selection:[UUID()]) }
        let pending = CanvasStore()
        check(pending.updateDrawing(PKDrawing(strokes:[oval])),"ellipse preview native source")
        pending.mode = .lasso; pending.setInkSelection([oval.id]); pending.proposeInkShape()
        let unsupportedOriginal = pending.scene
        check(pending.inkShapeProposal?.node.kind == .ellipse && !pending.inkShapeIsCurrent && !pending.confirmInkShape(),
              "ellipse compatibility pending: preview only, no confirmation")
        check(pending.scene == unsupportedOriginal && pending.status.contains("shape_wire_contract_pending"),
              "unsupported kind preserves original and explicit reason")
        let store = CanvasStore()
        check(store.updateDrawing(PKDrawing(strokes:[box])),"store accepts native drawing")
        store.mode = .lasso; store.setInkSelection([box.id]); store.proposeInkShape()
        check(store.inkShapeIsCurrent && store.inkShapeProposal?.node.kind == .box,"product proposal selected native ink")
        let before = store.scene
        store.cancelInkShape()
        check(store.scene == before && !store.confirmInkShape(),"cancel leaves scene unchanged")
        store.proposeInkShape(); store.setInkSelection([]); store.setInkSelection([box.id])
        check(!store.inkShapeIsCurrent && !store.confirmInkShape(),"selection ABA is stale")
        store.proposeInkShape(); store.mode = .pen; store.mode = .lasso
        check(!store.confirmInkShape(),"mode change cancels")
        store.setInkSelection([box.id]); store.proposeInkShape(); check(store.confirmInkShape(),"store confirmation persists")
        check(store.canUndoGraph,"existing graph undo available")
        store.undoGraphEdit(); check(store.scene.nodes == before.nodes && store.scene.drawingBase64 == before.drawingBase64,"undo preserves ink")
        store.redoGraphEdit(); check(store.scene.nodes.count == before.nodes.count+1 && store.scene.drawingBase64 == before.drawingBase64,"redo preserves ink")
        store.saveNow()
        let reopened = CanvasStore()
        check(reopened.scene == store.scene && reopened.drawing == store.drawing,"fresh store reopens actual saved JSON and native drawing")
        check(CanvasInkShapeProposal.Failure.ambiguous.localizedDescription.contains("원본"),"Korean rejection")
        store.mode = .lasso; store.setInkSelection([box.id]); store.proposeInkShape()
        let saved = store.scene
        store.scene = saved
        check(!store.inkShapeIsCurrent && !store.confirmInkShape(),"same scene replacement invalidates generation")
        store.setInkSelection([box.id]); store.proposeInkShape()
        store.inkHistory.setUsingTool(true)
        check(!store.confirmInkShape(),"active ink blocks confirmation")
        store.inkHistory.setUsingTool(false)
        if let outputPath = ProcessInfo.processInfo.environment["INK_SHAPE_OUTPUT"] {
            let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            let folder = output.appendingPathComponent("shape-selected-files", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
            let files = CanvasFileWorkspace(folder: folder, requiresScope: false)
            let incompatible = try proposal([oval])
            let unsupported = try incompatible.confirmed(in:incompatible.source,selection:incompatible.selection)
            rejects("Files refuses new shape kind before external writes") { _ = try files.save(unsupported,preview:png,expected:nil) }
            check(!FileManager.default.fileExists(atPath:files.documentURL(unsupported.id).path),
                  "unsupported kind creates no external source document")
            _ = try files.save(before, preview: png, expected: nil)
            let binding = CanvasFileWorkspace.Binding(bookmark: try folder.bookmarkData(options: .minimalBookmark,
                includingResourceValuesForKeys: nil, relativeTo: nil), sceneID: before.id,
                savedSceneSHA: try CanvasFileWorkspace.sceneSHA(before))
            try CanvasLocalFile.write(CanvasFileWorkspace.bytes(before), to: CanvasRuntime.stateURL(.scene))
            try CanvasLocalFile.write(JSONEncoder().encode(binding), to: CanvasRuntime.stateURL(.workspace))
            let real = CanvasStore(); real.filePreview = { _ in png }
            real.mode = .lasso; real.setInkSelection([box.id]); real.proposeInkShape()
            check(real.confirmInkShape(), "combined Store shape confirmation")
            check(!real.fileWorkspaceCanSync && real.fileWorkspaceState == .pending && real.status.contains("미저장"),
                  "shape cache is not Files success and relay waits")
            let after = real.scene
            check(after.drawingBase64 == before.drawingBase64 && after.strokes == before.strokes,
                  "combined Store never deletes original shape ink")
            await real.saveFileWorkspace()
            let saved = try files.load(before.id)
            check(saved.scene == after && real.fileWorkspaceCanSync, "shape actual Files save/readback enables relay")
            let fresh = CanvasStore(); fresh.filePreview = { _ in png }
            check(fresh.scene == after && fresh.drawing == real.drawing, "shape fresh Store reopens Files JSON/native source")
            real.undoGraphEdit(); real.saveNow(); await real.saveFileWorkspace()
            let undoSaved = try files.load(before.id)
            check(undoSaved.scene.nodes == before.nodes, "shape Undo Files roundtrip")
            let undone = real.scene
            let originalHead = try Data(contentsOf: files.documentURL(before.id).appendingPathComponent("current.json"))
            let revisions = files.documentURL(before.id).appendingPathComponent("revisions")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: revisions.path)
            real.redoGraphEdit(); real.saveNow(); await real.saveFileWorkspace()
            check(real.fileWorkspaceState == .blocked && !real.fileWorkspaceCanSync && real.fileWorkspaceStatus.contains("미저장"),
                  "shape original-folder failure blocks relay and retains pending recovery")
            let failedHead = try Data(contentsOf: files.documentURL(before.id).appendingPathComponent("current.json"))
            check(failedHead == originalHead,
                  "shape folder failure preserves original current pointer")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: revisions.path)
            real.mode = .lasso; real.setInkSelection([box.id]); real.proposeInkShape()
            check(real.inkShapeProposal == nil, "blocked Files rejects a new shape proposal")
            try CanvasFileWorkspace.bytes(before).write(to: output.appendingPathComponent("shape-before.json"))
            try CanvasFileWorkspace.bytes(after).write(to: output.appendingPathComponent("shape-after.json"))
            try CanvasFileWorkspace.bytes(undone).write(to: output.appendingPathComponent("shape-undo.json"))
        }
        print("SHAPE_CHECKS_OK \(checks)")
    }
}
