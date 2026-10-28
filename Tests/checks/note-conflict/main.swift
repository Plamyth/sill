import Foundation
import PDFKit

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
        if CommandLine.arguments.contains("--bom-only") {
            NoteConflictProtocol.active="\u{feff}현재 e\u{301}\r\n"
            NoteConflictProtocol.displaced="\u{feff}외부 e\u{301}\r\n"
            for decision in CanvasRelay.ConflictDecision.allCases {
                let expected=Data((decision == .keepCurrent ? NoteConflictProtocol.active:NoteConflictProtocol.displaced).utf8)
                let conflict=try await relay.vaultNoteConflict(path:path)
                check(conflict.selected(decision)?.markdown.map { Data($0.utf8) } == expected,"BOM CRLF NFD material preserves exact bytes for "+decision.rawValue)
                let reopened=try await relay.resolveVaultNoteConflict(conflict,decision:decision)
                check(Data(reopened.text.utf8)==expected,"BOM CRLF NFD PUT and GET readback succeeds for "+decision.rawValue)
                let store=CanvasStore();store.saveNow();store.setNoteConnection(address:relay.address,token:relay.token)
                await store.openVaultNote(path) {_ in note(NoteConflictProtocol.base)}
                store.vaultDraft="\u{feff}보존 초안 e\u{301}\r\n"
                let original=Data(store.vaultDraft.utf8)
                await store.saveVaultNote {_,_,_ in throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:VaultSaveConflict.reconciliationRequired.rawValue])}
                let harness=NoteWorkspaceHarness(store,relay);await harness.read();await harness.resolve(decision)
                check(!store.noteReconciliationHeld && !store.vaultBlocked && Data(store.vaultDraft.utf8)==expected,"actual Workspace and Store apply retains BOM source for "+decision.rawValue)
                check(harness.noteConflictArchive.map { Data($0.draft.utf8) }==original,"archived local input retains original BOM bytes for "+decision.rawValue)
            }
            for bytes in [Data([0xff]),Data([0xef,0xbb,0xbf,0xc3,0x28])] {
                let bad=CanvasRelay.NoteConflictMaterial(sha256:CanvasPacket.sha(bytes),markdownBase64:bytes.base64EncodedString(),validNote:true,refusal:nil)
                check(bad.markdown==nil,"invalid UTF8 never replacement-decodes into valid note")
                do {try bad.validated(expected:bad.sha256);preconditionFailure("invalid UTF8 accepted")}
                catch {check(true,"invalid UTF8 is explicitly refused by material validation")}
            }
            print("NOTE_BOM_OK",count,"actual isolated Relay/Store/Workspace actions; URLProtocol fixture; no live HTTP")
            session.invalidateAndCancel();return
        }
        if CommandLine.arguments.contains("--reconciliation-only") {
            let store=CanvasStore();store.saveNow();store.setNoteConnection(address:relay.address,token:relay.token)
            await store.openVaultNote(path) {_ in note(NoteConflictProtocol.base)}
            let first=NoteWorkspaceHarness(store,relay);await first.read()
            NoteConflictProtocol.mode="stale";await first.resolve(.keepCurrent)
            check(store.noteReconciliationHeld && store.noteConflictChoice?.phase == .refreshRequired,"server rejection creates durable unresolved barrier")
            let fresh=CanvasStore();fresh.setNoteConnection(address:relay.address,token:relay.token)
            let ui=NoteWorkspaceHarness(fresh,relay)
            check(fresh.noteReconciliationHeld && !fresh.canApplyReconciledCanvas,"restart without active draft still blocks Canvas apply")
            NoteConflictProtocol.mode="normal";let puts=NoteConflictProtocol.putBodies.count
            await ui.read(refresh:true)
            check(ui.noteConflict != nil && fresh.noteConflictChoice?.phase == .refreshRequired && fresh.noteReconciliationHeld && !fresh.canApplyReconciledCanvas && NoteConflictProtocol.putBodies.count==puts && !NoteConflictProtocol.resolved,"fresh GET keeps durable barrier and never counts as explicit selection")
            let again=CanvasStore();again.setNoteConnection(address:relay.address,token:relay.token)
            check(again.noteReconciliationHeld && !again.canApplyReconciledCanvas,"restart after refresh retains unresolved barrier")
            var imported=fresh.scene;imported.revision += 100
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let bytes=try encoder.encode(fresh.scene)
            let preserve=try CanvasRuntime.conflictRecoveryURL("CanvasConflictLocal-\(UUID().uuidString.lowercased()).json");try CanvasLocalFile.write(bytes,to:preserve)
            do {try fresh.applyReconciledCanvas(imported,expectedLocalSHA:CanvasPacket.sha(bytes),preservedAt:preserve);preconditionFailure("refresh permitted Canvas apply")}
            catch {check(fresh.scene.revision != imported.revision,"actual Canvas apply refuses refresh-only authority")}
            await ui.resolve(.useDisplaced)
            check(!fresh.noteReconciliationHeld && !fresh.vaultBlocked && fresh.canApplyReconciledCanvas,"new explicit selection completes and releases barrier normally")
            fresh.addNode(.note);let node=fresh.selectedNode!
            let base=note(NoteConflictProtocol.base)
            fresh.scene.nodes[fresh.scene.nodes.count-1].vaultNote=VaultNoteReference(path:path,sha256:base.sha256,relayAddress:relay.address,blockID:"pdfx");fresh.saveNow()
            await fresh.openVaultNote(path,nodeID:node) {_ in base};precondition(fresh.beginLinkedBlockEdit())
            let nfd="새 입력 e\u{301} 👩🏽‍💻",nfc=nfd.precomposedStringWithCanonicalMapping
            fresh.vaultBlockDraft=nfd
            await fresh.saveLinkedBlock(replace:{_,_,_ in throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:VaultSaveConflict.reconciliationRequired.rawValue])},load:{_ in base})
            let captured=try fresh.captureNoteConflictLocal(path:path)
            var raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(captured)) as! [String:Any];raw["blockDraft"]=nfc
            let equivalent=try JSONDecoder().decode(NoteConflictLocalState.self,from:JSONSerialization.data(withJSONObject:raw))
            check(nfd==nfc && captured != equivalent,"recovery snapshot equality preserves byte-distinct canonical Unicode even with equal generations")
            let blockUI=NoteWorkspaceHarness(fresh,relay);await blockUI.read()
            var durable=false
            NoteConflictProtocol.hook={ endpoint,method in
                guard endpoint=="/vault/note/conflict",method=="PUT" else{return};NoteConflictProtocol.hook=nil
                fresh.vaultBlockDraft=nfc;durable=fresh.blockRecovery?.draft.utf8.elementsEqual(nfc.utf8)==true
            }
            await blockUI.resolve(.keepCurrent)
            check(durable,"new NFC block input is durable during pending PUT")
            check(fresh.noteReconciliationHeld && fresh.noteConflictChoice?.phase == .pending && fresh.vaultBlockDraft.utf8.elementsEqual(nfc.utf8) && fresh.blockRecovery?.draft.utf8.elementsEqual(nfc.utf8)==true,"late NFC input blocks installation and survives active draft and recovery")
            let archiveURL=try CanvasRuntime.conflictRecoveryURL(fresh.noteConflictChoice!.backupFilename)
            let archived=try JSONDecoder().decode(NoteConflictLocalState.self,from:CanvasLocalFile.read(archiveURL))
            check(archived.blockRecovery?.draft.utf8.elementsEqual(nfd.utf8)==true,"original NFD proposal archive remains unchanged")
            let after=CanvasStore();after.setNoteConnection(address:relay.address,token:relay.token)
            check(after.noteReconciliationHeld && after.blockRecovery?.draft.utf8.elementsEqual(nfc.utf8)==true,"restart preserves late NFC block input and held barrier")
            let refreshed=try fresh.captureNoteConflictLocal(path:path)
            fresh.vaultBlockDraft=nfd;fresh.vaultBlockDraft=nfc
            check(try fresh.captureNoteConflictLocal(path:path) != refreshed,"block input generation catches change-and-return ABA")
            await blockUI.read(refresh:true);await blockUI.resolve(.keepCurrent)
            check(!fresh.noteReconciliationHeld && blockUI.noteConflictArchive?.blockRecovery?.draft.utf8.elementsEqual(nfc.utf8)==true,"fresh explicit selection completes while preserving newer NFC input")
            print("NOTE_RECONCILIATION_OK",count,"actual isolated Model Store file IO and extracted Workspace; URLProtocol fixture")
            session.invalidateAndCancel();return
        }
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
        let completion=store.noteConflictChoice!
        var localPending=completion;localPending.phase = .serverResolved
        let completionURL=try CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json")
        try CanvasLocalFile.write(JSONEncoder().encode(localPending),to:completionURL)
        check(store.noteReconciliationHeld && !store.vaultDirty && !store.canApplyReconciledCanvas,"unfinished note recovery blocks unrelated Canvas reconciliation even after local draft records are cleared")
        try CanvasLocalFile.write(JSONEncoder().encode(completion),to:completionURL)
        check(store.canApplyReconciledCanvas,"completed note recovery does not permanently block Canvas reconciliation")
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
        let validDraft=pdf.vaultDraft
        pdf.vaultDraft=String(repeating:"a",count:1024*1024+1)
        check(!pdf.canCompareNoteConflict,"oversized or unpreserved local input cannot create an unbounded recovery archive")
        pdf.vaultDraft=validDraft
        check(pdf.canCompareNoteConflict,"returning to bounded input restores recovery comparison eligibility")
        _ = pdf.closeVaultEditor(discard:true)
        let nativePDFBytes = try Data(contentsOf:URL(fileURLWithPath:ProcessInfo.processInfo.environment["PDF_RECOVERY_FIXTURE"]!))
        let nativePDF = PDFDocument(data:nativePDFBytes)!, nativePage = nativePDF.page(at:0)!
        let source = try VaultPDFExcerpt.capture(snapshot:VaultPDFSnapshot(path:"원문/Unicode.pdf",sha256:CanvasPacket.sha(nativePDFBytes),dataBase64:nativePDFBytes.base64EncodedString()),
            document:nativePDF,selection:nativePage.selection(for:NSRange(location:0,length:(nativePage.string! as NSString).length))!)
        let cardText = try source.markdown(), cardBase = try VaultPDFCard.parse(cardText)!
        let externalTitle = "외부 제목 e\u{301}", externalMemo = "외부 메모 e\u{301} 👩🏽‍💻"
        let titled = try cardBase.replacing(.title,with:externalTitle)
        let externalCard = try VaultPDFCard.parse(titled)!.replacing(.memo,with:externalMemo)
        let externalBytes = "\u{feff}" + externalCard.replacingOccurrences(of:"\n",with:"\r\n")
        NoteConflictProtocol.path=source.notePath;NoteConflictProtocol.id=UUID().uuidString.lowercased()
        NoteConflictProtocol.base=cardText;NoteConflictProtocol.active=cardText;NoteConflictProtocol.displaced=externalBytes
        NoteConflictProtocol.mode="normal";NoteConflictProtocol.resolved=false
        let cardStore=CanvasStore();cardStore.setNoteConnection(address:relay.address,token:relay.token)
        await cardStore.openVaultNote(source.notePath) {_ in note(cardText)}
        let cardID=cardStore.attachOpenedVaultNote()!, oldSession=cardStore.vaultPDFEditSession!
        check(cardStore.editVaultPDF(.memo,text:"내 미저장 메모",session:oldSession),"actual PDF field uses the shared Markdown draft before conflict")
        await cardStore.saveVaultNote {_,_,_ in throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:VaultSaveConflict.reconciliationRequired.rawValue])}
        let cardUI=NoteWorkspaceHarness(cardStore,relay);await cardUI.read();await cardUI.resolve(.useDisplaced)
        let restoredCard=try VaultPDFCard.parse(cardStore.vaultDraft)!
        check(!cardStore.noteReconciliationHeld && !cardStore.vaultBlocked && cardStore.vaultDraft.utf8.elementsEqual(externalBytes.utf8),
            "PDF explicit note recovery installs exact external BOM/CRLF bytes before enabling normal writes")
        check(restoredCard.title==externalTitle && restoredCard.memo==externalMemo && restoredCard.sourceSHA256==cardBase.sourceSHA256,
            "recovered title and memo are separate from unchanged native PDF quote SHA and textRanges")
        check(cardStore.scene.nodes.contains {$0.id==cardID && $0.vaultNote?.path==source.notePath && $0.text.contains(externalTitle)},
            "external PDF memo recovery refreshes the same existing card identity")
        check(!cardStore.editVaultPDF(.memo,text:"늦은 이전 입력",session:oldSession),"pre-recovery PDF field session cannot overwrite recovered memo")
        let recoveredSession=cardStore.vaultPDFEditSession!
        check(cardStore.editVaultPDF(.memo,text:"복구 뒤 메모",session:recoveredSession),"explicit recovery returns PDF fields to ordinary Markdown editing")
        var cardSaved=note(externalBytes)
        await cardStore.saveVaultNote(save:{_,base,text in
            precondition(base==CanvasPacket.sha(Data(externalBytes.utf8)))
            cardSaved=note(text);return cardSaved
        },load:{_ in cardSaved})
        let finalCard=try VaultPDFCard.parse(cardSaved.text)!
        check(!cardStore.vaultDirty && finalCard.memo=="복구 뒤 메모" && finalCard.title==externalTitle && finalCard.sourceSHA256==cardBase.sourceSHA256,
            "post-recovery PDF memo CAS/readback preserves title and immutable source")
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
