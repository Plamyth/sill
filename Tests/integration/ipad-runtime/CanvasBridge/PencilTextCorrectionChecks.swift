#if DEBUG && CANVAS_PENCIL_CORRECTION_CHECK
import PencilKit
import SwiftUI
import UIKit

@MainActor
enum PencilTextCorrectionChecks {
    static func run(host: UIHostingController<AnyView>) async throws -> String {
        guard case .isolated(let runtime) = CanvasRuntime.launch,
              let connection = CanvasRelay.loadConnection(),
              connection.address == runtime.relayAddress, connection.token == runtime.token else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let store = CanvasStore()
        guard let node = store.scene.nodes.first else { throw CocoaError(.fileReadCorruptFile) }
        let originalDrawing = store.scene.drawingBase64
        let originalStrokes = store.scene.strokes
        store.proposedNode = node.id
        store.proposalText = "가나다"
        let session = store.proposalInputSessionID
        let editor = VaultMarkdownEditor(
            text:Binding(get:{ store.proposalText },set:{ store.proposalText = $0 }),
            selection:.constant(NSRange(location:0,length:0)),
            identifier:"pencilCorrectionNativeEditor",label:"펜 교정 네이티브 검사",
            editSession:{ store.proposalInputSessionID })
        host.rootView = AnyView(editor.frame(width:600,height:300))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for _ in 0..<40 {
            host.view.layoutIfNeeded()
            if host.view.window != nil && descendants(host.view).contains(where:{ $0 is VaultMarkdownEditor.NodeTextView }) { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        func missing(_ field: String) -> NSError {
            NSError(domain:"PencilTextCorrectionFixture",code:1,userInfo:[NSLocalizedDescriptionKey:field])
        }
        guard let view = descendants(host.view).compactMap({ $0 as? VaultMarkdownEditor.NodeTextView }).first else { throw missing("편집기 마운트 실패") }
        guard let controller = view.delegate as? VaultMarkdownEditor.Coordinator else { throw missing("편집기 delegate 없음") }
        guard let toolbar = view.inputAccessoryView as? UIToolbar else { throw missing("편집 도구 막대 없음") }
        guard let mode = toolbar.items?.first(where:{ $0.accessibilityIdentifier == "canvasPencilCorrectionMode" }),
              let action = mode.action else { throw missing("펜 교정 전환 동작 없음") }
        view.becomeFirstResponder()
        try await Task.sleep(for:.milliseconds(200))
        host.view.layoutIfNeeded()
        UIApplication.shared.sendAction(action,to:mode.target,from:mode,for:nil)
        var checks = 0
        func check(_ condition: Bool,_ label: String) throws {
            checks += 1
            print("PENCIL_CHECK \(condition ? "PASS" : "FAIL") \(label)")
            guard condition else { throw NSError(domain:"PencilTextCorrection",code:checks,
                userInfo:[NSLocalizedDescriptionKey:label]) }
        }
        func glyph(_ offset: Int, length: Int = 1) throws -> CGRect {
            view.layoutManager.ensureLayout(for:view.textContainer)
            guard let start = view.position(from:view.beginningOfDocument,offset:offset),
                  let end = view.position(from:start,offset:length),
                  let range = view.textRange(from:start,to:end),
                  let rect = view.selectionRects(for:range).map(\.rect).first(where:{ $0.width > 0 })
            else { throw CocoaError(.validationMissingMandatoryProperty) }
            return rect
        }
        func vertical(at offset: Int, down: Bool) throws -> [CGPoint] {
            guard let position = view.position(from:view.beginningOfDocument,offset:offset) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let rect = view.caretRect(for:position), x = rect.midX, y = rect.midY
            return (0...6).map { index in
                CGPoint(x:x,y:y + (down ? -1 : 1) * 24 + CGFloat(index) * (down ? 8 : -8))
            }
        }
        try check(mode.accessibilityValue == "펜 교정","실제 편집 도구의 펜 교정 전환")
        try checkJoinSplitGeometry(view:view,controller:controller,check:check)
        let twoLines = "가나다라마바사아자차카타파하\n가나다라마바사아자차카타파하"
        view.text = twoLines
        controller.textViewDidChange(view)
        let upperLine = try glyph(5), lowerLine = try glyph(20)
        let crossing = (0...5).map { index in
            CGPoint(x:upperLine.midX + (index % 2 == 0 ? -50 : 50),
                    y:upperLine.midY - 4 + CGFloat(index) * (lowerLine.midY-upperLine.midY+8)/5)
        }
        controller.applyCorrection(crossing,expectedText:view.text)
        try check(view.text == twoLines,"두 줄의 일부만 닿은 삭제 획은 적용하지 않음")
        view.text = "abcde"
        controller.textViewDidChange(view)
        let narrow = try glyph(2)
        let narrowScratch = (0...5).map { index in
            CGPoint(x:narrow.midX + (index % 2 == 0 ? -1 : 1) * narrow.width * 0.45,
                    y:narrow.midY + (index % 2 == 0 ? -1 : 1))
        }
        controller.applyCorrection(narrowScratch,expectedText:view.text)
        try check(view.text == "abde","실제 좁은 영문 글자 c만 지우기")
        for (word,middleOffset,middleLength,result) in [("가나다",1,1,"가다"),("a👩🏽‍💻b",1,"👩🏽‍💻".utf16.count,"ab")] {
            view.text = word
            controller.textViewDidChange(view)
            let left = try glyph(0), middle = try glyph(middleOffset,length:middleLength)
            let right = try glyph(word.utf16.count-1)
            let wideScratch = (0...7).map { index in
                CGPoint(x:index % 2 == 0 ? left.minX : right.maxX,
                        y:middle.midY + (index % 2 == 0 ? -4 : 4))
            }
            try check(controller.correctionRange(wideScratch,gesture:.erase,in:view) ==
                NSRange(location:middleOffset,length:middleLength),"넓은 실제 필기 폭에서도 가운데 글자 한 개만 대상")
            controller.applyCorrection(wideScratch,expectedText:view.text)
            try check(view.text == result,"넓은 지그재그가 인접 글자를 지우지 않고 전체 Character를 보존")
        }
        view.text = "a👩🏽‍💻b"
        controller.textViewDidChange(view)
        let emoji = try glyph(1,length:"👩🏽‍💻".utf16.count)
        let ambiguous = (0...7).map { index in
            CGPoint(x:emoji.maxX + (index % 2 == 0 ? -25 : 25),
                    y:emoji.midY + (index % 2 == 0 ? -4 : 4))
        }
        try check(controller.correctionRange(ambiguous,gesture:.erase,in:view) == nil,
                  "폭이 다른 emoji와 영문의 경계 중심은 모호한 삭제로 거부")
        controller.applyCorrection(ambiguous,expectedText:view.text)
        try check(view.text == "a👩🏽‍💻b","문자 경계의 넓은 획은 어느 글자도 지우지 않음")
        view.text = "가나다"
        controller.textViewDidChange(view)
        let sampledGlyph = try glyph(1)
        let recordedDiagonal = [CGPoint(x:35,y:41.5),CGPoint(x:35,y:41.5),CGPoint(x:34.5,y:41.5),CGPoint(x:34.5,y:41.5),CGPoint(x:34,y:41.5),CGPoint(x:34,y:41.5),CGPoint(x:33.5,y:41.5),CGPoint(x:33,y:41.5),CGPoint(x:32.5,y:41.5),CGPoint(x:32,y:41.5),CGPoint(x:31,y:42.5),CGPoint(x:30,y:43.5),CGPoint(x:28.5,y:44.5),CGPoint(x:27,y:46),CGPoint(x:25,y:47.5),CGPoint(x:23,y:49.5),CGPoint(x:21,y:51.5),CGPoint(x:18.5,y:54),CGPoint(x:17,y:55.5),CGPoint(x:15.5,y:57),CGPoint(x:14.5,y:58.5),CGPoint(x:14,y:59),CGPoint(x:13.5,y:59.5),CGPoint(x:13.5,y:60),CGPoint(x:13.5,y:60),CGPoint(x:14,y:60),CGPoint(x:15,y:59.5),CGPoint(x:16,y:59),CGPoint(x:17,y:58.5),CGPoint(x:18.5,y:57.5),CGPoint(x:20,y:56.5),CGPoint(x:22,y:55),CGPoint(x:23.5,y:54),CGPoint(x:25.5,y:53),CGPoint(x:27.5,y:51.5),CGPoint(x:29,y:50.5),CGPoint(x:30.5,y:49.5),CGPoint(x:32,y:48.5),CGPoint(x:33.5,y:47.5),CGPoint(x:34.5,y:46.5),CGPoint(x:35,y:45.5),CGPoint(x:36,y:44.5),CGPoint(x:36.5,y:44.5),CGPoint(x:36.5,y:44),CGPoint(x:36.5,y:44),CGPoint(x:36,y:44),CGPoint(x:35,y:44.5),CGPoint(x:33.5,y:45.5),CGPoint(x:32,y:46.5),CGPoint(x:30.5,y:48),CGPoint(x:28.5,y:49.5),CGPoint(x:26,y:51),CGPoint(x:24,y:52.5),CGPoint(x:21.5,y:54.5),CGPoint(x:19.5,y:56),CGPoint(x:17.5,y:57),CGPoint(x:16,y:58.5),CGPoint(x:14.5,y:59.5),CGPoint(x:13.5,y:61),CGPoint(x:12.5,y:62),CGPoint(x:12,y:62.5),CGPoint(x:12,y:63),CGPoint(x:12,y:63),CGPoint(x:12.5,y:63),CGPoint(x:13,y:63),CGPoint(x:14,y:63),CGPoint(x:15,y:62.5),CGPoint(x:16,y:61.5),CGPoint(x:17.5,y:60.5),CGPoint(x:19.5,y:59),CGPoint(x:21,y:57.5),CGPoint(x:23,y:56),CGPoint(x:25,y:54.5),CGPoint(x:26.5,y:53.5),CGPoint(x:28.5,y:52),CGPoint(x:30,y:51),CGPoint(x:31.5,y:49.5),CGPoint(x:32.5,y:48),CGPoint(x:33.5,y:47.5),CGPoint(x:34,y:46.5),CGPoint(x:34,y:46.5),CGPoint(x:34,y:46.5),CGPoint(x:33.5,y:46.5),CGPoint(x:32.5,y:47),CGPoint(x:31,y:48),CGPoint(x:29,y:49.5),CGPoint(x:27,y:51),CGPoint(x:25,y:53),CGPoint(x:22.5,y:55),CGPoint(x:20.5,y:57),CGPoint(x:18.5,y:59),CGPoint(x:17,y:61),CGPoint(x:16,y:62.5),CGPoint(x:15,y:64.5),CGPoint(x:14,y:66),CGPoint(x:14,y:67),CGPoint(x:14,y:67.5),CGPoint(x:14.5,y:68),CGPoint(x:15.5,y:68),CGPoint(x:17,y:68),CGPoint(x:19,y:68),CGPoint(x:21,y:68),CGPoint(x:23.5,y:67),CGPoint(x:26,y:66),CGPoint(x:28,y:65),CGPoint(x:30.5,y:63.5),CGPoint(x:32.5,y:62),CGPoint(x:34.5,y:60.5),CGPoint(x:36,y:59),CGPoint(x:37,y:57.5),CGPoint(x:38.5,y:56.5),CGPoint(x:39.5,y:55),CGPoint(x:41,y:53.5),CGPoint(x:41.5,y:53),CGPoint(x:42,y:52),CGPoint(x:42.5,y:52),CGPoint(x:42.5,y:52),CGPoint(x:42.5,y:52),CGPoint(x:42,y:52),CGPoint(x:41,y:52),CGPoint(x:40,y:53),CGPoint(x:38.5,y:53.5),CGPoint(x:37,y:55),CGPoint(x:35.5,y:56.5),CGPoint(x:33.5,y:58),CGPoint(x:32,y:59.5),CGPoint(x:30.5,y:60.5),CGPoint(x:29,y:62),CGPoint(x:27.5,y:63.5),CGPoint(x:26.5,y:64.5),CGPoint(x:25,y:66),CGPoint(x:24,y:66.5),CGPoint(x:23.5,y:67),CGPoint(x:23.5,y:67.5),CGPoint(x:23.5,y:67.5),CGPoint(x:23.5,y:67.5),CGPoint(x:24.5,y:67.5),CGPoint(x:26,y:66.5),CGPoint(x:27.5,y:65.5),CGPoint(x:29,y:64.5),CGPoint(x:31,y:63),CGPoint(x:33,y:61.5),CGPoint(x:34.5,y:60),CGPoint(x:36,y:58.5),CGPoint(x:37,y:57.5),CGPoint(x:38.5,y:56.5),CGPoint(x:39.5,y:55.5),CGPoint(x:41,y:55),CGPoint(x:41.5,y:54.5),CGPoint(x:42,y:54.5),CGPoint(x:42,y:54.5),CGPoint(x:42,y:55),CGPoint(x:41.5,y:56),CGPoint(x:40.5,y:57.5),CGPoint(x:39.5,y:59),CGPoint(x:38,y:60.5),CGPoint(x:36.5,y:62),CGPoint(x:35,y:63.5),CGPoint(x:34,y:65),CGPoint(x:32.5,y:67),CGPoint(x:31,y:68),CGPoint(x:30,y:69),CGPoint(x:29,y:69.5),CGPoint(x:28.5,y:70.5),CGPoint(x:28,y:70.5),CGPoint(x:27.5,y:71),CGPoint(x:27.5,y:71),CGPoint(x:28,y:71),CGPoint(x:28.5,y:70.5),CGPoint(x:29,y:70),CGPoint(x:30.5,y:69.5),CGPoint(x:31.5,y:68.5),CGPoint(x:33,y:67.5),CGPoint(x:34,y:67),CGPoint(x:40,y:58.5)]
        let actualDiagonal = recordedDiagonal.map { point in
            CGPoint(x:sampledGlyph.midX + (point.x-25.75)*sampledGlyph.width/13.5,
                    y:sampledGlyph.midY + (point.y-55.5)*sampledGlyph.height/21)
        }
        try check(CanvasPencilTextCorrection.gesture(for:actualDiagonal,minimumEraseWidth:min(24,sampledGlyph.width*0.8)) == .erase,
                  "실제44 Pencil 대각선 왕복175점을 글자 폭에 맞춰 삭제로 인식")
        try check(controller.correctionRange(actualDiagonal,gesture:.erase,in:view) == NSRange(location:1,length:1),
                  "실제 대각선 Pencil 획의 대상은 나 한 글자")
        controller.applyCorrection(actualDiagonal,expectedText:view.text)
        try check(view.text == "가다" && store.proposalText == "가다",
                  "실제 수집 대각선 획 재현에서 주변 글자 보존")
        view.text = "가나다"
        controller.textViewDidChange(view)
        view.undoManager?.removeAllActions()
        let middle = try glyph(1), cy = middle.midY, cx = middle.midX
        let scratch = (0...5).map { index in CGPoint(x:cx + (index % 2 == 0 ? -12 : 12),y:cy + (index % 2 == 0 ? -4 : 4)) }
        let hit = controller.correctionRange(scratch,gesture:.erase,in:view)
        let recognized = CanvasPencilTextCorrection.gesture(for:scratch)
        try check(hit == NSRange(location:1,length:1),"글자 실제 폭에 맞춘 획의 대상은 나 한 글자")
        view.undoManager?.beginUndoGrouping()
        controller.applyCorrection(scratch,expectedText:view.text)
        view.undoManager?.endUndoGrouping()
        try check(view.text == "가다" && store.proposalText == "가다",
            "가운데 나 삭제 text=\(view.text ?? "nil") draft=\(store.proposalText) hit=\(String(describing:hit)) kind=\(String(describing:recognized)) glyph=\(middle)")
        guard let undo = toolbar.items?.first(where:{ $0.title == "실행 취소" }), let undoAction = undo.action,
              let redo = toolbar.items?.first(where:{ $0.title == "다시 실행" }), let redoAction = redo.action
        else { throw CocoaError(.validationMissingMandatoryProperty) }
        try check(undo.isEnabled,"Pencil 교정 후 실행 취소 가능")
        UIApplication.shared.sendAction(undoAction,to:undo.target,from:undo,for:nil)
        try check(view.text == "가나다","Pencil 교정 글자 삭제 실행 취소")
        UIApplication.shared.sendAction(redoAction,to:redo.target,from:redo,for:nil)
        try check(view.text == "가다","Pencil 교정 글자 삭제 다시 실행")
        controller.applyCorrection(try vertical(at:1,down:true),expectedText:view.text)
        try check(view.text == "가 다","아래 방향 획으로 글자 사이 나누기")
        controller.applyCorrection(try vertical(at:1,down:false),expectedText:view.text)
        try check(view.text == "가다","위 방향 획으로 공백 합치기")
        let beforeStale = view.text
        controller.applyCorrection(scratch,expectedText:"옛 입력")
        try check(view.text == beforeStale,"그리는 동안 바뀐 입력은 적용하지 않음")
        UIApplication.shared.sendAction(action,to:mode.target,from:mode,for:nil)
        try check(mode.accessibilityValue == "손글씨 입력","펜 교정 종료 후 손글씨 입력 복원")
        guard let scribble = view.interactions.compactMap({ $0 as? UIScribbleInteraction }).first else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        try check(controller.scribbleInteraction(scribble,shouldBeginAt:.zero),"기존 Scribble 교정 경로 다시 허용")
        try await checkSelectionCorrections(view:view,controller:controller,check:check)
        guard let start = view.position(from:view.beginningOfDocument,offset:1),
              let end = view.position(from:start,offset:1),
              let range = view.textRange(from:start,to:end) else { throw CocoaError(.validationMissingMandatoryProperty) }
        view.replace(range,withText:"구")
        controller.textViewDidChange(view)
        try check(view.text == "가구" && store.proposalText == "가구","기존 네이티브 입력의 글자 교정 결과 연결")
        UIApplication.shared.sendAction(action,to:mode.target,from:mode,for:nil)
        try check(store.proposalInputSessionID == session && store.proposalIsCurrent,"수정 중 원래 요소·입력 세션 유지")
        view.selectedRange = NSRange(location:1,length:1)
        guard let retiredCorrection = controller.beginSelectionCorrection() else { throw CocoaError(.validationMissingMandatoryProperty) }
        store.confirmProposal()
        try check(!controller.confirmSelectionCorrection(retiredCorrection,replacement:"오래된 교정") && view.text == "가구",
                  "노드 확정 후 지연된 선택 교정도 적용하지 않음")
        store.saveNow()
        let reopened = CanvasStore()
        try check(reopened.scene.nodes.first(where:{ $0.id == node.id })?.text == "가구","파일 저장 후 Store 재열기")
        try check(reopened.scene.drawingBase64 == originalDrawing && reopened.scene.strokes == originalStrokes,
                  "원본 잉크·출처 획 보존")
        try check(reopened.scene.nodes.first(where:{ $0.id == node.id })?.sourceStrokeIds == node.sourceStrokeIds,
                  "노드 ID·원본 획 참조 보존")
        controller.applyCorrection(scratch,expectedText:view.text)
        try check(view.text == "가구","확정된 이전 편집 세션에 늦은 제스처 적용 금지")
        try await checkVaultEditors(host:host,check:check)
        try await checkVaultEditors(host:host,connection:connection,check:check)
        return "PENCIL_CORRECTION total=\(checks) failed=0 productionGeometry=true injectedTrace=true physicalPencil=false vaultRoundTrip=true fixture=REA-Pencil-Obsidian.md"
    }

    private static func checkJoinSplitGeometry(view: UITextView, controller: VaultMarkdownEditor.Coordinator,
                                              check: (Bool,String) throws -> Void) throws {
        func install(_ text: String) {
            view.text = text
            controller.textViewDidChange(view)
            view.layoutManager.ensureLayout(for:view.textContainer)
            view.undoManager?.removeAllActions()
        }
        func vertical(_ point: CGPoint, down: Bool) -> [CGPoint] {
            (0...6).map { CGPoint(x:point.x,y:point.y + (down ? -24 : 24) + CGFloat($0) * (down ? 8 : -8)) }
        }
        for separator in [" ","   "] {
            let source = "앞" + separator + "👩🏽‍💻뒤\n\n보존할 문단\n"
            install(source)
            guard let start = view.position(from:view.beginningOfDocument,offset:1),
                  let end = view.position(from:start,offset:separator.utf16.count),
                  let range = view.textRange(from:start,to:end),
                  let rect = view.selectionRects(for:range).map(\.rect).first(where:{ $0.width > 0 }) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let points = vertical(CGPoint(x:rect.midX,y:rect.midY),down:false)
            view.undoManager?.beginUndoGrouping()
            controller.applyCorrection(points,expectedText:source)
            view.undoManager?.endUndoGrouping()
            try check(view.text == "앞👩🏽‍💻뒤\n\n보존할 문단\n","실제 공백 영역 중앙 위 획 합치기와 다른 문단 보존")
            view.undoManager?.undo(); controller.textViewDidChange(view)
            try check(view.text.utf8.elementsEqual(source.utf8),"합치기 Undo의 정확 원문 복원")
            view.undoManager?.redo(); controller.textViewDidChange(view)
            guard let position = view.position(from:view.beginningOfDocument,offset:1) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let caret = view.caretRect(for:position)
            view.undoManager?.beginUndoGrouping()
            controller.applyCorrection(vertical(CGPoint(x:caret.midX,y:caret.midY),down:true),expectedText:view.text)
            view.undoManager?.endUndoGrouping()
            try check(view.text == "앞 👩🏽‍💻뒤\n\n보존할 문단\n","실제 caret 아래 획 나누기와 emoji 보존")
            view.undoManager?.undo(); controller.textViewDidChange(view)
            try check(view.text == "앞👩🏽‍💻뒤\n\n보존할 문단\n","나누기 Undo가 추가 공백 하나만 복원")
        }
        for separator in ["\n", "\r\n", "  \n", "\n\n", "\t", "\u{a0}", "\u{2028}"] {
            let source = "앞" + separator + "뒤"
            install(source)
            for offset in [1,1+separator.utf16.count] {
                guard let position = view.position(from:view.beginningOfDocument,offset:offset) else { throw CocoaError(.validationMissingMandatoryProperty) }
                let caret = view.caretRect(for:position)
                controller.applyCorrection(vertical(CGPoint(x:caret.midX,y:caret.midY),down:false),expectedText:source)
                try check(view.text.utf8.elementsEqual(source.utf8),"UIKit replay에서 Markdown 구분자·줄바꿈 합치기 거부")
            }
        }
        install("앞👩🏽‍💻뒤")
        guard let start = view.position(from:view.beginningOfDocument,offset:1),
              let end = view.position(from:start,offset:"👩🏽‍💻".utf16.count),
              let range = view.textRange(from:start,to:end),
              let rect = view.selectionRects(for:range).map(\.rect).first(where:{ $0.width > 0 }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        controller.applyCorrection(vertical(CGPoint(x:rect.midX,y:rect.midY),down:true),expectedText:view.text)
        try check(view.text == "앞👩🏽‍💻뒤","글자 중앙의 세로 획은 가까운 다른 caret에 나누기로 오적용하지 않음")
        install("가나다")
        guard let session = controller.parent.editSession(),
              let position = view.position(from:view.beginningOfDocument,offset:1) else { throw CocoaError(.validationMissingMandatoryProperty) }
        let caret = view.caretRect(for:position)
        let points = vertical(CGPoint(x:caret.midX,y:caret.midY),down:true)
        let snapshot = CanvasPencilTextSnapshot(text:view.text,session:session,selection:view.selectedRange)
        view.selectedRange = NSRange(location:view.selectedRange.location == 0 ? 1 : 0,length:0)
        controller.applyCorrection(points,snapshot:snapshot)
        try check(view.text == "가나다","Pencil 시작 후 선택이 달라지면 snapshot 획 적용 거부")
    }

    private static func checkSelectionCorrections(view: VaultMarkdownEditor.NodeTextView,
                                                  controller: VaultMarkdownEditor.Coordinator,
                                                  check: (Bool,String) throws -> Void) async throws {
        let source = "앞👩🏽‍💻e\u{301}뒤"
        let selection = NSRange(location:1,length:"👩🏽‍💻".utf16.count)
        func install(_ text: String = "앞👩🏽‍💻e\u{301}뒤", range: NSRange? = nil) {
            controller.cancelSelectionCorrection()
            view.text = text
            view.selectedRange = range ?? selection
            controller.textViewDidChange(view)
            view.undoManager?.removeAllActions()
        }
        func begin() throws -> CanvasPencilTextSnapshot {
            guard let snapshot = controller.beginSelectionCorrection() else { throw CocoaError(.validationMissingMandatoryProperty) }
            return snapshot
        }
        install()
        let nativeAction = UIAction(title:"기존 편집") { _ in }
        let menu = controller.textView(view,editMenuForTextIn:selection,suggestedActions:[nativeAction])
        try check(menu?.children.contains(where:{ ($0 as? UIAction)?.title == "선택 글자 교정…" }) == true &&
                  menu?.children.first === nativeAction,"실제 UITextView 편집메뉴에 선택 교정을 추가하고 기본 동작 보존")
        let cancelled = try begin()
        controller.cancelSelectionCorrection(cancelled)
        try check(view.text.utf8.elementsEqual(source.utf8) && view.undoManager?.canUndo != true &&
                  !controller.confirmSelectionCorrection(cancelled,replacement:"취소 뒤 교정"),"선택 교정 취소는 원문·Undo를 바꾸지 않고 늦은 확정 거부")
        let snapshot = try begin()
        controller.cancelSelectionCorrection(cancelled)
        try check(controller.pendingCorrection?.id == snapshot.id,"이전 창의 취소는 새 교정 요청을 취소하지 않음")
        view.undoManager?.beginUndoGrouping()
        let applied = controller.confirmSelectionCorrection(snapshot,replacement:"한글")
        view.undoManager?.endUndoGrouping()
        try check(applied && view.text == "앞한글e\u{301}뒤","명시 교정이 선택 emoji 전체만 바꾸고 결합문자 보존")
        try check(!controller.confirmSelectionCorrection(snapshot,replacement:"중복"),"같은 교정 확정은 한 번만 소비")
        view.undoManager?.undo(); controller.textViewDidChange(view)
        try check(view.text.utf8.elementsEqual(source.utf8),"선택 교정 Undo의 UTF8 원문 복원")
        view.undoManager?.redo(); controller.textViewDidChange(view)
        try check(view.text == "앞한글e\u{301}뒤","선택 교정 Redo")
        install()
        let changedSelection = try begin()
        view.selectedRange = NSRange(location:0,length:1)
        controller.textViewDidChangeSelection(view)
        try check(!controller.confirmSelectionCorrection(changedSelection,replacement:"오적용") && view.text == source,"선택 변경 후 교정 거부")
        install()
        let changedSource = try begin()
        view.text = "새 입력"
        controller.textViewDidChange(view)
        try check(!controller.confirmSelectionCorrection(changedSource,replacement:"오적용") && view.text == "새 입력" &&
                  controller.parent.text == "새 입력","교정 도중 새 입력과 바인딩 보존")
        install()
        let changedBinding = try begin()
        controller.parent.text = "외부에서 갱신한 초안"
        try check(!controller.confirmSelectionCorrection(changedBinding,replacement:"오적용") &&
                  controller.parent.text == "외부에서 갱신한 초안" && view.text == source,"화면보다 먼저 갱신된 원문도 덮어쓰지 않음")
        install()
        let composition = try begin()
        view.setMarkedText("조합",selectedRange:NSRange(location:1,length:0))
        let composingText = view.text
        try check(!controller.confirmSelectionCorrection(composition,replacement:"오적용") && view.text == composingText &&
                  controller.beginSelectionCorrection() == nil,"실제 UITextView IME 조합 동안 교정 시작과 확정 거부")
        view.unmarkText()
        install()
        if let scribble = view.interactions.compactMap({ $0 as? UIScribbleInteraction }).first {
            let writing = try begin()
            controller.scribbleInteractionWillBeginWriting(scribble)
            try check(!controller.confirmSelectionCorrection(writing,replacement:"오적용") && controller.beginSelectionCorrection() == nil,
                      "Scribble 시작은 열린 선택 교정을 무효화")
            controller.scribbleInteractionDidFinishWriting(scribble)
        } else { throw CocoaError(.validationMissingMandatoryProperty) }
        install()
        let expired = try begin()
        let session = controller.parent.editSession
        controller.parent.editSession = { nil }
        try check(!controller.confirmSelectionCorrection(expired,replacement:"오적용") && view.text == source,"만료 세션의 수동 교정 거부")
        controller.parent.editSession = session
        install()
        guard let toolbar = view.inputAccessoryView as? UIToolbar,
              let item = toolbar.items?.first(where:{ $0.accessibilityIdentifier == "canvasSelectedTextCorrection" }),
              let action = item.action else { throw CocoaError(.validationMissingMandatoryProperty) }
        UIApplication.shared.sendAction(action,to:item.target,from:item,for:nil)
        try await Task.sleep(for:.milliseconds(350))
        var responder: UIResponder? = view
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let presenter = responder as? UIViewController,
              let alert = presenter.presentedViewController as? UIAlertController,
              let field = alert.textFields?.first else { throw CocoaError(.validationMissingMandatoryProperty) }
        try check(alert.title == "선택 글자 교정" && field.accessibilityIdentifier == "canvasSelectedTextCorrectionInput" &&
                  field.text == "👩🏽‍💻" && alert.actions.map(\.title) == ["취소","입력 그대로 적용","적용"] &&
                  alert.preferredAction?.isEnabled == false && alert.actions[1].isEnabled == false,
                  "실제 수동 교정 창은 원래 선택 글자·취소·명시 적용과 원문 경로를 표시")
        field.text = "고침"
        field.sendActions(for:.editingChanged)
        try check(alert.preferredAction?.isEnabled == true && view.text == source,"대체 입력만으로 원문을 확정하지 않음")
        field.setMarkedText("조합",selectedRange:NSRange(location:1,length:0))
        field.sendActions(for:.editingChanged)
        try check(alert.preferredAction?.isEnabled == false && view.text == source,"교정 입력창 IME 중 적용 비활성")
        field.unmarkText()
        controller.cancelSelectionCorrection()
        for _ in 0..<40 {
            if presenter.presentedViewController == nil { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        try check(presenter.presentedViewController == nil,"이전 교정 창이 닫힌 뒤 다음 네이티브 입력 검사 시작")
        view.becomeFirstResponder()
        try await Task.sleep(for:.milliseconds(200))
        install("가다\n\n보존할 문단\n",range:NSRange(location:0,length:2))
        UIApplication.shared.sendAction(action,to:item.target,from:item,for:nil)
        try await Task.sleep(for:.milliseconds(350))
        guard let wordAlert = presenter.presentedViewController as? UIAlertController,
              let wordField = wordAlert.textFields?.first,
              let wordSnapshot = controller.pendingCorrection else {
            throw NSError(domain:"PencilTextCorrectionFixture",code:2,userInfo:[NSLocalizedDescriptionKey:"단어 교정 창 준비 실패 presented=\(String(describing:presenter.presentedViewController)) selection=\(view.selectedRange) pending=\(controller.pendingCorrection != nil)"])
        }
        wordField.text = " 가구 ."
        wordField.sendActions(for:.editingChanged)
        try check(wordAlert.message?.hasPrefix("적용 결과: \("가구".debugDescription)") == true &&
                  wordAlert.message?.contains("입력 그대로 적용: \(" 가구 .".debugDescription)") == true &&
                  wordAlert.preferredAction?.isEnabled == true && wordAlert.actions[1].isEnabled,
                  "실제47 관측 입력은 정리된 단어와 원문 두 결과를 표시하고 명시 적용을 기다림")
        wordField.text = " 가다 ."
        wordField.sendActions(for:.editingChanged)
        try check(wordAlert.preferredAction?.isEnabled == false && wordAlert.actions[1].isEnabled,
                  "정리 결과가 원래 단어와 같으면 기본 변경은 막고 의도한 원문 적용은 허용")
        for raw in ["가구."," 가구 다리 "," 3.14 .","`가구`","**가구**","가구\n"," e\u{301} ."] {
            wordField.text = raw
            wordField.sendActions(for:.editingChanged)
            let observed = wordField.text ?? ""
            if raw == "가구\n" {
                try check(observed == "가구","UIKit 단일 줄 입력칸은 줄바꿈을 받지 않음")
            } else {
                try check(observed.utf8.elementsEqual(raw.utf8),"네이티브 입력값의 UTF8 보존 \(raw.debugDescription)")
            }
            let input = CanvasPencilTextCorrectionInput(text:wordSnapshot.text,selection:wordSnapshot.selection,raw:observed)
            try check(wordAlert.message?.hasPrefix("적용 결과: \(input.preferred.debugDescription)") == true &&
                      wordAlert.actions[1].isEnabled == (input.word != nil),
                      "네이티브 미리보기와 실제 입력 바이트가 일치 \(observed.debugDescription)")
        }
        wordField.text = " 가구 ."
        wordField.sendActions(for:.editingChanged)
        wordField.setMarkedText("조합",selectedRange:NSRange(location:1,length:0))
        wordField.sendActions(for:.editingChanged)
        try check(wordAlert.actions.filter({ $0.style != .cancel }).allSatisfy({ !$0.isEnabled }),
                  "단어 적용과 원문 적용 모두 교정 입력창 IME 동안 비활성")
        wordField.unmarkText()
        controller.cancelSelectionCorrection()
        try await Task.sleep(for:.milliseconds(150))
        for rawMode in [false,true] {
            let original = "가다\n\n보존할 문단\n"
            install(original,range:NSRange(location:0,length:2))
            let snapshot = try begin()
            let input = CanvasPencilTextCorrectionInput(text:original,selection:snapshot.selection,raw:" 가구 .")
            view.undoManager?.beginUndoGrouping()
            let applied = controller.confirmSelectionCorrection(snapshot,replacement:rawMode ? input.raw : input.preferred)
            view.undoManager?.endUndoGrouping()
            let expected = rawMode ? " 가구 .\n\n보존할 문단\n" : "가구\n\n보존할 문단\n"
            try check(applied && view.text.utf8.elementsEqual(expected.utf8),"명시한 기본·원문 결과만 UITextView 선택 범위에 적용 \(rawMode)")
            view.undoManager?.undo(); controller.textViewDidChange(view)
            try check(view.text.utf8.elementsEqual(original.utf8),"기본·원문 교정 Undo 원문 복원 \(rawMode)")
            view.undoManager?.redo(); controller.textViewDidChange(view)
            try check(view.text.utf8.elementsEqual(expected.utf8),"기본·원문 교정 Redo 결과 보존 \(rawMode)")
        }
        view.becomeFirstResponder()
        install("가다",range:NSRange(location:1,length:1))
    }

    private static func checkVaultEditors(host: UIHostingController<AnyView>,
                                         connection: (address: String,token: String)? = nil,
                                         check: (Bool,String) throws -> Void) async throws {
        func note(_ text: String, path: String = "Pencil/isolated.md") -> VaultNoteSnapshot {
            VaultNoteSnapshot(path:path,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"test")
        }
        let store = CanvasStore(blockRecoveryURL:FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("recovery.json"))
        let preservedScene = store.scene
        defer { store.scene = preservedScene; store.saveNow() }
        let relay = connection.map { CanvasRelay(address:$0.address,token:$0.token) }
        var fixture = note("가나다 ^pencil-1\n\n보존할 문단\n")
        func load(_ path: String) async throws -> VaultNoteSnapshot {
            if let relay { return try await relay.vaultNote(at:path) }
            return fixture
        }
        func save(_ path: String,_ sha: String,_ text: String) async throws -> VaultNoteSnapshot {
            if let relay { return try await relay.saveVaultNote(at:path,baseSha256:sha,text:text) }
            fixture = note(text,path:path)
            return fixture
        }
        store.setNoteConnection(address:connection?.address ?? "http://pencil-fixture.invalid",
                                token:connection?.token ?? "fixture")
        let original = try await load(relay == nil ? fixture.path : "REA-Pencil-Obsidian.md")
        try check(original.text.utf8.elementsEqual("가나다 ^pencil-1\n\n보존할 문단\n".utf8),
                  "원문·문단 검사의 격리 fixture 본문 확인")
        await store.openVaultNote(original.path,load:load)
        store.vaultSelection = NSRange(location:0,length:3)
        let nodeID = await store.excerptSelectedVaultBlock(save:{ _,_,_ in
            throw URLError(.badURL)
        },load:load)
        guard let nodeID else { throw CocoaError(.validationMissingMandatoryProperty) }
        _ = store.closeVaultEditor()
        await store.openVaultNote(original.path,nodeID:nodeID,load:load)

        func mount() async throws -> (VaultMarkdownEditor.NodeTextView,VaultMarkdownEditor.Coordinator,UIBarButtonItem,UIScribbleInteraction) {
            let block = store.vaultBlockEditing
            let editor = VaultMarkdownEditor(
                text:Binding(get:{ block ? store.vaultBlockDraft : store.vaultDraft },set:{
                    if block { store.vaultBlockDraft = $0 } else { store.vaultDraft = $0 }
                }),selection:.constant(NSRange(location:0,length:0)),
                inputBusy:Binding(get:{ store.vaultInputBusy },set:{ store.vaultInputBusy = $0 }),
                editSession:{ store.vaultInputSessionID })
            host.rootView = AnyView(editor.id(store.vaultInputSessionID).frame(width:600,height:300))
            try await Task.sleep(for:.milliseconds(250))
            host.view.layoutIfNeeded()
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            guard let view = descendants(host.view).compactMap({ $0 as? VaultMarkdownEditor.NodeTextView }).first,
                  let controller = view.delegate as? VaultMarkdownEditor.Coordinator,
                  let toolbar = view.inputAccessoryView as? UIToolbar,
                  let mode = toolbar.items?.first(where:{ $0.accessibilityIdentifier == "canvasPencilCorrectionMode" }),
                  let scribble = view.interactions.compactMap({ $0 as? UIScribbleInteraction }).first else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            view.becomeFirstResponder()
            try await Task.sleep(for:.milliseconds(150))
            host.view.layoutIfNeeded()
            return (view,controller,mode,scribble)
        }
        func toggle(_ mode: UIBarButtonItem) throws {
            guard let action = mode.action else { throw CocoaError(.validationMissingMandatoryProperty) }
            UIApplication.shared.sendAction(action,to:mode.target,from:mode,for:nil)
        }
        func correct(_ view: UITextView, _ controller: VaultMarkdownEditor.Coordinator) throws -> [CGPoint] {
            view.layoutManager.ensureLayout(for:view.textContainer)
            guard let start = view.position(from:view.beginningOfDocument,offset:1),
                  let end = view.position(from:start,offset:1),
                  let range = view.textRange(from:start,to:end),
                  let rect = view.selectionRects(for:range).map(\.rect).first(where:{ $0.width > 0 }) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let scratch = (0...5).map { index in
                CGPoint(x:rect.midX + (index % 2 == 0 ? -1 : 1) * rect.width * 0.45,
                        y:rect.midY + (index % 2 == 0 ? -1 : 1))
            }
            controller.applyCorrection(scratch,expectedText:view.text)
            try check(view.text.hasPrefix("가다"),"Obsidian 편집기에서 실제 글자 폭으로 나 삭제")
            func vertical(down: Bool) -> [CGPoint] {
                let caret = view.caretRect(for:start)
                return (0...6).map { index in
                    CGPoint(x:caret.midX,y:caret.midY + (down ? -24 : 24) + CGFloat(index) * (down ? 8 : -8))
                }
            }
            controller.applyCorrection(vertical(down:true),expectedText:view.text)
            try check(view.text.hasPrefix("가 다"),"Obsidian 편집기의 아래 획 나누기")
            controller.applyCorrection(vertical(down:false),expectedText:view.text)
            try check(view.text.hasPrefix("가다"),"Obsidian 편집기의 위 획 합치기")
            return scratch
        }
        func scribbleReplace(_ view: UITextView, _ controller: VaultMarkdownEditor.Coordinator, text: String) throws {
            guard let start = view.position(from:view.beginningOfDocument,offset:1),
                  let end = view.position(from:start,offset:1),
                  let range = view.textRange(from:start,to:end) else { throw CocoaError(.validationMissingMandatoryProperty) }
            view.replace(range,withText:text)
            controller.textViewDidChange(view)
        }
        func manuallyCorrect(_ view: UITextView, _ controller: VaultMarkdownEditor.Coordinator, text: String) throws {
            let before = view.text ?? ""
            view.selectedRange = NSRange(location:1,length:1)
            controller.textViewDidChangeSelection(view)
            guard let cancelled = controller.beginSelectionCorrection() else { throw CocoaError(.validationMissingMandatoryProperty) }
            try check(store.vaultInputBusy && !store.vaultCanSave && !store.vaultBlockCanSave,
                      "원문·연결 문단의 명시 교정 중 기존 저장과 CAS 전송 대기")
            controller.cancelSelectionCorrection(cancelled)
            try check(!store.vaultInputBusy && view.text == before,"원문·연결 문단의 교정 취소는 초안과 입력 상태 보존")
            guard let snapshot = controller.beginSelectionCorrection() else { throw CocoaError(.validationMissingMandatoryProperty) }
            try check(controller.confirmSelectionCorrection(snapshot,replacement:text) && !store.vaultInputBusy,
                      "원문·연결 문단에 공통 선택 교정 확정 경로 적용")
            try check(view.text == (before as NSString).replacingCharacters(in:NSRange(location:1,length:1),with:text),
                      "선택 글자 교정은 블록 표식·인접 문자·나머지 문단 보존")
        }
        let (whole,wholeController,wholeMode,wholeScribble) = try await mount()
        let wholeSession = store.vaultInputSessionID
        try toggle(wholeMode)
        let wholeStroke = try correct(whole,wholeController)
        try check(store.vaultDraft.hasPrefix("가다") && store.vaultInputSessionID == wholeSession,
                  "원문의 교정 결과와 동일 세션 연결")
        try toggle(wholeMode)
        try manuallyCorrect(whole,wholeController,text:"구")
        wholeController.scribbleInteractionWillBeginWriting(wholeScribble)
        try scribbleReplace(whole,wholeController,text:"구")
        try check(store.vaultDraft.hasPrefix("가구"),"원문 Scribble의 실제 UITextView 교정 결과 연결")
        try check(store.vaultInputBusy && !store.vaultCanSave && !store.vaultCanAttach,
                  "원문 Scribble 중 저장과 문단 전환 차단")
        var writes = 0
        await store.saveVaultNote { path,sha,text in writes += 1; return try await save(path,sha,text) }
        try check(writes == 0 && !store.closeVaultEditor(discard:true),"조합 중 원문은 전송하거나 닫지 않음")
        wholeController.scribbleInteractionDidFinishWriting(wholeScribble)
        try check(!store.vaultInputBusy && store.vaultCanSave,"Scribble 종료 뒤 저장 재개")
        await store.saveVaultNote { path,sha,text in
            try check(sha == original.sha256,"원문 Pencil 결과도 기존 SHA CAS 사용")
            writes += 1
            return try await save(path,sha,text)
        }
        try check(writes == 1 && !store.vaultDirty,"원문 교정 저장 결과 수용")
        try toggle(wholeMode)
        let wholeSaved = store.vaultNote!
        try check(store.closeVaultEditor(),"원문 교정 저장 뒤 닫기")
        await store.openVaultNote(original.path,nodeID:nodeID,load:load)
        try check(store.vaultNote?.sha256 == wholeSaved.sha256 &&
                  store.vaultDraft.utf8.elementsEqual(wholeSaved.text.utf8),"원문 교정 저장 뒤 같은 SHA로 재열기")
        let beforeBlockSession = store.vaultInputSessionID
        try check(store.beginLinkedBlockEdit() && store.vaultInputSessionID != beforeBlockSession,
                  "문단 진입은 원문 세션을 퇴역시킴")
        let blockBefore = store.vaultBlockDraft, wholeBefore = store.vaultDraft
        whole.text = "가나다"
        wholeController.textViewDidChange(whole)
        wholeController.applyCorrection(wholeStroke,expectedText:whole.text)
        wholeController.scribbleInteractionWillBeginWriting(wholeScribble)
        try check(whole.text == "가나다" && store.vaultDraft == wholeBefore &&
                  store.vaultBlockDraft == blockBefore && !store.vaultInputBusy,
                  "문단 전환 후 옛 원문 delegate·제스처·Scribble 거부")
        let (block,blockController,blockMode,blockScribble) = try await mount()
        block.text = "가나다라"
        blockController.textViewDidChange(block)
        try toggle(blockMode)
        let blockStroke = try correct(block,blockController)
        try check(store.vaultBlockDraft == "가다라" && store.blockRecovery?.draft == "가다라",
                  "문단 Pencil 결과를 기존 복구 기록에 보존")
        try toggle(blockMode)
        try manuallyCorrect(block,blockController,text:"마")
        blockController.scribbleInteractionWillBeginWriting(blockScribble)
        try scribbleReplace(block,blockController,text:"마")
        try check(store.vaultBlockDraft == "가마라" && store.blockRecovery?.draft == "가마라",
                  "문단 Scribble의 실제 교정과 복구 기록 연결")
        var blockWrites = 0
        await store.saveLinkedBlock(replace:{ _,_,_ in
            blockWrites += 1; throw URLError(.badURL)
        },load:{ _ in original })
        try check(store.vaultInputBusy && !store.vaultBlockCanSave && blockWrites == 0,
                  "문단 Scribble 중 부분 입력 전송 차단")
        blockController.scribbleInteractionDidFinishWriting(blockScribble)
        let base = store.vaultNote!
        var saved = base
        await store.saveLinkedBlock(replace:{ _,id,edit in
            blockWrites += 1
            try check(id == "pencil-1" && edit.baseSha256 == base.sha256,"문단 Pencil 결과의 블록 ID와 SHA CAS 유지")
            if let relay {
                let result = try await relay.replaceVaultBlock(at:base.path,blockID:id,edit:edit)
                saved = result.note
                return result
            }
            saved = note(try VaultMarkdownBlocks(base.text).replacing(id,with:edit.replacementText))
            fixture = saved
            return VaultBlockEditResult(schemaVersion:1,operationId:edit.operationId,blockID:id,
                disposition:"committed",quoteSha256:CanvasPacket.sha(Data(edit.replacementText.utf8)),note:saved)
        },load:load)
        try check(blockWrites == 1 && !store.vaultDirty && saved.text.hasSuffix("보존할 문단\n"),
                  "문단 교정 저장과 재조회 뒤 나머지 원문 보존")
        block.selectedRange = NSRange(location:1,length:0)
        block.setMarkedText("조합",selectedRange:NSRange(location:1,length:0))
        try check(store.vaultInputBusy && !store.vaultBlockCanSave,"실제 UITextView 조합 시작을 Store에 연결")
        block.unmarkText()
        try check(!store.vaultInputBusy,"실제 UITextView 조합 종료를 Store에 연결")
        let retained = store.vaultBlockDraft
        try toggle(blockMode)
        store.setNoteConnection(address:"http://replacement.invalid",token:"replacement")
        block.text = "가나다라"
        blockController.textViewDidChange(block)
        blockController.applyCorrection(blockStroke,expectedText:block.text)
        blockController.scribbleInteractionWillBeginWriting(blockScribble)
        try check(block.text == "가나다라" && store.vaultInputSessionID == nil &&
                  store.vaultBlockDraft == retained && !store.vaultInputBusy,
                  "연결 교체 후 옛 문단 입력과 Scribble 거부")
        blockController.retire(block)
        blockController.scribbleInteractionDidFinishWriting(blockScribble)
        try check(store.vaultBlockDraft == retained,"퇴역 뒤 지연된 입력 종료도 초안을 보존")
        store.setNoteConnection(address:connection?.address ?? "http://pencil-fixture.invalid",
                                token:connection?.token ?? "fixture")
        try check(store.closeVaultEditor(discard:true),"전송하지 않은 조합 입력을 닫고 저장 원문 확인 준비")
        await store.openVaultNote(original.path,nodeID:nodeID,load:load)
        try check(store.vaultNote?.sha256 == saved.sha256 && store.vaultDraft.utf8.elementsEqual(saved.text.utf8),
                  "문단 교정 저장 뒤 닫기·재열기와 원문 SHA 재조회")
        let (last,lastController,_,lastScribble) = try await mount()
        let finalDraft = store.vaultDraft
        store.scene = CanvasScene()
        last.text = "옛 장면의 지연 입력"
        lastController.textViewDidChange(last)
        lastController.scribbleInteractionWillBeginWriting(lastScribble)
        try check(store.vaultInputSessionID == nil && !store.vaultInputBusy && store.vaultDraft == finalDraft,
                  "장면 교체 후 실제 UITextView와 Scribble의 늦은 콜백 거부")
    }
}

@main
struct PencilTextCorrectionProbeApp: App {
    init() {
        do { try CanvasRuntime.writeRuntimeReceipt() }
        catch { print("PENCIL_RUNTIME_RECEIPT_FAILED") }
    }
    var body: some Scene { WindowGroup {
        if ProcessInfo.processInfo.arguments.contains("--ccr-pencil-native-check") {
            PencilTextCorrectionProbe()
        } else { CanvasWorkspace() }
    } }
}
private struct PencilTextCorrectionProbe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView:AnyView(Text("펜 교정 검사 중")))
        Task { @MainActor in
            do {
                let result = try await PencilTextCorrectionChecks.run(host:host)
                print(result)
                host.rootView = AnyView(VStack {
                    Text(result).font(.caption).accessibilityIdentifier("pencilCorrectionNativeResult")
                    CanvasWorkspace()
                })
            } catch {
                let result = "FAIL \(error.localizedDescription)"
                print(result)
                host.rootView = AnyView(Text(result).accessibilityIdentifier("pencilCorrectionNativeResult"))
            }
        }
        return host
    }
    func updateUIViewController(_ host: UIHostingController<AnyView>, context: Context) { }
}
#endif
