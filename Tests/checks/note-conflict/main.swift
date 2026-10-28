import Foundation

final class NoteConflictProtocol: URLProtocol {
    static var path="Notes/plan.md",id=UUID().uuidString.lowercased(),mode="normal"
    static var base="기준 e\u{301} 👩🏽‍💻\r\n\r\nPDF 발췌 원문 ^pdfx\r\n", active="제안본\r\n",displaced="외부 보존본\r\n"
    static var putBodies:[[String:Any]]=[],resolved=false,selected=""
    static var hook:(@MainActor (String,String)->Void)?
    static func material(_ text:String)->[String:Any] {
        let data=Data(text.utf8);return ["sha256":CanvasPacket.sha(data),"markdownBase64":data.base64EncodedString(),"validNote":true]
    }
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let method=request.httpMethod ?? "GET",endpoint=request.url!.path
        let items=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
        precondition(items.count==1 && items[0].name=="path" && items[0].value==Self.path)
        precondition(request.value(forHTTPHeaderField:"X-Canvas-Token")=="own-fixture-token-012345678901")
        var value:[String:Any],status=200,lost=false
        if endpoint=="/vault/note/conflict" && method=="PUT" {
            var data=request.httpBody ?? Data()
            if let stream=request.httpBodyStream {stream.open();defer {stream.close()};var b=[UInt8](repeating:0,count:4096);while true {let n=stream.read(&b,maxLength:b.count);if n<=0 {break};data.append(contentsOf:b.prefix(n))}}
            let body=try! JSONSerialization.jsonObject(with:data) as! [String:Any];Self.putBodies.append(body)
            precondition(body["recoveryID"] as? String==Self.id)
            precondition(Set(body.keys)==Set(["recoveryID","expected","decision"]))
            if Self.mode=="stale" {status=409;value=["error":"kept /private/fixture","code":"note_reconciliation_required","reconciliationRequired":true,"recoveryID":UUID().uuidString.lowercased()]}
            else {
                Self.selected=body["decision"] as? String=="keepCurrent" ? Self.active:Self.displaced;Self.resolved=true
                value=["path":Self.path,"sha256":CanvasPacket.sha(Data(Self.selected.utf8)),"recoveryID":Self.id,"decision":body["decision"]!,"resolved":true,"reconciliationRequired":false]
                if Self.mode=="lost" {lost=true;Self.mode="normal"}
                if Self.mode=="bad-result" {value["sha256"]=String(repeating:"0",count:64)}
            }
        } else if endpoint=="/vault/note/conflict" {
            value=["schema":"ccr.note-conflict/v1","path":Self.path,"recoveryID":Self.id,"code":"note_reconciliation_required","reconciliationRequired":true,"publicationAttempted":true,
                "expected":["activeSha256":materialHash(Self.active),"baseSha256":materialHash(Self.base),"displacedSha256":materialHash(Self.displaced),"proposalSha256":materialHash(Self.active),"historySha256":CanvasPacket.sha(Data("[]".utf8))],
                "materials":["active":Self.material(Self.active),"base":Self.material(Self.base),"displaced":Self.material(Self.displaced),"proposal":Self.material(Self.active)],"history":[]]
            if Self.mode=="null-active" {
                var e=value["expected"] as! [String:Any],m=value["materials"] as! [String:Any]
                e["activeSha256"]=NSNull();m["active"]=NSNull();value["expected"]=e;value["materials"]=m
            }
            if Self.mode=="not-found" {status=404;value=["error":"not supported or not found"]}
            if Self.mode=="bad-material" {var m=value["materials"] as! [String:Any];var a=Self.material(Self.active);a["sha256"]=String(repeating:"0",count:64);m["active"]=a;value["materials"]=m}
        } else {
            let text=Self.mode=="bad-readback" ? "changed":Self.selected
            value=["path":Self.path,"sha256":materialHash(text),"text":text,"modifiedAt":"fixture"]
        }
        let bytes=try! JSONSerialization.data(withJSONObject:value),replyStatus=status,isLost=lost
        Task { @MainActor in
            Self.hook?(endpoint,method)
            if isLost {client!.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return}
            client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:replyStatus,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client!.urlProtocol(self,didLoad:bytes);client!.urlProtocolDidFinishLoading(self)
        }
    }
    private func materialHash(_ text:String)->String {CanvasPacket.sha(Data(text.utf8))}
    override func stopLoading() {}
}
@main struct NoteConflictChecks {
    @MainActor static func main()async throws {
        setbuf(stdout,nil)
        guard case .isolated = CanvasRuntime.launch else {preconditionFailure("actual isolated process required")}
        var count=0
        func check(_ v:Bool,_ s:String) {precondition(v,s);count+=1;print("PASS",s)}
        let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[NoteConflictProtocol.self]
        let session=URLSession(configuration:c),relay=CanvasRelay(address:"http://192.168.88.88:4242",token:"own-fixture-token-012345678901",session:session)
        func note(_ text:String)->VaultNoteSnapshot {.init(path:NoteConflictProtocol.path,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"fixture")}
        let path=NoteConflictProtocol.path
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        let state=try CanvasRuntime.stateURL(.checkpoint).deletingLastPathComponent()
        for name in ["NoteConflictChoice.json","NoteConflictLocal-33333333-3333-4333-8333-333333333333.json","NoteConflictAttempt-44444444-4444-4444-8444-444444444444.json"] {
            for base in [support,support.appendingPathComponent("CCRIntegrationTests/55555555-5555-4555-8555-555555555555/state/CanvasConflictRecovery"),state] {
                do {try CanvasLocalFile.write(Data([1]),to:base.appendingPathComponent(name));preconditionFailure("root escape")}
                catch {check(true,"new note recovery names cannot write outside exact current context directory")}
            }
        }
        for decision in CanvasRelay.ConflictDecision.allCases {
            let snapshot=try await relay.vaultNoteConflict(path:path)
            let saved=try await relay.resolveVaultNoteConflict(snapshot,decision:decision)
            check(saved.text==snapshot.selected(decision)?.markdown,"exact note DTO "+decision.rawValue+" reopens original bytes")
            check((NoteConflictProtocol.putBodies.last!["expected"] as! [String:Any]).count==5,"echo all expected hashes")
        }
        NoteConflictProtocol.mode="null-active"
        let absent=try await relay.vaultNoteConflict(path:path)
        check(absent.materials.active==nil && absent.expected.activeSha256==nil,"explicit null active note and hash decode without invented source")
        let journalRoundtrip=try JSONDecoder().decode(CanvasRelay.NoteConflict.self,from:JSONEncoder().encode(absent)).validated(path:path)
        check(journalRoundtrip.materials.active==nil,"local pending snapshot preserves explicit material null")
        do {_=try await relay.resolveVaultNoteConflict(absent,decision:.keepCurrent);preconditionFailure("null candidate")}
        catch {check(true,"absent current source cannot be selected")}
        NoteConflictProtocol.mode="normal"
        for bad in ["CCR Canvas/test.md","ccr canvas/test.md","../private.md","/absolute.md","Notes/.hidden.md"] {
            let before=NoteConflictProtocol.putBodies.count
            do {_=try await relay.vaultNoteConflict(path:bad);preconditionFailure("unsafe path")}
            catch {check(NoteConflictProtocol.putBodies.count==before,"unsafe/Canvas note conflict path sends no write")}
        }
        for mode in ["stale","bad-result","bad-readback","bad-material"] {
            NoteConflictProtocol.mode=mode
            do {let s=try await relay.vaultNoteConflict(path:path);_=try await relay.resolveVaultNoteConflict(s,decision:.keepCurrent);preconditionFailure(mode)}
            catch {check(true,"reject "+mode+" without generic save fallback")}
        }
        NoteConflictProtocol.mode="normal"
        let store=CanvasStore();store.saveNow();store.setNoteConnection(address:"http://192.168.88.88:4242",token:"own-fixture-token-012345678901")
        let base=note(NoteConflictProtocol.base)
        await store.openVaultNote(path) {_ in base};store.vaultDraft="사용자 미저장 e\u{301} 👩🏽‍💻\r\n"
        await store.saveVaultNote {_,_,_ in throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:VaultSaveConflict.reconciliationRequired.rawValue])}
        let draft=store.vaultDraft,originalRecovery=store.noteRecovery
        let harness=NoteWorkspaceHarness(store,relay)
        await harness.read()
        check(harness.noteConflict != nil && store.vaultDraft==draft,"actual UI read keeps original draft and opens four source materials")
        NoteConflictProtocol.mode="lost"
        await harness.resolve(.useDisplaced)
        check(store.noteReconciliationHeld && store.noteRecovery==originalRecovery && store.vaultDraft==draft,"lost resolve response retains draft/base/submission and durable held marker")
        let restart=CanvasStore();restart.setNoteConnection(address:"http://192.168.88.88:4242",token:"own-fixture-token-012345678901")
        check(restart.noteReconciliationHeld && restart.noteRecovery==originalRecovery,"new native Store retains unresolved note reconciliation")
        await harness.resolve(.useDisplaced)
        check(!store.noteReconciliationHeld && !store.vaultBlocked && store.vaultDraft==NoteConflictProtocol.displaced,"explicit same request finishes only after server note readback and local completion")
        check(harness.noteConflictArchive?.noteRecovery==originalRecovery,"archived original draft and submitted bytes remain readable")
        let archive=try CanvasRuntime.conflictRecoveryURL(store.noteConflictChoice!.backupFilename)
        let savedArchive=try CanvasLocalFile.read(archive)
        let record=try JSONDecoder().decode(NoteConflictLocalState.self,from:savedArchive)
        check(record.noteRecovery?.draft==draft,"native archive includes exact original draft")
        try store.resumeArchivedNoteDraft(record)
        check(store.vaultDraft==draft && store.vaultDirty && store.vaultCanSave,"draft resumes as unsaved text on selected source, never automatically PUT")
        let archiveAfter=try CanvasLocalFile.read(archive)
        check(archiveAfter==savedArchive,"resuming draft never consumes original archive")
        await harness.read(refresh:true);NoteConflictProtocol.mode="lost"
        await harness.resolve(.keepCurrent)
        let beforeNormalization=store.vaultDraft
        store.vaultDraft=beforeNormalization.precomposedStringWithCanonicalMapping
        let canonicalRestart=CanvasStore();canonicalRestart.setNoteConnection(address:"http://192.168.88.88:4242",token:"own-fixture-token-012345678901")
        let canonicalUI=NoteWorkspaceHarness(canonicalRestart,relay);await canonicalUI.read()
        let writesBeforeCanonical=NoteConflictProtocol.putBodies.count
        await canonicalUI.resolve(.keepCurrent)
        check(NoteConflictProtocol.putBodies.count==writesBeforeCanonical && canonicalRestart.noteReconciliationHeld,
              "restarted NFD-to-NFC draft change cannot resubmit a byte-distinct archived choice")
        for mutation in ["draft","scene-ABA","token-ABA","cancel"] {
            await harness.read(refresh:true)
            let beforeDraft=store.vaultDraft
            NoteConflictProtocol.hook={ endpoint,method in
                guard endpoint=="/vault/note/conflict" && method=="PUT" else {return}
                NoteConflictProtocol.hook=nil
                if mutation=="draft" {store.vaultDraft += "늦은 입력"}
                if mutation=="scene-ABA" {store.scene.revision += 1;store.scene.revision -= 1}
                if mutation=="token-ABA" {harness.relayToken="changed";harness.noteConflictGeneration &+= 1;harness.relayToken="own-fixture-token-012345678901";harness.noteConflictGeneration &+= 1}
                if mutation=="cancel" {harness.noteConflictGeneration &+= 1}
            }
            await harness.resolve(.keepCurrent)
            check(store.noteReconciliationHeld && (mutation != "draft" || store.vaultDraft==beforeDraft+"늦은 입력"),"late "+mutation+" after PUT preserves held and current draft")
        }
        NoteConflictProtocol.mode="not-found"
        await harness.read(refresh:true)
        check(store.noteReconciliationHeld && store.vaultDirty,"404 is never authority to clear held or draft")
        NoteConflictProtocol.mode="normal";await harness.read(refresh:true)
        let choiceURL=try CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json")
        let preservedChoice=try CanvasRuntime.conflictRecoveryURL("NoteConflictAttempt-\(UUID().uuidString.lowercased()).json")
        let beforeIO=store.noteRecovery
        NoteConflictProtocol.hook={ endpoint,method in
            guard endpoint=="/vault/note/conflict" && method=="PUT" else {return};NoteConflictProtocol.hook=nil
            try! FileManager.default.moveItem(at:choiceURL,to:preservedChoice)
            try! FileManager.default.createDirectory(at:choiceURL,withIntermediateDirectories:false)
        }
        await harness.resolve(.keepCurrent)
        check(store.noteReconciliationHeld && store.noteRecovery==beforeIO,"actual choice directory IO failure after server success preserves held and source journal")
        try FileManager.default.removeItem(at:choiceURL) // only the empty directory injected into this isolated fixture
        try FileManager.default.moveItem(at:preservedChoice,to:choiceURL)
        await harness.resolve(.keepCurrent)
        check(!store.noteReconciliationHeld,"same explicit choice recovers after native IO is restored")
        // A PDF excerpt is represented by its existing relative Markdown and block anchor; no PDF binary is rewritten.
        _=store.closeVaultEditor(discard:true)
        try CanvasLocalFile.write(JSONEncoder().encode(VaultNoteRecoveryFile(nil)),to:CanvasRuntime.stateURL(.noteRecovery))
        NoteConflictProtocol.path="PDF 발췌/읽기 기록.md";NoteConflictProtocol.id=UUID().uuidString.lowercased()
        NoteConflictProtocol.base="# PDF 발췌\r\n\r\nPDF 발췌 원문 ^pdfx\r\n"
        NoteConflictProtocol.active=NoteConflictProtocol.base+"\r\n제안 메모\r\n"
        NoteConflictProtocol.displaced=NoteConflictProtocol.base+"\r\n외부 독서 메모\r\n"
        let pdfBase=note(NoteConflictProtocol.base),node=UUID()
        let pending=VaultBlockEdit(base:pdfBase,block:try VaultMarkdownBlocks(pdfBase.text).resolve("pdfx"),text:"Pencil 교정 미저장")
        let block=VaultBlockRecovery(schemaVersion:1,sceneID:store.scene.id,nodeID:node,relayAddress:"http://192.168.88.88:4242",blockID:"pdfx",base:pdfBase,draft:"Pencil 교정 미저장",pending:pending,saveConflict:.reconciliationRequired)
        try CanvasLocalFile.write(JSONEncoder().encode(VaultBlockRecoveryFile(block)),to:CanvasRuntime.stateURL(.blockRecovery))
        let pdf=CanvasStore();pdf.setNoteConnection(address:"http://192.168.88.88:4242",token:"own-fixture-token-012345678901")
        let pdfUI=NoteWorkspaceHarness(pdf,relay)
        await pdfUI.read()
        check(pdfUI.noteConflict?.path==NoteConflictProtocol.path,"PDF excerpt relative Markdown opens its own conflict DTO without Canvas route")
        await pdfUI.resolve(.keepCurrent)
        check(!pdf.vaultBlocked && pdf.vaultNote?.text==NoteConflictProtocol.active,"PDF excerpt chosen original reopens normally")
        check(pdfUI.noteConflictArchive?.blockRecovery?.pending?.operationId==pending.operationId,"original PDF block operation ID retained in native archive")
        try pdf.resumeArchivedNoteDraft(pdfUI.noteConflictArchive!)
        check(pdf.vaultDirty && pdf.vaultDraft.contains("Pencil 교정 미저장") && pdf.vaultBlockHasPendingSave==false,"PDF excerpt draft explicitly rebases on current anchor without replaying old block operation")
        let canvasText="---\nccr_scene_id: 123\n---\nmanaged"
        NoteConflictProtocol.active=canvasText
        do {_=try await relay.vaultNoteConflict(path:NoteConflictProtocol.path);preconditionFailure("managed bypass")}
        catch {check(true,"ordinary note candidate rejects managed Canvas frontmatter")}
        let wire=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
        let full=try JSONSerialization.jsonObject(with:wire) as! [String:Any]
        let actual=try JSONDecoder().decode(CanvasRelay.NoteConflict.self,from:JSONSerialization.data(withJSONObject:full["get"]!))
        _=try actual.validated(path:actual.path)
        if actual.path != "ascii" {
            var changed=full["get"] as! [String:Any];changed["path"]=actual.path.precomposedStringWithCanonicalMapping
            do {_=try JSONDecoder().decode(CanvasRelay.NoteConflict.self,from:JSONSerialization.data(withJSONObject:changed)).validated(path:actual.path);preconditionFailure("rewritten path accepted")}
            catch {check(true,"server path normalization is rejected instead of rewriting original path bytes")}
        }
        check(actual.materials.displaced?.validNote==true,"exact f6e7 real file example decodes and passes all raw-byte SHA checks")
        print("NOTE_CONFLICT_OK",count,"real isolated Model Store Relay and Workspace actions; URLProtocol fixture; no live vault/PDF document mutation")
        session.invalidateAndCancel()
    }
}
