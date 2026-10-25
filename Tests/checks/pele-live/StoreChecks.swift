import Foundation
import PencilKit
import SwiftUI

@main struct StoreChecks {
    @MainActor static func main() throws {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]! + "/"))
        let out = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PELE_OUTPUT"]!)
        let store = CanvasStore(blockRecoveryURL:out.appendingPathComponent("recovery.json"))
        store.scene = CanvasScene()
        let rulerScene = store.scene
        let rulerViewport = store.viewport
        let rulerGeneration = store.inkHistory.generation
        let rulerBinding = ObservedObject(wrappedValue:store).projectedValue.rulerEnabled
        precondition(!rulerBinding.wrappedValue && !store.rulerIsActive(isVisible:true))
        rulerBinding.wrappedValue = true
        for mode in CanvasMode.allCases {
            store.mode = mode
            precondition(store.rulerEnabled && store.rulerIsActive(isVisible:true) == (mode == .pen))
            precondition(!store.rulerIsActive(isVisible:false))
        }
        store.mode = .pen
        precondition(store.rulerIsActive(isVisible:true))
        rulerBinding.wrappedValue = false
        precondition(!store.rulerIsActive(isVisible:true))
        precondition(store.scene == rulerScene && store.viewport == rulerViewport &&
            store.inkHistory.generation == rulerGeneration)
        rulerBinding.wrappedValue = true
        store.saveNow()
        let rulerReopened = CanvasStore(blockRecoveryURL:out.appendingPathComponent("recovery.json"))
        precondition(!rulerReopened.rulerEnabled && rulerReopened.scene == store.scene)
        rulerBinding.wrappedValue = false
        print("PASS 자의 실제 ObservedObject binding·전체 도구 모드·숨김 전환·세션 내 의도 유지·비영속화와 장면·뷰포트·이력 불변")
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
        let parent = store.scene.nodes[0].id
        let child = store.scene.addNode(kind:.box,at:.init(x:400,y:200),text:"기존 자식")
        let other = store.scene.addNode(kind:.box,at:.init(x:700,y:200),text:"다른 부모")
        precondition(store.scene.connectAsChild(parent:parent,child:child))
        let beforeMixed = store.scene
        var proposed = store.scene.nodes[1]
        proposed.id = UUID()
        proposed.text = "새 제안 자식"
        proposed.confidence = .proposal
        var moved = store.scene.links[0]
        moved.to = proposed.id
        let mixed = AgentRevision(sceneId:store.scene.id,baseRevision:store.scene.revision,
            annotations:[],proposedNodes:[proposed],
            proposedLinks:[.init(id:UUID(),from:other,to:child,label:"새 부모",kind:.parentChild)],
            nodeEdits:[.init(expected:store.scene.nodes[0],text:"혼합 수정")],
            linkEdits:[.init(expected:store.scene.links[0],replacement:moved)])
        precondition(store.applyAgentRevision(mixed) && store.canUndoGraph)
        let afterMixed = store.scene
        precondition(store.applyAgentRevision(mixed) && store.scene == afterMixed)
        store.saveNow()
        let mixedReopened = CanvasStore(blockRecoveryURL:out.appendingPathComponent("recovery.json"))
        precondition(mixedReopened.scene == afterMixed)
        let latestDrawing = PKDrawing(strokes:later.strokes + drawing.strokes)
        store.updateDrawing(latestDrawing)
        let latestRaw = store.scene.drawingBase64
        store.undoGraphEdit()
        precondition(store.scene.hasSameGraph(as:beforeMixed) && !store.canUndoGraph)
        precondition(store.drawing.strokes.map(\.id) == latestDrawing.strokes.map(\.id) &&
            store.scene.drawingBase64 == latestRaw)
        store.saveNow()
        let restored = CanvasStore(blockRecoveryURL:out.appendingPathComponent("recovery.json"))
        precondition(restored.scene == store.scene)
        print("PASS 혼합 노드·부모 링크·기존 수정의 단일 적용, 멱등 재수신, 저장 복원과 전체 그래프 되돌림 뒤 최신 잉크 보존")
        print("PASS 실제 Store의 AI 수정→저장→새 Store 복원, 재수신·오래된 거부, 공통 텍스트 편집, Undo 뒤 새 Pencil 획 보존")
    }
}
