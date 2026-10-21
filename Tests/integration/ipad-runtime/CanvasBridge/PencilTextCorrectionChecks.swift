#if DEBUG && CANVAS_PENCIL_CORRECTION_CHECK
import PencilKit
import SwiftUI
import UIKit

@MainActor
enum PencilTextCorrectionChecks {
    static func run(host: UIHostingController<AnyView>) async throws -> String {
        guard case .isolated = CanvasRuntime.launch else { throw CocoaError(.fileWriteNoPermission) }
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
            nodeEditing:true,editSession:{ store.proposalInputSessionID })
        host.rootView = AnyView(editor.frame(width:600,height:300))
        try await Task.sleep(for:.milliseconds(250))
        host.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        guard let view = descendants(host.view).compactMap({ $0 as? VaultMarkdownEditor.NodeTextView }).first,
              let controller = view.delegate as? VaultMarkdownEditor.Coordinator,
              let toolbar = view.inputAccessoryView as? UIToolbar,
              let mode = toolbar.items?.first(where:{ $0.accessibilityIdentifier == "canvasPencilCorrectionMode" }),
              let action = mode.action else { throw CocoaError(.validationMissingMandatoryProperty) }
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
        guard let start = view.position(from:view.beginningOfDocument,offset:1),
              let end = view.position(from:start,offset:1),
              let range = view.textRange(from:start,to:end) else { throw CocoaError(.validationMissingMandatoryProperty) }
        view.replace(range,withText:"구")
        controller.textViewDidChange(view)
        try check(view.text == "가구" && store.proposalText == "가구","기존 네이티브 입력의 글자 교정 결과 연결")
        UIApplication.shared.sendAction(action,to:mode.target,from:mode,for:nil)
        try check(store.proposalInputSessionID == session && store.proposalIsCurrent,"수정 중 원래 요소·입력 세션 유지")
        store.confirmProposal()
        store.saveNow()
        let reopened = CanvasStore()
        try check(reopened.scene.nodes.first(where:{ $0.id == node.id })?.text == "가구","파일 저장 후 Store 재열기")
        try check(reopened.scene.drawingBase64 == originalDrawing && reopened.scene.strokes == originalStrokes,
                  "원본 잉크·출처 획 보존")
        try check(reopened.scene.nodes.first(where:{ $0.id == node.id })?.sourceStrokeIds == node.sourceStrokeIds,
                  "노드 ID·원본 획 참조 보존")
        controller.applyCorrection(scratch,expectedText:view.text)
        try check(view.text == "가구","확정된 이전 편집 세션에 늦은 제스처 적용 금지")
        return "PENCIL_CORRECTION total=\(checks) failed=0 productionGeometry=true injectedTrace=true physicalPencil=false"
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
