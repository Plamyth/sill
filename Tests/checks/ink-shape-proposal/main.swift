import Foundation
import CryptoKit
import PencilKit
import ImageIO
import UniformTypeIdentifiers
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
        s.strokes = CanvasScene.nativeInkStrokes(try! PKDrawing(data:Data(base64Encoded:s.drawingBase64)!))
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
    @MainActor static func rotationChecks(support: URL) throws {
        let corners: [CGPoint] = [.init(x:-90,y:-55),.init(x:90,y:-55),.init(x:90,y:55),.init(x:-90,y:55),.init(x:-90,y:-55)]
        func transform(_ degrees: Double, _ scale: CGFloat) -> CGAffineTransform {
            let angle = CGFloat(degrees * .pi/180)
            return .init(a:scale*cos(angle),b:scale*sin(angle),c:-scale*sin(angle),d:scale*cos(angle),tx:250,ty:250)
        }
        func worldCorners(_ node: CanvasNode) -> [CGPoint] {
            let f = node.frame
            return [CanvasPoint(x:f.x,y:f.y),.init(x:f.x+f.width,y:f.y),
                .init(x:f.x+f.width,y:f.y+f.height),.init(x:f.x,y:f.y+f.height)].map {
                    let p = node.scenePoint($0)!
                    return CGPoint(x:p.x,y:p.y)
                }
        }
        for scale: CGFloat in [0.75,1,2] {
            for degrees in [-170.0,-135,-91,-60,-45,-30,-12,0,19,44,45,60,90,137,179] {
                let t = transform(degrees,scale)
                let ink = stroke(polyline(corners),transform:t)
                let p = try proposal([ink])
                check(p.node.kind == .box,"rotated rectangle \(degrees) scale=\(scale)")
                let expected = corners.dropLast().map { $0.applying(t) }
                check(worldCorners(p.node).allSatisfy { actual in expected.contains { hypot(actual.x-$0.x,actual.y-$0.y)<4*scale } },"frame and rotation world corners")
                let beforeHash = SHA256.hash(data:Data(base64Encoded:p.source.drawingBase64)!)
                let confirmed = try p.confirmed(in:p.source,selection:p.selection)
                check(confirmed.nodes[0].sourceStrokeIds == [ink.id] && confirmed.strokes == p.source.strokes &&
                    SHA256.hash(data:Data(base64Encoded:confirmed.drawingBase64)!) == beforeHash,"native SHA pressure source IDs unchanged")
                let data = try JSONEncoder().encode(confirmed)
                let decoded = try JSONDecoder().decode(CanvasScene.self,from:data)
                check(decoded.nodes[0].frame == confirmed.nodes[0].frame && decoded.nodes[0].rotationDegrees == confirmed.nodes[0].rotationDegrees,"JSON frame+rotation exact")
            }
        }
        for degrees in [-31.0,23,67] {
            let t = transform(degrees,1.25)
            let p = try proposal([stroke(polyline(corners).map { $0.applying(t) })])
            let expected = corners.dropLast().map { $0.applying(t) }
            check(p.node.kind == .box && worldCorners(p.node).allSatisfy { actual in
                expected.contains { hypot(actual.x-$0.x,actual.y-$0.y)<4 }
            },"baked world coordinates preserve recognition \(degrees)")
        }
        rejects("sheared quadrilateral stays ambiguous") {
            _ = try proposal([stroke(polyline(corners),transform:.init(a:1,b:0,c:0.5,d:1,tx:250,ty:250))])
        }
        for degrees in [-45.0,0,31,89] {
            let t = transform(degrees,1)
            let segments = Array(zip(corners,corners.dropFirst()))
            let ink = [2,0,3,1].enumerated().map { i,index -> PKStroke in
                let pair = segments[index]
                let ends = i%2 == 0 ? [pair.1,pair.0] : [pair.0,pair.1]
                return stroke(polyline(ends),transform:t)
            }
            check(tryKind(ink) == .box,"four sides permuted and reversed \(degrees)")
        }
        let circle = stroke((0...120).map { i in
            let angle = Double(i)*2 * .pi/120
            return CGPoint(x:100*cos(angle),y:100*sin(angle))
        },transform:transform(31,1))
        check(tryKind([circle]) == .ellipse,"circle stays ellipse never rectangle")
        rejects("overlapping boxes are not one rotated rectangle") {
            _ = try proposal([stroke(polyline(corners),transform:transform(31,1)),
                stroke(polyline(corners.map { CGPoint(x:$0.x+30,y:$0.y+25) }),transform:transform(31,1))])
        }
        rejects("rotated crossing scribble") {
            _ = try proposal([stroke(polyline([corners[0],corners[2],corners[1],corners[3],corners[0]]),transform:transform(31,1))])
        }
        rejects("two disconnected parallel lines") {
            _ = try proposal([stroke(polyline([.init(x:-90,y:-55),.init(x:90,y:-55)]),transform:transform(31,1)),
                stroke(polyline([.init(x:-90,y:55),.init(x:90,y:55)]),transform:transform(31,1))])
        }
        let p = try proposal([stroke(polyline(corners),transform:transform(31,1))])
        let confirmed = try p.confirmed(in:p.source,selection:p.selection)
        try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true)
        let json = support.appendingPathComponent("rotated-shape.json")
        try JSONEncoder().encode(confirmed).write(to:json,options:.atomic)
        let reopened = try JSONDecoder().decode(CanvasScene.self,from:Data(contentsOf:json))
        check(reopened == confirmed,"rotated JSON actual file reopen")
        let node = reopened.nodes[0]
        let context = CGContext(data:nil,width:512,height:512,bitsPerComponent:8,bytesPerRow:512*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x:node.frame.center.x,y:node.frame.center.y)
        context.rotate(by:node.rotationRadians)
        context.translateBy(x:-node.frame.center.x,y:-node.frame.center.y)
        let f = node.frame
        context.addPath(CanvasInkShapeOutline(kind:node.kind).path(in:CGRect(x:f.x,y:f.y,width:f.width,height:f.height)).cgPath)
        context.setStrokeColor(CGColor(gray:1,alpha:1)); context.setLineWidth(3); context.strokePath()
        let png = support.appendingPathComponent("rotated-shape.png")
        let destination = CGImageDestinationCreateWithURL(png as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil)
        check(CGImageDestinationFinalize(destination),"production outline frame+rotation writes actual PNG")
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(png as CFURL,nil)!,0,nil)!
        check(image.width == 512 && image.height == 512,"PNG decoded from actual file")
        let pixels = image.dataProvider!.data! as Data
        var occupied: [CGPoint] = []
        for y in 0..<512 { for x in 0..<512 where pixels[y*image.bytesPerRow+x*4+3] > 0 {
            occupied.append(CGPoint(x:x,y:511-y))
        } }
        let expected = worldCorners(node)
        print("PNG_PIXELS scene origin uses y=511-row after PNG decode")
        check(!occupied.isEmpty && abs(occupied.map(\.x).min()!-expected.map(\.x).min()!)<4 &&
            abs(occupied.map(\.x).max()!-expected.map(\.x).max()!)<4 &&
            abs(occupied.map(\.y).min()!-expected.map(\.y).min()!)<4 &&
            abs(occupied.map(\.y).max()!-expected.map(\.y).max()!)<4,"PNG pixels match JSON rotated bounds")
    }
    static func tryKind(_ strokes: [PKStroke]) -> CanvasNode.Kind? { try? proposal(strokes).node.kind }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        check(support.path.hasPrefix(home+"/"),"isolated file location")
        try rotationChecks(support:support)
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
            check(s.schemaVersion == (kind == .box ? 2 : 3),"scene version follows actual kind")
            if kind != .box {
                for old in [1,2] {
                    var invalid = s; invalid.schemaVersion = old
                    rejects("new kind refuses legacy scene version") {
                        _ = try JSONDecoder().decode(CanvasScene.self,from:JSONEncoder().encode(invalid))
                    }
                }
                let diagram = try CanvasDiagramSnapshot(scene:s)
                check(diagram.source.contains(kind == .ellipse ? "rx:50%,ry:50%" : " ---|"),
                      "deterministic actual shape diagram projection")
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
        check(pending.inkShapeProposal?.node.kind == .ellipse && pending.inkShapeIsCurrent,
              "schema3 ellipse preview ready for explicit confirmation")
        check(pending.scene == unsupportedOriginal,"preview never mutates original")
        var newer = unsupportedOriginal; newer.schemaVersion = 4
        rejects("unknown scene version refused") { _ = try JSONDecoder().decode(CanvasScene.self,from:JSONEncoder().encode(newer)) }
        let raw = String(data:try JSONEncoder().encode(try proposal([oval]).source),encoding:.utf8)!
        var unknown = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [String:Any]
        unknown["nodes"] = [["id":UUID().uuidString,"kind":"future-shape"]]
        rejects("unknown kind refused instead of remapped") { _ = try JSONDecoder().decode(CanvasScene.self,from:JSONSerialization.data(withJSONObject:unknown)) }
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
            var legacy = try proposal([oval]).source
            legacy.nodes = [try proposal([oval]).node]
            rejects("Files rejects legacy schema with new shape kind") { _ = try files.save(legacy,preview:png,expected:nil) }
            check(!FileManager.default.fileExists(atPath:files.documentURL(legacy.id).path), "legacy invalid kind writes no external document")
            let combinedNative = try PKDrawing(data:PKDrawing(strokes:[line,box,oval]).dataRepresentation())
            var projected = scene(combinedNative)
            for stroke in [line,box,oval] {
                let p = try CanvasInkShapeProposal.make(scene:projected,drawing:combinedNative,selection:[stroke.id])
                projected = try p.confirmed(in:projected,selection:p.selection)
            }
            check(projected.schemaVersion == 3,"mixed new shapes promote schema3")
            let snapshot = try CanvasDiagramSnapshot(scene:projected)
            check(projected.nodes.count == 3 && projected.links.isEmpty && snapshot.displayedNodeCount == 4 && snapshot.displayedEdgeCount == 1,
                  "display helper counted but never stored as real node or source")
            var limitScene = CanvasScene(); limitScene.schemaVersion = 3
            limitScene.nodes = (0..<512).map { _ in CanvasNode(id:UUID(),kind:.box,frame:.init(x:0,y:0,width:20,height:20),text:"",confidence:.confirmed,sourceStrokeIds:[]) }
            _ = try CanvasDiagramSnapshot(scene:limitScene)
            limitScene.nodes[0].kind = .line
            rejects("512 real nodes plus line helper exceeds displayed node limit") { _ = try CanvasDiagramSnapshot(scene:limitScene) }
            limitScene.nodes = Array(limitScene.nodes.prefix(2)); limitScene.nodes[1].kind = .box
            limitScene.links = (0..<1024).map { _ in CanvasLink(id:UUID(),from:limitScene.nodes[0].id,to:limitScene.nodes[1].id,label:"") }
            rejects("1024 links plus primitive edge exceeds displayed edge limit") { _ = try CanvasDiagramSnapshot(scene:limitScene) }
            try CanvasFileWorkspace.bytes(projected).write(to:output.appendingPathComponent("projection-scene.json"))
            try JSONEncoder().encode(snapshot).write(to:output.appendingPathComponent("projection-snapshot.json"))
            let v3Files = CanvasFileWorkspace(folder:output.appendingPathComponent("schema3-files"),requiresScope:false)
            try FileManager.default.createDirectory(at:v3Files.folder,withIntermediateDirectories:true)
            _ = try v3Files.save(projected,preview:png,expected:nil)
            let v3Restored = try v3Files.load(projected.id)
            check(v3Restored.scene == projected,"schema3 native frame rotation IDs and all kinds Files roundtrip")
            let stable = projected
            var settings = projected.effectivePenSettings; settings.width = settings.width == 4 ? 2 : 4
            _ = try projected.setPenSettings(.init(expected:projected.effectivePenSettings,settings:settings),sceneID:projected.id,baseRevision:projected.revision)
            check(projected.schemaVersion == 3 && projected.nodes == stable.nodes,"pen settings never downgrade schema3 or shape geometry")
            let drawingStore = CanvasStore(); drawingStore.scene = stable
            check(drawingStore.updateDrawing(combinedNative) && drawingStore.scene.schemaVersion == 3,
                  "general drawing preserves schema3")
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
