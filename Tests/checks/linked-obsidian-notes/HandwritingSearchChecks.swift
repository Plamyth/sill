import Foundation
import PencilKit

@MainActor private final class HandwritingSearchGate {
    var input: PKDrawing?
    var query: String?
    private var continuation: CheckedContinuation<[Set<UUID>], Never>?
    func search(_ drawing: PKDrawing, _ query: String) async -> [Set<UUID>] {
        input = drawing
        self.query = query
        return await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { while input == nil { await Task.yield() } }
    func finish(_ matches: [Set<UUID>]) { continuation!.resume(returning:matches); continuation = nil }
}

@MainActor func checkHandwritingSearch(_ check: (Bool, String) -> Void) async throws {
    func stroke(_ x: CGFloat) -> PKStroke {
        let points = [CGPoint(x:x,y:10),CGPoint(x:x+10,y:40)].enumerated().map { index,point in
            PKStrokePoint(location:point,timeOffset:Double(index)*0.1,size:CGSize(width:3,height:3),
                          opacity:1,force:0.5,azimuth:0,altitude:1)
        }
        return PKStroke(ink:PKInk(.pen,color:.black),
                        path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))
    }
    let a = stroke(10), b = stroke(200), ink = PKDrawing(strokes:[a,b])
    func store() -> CanvasStore {
        let s = CanvasStore()
        s.scene = CanvasScene()
        s.drawing = PKDrawing()
        s.updateDrawing(ink)
        s.mode = .pen
        s.setHandwritingSearchSurface(CGSize(width:800,height:600))
        return s
    }
    let s = store(), before = s.scene
    await s.searchHandwriting("  한글 👩🏽‍💻 e\u{301}\n") { drawing,query in
        check(drawing == ink && query == "한글 👩🏽‍💻 e\u{301}","search receives exact source drawing and trimmed Unicode query")
        return [[b.id,UUID()],[a.id],[UUID()],[]]
    }
    check(s.mode == .lasso && s.inkSelection == [a.id,b.id],"search selects valid matched ink using native lasso")
    check(s.status.contains("2곳"),"result count excludes empty and invalid matches")
    check(s.scene == before && s.drawing == ink,"search preserves scene revision, structure and exact original ink")
    s.setInkSelection([a.id])
    let selectedStatus = s.mode
    await s.searchHandwriting("없음") { _,_ in [] }
    check(s.inkSelection == [a.id] && s.mode == selectedStatus && s.scene == before,
          "no match preserves previous selection, mode and persisted scene")
    var called = false
    await s.searchHandwriting(" \n ") { _,_ in called = true;return [] }
    check(!called && s.inkSelection == [a.id],"empty query does not invoke recognition or clear selection")
    let empty = store()
    empty.updateDrawing(PKDrawing())
    await empty.searchHandwriting("한글") { _,_ in called = true;return [] }
    check(!called && empty.status.contains("획이 없습니다"),"empty page rejects search without recognizing")
    for action in ["drawing","scene","mode","selection","proposal"] {
        let pending = store(), gate = HandwritingSearchGate()
        let task = Task { await pending.searchHandwriting("old",search:gate.search) }
        await gate.wait()
        switch action {
        case "drawing": pending.updateDrawing(PKDrawing(strokes:[a]))
        case "scene": pending.scene = CanvasScene()
        case "mode": pending.mode = .select
        case "selection": pending.setInkSelection([a.id])
        default: pending.proposalText = "새 입력"
        }
        let current = pending.scene, selection = pending.inkSelection, mode = pending.mode, status = pending.status
        gate.finish([[b.id]])
        await task.value
        check(pending.scene == current && pending.inkSelection == selection && pending.mode == mode && pending.status == status,
              "\(action) invalidates in-flight search without overwriting newer state")
    }
    let overlap = store(), old = HandwritingSearchGate(), newer = HandwritingSearchGate()
    let oldTask = Task { await overlap.searchHandwriting("old",search:old.search) }
    await old.wait()
    let newTask = Task { await overlap.searchHandwriting("new",search:newer.search) }
    await newer.wait()
    newer.finish([[b.id]]); await newTask.value
    old.finish([[a.id]]); await oldTask.value
    check(overlap.inkSelection == [b.id],"newer query wins when older recognition completes last")
    let searchAfterRecognition = store()
    let pendingRecognition = Task {
        await searchAfterRecognition.proposeHandwriting { _ in
            await searchAfterRecognition.searchHandwriting("new") { _,_ in [[b.id]] }
            return "obsolete"
        }
    }
    await pendingRecognition.value
    check(searchAfterRecognition.scene.nodes.isEmpty && searchAfterRecognition.inkSelection == [b.id],
          "search cancels old text proposal while preserving matched selection")
    let recognitionAfterSearch = store(), gate = HandwritingSearchGate()
    let pendingSearch = Task { await recognitionAfterSearch.searchHandwriting("old",search:gate.search) }
    await gate.wait()
    await recognitionAfterSearch.proposeHandwriting { _ in "새 후보" }
    let current = recognitionAfterSearch.scene
    gate.finish([[b.id]]); await pendingSearch.value
    check(recognitionAfterSearch.scene == current && recognitionAfterSearch.inkSelection.isEmpty && recognitionAfterSearch.mode == .select,
          "new text proposal cancels old search without switching mode or ink selection")
    let invalidated = store(), invalidGate = HandwritingSearchGate()
    let invalidTask = Task { await invalidated.searchHandwriting("old",search:invalidGate.search) }
    await invalidGate.wait()
    await invalidated.searchHandwriting(" ") { _,_ in [] }
    invalidGate.finish([[a.id]]); await invalidTask.value
    check(invalidated.inkSelection.isEmpty && invalidated.status.contains("입력하세요"),"empty newer query invalidates pending search")
}
