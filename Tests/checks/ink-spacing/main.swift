import Foundation
import PencilKit
#if os(macOS)
import AppKit
#endif

@MainActor final class SpacingGate {
    var input: PKDrawing?
    var continuation: CheckedContinuation<CanvasInkTextEditing.Evidence,Never>?
    func read(_ drawing: PKDrawing,_ ids: Set<UUID>,_ target: String,_ other: [String]) async -> CanvasInkTextEditing.Evidence {
        input = drawing;return await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { while input == nil { await Task.yield() } }
    func finish(_ value: CanvasInkTextEditing.Evidence) { continuation!.resume(returning:value);continuation = nil }
}
@main struct SpacingChecks {
    static var count = 0
    static func check(_ pass: @autoclosure () -> Bool,_ label: String) { precondition(pass(),label);count += 1;print("PASS \(label)") }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        check(support.path.hasPrefix(home+"/"),"isolated own files")
        func stroke(_ x: CGFloat,_ y: CGFloat = 20,mask: Bool = false,rotation: Bool = false) -> PKStroke {
            let points = [CGPoint(x:x,y:y),CGPoint(x:x,y:y+30)].enumerated().map { i,p in
                PKStrokePoint(location:p,timeOffset:Double(i)/10,size:CGSize(width:3,height:3),opacity:0.8,force:0.5,azimuth:0.2,altitude:1)
            }
            return PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)),
                transform:rotation ? CGAffineTransform(rotationAngle:0.3) : .identity,
                mask:mask ? NSBezierPath(rect:NSRect(x:x-5,y:y,width:10,height:18)) : nil)
        }
        let left = stroke(10), right = stroke(80), other = stroke(200,mask:true)
        let input = PKDrawing(strokes:[left,right,other])
        let movedAPI = PKDrawing(strokes:[right]).transformed(using:CGAffineTransform(translationX:20,y:0))
        var setter = right;setter.transform = setter.transform.concatenating(CGAffineTransform(translationX:20,y:0))
        print("TRANSFORM_ID_OBSERVATION drawingTransformedStable=\(movedAPI.strokes.map(\.id)==[right.id]) strokeSetterStable=\(setter.id==right.id)")
        check(setter.id == right.id,"chosen transform setter keeps native stroke ID")
        func scene(_ ink: PKDrawing = input,text: String = "가나") throws -> CanvasScene {
            var s = CanvasScene();s.schemaVersion = 3;s.drawingBase64 = ink.dataRepresentation().base64EncodedString()
            s.strokes = CanvasScene.nativeInkStrokes(try PKDrawing(data:Data(base64Encoded:s.drawingBase64)!))
            s.nodes = [.init(id:UUID(),kind:.note,frame:.init(x:10,y:100,width:260,height:120),text:text,confidence:.confirmed,sourceStrokeIds:[left.id,right.id]),
                .init(id:UUID(),kind:.box,frame:.init(x:300,y:300,width:100,height:100),text:"다른 노드",confidence:.confirmed,sourceStrokeIds:[other.id])]
            s.links = [.init(id:UUID(),from:s.nodes[0].id,to:s.nodes[1].id,label:"보존 관계")]
            return s
        }
        func evidence(_ source: CanvasScene,_ target: String) -> CanvasInkTextEditing.Evidence {
            let first = target == "가"
            return .init(wholeText:source.nodes[0].text,matches:[first ? [left.id] : [right.id]],targetText:target,
                remainingText:first ? "나" : "가",otherCharacterMatches:[[first ? [right.id] : [left.id]]])
        }
        let original = try scene(), selection: Set<UUID> = [left.id,right.id]
        let edit = CanvasInkSpacingProposal()
        await edit.propose(scene:original,nodeID:original.nodes[0].id,selection:selection,left:"가",right:"나",action:.split,amount:20,
            isCurrent:{ $0.matches(scene:original,selection:selection) },readEvidence:{ _,_,target,_ in evidence(original,target) })
        if case .refused(let reason) = edit.phase { print("FIRST_REFUSAL \(reason)") }
        check(edit.proposal != nil,"injected unique two-group split yields native preview")
        let proposal = edit.proposal!
        check(proposal.before == original && proposal.snapshot.drawingSHA256 == CanvasPacket.sha(Data(base64Encoded:original.drawingBase64)!),"snapshot retains exact scene revision and native hash")
        check(proposal.leftIDs == [left.id] && proposal.rightIDs == [right.id] && proposal.delta == 20,"two exact native groups not bbox classification")
        let blocker = support.appendingPathComponent("own-IO-blocker",isDirectory:true)
        try FileManager.default.createDirectory(at:blocker,withIntermediateDirectories:true)
        do { _ = try edit.confirm(current:original,selection:selection,persist:{ try CanvasLocalFile.write(CanvasInkTextEditing.encode($0),to:blocker) });preconditionFailure() } catch { }
        check(edit.proposal != nil && proposal.before == original,"actual IO failure keeps preview and original")
        let sceneURL = try CanvasRuntime.stateURL(.scene)
        var after = try edit.confirm(current:original,selection:selection,persist:{ try CanvasLocalFile.write(CanvasInkTextEditing.encode($0),to:sceneURL) })
        check(after.nodes[0].text == "가 나" && after.nodes[0].sourceStrokeIds == original.nodes[0].sourceStrokeIds,"split changes source ink and note spacing preserving source IDs")
        check(after.schemaVersion == 3 && after.nodes[1] == original.nodes[1] && after.links == original.links,"schema3 other nodes and relations unchanged")
        check(after.strokes.map(\.id) == original.strokes.map(\.id),"all IDs and stroke order preserved after serialization")
        for (before,new) in zip(original.strokes,after.strokes) {
            let delta = before.id == right.id ? 20.0 : 0
            check(zip(before.points,new.points).allSatisfy { $0.pressure == $1.pressure && abs($1.x-$0.x-delta)<0.001 && $1.y==$0.y },"native movement affects only right world x and preserves pressure")
        }
        let nativeAfter = try PKDrawing(data:Data(base64Encoded:after.drawingBase64)!)
        check(nativeAfter.strokes[2].mask != nil && nativeAfter.strokes[0].transform == left.transform,"unselected partial mask and left transform preserved")
        let reopened = CanvasStore()
        check(reopened.scene == after && reopened.drawing == nativeAfter,"actual JSON and fresh Store reopen moved native ink")
        after = try edit.undo(current:after,persist:{ try CanvasLocalFile.write(CanvasInkTextEditing.encode($0),to:sceneURL) })
        check(after.drawingBase64 == original.drawingBase64 && after.nodes == original.nodes && after.schemaVersion == 3,"undo restores exact original native bytes text IDs version")
        after = try edit.redo(current:after,persist:{ try CanvasLocalFile.write(CanvasInkTextEditing.encode($0),to:sceneURL) })
        check(after.drawingBase64 == proposal.after.drawingBase64 && after.nodes[0].text == "가 나","redo restores exact candidate bytes")
        let join = CanvasInkSpacingProposal()
        await join.propose(scene:after,nodeID:after.nodes[0].id,selection:selection,left:"가",right:"나",action:.join,amount:10,
            isCurrent:{ $0.matches(scene:after,selection:selection) },readEvidence:{ _,_,target,_ in evidence(after,target) })
        check(join.proposal?.delta == -10,"join reduces only confirmed group gap by explicit amount")
        let joined = try join.confirm(current:after,selection:selection,persist:{ _ in })
        check(joined.nodes[0].text == "가나" && joined.strokes[1].points[0].x == original.strokes[1].points[0].x+10,"join moves right original ink rather than only UITextView text")
        for risk in ["duplicate","shared-group","extra-selection","mask","other-node-reference","rotation","affine-rotation","multiline","overlap","amount","overshoot","nil"] {
            var s = original;var ink = input;var ids = selection;var amount = 20.0
            var action = CanvasInkSpacingProposal.Action.split
            if risk == "mask" { ink = PKDrawing(strokes:[left,PKStroke(ink:right.ink,path:right.path,mask:NSBezierPath(rect:NSRect(x:75,y:20,width:10,height:18)),id:right.id),other]) }
            if risk == "rotation" { s.nodes[0].rotationDegrees = 30 }
            if risk == "affine-rotation" {
                var rotated = right;rotated.transform = CGAffineTransform(rotationAngle:0.2)
                ink = PKDrawing(strokes:[left,rotated,other])
            }
            if risk == "multiline" { ink = PKDrawing(strokes:[left,PKStroke(ink:right.ink,path:stroke(80,120).path,id:right.id),other]) }
            if risk == "overlap" { ink = PKDrawing(strokes:[left,PKStroke(ink:right.ink,path:stroke(11).path,id:right.id),other]) }
            if risk == "other-node-reference" { s.nodes[1].sourceStrokeIds.append(right.id) }
            if risk == "extra-selection" { ids.insert(other.id);s.nodes[0].sourceStrokeIds.append(other.id);s.nodes[1].sourceStrokeIds=[] }
            if risk == "amount" { amount = .nan }
            if risk == "overshoot" { amount = 512;action = .join;s.nodes[0].text="가 나" }
            s.drawingBase64 = ink.dataRepresentation().base64EncodedString();s.strokes=CanvasScene.nativeInkStrokes(try PKDrawing(data:Data(base64Encoded:s.drawingBase64)!))
            let frozen = s, current = ids, target = CanvasInkSpacingProposal()
            await target.propose(scene:s,nodeID:s.nodes[0].id,selection:ids,left:"가",right:"나",action:action,amount:amount,
                isCurrent:{ $0.matches(scene:frozen,selection:current) },readEvidence:{ _,_,text,_ in
                    let e = evidence(frozen,text)
                    if risk == "duplicate" { return .init(wholeText:e.wholeText,matches:e.matches+e.matches,targetText:e.targetText,remainingText:e.remainingText,otherCharacterMatches:e.otherCharacterMatches) }
                    if risk == "shared-group" { return .init(wholeText:e.wholeText,matches:[[left.id]],targetText:e.targetText,remainingText:e.remainingText,otherCharacterMatches:e.otherCharacterMatches) }
                    if risk == "nil" { return .init(wholeText:nil,matches:[],targetText:nil,remainingText:nil,otherCharacterMatches:[]) }
                    return e
                })
            check(target.proposal == nil,"refuse risky \(risk) without changing source")
        }
        let live = CanvasStore();live.scene = original;live.drawing = input;live.mode = .lasso;live.setInkSelection(selection)
        let liveEdit = CanvasInkSpacingProposal()
        await live.proposeInkSpacing(left:"가",right:"나",action:.split,amount:20,editing:liveEdit,readEvidence:{ _,_,text,_ in evidence(original,text) })
        check(liveEdit.proposal != nil && live.confirmInkSpacing(liveEdit),"real Store candidate persistence and native install integration")
        check(live.undoInkSpacing(liveEdit) && live.scene.drawingBase64 == original.drawingBase64,"Store raw ink undo")
        check(live.undoInkSpacing(liveEdit,redo:true) && live.scene.schemaVersion == 3,"Store raw ink redo retains3")
        for change in ["scene","selection","mode","pencil","cancel","task-cancel"] {
            let store = CanvasStore();store.scene = original;store.drawing = input;store.mode = .lasso;store.setInkSelection(selection)
            let editor = CanvasInkSpacingProposal(),gate = SpacingGate()
            let task = Task { await store.proposeInkSpacing(left:"가",right:"나",action:.split,amount:20,editing:editor,readEvidence:gate.read) }
            await gate.wait()
            switch change {
            case "scene": let old = store.scene;store.scene = CanvasScene();store.scene = old;store.setInkSelection(selection)
            case "selection": store.setInkSelection([]);store.setInkSelection(selection)
            case "mode": store.mode = .select;store.mode = .lasso;store.setInkSelection(selection)
            case "pencil": let id=UUID();store.setPencilTraceActive(true,owner:id);store.setPencilTraceActive(false,owner:id)
            case "task-cancel": task.cancel()
            default: editor.cancel()
            }
            gate.finish(evidence(original,"가"));await task.value
            check(editor.proposal == nil && !editor.hasPendingWork && store.scene == original,"late native evidence after \(change) ABA/cancel discarded")
        }
        let native = CanvasInkSpacingProposal()
        await native.propose(scene:original,nodeID:original.nodes[0].id,selection:selection,left:"가",right:"나",action:.split,amount:20,isCurrent:{ $0.matches(scene:original,selection:selection) })
        if case .refused(let reason) = native.phase { print("NATIVE_SPACING_RESULT_REFUSED \(reason)") } else { print("NATIVE_SPACING_RESULT_HAS_PREVIEW \(native.proposal != nil)") }
        check(original.drawingBase64 == proposal.before.drawingBase64,"native probe never auto confirms")
        print("INK_SPACING_CHECKS_OK \(count)")
    }
}
