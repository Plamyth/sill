import Foundation
import PDFKit
import AppKit
import Combine

private func viewStateHome() -> URL {
    URL(fileURLWithPath:ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!).appendingPathComponent("pdf-view-state")
}
private func viewSnapshot(_ bytes: Data, _ path: String = "문서/원본.pdf") -> VaultPDFSnapshot {
    .init(path:path,sha256:CanvasPacket.sha(bytes),dataBase64:bytes.base64EncodedString())
}
private func viewNote(_ state: VaultPDFViewState) throws -> VaultNoteSnapshot {
    let text = try state.markdown()
    return .init(path:state.notePath,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"")
}

@MainActor func checkPDFViewState(_ check:(Bool,String)->Void) async throws {
    let root = viewStateHome(); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let windows = NSApplication.shared.windows.count
    func refused(_ label: String, _ body: () throws -> Void) {
        do { try body(); check(false,label) } catch { check(true,label) }
    }
    for rotation in [0,90,180,270] {
        let boxes = "/MediaBox [-50 -30 562 762] /CropBox [-20 600 500 750] /Rotate \(rotation)"
        let bytes = pagesPDF([("ONE",boxes),("TWO",boxes),("THREE",boxes)])
        let snap = viewSnapshot(bytes,"문서/원본\(rotation).pdf"), reader = try VaultPDFReader(snapshot:snap)
        reader.view.frame = CGRect(x:0,y:0,width:640,height:900)
        let originalPage = reader.view.document!.page(at:0)!, originalBox = originalPage.bounds(for:.cropBox)
        reader.view.setCurrentSelection(originalPage.selection(for:(originalPage.string! as NSString).range(of:"Core",options:.backwards)),animate:false)
        let old = try reader.excerpt(), oldMarkdown = try old.markdown(), oldSourceSHA = CanvasPacket.sha(Data(oldMarkdown.utf8))
        var state = reader.viewState; state.displayOrder = [2,1,3]; state.crops[0] = .init(x:0,y:0,width:0.94181034482758619,height:1)
        try reader.applyViewState(state)
        check(reader.pageNumber == 1 && reader.displayPageNumber == 2 && reader.selectionPageNumber == 1,
              "order2-1-3 preserves current physical page and selected source identity at every native rotation")
        check(reader.view.document !== originalPage.document && originalPage.document!.index(for:originalPage) == 0 && originalPage.bounds(for:.cropBox) == originalBox,
              "view order and crop use copied pages while the original PDFDocument index and boxes stay unchanged")
        let shown = reader.view.document!.page(at:1)!, expected = CGRect(x:originalBox.minX,y:originalBox.minY,width:originalBox.width * state.crops[0].width,height:originalBox.height)
        check(shown.rotation == rotation && shown.bounds(for:.cropBox) == expected,
              "native display crop uses original page-space box including negative origin and quarter-turn rotation")
        let freshCapture = try reader.excerpt()
        check(freshCapture.pageIndex == old.pageIndex && freshCapture.cropBox == old.cropBox && freshCapture.mediaBox == old.mediaBox &&
              freshCapture.rotation == old.rotation && freshCapture.textRanges == old.textRanges && freshCapture.selectionRects == old.selectionRects && freshCapture.quote == old.quote,
              "new capture translates visible selection back to canonical physical ranges and original geometry")
        try reader.undoViewState()
        check(reader.viewState.displayOrder == [1,2,3] && reader.viewState.crops[0] == .init() && reader.pageNumber == 1 && reader.view.currentSelection?.string == old.quote,
              "view-state Undo restores crop/order while keeping original selection")
        try reader.redoViewState()
        check(reader.viewState == state && reader.displayPageNumber == 2,"view-state Redo re-applies exact metadata")
        reader.view.perform(PDFActionGoTo(destination:PDFDestination(page:originalPage.document!.page(at:2)!,at:.zero)))
        check(reader.pageNumber == 3 && reader.displayPageNumber == 3 && reader.viewState == state,
              "native internal GoTo keeps its physical target in the reordered display")
        let foreign = PDFDocument(data:bytes)!, beforeForeign = reader.view.currentPage
        reader.view.perform(PDFActionGoTo(destination:PDFDestination(page:foreign.page(at:0)!,at:.zero)))
        check(reader.view.currentPage === beforeForeign && reader.pageNumber == 3,"native foreign-document GoTo cannot escape the verified reader")
        try reader.returnToSource(old)
        try reader.setCrop(.init(x:0.1,y:0,width:0.9,height:1),physicalPageNumber:2)
        check(reader.viewState.crops[1].valid && reader.view.document!.page(at:0)!.bounds(for:.cropBox).maxX == originalBox.maxX,
              "normalized crop ending at one uses stable endpoints without escaping the original box")
        try reader.undoViewState()
        try reader.setCrop(.init(x:0.7,y:0,width:0.3,height:1),physicalPageNumber:1)
        let hiddenState = reader.viewState
        check(reader.sourceRevealed && reader.view.currentSelection?.string == old.quote && reader.viewState == hiddenState,
              "crop excluding an existing source temporarily reveals its page without replacing saved crop metadata")
        try reader.returnToSource(old)
        check(reader.pageNumber == 1 && reader.displayPageNumber == 2 && reader.view.currentSelection?.string == old.quote && reader.sourceRevealed,
              "existing excerpt returns to the same original page and text through changed order and crop")
        let selected = reader.view.currentSelection?.string, priorDocument = reader.view.document
        check(!reader.go(toDisplayPageNumber:Int.min) && !reader.go(toDisplayPageNumber:Int.max) && !reader.go(toDisplayPageNumber:0) && reader.view.document === priorDocument && reader.view.currentSelection?.string == selected,
              "invalid display navigation preserves reveal mode and native selection")
        check(reader.go(toDisplayPageNumber:1) && reader.pageNumber == 2 && !reader.sourceRevealed && reader.view.currentSelection == nil,
              "ordinary display navigation restores configured crops and reaches physical page two")
        try reader.returnToSource(old)
        try reader.setCrop(.init(),physicalPageNumber:1)
        check(!reader.sourceRevealed && reader.viewState.crops[0] == .init(),"explicit crop restore returns full view without changing the source")
        try reader.undoViewState(); check(reader.viewState == hiddenState,"crop restore Undo recovers the prior crop and base view metadata")
        try reader.redoViewState(); check(reader.viewState.crops[0] == .init(),"crop restore Redo retains physical source identity")
        let before = reader.viewState, beforeSelection = reader.view.currentSelection?.string
        var invalid = before; invalid.displayOrder = [1,1,3]
        refused("duplicate physical page order is rejected before changing view") { try reader.applyViewState(invalid) }
        invalid = before; invalid.crops[0] = .init(x:-0.1,y:0,width:1,height:1)
        refused("negative crop is rejected before changing view") { try reader.applyViewState(invalid) }
        invalid.crops[0] = .init(x:0,y:0,width:.nan,height:1)
        refused("nonfinite crop cannot mutate the native page") { try reader.applyViewState(invalid) }
        check(reader.viewState == before && reader.view.currentSelection?.string == beforeSelection,"invalid state preserves the complete draft and native selection")
        let markdown = try reader.viewState.markdown(), note = try viewNote(reader.viewState)
        check(try VaultPDFViewState.parse(markdown,snapshot:snap,pageCount:3) == reader.viewState,
              "human/AI Markdown permutation and crop table roundtrip exactly")
        for malformed in [markdown.replacingOccurrences(of:VaultPDFViewState.marker,with:"<!-- ccr:pdf-view-state:v2 -->"),
                          markdown + "unknown footer\n",
                          markdown.replacingOccurrences(of:snap.sha256,with:String(repeating:"0",count:64)),
                          markdown.replacingOccurrences(of:"| 1 |",with:"| 2 |") ] {
            refused("unknown version malformed table or changed PDF SHA does not fall back") { _ = try VaultPDFViewState.parse(malformed,snapshot:snap,pageCount:3) }
        }
        refused("external reload refuses to overwrite a dirty view draft") { try reader.applyViewStateNote(note) }
        try Data(bytes).write(to:root.appendingPathComponent("\(rotation).pdf"))
        try Data(markdown.utf8).write(to:root.appendingPathComponent("\(rotation).view.md"))
        try Data(oldMarkdown.utf8).write(to:root.appendingPathComponent("\(rotation).source.md"))
        check(try old.sourcePage(in:snap).1.bounds(for:.cropBox) == originalBox && CanvasPacket.sha(Data(oldMarkdown.utf8)) == oldSourceSHA && originalPage.bounds(for:.cropBox) == originalBox,
              "reorder crop restore and Undo never rewrite original excerpt Markdown or canonical page geometry")
        let reopened = try VaultPDFReader(snapshot:snap,source:old,viewState:try VaultPDFViewState.parse(markdown,snapshot:snap,pageCount:3))
        check(reopened.pageNumber == 1 && reopened.displayPageNumber == 2 && reopened.view.currentSelection?.string == old.quote,
              "fresh Reader reopens Markdown view state and an existing physical-page source")
        let request = try reopened.prepareViewStateSave(base:note)
        let confirmed = try await request.submit(save:{_,_,_ in note},load:{_ in note})
        try reopened.confirmViewStateSave(request,note:confirmed)
        check(!reopened.hasViewEdits,"explicit CAS request requires matching PUT and GET before marking the view saved")
        try reopened.setCrop(.init(x:0,y:0,width:0.9,height:1),physicalPageNumber:2)
        var differentBase = reopened.viewState; differentBase.displayOrder = [3,2,1]
        refused("a caller cannot rebase a dirty draft onto a different external state without reconciliation") { _ = try reopened.prepareViewStateSave(base:viewNote(differentBase)) }
        refused("a known existing sidecar cannot be silently changed to create mode") { _ = try reopened.prepareViewStateSave(base:nil) }
        var saveNotifications = 0
        let observation = reopened.objectWillChange.sink { saveNotifications += 1 }
        try reopened.confirmViewStateSave(request,note:confirmed)
        observation.cancel()
        check(saveNotifications > 0,"save confirmation publishes the saved baseline so view controls refresh their dirty state")
        check(reopened.hasViewEdits,"late acknowledgement keeps a newer view edit dirty")
        var writes = 0, reads = 0
        do { _ = try await request.submit(save:{_,_,_ in writes += 1; throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:VaultSaveConflict.reconciliationRequired.rawValue])},load:{_ in reads += 1; return note}); check(false,"typed409 should throw") }
        catch { check(VaultSaveConflict.classified(error) == .reconciliationRequired && writes == 1 && reads == 0 && reopened.hasViewEdits,"typed409 is retained without GET fallback automatic retry or draft discard") }
        let other = viewSnapshot(bytes,"문서/다른 경로.pdf")
        refused("view state bound to another path or PDF is not reused") { _ = try VaultPDFViewState.parse(markdown,snapshot:other,pageCount:3) }
        check(try Data(contentsOf:root.appendingPathComponent("\(rotation).pdf")) == bytes && originalPage.rotation == rotation,
              "native rotated PDF file bytes and original rotation remain immutable")
    }
    let reaURL = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PDF_OUTLINE_FIXTURE"]!), data = try Data(contentsOf:reaURL)
    let snap = viewSnapshot(data), reader = try VaultPDFReader(snapshot:snap)
    try reader.moveDisplayPage(from:1,to:2)
    check(reader.go(toOutlineEntry:reader.outlineEntries[0]) && reader.pageNumber == 1 && reader.displayPageNumber == 2,
          "REA original Chapter1 still reaches physical one at display position two")
    check(reader.go(toOutlineEntry:reader.outlineEntries[1]) && reader.pageNumber == 3,"REA Chapter3 retains its physical destination after reorder")
    check(try Data(contentsOf:reaURL) == data && NSApplication.shared.windows.count == windows,"REA input bytes and visible Window count remain unchanged")
}

@MainActor func checkPDFViewStateReopen(_ check:(Bool,String)->Void) throws {
    let root = viewStateHome()
    for rotation in [0,90,180,270] {
        let bytes = try Data(contentsOf:root.appendingPathComponent("\(rotation).pdf")), snap = viewSnapshot(bytes,"문서/원본\(rotation).pdf")
        let text = try String(contentsOf:root.appendingPathComponent("\(rotation).view.md"),encoding:.utf8), state = try VaultPDFViewState.parse(text,snapshot:snap,pageCount:3)
        let sourceText = try String(contentsOf:root.appendingPathComponent("\(rotation).source.md"),encoding:.utf8), source = try VaultPDFExcerpt.parse(sourceText)!
        let reader = try VaultPDFReader(snapshot:snap,source:source,viewState:state)
        check(reader.pageNumber == 1 && reader.displayPageNumber == 2 && reader.view.currentSelection?.string == source.quote,"new process reopens the saved order/crop and exact old physical-page quote")
        check(try reader.excerpt().textRanges == source.textRanges && reader.viewState == state,"new process capture keeps canonical ranges separate from display metadata")
        check(try source.markdown().utf8.elementsEqual(sourceText.utf8),"new process does not replace the old excerpt provenance or ID")
    }
}

@MainActor func checkPDFViewStateFiles(_ check:(Bool,String)->Void) async throws {
    let bridge = try PDFRemoteVault(source:ProcessInfo.processInfo.environment["PDF_VIEW_STATE_REMOTE_SOURCE"]!,job:"pdf-view-state-20261029",script:"Tests/checks/pdf-pages-rotation/vault-fixture.cjs",guardScript:nil)
    var finished = false; defer { if !finished { try? bridge.finish() } }
    let data = try Data(contentsOf:URL(fileURLWithPath:ProcessInfo.processInfo.environment["PDF_OUTLINE_FIXTURE"]!)), snap = viewSnapshot(data)
    let reader = try VaultPDFReader(snapshot:snap); reader.view.frame = CGRect(x:0,y:0,width:640,height:900)
    let page = reader.view.document!.page(at:0)!
    reader.view.setCurrentSelection(page.selection(for:(page.string! as NSString).range(of:"ANCHOR_P1_ALPHA")),animate:false)
    let source = try reader.excerpt(), sourceText = try source.markdown()
    _ = try bridge.create(source.notePath,sourceText)
    try reader.moveDisplayPage(from:1,to:2); try reader.setCrop(.init(x:0,y:0,width:0.94181034482758619,height:1),physicalPageNumber:1)
    let request = try reader.prepareViewStateSave(base:nil)
    let saved = try await request.submit(save:{path,sha,text in try bridge.run(["operation":"saveNote","path":path,"baseSha256":sha.map{$0 as Any} ?? NSNull(),"text":text],as:VaultNoteSnapshot.self)},load:bridge.note)
    try reader.confirmViewStateSave(request,note:saved)
    check(!reader.hasViewEdits && saved.text == request.markdown,"actual ObsidianVault note PUT CAS and GET save the separate view-state Markdown")
    let staleReader = try VaultPDFReader(snapshot:snap,source:source,viewState:reader.viewState)
    try staleReader.setCrop(.init(x:0,y:0,width:0.8,height:1),physicalPageNumber:1)
    let stale = try staleReader.prepareViewStateSave(base:saved)
    var outside = reader.viewState; outside.displayOrder = [3,1,2]; outside.crops[1] = .init(x:0.1,y:0,width:0.9,height:1)
    let external = try bridge.run(["operation":"saveNote","path":saved.path,"baseSha256":saved.sha256,"text":try outside.markdown()],as:VaultNoteSnapshot.self)
    try reader.applyViewStateNote(bridge.note(saved.path))
    check(reader.viewState == outside && reader.pageNumber == 1 && reader.displayPageNumber == 2,"external human/AI Markdown edits reload the same source PDF with full order and crop")
    try reader.setCrop(.init(x:0,y:0,width:0.8,height:1),physicalPageNumber:1)
    let draft = reader.viewState
    do { _ = try await stale.submit(save:{path,sha,text in try bridge.run(["operation":"saveNote","path":path,"baseSha256":sha! as Any,"text":text],as:VaultNoteSnapshot.self)},load:bridge.note);check(false,"stale file CAS should throw") }
    catch let error as PDFRemoteFailure {check(error.status == 409 && reader.viewState == draft && reader.hasViewEdits,"actual external CAS409 preserves view draft and external original")}
    check(try bridge.note(saved.path).sha256 == external.sha256,"refused stale CAS does not overwrite the external Markdown")
    let pending = try reader.prepareViewStateSave(base:external), root = viewStateHome()
    try JSONEncoder().encode(pending).write(to:root.appendingPathComponent("pending-view-intent.json"))
    var puts = 0
    do { _ = try await pending.submit(save:{path,sha,text in puts += 1; _ = try bridge.run(["operation":"saveNote","path":path,"baseSha256":sha! as Any,"text":text],as:VaultNoteSnapshot.self); throw URLError(.networkConnectionLost)},load:bridge.note);check(false,"lost acknowledgement should throw") }
    catch { check(puts == 1 && reader.hasViewEdits,"lost PUT response preserves the same immutable view-state save intent without retry") }
    let retained = try JSONDecoder().decode(VaultPDFViewState.SaveRequest.self,from:Data(contentsOf:root.appendingPathComponent("pending-view-intent.json")))
    let recovered = try retained.confirmed(bridge.note(retained.path));try reader.confirmViewStateSave(retained,note:recovered)
    check(retained == pending && !reader.hasViewEdits && puts == 1,"explicit GET confirms the exact pending intent after response loss without a second PUT")
    let reopened = try VaultPDFReader(snapshot:snap,source:source,viewState:try VaultPDFViewState.parse(recovered.text,snapshot:snap,pageCount:3))
    check(reopened.viewState == draft && reopened.pageNumber == 1 && reopened.displayPageNumber == 2,"fresh Reader reopens actual Files state and returns the old excerpt to its physical page")
    check(try bridge.note(source.notePath).text.utf8.elementsEqual(sourceText.utf8),"actual pre-existing excerpt note ID quote and provenance bytes remain unchanged")
    finished = true; try bridge.finish()
}
