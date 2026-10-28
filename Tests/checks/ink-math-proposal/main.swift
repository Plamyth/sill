import Foundation
import PencilKit
import CryptoKit
#if os(macOS)
import AppKit
#endif

@MainActor final class MathGate {
    var input: PKDrawing?
    var continuation: CheckedContinuation<String?,Never>?
    func recognize(_ drawing: PKDrawing) async -> String? {
        input = drawing
        return await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { while input == nil { await Task.yield() } }
    func finish(_ value: String?) { continuation!.resume(returning:value); continuation = nil }
}

@main struct MathChecks {
    static var count = 0
    static func check(_ pass: @autoclosure () -> Bool, _ label: String) {
        precondition(pass(),label); count += 1; print("PASS \(label)")
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("accepted \(label)") }
        catch { check(true,label) }
    }
    static func stroke(_ x: CGFloat, masked: Bool = false) -> PKStroke {
        let points = [CGPoint(x:x,y:20),CGPoint(x:x+20,y:50)].enumerated().map { i,p in
            PKStrokePoint(location:p,timeOffset:Double(i)*0.1,size:CGSize(width:3,height:3),opacity:1,
                force:0.5,azimuth:0,altitude:1)
        }
        return PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)),
            transform:CGAffineTransform(translationX:5,y:10),mask:masked ? NSBezierPath(rect:NSRect(x:x,y:20,width:15,height:30)) : nil)
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        check(support.path.hasPrefix(home+"/"),"isolated fixture files only")
        if !CommandLine.arguments.contains("--integration-only") {
        let positive = ["1+1=":"2","1+2":"3","2+3*4":"14","(2+3)*4":"20","0.1+0.2":"0.3", "1÷4":"0.25",
            "(1+2)/2":"1.5","-2*-3":"6","2−5":"-3","6×7":"42",".5+.25":"0.75","1.20+2.30":"3.5",
            "8/4/2":"1","10-3-2":"5","(-1+2)*(3+4)":"7","0*999":"0","1 + 1 =":"2"]
        for (expression,result) in positive {
            let actual = try CanvasInkMathProposal.calculate(expression)
            check(actual.result == result,"exact Decimal \(expression)=\(result)")
        }
        for expression in ["", "=", "1+z", "O+1", "1l+2", "1,2+3", "１２+1", "1 2+3", "1..2", "NaN", "Infinity",
            "sqrt(4)", "2^3", "2(3)", "1+1=2", "a=2", "1/0", "1/(2-2)", "(1+2", "1+2)","1e3","1/3",
            String(repeating:"9",count:29),String(repeating:"(",count:17)+"1"+String(repeating:")",count:17),String(repeating:"1",count:257),
            Array(repeating:String(repeating:"9",count:28),count:6).joined(separator:"*")] {
            rejects("reject unsupported/unsafe expression \(expression.prefix(32))") { _ = try CanvasInkMathProposal.calculate(expression) }
        }
        }
        let selected = stroke(10), other = stroke(200), masked = stroke(300,masked:true)
        let ink = PKDrawing(strokes:[selected,other,masked])
        @MainActor func store() -> CanvasStore {
            let s = CanvasStore(); s.scene = CanvasScene(); s.drawing = PKDrawing()
            precondition(s.updateDrawing(ink))
            s.scene.nodes = [.init(id:UUID(),kind:.note,frame:.init(x:600,y:400,width:100,height:100),text:"다른 메모",confidence:.confirmed,sourceStrokeIds:[])]
            s.mode = .lasso; s.setInkSelection([selected.id]); s.saveNow(); return s
        }
        let s = store(), before = s.scene
        await s.proposeInkMath { drawing in
            check(drawing.strokes.map(\.id) == [selected.id],"recognizer gets selected native strokes only")
            return "1+z="
        }
        check(s.scene == before && s.inkMathProposal?.recognizedText == "1+z=","raw OCR preserved without committing")
        check(!s.confirmInkMath() && s.scene == before,"ambiguous recognized variable not confirmed")
        s.inkMathDraft = "1+2"
        s.inkMathInputBusy = true; check(!s.confirmInkMath() && s.scene == before,"IME and Scribble busy block confirm")
        s.inkMathInputBusy = false
        let maskedProposal = try CanvasInkMathProposal.capture(scene:before,drawing:s.drawing,selection:[masked.id],recognized:"1+1")
        let maskedConfirmed = try maskedProposal.confirmed(in:before,selection:[masked.id],expression:"1+1")
        check(maskedProposal.original.strokes.first?.mask != nil && maskedConfirmed.drawingBase64 == before.drawingBase64 && maskedConfirmed.nodes.last?.sourceStrokeIds == [masked.id],"selected partial mask preserved without replacing source")
        let hash = SHA256.hash(data:Data(base64Encoded:before.drawingBase64)!)
        check(s.confirmInkMath(),"explicit corrected expression confirmation")
        let after = s.scene
        check(after.nodes.last?.kind == .note && after.nodes.last?.sourceStrokeIds == [selected.id],"existing note wire kind and source IDs")
        check(after.nodes.last!.text.contains("1+z=") && after.nodes.last!.text.contains("1+2 = 3"),"raw candidate corrected expression and answer readable in note")
        check(after.nodes.first == before.nodes.first && after.strokes == before.strokes && after.drawingBase64 == before.drawingBase64,
            "other node ink pressure mask and transform unchanged")
        check(SHA256.hash(data:Data(base64Encoded:after.drawingBase64)!) == hash && after.schemaVersion == before.schemaVersion,"native hash and schema unchanged")
        check(!s.confirmInkMath(),"second confirmation not duplicated")
        s.undoGraphEdit(); check(s.scene.nodes == before.nodes && s.scene.strokes == before.strokes,"graph undo preserves original ink")
        s.redoGraphEdit(); check(s.scene.nodes == after.nodes && s.scene.drawingBase64 == before.drawingBase64,"graph redo preserves original ink")
        s.saveNow()
        let reopened = CanvasStore()
        check(reopened.scene == s.scene && reopened.drawing == s.drawing,"actual JSON and fresh Store reopen")
        for action in ["cancel","selection","scene","mode","drawing"] {
            let current = store(), gate = MathGate()
            let task = Task { await current.proposeInkMath(recognize:gate.recognize) }
            await gate.wait()
            switch action {
            case "cancel": current.cancelInkMath()
            case "selection": current.setInkSelection([]); current.setInkSelection([selected.id])
            case "scene": current.scene = current.scene
            case "mode": current.mode = .pen; current.mode = .lasso
            default: _ = current.updateDrawing(PKDrawing(strokes:[other]))
            }
            let frozen = current.scene
            gate.finish("1+1"); await task.value
            check(current.inkMathProposal == nil && current.scene == frozen,"late recognition discarded after \(action)")
        }
        let cancel = store(); await cancel.proposeInkMath { _ in "1+1" }
        let frozen = cancel.scene; cancel.cancelInkMath()
        check(!cancel.confirmInkMath() && cancel.scene == frozen,"cancel preview no scene mutation")
        let stale = store(); await stale.proposeInkMath { _ in "1+1" }
        stale.scene = stale.scene
        check(!stale.confirmInkMath(),"preview scene generation ABA rejected")
        let nilCase = store(); await nilCase.proposeInkMath { _ in nil }
        check(nilCase.inkMathProposal?.recognizedText == nil && nilCase.inkMathProposal != nil,"injected nil remains no OCR candidate")
        nilCase.inkMathDraft = "(1+1)/2"
        check(nilCase.confirmInkMath(),"manual correction supported after nil without claiming OCR success")
        let schema = store(); var v3 = schema.scene; v3.schemaVersion = 3
        do {
            let proposal = try CanvasInkMathProposal.capture(scene:v3,drawing:schema.drawing,selection:schema.inkSelection,recognized:"1+1")
            let accepted = try proposal.confirmed(in:v3,selection:proposal.selection,expression:"1+1")
            check(accepted.schemaVersion == 3,"supported schema3 never downgraded")
        } catch CanvasPenSettingsError.unsupportedInkProjection {
            check(v3.schemaVersion == 3,"baseline unsupported schema3 refused without downgrade")
            print("SCHEMA3_BASELINE_UNSUPPORTED")
        }
        if CommandLine.arguments.contains("--native") {
        let native = store()
        await native.proposeInkMath()
        print("NATIVE_RECOGNITION_RESULT \(native.inkMathProposal?.recognizedText.map { String(reflecting:$0) } ?? "nil")")
        check(native.scene.nodes.count == 1,"real recognizer does not silently confirm")
        native.cancelInkMath()
        } else { print("NATIVE_RECOGNITION_SKIPPED preserved producer nil; not a success") }
        let failed = store(); await failed.proposeInkMath { _ in "1+1" }
        let old = failed.scene, oldProposal = failed.inkMathProposal?.id
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:support.path)
        check(!failed.confirmInkMath() && failed.scene == old && failed.inkMathProposal?.id == oldProposal,
              "cache write failure preserves scene and editable candidate")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:support.path)
        check(failed.confirmInkMath(),"same explicit candidate retry after cache IO failure")
        for action in ["trace","drawingABA"] {
            let current = store(), gate = MathGate()
            let task = Task { await current.proposeInkMath(recognize:gate.recognize) }; await gate.wait()
            if action == "trace" {
                let owner = UUID(); current.setPencilTraceActive(true,owner:owner); current.setPencilTraceActive(false,owner:owner)
            } else { let drawing = current.drawing; current.drawing = drawing; current.setInkSelection([selected.id]) }
            gate.finish("1+1"); await task.value
            check(current.inkMathProposal == nil,"late math callback rejects trace/drawing ABA \(action)")
        }
        let cross = store(); await cross.proposeInkMath { _ in nil }; cross.inkMathDraft = "1+2"
        let mathID = cross.inkMathProposal?.id; cross.inkMathInputBusy = true
        cross.proposeInkShape()
        let editing = CanvasInkTextEditing()
        await cross.proposeInkTextDeletion(range:NSRange(location:0,length:1),editing:editing)
        check(cross.inkMathProposal?.id == mathID && cross.inkMathDraft == "1+2" && cross.inkShapeProposal == nil,
              "glyph/shape actions cannot discard active math input")
        cross.inkMathInputBusy = false; cross.proposeInkShape()
        check(cross.inkMathProposal == nil,"new shape action cancels stale math request")
        failed.saveNow(); nilCase.saveNow(); stale.saveNow()
        if let outputPath = ProcessInfo.processInfo.environment["INK_MATH_OUTPUT"] {
            let output = URL(fileURLWithPath:outputPath,isDirectory:true)
            let folder = output.appendingPathComponent("selected-files",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
            var original = before; original.schemaVersion = 3
            let files = CanvasFileWorkspace(folder:folder,requiresScope:false)
            _ = try files.save(original,preview:png,expected:nil)
            let binding = CanvasFileWorkspace.Binding(bookmark:try folder.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil),sceneID:original.id,savedSceneSHA:try CanvasFileWorkspace.sceneSHA(original))
            try CanvasLocalFile.write(CanvasFileWorkspace.bytes(original),to:CanvasRuntime.stateURL(.scene))
            try CanvasLocalFile.write(JSONEncoder().encode(binding),to:CanvasRuntime.stateURL(.workspace))
            let actual = CanvasStore(); actual.filePreview = { _ in png }; actual.mode = .lasso; actual.setInkSelection([selected.id])
            await actual.proposeInkMath { _ in nil }
            check(actual.inkMathProposal != nil && actual.inkMathProposal?.recognizedText == nil && actual.inkMathDraft.isEmpty,"nil stays absent and requires manual correction")
            actual.inkMathDraft = "(1+2)/2"
            check(actual.confirmInkMath() && actual.scene.schemaVersion == 3 && !actual.fileWorkspaceCanSync && actual.status.contains("미저장"),"actual math note cache confirmation keeps scene3 and Files pending")
            let confirmed = actual.scene
            check(confirmed.drawingBase64 == original.drawingBase64 && confirmed.strokes == original.strokes && confirmed.nodes.dropLast() == original.nodes[...],"actual math raw ink mask pressure transform and neighbors preserved")
            await actual.saveFileWorkspace()
            let loaded = try files.load(original.id)
            check(loaded.scene == confirmed && actual.fileWorkspaceCanSync,"actual Files source save and complete readback")
            let fresh = CanvasStore(); check(fresh.scene == confirmed && fresh.drawing == actual.drawing,"fresh Store reopens scene3 math and native ink")
            actual.undoGraphEdit(); actual.saveNow(); await actual.saveFileWorkspace()
            let undone = try files.load(original.id)
            check(undone.scene.nodes == original.nodes && undone.scene.schemaVersion == 3 && undone.scene.drawingBase64 == original.drawingBase64,"math Undo actual Files roundtrip preserves schema and raw ink")
            let revisions = files.documentURL(original.id).appendingPathComponent("revisions")
            let current = files.documentURL(original.id).appendingPathComponent("current.json")
            let oldHead = try Data(contentsOf:current)
            try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:revisions.path)
            actual.redoGraphEdit(); actual.saveNow(); await actual.saveFileWorkspace()
            let failedHead = try Data(contentsOf:current)
            check(actual.fileWorkspaceState == .blocked && !actual.fileWorkspaceCanSync && actual.fileWorkspaceStatus.contains("미저장") && failedHead == oldHead,"Files failure never claims saved and preserves original pointer")
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:revisions.path)
            actual.retryFileWorkspaceSave(); await actual.saveFileWorkspace()
            let redone = try files.load(original.id)
            check(actual.fileWorkspaceCanSync && redone.scene.nodes == confirmed.nodes && redone.scene.schemaVersion == 3,"same original retry and Redo source readback")
            actual.undoGraphEdit()
            var external = redone.scene; external.revision += 1; external.nodes[0].text = "별도 외부 변경"
            _ = try files.save(external,preview:png,expected:redone.token)
            await actual.saveFileWorkspace()
            let untouched = try files.load(original.id)
            check(actual.fileWorkspaceState == .blocked && !actual.fileWorkspaceCanSync && untouched.scene == external,"Files CAS rejects pending math Undo without overwriting external original")
            let draft = actual.inkMathDraft
            await actual.proposeInkMath { _ in preconditionFailure("blocked original must not recognize") }
            check(actual.inkMathProposal == nil && actual.inkMathDraft == draft,"blocked Files preserves math draft and refuses a new request")
            try CanvasFileWorkspace.bytes(original).write(to:output.appendingPathComponent("math-before.json"))
            try CanvasFileWorkspace.bytes(confirmed).write(to:output.appendingPathComponent("math-after.json"))
            try CanvasFileWorkspace.bytes(undone.scene).write(to:output.appendingPathComponent("math-undo.json"))
        }
        print("MATH_CHECKS_OK \(count)")
    }
}
