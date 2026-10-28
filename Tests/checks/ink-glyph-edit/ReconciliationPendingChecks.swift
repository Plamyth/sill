import Foundation
import PencilKit
import AppKit

@MainActor private final class ReconciliationEvidenceGate {
    var continuation:CheckedContinuation<CanvasInkTextEditing.Evidence,Never>?
    func read(_ drawing:PKDrawing,_ ids:Set<UUID>,_ text:String,_ others:[String])async->CanvasInkTextEditing.Evidence {
        await withCheckedContinuation {continuation=$0}
    }
    func wait()async {while continuation==nil {await Task.yield()}}
    func finish() {continuation!.resume(returning:.init(wholeText:nil,matches:[],targetText:nil,remainingText:nil,otherCharacterMatches:[]));continuation=nil}
}
@MainActor func checkPendingReconciliationEditors(_ check:(Bool,String)->Void) async throws {
    func stroke(_ points:[CGPoint])->PKStroke {
        PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points.enumerated().map {i,p in
            PKStrokePoint(location:p,timeOffset:Double(i)/100,size:CGSize(width:3,height:3),opacity:0.8,force:0.5,azimuth:0.2,altitude:1)
        },creationDate:Date(timeIntervalSince1970:1)))
    }
    let l=stroke([.init(x:10,y:20),.init(x:10,y:50)]),r=stroke([.init(x:80,y:20),.init(x:80,y:50)])
    let ink=try PKDrawing(data:PKDrawing(strokes:[l,r]).dataRepresentation())
    var scene=CanvasScene();scene.schemaVersion=3;scene.drawingBase64=ink.dataRepresentation().base64EncodedString();scene.strokes=CanvasScene.nativeInkStrokes(ink)
    scene.nodes=[.init(id:UUID(),kind:.note,frame:.init(x:10,y:100,width:260,height:120),text:"가나",confidence:.confirmed,sourceStrokeIds:[l.id,r.id])]
    let selection:Set<UUID>=[l.id,r.id]
    func make()->CanvasStore {let s=CanvasStore();s.scene=scene;s.drawing=ink;s.mode = .lasso;s.setInkSelection(selection);s.saveNow();return s}
    func evidence(_ target:String)->CanvasInkTextEditing.Evidence {
        let first=target=="가"
        return .init(wholeText:"가나",matches:[first ? [l.id]:[r.id]],targetText:target,remainingText:first ? "나":"가",otherCharacterMatches:[[first ? [r.id]:[l.id]]])
    }
    for kind in ["spacing","glyph"] {
        let s=make(),gate=ReconciliationEvidenceGate(),spacing=CanvasInkSpacingProposal(),glyph=CanvasInkTextEditing()
        let work=Task {
            if kind=="spacing" {await s.proposeInkSpacing(left:"가",right:"나",action:.split,amount:20,editing:spacing,readEvidence:gate.read)}
            else {await s.proposeInkTextDeletion(range:NSRange(location:0,length:1),editing:glyph,readEvidence:gate.read)}
        }
        await gate.wait()
        check(s.hasPendingInkProposal && !s.canApplyReconciledCanvas,"real pending "+kind+" recognition blocks reconciliation")
        spacing.invalidatePending();glyph.invalidatePending();gate.finish();await work.value
        check(!s.hasPendingInkProposal && s.canApplyReconciledCanvas && s.scene==scene,"cancelled "+kind+" late evidence cannot replace source or leave a permanent busy flag")
    }
    let spaced=make(),spacing=CanvasInkSpacingProposal()
    await spaced.proposeInkSpacing(left:"가",right:"나",action:.split,amount:20,editing:spacing,readEvidence:{_,_,target,_ in evidence(target)})
    check(spacing.proposal != nil && !spaced.canApplyReconciledCanvas,"real spacing preview blocks reconciliation")
    check(spaced.confirmInkSpacing(spacing) && spaced.canUndoGraph && spaced.canApplyReconciledCanvas,"spacing applied history remains Undo-able without permanently blocking reconciliation")
    spaced.undoGraphEdit();check(spaced.scene.nodes==scene.nodes && spaced.canRedoGraph,"common spacing Undo preserves original source after integration")
    spaced.redoGraphEdit();check(spaced.scene.nodes[0].text=="가 나" && spaced.canUndoGraph,"common spacing Redo survives client integration")
    let glyphStore=make(),glyph=CanvasInkTextEditing()
    await glyphStore.proposeInkTextDeletion(range:NSRange(location:0,length:1),editing:glyph,readEvidence:{_,_,target,_ in evidence(target)})
    check(glyph.proposal != nil && !glyphStore.canApplyReconciledCanvas,"real glyph preview blocks reconciliation")
    glyph.invalidatePending();check(glyphStore.canApplyReconciledCanvas && glyphStore.scene==scene,"closing glyph preview keeps originals and releases reconciliation")
    let corners:[CGPoint]=[.init(x:10,y:10),.init(x:100,y:10),.init(x:100,y:100),.init(x:10,y:100),.init(x:10,y:10)]
    var points:[CGPoint]=[]
    for (a,b) in zip(corners,corners.dropFirst()) {for i in 0..<25 {let t=CGFloat(i)/25;points.append(.init(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t))}}
    points.append(corners.last!)
    let box=stroke(points),drawing=PKDrawing(strokes:[box]),shape=CanvasStore()
    var shapeScene=CanvasScene();shapeScene.schemaVersion=3;shapeScene.drawingBase64=drawing.dataRepresentation().base64EncodedString();shapeScene.strokes=CanvasScene.nativeInkStrokes(drawing)
    shape.scene=shapeScene;shape.drawing=drawing;shape.mode = .lasso;shape.setInkSelection([box.id]);shape.saveNow();shape.proposeInkShape()
    check(shape.inkShapeProposal != nil && !shape.canApplyReconciledCanvas,"real native shape proposal blocks reconciliation")
    shape.cancelInkShape();check(shape.canApplyReconciledCanvas && shape.scene==shapeScene,"cancelled shape preserves original ink and releases reconciliation")
}
