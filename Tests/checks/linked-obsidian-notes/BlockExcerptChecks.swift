import Foundation
import PencilKit

@MainActor
func checkBlockExcerpts(_ check: (Bool, String) -> Void) async throws {
    func note(_ text: String) -> VaultNoteSnapshot {
        VaultNoteSnapshot(path:"Notes/blocks.md",text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"now")
    }
    func store(_ text: String) async -> CanvasStore {
        let value = CanvasStore(noteRecoveryURL:FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("note.json"))
        value.scene = CanvasScene()
        value.drawing = PKDrawing()
        value.scene.drawingBase64 = value.drawing.dataRepresentation().base64EncodedString()
        value.setNoteConnection(address:"http://test",token:"test-token")
        await value.openVaultNote("Notes/blocks.md") { _ in note(text) }
        return value
    }
    func select(_ value: CanvasStore, _ text: String) {
        value.vaultSelection = (value.vaultDraft as NSString).range(of:text)
    }
    func rejected(_ text: String, _ selected: String, _ expected: VaultBlockError) -> Bool {
        do {
            _ = try VaultMarkdownBlocks(text).selected((text as NSString).range(of:selected))
            return false
        } catch { return (error as? VaultBlockError) == expected }
    }
    let quote = "첫 문단 e\u{301} 👩🏽‍💻\r\n둘째 줄"
    let prefix = "\u{feff}# 제목\r\n\r\n"
    let suffix = "\r\n\r\n다른 문단 끝\n"
    let raw = prefix + quote + suffix
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NoteProtocol.self]
    let relay = CanvasRelay(address:"http://test",token:"test-token",session:URLSession(configuration:config))
    func excerpt(_ value: CanvasStore) async -> UUID? {
        await value.excerptSelectedVaultBlock(save:{ path,sha,text in
            try await relay.saveVaultNote(at:path,baseSha256:sha,text:text)
        },load:relay.vaultNote)
    }
    NoteProtocol.cas = true
    NoteProtocol.status = 200
    NoteProtocol.text = raw
    NoteProtocol.writes = 0
    NoteProtocol.calls = []
    let s = await store(raw)
    let ink = s.scene.drawingBase64
    let stroke = InkStroke(id:UUID(),points:[InkPoint(x:5,y:8,pressure:0.5)],createdAt:Date())
    s.scene.strokes = [stroke]
    let originalNode = s.scene.addNode(kind:.box,at:CanvasPoint(x:4,y:5),text:"existing")
    let existing = s.scene.nodes
    select(s,quote)
    let created = await excerpt(s)
    check(created != nil,"selected paragraph creates an anchored card through production store and relay")
    guard let created, let ref = s.scene.nodes.last?.vaultNote, let id = ref.blockID else { return }
    let expected = prefix + quote + " ^\(id)" + suffix
    check(Array(NoteProtocol.text.utf8) == Array(expected.utf8),
        "anchor insertion preserves BOM, mixed CRLF/LF, Unicode normalization and every unrelated byte")
    check(NoteProtocol.calls == ["PUT","GET"] && NoteProtocol.writes == 1 && NoteProtocol.authenticated,
        "anchor uses existing authenticated CAS PUT and explicit GET readback exactly once")
    check(ref.sha256 == note(expected).sha256 && ref.observedSha256 == ref.sha256 && s.vaultNote?.sha256 == ref.sha256,
        "saved readback SHA binds editor, card cache and observed source")
    check(s.scene.nodes.last?.text == quote && ref.sourceState == .current && ref.cacheTruncated == false,
        "card quote excludes source marker and remains derived from verified Markdown")
    check(s.scene.drawingBase64 == ink && s.scene.strokes == [stroke] && Array(s.scene.nodes.dropLast()) == existing &&
          s.scene.nodes.first?.id == originalNode,"excerpt preserves raw ink, provenance and preexisting node identities")
    let count = NoteProtocol.writes
    select(s,quote)
    let reused = await excerpt(s)
    check(reused != nil && s.scene.nodes.last?.vaultNote?.blockID == id && NoteProtocol.writes == count,
        "existing explicit ID is reused without a marker write")

    let legacy = s.attachOpenedVaultNote()!
    let fresh = note("Other paragraph\n\nMac의 새 문단 ^\(id)\n\nTail")
    await s.refreshVaultNotes { _ in fresh }
    let updated = s.scene.nodes.first { $0.id == created }!
    check(updated.text == "Mac의 새 문단" && updated.vaultNote?.sourceState == .changed &&
          updated.vaultNote?.sha256 == fresh.sha256,"Mac edits resolve the same block ID after reordering and change its cache")
    check(s.scene.nodes.first { $0.id == legacy }?.text == fresh.text,
        "legacy whole-note cards retain whole-note refresh behavior alongside block cards")
    _ = s.closeVaultEditor()
    await s.openVaultNote(fresh.path,nodeID:created) { _ in fresh }
    check(s.vaultSelection == (fresh.text as NSString).range(of:"Mac의 새 문단 ^\(id)") && s.vaultLinkedBlockID == id,
        "opening a linked card selects the exact anchored block in the native editor")
    for (text,state) in [("Unrelated whole-note preview",VaultNoteReference.SourceState.missing),
                          ("One ^\(id)\n\nTwo ^\(id)",.ambiguous),
                          ("- Complex list ^\(id)",.unsupported)] {
        let incoming = note(text)
        await s.refreshVaultNotes { _ in incoming }
        let retained = s.scene.nodes.first { $0.id == created }!
        check(retained.text == updated.text && retained.vaultNote?.sha256 == fresh.sha256 &&
              retained.vaultNote?.observedSha256 == incoming.sha256 && retained.vaultNote?.sourceState == state,
            "\(state.rawValue) anchor preserves last verified quote and cached-source SHA without whole-note fallback")
    }
    await s.openVaultNote(fresh.path,nodeID:created) { _ in note("Unrelated paragraph") }
    check(s.vaultSelection.location == NSNotFound && s.vaultSelectedBlock == nil &&
          s.scene.nodes.first { $0.id == created }?.text == updated.text,
        "opening a missing linked block cannot select or substitute an unrelated paragraph")
    await s.refreshVaultNotes { _ in throw NSError(domain:"CanvasRelay",code:404) }
    check(s.scene.nodes.first { $0.id == created }?.vaultNote?.sourceState == .missing,
        "missing note marks source missing without deleting the card")
    let roundtrip = try JSONDecoder().decode(CanvasScene.self,from:JSONEncoder().encode(s.scene))
    let json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(s.scene)) as! [String:Any]
    let encodedNodes = json["nodes"] as! [[String:Any]]
    let encodedRef = encodedNodes.first { $0["id"] as? String == created.uuidString }!["vaultNote"] as! [String:Any]
    check(roundtrip == s.scene && encodedRef["blockID"] as? String == id &&
          encodedRef["sourceState"] as? String == "missing" && encodedRef["path"] as? String == fresh.path,
        "AI-readable scene JSON roundtrip retains explicit source ID, path, SHA, cache and missing state")
    var legacyJSON = encodedRef
    legacyJSON.removeValue(forKey:"blockID")
    legacyJSON.removeValue(forKey:"sourceState")
    legacyJSON.removeValue(forKey:"observedSha256")
    legacyJSON.removeValue(forKey:"quoteSha256")
    let decodedLegacy = try JSONDecoder().decode(VaultNoteReference.self,from:JSONSerialization.data(withJSONObject:legacyJSON))
    check(decodedLegacy.blockID == nil && decodedLegacy.sourceState == nil,"old whole-note reference JSON remains compatible")

    check(rejected("One ^same\n\nTwo ^same","One",.ambiguous),"duplicate explicit IDs refuse attribution")
    check(rejected("Paragraph\n\n^separate","Paragraph",.unsupported),"separate marker line is not reinterpreted as a plain paragraph")
    for text in ["- list item", "Title\n---", "> quote", "| a | b |", "    indented", "Text\nnext ^a\nthird",
                 "```md\n\nInside\n\n```", "---\nkey: value\n\nInside\n---", "<div>\n\nInside\n\n</div>",
                 "%% comment\n\nInside\n%%", "$$\n\nInside\n$$"] {
        let selected = text.contains("Inside") ? "Inside" : text
        check(rejected(text,selected,.unsupported),"unsupported complex block is refused: \(selected.replacingOccurrences(of:"\n",with:" / "))")
    }
    check(rejected("One\n\nTwo","One\n\nTwo",.unsupported),"selection crossing paragraphs cannot invent a source block")
    check(rejected("emoji 👩🏽‍💻", "absent",.selection),"invalid native selection range is refused")
    let explicit = await store("Before\n\nAlready linked ^A-9\n\nAfter")
    select(explicit,"Already linked")
    let explicitID = await explicit.excerptSelectedVaultBlock(save:{ _,_,_ in
        check(false,"existing ID must not write"); throw URLError(.badURL)
    },load:{ _ in check(false,"reuse needs no PUT readback"); throw URLError(.badURL) })
    check(explicitID != nil && explicit.scene.nodes.last?.vaultNote?.blockID == "A-9","user-created Obsidian ASCII block IDs are reused verbatim")
    explicit.vaultDraft = "Native editor deliberately removed the marker"
    await explicit.saveVaultNote { _,_,text in note(text) }
    check(explicit.scene.nodes.last?.text == "Already linked" && explicit.scene.nodes.last?.vaultNote?.sourceState == .missing,
        "native note editing remains authoritative when it deliberately deletes a linked marker")
    let cursor = "Paragraph end"
    let endBlock = try VaultMarkdownBlocks(cursor).selected(NSRange(location:cursor.utf16.count,length:0))
    check(endBlock.quote == cursor,"native caret at paragraph end selects that same paragraph")

    let longQuote = String(repeating:"한글",count:300)
    let long = await store(longQuote + " ^long-id")
    let longCard = await long.excerptSelectedVaultBlock(save:{ _,_,_ in throw URLError(.badURL) },load:{ _ in throw URLError(.badURL) })
    let cached = long.scene.nodes.first?.text
    await long.refreshVaultNotes { _ in note(longQuote + " changed after preview ^long-id") }
    check(longCard != nil && long.scene.nodes.first?.text == cached && long.scene.nodes.first?.vaultNote?.cacheTruncated == true &&
          long.scene.nodes.first?.vaultNote?.sourceState == .changed,
        "full quote digest detects changes beyond bounded 512-byte cache without storing text history")
    let full = await store(String(repeating:"x",count:1024*1024))
    var overflowWrites = 0
    let oversized = await full.excerptSelectedVaultBlock(save:{ _,_,text in overflowWrites += 1; return note(text) },
                                                        load:{ _ in note("") })
    check(oversized == nil && overflowWrites == 0,"marker exceeding existing note size limit is refused before a write")

    for lost in [false,true] {
        NoteProtocol.text = "CAS paragraph"
        NoteProtocol.calls = []
        NoteProtocol.writes = 0
        NoteProtocol.conflict = !lost
        NoteProtocol.loseResponse = lost
        let state = await store(NoteProtocol.text)
        let result = await excerpt(state)
        if lost {
            check(result != nil && NoteProtocol.writes == 1 && NoteProtocol.calls == ["PUT","GET"] && !state.vaultBlocked,
                "lost PUT response reconciles identical saved bytes and ID through GET without duplicate write")
        } else {
            check(result == nil && state.vaultBlocked && NoteProtocol.writes == 0 && state.scene.nodes.isEmpty,
                "stale CAS refuses attachment and preserves the source written by Mac")
        }
        if !lost {
            let attempts = NoteProtocol.calls.count
            _ = await excerpt(state)
            check(NoteProtocol.calls.count == attempts,"blocked stale CAS cannot generate or submit another anchor")
        }
    }
    NoteProtocol.conflict = false
    NoteProtocol.loseResponse = false

    let recoverySource = "First paragraph must stay untouched\n\nUnconfirmed second paragraph\n\nThird paragraph"
    let unknown = await store(recoverySource)
    select(unknown,"Unconfirmed second paragraph")
    var persisted: VaultNoteSnapshot?
    var puts = 0
    let failed = await unknown.excerptSelectedVaultBlock(save:{ _,_,text in
        puts += 1; persisted = note(text); throw URLError(.networkConnectionLost)
    },load:{ _ in throw URLError(.timedOut) })
    check(failed == nil && unknown.vaultBlocked && puts == 1 && unknown.scene.nodes.isEmpty,
        "lost response plus failed readback remains explicitly unresolved without a guessed card")
    _ = await unknown.excerptSelectedVaultBlock(save:{ _,_,_ in puts += 1; return persisted! },load:{ _ in persisted! })
    check(puts == 1,"unresolved anchor attempt cannot be automatically written again")
    await unknown.openVaultNote("Notes/blocks.md") { _ in persisted! }
    check(unknown.vaultSelectedBlock?.quote == "Unconfirmed second paragraph",
        "reread focuses the attempted second paragraph instead of silently selecting paragraph one")
    let recoveredID = await unknown.excerptSelectedVaultBlock(save:{ _,_,_ in puts += 1; return persisted! },load:{ _ in persisted! })
    check(recoveredID != nil && puts == 1 && unknown.scene.nodes.last?.text == "Unconfirmed second paragraph" &&
          persisted!.text.hasPrefix("First paragraph must stay untouched\n\n"),
        "explicit source reread recovers the same second-paragraph anchor without another write or wrong card")
    let rejected = await store(recoverySource)
    select(rejected,"Unconfirmed second paragraph")
    _ = await rejected.excerptSelectedVaultBlock(save:{ _,_,_ in throw URLError(.networkConnectionLost) },
                                                load:{ _ in throw URLError(.timedOut) })
    await rejected.openVaultNote("Notes/blocks.md") { _ in note(recoverySource) }
    check(rejected.vaultSelection.location == NSNotFound && rejected.vaultSelectedBlock == nil,
        "uncommitted missing anchor requires explicit reselection and never falls back to the first paragraph")
    var recoveryWrites = 0
    _ = await rejected.excerptSelectedVaultBlock(save:{ _,_,text in recoveryWrites += 1; return note(text) },
                                                load:{ _ in note(recoverySource) })
    check(recoveryWrites == 0 && rejected.scene.nodes.isEmpty,
        "recovery cannot silently write another marker when the attempted identity is absent")

    let typing = await store("Freeze this paragraph"), gate = NoteGate()
    var submitted: VaultNoteSnapshot?
    let pending = Task { await typing.excerptSelectedVaultBlock(save:{ path,_,text in
        submitted = note(text); return try await gate.load(path)
    },load:{ _ in submitted! }) }
    await gate.wait()
    typing.vaultDraft = "New draft entered during marker save"
    check(!typing.closeVaultEditor(discard:true),"editor cannot discard an in-flight marker operation")
    do { try typing.importScene(typing.scene); check(false,"in-flight marker prevents scene import") }
    catch { check(true,"in-flight marker prevents scene import") }
    gate.finish(submitted!); let typedCard = await pending.value
    check(typedCard != nil && typing.vaultDraft == "New draft entered during marker save" && typing.vaultBlocked &&
          typing.scene.nodes.last?.text == "Freeze this paragraph" && !typing.vaultCanSave,
        "simultaneous draft edits survive marker readback and cannot blindly remove the new anchor")

    for mutation in ["connection", "scene", "connection ABA", "cancel"] {
        let state = await store("Frozen source"), delayed = NoteGate()
        var saved: VaultNoteSnapshot?
        let operation = Task { await state.excerptSelectedVaultBlock(save:{ path,_,text in
            saved = note(text); return try await delayed.load(path)
        },load:{ _ in saved! }) }
        await delayed.wait()
        switch mutation {
        case "scene": state.scene = CanvasScene()
        case "cancel": operation.cancel()
        default:
            state.setNoteConnection(address:"http://other",token:"other")
            if mutation == "connection ABA" { state.setNoteConnection(address:"http://test",token:"test-token") }
        }
        delayed.finish(saved!)
        let result = await operation.value
        check(result == nil && state.scene.nodes.isEmpty && state.vaultDraft == "Frozen source",
            "late marker response cannot attach across \(mutation)")
    }
    for mutation in ["connection", "scene"] {
        let state = await store("Readback source"), delayed = NoteGate()
        var saved: VaultNoteSnapshot?
        let operation = Task { await state.excerptSelectedVaultBlock(save:{ _,_,text in saved = note(text); return saved! },
                                                                     load:delayed.load) }
        await delayed.wait()
        if mutation == "scene" { state.scene = CanvasScene() }
        else { state.setNoteConnection(address:"http://other",token:"other") }
        delayed.finish(saved!)
        let result = await operation.value
        check(result == nil && state.scene.nodes.isEmpty,"late marker readback cannot attach across \(mutation)")
    }
    let ordered = await store("Race quote"), older = NoteGate()
    _ = ordered.attachOpenedVaultNote()
    var firstRead: VaultNoteSnapshot?
    let earlyReadback = Task { await ordered.excerptSelectedVaultBlock(save:{ _,_,text in firstRead = note(text); return firstRead! },
                                                                      load:older.load) }
    await older.wait()
    let newerRead = note(firstRead!.text.replacingOccurrences(of:"Race quote",with:"Newer Mac quote"))
    await ordered.refreshVaultNotes { _ in newerRead }
    older.finish(firstRead!)
    let staleCard = await earlyReadback.value
    check(staleCard == nil && ordered.vaultBlocked && ordered.scene.nodes.count == 1 &&
          ordered.scene.nodes.first?.vaultNote?.sha256 == newerRead.sha256,
        "older anchor readback cannot regress a newer accepted refresh or attach stale quote")
    NoteProtocol.cas = false
    try await checkLinkedBlockEditing(check)
    try await checkBlockDraftRecovery(check)
}


@MainActor
private func checkLinkedBlockEditing(_ check: (Bool,String) -> Void) async throws {
    func note(_ text: String) -> VaultNoteSnapshot {
        VaultNoteSnapshot(path:"Notes/semantic.md",text:text,
            sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"now")
    }
    let original = note("# 원본\r\n\r\n문단 e\u{301} 👩🏽‍💻\r\n둘째 줄 ^edit-1\r\n\r\n끝\r\n")
    let replacement = "수정한 글자 👩🏽‍💻\r\n다음 줄"
    let expected = try VaultMarkdownBlocks(original.text).replacing("edit-1",with:replacement)
    check(Array(expected.utf8) == Array(original.text.replacingOccurrences(of:"문단 e\u{301} 👩🏽‍💻\r\n둘째 줄",with:replacement).utf8),
          "block replacement preserves every unrelated byte, CRLF, marker and Unicode")
    for invalid in ["", "- 목록", "새 문단\n\n다른 문단", "글자 ^injected", "<tag>", "문단\r불완전"] {
        do { _ = try VaultMarkdownBlocks(original.text).replacing("edit-1",with:invalid)
            check(false,"unsupported block replacement rejected: \(invalid)")
        } catch { check(true,"unsupported block replacement rejected: \(invalid)") }
    }
    func store(_ source: VaultNoteSnapshot = original) async -> CanvasStore {
        let s = CanvasStore(blockRecoveryURL:FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("recovery.json"))
        s.scene = CanvasScene()
        s.setNoteConnection(address:"http://test",token:"test-token")
        await s.openVaultNote(source.path) { _ in source }
        s.vaultSelection = (source.text as NSString).range(of:"문단")
        let id = await s.excerptSelectedVaultBlock(save:{ _,_,_ in throw URLError(.badURL) },load:{ _ in source })!
        _ = s.closeVaultEditor()
        await s.openVaultNote(source.path,nodeID:id) { _ in source }
        return s
    }
    func result(_ edit: VaultBlockEdit, disposition: String = "committed") throws -> VaultBlockEditResult {
        let saved = note(try VaultMarkdownBlocks(original.text).replacing("edit-1",with:edit.replacementText))
        return VaultBlockEditResult(schemaVersion:1,operationId:edit.operationId,blockID:"edit-1",
            disposition:disposition,quoteSha256:CanvasPacket.sha(Data(edit.replacementText.utf8)),note:saved)
    }
    let invalidDraft = await store()
    check(invalidDraft.beginLinkedBlockEdit(),"unsupported draft starts in a valid linked editor")
    invalidDraft.vaultBlockDraft = " invalid leading indentation"
    var invalidDispatched = false
    await invalidDraft.saveLinkedBlock(replace:{ _,_,edit in
        invalidDispatched = true
        return try result(edit)
    },load:{ _ in original })
    check(!invalidDispatched && !invalidDraft.vaultBlockHasPendingSave &&
          invalidDraft.vaultBlockDraft == " invalid leading indentation" &&
          invalidDraft.vaultStatus.contains("저장 요청은 보내지 않았습니다"),
          "local paragraph rejection preserves draft without claiming a dispatched pending operation")
    let s = await store()
    let before = s.scene
    check(s.beginLinkedBlockEdit() && s.vaultBlockDraft == "문단 e\u{301} 👩🏽‍💻\n둘째 줄" && !s.vaultDirty,
          "linked editor exposes paragraph without source marker and normalizes display newlines")
    s.vaultBlockDraft = replacement.replacingOccurrences(of:"\r\n",with:"\n")
    var submitted: VaultBlockEdit?
    await s.saveLinkedBlock(replace: { path,id,edit in
        check(path == original.path && id == "edit-1" && edit.baseSha256 == original.sha256,
              "human editor sends shared semantic source identity and whole-note CAS")
        check(edit.replacementText == replacement,"native editor restores CRLF before semantic request")
        submitted = edit
        return try result(edit)
    },load:{ _ in note(expected) })
    check(s.vaultNote?.text == expected && s.scene.nodes.first?.text == replacement && !s.vaultDirty,
          "verified semantic result updates authoritative note and derived card")
    check(s.scene.nodes.first?.id == before.nodes.first?.id && s.scene.nodes.first?.frame == before.nodes.first?.frame &&
          s.scene.strokes == before.strokes && s.scene.drawingBase64 == before.drawingBase64 && s.scene.links == before.links,
          "semantic editing preserves node identity, layout, ink and relations")
    let fresh = note(expected.replacingOccurrences(of:"수정한 글자",with:"Mac에서 바뀐 글자"))
    await s.openVaultNote(original.path) { _ in fresh }
    check(!s.vaultBlockEditing && s.vaultBlockDraft.isEmpty && !s.vaultDirty && !s.vaultBlockCanSave,
          "clean reload exits semantic mode and cannot rebase an old block draft onto fresh source")
    check(s.beginLinkedBlockEdit() && s.vaultBlockDraft.contains("Mac에서 바뀐 글자"),
          "reopening block edit seeds the fresh source quote")

    let single = note("# 제목\r\n\r\n문단 ^edit-1\r\n\r\n뒤\r\n")
    let expanded = await store(single)
    check(expanded.beginLinkedBlockEdit(),"single-line CRLF quote is editable")
    expanded.vaultBlockDraft = "문단\n추가 줄"
    await expanded.saveLinkedBlock(replace:{ _,_,edit in
        check(edit.replacementText == "문단\r\n추가 줄",
              "multiline expansion inherits whole-note CRLF even when old quote has no newline")
        let saved = note(try VaultMarkdownBlocks(single.text).replacing("edit-1",with:edit.replacementText))
        return VaultBlockEditResult(schemaVersion:1,operationId:edit.operationId,blockID:"edit-1",
            disposition:"committed",quoteSha256:CanvasPacket.sha(Data(edit.replacementText.utf8)),note:saved)
    },load:{ _ in note("# 제목\r\n\r\n문단\r\n추가 줄 ^edit-1\r\n\r\n뒤\r\n") })
    check(!expanded.vaultDirty && !expanded.vaultBlockHasPendingSave,"CRLF expansion confirms without a rejected pending operation")
    let mixed = note("문단 ^edit-1\r\n\r\n뒤\n")
    let rejected = await store(mixed)
    check(!rejected.beginLinkedBlockEdit() && !rejected.vaultBlockHasPendingSave,
          "mixed source newlines are rejected before edit or pending write")
    do { _ = try VaultMarkdownBlocks(mixed.text).replacing("edit-1",with:"변경")
        check(false,"pure model rejects mixed source newlines")
    } catch { check(true,"pure model rejects mixed source newlines") }
    let edit = submitted!
    let forged = VaultBlockEditResult(schemaVersion:1,operationId:edit.operationId,blockID:"edit-1",
        disposition:"committed",quoteSha256:CanvasPacket.sha(Data(replacement.utf8)),note:note(expected + "forged"))
    do { _ = try forged.validated(edit:edit,base:original,blockID:"edit-1")
        check(false,"semantic response may not modify any unrelated source byte")
    } catch { check(true,"semantic response may not modify any unrelated source byte") }

    let uncertain = await store()
    _ = uncertain.beginLinkedBlockEdit()
    uncertain.vaultBlockDraft = "확정할 문장"
    var firstEdit: VaultBlockEdit?
    await uncertain.saveLinkedBlock(replace:{ _,_,edit in firstEdit = edit; throw URLError(.networkConnectionLost) },load:{ _ in original })
    check(uncertain.vaultBlockHasPendingSave && uncertain.vaultDirty && uncertain.vaultBlockCanSave,
          "lost response retains pending operation and draft for same-ID reconciliation")
    uncertain.vaultBlockDraft = "응답 뒤에 새로 쓴 내용"
    await uncertain.saveLinkedBlock(replace: { _,_,edit in
        check(edit == firstEdit,"retry keeps exact operation ID and frozen payload despite later typing")
        return try result(edit,disposition:"reconciled")
    },load:{ _ in try result(firstEdit!).note })
    check(uncertain.vaultNote?.text.contains("확정할 문장 ^edit-1") == true &&
          uncertain.vaultBlockDraft == "응답 뒤에 새로 쓴 내용" && uncertain.vaultDirty && !uncertain.vaultBlockHasPendingSave,
          "reconciliation confirms old operation without deleting newer unsaved typing")


    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SemanticBlockProtocol.self]
    let relay = CanvasRelay(address:"http://test",token:"test-token",session:URLSession(configuration:config))
    SemanticBlockProtocol.note = original
    SemanticBlockProtocol.validContract = true
    let transport = await store()
    _ = transport.beginLinkedBlockEdit()
    transport.vaultBlockDraft = "인간과 에이전트의 공통 수정"
    await transport.saveLinkedBlock(replace:{ path,id,edit in
        try await relay.replaceVaultBlock(at:path,blockID:id,edit:edit)
    },load:relay.vaultNote)
    check(SemanticBlockProtocol.validContract && transport.vaultNote?.text.contains("인간과 에이전트의 공통 수정 ^edit-1") == true,
          "production URLSession semantic route sends auth, encoded path/block ID and versioned operation, then GET confirms")
    check(!transport.vaultDirty && !transport.vaultBlockHasPendingSave,
          "HTTP semantic receipt and explicit source readback finish the pending operation")

    let dirty = await store()
    dirty.vaultDraft += "whole-note draft"
    check(!dirty.beginLinkedBlockEdit(),"block editor cannot replace an existing unsaved full-note draft")
    for mutation in ["connection", "scene", "typing", "background refresh"] {
        let delayed = await store(), gate = NoteGate()
        _ = delayed.beginLinkedBlockEdit()
        delayed.vaultBlockDraft = "일단 저장"
        var frozen: VaultBlockEdit?
        let task = Task { await delayed.saveLinkedBlock(replace: { _,_,edit in
            frozen = edit
            let saved = try await gate.load(original.path)
            return VaultBlockEditResult(schemaVersion:1,operationId:edit.operationId,blockID:"edit-1",
                disposition:"committed",quoteSha256:CanvasPacket.sha(Data(edit.replacementText.utf8)),note:saved)
        },load:{ _ in try result(frozen!).note }) }
        await gate.wait()
        if mutation == "scene" { delayed.scene = CanvasScene() }
        else if mutation == "connection" { delayed.setNoteConnection(address:"http://different",token:"other") }
        else if mutation == "typing" { delayed.vaultBlockDraft = "저장 중 새 입력" }
        else { await delayed.refreshVaultNotes { _ in note("Mac changed ^edit-1") } }
        gate.finish(try result(frozen!).note)
        await task.value
        if mutation == "scene" || mutation == "connection" {
            check(delayed.vaultNote?.sha256 == original.sha256 && delayed.vaultBlockDraft == "일단 저장",
                  "late semantic response cannot cross \(mutation) context")
        } else if mutation == "typing" {
            check(delayed.vaultBlockDraft == "저장 중 새 입력" && delayed.vaultDirty,
                  "typing during semantic save remains unsaved and intact")
        } else {
            check(delayed.vaultNote?.text.contains("일단 저장 ^edit-1") == true,
                  "background refresh does not replace frozen semantic edit base")
        }
    }
}


private final class SemanticBlockProtocol: URLProtocol {
    static var note: VaultNoteSnapshot!
    static var validContract = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = request.url!
            let query = URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
            let relative = query.first(where:{$0.name == "path"})!.value!
            Self.validContract = Self.validContract && relative == Self.note.path &&
                request.value(forHTTPHeaderField:"X-Canvas-Token") == "test-token"
            var payload: [String:Any]
            if request.httpMethod == "PUT" {
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating:0,count:4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer,maxLength:buffer.count)
                        if count <= 0 { break }
                        body.append(contentsOf:buffer.prefix(count))
                    }
                }
                let edit = try JSONDecoder().decode(VaultBlockEdit.self,from:body)
                let id = query.first(where:{$0.name == "blockID"})!.value!
                let originalQuote = try VaultMarkdownBlocks(Self.note.text).resolve(id).quote
                Self.validContract = Self.validContract && url.path == "/vault/block" && edit.schemaVersion == 1 &&
                    id == "edit-1" && edit.baseSha256 == Self.note.sha256 &&
                    edit.baseQuoteSha256 == CanvasPacket.sha(Data(originalQuote.utf8))
                let text = try VaultMarkdownBlocks(Self.note.text).replacing(id,with:edit.replacementText)
                Self.note = VaultNoteSnapshot(path:relative,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"now")
                payload = ["schemaVersion":1,"operationId":edit.operationId.uuidString,"blockID":id,
                    "disposition":"committed","quoteSha256":CanvasPacket.sha(Data(edit.replacementText.utf8)),
                    "note":snapshot()]
            } else { Self.validContract = Self.validContract && url.path == "/vault/note"; payload = snapshot() }
            let data = try JSONSerialization.data(withJSONObject:payload)
            client!.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client!.urlProtocol(self,didLoad:data)
            client!.urlProtocolDidFinishLoading(self)
        } catch { client!.urlProtocol(self,didFailWithError:error) }
    }
    private func snapshot() -> [String:Any] {
        ["path":Self.note.path,"text":Self.note.text,"sha256":Self.note.sha256,"modifiedAt":Self.note.modifiedAt]
    }
    override func stopLoading() {}
}

@MainActor
private func checkBlockDraftRecovery(_ check: (Bool,String) -> Void) async throws {
    func note(_ text: String) -> VaultNoteSnapshot {
        VaultNoteSnapshot(path:"Notes/recovery.md",text:text,
            sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"now")
    }
    let source = note("# 원본\r\n\r\n문단 e\u{301} 👩🏽‍💻 ^recover-1\r\n\r\n다른 문단\r\n")
    func path() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("recovery.json")
    }
    func record(_ url: URL) throws -> VaultBlockRecovery? {
        try JSONDecoder().decode(VaultBlockRecoveryFile.self,from:Data(contentsOf:url)).record()
    }
    func setup(_ url: URL) async -> CanvasStore {
        let s = CanvasStore(blockRecoveryURL:url)
        s.scene = CanvasScene()
        s.setNoteConnection(address:"http://test",token:"test-token")
        await s.openVaultNote(source.path) { _ in source }
        s.vaultSelection = (source.text as NSString).range(of:"문단")
        let id = await s.excerptSelectedVaultBlock(save:{ _,_,_ in throw URLError(.badURL) },load:{ _ in source })!
        _ = s.closeVaultEditor()
        await s.openVaultNote(source.path,nodeID:id) { _ in source }
        check(s.beginLinkedBlockEdit(),"recovery fixture starts a source-linked editor")
        return s
    }
    func restart(_ previous: CanvasStore, _ url: URL) -> CanvasStore {
        let s = CanvasStore(blockRecoveryURL:url)
        check(s.scene.id == previous.scene.id && s.scene.nodes.map(\.id) == previous.scene.nodes.map(\.id),
              "restart reads persisted source scene and card identities without reconstructing them")
        s.setNoteConnection(address:"http://test",token:"test-token")
        return s
    }
    func result(_ edit: VaultBlockEdit, disposition: String = "committed") throws -> VaultBlockEditResult {
        let saved = note(try VaultMarkdownBlocks(source.text).replacing("recover-1",with:edit.replacementText))
        return VaultBlockEditResult(schemaVersion:1,operationId:edit.operationId,blockID:"recover-1",
            disposition:disposition,quoteSha256:CanvasPacket.sha(Data(edit.replacementText.utf8)),note:saved)
    }
    let url = path(), initial = await setup(url)
    let draft = "한 글자 수정 e\u{301} 👩🏽‍💻\n계속 입력"
    initial.vaultBlockDraft = draft
    let savedDraft = try record(url)
    check(!String(decoding:try Data(contentsOf:url),as:UTF8.self).contains("test-token"),
          "recovery stores no relay credential")
    check(savedDraft?.draft.utf8.elementsEqual(draft.utf8) == true && savedDraft?.pending == nil,
          "each draft change is durable before any network operation")
    let recovered = restart(initial,url)
    check(!recovered.vaultBlockEditing && recovered.blockRecovery != nil,
          "restart offers recovery without opening or automatically transmitting the draft")
    recovered.setNoteConnection(address:"http://other",token:"different")
    check(!recovered.restoreLinkedBlockDraft(),"recovery refuses a different relay identity")
    recovered.setNoteConnection(address:"http://test",token:"test-token")
    let originalScene = recovered.scene
    recovered.scene.nodes = []
    check(!recovered.restoreLinkedBlockDraft(),"recovery refuses a missing source card")
    recovered.scene = CanvasScene()
    check(!recovered.restoreLinkedBlockDraft(),"recovery refuses a different scene")
    recovered.scene = originalScene
    check(recovered.restoreLinkedBlockDraft() && recovered.vaultBlockDraft.utf8.elementsEqual(draft.utf8) && recovered.vaultDirty,
          "restart restores exact Unicode draft with its original scene, card and source")
    var preflight = 0, writes = 0
    await recovered.saveLinkedBlock(replace:{ _,_,edit in
        writes += 1
        check(try record(url)?.pending == edit,"operation ID and frozen payload reach disk before the request")
        return try result(edit)
    },load:{ _ in
        preflight += 1
        return preflight == 1 ? source : try result(record(url)!.pending!).note
    })
    check(preflight == 2 && writes == 1 && !recovered.vaultDirty && !recovered.vaultBlockHasPendingSave,
          "recovered draft checks source, saves once, and independently confirms exact result")
    check(try record(url)?.base == recovered.vaultNote,"confirmed base advances durably before pending state clears")
    await recovered.openVaultNote(source.path) { _ in recovered.vaultNote ?? source }
    check(try record(url) == nil,"clean editor reload clears obsolete recovery before accepting another source")

    let pendingURL = path(), pendingStore = await setup(pendingURL)
    pendingStore.vaultBlockDraft = "서버에 먼저 저장됨"
    var operation: VaultBlockEdit?
    await pendingStore.saveLinkedBlock(replace:{ _,_,edit in
        operation = edit
        check(try record(pendingURL)?.pending == edit,"lost-response operation was durable before dispatch")
        throw URLError(.networkConnectionLost)
    },load:{ _ in source })
    pendingStore.vaultBlockDraft = "응답 뒤 새 입력"
    let pendingRestart = restart(pendingStore,pendingURL)
    check(pendingRestart.restoreLinkedBlockDraft() && pendingRestart.vaultBlockHasPendingSave &&
          pendingRestart.vaultBlockDraft == "응답 뒤 새 입력","restart retains uncertain operation separately from later typing")
    let committed = try result(operation!).note
    await pendingRestart.saveLinkedBlock(replace:{ _,_,edit in
        check(edit == operation,"restart retries the identical operation ID and immutable payload")
        return try result(edit,disposition:"reconciled")
    },load:{ _ in committed })
    check(!pendingRestart.vaultBlockHasPendingSave && pendingRestart.vaultDirty &&
          pendingRestart.vaultBlockDraft == "응답 뒤 새 입력" && pendingRestart.vaultNote == committed,
          "reconciled server result never erases newer local typing")
    let newerRestart = restart(pendingRestart,pendingURL)
    check(newerRestart.restoreLinkedBlockDraft() && newerRestart.vaultBlockDraft == "응답 뒤 새 입력" &&
          newerRestart.vaultNote == committed && !newerRestart.vaultBlockHasPendingSave,
          "another restart retains the newer draft against the confirmed server base")
    let closed = newerRestart.closeVaultEditor(discard:true)
    let cleared = try record(pendingURL) == nil
    check(closed && cleared,
          "explicit editor discard clears local recovery without a remote write")

    let staleURL = path(), stale = await setup(staleURL)
    stale.vaultBlockDraft = "보존할 입력"
    let staleRestart = restart(stale,staleURL)
    _ = staleRestart.restoreLinkedBlockDraft()
    let before = try Data(contentsOf:staleURL)
    var staleWrites = 0
    await staleRestart.saveLinkedBlock(replace:{ _,_,edit in staleWrites += 1; return try result(edit) },
        load:{ _ in note(source.text + "Mac의 새 내용") })
    let unchanged = try Data(contentsOf:staleURL) == before
    check(staleWrites == 0 && staleRestart.vaultBlockDraft == "보존할 입력" && unchanged,"changed source refuses overwrite and preserves recovery byte-for-byte")

    let failedURL = path(), failed = await setup(failedURL)
    failed.vaultBlockDraft = "저장 장벽"
    try FileManager.default.removeItem(at:failedURL)
    try FileManager.default.createDirectory(at:failedURL,withIntermediateDirectories:false)
    var failedWrites = 0
    await failed.saveLinkedBlock(replace:{ _,_,edit in failedWrites += 1; return try result(edit) },load:{ _ in source })
    check(failedWrites == 0 && !failed.vaultBlockHasPendingSave && failed.vaultBlockDraft == "저장 장벽",
          "journal IO failure stops dispatch without losing in-memory typing")

    let corruptURL = path(), corruptSource = await setup(corruptURL)
    corruptSource.vaultBlockDraft = "보존된 원본 초안"
    let intact = try Data(contentsOf:corruptURL)
    var object = try JSONSerialization.jsonObject(with:intact) as! [String:Any]
    object["sha256"] = String(repeating:"0",count:64)
    let corrupt = try JSONSerialization.data(withJSONObject:object)
    try corrupt.write(to:corruptURL)
    let refused = restart(corruptSource,corruptURL)
    let corruptUnchanged = try Data(contentsOf:corruptURL) == corrupt
    check(!refused.restoreLinkedBlockDraft() && !refused.discardLinkedBlockRecovery() && corruptUnchanged,"corrupt journal is preserved and never silently reset or transmitted")
    do {
        let envelope = try JSONDecoder().decode(VaultBlockRecoveryFile.self,from:corrupt)
        _ = try envelope.record()
        check(false,"journal checksum mismatch is rejected")
    } catch { check(true,"journal checksum mismatch is rejected") }
    let externalURL = path(), external = await setup(externalURL)
    external.vaultBlockDraft = "before replacement"
    try Data("external owner".utf8).write(to:externalURL)
    external.vaultBlockDraft = "after replacement"
    await external.saveLinkedBlock(replace:{ _,_,edit in failedWrites += 1; return try result(edit) },load:{ _ in source })
    let externalUnchanged = try Data(contentsOf:externalURL) == Data("external owner".utf8)
    check(failedWrites == 0 && externalUnchanged,
          "external journal replacement is not overwritten and cannot authorize a request")
    let discardURL = path(), discardSource = await setup(discardURL)
    discardSource.vaultBlockDraft = "의도적으로 버릴 초안"
    let discardRestart = restart(discardSource,discardURL)
    let discarded = discardRestart.discardLinkedBlockRecovery()
    let discardedRecord = try record(discardURL)
    check(discarded && discardedRecord == nil &&
          discardRestart.vaultNote == nil,"unopened recovery can be explicitly discarded without opening or modifying Obsidian")
}

@MainActor func checkExcerptAnchorReentry(_ check: (Bool,String) -> Void) async throws {
    let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!)
    let path = "Notes/anchor-reentry.md"
    let source = "첫째 문단은 그대로 둡니다.\n\n둘째 문단 e\u{301} 👩🏽‍💻\n\n셋째 문단"
    let quote = "둘째 문단 e\u{301} 👩🏽‍💻"
    func note(_ text: String, held: Bool? = nil) -> VaultNoteSnapshot {
        VaultNoteSnapshot(path:path,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"fixture",reconciliationRequired:held)
    }
    func setup(_ label: String) async -> (CanvasStore,URL) {
        let url = root.appendingPathComponent(label + ".json")
        let store = CanvasStore(noteRecoveryURL:url)
        store.scene = CanvasScene()
        store.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
        await store.openVaultNote(path,load:{_ in note(source)})
        store.vaultSelection = (source as NSString).range(of:quote)
        return (store,url)
    }
    for acknowledged in [false,true] {
        let (store,url) = await setup("ack-\(acknowledged)")
        let sceneID = store.scene.id
        var written: VaultNoteSnapshot?, puts = 0, gets = 0
        let result = await store.excerptSelectedVaultBlock(save:{p,_,text in
            puts += 1; check(p == path,"anchor submission preserves note path")
            written = note(text)
            if !acknowledged { throw URLError(.networkConnectionLost) }
            return written!
        },load:{_ in throw URLError(.timedOut)})
        let record = store.noteRecovery!
        let anchored = try VaultMarkdownBlocks(record.submittedText!).selected((record.submittedText! as NSString).range(of:quote))
        let id = anchored.blockID!
        print("TRACE ack=\(acknowledged) conflict=\(record.saveConflict?.rawValue ?? "nil") block=\(id)")
        check(result == nil && puts == 1 && store.vaultBlocked && store.scene.nodes.isEmpty,
              "failed initial GET preserves one attempted anchor and never guesses a card")
        check(record.saveConflict == .acknowledgementLost,
              "ordinary missing acknowledgement is distinct from an explicit publication conflict")
        await store.openVaultNote(path,load:{p in gets += 1; check(p == path,"readback uses the original note path"); return written!})
        check(gets == 1 && puts == 1 && store.vaultSelectedBlock?.blockID == id && store.vaultSelectedBlock?.quote == quote,
              "original reentry focuses the attempted second paragraph with one GET and zero new PUT")
        let card = await store.excerptSelectedVaultBlock(save:{_,_,_ in puts += 1; return written!},load:{_ in gets += 1; return written!})
        check(card != nil && puts == 1 && gets == 1 && store.scene.nodes.last?.vaultNote?.blockID == id &&
              store.scene.nodes.last?.vaultNote?.path == path && store.scene.id == sceneID,
              "confirmed anchor attaches the same paragraph ID and note path without another write")
        check(try JSONDecoder().decode(VaultNoteRecoveryFile.self,from:Data(contentsOf:url)).record() == nil,
              "exact submitted bytes clear only the confirmed recovery journal")
    }
    let (missing,url) = await setup("missing-anchor")
    var puts = 0, gets = 0
    _ = await missing.excerptSelectedVaultBlock(save:{_,_,_ in puts += 1; throw URLError(.networkConnectionLost)},
        load:{_ in throw URLError(.timedOut)})
    let before = missing.noteRecovery!
    await missing.openVaultNote(path,load:{_ in gets += 1; return note(source)})
    check(puts == 1 && gets == 1 && missing.vaultSelection.location == NSNotFound && missing.vaultSelectedBlock == nil,
          "missing attempted anchor cannot fall back to the first paragraph")
    check(missing.noteRecovery?.draft == before.draft && missing.noteRecovery?.sceneID == before.sceneID &&
          missing.noteRecovery?.base.path == path && missing.vaultDraft == before.draft,
          "missing anchor preserves the exact anchored draft and original recovery identity")
    _ = await missing.excerptSelectedVaultBlock(save:{_,_,text in puts += 1; return note(text)},load:{_ in gets += 1; return note(source)})
    check(puts == 1 && gets == 1 && missing.scene.nodes.isEmpty,"missing source reentry cannot create another anchor or card")
    check(try JSONDecoder().decode(VaultNoteRecoveryFile.self,from:Data(contentsOf:url)).record()?.draft == before.draft,
          "missing source keeps the attempted anchor in the durable journal")

    for conflict in [VaultSaveConflict.reconciliationRequired,.unclassified] {
        let (held,journal) = await setup("held-\(conflict.rawValue)")
        var writes = 0, reads = 0
        _ = await held.excerptSelectedVaultBlock(save:{_,_,_ in
            writes += 1
            throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:conflict.rawValue])
        },load:{_ in reads += 1; return note(source)})
        let bytes = try Data(contentsOf:journal), draft = held.vaultDraft, selection = held.vaultSelection
        await held.openVaultNote(path,load:{_ in reads += 1; return note(held.noteRecovery!.submittedText!)})
        check(writes == 1 && reads == 0 && held.vaultBlocked && held.scene.nodes.isEmpty && held.noteRecovery?.saveConflict == conflict,
              "typed or unclassified 409 cannot use same-text GET to release the held anchor")
        check(try Data(contentsOf:journal) == bytes && held.vaultDraft == draft && held.vaultSelection == selection,
              "held conflict preserves journal bytes, input and selection")
    }
}
