import Foundation

@main struct EPUBContractBoundaries {
    static var checks: [String] = []
    static func check(_ value: Bool, _ name: String) { precondition(value,name); checks.append(name); print("PASS",name) }
    static func object<T:Encodable>(_ value:T) throws -> [String:Any] { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any] }
    static func bytes(_ object:[String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]) }
    static func envelope(_ object:[String:Any]) throws -> Data {
        let payload = try bytes(object)
        return try bytes(["schema":"ccr.pdf-create-recovery/v1","payload":payload.base64EncodedString(),"sha256":CanvasPacket.sha(payload)])
    }
    static func reject(_ body:() throws -> Void,_ name:String) {
        do { try body(); fatalError(name) } catch { checks.append(name); print("PASS",name) }
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated only") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        let recoveryURL = try CanvasRuntime.stateURL(.pdfExcerptRecovery)
        let choiceURL = try CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json")
        func store() -> CanvasStore {
            let value = CanvasStore(); value.enableDocumentChecks()
            value.setNoteConnection(address:context.relayAddress,token:context.token); return value
        }
        if CommandLine.arguments.contains("--bad-reopen") {
            let before = try CanvasLocalFile.read(recoveryURL), s = store()
            check(!s.pdfExcerptRecoveryNotice.isEmpty && s.pdfExcerptRecovery == nil && !s.canTransitionDocument,"fresh process refuses unsupported kind and retains transition barrier")
            check(try CanvasLocalFile.read(recoveryURL) == before,"fresh process leaves unsupported raw recovery bytes intact")
            return
        }
        let source = VaultEPUBExcerpt(schemaVersion:1,excerptID:UUID(),sourceID:"epub-" + CanvasPacket.sha(Data("own.epub".utf8)),sourcePath:"own.epub",sourceSHA256:String(repeating:"a",count:64),spineItem:"one",chapterPath:"one.xhtml",xpath:"/html[1]/body[1]/p[1]",range:.init(location:0,length:2),quote:"원문")
        let markdown = try source.markdown(), id = UUID()
        let record = VaultPDFCreateRecovery(sceneID:id,relayAddress:context.relayAddress,path:source.notePath,draft:markdown,submittedText:nil,sourceKind:.epub)
        let valid = try JSONEncoder().encode(VaultPDFCreateRecoveryFile(record))
        try CanvasLocalFile.write(valid,to:recoveryURL)
        check(store().hasPendingEPUBExcerpt,"explicit EPUB envelope reopens in original recovery file")
        let pdf = VaultPDFExcerpt(schemaVersion:1,excerptID:UUID(),pdfPath:"own.pdf",pdfSha256:String(repeating:"b",count:64),pageIndex:0,mediaBox:.init(CGRect(x:0,y:0,width:100,height:100)),cropBox:.init(CGRect(x:0,y:0,width:100,height:100)),rotation:0,selectionRects:[.init(CGRect(x:1,y:1,width:20,height:10))],quote:"원문")
        let legacy = VaultPDFCreateRecovery(sceneID:id,relayAddress:context.relayAddress,path:pdf.notePath,draft:try pdf.markdown(),submittedText:nil)
        let legacyObject = try object(legacy)
        check(legacyObject["sourceKind"] == nil,"legacy PDF encoding omits optional sourceKind")
        try CanvasLocalFile.write(try JSONEncoder().encode(VaultPDFCreateRecoveryFile(legacy)),to:recoveryURL)
        let oldStore = store()
        check(oldStore.pdfExcerptRecovery == legacy && !oldStore.hasPendingEPUBExcerpt,"nil kind remains strictly legacy PDF with same envelope")
        let state = VaultPDFViewState(snapshot:.init(path:"own.pdf",sha256:String(repeating:"b",count:64),dataBase64:""),pageCount:1)
        let view = VaultPDFViewRecovery(id:UUID(),base:nil,draft:try .init(state:state,base:nil),submitted:nil)
        try view.validate()
        let epub = try object(record)
        var unknown = epub; unknown["sourceKind"] = "future"
        var missing = epub; missing.removeValue(forKey:"sourceKind")
        var mixed = epub; mixed["viewRecovery"] = try object(view)
        var wrongSource = legacyObject; wrongSource["sourceKind"] = "epub"
        for (name,payload) in [("unknown kind",unknown),("EPUB without explicit kind",missing),("EPUB plus valid PDF viewRecovery",mixed),("PDF draft tagged EPUB",wrongSource)] {
            let raw = try envelope(payload)
            reject({ _ = try JSONDecoder().decode(VaultPDFCreateRecoveryFile.self,from:raw).record() },name + " rejects decode/validation")
            try CanvasLocalFile.write(raw,to:recoveryURL)
            let s = store()
            check(s.pdfExcerptRecovery == nil && !s.pdfExcerptRecoveryNotice.isEmpty && !s.canTransitionDocument,name + " reopens with explicit notice and durable barrier")
            check(!s.prepareEPUBExcerpt(source),name + " cannot replace existing unrecognized recovery")
            var loadCalls = 0
            let opened = await s.openEPUB("own.epub",load:{ _ in loadCalls += 1; throw URLError(.badServerResponse) })
            check(try !opened && loadCalls == 0 && (try CanvasLocalFile.read(recoveryURL)) == raw,name + " keeps exact bytes and refuses source load")
        }
        // One genuine separate process confirms unsupported kind never becomes a default PDF.
        let unknownRaw = try envelope(unknown)
        try CanvasLocalFile.write(unknownRaw,to:recoveryURL)
        let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments = [out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--bad-reopen"]
        try child.run(); child.waitUntilExit()
        check(try child.terminationStatus == 0 && (try CanvasLocalFile.read(recoveryURL)) == unknownRaw,"separate process retains unsupported kind without rewriting")
        try CanvasLocalFile.write(valid,to:recoveryURL)
        // Reuse a real prior Store/Obsidian conflict choice instead of guessing DTO fields.
        let priorBytes = try Data(contentsOf:out.appendingPathComponent("prior-choice.json"))
        let prior = try JSONDecoder().decode(VaultPDFViewChoice.self,from:priorBytes).validated()
        check(prior.schema == VaultPDFViewChoice.epubSchema,"actual earlier EPUB server-choice fixture validates")
        var priorObject = try object(prior)
        for schema in [VaultPDFViewChoice.schemaName,"ccr.epub-excerpt-note-choice/v2",VaultPDFViewLocalChoice.epubSchema] {
            priorObject["schema"] = schema; let raw = try bytes(priorObject)
            reject({ _ = try JSONDecoder().decode(VaultPDFViewChoice.self,from:raw).validated() },schema + " refuses wrong server-choice schema")
            try CanvasLocalFile.write(raw,to:choiceURL)
            let s = store()
            check(try s.noteReconciliationHeld && !s.canTransitionDocument && (try CanvasLocalFile.read(choiceURL)) == raw,schema + " remains a preserved unknown-choice barrier")
        }
        let current = VaultNoteSnapshot(path:record.path,text:record.draft,sha256:CanvasPacket.sha(Data(record.draft.utf8)),modifiedAt:"")
        let local = VaultPDFViewLocalChoice(schema:VaultPDFViewLocalChoice.epubSchema,original:record,current:current,phase:.compared)
        _ = try local.validated()
        check(true,"explicit EPUB current-choice schema validates")
        var localObject = try object(local)
        for schema in [VaultPDFViewLocalChoice.schemaName,"ccr.epub-excerpt-current-choice/v2",VaultPDFViewChoice.epubSchema] {
            localObject["schema"] = schema; let raw = try bytes(localObject)
            reject({ _ = try JSONDecoder().decode(VaultPDFViewLocalChoice.self,from:raw).validated() },schema + " refuses wrong current-choice schema")
            try CanvasLocalFile.write(raw,to:choiceURL)
            check(try store().noteReconciliationHeld && (try CanvasLocalFile.read(choiceURL)) == raw,schema + " preserves current-choice bytes")
        }
        let result:[String:Any] = ["count":checks.count,"checks":checks,"whole54Repeated":false,"separateProcesses":1,"separateProcessObservations":2,"productModified":false,"actualHTTP":false,"GUI":false,"wholeEPUBAccepted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
    }
}
