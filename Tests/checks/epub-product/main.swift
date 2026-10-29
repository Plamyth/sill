import Foundation
import AppKit
import PencilKit

@MainActor final class OwnEPUBVault {
    let process = Process(), input = Pipe(), output = Pipe()
    var operations: [String] = []
    init() throws {
        let env = ProcessInfo.processInfo.environment
        process.executableURL = URL(fileURLWithPath:env["EPUB_PRODUCT_NODE"]!)
        process.arguments = [env["EPUB_PRODUCT_BACKEND"]!]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
    }
    func close() { try? input.fileHandleForWriting.close(); process.waitUntilExit(); precondition(process.terminationStatus == 0) }
    func call(_ operation: String, _ arguments: [String:Any] = [:]) throws -> Data {
        operations.append(operation)
        var row = arguments; row["operation"] = operation
        var bytes = try JSONSerialization.data(withJSONObject:row); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf:bytes)
        var line = Data()
        while let part = try output.fileHandleForReading.read(upToCount:1), !part.isEmpty { if part[0] == 10 { break }; line.append(part) }
        let answer = try JSONSerialization.jsonObject(with:line) as! [String:Any]
        guard answer["ok"] as? Bool == true else {
            let held = answer["reconciliationRequired"] as? Bool == true || answer["code"] as? String == "note_reconciliation_required"
            throw NSError(domain:"CanvasRelay",code:answer["status"] as? Int ?? 500,userInfo:[NSLocalizedDescriptionKey:answer["message"] as? String ?? "own fixture",VaultSaveConflict.errorKey:held ? VaultSaveConflict.reconciliationRequired.rawValue : VaultSaveConflict.unclassified.rawValue])
        }
        return try JSONSerialization.data(withJSONObject:answer["value"]!)
    }
    func epub(_ path: String) async throws -> VaultEPUBSnapshot { try JSONDecoder().decode(VaultEPUBSnapshot.self,from:call("readEPUB",["path":path])) }
    func note(_ path: String) async throws -> VaultNoteSnapshot { try JSONDecoder().decode(VaultNoteSnapshot.self,from:call("readNote",["path":path])) }
    func save(_ path: String, _ base: String?, _ text: String) async throws -> VaultNoteSnapshot {
        try JSONDecoder().decode(VaultNoteSnapshot.self,from:call("saveNote",["path":path,"baseSha256":base as Any? ?? NSNull(),"text":text]))
    }
    func compare(_ path: String) async throws -> CanvasRelay.NoteConflict { try JSONDecoder().decode(CanvasRelay.NoteConflict.self,from:call("compare",["path":path])).validated(path:path) }
    func resolve(_ conflict: CanvasRelay.NoteConflict, _ decision: CanvasRelay.ConflictDecision) async throws -> VaultNoteSnapshot {
        let expected = try JSONSerialization.jsonObject(with:JSONEncoder().encode(conflict.expected))
        _ = try call("resolve",["path":conflict.path,"request":["recoveryID":conflict.recoveryID.uuidString.lowercased(),"expected":expected,"decision":decision.rawValue]])
        return try await note(conflict.path)
    }
}

@main struct EPUBProductChecks {
    static var assertions: [String] = []
    static func check(_ value: Bool, _ name: String) { precondition(value,name); assertions.append(name); print("PASS",name) }
    static func sameAnchor(_ left: VaultEPUBExcerpt?, _ right: VaultEPUBExcerpt) -> Bool {
        guard let left else { return false }
        return left.sourcePath.utf8.elementsEqual(right.sourcePath.utf8) && left.sourceSHA256 == right.sourceSHA256 &&
            left.spineItem.utf8.elementsEqual(right.spineItem.utf8) && left.chapterPath.utf8.elementsEqual(right.chapterPath.utf8) &&
            left.xpath == right.xpath && left.range.ns == right.range.ns && left.quote.utf8.elementsEqual(right.quote.utf8)
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated only") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        let vault = try OwnEPUBVault(); defer { vault.close() }
        let path = "book.epub", sourceURL = out.appendingPathComponent("vault/book.epub")
        let sourceBytes = try Data(contentsOf:sourceURL)
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==")!
        func store() -> CanvasStore { let s = CanvasStore(); s.enableDocumentChecks(); s.filePreview = { _ in png }; s.setNoteConnection(address:context.relayAddress,token:context.token); return s }
        if CommandLine.arguments.contains("--reopen") {
            let s = store(), expected = try JSONDecoder().decode(VaultEPUBExcerpt.self,from:Data(contentsOf:out.appendingPathComponent("expected-source.json")))
            if CommandLine.arguments.contains("--pending") {
                check(s.hasPendingEPUBExcerpt && s.pdfExcerptRecovery?.path == expected.notePath,"fresh process restores same EPUB ID and complete draft")
                check(!s.canTransitionDocument,"fresh process pending intent blocks whole-document replacement")
            } else {
                check(s.documentFileReady && s.isDocumentSource && s.document.pages.count == 2,"fresh process restores actual whole Files binding and ordered pages")
                check(s.scene.nodes.contains { $0.vaultNote?.path == expected.notePath },"fresh process retains linked excerpt card")
            }
            let opened = await s.openEPUB(path,source:expected,load:vault.epub)
            if !opened { print("REOPEN",s.vaultStatus,s.sceneRecoveryNotice,s.pdfExcerptRecoveryNotice) }
            check(try opened && sameAnchor(s.epubReader?.capture(),expected),"fresh process returns exact archive/chapter/XPath/UTF16 quote")
            return
        }
        func reopen(_ source: VaultEPUBExcerpt, pending: Bool = false) throws {
            try JSONEncoder().encode(source).write(to:out.appendingPathComponent("expected-source.json"))
            let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
            child.arguments = [out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--reopen"] + (pending ? ["--pending"] : [])
            try child.run(); child.waitUntilExit(); check(child.terminationStatus == 0,"separate process \(pending ? "pending" : "Files") completes")
        }
        var s = store()
        let entries = try JSONSerialization.jsonObject(with:vault.call("entries")) as! [[String:Any]]
        check(entries.contains { $0["path"] as? String == path && $0["kind"] as? String == "epub" },"actual own Vault lists EPUB kind")
        var opened = await s.openEPUB(path,load:vault.epub)
        if !opened { print("OPEN",s.vaultStatus,s.sceneRecoveryNotice,s.pdfExcerptRecoveryNotice) }
        check(opened,"Store opens module Reader from actual own archive")
        var reader = s.epubReader!
        try reader.openChapter(1)
        reader.view.setSelectedRange((reader.view.string as NSString).range(of:"문구 😀"))
        let source = try reader.prepareExcerpt(), stable = try reader.prepareExcerpt()
        check(source == stable && source.spineItem == "two" && source.quote == "문구 😀","native selection produces stable ID and correct second chapter UTF16 quote")
        check(!s.closeEPUBReader() && s.epubReader === reader,"unrecorded native selection is retained on close")
        check(s.prepareEPUBExcerpt(source),"Store durably records same ID before sending")
        try reopen(source,pending:true)
        let id = await s.saveEPUBExcerpt(allowCreate:true,create:{ try await vault.save($0,nil,$1) },load:vault.note)
        check(id != nil && !s.hasPendingEPUBExcerpt && !s.vaultSaving,"actual exclusive note create and full GET attach card then close intent")
        var note = try await vault.note(source.notePath)
        check(try VaultEPUBExcerpt.parse(note.text) == source,"human/AI Markdown preserves exact source payload")
        check(s.scene.nodes.first { $0.id == id }?.vaultNote?.quoteSha256 == CanvasPacket.sha(Data(source.quote.utf8)),"card binds full note SHA and quote SHA")
        check(s.closeVaultEditor(),"confirmed excerpt editor closes without draft")
        try s.createDocument()
        let folder = out.appendingPathComponent("selected-files",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        await s.connectDocumentWorkspace(folder)
        await s.duplicateDocumentPage()
        check(s.documentFileReady && s.document.pages.count == 2,"actual whole Files generation includes copied page and source references")
        try reopen(source)
        let files = CanvasDocumentFiles(folder:folder,requiresScope:false)
        check(try files.load(s.document.id).document == s.document,"complete readback matches every page and source card")
        // Existing note CAS and inverse full GET; source block stays immutable while user memo changes.
        note = try await vault.save(note.path,note.sha256,note.text + "\n외부에서 추가한 메모\n")
        await s.refreshVaultNotes(load:vault.note)
        let linked = s.scene.nodes.first { $0.vaultNote?.path == source.notePath }!
        await s.openVaultNote(note.path,nodeID:linked.id,load:vault.note)
        check(s.vaultNote?.sha256 == note.sha256 && s.vaultDraft.utf8.elementsEqual(note.text.utf8),"external Markdown CAS changes reverse into Store full text and SHA")
        check(try VaultEPUBExcerpt.parse(s.vaultDraft) == source,"external memo retains immutable EPUB anchor")
        check(s.closeVaultEditor(),"inverse read closes without draft")
        opened = await s.openEPUB(path,source:source,load:vault.epub)
        check(try opened && sameAnchor(s.epubReader?.capture(),source),"card returns exact source after external memo change")
        reader = s.epubReader!
        let invalid = await s.openEPUB("hidden.epub",load:vault.epub)
        check(!invalid && s.epubReader === reader,"unsupported XHTML refuses without replacing previous Reader")
        let wrong = try JSONDecoder().decode(VaultEPUBSnapshot.self,from:JSONSerialization.data(withJSONObject:["path":path,"sha256":String(repeating:"0",count:64),"dataBase64":sourceBytes.base64EncodedString()]))
        let changed = await s.openEPUB(path,source:source,load:{ _ in wrong })
        check(!changed && s.epubReader === reader,"source hash mismatch refuses instead of showing guessed text")
        check(s.closeEPUBReader(),"verified read-only Reader closes")
        await s.saveDocumentWorkspace()
        // Page ABA must retire the prior load even when scene returns to the same page UUID.
        let pageA = s.scene.id, pageB = s.document.pages.first { $0.id != pageA }!.id
        let aba = await s.openEPUB(path,load:{ p in
            await s.selectDocumentPage(pageB)
            check(s.scene.id == pageA,"in-flight EPUB load blocks page switch")
            check(s.closeEPUBReader(),"explicit close cancels load ownership")
            await s.selectDocumentPage(pageB); await s.selectDocumentPage(pageA)
            check(s.scene.id == pageA,"actual page ABA returns to original page")
            return try await vault.epub(p)
        })
        check(!aba && s.epubReader == nil && !s.epubBusy,"late page ABA Reader result is rejected")
        // An uncertain create keeps the same durable intent. No successful acknowledgement is injected.
        opened = await s.openEPUB(path,load:vault.epub); check(opened,"Reader opens after canceled load")
        reader = s.epubReader!; reader.view.setSelectedRange(NSRange(location:0,length:2))
        let lostSource = try reader.prepareExcerpt()
        check(s.prepareEPUBExcerpt(lostSource),"second stable intent persists before uncertain send")
        var created = 0, reads = 0
        let lost = await s.saveEPUBExcerpt(allowCreate:true,create:{ p,t in created += 1; _ = try await vault.save(p,nil,t); throw URLError(.networkConnectionLost) },load:{ p in reads += 1; if reads > 1 { throw URLError(.notConnectedToInternet) }; return try await vault.note(p) })
        check(lost == nil && created == 1 && s.hasPendingEPUBExcerpt && s.pdfExcerptRecovery?.submittedText != nil,"lost create ACK plus unavailable GET retains same submitted intent")
        try reopen(lostSource,pending:true)
        s = store()
        let recovered = await s.saveEPUBExcerpt(allowCreate:false,create:{ _,_ in fatalError("must not resend") },load:vault.note)
        check(recovered != nil && !s.hasPendingEPUBExcerpt,"fresh Store full GET recovers own prior create without retry PUT")
        check(s.closeVaultEditor(),"recovered source editor closes")
        await s.saveDocumentWorkspace()
        // An existing note must never be overwritten via nil-base creation.
        opened = await s.openEPUB(path,load:vault.epub); check(opened,"Reader opens for existing-note collision")
        reader = s.epubReader!; reader.view.setSelectedRange(NSRange(location:0,length:2))
        let collision = try reader.prepareExcerpt(), submitted = try collision.markdown()
        check(s.prepareEPUBExcerpt(collision),"collision intent is durable")
        let external = try await vault.save(collision.notePath,nil,submitted + "\n외부 메모 유지\n")
        let refused = await s.saveEPUBExcerpt(allowCreate:true,create:{ _,_ in fatalError("existing note must not create") },load:vault.note)
        check(refused == nil && s.hasPendingEPUBExcerpt,"existing different full text cannot auto-attach or overwrite")
        await s.compareEPUBExcerptConflict(load:vault.compare,loadCurrent:vault.note)
        check(s.epubCurrentChoice?.current.sha256 == external.sha256,"missing server journal requires explicit current-note comparison")
        await s.adoptEPUBExcerptCurrent(load:vault.note)
        let adopted = await s.saveEPUBExcerpt(allowCreate:false,create:{ _,_ in fatalError("must not create") },load:vault.note)
        check(adopted != nil && s.vaultNote?.sha256 == external.sha256,"explicit current adoption then full GET retains external memo and attaches")
        check(s.closeVaultEditor(),"adopted editor closes")
        await s.saveDocumentWorkspace()
        // Real preservation conflict: actual exchange helper retains the pre-exchange note.
        opened = await s.openEPUB(path,load:vault.epub); check(opened,"Reader opens for typed preserved conflict")
        reader = s.epubReader!; reader.view.setSelectedRange(NSRange(location:0,length:2))
        let conflictSource = try reader.prepareExcerpt()
        check(s.prepareEPUBExcerpt(conflictSource),"typed conflict starts with durable same-ID intent")
        let blocked = await s.saveEPUBExcerpt(allowCreate:true,create:{ p,t in
            let base = try await vault.save(p,nil,t + "\n기준 메모\n")
            _ = try vault.call("conflictingSave",["path":p,"baseSha256":base.sha256,"text":t,"external":t + "\n외부 원문 보존\n"])
            fatalError("post-exchange conflict must throw")
        },load:vault.note)
        check(blocked == nil && s.pdfExcerptRecovery?.saveConflict == .reconciliationRequired,"actual post-exchange typed409 persists reconciliation barrier")
        let beforeHeld = vault.operations.count
        let held = await s.saveEPUBExcerpt(allowCreate:true,create:{ _,_ in fatalError("held must not PUT") },load:{ _ in fatalError("held must not auto-GET-accept") })
        check(held == nil && vault.operations.count == beforeHeld,"typed409 cannot auto-checkpoint even if active note resembles proposal")
        try reopen(conflictSource,pending:true)
        s = store()
        await s.compareEPUBExcerptConflict(load:vault.compare,loadCurrent:vault.note)
        check(s.epubConflictChoice != nil && s.noteReconciliationHeld,"typed conflict reads bounded active/base/displaced/proposal for explicit choice")
        await s.resolveEPUBExcerptConflict(.keepCurrent,resolve:vault.resolve)
        check(s.epubConflictChoice?.closed == true && !s.noteReconciliationHeld && s.hasPendingEPUBExcerpt,"explicit resolution closes choice but leaves card attachment pending full GET")
        let resolved = await s.saveEPUBExcerpt(allowCreate:false,create:{ _,_ in fatalError("resolution must not create") },load:vault.note)
        check(resolved != nil && s.vaultDraft.contains("외부 원문 보존"),"explicit current choice preserves external memo and attaches after GET")
        check(s.closeVaultEditor(),"resolved conflict editor closes")
        await s.saveDocumentWorkspace()
        // Non404 and connection ABA keep original intent and cannot create or apply a late result.
        opened = await s.openEPUB(path,load:vault.epub); check(opened,"Reader opens for callback ownership")
        reader = s.epubReader!; reader.view.setSelectedRange(NSRange(location:0,length:2))
        let callbackSource = try reader.prepareExcerpt()
        check(s.prepareEPUBExcerpt(callbackSource),"callback test records immutable draft before send")
        let offline = await s.saveEPUBExcerpt(allowCreate:true,create:{ _,_ in fatalError("non404 must not create") },load:{ _ in throw URLError(.notConnectedToInternet) })
        check(offline == nil && s.hasPendingEPUBExcerpt,"unavailable GET does not imply absent note or nil-base permission")
        let late = await s.saveEPUBExcerpt(allowCreate:true,create:{ p,t in
            let note = try await vault.save(p,nil,t)
            check(!s.closeEPUBReader(),"Store close refuses during owned save")
            s.setNoteConnection(address:"http://192.168.88.89:4242",token:context.token)
            s.setNoteConnection(address:context.relayAddress,token:context.token)
            return note
        },load:vault.note)
        check(late == nil && !s.vaultSaving && s.hasPendingEPUBExcerpt && !s.scene.nodes.contains { $0.vaultNote?.path == callbackSource.notePath },"late connection ABA cannot attach or erase durable pending ID")
        try reopen(callbackSource,pending:true)
        s = store()
        let afterABA = await s.saveEPUBExcerpt(allowCreate:false,create:{ _,_ in fatalError("no retry") },load:vault.note)
        check(afterABA != nil && !s.hasPendingEPUBExcerpt,"explicit fresh-process GET resumes same callback intent")
        check(s.closeVaultEditor(),"callback recovery editor closes")
        await s.saveDocumentWorkspace()
        check(try Data(contentsOf:sourceURL) == sourceBytes,"all Store/create/recovery paths keep EPUB original bytes unchanged")
        let result: [String:Any] = ["assertions":assertions,"count":assertions.count,"operations":vault.operations,"sourceSHA256":CanvasPacket.sha(sourceBytes),"actualStore":true,"actualOwnObsidianFiles":true,"HTTP":false,"GUI":false,"moduleP2Cleared":false,"wholeEPUBAccepted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
    }
}
