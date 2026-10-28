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
    @MainActor static func main() throws {
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
            let reopened = try JSONDecoder().decode(CanvasScene.self,from:Data(contentsOf:file))
            check(reopened == s,"actual JSON file reopen \(kind.rawValue)")
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
        let store = CanvasStore()
        check(store.updateDrawing(PKDrawing(strokes:[oval])),"store accepts native drawing")
        store.mode = .lasso; store.setInkSelection([oval.id]); store.proposeInkShape()
        check(store.inkShapeIsCurrent && store.inkShapeProposal?.node.kind == .ellipse,"product proposal selected native ink")
        let before = store.scene
        store.cancelInkShape()
        check(store.scene == before && !store.confirmInkShape(),"cancel leaves scene unchanged")
        store.proposeInkShape(); store.setInkSelection([]); store.setInkSelection([oval.id])
        check(!store.inkShapeIsCurrent && !store.confirmInkShape(),"selection ABA is stale")
        store.proposeInkShape(); store.mode = .pen; store.mode = .lasso
        check(!store.confirmInkShape(),"mode change cancels")
        store.setInkSelection([oval.id]); store.proposeInkShape(); check(store.confirmInkShape(),"store confirmation persists")
        check(store.canUndoGraph,"existing graph undo available")
        store.undoGraphEdit(); check(store.scene.nodes == before.nodes && store.scene.drawingBase64 == before.drawingBase64,"undo preserves ink")
        store.redoGraphEdit(); check(store.scene.nodes.count == before.nodes.count+1 && store.scene.drawingBase64 == before.drawingBase64,"redo preserves ink")
        store.saveNow()
        let reopened = CanvasStore()
        check(reopened.scene == store.scene && reopened.drawing == store.drawing,"fresh store reopens actual saved JSON and native drawing")
        check(CanvasInkShapeProposal.Failure.ambiguous.localizedDescription.contains("원본"),"Korean rejection")
        store.mode = .lasso; store.setInkSelection([oval.id]); store.proposeInkShape()
        let saved = store.scene
        store.scene = saved
        check(!store.inkShapeIsCurrent && !store.confirmInkShape(),"same scene replacement invalidates generation")
        store.setInkSelection([oval.id]); store.proposeInkShape()
        store.inkHistory.setUsingTool(true)
        check(!store.confirmInkShape(),"active ink blocks confirmation")
        store.inkHistory.setUsingTool(false)
        print("SHAPE_CHECKS_OK \(checks)")
    }
}
