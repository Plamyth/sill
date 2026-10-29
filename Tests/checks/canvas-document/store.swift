import Foundation
import PencilKit
import AppKit

// 실제 URLSession을 통과하는 격리 DTO fixture. socket/실서버/Pencil 인식 검사는 아니다.
final class DocumentProductProtocol: URLProtocol {
    static var handle: ((URLRequest,Data) throws -> (Int,Data))?
    static var paths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.paths.append(request.url!.path)
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating:0,count:16384)
                while true { let size = stream.read(&buffer,maxLength:buffer.count); if size <= 0 { break }; body.append(buffer,count:size) }
            }
            guard let handle = Self.handle else { throw URLError(.badServerResponse) }
            let (status,bytes) = try handle(request,body)
            client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client!.urlProtocol(self,didLoad:bytes); client!.urlProtocolDidFinishLoading(self)
        } catch { client!.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
@main struct DocumentStoreChecks {
    static var assertions: [String] = []
    static func check(_ ok: Bool, _ name: String) { precondition(ok,name); assertions.append(name); print("PASS \(name)") }
    static func bytes(_ x: Any) throws -> Data { try JSONSerialization.data(withJSONObject:x,options:[.sortedKeys,.withoutEscapingSlashes]) }
    static func object(_ x: Data) throws -> [String:Any] { try JSONSerialization.jsonObject(with:x) as! [String:Any] }
    static let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
    static func drawing(_ x: Double) throws -> PKDrawing {
        let points = [0.0,10,20].enumerated().map { i,dx in PKStrokePoint(location:CGPoint(x:x+dx,y:20+dx),timeOffset:Double(i)/10,size:CGSize(width:3,height:5),opacity:0.8,force:0.7,azimuth:0.3,altitude:1) }
        let native = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))])
        return try PKDrawing(data:native.dataRepresentation())
    }
    static func bundle(_ doc: CanvasDocument) throws -> (summary:[String:Any],bundle:Data) {
        let data = try doc.bytes(), previews = Dictionary(uniqueKeysWithValues:doc.pages.map { ($0.id,png) })
        let (put,_,_) = try CanvasDocumentRelay.Put.make(bytes:data,previews:previews,base:nil)
        let note = Data(("own whole-document fixture " + CanvasPacket.sha(data)).utf8)
        let summary: [String:Any] = ["schema":"ccr.vault-document/v1","id":doc.id.uuidString.lowercased(),"path":"CCR Documents/\(doc.id.uuidString.lowercased()).md","revision":doc.revision,"activePageID":doc.activePageID.uuidString.lowercased(),"noteSha256":CanvasPacket.sha(note),"documentSha256":CanvasPacket.sha(data),"manifestSha256":CanvasPacket.sha(Data("own manifest".utf8)),"generation":UUID().uuidString.lowercased(),"pages":put.pages.map { ["id":$0.id,"drawingSha256":$0.drawingSha256,"previewSha256":$0.previewSha256] }]
        var response = summary
        response["documentJSONBase64"] = data.base64EncodedString()
        response["pages"] = put.pages.map { ["id":$0.id,"drawingSha256":$0.drawingSha256,"previewSha256":$0.previewSha256,"previewPNGBase64":$0.previewPNGBase64] }
        return (summary,try bytes(response))
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated required") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        let cache = try CanvasRuntime.stateURL(.documentSource), legacy = try CanvasRuntime.stateURL(.scene)
        if CommandLine.arguments.contains("--reopen") {
            let store = CanvasStore(); store.enableDocumentChecks()
            let expected = try CanvasDocument.decode(Data(contentsOf:out.appendingPathComponent("expected.json")))
            check(store.isDocumentSource && store.sceneRecoveryNotice.isEmpty && store.document == expected,"new process reopens all ordered pages and ink")
            check(store.documentFileReady,"new process readback binds Files identity and full token")
            return
        }
        if CommandLine.arguments.contains("--held-reopen") {
            let store = CanvasStore(); store.enableDocumentChecks()
            check(store.isDocumentSource && store.documentSyncHeld && !store.canTransitionDocument,"new process retains unknown send and transition barrier")
            return
        }
        func reopen(_ flag: String) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
            process.arguments = [out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),flag]
            try process.run(); process.waitUntilExit(); check(process.terminationStatus == 0,"separate process \(flag)")
        }
        let store = CanvasStore(); store.enableDocumentChecks(); store.filePreview = { _ in png }
        check(!store.isDocumentSource && store.document.pages.count == 1,"legacy entry remains single scene mode")
        _ = store.updateDrawing(try drawing(10)); store.addNode(.note)
        store.scene.nodes[0].text = "원본 메모 e\u{301} 🖊️"
        store.scene.annotations = [.init(id:UUID(),nodeId:store.scene.nodes[0].id,text:"원본 댓글",author:"사용자")]
        store.saveNow()
        let original = store.scene
        try store.createDocument()
        let oldLegacy = try Data(contentsOf:legacy) // 명시 legacy flush 뒤부터 문서 모드의 byte 보존 기준이다.
        check(store.isDocumentSource && store.document.pages == [original],"explicit document entry wraps complete legacy page")
        let folder = out.appendingPathComponent("selected-files",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        await store.connectDocumentWorkspace(folder)
        print("BIND",store.documentFileReady,store.documentBusy,store.status,store.fileWorkspaceStatus,store.canTransitionDocument)
        check(store.documentFileReady && !store.documentBusy,"whole Files bind completes and releases busy")
        let files = CanvasDocumentFiles(folder:folder,requiresScope:false), id = store.document.id
        func paths(_ folder: URL) throws -> [String:Data] {
            let entries = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey])!
            var result: [String:Data] = [:]
            for case let url as URL in entries where (try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true) {
                result[url.path] = try Data(contentsOf:url)
            }
            return result
        }
        let noopBefore = try paths(folder)
        store.saveNow()
        check(store.documentFileReady,"unchanged cache flush keeps verified Files readiness")
        await store.saveDocumentWorkspace()
        check(try paths(folder) == noopBefore,"Store autosave unchanged document creates no Files paths or copied bytes")
        let firstID = store.scene.id, firstBytes = store.scene.drawingBase64
        await store.duplicateDocumentPage()
        check(store.document.pages.count == 2 && store.scene.id != firstID,"duplicate inserts ordered page and selects it")
        let secondID = store.scene.id
        check(store.scene.drawingBase64 == firstBytes && store.scene.nodes[0].id != original.nodes[0].id && store.scene.annotations[0].nodeId == store.scene.nodes[0].id,"duplicate retains native ink and remaps node/comment ownership")
        check(try files.load(id).document == store.document,"Files readback contains both complete pages")
        // 같은 turn의 단계별 원본 수정. 첫 setter의 일시 mismatch를 외부 ingress로 오인하지 않는다.
        let newInk = try drawing(120), newRaw = newInk.dataRepresentation().base64EncodedString()
        store.scene.drawingBase64 = newRaw
        store.scene.strokes = CanvasScene.nativeInkStrokes(newInk)
        store.scene.revision += 1
        store.drawing = newInk
        check(store.scene.drawingBase64 == newRaw && store.scene.strokes == CanvasScene.nativeInkStrokes(newInk),"staged drawingBase64/strokes mutation retains final valid page")
        store.saveNow(); await store.saveDocumentWorkspace()
        check(store.documentFileReady,"completed staged mutation persists whole document")
        await store.selectDocumentPage(firstID)
        check(try store.scene.drawingBase64 == firstBytes && store.drawing == (try PKDrawing(data:Data(base64Encoded:firstBytes)!)),"select restores page-specific native drawing")
        await store.selectDocumentPage(secondID)
        check(store.scene.drawingBase64 == newRaw,"other page retains independent native drawing")
        check(try Data(contentsOf:legacy) == oldLegacy,"document edits never overwrite legacy scene cache")
        let legacyPacketBefore = try JSONEncoder().encode(store.outbox)
        do { _ = try store.preparePacket(scene:store.scene,imagePNG:png,session:.init(threadId:UUID(),sessionId:"own",observedAt:ISO8601DateFormatter().string(from:Date())),targetMode:nil,relayAddress:context.relayAddress); fatalError("document packet accepted") } catch { check((try JSONEncoder().encode(store.outbox)) == legacyPacketBefore,"document mode refuses selected-page packet") }
        // Native UndoManager를 페이지별 소유자로 유지한다.
        final class Counter { var value = 0 }
        let counter = Counter(), ownerB = store.nativeHistoryOwner
        let managerB = store.inkHistory.activate(ownerB); managerB.beginUndoGrouping()
        managerB.registerUndo(withTarget:counter) { $0.value += 1 }; managerB.endUndoGrouping()
        await store.selectDocumentPage(firstID)
        check(!store.inkHistory.commandAvailability.canUndo,"page A does not inherit page B native Undo")
        await store.selectDocumentPage(secondID); store.inkHistory.undo()
        check(counter.value == 1,"return to B restores its own native Undo")
        // 실제 공통 graph Undo도 페이지 간 분리한다.
        store.mode = .select; let node = store.scene.nodes[0]; store.selectedNode = node.id
        check(store.rotateNode(node,sceneID:secondID,to:25),"native Store rotation records graph Undo")
        let rotated = store.scene.nodes[0]
        await store.saveDocumentWorkspace(); await store.selectDocumentPage(firstID)
        check(!store.canUndoGraph,"page A does not inherit page B graph Undo")
        await store.selectDocumentPage(secondID); store.undoGraphEdit()
        check(store.scene.nodes[0].rotationDegrees == node.rotationDegrees && store.canRedoGraph,"B graph Undo restored after page return")
        store.redoGraphEdit(); check(store.scene.nodes[0].rotationDegrees == rotated.rotationDegrees,"B graph Redo remains owned")
        await store.saveDocumentWorkspace()
        for gate in ["Pencil","IME","sheet"] {
            let before = store.document
            if gate == "Pencil" { store.inkHistory.setUsingTool(true) }
            if gate == "IME" { store.vaultInputBusy = true }
            if gate == "sheet" { store.documentPresentationBusy = true }
            await store.selectDocumentPage(firstID)
            check(store.document == before,"\(gate) blocks page transition without losing original")
            store.inkHistory.setUsingTool(false); store.vaultInputBusy = false; store.documentPresentationBusy = false
        }
        var continuation: CheckedContinuation<String?,Never>?
        store.mode = .lasso; store.setInkSelection(Set(store.drawing.strokes.map(\.id)))
        let callback = Task { await store.proposeHandwriting { _ in await withCheckedContinuation { continuation = $0 } } }
        while continuation == nil { await Task.yield() }
        check(!store.canTransitionDocument,"recognition pending blocks transition")
        store.mode = .select // explicit cancellation; late result must not revive its proposal after A-B-A.
        await store.selectDocumentPage(firstID); await store.selectDocumentPage(secondID)
        let beforeCallback = store.document
        continuation!.resume(returning:"지연 결과"); await callback.value
        check(store.document == beforeCallback && store.proposedNode == nil,"A-B-A rejects late recognizer result")
        await store.saveDocumentWorkspace()
        // 비선택 페이지의 외부 변경도 문서 전체 CAS에 포함한다.
        var previewContinuation: CheckedContinuation<Data?,Never>?
        store.filePreview = { _ in await withCheckedContinuation { previewContinuation = $0 } }
        let cancelledSource = store.document
        let cancelled = Task { await store.duplicateDocumentPage() }
        while previewContinuation == nil { await Task.yield() }
        cancelled.cancel(); previewContinuation!.resume(returning:png); await cancelled.value
        check(store.document == cancelledSource && !store.documentBusy,"cancelled late preview preserves whole source and releases only its busy owner")
        store.filePreview = { _ in png }
        let beforeExternal = store.document, disk = try files.load(id)
        var external = disk.document, changed = external.pages.first { $0.id == firstID }!
        changed.nodes[0].text = "외부 변경"; changed.revision += 1
        try external.replacePage(changed,expectedRevision:external.revision)
        _ = try files.save(external,previews:disk.previews,expected:disk.token)
        await store.selectDocumentPage(firstID)
        check(try store.document == beforeExternal && (try files.load(id).document) == external,"hidden-page CAS change blocks switch and retains external document")
        let restartedExternal = CanvasStore(); restartedExternal.enableDocumentChecks()
        restartedExternal.refreshDocumentWorkspace()
        check(restartedExternal.document == external && restartedExternal.documentFileReady,"explicit clean-cache Files refresh recovers after restart without discarding local edits")
        await store.saveDocumentWorkspace()
        check(store.fileWorkspaceState == .blocked && store.document == beforeExternal,"failed external CAS marks blocked and keeps complete local source")
        check(try CanvasDocument.decode(store.sourceBytes()) == beforeExternal,"blocked source still exports complete preservation JSON without clearing barrier")
        store.refreshDocumentWorkspace()
        check(store.documentFileReady && store.fileWorkspaceState == .ready,"explicit clean Files refresh releases only verified local file barrier")
        check(store.document == external,"whole external document readback applies hidden page change")
        try store.document.bytes().write(to:out.appendingPathComponent("expected.json"))
        try reopen("--reopen")
        check(try store.documentWorkspaceDocuments(in:folder) == [id],"whole document listing validates canonical generation")
        // 원장 손상과 알 수 없는 복구 파일은 숨은 채로 통과하지 않는다.
        let checkpoint = try CanvasRuntime.stateURL(.checkpoint)
        try CanvasLocalFile.write(Data("broken".utf8),to:checkpoint)
        let beforeBarrier = store.document
        await store.selectDocumentPage(firstID)
        check(store.document == beforeBarrier,"corrupt hidden checkpoint blocks transition")
        try FileManager.default.removeItem(at:checkpoint)
        let recovery = try CanvasRuntime.conflictRecoveryURL("CanvasConflictChoice.json")
        try CanvasLocalFile.write(Data("broken".utf8),to:recovery)
        await store.selectDocumentPage(firstID)
        check(store.document == beforeBarrier,"corrupt recovery choice blocks transition")
        try FileManager.default.removeItem(at:recovery)
        let orphan = try CanvasRuntime.conflictRecoveryURL("CanvasConflictLocal-" + UUID().uuidString.lowercased() + ".json")
        try CanvasLocalFile.write(oldLegacy,to:orphan)
        await store.selectDocumentPage(firstID)
        check(store.document == beforeBarrier,"orphan full local recovery blocks transition")
        try FileManager.default.removeItem(at:orphan)
        let outbox = try CanvasRuntime.stateURL(.outbox)
        try CanvasLocalFile.write(Data("broken".utf8),to:outbox)
        let outboxStore = CanvasStore(); outboxStore.enableDocumentChecks()
        check(!outboxStore.canTransitionDocument,"corrupt hidden outbox blocks document transition")
        try FileManager.default.removeItem(at:outbox)
        for (name,file) in [("note",CanvasRuntime.StateFile.noteRecovery),("block",.blockRecovery),("pdf",.pdfExcerptRecovery)] {
            let journal = try CanvasRuntime.stateURL(file)
            try CanvasLocalFile.write(Data("broken".utf8),to:journal)
            let guarded = CanvasStore(); guarded.enableDocumentChecks()
            check(!guarded.canTransitionDocument,"corrupt hidden \(name) journal blocks transition without visible sheet")
            try FileManager.default.removeItem(at:journal)
        }
        // decode 실패는 legacy fallback을 허용하지 않는다. 손상 byte 자체를 보존한다.
        let savedCache = try Data(contentsOf:cache)
        var invalid = try object(savedCache); var badDoc = invalid["document"] as! [String:Any]; badDoc["version"] = 999; invalid["document"] = badDoc
        let badBytes = try bytes(invalid); try CanvasLocalFile.write(badBytes,to:cache)
        let rejected = CanvasStore(); rejected.enableDocumentChecks()
        check(try !rejected.sceneRecoveryNotice.isEmpty && !rejected.canTransitionDocument && (try Data(contentsOf:cache)) == badBytes,"unsupported document cache refuses legacy fallback and preserves bytes")
        try CanvasLocalFile.write(savedCache,to:cache)
        // 실패 후 전체 문서가 다시 열린다.
        let restored = CanvasStore(); restored.enableDocumentChecks(); restored.filePreview = { _ in png }
        check(restored.document == store.document && restored.documentFileReady,"full document reopens after failed ingress")
        // 실제 Files/cache IO 실패 후 page memory를 설치하지 않는다.
        let originalCache = cache.deletingLastPathComponent().appendingPathComponent("cache-before-io.json")
        try FileManager.default.moveItem(at:cache,to:originalCache)
        try FileManager.default.createSymbolicLink(at:cache,withDestinationURL:originalCache)
        let beforeIO = restored.document
        await restored.duplicateDocumentPage()
        check(try restored.document == beforeIO && (try Data(contentsOf:originalCache)) == savedCache,"cache no-follow failure preserves active document and old cache")
        try FileManager.default.removeItem(at:cache); try FileManager.default.moveItem(at:originalCache,to:cache)
        // 위 실패가 Files head 교체 후라면 재열기는 명시 보류다. 임의 retry로 성공 처리하지 않는다.
        let blocked = CanvasStore(); blocked.enableDocumentChecks()
        check(!blocked.sceneRecoveryNotice.isEmpty && !blocked.canTransitionDocument,"post-Files cache failure reopens blocked rather than false success")
        // 독립 HTTP fixture 문서로 새 격리 canonical 상태를 준비한다. 기존 Files 세대는 그대로 유지한다.
        try CanvasLocalFile.write(savedCache,to:cache)
        let httpStore = CanvasStore(); httpStore.enableDocumentChecks(); httpStore.filePreview = { _ in png }
        // 실패 후 head와 cache token 차이는 원본을 보존한 명시 import로 별도 폴더에 연결한다.
        let httpDoc = try CanvasDocument(legacy:CanvasScene())
        var state = try object(savedCache); state["document"] = try object(httpDoc.bytes()); state.removeValue(forKey:"binding"); state.removeValue(forKey:"sync")
        try CanvasLocalFile.write(bytes(state),to:cache)
        let client = CanvasStore(); client.enableDocumentChecks(); client.filePreview = { _ in png }
        let httpFolder = out.appendingPathComponent("http-files",isDirectory:true); try FileManager.default.createDirectory(at:httpFolder,withIntermediateDirectories:true)
        await client.connectDocumentWorkspace(httpFolder)
        check(client.documentFileReady,"HTTP product fixture has complete Files canonical source")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DocumentProductProtocol.self]
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
        let relay = CanvasRelay(address:context.relayAddress,token:context.token,session:session)
        client.setDocumentConnection(address:relay.address,token:relay.token)
        var active = try bundle(client.document)
        let capability: [String:Any] = ["schema":"ccr.canvas-capabilities/v1","document":["schema":"ccr.vault-document/v1","format":CanvasDocument.formatName,"versions":[1],"wholeDocument":true,"explicitConflictResolution":true,"maxDocumentJSONBytes":CanvasDocument.byteLimit,"maxPageCount":CanvasDocument.pageLimit,"maxPreviewTotalBytes":32*1024*1024,"maxRequestBytes":CanvasDocumentRelay.requestLimit]]
        DocumentProductProtocol.handle = { request,data in
            if request.url!.path == "/vault/canvas/capabilities" { return (200,try bytes(capability)) }
            if request.httpMethod == "PUT" {
                check(try object(data)["documentJSONBase64"] as? String == (try clientDocumentBytesPlaceholder(active.bundle)),"full PUT contains complete document bytes")
                return (200,try bytes(active.summary))
            }
            return (200,active.bundle)
        }
        await client.synchronizeDocumentToVault(relay)
        check(client.documentSync?.phase == .synchronized && !client.documentSyncHeld && !client.documentBusy,"whole API capability PUT reopen commits durable checkpoint")
        check(DocumentProductProtocol.paths.allSatisfy { $0 != "/vault/canvas" && $0 != "/canvas/packets" },"product path never publishes selected scene")
        var remote = client.document, remotePage = remote.activePage
        _ = remotePage.addNode(kind:.note,at:.init(x:30,y:30),text:"서버 역수신")
        remotePage.revision += 1; try remote.replacePage(remotePage,expectedRevision:remote.revision)
        active = try bundle(remote)
        await client.refreshDocumentFromVault(relay)
        check(try client.document == remote && (try CanvasDocumentFiles(folder:httpFolder,requiresScope:false).load(remote.id).document) == remote,"reverse GET installs entire document through Files readback")
        // 전송 후 ACK 유실은 durable sending/held이고 재시작 및 다음 자동 save에서 해제되지 않는다.
        client.scene.nodes[0].text = "새 로컬 입력"; client.scene.revision += 1
        await client.saveDocumentWorkspace()
        DocumentProductProtocol.handle = { request,_ in
            if request.url!.path == "/vault/canvas/capabilities" { return (200,try bytes(capability)) }
            throw URLError(.timedOut)
        }
        await client.synchronizeDocumentToVault(relay)
        let requestCount = DocumentProductProtocol.paths.count
        check(client.documentSyncHeld && !client.canTransitionDocument,"lost ACK persists typed held barrier")
        await client.synchronizeDocumentToVault(relay); await client.refreshDocumentFromVault(relay)
        check(DocumentProductProtocol.paths.count == requestCount,"held state blocks automatic retries and SHA-based checkpoint")
        try reopen("--held-reopen")
        active = try bundle(client.document)
        DocumentProductProtocol.handle = { _,_ in (200,active.bundle) }
        await client.confirmDocumentAcknowledgement(relay)
        check(!client.documentSyncHeld && client.documentSync?.phase == .synchronized,"explicit complete ACK readback closes only identical original and all assets")
        // 실제 typed 409와 명시 비교·선택·전체 재열기 제품 경로.
        client.scene.nodes[0].text = "새 충돌 제안"; client.scene.revision += 1
        await client.saveDocumentWorkspace()
        let proposalDoc = client.document, proposalBundle = try bundle(proposalDoc)
        var displacedDoc = proposalDoc, displacedPage = displacedDoc.activePage
        displacedPage.nodes[0].text = "보존된 외부 전체 문서"; displacedPage.revision += 1
        try displacedDoc.replacePage(displacedPage,expectedRevision:displacedDoc.revision)
        let displacedBundle = try bundle(displacedDoc), recoveryID = "own-recovery:/선택 1"
        func material(_ document: CanvasDocument,_ bundle: (summary:[String:Any],bundle:Data)) throws -> [String:Any] {
            let markdown = Data(("own whole-document fixture " + CanvasPacket.sha(try document.bytes())).utf8)
            return ["sha256":bundle.summary["noteSha256"]!,"markdownBase64":markdown.base64EncodedString(),"validDocument":true,"document":bundle.summary]
        }
        let activeMaterial = try material(proposalDoc,proposalBundle), externalMaterial = try material(displacedDoc,displacedBundle)
        let conflict: [String:Any] = ["schema":"ccr.document-conflict/v1","id":proposalDoc.id.uuidString.lowercased(),"recoveryID":recoveryID,"code":"note_reconciliation_required","reconciliationRequired":true,"publicationAttempted":true,
            "expected":["activeSha256":activeMaterial["sha256"]!,"baseSha256":activeMaterial["sha256"]!,"displacedSha256":externalMaterial["sha256"]!,"proposalSha256":activeMaterial["sha256"]!,"historySha256":CanvasPacket.sha(Data("own-history".utf8)),"bundlesSha256":CanvasPacket.sha(Data("own-bundles".utf8))],
            "materials":["active":activeMaterial,"base":activeMaterial,"displaced":externalMaterial,"proposal":activeMaterial],"history":[]]
        let error = try bytes(["error":"own preserved external conflict","code":"note_reconciliation_required","reconciliationRequired":true,"publicationAttempted":true,"recoveryID":recoveryID])
        DocumentProductProtocol.handle = { request,_ in
            if request.url!.path == "/vault/canvas/capabilities" { return (200,try bytes(capability)) }
            return (409,error)
        }
        await client.synchronizeDocumentToVault(relay)
        check(client.documentSyncHeld,"structured preserved-external 409 retains durable held")
        client.mode = .select; client.selectedNode = client.scene.nodes[0].id
        check(!client.rotateNode(client.scene.nodes[0],sceneID:client.scene.id,to:35) && client.document == proposalDoc,"held document refuses direct graph commit before history or cache changes")
        await client.confirmDocumentAcknowledgement(relay)
        check(client.documentSyncHeld && client.document == proposalDoc,"same active proposal SHA cannot bypass typed reconciliation barrier")
        DocumentProductProtocol.handle = { request,data in
            let path = request.url!.path
            if path == "/vault/canvas/capabilities" { return (200,try bytes(capability)) }
            if path == "/vault/document/conflict" {
                if request.httpMethod == "PUT" {
                    let put = try object(data)
                    check(put["recoveryID"] as? String == recoveryID && (put["expected"] as? [String:Any])?.count == 6 && put["decision"] as? String == "useDisplaced","resolve sends opaque ID exact six expectations and explicit choice")
                    var resolved = displacedBundle.summary
                    resolved["recoveryID"] = recoveryID; resolved["decision"] = "useDisplaced"; resolved["resolved"] = true; resolved["reconciliationRequired"] = false
                    return (200,try bytes(resolved))
                }
                let name = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "material" }?.value
                if let name { return (200,name == "displaced" ? displacedBundle.bundle : proposalBundle.bundle) }
                return (200,try bytes(conflict))
            }
            return (200,displacedBundle.bundle)
        }
        await client.readDocumentConflict(relay)
        check(client.documentConflict?.recoveryID == recoveryID && client.documentCandidates.count == 4 && client.document == proposalDoc,"explicit compare reads four whole candidates without changing original")
        let beforeGuardedResolve = DocumentProductProtocol.paths.count
        client.vaultInputBusy = true
        await client.resolveDocumentConflict(.useDisplaced,relay:relay)
        check(client.documentSyncHeld && DocumentProductProtocol.paths.count == beforeGuardedResolve,"open IME input prevents explicit resolve publication")
        client.vaultInputBusy = false
        await client.resolveDocumentConflict(.useDisplaced,relay:relay)
        check(client.document == displacedDoc && !client.documentSyncHeld && !client.documentBusy,"explicit choice installs complete candidate only after server and Files reopen")
        check(try CanvasDocumentFiles(folder:httpFolder,requiresScope:false).load(displacedDoc.id).document == displacedDoc,"resolved entire Files canonical readback retains all selected candidate pages")
        let result: [String:Any] = ["assertions":assertions,"count":assertions.count,"actualStore":true,"actualPKDrawing":true,"nativeFiles":true,"newProcess":true,"URLSessionProtocolFixture":true,"socketHTTP":false,"PencilRecognition":false,"GUI":false,"installed":false,"wholeProductAccepted":false]
        try bytes(result).write(to:out.appendingPathComponent("store-observations.json"))
        print("STORE_ASSERTIONS \(assertions.count)")
    }
    static func clientDocumentBytesPlaceholder(_ data: Data) throws -> String? { try object(data)["documentJSONBase64"] as? String }
}
