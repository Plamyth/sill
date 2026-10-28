import Foundation
import PencilKit
import AppKit

@MainActor final class ProductSpacingGate {
    var waiting: CheckedContinuation<CanvasInkTextEditing.Evidence,Never>?
    func read(_ drawing: PKDrawing,_ ids: Set<UUID>,_ text: String,_ other: [String]) async -> CanvasInkTextEditing.Evidence {
        await withCheckedContinuation { waiting = $0 }
    }
    func wait() async { while waiting == nil { await Task.yield() } }
    func finish(_ evidence: CanvasInkTextEditing.Evidence) { waiting!.resume(returning:evidence);waiting = nil }
}

@main struct SpacingProductChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool,_ name: String) { precondition(condition(),name);count += 1;print("PASS \(name)") }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let output = URL(fileURLWithPath:ProcessInfo.processInfo.environment["INK_SPACING_OUTPUT"]!,isDirectory:true)
        func stroke(_ x: CGFloat, masked: Bool = false) -> PKStroke {
            let points = [CGPoint(x:x,y:20),CGPoint(x:x,y:50)].enumerated().map { i,p in
                PKStrokePoint(location:p,timeOffset:Double(i)/10,size:CGSize(width:3,height:3),opacity:0.8,force:0.5,azimuth:0.2,altitude:1)
            }
            return PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)),
                mask:masked ? NSBezierPath(rect:NSRect(x:x-5,y:20,width:10,height:18)) : nil)
        }
        let left = stroke(10),right = stroke(80),other = stroke(200,masked:true)
        let ink = try PKDrawing(data:PKDrawing(strokes:[left,right,other]).dataRepresentation())
        var original = CanvasScene();original.schemaVersion = 3;original.drawingBase64 = ink.dataRepresentation().base64EncodedString()
        original.strokes = CanvasScene.nativeInkStrokes(ink)
        original.nodes = [.init(id:UUID(),kind:.note,frame:.init(x:10,y:100,width:260,height:120),text:"가나",confidence:.confirmed,sourceStrokeIds:[left.id,right.id]),
            .init(id:UUID(),kind:.ellipse,frame:.init(x:300,y:300,width:100,height:100),text:"다른 도형",confidence:.confirmed,sourceStrokeIds:[other.id])]
        original.links = [.init(id:UUID(),from:original.nodes[0].id,to:original.nodes[1].id,label:"보존 관계")]
        let selection: Set<UUID> = [left.id,right.id]
        func evidence(_ text: String,_ whole: String = "가나") -> CanvasInkTextEditing.Evidence {
            let first = text == "가"
            return .init(wholeText:whole,matches:[first ? [left.id] : [right.id]],targetText:text,
                remainingText:first ? "나" : "가",otherCharacterMatches:[[first ? [right.id] : [left.id]]])
        }
        func store() -> CanvasStore {
            let s = CanvasStore();s.scene = original;s.drawing = ink;s.mode = .lasso;s.setInkSelection(selection);s.saveNow();return s
        }
        func propose(_ s: CanvasStore,_ e: CanvasInkSpacingProposal,action: CanvasInkSpacingProposal.Action = .split,amount: Double = 20) async {
            let text = s.scene.nodes[0].text
            await s.proposeInkSpacing(left:"가",right:"나",action:action,amount:amount,editing:e,readEvidence:{ _,_,target,_ in evidence(target,text) })
        }
        let live = store(),editing = CanvasInkSpacingProposal()
        check(live.canProposeInkSpacing,"product uniquely matched note can open spacing tool")
        await propose(live,editing)
        check(editing.proposal != nil && live.scene == original && live.drawing == ink,"product preview leaves native scene unchanged")
        let sceneURL = try CanvasRuntime.stateURL(.scene),directory = sceneURL.deletingLastPathComponent()
        let diskBefore = try Data(contentsOf:sceneURL)
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:directory.path)
        check(!live.confirmInkSpacing(editing) && editing.proposal != nil && live.scene == original && live.drawing == ink,"actual recovery IO failure retains preview and both originals")
        let failedDisk = try Data(contentsOf:sceneURL)
        check(failedDisk == diskBefore,"failed confirm preserves actual recovery file")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        check(live.confirmInkSpacing(editing),"product confirms only after successful actual persistence")
        let confirmed = live.scene
        let decoded = try PKDrawing(data:Data(base64Encoded:confirmed.drawingBase64)!)
        check(live.drawing == decoded && confirmed.nodes[0].text == "가 나" && confirmed.strokes[1].points[0].x == original.strokes[1].points[0].x+20,"confirm installs moved PKDrawing and scene together")
        check(confirmed.schemaVersion == 3 && confirmed.nodes[1] == original.nodes[1] && confirmed.links == original.links && confirmed.nodes[0].sourceStrokeIds == original.nodes[0].sourceStrokeIds,"schema3 ellipse links and source IDs preserved")
        check(confirmed.strokes[0] == original.strokes[0] && confirmed.strokes[2] == original.strokes[2] && decoded.strokes[2].mask != nil,"unselected ink transform pressure and partial mask preserved")
        check(zip(confirmed.strokes[1].points,original.strokes[1].points).allSatisfy { $0.pressure == $1.pressure },"moving native stroke keeps pressure")
        let fresh = CanvasStore()
        check(fresh.scene == confirmed && fresh.drawing == decoded,"fresh product Store reopens actual JSON and native drawing")
        print("UNDO_GATE_OBSERVATION rawSerializationEqual=\(live.drawing.dataRepresentation().base64EncodedString() == confirmed.drawingBase64) nativeEqual=\(live.drawing == decoded) projectionEqual=\(CanvasScene.nativeInkStrokes(live.drawing) == confirmed.strokes) phasePending=\(editing.hasPendingWork) busy=\(live.inkBusy) file=\(live.fileWorkspaceState)")
        check(live.canUndoGraph,"spacing uses existing graph Undo entry")
        live.scene.nodes[1].text = confirmed.nodes[1].text.decomposedStringWithCanonicalMapping
        check(!live.canUndoGraph,"Undo refuses exact UTF8 source change despite canonical string equality")
        live.scene = confirmed;live.scene.revision += 1
        check(!live.canUndoGraph,"Undo refuses changed source revision with identical content")
        live.scene = confirmed;live.drawing = PKDrawing()
        check(!live.canUndoGraph,"Undo refuses drawing scene divergence")
        live.drawing = decoded;live.scene.revision = Int.max
        check(!live.canUndoGraph,"Undo refuses revision overflow")
        live.scene = confirmed
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:directory.path)
        live.undoGraphEdit()
        check(live.scene == confirmed && live.drawing == decoded && live.canUndoGraph,"common Undo IO failure leaves installed drawing and history unchanged")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        live.undoGraphEdit()
        check(live.scene.drawingBase64 == original.drawingBase64 && live.scene.nodes == original.nodes && live.drawing == ink && live.canRedoGraph,"existing Undo restores original ink and text together")
        live.redoGraphEdit()
        check(live.scene.drawingBase64 == confirmed.drawingBase64 && live.drawing == decoded && live.scene.revision > confirmed.revision,"existing Redo restores candidate native bytes with monotonic revision")
        let reopenedRedo = CanvasStore()
        check(reopenedRedo.scene == live.scene && reopenedRedo.drawing == live.drawing,"fresh Store reopens persisted Redo")
        live.setInkSelection(selection)
        let join = CanvasInkSpacingProposal();await propose(live,join,action:.join,amount:10)
        check(join.proposal != nil && live.confirmInkSpacing(join) && live.scene.nodes[0].text == "가나" && live.scene.strokes[1].points[0].x == original.strokes[1].points[0].x+10,"product join shrinks only confirmed gap")
        for risk in ["math-input","pencil","wrong-mode","duplicate-note","fractional","nil-evidence"] {
            let s = store(),e = CanvasInkSpacingProposal();var calls = 0
            if risk == "math-input" { s.inkMathInputBusy = true }
            if risk == "pencil" { s.setPencilTraceActive(true,owner:UUID()) }
            if risk == "wrong-mode" { s.mode = .select }
            if risk == "duplicate-note" { var n = original.nodes[0];n.id = UUID();s.scene.nodes.append(n) }
            let before = s.scene
            await s.proposeInkSpacing(left:"가",right:"나",action:.split,amount:risk == "fractional" ? 1.1 : 20,editing:e,readEvidence:{ _,_,target,_ in
                calls += 1
                return risk == "nil-evidence" ? .init(wholeText:nil,matches:[],targetText:nil,remainingText:nil,otherCharacterMatches:[]) : evidence(target)
            })
            check(e.proposal == nil && s.scene == before && s.drawing == ink && (risk == "nil-evidence" || calls == 0),"product refuses \(risk) preserving originals")
            s.saveNow()
        }
        for change in ["scene-ABA","selection-ABA","mode-ABA","pencil","cancel","task-cancel","math-start","glyph-start","shape-start"] {
            let s = store(),e = CanvasInkSpacingProposal(),gate = ProductSpacingGate()
            let task = Task { await s.proposeInkSpacing(left:"가",right:"나",action:.split,amount:20,editing:e,readEvidence:gate.read) }
            await gate.wait()
            switch change {
            case "scene-ABA": s.scene.revision += 1;s.scene = original
            case "selection-ABA": s.setInkSelection([]);s.setInkSelection(selection)
            case "mode-ABA": s.mode = .pen;s.mode = .lasso;s.setInkSelection(selection)
            case "pencil": let owner=UUID();s.setPencilTraceActive(true,owner:owner);s.setPencilTraceActive(false,owner:owner)
            case "task-cancel": task.cancel()
            case "math-start": await s.proposeInkMath { _ in nil };s.cancelInkMath()
            case "glyph-start":
                let glyph = CanvasInkTextEditing()
                await s.proposeInkTextDeletion(range:NSRange(location:0,length:1),editing:glyph,readEvidence:{ _,_,_,_ in .init(wholeText:nil,matches:[],targetText:nil,remainingText:nil,otherCharacterMatches:[]) })
            case "shape-start": s.proposeInkShape();s.cancelInkShape()
            default: e.cancel()
            }
            gate.finish(evidence("가"));await task.value
            check(e.proposal == nil && !e.hasPendingWork && !s.confirmInkSpacing(e) && s.scene == original,"product late callback after \(change) cannot confirm")
            s.saveNow()
        }
        let graph = store(),unselected = graph.scene.nodes[1]
        graph.mode = .select;graph.selectedNode = unselected.id
        check(graph.rotateNode(unselected,sceneID:graph.scene.id,to:30),"existing shape graph edit still available")
        graph.undoGraphEdit();check(graph.scene.nodes == original.nodes && graph.drawing == ink,"ordinary graph Undo keeps native ink unchanged")
        graph.redoGraphEdit();check(graph.scene.nodes[1].rotationDegrees == 30 && graph.drawing == ink,"ordinary graph Redo remains unchanged")

        let folder = output.appendingPathComponent("selected-files",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        let files = CanvasFileWorkspace(folder:folder,requiresScope:false)
        _ = try files.save(original,preview:png,expected:nil)
        let binding = CanvasFileWorkspace.Binding(bookmark:try folder.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil),sceneID:original.id,savedSceneSHA:try CanvasFileWorkspace.sceneSHA(original))
        try CanvasLocalFile.write(CanvasFileWorkspace.bytes(original),to:sceneURL)
        try CanvasLocalFile.write(JSONEncoder().encode(binding),to:CanvasRuntime.stateURL(.workspace))
        let actual = CanvasStore();actual.filePreview = { _ in png };actual.mode = .lasso;actual.setInkSelection(selection)
        let fileEdit = CanvasInkSpacingProposal();await propose(actual,fileEdit)
        check(actual.confirmInkSpacing(fileEdit) && !actual.fileWorkspaceCanSync,"product confirm marks selected Files original pending")
        await actual.saveFileWorkspace()
        let saved = try files.load(original.id)
        check(saved.scene == actual.scene && actual.fileWorkspaceCanSync,"actual selected folder source generation roundtrip")
        let newStore = CanvasStore()
        check(newStore.scene == actual.scene && newStore.drawing == actual.drawing,"new Store reopens Files-bound spacing")
        actual.undoGraphEdit();await actual.saveFileWorkspace()
        let undone = try files.load(original.id)
        check(undone.scene.drawingBase64 == original.drawingBase64 && undone.scene.nodes == original.nodes && undone.scene.schemaVersion == 3,"common spacing Undo persists original Files ink text and schema3")
        let revisions = files.documentURL(original.id).appendingPathComponent("revisions"),head = files.documentURL(original.id).appendingPathComponent("current.json")
        let oldHead = try Data(contentsOf:head)
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:revisions.path)
        actual.redoGraphEdit();await actual.saveFileWorkspace()
        let failedHead = try Data(contentsOf:head)
        check(actual.fileWorkspaceState == .blocked && !actual.fileWorkspaceCanSync && oldHead == failedHead,"actual Files IO failure preserves original pointer and marks unsaved")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:revisions.path)
        actual.retryFileWorkspaceSave();await actual.saveFileWorkspace()
        let retried = try files.load(original.id)
        check(actual.fileWorkspaceCanSync && retried.scene == actual.scene && retried.scene.drawingBase64 == saved.scene.drawingBase64,"existing retry saves same spacing Redo source")
        actual.undoGraphEdit()
        var external = retried.scene;external.revision += 1;external.nodes[1].text = "외부에서 바꾼 도형"
        _ = try files.save(external,preview:png,expected:retried.token)
        await actual.saveFileWorkspace()
        let protected = try files.load(original.id)
        check(actual.fileWorkspaceState == .blocked && protected.scene == external,"existing Files CAS protects external original from pending Undo")
        print("INK_SPACING_PRODUCT_CHECKS_OK \(count); success mapping injected; no native recognition or Pencil acceptance")
    }
}
