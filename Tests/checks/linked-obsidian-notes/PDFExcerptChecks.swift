import Foundation
import PDFKit

struct PDFRemoteFailure: Error { let status: Int }

private struct PDFRemoteReply<Value:Decodable>: Decodable { let ok: Bool; let value: Value?; let status: Int? }

final class PDFRemoteVault {
    static var shared: PDFRemoteVault?
    private let process = Process()
    private let input = Pipe(), output = Pipe()

    init() throws {
        let env = ProcessInfo.processInfo.environment
        process.executableURL = URL(fileURLWithPath:"/Users/ambrion/.local/bin/mini-ephemeral-source")
        process.arguments = ["run","--source",env["PENCIL_RELAY_REPO"]!,"--owner",env["CODEX_THREAD_ID"]!,
            "--job","pdf-vault-roundtrip-20261026","--","/Users/sin-wonho/.local/bin/node","tests/pdf-excerpt-fixture.cjs"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
        let ready = try JSONSerialization.jsonObject(with:line()) as? [String:Bool]
        guard ready?["ready"] == true else { throw CocoaError(.executableRuntimeMismatch) }
    }

    private func line() throws -> Data {
        var bytes = Data()
        while let part = try output.fileHandleForReading.read(upToCount:1), !part.isEmpty {
            if part[0] == 10 { return bytes }
            bytes.append(part)
            guard bytes.count <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        }
        throw CocoaError(.fileReadUnknown)
    }

    func run<T: Decodable>(_ request: [String:Any], as: T.Type) throws -> T {
        try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:request) + Data([10]))
        let reply = try JSONDecoder().decode(PDFRemoteReply<T>.self,from:line())
        guard reply.ok, let value = reply.value else { throw PDFRemoteFailure(status:reply.status ?? 500) }
        return value
    }

    func note(_ path: String) throws -> VaultNoteSnapshot {
        do { return try run(["operation":"readNote","path":path],as:VaultNoteSnapshot.self).validated(at:path) }
        catch let error as PDFRemoteFailure { throw NSError(domain:"CanvasRelay",code:error.status) }
    }

    func create(_ path: String, _ text: String) throws -> VaultNoteSnapshot {
        try run(["operation":"saveNote","path":path,"baseSha256":NSNull(),"text":text],as:VaultNoteSnapshot.self)
    }

    func finish() throws {
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }
}

@MainActor func checkPDFExcerptRoundtrip(_ check: (Bool,String) -> Void) async throws {
    let bridge = PDFRemoteVault.shared!
    let snapshot = try bridge.run(["operation":"readPDF"],as:VaultPDFSnapshot.self)
    let original = try snapshot.bytes(at:"원본.pdf")
    let document = PDFDocument(data:original)!, page = document.page(at:0)!
    let range = (page.string! as NSString).range(of:"Core")
    let selected = page.selection(for:range)!
    let excerpt = try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,selection:selected)
    let markdown = try excerpt.markdown()
    check(excerpt.quote == "Core" && excerpt.pageIndex == 0 && excerpt.rotation == 0,
          "PDFKit native selection records actual page-space rects and selected quote")
    check(try VaultPDFExcerpt.parse(markdown) == excerpt && markdown.contains("[[원본.pdf#page=1]]"),
          "Markdown keeps human page link and versioned machine provenance")
    check(try VaultPDFExcerpt.parse(markdown + "\nMac에서 뒤에 덧붙인 메모\n") == excerpt,
          "appending editable Markdown after provenance keeps source readable")
    let (_,returnedPage,returnedSelection) = try excerpt.sourcePage(in:snapshot)
    check(returnedSelection.string == "Core" && returnedPage.string == page.string,
          "source return selects the same page and geometric Core rather than another identical word")
    func store(_ name: String) -> CanvasStore {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!)
            .appendingPathComponent(name)
        let defaults = UserDefaults(suiteName:"pdf-excerpt-fixture-"+name)!
        let result = CanvasStore(noteRecoveryURL:root.appendingPathComponent("note.json"),defaults:defaults)
        result.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
        return result
    }
    let editor = store("pdf-first")
    editor.scene = CanvasScene()
    check(editor.preparePDFExcerpt(excerpt),"stable UUID and exact Markdown are journaled before network creation")
    let nodeID = await editor.savePDFExcerpt(allowCreate:true,create:{ path,text in
        _ = try bridge.create(path,text)
        throw URLError(.networkConnectionLost)
    },load:bridge.note)
    check(nodeID != nil && editor.noteRecovery == nil,"lost PUT response reconciles through exact GET and attaches once")
    check(try bridge.run(["operation":"countNotes"],as:Int.self) == 1,"lost response creates exactly one Markdown excerpt")
    let ref = editor.scene.nodes.first(where:{$0.id == nodeID})!.vaultNote!
    check(ref.path == excerpt.notePath && ref.blockID == nil && VaultNoteReference.validPath(ref.path),
          "scene uses only the existing Markdown VaultNoteReference")
    let newStore = store("pdf-reopen")
    check(newStore.scene.nodes.first(where:{$0.id == nodeID})?.vaultNote == ref,
          "scene autosave reopens the attached card in a fresh Store")
    await newStore.openVaultNote(ref.path,nodeID:nodeID,load:bridge.note)
    check(newStore.vaultDraft == markdown,"fresh Store reopens exact Markdown excerpt")
    newStore.vaultDraft = markdown.replacingOccurrences(of:"## 메모\n\n",with:"## 메모\n\niPad 편집 👩🏽‍💻\n")
    await newStore.saveVaultNote(save:{ path,sha,text in
        try bridge.run(["operation":"saveNote","path":path,"baseSha256":sha,"text":text],as:VaultNoteSnapshot.self)
    },load:bridge.note)
    let saved = try bridge.note(ref.path)
    check(saved.text.contains("iPad 편집"),"editable knowledge card saves via existing note CAS and exact GET")
    let macText = saved.text.replacingOccurrences(of:"iPad 편집",with:"Mac Markdown 역수신")
    _ = try bridge.run(["operation":"saveNote","path":ref.path,"baseSha256":saved.sha256,"text":macText],as:VaultNoteSnapshot.self)
    await newStore.refreshVaultNotes(load:bridge.note)
    check(newStore.scene.nodes.first(where:{$0.id == nodeID})?.text.contains("Mac Markdown 역수신") == true,
          "Mac Markdown edits flow back to the existing card cache")
    check(try VaultPDFExcerpt.parse(macText) == excerpt,"editable memo preserves PDF anchor and excerpt ID")
    let cache = newStore.scene
    _ = try bridge.run(["operation":"changePDF"],as:Bool.self)
    let changed = try bridge.run(["operation":"readPDF"],as:VaultPDFSnapshot.self)
    do { _ = try excerpt.sourcePage(in:changed); check(false,"changed PDF must refuse old coordinates") }
    catch VaultPDFError.changed { check(true,"changed PDF reports changed without altering cache") }
    _ = try bridge.run(["operation":"removePDF"],as:Bool.self)
    do { _ = try bridge.run(["operation":"readPDF"],as:VaultPDFSnapshot.self); check(false,"missing PDF must refuse") }
    catch let error as PDFRemoteFailure { check(error.status == 404,"deleted PDF reports missing") }
    check(newStore.scene == cache,"changed or missing PDF never discards the cached card")

    let blocked = store("pdf-cas")
    _ = blocked.closeVaultEditor()
    let conflict = try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,selection:selected)
    check(blocked.preparePDFExcerpt(conflict),"conflicting create retains one stable identity")
    _ = try bridge.create(conflict.notePath,"Mac owns this path")
    let blockedID = await blocked.savePDFExcerpt(allowCreate:true,create:bridge.create,load:bridge.note)
    check(blockedID == nil && blocked.hasPendingPDFExcerpt,"CAS conflict preserves intent without attaching wrong text")
    check(try bridge.note(conflict.notePath).text == "Mac owns this path","CAS conflict never overwrites Mac data")
    let restart = store("pdf-cas")
    check(restart.noteRecovery?.base.path == conflict.notePath,"pending creation survives fresh Store restart")
    var creates = 0
    _ = await restart.savePDFExcerpt(allowCreate:false,create:{path,text in creates += 1; return try bridge.create(path,text)},load:bridge.note)
    check(creates == 0,"recovery result check never retries PUT or generates another ID")

    let uncertain = store("pdf-uncertain")
    _ = uncertain.closeVaultEditor()
    let lost = try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,selection:selected)
    _ = uncertain.preparePDFExcerpt(lost)
    var reads = 0, writes = 0
    _ = await uncertain.savePDFExcerpt(allowCreate:true,create:{path,text in
        writes += 1; _ = try bridge.create(path,text); throw URLError(.networkConnectionLost)
    },load:{ path in
        reads += 1
        if reads > 1 { throw URLError(.timedOut) }
        return try bridge.note(path)
    })
    check(uncertain.hasPendingPDFExcerpt && writes == 1,"lost PUT plus lost GET retains durable intent")
    let recovered = store("pdf-uncertain")
    let resolved = await recovered.savePDFExcerpt(allowCreate:false,create:{path,text in
        writes += 1; return try bridge.create(path,text)
    },load:bridge.note)
    check(resolved != nil && writes == 1 && !recovered.hasPendingPDFExcerpt,
          "fresh Store resolves response loss with one GET and zero duplicate writes")
    let total = try bridge.run(["operation":"countNotes"],as:Int.self)
    _ = await recovered.savePDFExcerpt(allowCreate:true,create:bridge.create,load:bridge.note)
    check(try bridge.run(["operation":"countNotes"],as:Int.self) == total,"repeated completion adds neither note nor card")

    let stale = store("pdf-delayed")
    _ = stale.closeVaultEditor()
    let staleExcerpt = try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,selection:selected)
    _ = stale.preparePDFExcerpt(staleExcerpt)
    let gate = NoteGate()
    let oldScene = stale.scene.id
    let response = VaultNoteSnapshot(path:staleExcerpt.notePath,text:try staleExcerpt.markdown(),
        sha256:CanvasPacket.sha(Data(try staleExcerpt.markdown().utf8)),modifiedAt:"fixture")
    let pending = Task { await stale.savePDFExcerpt(allowCreate:false,create:bridge.create,load:gate.load) }
    await gate.wait()
    stale.scene = CanvasScene()
    gate.finish(response)
    let staleID = await pending.value
    check(staleID == nil && stale.scene.nodes.isEmpty && stale.noteRecovery?.sceneID == oldScene,
          "late source callback cannot attach to a different scene or discard original intent")

    let unavailable = CanvasStore(noteRecoveryURL:URL(fileURLWithPath:ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!)
        .appendingPathComponent("pdf-failed-journal.json"),noteRecoveryWrite:{_,_ in throw CocoaError(.fileWriteNoPermission)})
    unavailable.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
    check(!unavailable.preparePDFExcerpt(excerpt) && !unavailable.hasPendingPDFExcerpt,
          "failed durable journal prevents creation before any request can be sent")

    let json = try JSONEncoder().encode(excerpt)
    var object = try JSONSerialization.jsonObject(with:json) as! [String:Any]
    for key in ["pdfPath","schemaVersion","pageIndex","rotation","selectionRects","nativeID"] {
        var bad = object
        switch key {
        case "pdfPath": bad[key] = "../escape.pdf"
        case "schemaVersion": bad[key] = 99
        case "pageIndex": bad[key] = -1
        case "rotation": bad[key] = 90
        case "selectionRects": bad[key] = [["x":-100,"y":0,"width":1,"height":2]]
        default: bad[key] = "invented-native-ID"
        }
        let text = VaultPDFExcerpt.fence + String(decoding:try JSONSerialization.data(withJSONObject:bad),as:UTF8.self) + "\n```\n"
        do { _ = try VaultPDFExcerpt.parse(text); check(false,"untrusted \(key) must refuse") }
        catch { check(true,"untrusted \(key) refuses at Markdown boundary") }
    }
    object["quote"] = "Different text"
    let mismatch = try JSONDecoder().decode(VaultPDFExcerpt.self,from:JSONSerialization.data(withJSONObject:object))
    do { _ = try mismatch.sourcePage(in:snapshot); check(false,"mismatched quote must refuse") }
    catch { check(true,"valid geometry with mismatched quote refuses source confirmation") }
    check(CanvasPacket.sha(original) == snapshot.sha256,"original PDF bytes remain read-only across save and source return")
}

func checkRetainedNativePDFAnchor(_ check: (Bool,String) -> Void) throws {
    guard let fixture = ProcessInfo.processInfo.environment["PENCIL_REA_FIXTURE"] else { return }
    let data = try Data(contentsOf:URL(fileURLWithPath:fixture))
    let object = try JSONSerialization.jsonObject(with:data) as! [String:Any]
    let info = object["document"] as! [String:Any], anchor = object["anchor"] as! [String:Any]
    let bytes = try Data(contentsOf:URL(fileURLWithPath:info["extracted_path"] as! String))
    let hash = info["sha256"] as! String
    check(CanvasPacket.sha(bytes) == hash,"retained REA PDF hash matches immutable evidence")
    let document = PDFDocument(data:bytes)!, page = document.page(at:0)!
    let values = anchor["native_selection_rect"] as! [Double]
    let rect = CGRect(x:values[0],y:values[1],width:values[2],height:values[3])
    let selected = page.selection(for:rect)!
    check(selected.string == "Core","retained native rect selects actual Core in PDFKit page coordinates")
    let snapshot = VaultPDFSnapshot(path:"자체 REA.pdf",sha256:hash,dataBase64:bytes.base64EncodedString())
    let excerpt = VaultPDFExcerpt(schemaVersion:1,excerptID:UUID(),pdfPath:snapshot.path,pdfSha256:hash,
        pageIndex:0,mediaBox:.init(page.bounds(for:.mediaBox)),cropBox:.init(page.bounds(for:.cropBox)),
        rotation:page.rotation,selectionRects:[.init(rect)],quote:"Core")
    let (_,_,returned) = try excerpt.sourcePage(in:snapshot)
    check(returned.string == "Core","product source return validates retained PDF hash, bounds and native rect")
    check(excerpt.excerptID.uuidString != "16EE8B29-C1B3-479C-A739-F2B8369A007C",
          "CCR excerpt UUID is separate from historical native note ID")
    check(CanvasPacket.sha(try Data(contentsOf:URL(fileURLWithPath:info["extracted_path"] as! String))) == hash,
          "local native PDF probe does not mutate retained original")
}

private final class PDFSnapshotProtocol: URLProtocol {
    static var body = Data()
    static var status = 200
    static var declaredLength: Int?
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:nil,
            headerFields:["Content-Length":String(Self.declaredLength ?? Self.body.count)])!
        client!.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:Self.body)
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor func checkPDFReadTransport(_ check: (Bool,String) -> Void) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PDFSnapshotProtocol.self]
    let session = URLSession(configuration:configuration)
    defer { session.invalidateAndCancel() }
    let relay = CanvasRelay(address:"http://fixture.invalid",token:"test-token",session:session)
    let bytes = Data("%PDF-1.4\nfixture only\n%%EOF".utf8)
    PDFSnapshotProtocol.body = try JSONSerialization.data(withJSONObject:["path":"원본.pdf",
        "sha256":CanvasPacket.sha(bytes),"dataBase64":bytes.base64EncodedString()])
    PDFSnapshotProtocol.requests = []
    let pdf = try await relay.vaultPDF(at:"원본.pdf")
    check(try pdf.bytes(at:"원본.pdf") == bytes,"bounded PDF transport validates exact payload hash and magic")
    let request = PDFSnapshotProtocol.requests.last!
    check(request.httpMethod == "GET" && request.httpBody == nil && request.url?.path == "/vault/pdf" &&
          request.value(forHTTPHeaderField:"X-Canvas-Token") == "test-token",
          "PDF transport reuses authenticated relay and sends no PDF bytes")
    for (status,expected) in [(404,VaultPDFError.missing),(409,.changed),(413,.tooLarge),(401,.unavailable)] {
        PDFSnapshotProtocol.status = status
        PDFSnapshotProtocol.body = Data("{\"error\":\"fixture error\"}".utf8)
        do { _ = try await relay.vaultPDF(at:"원본.pdf"); check(false,"PDF status must refuse") }
        catch let error as VaultPDFError { check(error.localizedDescription == expected.localizedDescription,
            "PDF HTTP \(status) becomes explicit Korean state") }
    }
    PDFSnapshotProtocol.status = 200
    PDFSnapshotProtocol.declaredLength = 32 * 1024 * 1024
    do { _ = try await relay.vaultPDF(at:"원본.pdf"); check(false,"oversized envelope must refuse") }
    catch VaultPDFError.tooLarge { check(true,"declared oversized PDF response refuses before body accumulation") }
    PDFSnapshotProtocol.declaredLength = nil
    let count = PDFSnapshotProtocol.requests.count
    do { _ = try await relay.vaultPDF(at:"../escape.pdf"); check(false,"invalid PDF path must refuse") }
    catch VaultPDFError.invalid { check(PDFSnapshotProtocol.requests.count == count,"invalid path is rejected before any request") }
}
