import Foundation

final class VaultConflictProtocol: URLProtocol {
    static var puts = 0
    static var mode = "preserved"
    static var remoteText = "제안본\r\ne\u{301} 👩🏽‍💻\r\n"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let failed = request.httpMethod == "PUT"
        if failed { Self.puts += 1 }
        var body: [String:Any] = failed ? ["error":"교환 후 충돌 /private/fixture/recovery", "code":"note_reconciliation_required","reconciliationRequired":true,"publicationAttempted":true,
            "absoluteCAS":false,"automaticRollback":false,"recovery":["path":"/private/fixture/recovery"]] :
            ["path":"Notes/conflict.md","text":Self.remoteText,"sha256":CanvasPacket.sha(Data(Self.remoteText.utf8)),"modifiedAt":"fixture"]
        if failed && Self.mode == "prepublication" { body = ["error":"stale /private/fixture", "reconciliationRequired":false, "publicationAttempted":false] }
        if failed && Self.mode == "legacy" { body = ["error":"note_reconciliation_required in prose /private/fixture", "recovery":["path":"private"]] }
        client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:failed ? 409:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct VaultConflictCheck {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [VaultConflictProtocol.self]
        let session = URLSession(configuration:config), path = "Notes/conflict.md"
        let relay = CanvasRelay(address:"http://fixture.invalid",token:"own-fixture",session:session)
        let base = VaultNoteSnapshot(path:path,text:"기준 원문\r\n",sha256:CanvasPacket.sha(Data("기준 원문\r\n".utf8)),modifiedAt:"fixture")
        var checks = 0
        func check(_ value: Bool,_ message: String) { precondition(value,message);checks += 1;print("PASS",message) }
        do { _ = try await relay.saveVaultNote(at:path,baseSha256:base.sha256,text:VaultConflictProtocol.remoteText);preconditionFailure("409 accepted") }
        catch {
            let failure = error as NSError
            check(failure.domain == "CanvasRelay" && failure.code == 409,"mixed JSON boolean/recovery keeps HTTP409")
            check(failure.localizedDescription.contains("제안본") && failure.localizedDescription.contains("자동 재시도") && !failure.localizedDescription.contains("/private/"),"explicit Korean uncertainty without private recovery path")
        }
        let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let recovery = output.appendingPathComponent("note-recovery.json")
        let store = CanvasStore(noteRecoveryURL:recovery);store.saveNow()
        store.setNoteConnection(address:"http://fixture.invalid",token:"own-fixture")
        await store.openVaultNote(path) { _ in base }
        store.vaultDraft = VaultConflictProtocol.remoteText
        let draft = store.vaultDraft, source = store.scene
        var readbacks = 0
        await store.saveVaultNote(save:{ path,sha,text in try await relay.saveVaultNote(at:path,baseSha256:sha,text:text) },load:{ _ in readbacks += 1;return base })
        check(store.vaultBlocked && store.vaultDirty && store.vaultDraft.utf8.elementsEqual(draft.utf8) && store.scene == source,"409 keeps local dirty draft and scene")
        check(store.noteRecovery?.submittedText == draft && store.noteRecovery?.saveConflict == .reconciliationRequired && readbacks == 0,"recovery preserves submission; no success readback after409")
        let attempts = VaultConflictProtocol.puts
        await store.saveVaultNote { _,_,_ in preconditionFailure("automatic retry must be blocked") }
        check(VaultConflictProtocol.puts == attempts && !store.vaultCanSave,"no retry after409")
        let remote = try await relay.vaultNote(at:path)
        check(remote.text == draft,"active remote note may already equal our proposal")
        store.vaultDraft += "새 입력"
        check(store.noteRecovery?.saveConflict == .reconciliationRequired && store.vaultBlocked,"new typing preserves durable conflict marker")
        let disk = try Data(contentsOf:recovery)
        let fresh = CanvasStore(noteRecoveryURL:recovery);fresh.setNoteConnection(address:"http://fixture.invalid",token:"own-fixture")
        var reconciliationReads = 0
        await fresh.restoreNoteDraft { _ in reconciliationReads += 1;return remote }
        check(fresh.noteRecovery?.draft.utf8.elementsEqual(store.vaultDraft.utf8) == true && fresh.noteRecovery?.saveConflict == .reconciliationRequired && reconciliationReads == 0,"restart cannot silently accept remote proposal or clear dirty recovery")
        let afterRead = try Data(contentsOf:recovery)
        check(afterRead == disk,"read attempt leaves recovery file bytes intact")
        let unknown = CanvasVaultCheckpoint(sceneID:source.id,address:"http://fixture.invalid",sceneSha:"base",noteSha:"old-note",pendingSceneSha:"proposal")
        let restored = try JSONDecoder().decode(CanvasVaultCheckpoint.self,from:JSONEncoder().encode(unknown))
        check(restored.requiresExplicitReconciliation && restored.sceneSha == "base" && restored.pendingSceneSha == "proposal","pending legacy checkpoint blocks automatic matching-SHA success")
        check(restored.acceptingReadMatch(remoteSceneSha:"proposal",remoteNoteSha:"new-note",localSceneSha:"proposal",explicitlyConfirmed:false,remoteReconciliationRequired:false) == nil,"mere read of active proposal never becomes success checkpoint")
        check(restored.acceptingReadMatch(remoteSceneSha:"proposal",remoteNoteSha:"new-note",localSceneSha:"newer local",explicitlyConfirmed:true,remoteReconciliationRequired:false) == nil,"explicit reconcile cannot discard newer local input")
        let accepted = restored.acceptingReadMatch(remoteSceneSha:"proposal",remoteNoteSha:"new-note",localSceneSha:"proposal",explicitlyConfirmed:true,remoteReconciliationRequired:false)
        check(accepted?.sceneSha == "proposal" && accepted?.pendingSceneSha == nil && accepted?.requiresExplicitReconciliation == false,"only explicit verified exact match updates baseline without PUT or rollback")
        check(restored.acceptingReadMatch(remoteSceneSha:"proposal",remoteNoteSha:"new-note",localSceneSha:"proposal",explicitlyConfirmed:true,remoteReconciliationRequired:true) == nil,"explicit SHA match cannot clear unresolved server journal")
        check(restored.acceptingReadMatch(remoteSceneSha:"proposal",remoteNoteSha:"new-note",localSceneSha:"proposal",explicitlyConfirmed:true,remoteReconciliationRequired:nil) == nil,"legacy server without reconciliation metadata cannot release unresolved conflict")
        check(VaultConflictProtocol.puts == attempts,"comparison and explicit baseline operation send zero new writes")
        for (mode,expected) in [("prepublication",VaultSaveConflict.prepublication),("legacy",.unclassified)] {
            VaultConflictProtocol.mode = mode
            do { _ = try await relay.saveVaultNote(at:path,baseSha256:base.sha256,text:draft);preconditionFailure("409 accepted") }
            catch { check(VaultSaveConflict.classified(error) == expected,"structured disposition " + mode + "; no raw prose/path classification") }
        }
        VaultConflictProtocol.mode = "preserved"
        let failedMarkerURL = output.appendingPathComponent("failed-marker.json")
        let guarded = CanvasStore(noteRecoveryURL:failedMarkerURL,noteRecoveryWrite:{ bytes,url in
            if try JSONDecoder().decode(VaultNoteRecoveryFile.self,from:bytes).record()?.saveConflict == .reconciliationRequired { throw URLError(.cannotWriteToFile) }
            try CanvasLocalFile.write(bytes,to:url)
        })
        guarded.saveNow();guarded.setNoteConnection(address:"http://fixture.invalid",token:"own-fixture")
        await guarded.openVaultNote(path) { _ in base };guarded.vaultDraft = draft
        await guarded.saveVaultNote { p,sha,t in try await relay.saveVaultNote(at:p,baseSha256:sha,text:t) }
        let failedRestart = CanvasStore(noteRecoveryURL:failedMarkerURL)
        check(guarded.vaultBlocked && guarded.noteRecoveryWriteFailed && failedRestart.noteRecovery?.saveConflict == .unclassified,"prepublication durable uncertainty survives post409 marker IO failure")
        try await checkWholeNoteRecovery(check)
        print("VAULT_CONFLICT_OK",checks,"network=0")
        session.invalidateAndCancel()
    }
}
