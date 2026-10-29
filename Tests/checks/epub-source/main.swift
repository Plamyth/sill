import Foundation
import AppKit

@main struct EPUBChecks {
    static var checks: [String] = []
    static func check(_ value: Bool,_ name: String) { precondition(value,name); checks.append(name); print("PASS \(name)") }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        let sourcePath = "문서/원문.epub", windows = NSApplication.shared.windows.count
        let normal = root.appendingPathComponent("normal.epub")
        let snapshot = try VaultEPUBSnapshot.read(normal,path:sourcePath)
        let book = try VaultEPUBBook(snapshot:snapshot), reader = try VaultEPUBReader(snapshot:snapshot)
        if CommandLine.arguments.contains("--rea-archive") {
            check(snapshot.sha256 == "57c6950a4b480ec0c780bd555329adce039ad844b327d4165ccb827ad7eba901","exact archived own REA NCX input SHA")
            check(book.chapters.count == 2 && book.toc.map(\.title) == ["첫 장 · Alpha","둘째 장 · Beta"],"actual archived own REA spine and NCX")
            let block = book.chapters[0].paragraphs[1], range = (block.text as NSString).range(of:"Alpha")
            let excerpt = try VaultEPUBExcerpt.capture(book:book,chapter:0,paragraph:1,range:range)
            try reader.openChapter(1); try reader.setFontSize(30); try reader.reveal(excerpt)
            check(excerpt.range.location == 22 && reader.chapterIndex == 0 && reader.view.string.substring(reader.view.selectedRange()) == "Alpha","actual own archive returns via exact UTF16 after chapter and font change")
            try JSONSerialization.data(withJSONObject:["checks":checks,"count":checks.count,"sourceSHA256":snapshot.sha256,"GUI":false],options:.sortedKeys).write(to:root.appendingPathComponent("rea-observations.json"))
            return
        }
        if CommandLine.arguments.contains("--reopen") {
            let text = try String(contentsOf:root.appendingPathComponent("excerpt.md"),encoding:.utf8)
            let excerpt = try VaultEPUBExcerpt.parse(text)!
            try reader.reveal(excerpt)
            check(reader.view.string.substring(reader.view.selectedRange()) == "Alpha","fresh process restores exact chapter XPath UTF16 quote")
            check(try snapshot.bytes(at:sourcePath) == Data(contentsOf:root.appendingPathComponent("copy.epub")),"fresh process reopens original archive bytes")
            return
        }
        check(book.chapters.count == 2 && book.toc.count == 2 && book.toc[1].chapter == 1,"ordered spine and NCX chapters")
        let alphaRange = (book.chapters[0].paragraphs[1].text as NSString).range(of:"Alpha")
        let betaRange = (book.chapters[1].paragraphs[1].text as NSString).range(of:"Beta")
        let alpha = try VaultEPUBExcerpt.capture(book:book,chapter:0,paragraph:1,range:alphaRange)
        let beta = try VaultEPUBExcerpt.capture(book:book,chapter:1,paragraph:1,range:betaRange)
        check(alpha.range.location == 22 && beta.range.location == 22 && alpha.range.length == 5 && beta.range.length == 4,"emoji offsets use UTF16 22 rather than code-point count 21")
        check(alpha.xpath == beta.xpath && alpha.chapterPath != beta.chapterPath && alpha.spineItem != beta.spineItem,"same XPath and offset identify separate chapters")
        check(alpha.excerptID != beta.excerptID && alpha.sourceID == beta.sourceID && alpha.sourceID != snapshot.sha256,"source path identity source bytes and excerpt identity remain distinct")
        try reader.reveal(beta)
        check(reader.chapterIndex == 1 && reader.view.string.substring(reader.view.selectedRange()) == "Beta","native text selection returns to second chapter")
        try reader.setFontSize(30); try reader.reveal(alpha)
        check(reader.chapterIndex == 0 && reader.view.string.substring(reader.view.selectedRange()) == "Alpha","reflow returns to exact original quote")
        try reader.setFontSize(14)
        check(reader.view.string.substring(reader.view.selectedRange()) == "Alpha","font change preserves selected UTF16 range")
        let markdown = try alpha.markdown()
        check(try VaultEPUBExcerpt.parse(markdown) == alpha,"human-readable Markdown is the one source anchor ledger")
        try Data(markdown.utf8).write(to:root.appendingPathComponent("excerpt.md"),options:.withoutOverwriting)
        let note = VaultNoteSnapshot(path:alpha.notePath,text:markdown,sha256:CanvasPacket.sha(Data(markdown.utf8)),modifiedAt:"")
        let reference = try alpha.reference(note:note,relayAddress:"http://127.0.0.1:4242")
        check(reference.path == alpha.notePath && reference.quoteSha256 == CanvasPacket.sha(Data("Alpha".utf8)),"existing note source reference carries actual note and quote hashes")
        let pending = try reader.prepareExcerpt(), draft = try pending.markdown()
        let noteFile = root.appendingPathComponent("pending.md")
        try Data(draft.utf8).write(to:noteFile,options:.withoutOverwriting)
        do { _ = try reader.acceptSavedNote(note,relayAddress:"http://127.0.0.1:4242"); check(false,"wrong note acknowledgement") }
        catch { check(try reader.prepareExcerpt().excerptID == pending.excerptID,"failed acknowledgement retains exact excerpt ID and draft") }
        let savedText = try String(contentsOf:noteFile,encoding:.utf8)
        _ = try reader.acceptSavedNote(.init(path:pending.notePath,text:savedText,sha256:CanvasPacket.sha(Data(savedText.utf8)),modifiedAt:""),relayAddress:"http://127.0.0.1:4242")
        check(reader.pendingExcerpt == nil,"only exact actual note readback clears pending selection")
        try snapshot.writeVerifiedCopy(to:root.appendingPathComponent("copy.epub"))
        let process = Process(); process.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
        process.arguments = [root.path,"--reopen"]; try process.run(); process.waitUntilExit()
        check(process.terminationStatus == 0,"separate process reopens native text source and saved Markdown")
        let existing = try Data(contentsOf:root.appendingPathComponent("copy.epub"))
        do { try snapshot.writeVerifiedCopy(to:root.appendingPathComponent("copy.epub")); check(false,"copy must not overwrite") } catch { check(try Data(contentsOf:root.appendingPathComponent("copy.epub")) == existing,"existing archive never overwritten by safe copy") }
        let changed = root.appendingPathComponent("changed.epub"), changedBytes = try Data(contentsOf:changed)
        do { _ = try VaultEPUBSnapshot.read(changed,path:sourcePath,expectedSHA:snapshot.sha256); check(false,"changed source must be refused") }
        catch { check(try Data(contentsOf:changed) == changedBytes,"external source SHA mismatch preserves current file bytes") }
        let other = try VaultEPUBBook(snapshot:VaultEPUBSnapshot.read(changed,path:sourcePath))
        do { _ = try alpha.resolve(in:other); check(false,"anchor must not silently rebase") } catch { check(true,"external archive changes refuse old anchors instead of searching another occurrence") }
        let beforeSelection = reader.view.selectedRange(), beforeText = reader.view.string
        let foreign = try VaultEPUBExcerpt.capture(book:other,chapter:0,paragraph:1,range:alphaRange)
        do { try reader.reveal(foreign); check(false,"foreign return must fail") } catch { check(reader.view.selectedRange() == beforeSelection && reader.view.string == beforeText,"failed source return leaves current reading text and selection intact") }
        for name in try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("rejected").path).sorted() {
            let url = root.appendingPathComponent("rejected/"+name), raw = try Data(contentsOf:url)
            do { _ = try VaultEPUBBook(snapshot:VaultEPUBSnapshot(path:sourcePath,bytes:raw)); check(false,"must reject \(name)") }
            catch { check(try Data(contentsOf:url) == raw,"reject and preserve \(name)") }
        }
        for (name,broken) in [
            ("duplicate-key",markdown.replacingOccurrences(of:"\"schemaVersion\":1",with:"\"schemaVersion\":0,\"schemaVersion\":1")),
            ("multiple-sources",markdown+markdown),
            ("future-schema",markdown.replacingOccurrences(of:"ccr-epub-source-v1",with:"ccr-epub-source-v2"))
        ] {
            do { _ = try VaultEPUBExcerpt.parse(broken); check(false,"must reject source \(name)") } catch { check(true,"strict note contract rejects \(name)") }
        }
        check(NSApplication.shared.windows.count == windows,"native tests create no window")
        let result: [String:Any] = ["checks":checks,"count":checks.count,"nativeText":true,"actualFiles":true,"newProcess":true,"GUI":false,"device":false,"network":false,"installed":false]
        try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:root.appendingPathComponent("observations.json"))
    }
}

private extension String {
    func substring(_ range: NSRange) -> String { (self as NSString).substring(with:range) }
}
