import Foundation
import PDFKit
import CoreText

@MainActor func checkPDFExcerptRecovery(_ check: (Bool,String) -> Void) async throws {
    let env = ProcessInfo.processInfo.environment
    let home = URL(fileURLWithPath:env["CFFIXED_USER_HOME"]!)
    let fixture = URL(fileURLWithPath:env["PDF_RECOVERY_FIXTURE"]!)
    let bytes = try Data(contentsOf:fixture)
    let snapshot = VaultPDFSnapshot(path:"유니코드.pdf",sha256:CanvasPacket.sha(bytes),dataBase64:bytes.base64EncodedString())
    let document = PDFDocument(data:bytes)!, page = document.page(at:0)!
    let selected = page.selection(for:NSRange(location:0,length:(page.string! as NSString).length))!
    let excerpt = try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,selection:selected)
    print("PDF_INPUT_SHA256 \(snapshot.sha256)")

    let original = VaultNoteSnapshot(path:"기존.md",text:"저장된 원문 한글 👩🏽‍💻 e\u{301}",
        sha256:CanvasPacket.sha(Data("저장된 원문 한글 👩🏽‍💻 e\u{301}".utf8)),modifiedAt:"fixture")
    for replaceBeforeFailure in [false,true] {
        let url = home.appendingPathComponent("failed-\(replaceBeforeFailure).json")
        let store = CanvasStore(noteRecoveryURL:home.appendingPathComponent("normal-\(replaceBeforeFailure).json"),
            pdfExcerptRecoveryURL:url,pdfExcerptRecoveryWrite:{ data,url in
            if replaceBeforeFailure { try data.write(to:url,options:.atomic) }
            throw CocoaError(.fileWriteNoPermission)
        })
        store.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
        await store.openVaultNote(original.path,load:{_ in original})
        store.vaultSelection = NSRange(location:2,length:4)
        let input = store.vaultInputSessionID, scene = store.scene, selection = store.vaultSelection
        check(!store.preparePDFExcerpt(excerpt),"journal failure refuses prepare (replacement=\(replaceBeforeFailure))")
        check(store.vaultNote == original && store.vaultDraft.utf8.elementsEqual(original.text.utf8),
              "journal failure preserves opened original and exact draft")
        check(input != nil && store.vaultInputSessionID == input && store.vaultSelection == selection,
              "journal failure preserves input session and selection")
        check(store.scene == scene,"journal failure preserves scene and card cache")
        store.vaultDraft += "\n실패 뒤 이어 쓰기"
        check(store.vaultDraft.hasSuffix("실패 뒤 이어 쓰기") && store.vaultInputSessionID == input,
              "same input session remains editable after prepare failure")
    }
    let blockText = "연결 문단 e\u{301} 👩🏽‍💻 ^keep\n"
    let blockNote = VaultNoteSnapshot(path:"블록.md",text:blockText,sha256:CanvasPacket.sha(Data(blockText.utf8)),modifiedAt:"fixture")
    for failClosing in [false,true] {
        let blockURL = home.appendingPathComponent("block-\(failClosing).json")
        let block = CanvasStore(blockRecoveryURL:blockURL,
            noteRecoveryURL:home.appendingPathComponent("block-note-\(failClosing).json"),
            pdfExcerptRecoveryURL:home.appendingPathComponent("block-pdf-\(failClosing).json"),
            pdfExcerptRecoveryWrite:{ data,url in
                if !failClosing { throw CocoaError(.fileWriteNoPermission) }
                try CanvasLocalFile.write(data,to:url)
            })
        block.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
        block.scene = CanvasScene()
        let id = block.scene.addNode(kind:.note,at:.init(x:0,y:0),text:"캐시")
        block.scene.nodes[0].vaultNote = VaultNoteReference(path:blockNote.path,sha256:blockNote.sha256,
            relayAddress:"http://fixture.invalid",blockID:"keep",sourceState:.current)
        await block.openVaultNote(blockNote.path,nodeID:id,load:{_ in blockNote})
        check(block.beginLinkedBlockEdit(),"clean linked block begins before durability failure")
        block.vaultBlockSelection = NSRange(location:1,length:2)
        let session = block.vaultInputSessionID, recovery = block.blockRecovery, scene = block.scene
        let draft = block.vaultBlockDraft, selection = block.vaultBlockSelection
        if failClosing { try Data("foreign journal".utf8).write(to:blockURL) }
        let journal = try Data(contentsOf:blockURL)
        check(!block.preparePDFExcerpt(excerpt),"block editor prepare refuses \(failClosing ? "close" : "journal") failure")
        check(block.vaultNote == blockNote && block.vaultBlockEditing && block.vaultBlockDraft == draft &&
              block.vaultInputSessionID == session && block.vaultBlockSelection == selection && block.blockRecovery == recovery,
              "failed prepare preserves clean block editor, draft, session, selection and recovery")
        check(try block.scene == scene && Data(contentsOf:blockURL) == journal && !block.hasPendingPDFExcerpt,
              "failed block close rolls back owned create intent and preserves cache and block journal")
    }
    let dirty = CanvasStore(noteRecoveryURL:home.appendingPathComponent("dirty.json"),
        pdfExcerptRecoveryURL:home.appendingPathComponent("dirty-pdf.json"))
    dirty.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
    await dirty.openVaultNote(original.path,load:{_ in original})
    dirty.vaultDraft += "\n미저장 입력"
    dirty.vaultSelection = NSRange(location:1,length:2)
    let dirtyInput = dirty.vaultInputSessionID, draft = dirty.vaultDraft, selection = dirty.vaultSelection
    check(!dirty.preparePDFExcerpt(excerpt) && dirty.vaultDraft == draft && dirty.vaultNote == original &&
          dirty.vaultInputSessionID == dirtyInput && dirty.vaultSelection == selection,
          "dirty editor refuses before changing draft, selection or input session")

    let normalURL = home.appendingPathComponent("create-normal.json"), createURL = home.appendingPathComponent("create-only.json")
    let normalBytes = try JSONEncoder().encode(VaultNoteRecoveryFile(nil))
    try normalBytes.write(to:normalURL)
    let creating = CanvasStore(noteRecoveryURL:normalURL,pdfExcerptRecoveryURL:createURL)
    creating.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
    await creating.openVaultNote(original.path,load:{_ in original})
    check(creating.preparePDFExcerpt(excerpt) && creating.vaultNote == nil && creating.vaultInputSessionID == nil,
          "successful durable prepare closes the old clean editor")
    check(try Data(contentsOf:normalURL) == normalBytes && creating.noteRecovery == nil,
          "create-only prepare leaves ordinary note journal byte-identical")
    let createBytes = try Data(contentsOf:createURL)
    do { _ = try JSONDecoder().decode(VaultNoteRecoveryFile.self,from:createBytes); check(false,"create envelope must not decode as ordinary recovery") }
    catch { check(true,"create envelope cannot decode as ordinary note recovery") }
    let recreated = CanvasStore(noteRecoveryURL:normalURL,pdfExcerptRecoveryURL:createURL)
    recreated.scene = creating.scene
    recreated.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
    check(recreated.pdfExcerptRecovery == creating.pdfExcerptRecovery && recreated.hasPendingPDFExcerpt,
          "separate create-only journal survives Store restart")
    for classification in [VaultSaveConflict.reconciliationRequired, .unclassified] {
        let journal = home.appendingPathComponent("typed-\(classification.rawValue).json")
        let state = CanvasStore(noteRecoveryURL:home.appendingPathComponent("typed-note-\(classification.rawValue).json"),
            pdfExcerptRecoveryURL:journal)
        state.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
        check(state.preparePDFExcerpt(excerpt),"typed409 fixture journals exact PDF creation")
        let before = state.scene
        var reads = 0, puts = 0
        let same = VaultNoteSnapshot(path:excerpt.notePath,text:try excerpt.markdown(),
            sha256:CanvasPacket.sha(Data(try excerpt.markdown().utf8)),modifiedAt:"fixture")
        let result = await state.savePDFExcerpt(allowCreate:true,create:{ _,_ in
            puts += 1
            throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:classification.rawValue])
        },load:{ _ in
            reads += 1
            if reads == 1 { throw NSError(domain:"CanvasRelay",code:404) }
            return same
        })
        check(result == nil && puts == 1 && reads == 1 && state.scene == before && state.hasPendingPDFExcerpt,
              "explicit PDF publication conflict cannot be accepted through same-text GET")
        let held = CanvasStore(noteRecoveryURL:home.appendingPathComponent("typed-note-\(classification.rawValue).json"),
            pdfExcerptRecoveryURL:journal)
        held.scene = before
        held.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
        let restoredResult = await held.savePDFExcerpt(allowCreate:true,create:{_,_ in puts += 1; return same},load:{_ in reads += 1; return same})
        check(restoredResult == nil && puts == 1 && reads == 1 && held.pdfExcerptRecovery?.saveConflict == classification,
              "Store restart preserves typed conflict and never republishes or silently consumes the journal")
    }
    let heldStore = CanvasStore(noteRecoveryURL:home.appendingPathComponent("held-note.json"),
        pdfExcerptRecoveryURL:home.appendingPathComponent("held-pdf.json"))
    heldStore.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
    check(heldStore.preparePDFExcerpt(excerpt),"held GET fixture prepares PDF journal")
    let heldScene = heldStore.scene
    let heldResult = await heldStore.savePDFExcerpt(allowCreate:false,create:{_,_ in preconditionFailure("read-only recovery")},load:{_ in
        VaultNoteSnapshot(path:excerpt.notePath,text:try excerpt.markdown(),
            sha256:CanvasPacket.sha(Data(try excerpt.markdown().utf8)),modifiedAt:"fixture",reconciliationRequired:true)
    })
    check(heldResult == nil && heldStore.scene == heldScene && heldStore.hasPendingPDFExcerpt,
          "same-text GET with reconciliationRequired preserves scene and PDF creation journal")
    var creates = 0
    let empty = VaultNoteSnapshot(path:excerpt.notePath,text:"",sha256:CanvasPacket.sha(Data()),modifiedAt:"fixture")
    let attached = await recreated.savePDFExcerpt(allowCreate:true,create:{_,_ in creates += 1; return empty },load:{_ in empty})
    check(attached == nil && creates == 0 && recreated.hasPendingPDFExcerpt,
          "existing empty note remains a create-only conflict with zero PUT")
    check(try Data(contentsOf:normalURL) == normalBytes,"create conflict never changes the ordinary journal")
    try JSONEncoder().encode(excerpt).write(to:home.appendingPathComponent("legacy-excerpt.json"))
    try JSONEncoder().encode(creating.scene).write(to:home.appendingPathComponent("legacy-scene.json"))

    let draftURL = home.appendingPathComponent("ordinary-draft.json"), brokenPDF = home.appendingPathComponent("unreadable-create.json")
    let ordinary = VaultNoteRecovery(schemaVersion:1,sceneID:creating.scene.id,nodeID:nil,blockID:nil,
        relayAddress:"http://fixture.invalid",base:original,draft:original.text + "\n일반 노트 초안",submittedText:nil)
    let ordinaryBytes = try JSONEncoder().encode(VaultNoteRecoveryFile(ordinary))
    try ordinaryBytes.write(to:draftURL)
    try Data("unreadable PDF create journal".utf8).write(to:brokenPDF)
    let normal = CanvasStore(noteRecoveryURL:draftURL,pdfExcerptRecoveryURL:brokenPDF)
    normal.scene = creating.scene
    normal.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
    await normal.restoreNoteDraft(load:{_ in original})
    let restoredOrdinaryBytes = try Data(contentsOf:draftURL)
    check(normal.vaultDraft == ordinary.draft && normal.vaultNote == original && normal.vaultCanSave,
          "unreadable PDF journal does not block existing ordinary note draft recovery")
    check(!normal.preparePDFExcerpt(excerpt) && normal.vaultDraft == ordinary.draft && normal.vaultNote == original,
          "PDF prepare cannot replace ordinary recovery or dirty input")
    check(try Data(contentsOf:draftURL) == restoredOrdinaryBytes &&
          JSONDecoder().decode(VaultNoteRecoveryFile.self,from:restoredOrdinaryBytes).record() == ordinary,
          "PDF prepare leaves restored ordinary recovery bytes and payload unchanged")
    try JSONEncoder().encode(original).write(to:home.appendingPathComponent("ordinary-base.json"))

    do {
        let (_,_,returned) = try excerpt.sourcePage(in:snapshot)
        check(returned.string?.utf8.elementsEqual(selected.string!.utf8) == true,
              "Unicode PDF capture and source return preserve exact selected bytes")
    } catch { check(false,"Unicode PDF capture/source return failed: \(error)") }
    let encoded = try JSONSerialization.jsonObject(with:JSONEncoder().encode(excerpt)) as! [String:Any]
    check(encoded["schemaVersion"] as? Int == 2 && (encoded["textRanges"] as? [[String:Any]])?.isEmpty == false,
          "new native selection stores versioned text ranges")
    for ranges in [[["location":-1,"length":1]],[["location":0,"length":0]],
                   [["location":Int.max-1,"length":4]],[["location":0,"length":1,"nativeID":3]]] {
        var bad = encoded; bad["textRanges"] = ranges
        let text = "```ccr-pdf-source-v2\n" + String(decoding:try JSONSerialization.data(withJSONObject:bad),as:UTF8.self) + "\n```\n"
        do { _ = try VaultPDFExcerpt.parse(text); check(false,"invalid native range must refuse") }
        catch { check(true,"invalid or unknown native range field refuses at provenance boundary") }
    }
    for key in ["textRanges","selectionRects","quote"] {
        var bad = encoded
        if key == "textRanges" { bad[key] = [["location":1_000_000,"length":1]] }
        if key == "selectionRects" {
            var rects = encoded[key] as! [[String:Any]]
            rects[0]["x"] = (rects[0]["x"] as! Double) + 0.5
            bad[key] = rects
        }
        if key == "quote" { bad[key] = excerpt.quote.replacingOccurrences(of:"é",with:"e\u{301}") }
        let value = try JSONDecoder().decode(VaultPDFExcerpt.self,from:JSONSerialization.data(withJSONObject:bad))
        do { _ = try value.sourcePage(in:snapshot); check(false,"changed \(key) must refuse") }
        catch { check(true,"changed \(key) refuses exact source confirmation") }
    }

    let retained = URL(fileURLWithPath:env["PDF_RECOVERY_RETAINED"]!)
    let retainedBytes = try Data(contentsOf:retained)
    let retainedSnapshot = VaultPDFSnapshot(path:"자체.pdf",sha256:CanvasPacket.sha(retainedBytes),dataBase64:retainedBytes.base64EncodedString())
    let retainedDoc = PDFDocument(data:retainedBytes)!, retainedPage = retainedDoc.page(at:0)!
    let core = retainedPage.selection(for:(retainedPage.string! as NSString).range(of:"Core"))!
    func legacy(_ quote: String) -> VaultPDFExcerpt {
        VaultPDFExcerpt(schemaVersion:1,excerptID:UUID(),pdfPath:retainedSnapshot.path,pdfSha256:retainedSnapshot.sha256,
            pageIndex:0,mediaBox:.init(retainedPage.bounds(for:.mediaBox)),cropBox:.init(retainedPage.bounds(for:.cropBox)),
            rotation:0,selectionRects:[.init(core.bounds(for:retainedPage))],quote:quote)
    }
    let geometry = legacy("Core")
    check(try VaultPDFExcerpt.parse(geometry.markdown()) == geometry,"schema1 geometry-only Markdown remains readable")
    check(try geometry.sourcePage(in:retainedSnapshot).2.string == "Core","schema1 geometry-only source return remains supported")

    for quote in ["원문에 ccr-pdf-source 리터럴", "[링크](https://example.invalid) <img src=x onerror=alert(1)> `코드` ![[노트]]",
                  "```ccr-pdf-source-v99\n원문은 지시가 아님\n```\n한글 e\u{301} 👩🏽‍💻 & &#60;", "a\r\nb\rc\u{2028}d"] {
        let value = legacy(quote)
        do {
            let text = try value.markdown()
            let parsed = try VaultPDFExcerpt.parse(text)
            check(parsed?.quote.utf8.elementsEqual(quote.utf8) == true,"provenance JSON preserves literal quote bytes")
            let display = text.components(separatedBy:"\n\n## 메모")[0].components(separatedBy:"\n\n").dropFirst(2).joined(separator:"\n\n")
            check(!display.contains("<img") && !display.contains("[링크]") && !display.contains("`") && !display.contains("![["),
                  "display quote encodes Markdown, HTML and fence syntax as readable text")
            let rendered = try AttributedString(markdown:display)
            check(rendered.runs.allSatisfy({ $0.link == nil }),"display quote creates no Markdown link")
        } catch { check(false,"literal quote roundtrip failed: \(error)") }
    }
    do { check(try VaultPDFExcerpt.parse("일반 문장의 ccr-pdf-source 리터럴") == nil,"plain source marker text is not provenance") }
    catch { check(false,"plain source marker text was rejected: \(error)") }
    let validMarkdown = try geometry.markdown()
    for suffix in [validMarkdown,"```ccr-pdf-source-v99\n{}\n```\n","```ccr-pdf-source\n{}\n```\n",
                   " ```ccr-pdf-source-v1\n{}\n ```\n","~~~ccr-pdf-source-v1\n{}\n~~~\n","````ccr-pdf-source-v1\n{}\n````\n"] {
        do { _ = try VaultPDFExcerpt.parse(validMarkdown + "\n" + suffix); check(false,"duplicate or unsupported fence must refuse") }
        catch { check(true,"duplicate or unsupported anchored fence refuses") }
    }
    for prefix in ["```ccr-pdf-source-v99\n{}\n```\n","```ccr-pdf-source-v2-extra\n{}\n```\n",
                   " ```ccr-pdf-source-v1\n{}\n ```\n","~~~ccr-pdf-source-v1\n{}\n~~~\n","````ccr-pdf-source-v1\n{}\n````\n"] {
        do { _ = try VaultPDFExcerpt.parse(prefix); check(false,"unsupported fence must refuse") }
        catch { check(true,"unsupported standalone fence refuses") }
    }

    let data = NSMutableData()
    let target = CGDataConsumer(data:data)!
    var media = CGRect(x:0,y:0,width:612,height:792)
    let context = CGContext(consumer:target,mediaBox:&media,nil)!
    context.beginPDFPage(nil)
    let lines = ["Adjacent [source] letters 한글 e\u{301} é 👩🏽‍💻", "Second line with repeated Core and Core", "Third line Z"]
    for (index,line) in lines.enumerated() {
        context.textPosition = CGPoint(x:50,y:720 - index * 30)
        let attrs: [NSAttributedString.Key:Any] = [.font:CTFontCreateWithName("Helvetica" as CFString,16,nil)]
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:line,attributes:attrs)),context)
    }
    context.endPDFPage(); context.closePDF()
    let multilineBytes = data as Data
    try multilineBytes.write(to:home.appendingPathComponent("multiline.pdf"))
    print("MULTILINE_PDF_SHA256 \(CanvasPacket.sha(multilineBytes))")
    let multiline = PDFDocument(data:multilineBytes)!, multilinePage = multiline.page(at:0)!
    let text = multilinePage.string! as NSString
    let cases = [NSRange(location:0,length:text.length),text.range(of:"[source]"),text.range(of:"한글"),text.range(of:"Core")]
    let multilineSnapshot = VaultPDFSnapshot(path:"여러줄.pdf",sha256:CanvasPacket.sha(multilineBytes),dataBase64:multilineBytes.base64EncodedString())
    for range in cases {
        let selection = multilinePage.selection(for:range)!
        do {
            let value = try VaultPDFExcerpt.capture(snapshot:multilineSnapshot,document:multiline,selection:selection)
            let parsed = try VaultPDFExcerpt.parse(value.markdown())!
            let returned = try parsed.sourcePage(in:multilineSnapshot).2
            check(returned.string?.utf8.elementsEqual(selection.string!.utf8) == true,"native range roundtrip \(range)")
        } catch { check(false,"native range roundtrip \(range) failed: \(error)") }
    }
    let disjoint = PDFSelection(document:multiline)
    disjoint.add(multilinePage.selection(for:text.range(of:"Adjacent"))!)
    disjoint.add(multilinePage.selection(for:text.range(of:"Third"))!)
    do {
        let value = try VaultPDFExcerpt.capture(snapshot:multilineSnapshot,document:multiline,selection:disjoint)
        check(try value.sourcePage(in:multilineSnapshot).2.string?.utf8.elementsEqual(disjoint.string!.utf8) == true,
              "disjoint native text ranges preserve exact PDFSelection text")
    } catch { check(false,"disjoint native range source return failed: \(error)") }
    check(try Data(contentsOf:fixture) == bytes && Data(contentsOf:retained) == retainedBytes,
          "Unicode and retained PDF inputs remain byte-identical")
    check(!VaultPDFError.changed.localizedDescription.hasPrefix("changed") && !VaultPDFError.missing.localizedDescription.hasPrefix("missing"),
          "changed and missing state prefixes use Korean")
}

#if DEBUG
@MainActor func checkPDFIsolatedRecovery(_ check: (Bool,String) -> Void) async throws {
    guard case .isolated(let context) = CanvasRuntime.launch else { preconditionFailure("isolated context required") }
    let fixture = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PDF_RECOVERY_FIXTURE"]!)
    let bytes = try Data(contentsOf:fixture)
    let snapshot = VaultPDFSnapshot(path:"격리 원본.pdf",sha256:CanvasPacket.sha(bytes),dataBase64:bytes.base64EncodedString())
    let document = PDFDocument(data:bytes)!, page = document.page(at:0)!
    let excerpt = try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,
        selection:page.selection(for:NSRange(location:0,length:(page.string! as NSString).length))!)
    let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
    let normal = support.appendingPathComponent(CanvasRuntime.StateFile.pdfExcerptRecovery.rawValue)
    let normalBytes = try Data(contentsOf:normal)
    let url = try CanvasRuntime.stateURL(.pdfExcerptRecovery,pdfExcerptRecoveryOverride:normal)
    check(url == support.appendingPathComponent("CCRIntegrationTests/\(context.id.uuidString.lowercased())/state/CanvasPDFExcerptCreate/recovery.json"),
          "isolated launch ignores normal PDF override and selects its registered StateFile")
    let store = CanvasStore(pdfExcerptRecoveryURL:normal)
    store.scene.schemaVersion = 3
    store.setNoteConnection(address:context.relayAddress,token:context.token)
    let noteChoiceURL = try CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json")
    var noteChoice = NoteConflictLocalChoice(schema:"ccr.note-conflict-choice/v1",sceneID:store.scene.id,address:context.relayAddress,
        path:excerpt.notePath,backupFilename:"NoteConflictLocal-11111111-1111-4111-8111-111111111111.json",
        backupSHA256:String(repeating:"a",count:64),snapshot:Data(),decision:"keepCurrent",phase:.pending)
    try CanvasLocalFile.write(JSONEncoder().encode(noteChoice),to:noteChoiceURL)
    check(store.noteReconciliationHeld && !store.preparePDFExcerpt(excerpt) && store.pdfExcerptRecovery == nil,
          "held general-note recovery blocks PDF preparation before any PDF journal is created")
    noteChoice.phase = .completed
    try CanvasLocalFile.write(JSONEncoder().encode(noteChoice),to:noteChoiceURL)
    check(store.preparePDFExcerpt(excerpt),"actual isolated Store durably prepares PDF create intent")
    let journal = try CanvasLocalFile.read(url)
    check(try JSONDecoder().decode(VaultPDFCreateRecoveryFile.self,from:journal).record() == store.pdfExcerptRecovery,
          "actual isolated file decodes the same PDF create intent")
    check(!store.canApplyReconciledCanvas,"pending PDF intent blocks Canvas reconciliation before scene replacement")
    let sceneEncoder = JSONEncoder(); sceneEncoder.outputFormatting = [.sortedKeys]
    let sceneBefore = try sceneEncoder.encode(store.scene)
    let conflictURL = try CanvasRuntime.conflictRecoveryURL("CanvasConflictChoice.json")
    let conflictBytes = Data("별도 Canvas 충돌 선택 원문 e\u{301}\r\n".utf8)
    try CanvasLocalFile.write(conflictBytes,to:conflictURL)
    do {
        try store.applyReconciledCanvas(store.scene,expectedLocalSHA:CanvasPacket.sha(sceneBefore),preservedAt:conflictURL)
        check(false,"pending PDF reconciliation must refuse")
    } catch {
        check(try sceneEncoder.encode(store.scene) == sceneBefore && CanvasLocalFile.read(url) == journal,
              "actual apply refuses while preserving PDF journal and original scene")
    }
    check(!store.canCompareNoteConflict,"pending PDF journal blocks unrelated general-note reconciliation capture")
    do { _ = try store.captureNoteConflictLocal(path:excerpt.notePath); check(false,"pending PDF capture must refuse") }
    catch { check(true,"general-note archive cannot omit an active PDF recovery journal") }
    noteChoice.phase = .pending
    try CanvasLocalFile.write(JSONEncoder().encode(noteChoice),to:noteChoiceURL)
    var crossedCalls = 0
    let crossed = await store.savePDFExcerpt(allowCreate:true,create:{_,_ in crossedCalls += 1; throw URLError(.unknown)},
        load:{_ in crossedCalls += 1; throw URLError(.unknown)})
    let crossedJournal = try CanvasLocalFile.read(url)
    check(crossed == nil && crossedCalls == 0 && crossedJournal == journal,
          "general-note held barrier blocks PDF GET/PUT and preserves the exact pending PDF journal")
    noteChoice.phase = .completed
    try CanvasLocalFile.write(JSONEncoder().encode(noteChoice),to:noteChoiceURL)
    let reopened = CanvasStore(pdfExcerptRecoveryURL:normal)
    reopened.setNoteConnection(address:context.relayAddress,token:context.token)
    check(reopened.pdfExcerptRecovery == store.pdfExcerptRecovery && reopened.scene.id == store.scene.id,
          "Store restart restores both scene identity and separate PDF journal in isolated state")
    var puts = 0, saved: VaultNoteSnapshot?
    let readOnly = await reopened.savePDFExcerpt(allowCreate:false,create:{_,_ in puts += 1; preconditionFailure("read-only recovery")},
        load:{_ in throw NSError(domain:"CanvasRelay",code:404)})
    check(readOnly == nil && puts == 0 && reopened.hasPendingPDFExcerpt,
          "isolated result confirmation performs no creation after missing GET")
    let attached = await reopened.savePDFExcerpt(allowCreate:true,create:{path,text in
        puts += 1
        saved = VaultNoteSnapshot(path:path,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"fixture")
        throw URLError(.networkConnectionLost)
    },load:{_ in
        guard let saved else { throw NSError(domain:"CanvasRelay",code:404) }
        return saved
    })
    check(attached != nil && puts == 1 && !reopened.hasPendingPDFExcerpt && reopened.scene.schemaVersion == 3,
          "isolated lost response confirms same-path GET and attaches one existing-kind scene3 card")
    let final = CanvasStore(pdfExcerptRecoveryURL:normal)
    check(final.pdfExcerptRecovery == nil && final.scene.nodes.filter({$0.vaultNote?.path == excerpt.notePath}).count == 1,
          "isolated scene and cleared journal reopen without a duplicate card")
    check(try CanvasLocalFile.read(conflictURL) == conflictBytes,"PDF prepare/reopen/ACK recovery leaves separate Canvas conflict choice byte-identical")
    check(final.canApplyReconciledCanvas,"confirmed PDF journal clearing restores Canvas reconciliation eligibility")
    try CanvasLocalFile.write(Data("damaged PDF recovery".utf8),to:url)
    let damaged = CanvasStore(pdfExcerptRecoveryURL:normal)
    check(!damaged.canApplyReconciledCanvas,"unreadable PDF journal also protects original Canvas until explicit recovery")
    check(try Data(contentsOf:normal) == normalBytes,"normal PDF recovery bytes remain unchanged by actual Store execution")
}
#endif
