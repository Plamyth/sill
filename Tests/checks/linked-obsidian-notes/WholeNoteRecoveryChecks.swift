import Foundation
import PencilKit

@MainActor
func checkWholeNoteRecovery(_ check: (Bool,String) -> Void) async throws {
    func note(_ text: String, path: String = "Notes/recovery.md") -> VaultNoteSnapshot {
        VaultNoteSnapshot(path:path,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"now")
    }
    func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("note.json")
    }
    func store(_ url: URL) -> CanvasStore {
        let value = CanvasStore(noteRecoveryURL:url)
        value.setNoteConnection(address:"http://test",token:"test-token")
        return value
    }
    let base = note("# 검증\r\n\r\n가구\r\ne\u{301} 👩🏽‍💻\r\n")
    let draft = base.text.replacingOccurrences(of:"가구",with:"가방")
    let url = location(), first = store(url)
    first.scene = CanvasScene()
    await first.openVaultNote(base.path) { _ in base }
    first.vaultDraft = draft
    let bytes = try Data(contentsOf:url)
    let record = try JSONDecoder().decode(VaultNoteRecoveryFile.self,from:bytes).record()!
    check(record.draft.utf8.elementsEqual(draft.utf8) && record.base == base,
          "whole-note Pencil draft persists exact Unicode and CRLF with original source")
    check(!String(decoding:bytes,as:UTF8.self).contains("test-token"),"whole-note journal excludes credentials")
    let second = store(url)
    check(second.noteRecovery?.draft == draft && second.vaultNote == nil,
          "new Store discovers draft without opening or submitting it")
    var reads = 0
    await second.restoreNoteDraft { _ in reads += 1; return base }
    check(reads == 1 && second.vaultDraft.utf8.elementsEqual(draft.utf8) && second.vaultCanSave,
          "explicit restore checks original source before restoring editable draft")
    let third = store(url)
    var foreignReads = 0
    await third.openVaultNote("Notes/other.md") { path in foreignReads += 1; return note("other",path:path) }
    check(foreignReads == 0 && third.noteRecovery == record,"opening another note cannot replace pending draft")
    check(third.closeVaultEditor() && third.noteRecovery == record,
          "closing recovery notice without discard preserves durable input")
    third.setNoteConnection(address:"http://other",token:"another-token")
    await third.restoreNoteDraft { _ in foreignReads += 1; return base }
    check(foreignReads == 0 && third.vaultNote == nil,"different server cannot consume or transmit draft")
    let fourth = store(url)
    fourth.scene = CanvasScene()
    await fourth.restoreNoteDraft { _ in foreignReads += 1; return base }
    check(foreignReads == 0 && fourth.noteRecovery == record,"different scene leaves original draft intact")
    let conflict = store(url)
    await conflict.restoreNoteDraft { _ in note("Mac changed") }
    check(conflict.vaultNote == nil && conflict.noteRecovery == record && !conflict.noteRecoveryNotice.isEmpty,
          "changed Mac source blocks restore and preserves draft without a write")

    let lostURL = location(), lost = store(lostURL)
    lost.scene = CanvasScene()
    await lost.openVaultNote(base.path) { _ in base }
    lost.vaultDraft = draft
    var writes = 0
    await lost.saveVaultNote { _,_,_ in writes += 1; throw URLError(.networkConnectionLost) }
    check(writes == 1 && lost.noteRecovery?.submittedText == draft && lost.vaultBlocked,
          "lost response retains submitted bytes without inventing operation IDs")
    let committed = store(lostURL)
    await committed.restoreNoteDraft { _ in note(draft) }
    check(committed.vaultNote?.text == draft && committed.noteRecovery == nil && !committed.vaultDirty && writes == 1,
          "readback of committed draft clears recovery without duplicate write")

    let laterURL = location(), later = store(laterURL)
    later.scene = CanvasScene()
    await later.openVaultNote(base.path) { _ in base }
    later.vaultDraft = draft
    let gate = NoteGate()
    let save = Task { await later.saveVaultNote { path,_,_ in try await gate.load(path) } }
    await gate.wait()
    later.vaultDraft = draft + "다음 입력"
    gate.finish(note(draft))
    await save.value
    check(later.noteRecovery?.base.text == draft && later.noteRecovery?.draft == draft + "다음 입력",
          "successful save preserves typing added while request was in flight")
    let reopened = store(laterURL)
    await reopened.restoreNoteDraft { _ in note(draft) }
    check(reopened.vaultDraft == draft + "다음 입력" && reopened.vaultCanSave,
          "later input remains recoverable after another Store opens the journal")
    let before = try Data(contentsOf:laterURL)
    try Data("foreign replacement".utf8).write(to:laterURL,options:.atomic)
    reopened.vaultDraft += "보존"
    check(try Data(contentsOf:laterURL) != before && !reopened.vaultCanSave && reopened.vaultDraft.hasSuffix("보존"),
          "external journal replacement is not overwritten and disables further saves")
    let corrupt = store(laterURL)
    var corruptReads = 0
    await corrupt.openVaultNote(base.path) { _ in corruptReads += 1; return base }
    check(corruptReads == 0 && !corrupt.noteRecoveryNotice.isEmpty,
          "corrupt journal remains preserved and cannot silently disappear")

    let cancelURL = location(), cancelled = store(cancelURL)
    cancelled.scene = CanvasScene()
    await cancelled.openVaultNote(base.path) { _ in base }
    cancelled.vaultDraft = draft
    let awaiting = store(cancelURL), loading = NoteGate()
    let restore = Task { await awaiting.restoreNoteDraft(load:loading.load) }
    await loading.wait()
    awaiting.setNoteConnection(address:"http://replacement",token:"other")
    loading.finish(base)
    await restore.value
    check(awaiting.vaultNote == nil && awaiting.noteRecovery?.draft == draft,
          "connection switch rejects late restore while preserving input")
    func linked(_ url: URL) async -> CanvasStore {
        let value = store(url)
        value.scene = CanvasScene()
        let id = value.scene.addNode(kind:.note,at:CanvasPoint(x:0,y:0),text:"연결")
        value.scene.nodes[0].vaultNote = VaultNoteReference(path:base.path,sha256:base.sha256,
            relayAddress:"http://test",blockID:"keep",sourceState:.current)
        await value.openVaultNote(base.path,nodeID:id) { _ in base }
        return value
    }
    let bothURL = location(), both = await linked(bothURL)
    both.vaultDraft = draft
    let wholeBytes = try Data(contentsOf:bothURL)
    let blockURL = location()
    let blockBase = note("문단 ^keep")
    let blockRecord = VaultBlockRecovery(schemaVersion:1,sceneID:both.scene.id,
        nodeID:both.scene.nodes[0].id,relayAddress:"http://test",blockID:"keep",
        base:blockBase,draft:"문단 수정",pending:nil)
    try FileManager.default.createDirectory(at:blockURL.deletingLastPathComponent(),withIntermediateDirectories:true)
    let blockBytes = try JSONEncoder().encode(VaultBlockRecoveryFile(blockRecord))
    try blockBytes.write(to:blockURL)
    let bothRestart = CanvasStore(blockRecoveryURL:blockURL,noteRecoveryURL:bothURL)
    bothRestart.setNoteConnection(address:"http://test",token:"test-token")
    bothRestart.scene = both.scene
    check(try !bothRestart.restoreLinkedBlockDraft() && bothRestart.noteRecovery?.draft == draft &&
          (try Data(contentsOf:bothURL)) == wholeBytes && (try Data(contentsOf:blockURL)) == blockBytes,
          "F1 simultaneous journals refuse block restore and retain both original byte sequences")

    for mutation in ["missing","path","block","relay"] {
        let targetURL = location(), target = await linked(targetURL)
        target.vaultDraft = draft
        let bytes = try Data(contentsOf:targetURL)
        let restored = store(targetURL)
        restored.scene = target.scene
        let delayed = NoteGate()
        let task = Task { await restored.restoreNoteDraft(load:delayed.load) }
        await delayed.wait()
        if mutation == "missing" { restored.scene.nodes = [] }
        else {
            restored.scene.nodes[0].vaultNote = VaultNoteReference(
                path:mutation == "path" ? "Notes/changed.md" : base.path,sha256:base.sha256,
                relayAddress:mutation == "relay" ? "http://changed" : "http://test",
                blockID:mutation == "block" ? "changed" : "keep",sourceState:.current)
        }
        let sceneBefore = restored.scene
        delayed.finish(base)
        await task.value
        check(try restored.vaultNote == nil && restored.scene == sceneBefore &&
              (try Data(contentsOf:targetURL)) == bytes,"F2 late restore rejects node " + mutation + " change without modifying journal or cache")
    }
    let orderedURL = location(), ordered = await linked(orderedURL)
    ordered.vaultDraft = draft
    let orderedBytes = try Data(contentsOf:orderedURL)
    let orderedRestart = store(orderedURL)
    orderedRestart.scene = ordered.scene
    let delayedRead = NoteGate()
    let oldRead = Task { await orderedRestart.restoreNoteDraft(load:delayedRead.load) }
    await delayedRead.wait()
    await orderedRestart.refreshVaultNotes { _ in note("newer Mac text") }
    let newerScene = orderedRestart.scene
    delayedRead.finish(base)
    await oldRead.value
    check(try orderedRestart.vaultNote == nil && orderedRestart.scene == newerScene &&
          (try Data(contentsOf:orderedURL)) == orderedBytes,"F3 late recovery GET cannot undo a newer accepted cache read")

    let excerptURL = location(), excerpt = store(excerptURL)
    excerpt.scene = CanvasScene()
    await excerpt.openVaultNote(base.path) { _ in base }
    excerpt.vaultSelection = (base.text as NSString).range(of:"가구")
    let excerptGate = NoteGate()
    var anchor: VaultNoteSnapshot?
    var anchorDurable = false
    let excerptTask = Task { await excerpt.excerptSelectedVaultBlock(save:{ path,_,text in
        anchor = note(text)
        let onDisk = try JSONDecoder().decode(VaultNoteRecoveryFile.self,from:Data(contentsOf:excerptURL)).record()
        anchorDurable = onDisk?.submittedText?.utf8.elementsEqual(text.utf8) == true
        return try await excerptGate.load(path)
    },load:{ _ in anchor! }) }
    await excerptGate.wait()
    check(anchorDurable,"F4 exact anchor submission is durable before PUT")
    let typing = draft + "새 입력\r\n"
    excerpt.vaultDraft = typing
    excerptGate.finish(anchor!)
    _ = await excerptTask.value
    let excerptRestart = store(excerptURL)
    await excerptRestart.restoreNoteDraft { _ in anchor! }
    check(excerptRestart.vaultCanSave && excerptRestart.vaultDraft.utf8.elementsEqual(typing.utf8) &&
          excerptRestart.noteRecovery?.base == anchor && excerptRestart.noteRecovery?.submittedText == nil,
          "F4 excerpt concurrent typing restarts against confirmed anchor without false external conflict")

    let ioURL = location(), io = store(ioURL)
    io.scene = CanvasScene()
    await io.openVaultNote(base.path) { _ in base }
    io.vaultDraft = draft
    let ioBytes = try Data(contentsOf:ioURL)
    let directory = ioURL.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:directory.path)
    var ioWrites = 0
    await io.saveVaultNote { _,_,text in ioWrites += 1; return note(text) }
    check(try ioWrites == 0 && io.noteRecoveryWriteFailed && !io.vaultBlocked &&
          (try Data(contentsOf:ioURL)) == ioBytes,"F6 submission journal IO failure never enters uncertain server-result state")
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
    io.retryNoteDraftPreservation()
    check(ioWrites == 0 && io.vaultCanSave && !io.noteRecoveryWriteFailed,
          "F6 local retry restores durability without a server write")
    await io.saveVaultNote { _,_,text in ioWrites += 1; return note(text) }
    check(ioWrites == 1 && !io.vaultDirty,"F6 recovered journal permits one explicit server save")
    let sizeURL = location(), size = store(sizeURL)
    size.scene = CanvasScene()
    await size.openVaultNote(base.path) { _ in base }
    size.vaultDraft = String(repeating:"x",count:1024 * 1024 + 1)
    check(size.noteRecoveryWriteFailed && !size.vaultCanSave && !size.vaultBlocked,
          "F6 oversized input blocks only local durability")
    size.vaultDraft = draft
    check(!size.noteRecoveryWriteFailed && size.vaultCanSave && size.noteRecovery?.draft == draft,
          "F6 returning to valid size restores preservation and save eligibility")
    let externalBeforeRetry = try Data(contentsOf:laterURL)
    reopened.retryNoteDraftPreservation()
    check(try !reopened.vaultCanSave && (try Data(contentsOf:laterURL)) == externalBeforeRetry,
          "F6 local retry cannot overwrite an externally replaced journal")
    lost.retryNoteDraftPreservation()
    check(lost.vaultBlocked && !lost.vaultCanSave && writes == 1,
          "F6 local retry cannot clear uncertain server-result protection")

    let partialURL = location()
    var partialCalls = 0
    var failAfterWrite = false
    var failBeforeWrite = false
    let partial = CanvasStore(noteRecoveryURL:partialURL,noteRecoveryWrite:{ bytes,url in
        partialCalls += 1
        if failBeforeWrite { throw VaultBlockRecoveryError.unavailable }
        try CanvasLocalFile.write(bytes,to:url)
        if failAfterWrite {
            failAfterWrite = false
            throw VaultBlockRecoveryError.unavailable
        }
    })
    partial.setNoteConnection(address:"http://test",token:"test-token")
    partial.scene = CanvasScene()
    await partial.openVaultNote(base.path) { _ in base }
    partial.vaultDraft = draft
    let expectedBytes = try Data(contentsOf:partialURL)
    let extra = draft + "추가 e\u{301} 👩🏽‍💻\r\n"
    failAfterWrite = true
    partial.vaultDraft = extra
    let attemptedBytes = try Data(contentsOf:partialURL)
    check(attemptedBytes != expectedBytes && partial.noteRecoveryWriteFailed && !partial.vaultCanSave,
          "F6-R1 partial-success injection replaces bytes then throws and keeps saving blocked")
    var partialServerWrites = 0
    await partial.saveVaultNote { _,_,text in partialServerWrites += 1; return note(text) }
    check(partialServerWrites == 0 && partial.noteRecoveryWriteFailed,
          "F6-R1 failed durability never submits to server")
    let callsBeforeRetry = partialCalls
    failBeforeWrite = true
    partial.retryNoteDraftPreservation()
    check(partialCalls == callsBeforeRetry + 1 && partial.noteRecoveryWriteFailed && !partial.vaultCanSave,
          "F6-R1 equal readback retries writer and cannot clear failure when writer throws")
    failBeforeWrite = false
    partial.retryNoteDraftPreservation()
    check(partialCalls == callsBeforeRetry + 2 && !partial.noteRecoveryWriteFailed && partial.vaultCanSave &&
          partial.vaultDraft.utf8.elementsEqual(extra.utf8) &&
          partial.noteRecovery?.draft.utf8.elementsEqual(extra.utf8) == true && partialServerWrites == 0,
          "F6-R1 only successful full writer retry restores saving and preserves exact additional UTF8 input")
    failAfterWrite = true
    partial.vaultDraft = extra + "다음 입력"
    let partialAgainBytes = try Data(contentsOf:partialURL)
    failBeforeWrite = true
    let newest = extra + "더 입력 e\u{301}\r\n"
    partial.vaultDraft = newest
    check(try partial.noteRecoveryWriteFailed && !partial.vaultCanSave &&
          (try Data(contentsOf:partialURL)) == partialAgainBytes,
          "F6-R1 additional typing with pre-replacement failure preserves prior partial bytes")
    failBeforeWrite = false
    let beforeNewestRetry = partialCalls
    partial.retryNoteDraftPreservation()
    let newestRecord = try JSONDecoder().decode(VaultNoteRecoveryFile.self,from:Data(contentsOf:partialURL)).record()
    check(partialCalls == beforeNewestRetry + 1 && !partial.noteRecoveryWriteFailed && partial.vaultCanSave &&
          newestRecord?.draft.utf8.elementsEqual(newest.utf8) == true && partialServerWrites == 0,
          "F6-R1 full retry preserves latest UTF8 after consecutive partial and pre-write failures")
    try partialAgainBytes.write(to:partialURL,options:.atomic)
    let callsBeforeForeign = partialCalls
    partial.retryNoteDraftPreservation()
    check(try partialCalls == callsBeforeForeign && !partial.vaultCanSave &&
          (try Data(contentsOf:partialURL)) == partialAgainBytes && partialServerWrites == 0,
          "F6-R1 successful write releases attempted bytes and foreign replacement stays untouched")

}
