import Foundation
import AppKit

@main struct EPUBRepairP2 {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        let original = root.appendingPathComponent("source.epub"), note = root.appendingPathComponent("excerpt.md")
        let path = "own/source.epub"
        func load(_ name: String) throws -> VaultEPUBSnapshot {
            try .read(root.appendingPathComponent("fixtures/\(name).epub"),path:path)
        }
        func selectionMatches(_ reader: VaultEPUBReader,_ excerpt: VaultEPUBExcerpt) throws -> Bool {
            let selected = try reader.capture()
            return selected.sourceSHA256 == excerpt.sourceSHA256 && selected.sourcePath.utf8.elementsEqual(excerpt.sourcePath.utf8) &&
                selected.chapterPath.utf8.elementsEqual(excerpt.chapterPath.utf8) && selected.xpath == excerpt.xpath &&
                selected.range.location == excerpt.range.location && selected.range.length == excerpt.range.length &&
                selected.quote.utf8.elementsEqual(excerpt.quote.utf8)
        }
        if CommandLine.arguments.contains("--reopen") {
            let snapshot = try VaultEPUBSnapshot.read(original,path:path,expectedSHA:CommandLine.arguments[3])
            let excerpt = try VaultEPUBExcerpt.parse(String(decoding:Data(contentsOf:note),as:UTF8.self))!
            let reader = try VaultEPUBReader(snapshot:snapshot)
            try reader.reveal(excerpt)
            let matches = try selectionMatches(reader,excerpt)
            precondition(matches)
            print("PASS child-file-note-reopen")
            return
        }
        var checks = [String]()
        func check(_ name: String,_ condition: Bool) {
            precondition(condition,name); checks.append(name); print("PASS \(name)")
        }
        func refuses(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        for name in ["hidden-xhtml","hidden-dat","hidden-only-dat","style-only-dat","ncx-alias","ncx-reverse-alias"] {
            check(name,refuses { _ = try VaultEPUBBook(snapshot:load(name)) })
        }
        var identities = [[String:Any]]()
        for name in ["ncx-exact","ncx-exact-nfd","visible-dat"] {
            let reader = try VaultEPUBReader(snapshot:load(name)), entry = reader.book.toc[0]
            try reader.openChapter(entry.chapter,fragment:entry.fragment)
            let id = reader.book.chapters[entry.chapter].paragraphs[0].fragment!
            check(name,entry.fragment!.utf8.elementsEqual(id.utf8))
            identities.append(["case":name,"tocUTF8":Array(entry.fragment!.utf8),"paragraphUTF8":Array(id.utf8)])
        }
        let good = try load("ncx-exact")
        try good.writeVerifiedCopy(to:original)
        let reader = try VaultEPUBReader(snapshot:.read(original,path:path,expectedSHA:good.sha256))
        reader.view.setSelectedRange(NSRange(location:0,length:7))
        let pending = try reader.prepareExcerpt(), text = reader.view.string, selection = reader.view.selectedRange()
        try Data(pending.markdown().utf8).write(to:note,options:.withoutOverwriting)
        let noteBytes = try Data(contentsOf:note)
        for name in ["hidden-dat","ncx-alias"] {
            let rejected = try load(name), candidate = root.appendingPathComponent(name+"-preserved.epub")
            try rejected.writeVerifiedCopy(to:candidate)
            check(name+"-open-refused",refuses { _ = try VaultEPUBReader(snapshot:.read(candidate,path:path)) })
            check(name+"-bytes-preserved",try Data(contentsOf:candidate) == rejected.bytes(at:path))
            check(name+"-reader-pending-preserved",reader.pendingExcerpt == pending && reader.view.string.utf8.elementsEqual(text.utf8) && reader.view.selectedRange() == selection && reader.book.snapshot.sha256 == good.sha256)
            check(name+"-original-note-preserved",try Data(contentsOf:original) == good.bytes(at:path) && Data(contentsOf:note) == noteBytes)
        }
        check("copy-refuses-overwrite",refuses { try load("hidden-dat").writeVerifiedCopy(to:original) })
        check("copy-keeps-original",try Data(contentsOf:original) == good.bytes(at:path))
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]); child.arguments = [root.path,"--reopen",good.sha256]
        child.standardOutput = output; child.standardError = output
        try child.run(); child.waitUntilExit()
        let childLog = output.fileHandleForReading.readDataToEndOfFile()
        try childLog.write(to:root.appendingPathComponent("child.log"))
        check("new-process-reopen",child.terminationStatus == 0)
        let changed = try load("ncx-alias")
        try changed.bytes(at:path).write(to:original,options:.atomic)
        check("external-change-refused",refuses { _ = try VaultEPUBSnapshot.read(original,path:path,expectedSHA:good.sha256) })
        check("external-change-preserved",try Data(contentsOf:original) == changed.bytes(at:path))
        let corrupt = Data([0x50,0x4b,0x03])
        try corrupt.write(to:original,options:.atomic)
        check("corruption-refused",refuses { _ = try VaultEPUBReader(snapshot:.read(original,path:path)) })
        check("corruption-kept-pending-note",try Data(contentsOf:original) == corrupt && Data(contentsOf:note) == noteBytes && reader.pendingExcerpt == pending)
        let restored = root.appendingPathComponent("explicit-good-copy.epub")
        try good.writeVerifiedCopy(to:restored)
        let reopened = try VaultEPUBReader(snapshot:.read(restored,path:path,expectedSHA:good.sha256))
        try reopened.reveal(pending)
        check("explicit-recovery-after-failure",try selectionMatches(reopened,pending) && Data(contentsOf:original) == corrupt)
        try JSONSerialization.data(withJSONObject:["checks":checks,"identities":identities],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("observations.json"))
    }
}
