import Foundation
import PDFKit
import SwiftUI

@MainActor func checkPDFCardFields(_ check: (Bool,String) -> Void) async throws {
    let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!)
    let pdfURL = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PDF_RECOVERY_FIXTURE"]!)
    let bytes = try Data(contentsOf:pdfURL)
    let snapshot = VaultPDFSnapshot(path:"문서/원본.pdf",sha256:CanvasPacket.sha(bytes),dataBase64:bytes.base64EncodedString())
    let document = PDFDocument(data:bytes)!, page = document.page(at:0)!
    let selected = page.selection(for:NSRange(location:0,length:(page.string! as NSString).length))!
    let source = try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,selection:selected)
    let markdown = try source.markdown()
    let title = "  서로 다른 제목 e\u{301} 👩🏽‍💻 *literal*  "
    let memo = "  댓글 e\u{301} 👩🏽‍💻\r\n둘째 줄\n끝\r"
    let canonical = try VaultPDFCard.parse(markdown)!
    check(canonical.title == "PDF 발췌" && canonical.memo.isEmpty && canonical.source == source,
          "existing PDF Markdown exposes separate title, immutable source quote and empty memo")
    for eol in ["\n","\r\n"] {
        let original = markdown.replacingOccurrences(of:"\n",with:eol)
        let initial = try VaultPDFCard.parse(original)!
        let titled = try initial.replacing(.title,with:title)
        let edited = try VaultPDFCard.parse(titled)!.replacing(.memo,with:memo)
        let card = try VaultPDFCard.parse(edited)!
        check(card.title.utf8.elementsEqual(title.utf8) && card.memo.utf8.elementsEqual(memo.utf8),
              "field edits preserve exact Unicode, whitespace and mixed/trailing CR content")
        check(card.source == source && edited.hasSuffix(original.components(separatedBy:"```ccr-pdf-source-v2")[1]),
              "title and memo leave the exact provenance fence and original SHA/ranges/quote unchanged")
        let restored = try VaultPDFCard.parse(card.replacing(.memo,with:initial.memo))!.replacing(.title,with:initial.title)
        check(restored.utf8.elementsEqual(original.utf8),"editing fields back restores every original LF/CRLF Markdown byte")
        let (_,_,selection) = try card.source.sourcePage(in:snapshot)
        check(selection.string?.utf8.elementsEqual(selected.string!.utf8) == true,
              "edited card returns to the same native PDF text range and quote")
    }
    check(try VaultPDFCard.parse("# 일반 노트\n\n메모만 있습니다.") == nil,
          "a source-free ordinary Markdown note is not classified as a PDF card")
    check(try VaultPDFCard.parse("````markdown\n" + markdown + "````\n") == nil,
          "an example PDF source inside a code block is not a PDF card")
    for bad in [markdown + markdown,markdown.replacingOccurrences(of:"ccr-pdf-source-v2",with:"ccr-pdf-source-v99"),
                markdown.replacingOccurrences(of:"> 한글",with:"> 바뀐 인용"),"설명\n" + markdown] {
        do { _ = try VaultPDFCard.parse(bad); check(false,"malformed or ambiguous PDF fields must refuse") }
        catch { check(true,"damaged, duplicate or ambiguous PDF source cannot become editable PDF fields") }
    }
    do { _ = try canonical.replacing(.title,with:"제목\n다른 제목");check(false,"multiline title refuses") }
    catch { check(true,"title newline cannot move quotation or memo boundaries") }
    let example = "````markdown\n```ccr-pdf-source-v99\n{}\n```\n````\n"
    check(try VaultPDFCard.parse(canonical.replacing(.memo,with:example))!.source == source,
          "memo code examples remain editable without becoming source metadata")
    do { _ = try canonical.replacing(.memo,with:markdown);check(false,"real second provenance refuses") }
    catch { check(true,"memo cannot inject a second real provenance block") }
    let extra = markdown + "\n외부에서 출처 뒤에 보완한 내용\n"
    check(try VaultPDFCard.parse(VaultPDFCard.parse(extra)!.replacing(.title,with:title))!.additionalMarkdown.hasSuffix("외부에서 출처 뒤에 보완한 내용\n"),
          "title editing preserves and displays additional external Markdown after the source")
    let note = VaultNoteSnapshot(path:source.notePath,text:markdown,sha256:CanvasPacket.sha(Data(markdown.utf8)),modifiedAt:"fixture")
    func store(_ name: String) -> CanvasStore {
        let result = CanvasStore(noteRecoveryURL:root.appendingPathComponent(name + ".json"),
            pdfExcerptRecoveryURL:root.appendingPathComponent(name + "-pdf.json"))
        result.scene = CanvasScene()
        result.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
        return result
    }
    let state = store("field-journal")
    await state.openVaultNote(note.path,load:{_ in note})
    let id = state.attachOpenedVaultNote()!, originalScene = state.scene
    let session = state.vaultPDFEditSession!
    let ui = PDFUIBindings(store:state,session:session)
    ui.text(.title).wrappedValue = title
    ui.text(.memo).wrappedValue = memo
    check(try VaultPDFCard.parse(state.vaultDraft)!.title == title && VaultPDFCard.parse(state.vaultDraft)!.memo == memo,
          "actual UI field Binding setters update the single existing Store Markdown draft")
    check(state.vaultDirty && state.noteRecovery?.draft == state.vaultDraft && state.scene == originalScene,
          "field input is durable in the existing note journal while saved card projection stays unchanged")
    check(VaultPDFCard.previewLines(state.scene.nodes.first(where:{$0.id == id})!.text)?.count == 3 &&
          !state.scene.nodes[0].text.contains("ccr-pdf-source") && !state.scene.nodes[0].text.contains("textRanges"),
          "canvas projects labeled title/quote/memo and never raw provenance JSON")
    let draft = state.vaultDraft
    await state.saveVaultNote(save:{path,sha,text in
        check(path == note.path && sha == note.sha256,"PDF fields reuse the original note path and Markdown CAS base")
        return VaultNoteSnapshot(path:path,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"fixture")
    },load:{_ in VaultNoteSnapshot(path:note.path,text:draft,sha256:CanvasPacket.sha(Data(draft.utf8)),modifiedAt:"fixture")})
    check(!state.vaultDirty && state.noteRecovery == nil && state.scene.nodes[0].text.contains("서로 다른 제목") &&
          state.scene.nodes[0].text.contains("댓글") && state.scene.nodes[0].id == id,
          "confirmed CAS and GET update the same existing card to the saved title and memo")
    ui.text(.memo).wrappedValue = "저장 전 stale 입력"
    check(state.vaultDraft == draft,"UI session with an old base SHA cannot overwrite confirmed fields")
    for conflict in [VaultSaveConflict.reconciliationRequired,.unclassified] {
        let held = store("held-\(conflict.rawValue)")
        await held.openVaultNote(note.path,load:{_ in note})
        let heldUI = PDFUIBindings(store:held,session:held.vaultPDFEditSession!)
        heldUI.text(.memo).wrappedValue = "보존할 충돌 댓글"
        await held.saveVaultNote {_,_,_ in
            throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:conflict.rawValue])
        }
        let heldDraft = held.vaultDraft, record = held.noteRecovery
        heldUI.text(.title).wrappedValue = "충돌에서 덮기"
        heldUI.text(.memo).wrappedValue = "충돌 댓글 덮기"
        check(held.vaultBlocked && held.vaultDraft == heldDraft && held.noteRecovery == record && record?.saveConflict == conflict,
              "typed or unclassified conflict preserves field input and cannot be overwritten through UI bindings")
    }
    let busy = store("busy-fields")
    await busy.openVaultNote(note.path,load:{_ in note})
    let busyUI = PDFUIBindings(store:busy,session:busy.vaultPDFEditSession!)
    busyUI.inputBusy(.title).wrappedValue = true
    check(busy.vaultInputBusy,"actual UI title composition leases the existing input-busy state")
    busyUI.inputBusy(.memo).wrappedValue = true
    busyUI.inputBusy(.title).wrappedValue = false
    check(busy.vaultInputBusy,"memo composition keeps input ownership after title composition ends")
    busyUI.inputBusy(.memo).wrappedValue = false
    check(!busy.vaultInputBusy,"ending both actual field bindings returns the existing input lease")
    let tampered = store("tampered-source")
    await tampered.openVaultNote(note.path,load:{_ in note})
    let tamperSession = tampered.vaultPDFEditSession!
    var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as! [String:Any]
    object["quote"] = source.quote.replacingOccurrences(of:"é",with:"e\u{301}")
    let equivalentQuote = try JSONDecoder().decode(VaultPDFExcerpt.self,from:JSONSerialization.data(withJSONObject:object))
    let altered = try equivalentQuote.markdown()
    check(!equivalentQuote.quote.utf8.elementsEqual(source.quote.utf8) && equivalentQuote.quote == source.quote,
          "counterexample changes quote bytes while Swift Unicode equality still considers the text equal")
    tampered.vaultDraft = altered
    check(tampered.vaultPDFEditSession == nil && !tampered.editVaultPDF(.title,text:"은밀한 인용 덮기",session:tamperSession) && tampered.vaultDraft == altered,
          "field input cannot accept byte-changed source quote through Unicode canonical equivalence")
    let noTitle = try canonical.replacing(.title,with:"")
    check(try VaultPDFCard.parse(noTitle)!.title.isEmpty && VaultPDFCard.parse(noTitle)!.sourceSHA256 == canonical.sourceSHA256,
          "empty title remains editable without replacing the source or memo")
    let invalid = note.text + note.text
    let broken = store("broken-source")
    await broken.openVaultNote(note.path,load:{_ in VaultNoteSnapshot(path:note.path,text:invalid,
        sha256:CanvasPacket.sha(Data(invalid.utf8)),modifiedAt:"fixture")})
    _ = broken.attachOpenedVaultNote()
    check(broken.vaultPDFEditSession == nil && broken.vaultPDFCardMessage?.contains("확인 필요") == true &&
          broken.scene.nodes[0].text.hasPrefix("PDF 출처 확인 필요"),
          "duplicate source has an explicit damaged state instead of ordinary-note or trusted PDF fields")
    let ordinary = store("ordinary")
    let plain = VaultNoteSnapshot(path:"일반.md",text:"# 일반\n메모",sha256:CanvasPacket.sha(Data("# 일반\n메모".utf8)),modifiedAt:"fixture")
    await ordinary.openVaultNote(plain.path,load:{_ in plain})
    check(ordinary.vaultPDFEditSession == nil && ordinary.vaultPDFCardMessage == nil,
          "ordinary note keeps its original whole Markdown editing path")
    check(CanvasPacket.sha(try Data(contentsOf:pdfURL)) == snapshot.sha256,
          "title and memo operations never write the original PDF")
}

@MainActor func checkPDFCardFiles(_ check: (Bool,String) -> Void) async throws {
    let vault = PDFRemoteVault.shared!
    let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!)
    let snapshot = try vault.run(["operation":"readPDF"],as:VaultPDFSnapshot.self)
    let bytes = try snapshot.bytes(at:snapshot.path)
    let doc = PDFDocument(data:bytes)!, page = doc.page(at:0)!
    let selection = page.selection(for:(page.string! as NSString).range(of:"Core"))!
    let source = try VaultPDFExcerpt.capture(snapshot:snapshot,document:doc,selection:selection)
    let journal = root.appendingPathComponent("actual-file-note.json")
    let state = CanvasStore(noteRecoveryURL:journal,pdfExcerptRecoveryURL:root.appendingPathComponent("actual-file-create.json"))
    state.scene = CanvasScene()
    state.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
    check(state.preparePDFExcerpt(source),"actual file fixture prepares the existing PDF create journal")
    let id = await state.savePDFExcerpt(allowCreate:true,create:vault.create,load:vault.note)!
    let title = "직접 고친 제목 👩🏽‍💻", memo = "첫 댓글 e\u{301}\n추가 설명"
    let session = state.vaultPDFEditSession!
    let ui = PDFUIBindings(store:state,session:session)
    ui.text(.title).wrappedValue = title;ui.text(.memo).wrappedValue = memo
    await state.saveVaultNote(save:{path,sha,text in
        try vault.run(["operation":"saveNote","path":path,"baseSha256":sha,"text":text],as:VaultNoteSnapshot.self)
    },load:vault.note)
    let saved = try vault.note(source.notePath), card = try VaultPDFCard.parse(saved.text)!
    check(card.title == title && card.memo == memo && card.source == source && !state.vaultDirty,
          "actual ObsidianVault files save distinct title/memo with unchanged quote, SHA and text ranges")
    let reopened = CanvasStore(noteRecoveryURL:root.appendingPathComponent("file-reopen.json"),
        pdfExcerptRecoveryURL:root.appendingPathComponent("file-reopen-pdf.json"))
    reopened.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
    await reopened.openVaultNote(source.notePath,nodeID:id,load:vault.note)
    check(try reopened.scene.nodes.first(where:{$0.id == id})?.text.contains(title) == true &&
          VaultPDFCard.parse(reopened.vaultDraft)!.memo == memo && reopened.vaultPDFEditSession != nil,
          "new Store and real file read reopen the same card ID and separate editable fields")
    let oldSession = reopened.vaultPDFEditSession!
    let outsideTitle = "외부 에이전트 제목", outsideMemo = "Obsidian에서 보완한 댓글 👩🏽‍💻"
    let outside = try VaultPDFCard.parse(card.replacing(.title,with:outsideTitle))!.replacing(.memo,with:outsideMemo)
    let external = try vault.run(["operation":"saveNote","path":source.notePath,"baseSha256":saved.sha256,"text":outside],as:VaultNoteSnapshot.self)
    await reopened.refreshVaultNotes(load:vault.note)
    check(try VaultPDFCard.parse(reopened.vaultDraft)!.title == outsideTitle &&
          VaultPDFCard.parse(reopened.vaultDraft)!.memo == outsideMemo && reopened.scene.nodes.first(where:{$0.id == id})?.text.contains(outsideMemo) == true,
          "external title and memo changes return to the same original source card through actual file GET")
    check(!reopened.editVaultPDF(.memo,text:"외부 입력 덮기",session:oldSession) && reopened.vaultNote?.sha256 == external.sha256,
          "late field callbacks from before an external edit cannot overwrite a different title or memo")
    let current = reopened.vaultPDFEditSession!
    _ = reopened.editVaultPDF(.memo,text:"아직 저장하지 않은 댓글",session:current)
    let draft = reopened.vaultDraft
    let external2Text = try VaultPDFCard.parse(outside)!.replacing(.memo,with:"다른 외부 댓글")
    _ = try vault.run(["operation":"saveNote","path":source.notePath,"baseSha256":external.sha256,"text":external2Text],as:VaultNoteSnapshot.self)
    await reopened.refreshVaultNotes(load:vault.note)
    check(reopened.vaultBlocked && reopened.vaultDraft == draft && reopened.noteRecovery?.draft == draft,
          "concurrent external memo edit preserves local field input and blocks automatic overwrite")
    check(try VaultPDFCard.parse(vault.note(source.notePath).text)!.source == source &&
          vault.run(["operation":"readPDF"],as:VaultPDFSnapshot.self).sha256 == snapshot.sha256,
          "human and agent share one Markdown original and never rewrite the PDF source")
}
