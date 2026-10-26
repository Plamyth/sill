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
        let store = CanvasStore(noteRecoveryURL:url,noteRecoveryWrite:{ data,url in
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
    let dirty = CanvasStore(noteRecoveryURL:home.appendingPathComponent("dirty.json"))
    dirty.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
    await dirty.openVaultNote(original.path,load:{_ in original})
    dirty.vaultDraft += "\n미저장 입력"
    dirty.vaultSelection = NSRange(location:1,length:2)
    let dirtyInput = dirty.vaultInputSessionID, draft = dirty.vaultDraft, selection = dirty.vaultSelection
    check(!dirty.preparePDFExcerpt(excerpt) && dirty.vaultDraft == draft && dirty.vaultNote == original &&
          dirty.vaultInputSessionID == dirtyInput && dirty.vaultSelection == selection,
          "dirty editor refuses before changing draft, selection or input session")

    do {
        let (_,_,returned) = try excerpt.sourcePage(in:snapshot)
        check(returned.string?.utf8.elementsEqual(selected.string!.utf8) == true,
              "Unicode PDF capture and source return preserve exact selected bytes")
    } catch { check(false,"Unicode PDF capture/source return failed: \(error)") }
    let encoded = try JSONSerialization.jsonObject(with:JSONEncoder().encode(excerpt)) as! [String:Any]
    check(encoded["schemaVersion"] as? Int == 2 && (encoded["textRanges"] as? [[String:Any]])?.isEmpty == false,
          "new native selection stores versioned text ranges")

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
    for suffix in [validMarkdown,"```ccr-pdf-source-v99\n{}\n```\n","```ccr-pdf-source\n{}\n```\n"] {
        do { _ = try VaultPDFExcerpt.parse(validMarkdown + "\n" + suffix); check(false,"duplicate or unsupported fence must refuse") }
        catch { check(true,"duplicate or unsupported anchored fence refuses") }
    }
    for prefix in ["```ccr-pdf-source-v99\n{}\n```\n","```ccr-pdf-source-v2-extra\n{}\n```\n"] {
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
