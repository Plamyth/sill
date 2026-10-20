import Foundation
import PencilKit

@MainActor private final class SelectedInkGate {
    var input: PKDrawing?
    private var continuation: CheckedContinuation<String?, Never>?
    func recognize(_ drawing: PKDrawing) async -> String? {
        input = drawing
        return await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { while input == nil { await Task.yield() } }
    func finish(_ text: String?) { continuation!.resume(returning:text); continuation = nil }
}

@MainActor func checkSelectedInk(_ check: (Bool, String) -> Void) async throws {
    func stroke(_ x: CGFloat) -> PKStroke {
        let points = [CGPoint(x:x,y:20),CGPoint(x:x+20,y:50)].enumerated().map { index,point in
            PKStrokePoint(location:point,timeOffset:Double(index)*0.1,size:CGSize(width:3,height:3),
                          opacity:1,force:0.5,azimuth:0,altitude:1)
        }
        return PKStroke(ink:PKInk(.pen,color:.black),
                        path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))
    }
    let a = stroke(10), b = stroke(200)
    let ink = PKDrawing(strokes:[a,b])
    func store() -> CanvasStore {
        let value = CanvasStore()
        value.scene = CanvasScene()
        value.drawing = PKDrawing()
        value.updateDrawing(ink)
        value.mode = .lasso
        return value
    }
    let s = store()
    s.setInkSelection([b.id,UUID()])
    check(s.inkSelection == [b.id],"native selection discards IDs outside the current drawing")
    let gate = SelectedInkGate()
    let task = Task { await s.proposeHandwriting(selectedOnly:true,recognize:gate.recognize) }
    await gate.wait()
    check(gate.input?.strokes.map(\.id) == [b.id],"selected recognizer receives only selected strokes in source order")
    let selectedBounds = PKDrawing(strokes:[b]).bounds
    gate.finish("선택한 글자 👩🏽‍💻 e\u{301}")
    await task.value
    let proposal = s.scene.nodes.last!
    check(proposal.sourceStrokeIds == [b.id] && proposal.confidence == .proposal,
          "selected text remains an unconfirmed semantic node with exact stroke lineage")
    check(proposal.frame.x == selectedBounds.midX && proposal.frame.y == selectedBounds.midY,
          "selected proposal is placed at its own ink bounds rather than whole-page bounds")
    check(s.drawing == ink && s.scene.strokes.map(\.id) == [a.id,b.id],"recognition preserves both selected and unrelated ink")
    check(s.inkSelection.isEmpty && s.mode == .select,"leaving native lasso clears transient selection")
    s.proposalText = "수정된 글자"
    s.confirmProposal()
    let restored = try JSONDecoder().decode(CanvasScene.self,from:JSONEncoder().encode(s.scene))
    check(restored.nodes.last?.text == "수정된 글자" && restored.nodes.last?.sourceStrokeIds == [b.id] &&
          restored.nodes.last?.confidence == .confirmed,"Obsidian scene payload roundtrip preserves editable text and source IDs")
    for action in ["selection","drawing","scene","mode"] {
        let pending = store()
        pending.setInkSelection([b.id])
        let wait = SelectedInkGate()
        let work = Task { await pending.proposeHandwriting(selectedOnly:true,recognize:wait.recognize) }
        await wait.wait()
        switch action {
        case "selection": pending.setInkSelection([a.id])
        case "drawing": pending.updateDrawing(PKDrawing(strokes:[a]))
        case "scene": pending.scene = CanvasScene()
        default: pending.mode = .pen
        }
        let currentScene = pending.scene
        let status = pending.status
        wait.finish("stale")
        await work.value
        check(pending.scene == currentScene && pending.status == status && pending.proposedNode == nil,
              "\(action) change rejects an in-flight selected result")
    }
    let empty = store()
    var called = false
    await empty.proposeHandwriting(selectedOnly:true) { _ in called = true;return "whole page" }
    check(!called && empty.scene.nodes.isEmpty && empty.status.contains("먼저 선택"),
          "empty selected action never falls back to the whole drawing")
    let preserved = store()
    preserved.setInkSelection([a.id,b.id])
    preserved.updateDrawing(PKDrawing(strokes:[b]))
    check(preserved.inkSelection == [b.id],"deleted ink is removed from selection while surviving selected ink is retained")
    preserved.drawing = ink
    check(preserved.inkSelection.isEmpty,"external drawing replacement resets native selection")
    let whole = store()
    whole.setInkSelection([b.id])
    await whole.proposeHandwriting { drawing in
        check(drawing == ink,"whole-page action remains whole-page even when a lasso is selected")
        return "whole"
    }
    check(whole.scene.nodes.last?.sourceStrokeIds == [a.id,b.id],"whole-page action retains existing provenance behavior")
    let failure = store()
    failure.setInkSelection([a.id])
    await failure.proposeHandwriting(selectedOnly:true) { _ in nil }
    check(failure.scene.nodes.isEmpty && failure.drawing == ink && failure.inkSelection == [a.id],
          "unrecognized selection preserves original ink and selection for retry")
    for change in ["text", "frame", "lineage", "scene", "scene-roundtrip"] {
        let edit = store()
        let id = edit.scene.addNode(kind:.note,at:CanvasPoint(x:100,y:100),text:"원문",confidence:.confirmed,sourceStrokeIds:[a.id])
        edit.proposedNode = id
        edit.proposalText = "수정 중 👩🏽‍💻 e\u{301}"
        switch change {
        case "text": edit.scene.nodes[0].text = "Mac에서 수정"
        case "frame": edit.scene.nodes[0].frame.x += 1
        case "lineage": edit.scene.nodes[0].sourceStrokeIds = [b.id]
        default:
            let original = edit.scene
            edit.scene.id = UUID()
            if change == "scene-roundtrip" { edit.scene = original }
        }
        let external = edit.scene
        edit.confirmProposal()
        check(edit.scene == external && edit.proposedNode == id && edit.proposalText == "수정 중 👩🏽‍💻 e\u{301}",
              "\(change) conflict preserves external canonical data and the correction draft")
        check(edit.status.contains("다른 곳"),"\(change) conflict explains why the draft was not committed")
    }
    for (original, external) in [("\u{00E9}", "e\u{301}"), ("e\u{301}", "\u{00E9}")] {
        let stale = store()
        let id = stale.scene.addNode(kind:.note,at:CanvasPoint(x:100,y:100),text:original,confidence:.confirmed,sourceStrokeIds:[a.id])
        stale.proposedNode = id
        stale.proposalText = original
        stale.scene.nodes[0].text = external
        check(!stale.proposalIsCurrent,"Unicode normalization-only changes invalidate an open correction")
        stale.confirmProposal()
        check(stale.scene.nodes[0].text.utf8.elementsEqual(external.utf8) && stale.proposalText.utf8.elementsEqual(original.utf8) && stale.proposedNode == id,
              "Unicode conflict preserves exact external UTF-8 and the exact correction draft")
    }
    let edit = store()
    let id = edit.scene.addNode(kind:.note,at:CanvasPoint(x:100,y:100),text:"원문",confidence:.confirmed,sourceStrokeIds:[a.id])
    edit.proposedNode = id
    edit.proposalText = "  글자별 교정 👩🏽‍💻 e\u{301}\n"
    _ = edit.scene.addNode(kind:.box,at:CanvasPoint(x:500,y:100),text:"별개 요소")
    let untouched = edit.scene.nodes[1]
    let beforeInk = edit.drawing
    edit.confirmProposal()
    check(Array(edit.scene.nodes[0].text.utf8) == Array("  글자별 교정 👩🏽‍💻 e\u{301}\n".utf8),
          "confirmed text correction preserves exact whitespace and Unicode bytes")
    check(edit.proposedNode == nil && edit.scene.nodes[0].sourceStrokeIds == [a.id] && edit.drawing == beforeInk && edit.scene.nodes[1] == untouched,
          "unrelated scene edits do not block correction or change ink and source lineage")
    edit.proposedNode = id
    edit.proposalText = "취소할 입력"
    let beforeCancel = edit.scene
    edit.proposedNode = nil
    edit.confirmProposal()
    check(edit.scene == beforeCancel,"cancelling a correction never changes canonical data")
}
