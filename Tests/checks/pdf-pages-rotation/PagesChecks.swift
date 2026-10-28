import Foundation
import PDFKit
import AppKit

private func pagesPDF(_ pages: [(String,String)]) -> Data {
    var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count \(pages.count) /Kids [\(pages.indices.map { "\(4+$0*2) 0 R" }.joined(separator:" "))] >>", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    for (index,item) in pages.enumerated() {
        let stream = "BT /F1 16 Tf 60 700 Td (Core) Tj 0 -40 Td (\(item.0)) Tj 0 -40 Td (Core) Tj ET"
        objects.append("<< /Type /Page /Parent 2 0 R \(item.1.hasPrefix("/MediaBox") ? "" : "/MediaBox [0 0 612 792]") \(item.1) /Resources << /Font << /F1 3 0 R >> >> /Contents \(5+index*2) 0 R >>")
        objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
    }
    var data = Data("%PDF-1.4\n".utf8), offsets = [Int]()
    for (index,object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index+1) 0 obj\n\(object)\nendobj\n".utf8)) }
    let start = data.count
    data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
    for offset in offsets { data.append(Data(String(format:"%010d 00000 n \n",offset).utf8)) }
    data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8))
    return data
}

@MainActor func checkPDFPages(_ check:(Bool,String)->Void) async throws {
    let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!).appendingPathComponent("page-fixtures")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let originalWindows=NSApplication.shared.windows.count
    var returnRecords=[String]()
    func snapshot(_ data:Data)->VaultPDFSnapshot {
        .init(path:"문서/여러 쪽.pdf",sha256:CanvasPacket.sha(data),dataBase64:data.base64EncodedString())
    }
    func refused(_ label:String,_ body:()throws->Void) {
        do {try body();check(false,label)} catch {check(true,label)}
    }
    for (name,boxes) in [("default",""),("crop","/MediaBox [-50 -30 562 762] /CropBox [-20 600 500 750]")] {
        for rotation in [0,90,180,270] {
            let data=pagesPDF([("PAGE ONE",boxes),("PAGE TWO",boxes+" /Rotate \(rotation)"),("PAGE THREE",boxes+" /Rotate \(rotation)")])
            let pdfURL=root.appendingPathComponent("\(name)-\(rotation).pdf")
            try data.write(to:pdfURL)
            let snap=snapshot(data), reader=try VaultPDFReader(snapshot:snap)
            reader.view.frame=CGRect(x:0,y:0,width:640,height:900)
            check(reader.pageCount==3 && reader.pageNumber==1,"actual PDFView opens three-page document at page one")
            for number in [3,2,1,3] {
                check(reader.go(toPageNumber:number) && reader.pageNumber==number && reader.view.currentSelection==nil,
                      "explicit page navigation reaches exact native page and clears old selection")
            }
            let doc=reader.view.document!, page=doc.page(at:2)!
            let range=(page.string! as NSString).range(of:"Core",options:.backwards), selection=page.selection(for:range)!
            let first=page.selection(for:(page.string! as NSString).range(of:"Core"))!
            reader.view.setCurrentSelection(first,animate:false)
            let actualFirst=reader.view.currentSelection!, actualFirstRange=actualFirst.range(at:0,on:page)
            let firstSource=try reader.excerpt()
            check(firstSource.textRanges!.first!.ns==actualFirstRange && firstSource.quote==actualFirst.string,
                  "PDFView normalization is captured from the actual selection rather than the requested range")
            let (_,firstPage,firstReturn)=try firstSource.sourcePage(in:snap)
            check(firstReturn.range(at:0,on:firstPage)==actualFirstRange,
                  "normalized native selection range survives exact source return")
            reader.view.setCurrentSelection(selection,animate:false)
            let actualRange=reader.view.currentSelection!.range(at:0,on:page)
            check(reader.selectionPageNumber==3,"selection page is explicit even when identical text occurs on every page")
            for number in [0,-1,4,Int.max] {
                check(!reader.go(toPageNumber:number) && reader.pageNumber==3 && reader.view.currentSelection?.string=="Core",
                      "out-of-range page input preserves page and native selection")
            }
            let source=try reader.excerpt(), text=try source.markdown(), card=try VaultPDFCard.parse(text)!
            check(source.pageIndex==2 && source.rotation==rotation && source.textRanges?.first?.ns==actualRange,
                  "capture records selected page three canonical rotation and actual UTF16 range")
            check(source.selectionRects == selection.selectionsByLine().map{.init($0.bounds(for:page))},
                  "rotated page-space bounds remain native without y flip or crop-origin subtraction")
            let memo="역방향 메모 e\u{301} 👩🏽‍💻\r\n원문 보존"
            let titled=try card.replacing(.title,with:"세 번째 페이지 \(rotation)도")
            let edited=try VaultPDFCard.parse(titled)!.replacing(.memo,with:memo)
            let noteURL=root.appendingPathComponent("\(name)-\(rotation).md")
            try Data(edited.utf8).write(to:noteURL,options:.atomic)
            let reopenedText=try String(contentsOf:noteURL,encoding:.utf8), reopened=try VaultPDFCard.parse(reopenedText)!
            check(reopenedText.contains("#page=3") && reopened.sourceSHA256==card.sourceSHA256 && reopened.memo.utf8.elementsEqual(memo.utf8),
                  "actual Markdown file reopen preserves title memo provenance and one-based page link")
            let fromDisk=snapshot(try Data(contentsOf:pdfURL)), back=try VaultPDFReader(snapshot:fromDisk,source:reopened.source)
            back.view.frame=CGRect(x:0,y:0,width:640,height:900)
            let (_,backPage,backSelection)=try reopened.source.sourcePage(in:fromDisk)
            check(back.pageNumber==3 && back.view.currentSelection?.string=="Core" && backPage.string!.contains("PAGE THREE") &&
                  backSelection.range(at:0,on:backPage)==actualRange && backSelection.bounds(for:backPage)==selection.bounds(for:page),
                  "fresh PDFKit reader returns exact selected third page range and bounds at every supported rotation")
            returnRecords.append(String(decoding:try JSONEncoder().encode(source),as:UTF8.self))
            check(try Data(contentsOf:pdfURL)==data,"navigation selection source return and note edits leave PDF bytes unchanged")
            let changed=snapshot(pagesPDF([("CHANGED",boxes)]))
            refused("changed PDF SHA cannot return to an old page") {_=try VaultPDFReader(snapshot:changed,source:source)}
            let combined=PDFSelection(document:doc)
            combined.add(selection);combined.add(doc.page(at:1)!.selection(for:(doc.page(at:1)!.string! as NSString).range(of:"Core"))!)
            reader.view.setCurrentSelection(combined,animate:false)
            refused("cross-page selection is not silently collapsed to a different page") {_=try reader.excerpt()}
            reader.view.clearSelection()
            refused("empty selection cannot create a source card") {_=try reader.excerpt()}
            reader.view.document=PDFDocument(data:data)
            check(!reader.go(toPageNumber:1),"a replaced native document cannot reuse the verified reader identity")
            refused("replaced document selection cannot be saved against an old PDF SHA") {_=try reader.excerpt()}
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as! [String:Any]
            object["rotation"]=45
            refused("noncanonical provenance rotation remains invalid") {
                _=try JSONDecoder().decode(VaultPDFExcerpt.self,from:JSONSerialization.data(withJSONObject:object)).validated()
            }
            object["rotation"]=rotation;object["schemaVersion"]=1;object.removeValue(forKey:"textRanges")
            if rotation != 0 {
                refused("legacy geometry-only source does not gain unverified rotation support") {
                    _=try JSONDecoder().decode(VaultPDFExcerpt.self,from:JSONSerialization.data(withJSONObject:object)).validated()
                }
            }
        }
    }
    try Data(returnRecords.joined(separator:"\n").utf8).write(to:root.appendingPathComponent("source-return.jsonl"))
    check(NSApplication.shared.windows.count==originalWindows,"headless PDFView checks create no visible application window")
    if ProcessInfo.processInfo.environment["PDF_PAGES_REMOTE_SOURCE"] != nil {
        try await checkPDFPagesFiles(check)
    }
}

@MainActor func checkPDFPagesFiles(_ check:(Bool,String)->Void) async throws {
    let bridge=try PDFRemoteVault(source:ProcessInfo.processInfo.environment["PDF_PAGES_REMOTE_SOURCE"],
        job:"pdf-pages-rotation-20261029",script:"Tests/checks/pdf-pages-rotation/vault-fixture.cjs",guardScript:nil)
    var needsCleanup=true
    defer {if needsCleanup {try? bridge.finish()}}
    let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!).appendingPathComponent("page-fixtures")
    for rotation in [0,90,180,270] {
        let data=pagesPDF([("PAGE ONE",""),("PAGE TWO","/Rotate \(rotation)"),("PAGE THREE","")])
        let snap=VaultPDFSnapshot(path:"문서/여러 쪽.pdf",sha256:CanvasPacket.sha(data),dataBase64:data.base64EncodedString())
        let reader=try VaultPDFReader(snapshot:snap);reader.view.frame=CGRect(x:0,y:0,width:640,height:900)
        check(reader.go(toPageNumber:2),"file roundtrip selects the second PDF page through the actual reader")
        let page=reader.view.document!.page(at:1)!,range=(page.string! as NSString).range(of:"Core",options:.backwards)
        reader.view.setCurrentSelection(page.selection(for:range),animate:false)
        let source=try reader.excerpt(), sourceCard=try VaultPDFCard.parse(source.markdown())!
        let journal=root.appendingPathComponent("note-\(rotation).json"),pdfJournal=root.appendingPathComponent("create-\(rotation).json")
        let store=CanvasStore(noteRecoveryURL:journal,pdfExcerptRecoveryURL:pdfJournal)
        store.scene=CanvasScene();store.scene.schemaVersion=3
        store.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
        check(store.preparePDFExcerpt(source),"selected page and rotation enter the existing durable PDF create journal")
        let pending=store.pdfExcerptRecovery
        let id=await store.savePDFExcerpt(allowCreate:true,create:{path,text in
            let value=try bridge.create(path,text)
            if rotation==90 {throw URLError(.networkConnectionLost)}
            return value
        },load:bridge.note)
        check(id != nil && store.pdfExcerptRecovery==nil && pending?.path==source.notePath && store.scene.schemaVersion==3,
              "real ObsidianVault file CAS and GET attach the same page anchor including a lost create acknowledgement")
        let session=store.vaultPDFEditSession!,ui=PDFUIBindings(store:store,session:session)
        ui.text(.title).wrappedValue="두 번째 페이지 \(rotation)도"
        ui.text(.memo).wrappedValue="파일 메모 e\u{301} 👩🏽‍💻"
        await store.saveVaultNote(save:{path,sha,text in
            try bridge.run(["operation":"saveNote","path":path,"baseSha256":sha,"text":text],as:VaultNoteSnapshot.self)
        },load:bridge.note)
        let saved=try bridge.note(source.notePath),savedCard=try VaultPDFCard.parse(saved.text)!
        check(!store.vaultDirty && store.noteRecovery==nil && savedCard.sourceSHA256==sourceCard.sourceSHA256,
              "title and memo use real file CAS plus GET without changing rotated PDF provenance")
        let fresh=CanvasStore(noteRecoveryURL:journal,pdfExcerptRecoveryURL:pdfJournal)
        fresh.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
        await fresh.openVaultNote(source.notePath,nodeID:id,load:bridge.note)
        check(fresh.scene.nodes.contains{$0.id==id && $0.vaultNote?.path==source.notePath} && fresh.vaultDraft==saved.text,
              "fresh Store and fresh ObsidianVault instance reopen the same original note and card ID")
        let outside=try savedCard.replacing(.memo,with:"외부 원문 메모 e\u{301}")
        let external=try bridge.run(["operation":"saveNote","path":source.notePath,"baseSha256":saved.sha256,"text":outside],as:VaultNoteSnapshot.self)
        await fresh.refreshVaultNotes(load:bridge.note)
        let externalCard=try VaultPDFCard.parse(fresh.vaultDraft)!
        check(externalCard.memo=="외부 원문 메모 e\u{301}" && externalCard.sourceSHA256==sourceCard.sourceSHA256 && fresh.vaultNote?.sha256==external.sha256,
              "inverse Markdown edit refreshes the same page source card without changing quote or rotation")
        do {
            _=try bridge.run(["operation":"saveNote","path":source.notePath,"baseSha256":saved.sha256,"text":"stale"],as:VaultNoteSnapshot.self)
            check(false,"stale real-file CAS must refuse")
        } catch let error as PDFRemoteFailure {check(error.status==409,"stale Markdown CAS refuses while preserving the actual external note")}
        let back=try VaultPDFReader(snapshot:snap,source:externalCard.source)
        check(back.pageNumber==2 && back.view.currentSelection?.string=="Core" && externalCard.source.rotation==rotation,
              "actual file readback returns to selected page two and its text across supported rotations")
        try data.write(to:root.appendingPathComponent("vault-\(rotation).pdf"))
        try Data(external.text.utf8).write(to:root.appendingPathComponent("vault-\(rotation).md"))
        let held=CanvasStore(noteRecoveryURL:root.appendingPathComponent("held-\(rotation).json"),pdfExcerptRecoveryURL:root.appendingPathComponent("held-create-\(rotation).json"))
        held.scene=CanvasScene();held.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
        check(held.preparePDFExcerpt(source),"failure fixture preserves the same selected-page create intent")
        var writes=0
        let refused=await held.savePDFExcerpt(allowCreate:true,create:{_,_ in writes += 1;throw NSError(domain:"CanvasRelay",code:409,
            userInfo:[VaultSaveConflict.errorKey:VaultSaveConflict.reconciliationRequired.rawValue])},load:{_ in throw NSError(domain:"CanvasRelay",code:404)})
        let retained=held.pdfExcerptRecovery
        let retry=await held.savePDFExcerpt(allowCreate:true,create:{_,_ in writes += 1;return external},load:{_ in external})
        check(refused==nil && retry==nil && writes==1 && retained==held.pdfExcerptRecovery && retained?.submittedText != nil && held.scene.nodes.isEmpty,
              "typed409 retains submitted page provenance and sends no automatic retry or card installation")
    }
    needsCleanup=false
    try bridge.finish()
}

@MainActor func checkPDFPagesReopen(_ check:(Bool,String)->Void) throws {
    let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!).appendingPathComponent("page-fixtures")
    let notes=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.pathExtension=="md"}
    check(notes.count>=8,"fresh process finds all persisted multi-page and rotated source records")
    for note in notes {
        let text=try String(contentsOf:note,encoding:.utf8),card=try VaultPDFCard.parse(text)!
        let data=try Data(contentsOf:note.deletingPathExtension().appendingPathExtension("pdf"))
        let snap=VaultPDFSnapshot(path:card.source.pdfPath,sha256:CanvasPacket.sha(data),dataBase64:data.base64EncodedString())
        let reader=try VaultPDFReader(snapshot:snap,source:card.source)
        check(reader.pageNumber==card.source.pageIndex+1 && reader.view.currentSelection?.string==card.source.quote,
              "new Swift process returns saved selected page and exact native quote from Markdown")
        let (_,page,selection)=try card.source.sourcePage(in:snap)
        check(selection.range(at:0,on:page)==card.source.textRanges!.first!.ns && selection.selectionsByLine().map{VaultPDFExcerpt.Rect($0.bounds(for:page))}==card.source.selectionRects,
              "new process verifies actual UTF16 range and rotated page-space bounds")
    }
}
