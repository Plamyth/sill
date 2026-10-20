import Foundation
import PencilKit

@main struct StoreChecks {
    @MainActor static func main() throws {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]! + "/"))
        let out = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PELE_OUTPUT"]!)
        let store = CanvasStore(blockRecoveryURL:out.appendingPathComponent("recovery.json"))
        store.scene = CanvasScene()
        let drawing = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.white),
            path:PKStrokePath(controlPoints:[PKStrokePoint(location:CGPoint(x:15,y:20),timeOffset:0,
                size:CGSize(width:3,height:3),opacity:1,force:0.7,azimuth:0,altitude:1)],creationDate:Date()))])
        store.updateDrawing(drawing)
        store.addNode(.box)
        let id = store.selectedNode!
        let originalNode = store.scene.nodes[0]
        let raw = store.scene.drawingBase64
        let change = AgentRevision(sceneId:store.scene.id,baseRevision:store.scene.revision,
            annotations:[],proposedNodes:[],nodeEdits:[.init(expected:originalNode,text:"에이전트가 수정한 문장")])
        precondition(store.applyAgentRevision(change))
        precondition(store.scene.nodes[0].id == id && store.scene.nodes[0].text == "에이전트가 수정한 문장")
        store.saveNow()
        let reopened = CanvasStore(blockRecoveryURL:out.appendingPathComponent("recovery.json"))
        precondition(reopened.scene.nodes == store.scene.nodes && reopened.scene.drawingBase64 == raw)
        precondition(reopened.drawing.strokes.map(\.id) == drawing.strokes.map(\.id))
        precondition(reopened.drawing.bounds == drawing.bounds)
        try JSONEncoder().encode(reopened.scene).write(to:out.appendingPathComponent("store-scene.json"))
        let revision = store.scene.revision
        precondition(store.applyAgentRevision(change) && store.scene.revision == revision)
        var stale = change
        stale.nodeEdits![0].text = "오래된 덮어쓰기"
        precondition(!store.applyAgentRevision(stale) && store.scene.revision == revision)
        let later = PKDrawing(strokes:drawing.strokes + drawing.strokes)
        store.updateDrawing(later)
        let laterRaw = store.scene.drawingBase64
        precondition(store.canUndoGraph)
        store.undoGraphEdit()
        precondition(store.scene.nodes[0].text == originalNode.text && store.scene.drawingBase64 == laterRaw)
        precondition(store.drawing.strokes.map(\.id) == later.strokes.map(\.id))
        store.proposedNode = id
        store.proposalText = "Pencil·키보드 편집 계약"
        store.confirmProposal()
        precondition(store.scene.nodes[0].text == "Pencil·키보드 편집 계약" && store.canUndoGraph)
        let snapshot = try CanvasDiagramSnapshot(scene:store.scene)
        precondition(snapshot.source.contains("Pencil"))
        print("PASS 실제 Store의 AI 수정→저장→새 Store 복원, 재수신·오래된 거부, 공통 텍스트 편집, Undo 뒤 새 Pencil 획 보존")
    }
}
