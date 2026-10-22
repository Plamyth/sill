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
        try await checkVaultEditors(host:host,check:check)
        try await checkVaultEditors(host:host,connection:connection,check:check)
        return "PENCIL_CORRECTION total=\(checks) failed=0 productionGeometry=true injectedTrace=true physicalPencil=false vaultRoundTrip=true fixture=REA-Pencil-Obsidian.md"
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
        let (whole,wholeController,wholeMode,wholeScribble) = try await mount()
        let wholeSession = store.vaultInputSessionID
        try toggle(wholeMode)
        let wholeStroke = try correct(whole,wholeController)
        try check(store.vaultDraft.hasPrefix("가다") && store.vaultInputSessionID == wholeSession,
                  "원문의 교정 결과와 동일 세션 연결")
        try toggle(wholeMode)
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
