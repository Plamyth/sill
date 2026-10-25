import Foundation
import PencilKit
import Combine
import AppKit

@main struct CommentStoreChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let env = ProcessInfo.processInfo.environment
        let home = env["CFFIXED_USER_HOME"]!
        let output = URL(fileURLWithPath:env["PELE_OUTPUT"]!)
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/") && env["HOME"] == home)
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value,label); count += 1; print("통과 \(label)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func bytes(_ scene: CanvasScene) -> Data { try! encoder.encode(scene) }
        let defaults = UserDefaults(suiteName:output.appendingPathComponent("node-comments-defaults").path)!
        let store = CanvasStore(blockRecoveryURL:output.appendingPathComponent("recovery.json"),defaults:defaults)
        store.scene = CanvasScene()
        let stroke = PKStroke(ink:PKInk(.pen,color:.white),path:PKStrokePath(controlPoints:[
            PKStrokePoint(location:.init(x:15,y:20),timeOffset:0,size:.init(width:3,height:3),
                opacity:1,force:0.7,azimuth:0,altitude:1),
            PKStrokePoint(location:.init(x:70,y:90),timeOffset:1,size:.init(width:4,height:4),
                opacity:1,force:0.8,azimuth:0,altitude:1)],creationDate:Date(timeIntervalSince1970:10)))
        store.updateDrawing(PKDrawing(strokes:[stroke]))
        let a = store.scene.addNode(kind:.box,at:.init(x:100,y:200),text:"원본 e\u{301}")
        let b = store.scene.addNode(kind:.note,at:.init(x:700,y:650),text:"하위 요소")
        check(store.scene.connectAsChild(parent:a,child:b),"격리 계층 생성")
        store.scene.nodes[0].sourceStrokeIds = store.scene.strokes.map(\.id)
        store.scene.annotations = [.init(id:UUID(),nodeId:a,text:"유지할 에이전트 주석",author:"에이전트"),
                                   .init(id:UUID(),nodeId:nil,text:"유지할 전역 주석",author:"에이전트")]
        store.mode = .select
        store.selectedNode = a
        let base = store.scene
        var writes = 0
        let observer = store.$scene.dropFirst().sink { _ in writes += 1 }
        defer { observer.cancel() }
        let first = store.beginCommentEdit()!
        store.commentText = " \t사용자 댓글 e\u{301} 👩🏽‍💻\r\n다음 줄\n "
        let text = store.commentText
        check(store.scene == base && writes == 0 && !store.canUndoGraph,"입력 중 장면·이력 쓰기 없음")
        check(store.beginCommentEdit() == first && store.commentText == text,"닫기 후 재진입은 입력과 세션 유지")
        store.commentInputBusy = true
        check(!store.confirmComment(sessionID:first) && writes == 0 && store.commentText == text,"조합·손글씨 입력 중 확인 거부")
        store.commentInputBusy = false
        check(store.confirmComment(sessionID:first),"댓글 추가 확정")
        let added = store.scene
        let commentID = added.annotations.last!.id
        check(writes == 1 && added.revision == base.revision+1 && store.canUndoGraph,"단일 변경·수정 번호·기존 이력")
        check(added.nodes == base.nodes && added.links == base.links && added.strokes == base.strokes &&
              added.drawingBase64 == base.drawingBase64,"원본 노드·출처·획 보존")
        check(Array(added.annotations.dropLast()) == base.annotations &&
              added.annotations.last!.text.utf8.elementsEqual(text.utf8),"기존 주석과 댓글 원문 바이트 보존")
        check(!store.confirmComment(sessionID:first) && writes == 1,"중복 확인은 추가 저장 없음")
        store.undoGraphEdit()
        check(store.scene.hasSameGraph(as:base) && store.scene.revision == added.revision+1 && store.canRedoGraph,"추가 되돌리기")
        store.redoGraphEdit()
        check(store.scene.hasSameGraph(as:added) && store.scene.annotations.last!.id == commentID,"추가 다시 실행·같은 식별자")
        let second = store.beginCommentEdit()!
        store.commentInputBusy = true
        check(store.beginCommentEdit() == second && store.commentInputBusy,
              "미확정 조합 입력 중 재진입은 세션과 입력 상태 보존")
        store.commentInputBusy = false
        store.commentText = "수정한 댓글"
        check(!store.confirmComment(sessionID:first) && store.commentText == "수정한 댓글","이전 세션 콜백은 새 편집을 소비하지 않음")
        check(store.confirmComment(sessionID:second) && store.scene.annotations.last!.id == commentID &&
              store.scene.annotations.count == added.annotations.count,"댓글 수정은 기존 한 개 재사용")
        store.undoGraphEdit()
        check(store.scene.annotations.last!.text.utf8.elementsEqual(text.utf8),"댓글 수정 되돌리기 원문 복원")
        store.redoGraphEdit()
        check(store.scene.annotations.last!.text == "수정한 댓글","댓글 수정 다시 실행")
        let editable = store.scene
        let recovery = store.beginCommentEdit()!
        store.commentText = "선택 변경 뒤 보존할 초안 e\u{301}"
        let draft = store.commentText
        store.selectedNode = b
        let recoveryScene = bytes(store.scene)
        check(store.beginCommentEdit() == recovery && store.commentText == draft,
              "나중에·선택 변경·재진입은 원래 초안 유지")
        check(!store.confirmComment(sessionID:recovery) && bytes(store.scene) == recoveryScene,
              "재현: 선택이 바뀐 초안은 저장할 수 없음")
        let workspace = try String(contentsOfFile:env["COMMENT_WORKSPACE"]!,encoding:.utf8)
        check(workspace.contains("canvasDiscardCommentDraft"),"재현: stale 초안을 명시적으로 해제할 UI가 있어야 함")
        for invalid in ["", " \r\n\t"] {
            let token = store.beginCommentEdit()!
            store.commentText = invalid
            let before = bytes(store.scene)
            check(!store.confirmComment(sessionID:token) && bytes(store.scene) == before &&
                  store.commentText == invalid,"빈 입력 저장 거부·입력 보존")
            store.commentText = store.commentSession!.text
        }
        for mutation: (CanvasStore) -> Void in [
            { $0.selectedNode = b }, { $0.selectedNode = b; $0.selectedNode = a },
            { $0.scene.nodes.removeFirst() }, { $0.scene.nodes[0].text += "원격 변경" },
            { $0.scene.annotations[0].text += "원격 변경" },
            { $0.scene.id = UUID() }, { $0.scene.revision += 1 },
            { let original = $0.scene; $0.scene = CanvasScene(); $0.scene = original },
            { $0.scene.annotations.append(.init(id:UUID(),nodeId:a,text:"중복",author:"사용자")) }
        ] {
            store.scene = editable
            store.selectedNode = a
            if let session = store.commentSession { store.commentText = session.text }
            let token = store.beginCommentEdit()!
            store.commentText = "저장 전 입력 보존"
            mutation(store)
            check(store.beginCommentEdit() == token && store.commentText == "저장 전 입력 보존",
                  "변경 후 재진입도 초안을 새 노드에 자동 배정하지 않음")
            let before = bytes(store.scene)
            check(!store.commentIsCurrent && !store.confirmComment(sessionID:token) &&
                  bytes(store.scene) == before && store.commentText == "저장 전 입력 보존","선택·노드·주석·장면 변경 뒤 오래된 저장 거부")
        }
        store.scene = editable
        store.selectedNode = b
        if let session = store.commentSession { store.commentText = session.text }
        let hidden = store.beginCommentEdit()!
        store.commentText = "숨김 중 입력"
        _ = store.scene.toggleChildren(of:a)
        let folded = bytes(store.scene)
        check(!store.confirmComment(sessionID:hidden) && bytes(store.scene) == folded &&
              store.commentText == "숨김 중 입력","계층 숨김 뒤 원문 덮기 없음")
        store.scene = editable
        store.selectedNode = a
        if let session = store.commentSession { store.commentText = session.text }
        store.scene.annotations.append(.init(id:UUID(),nodeId:a,text:"중복",author:"사용자"))
        let ambiguous = bytes(store.scene)
        check(store.beginCommentEdit() == nil && bytes(store.scene) == ambiguous,"여러 사용자 댓글이면 진입 거부·보존")
        store.scene = editable
        try await Task.sleep(for:.milliseconds(500))
        let restored = CanvasStore(blockRecoveryURL:output.appendingPathComponent("restored-recovery.json"),defaults:defaults)
        check(bytes(restored.scene) == bytes(editable),"격리 장면 JSON 자동 저장·Store 재생성 후 정확한 복원")
        check(restored.scene.annotations.last!.id == commentID && restored.scene.annotations.last!.text == "수정한 댓글",
              "복원한 댓글의 식별자·작성자·전체 원문 유지")
        print("카드 댓글 저장 검사 \(count)개 통과")
    }
}
