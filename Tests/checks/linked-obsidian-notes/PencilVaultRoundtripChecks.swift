import Foundation
import PencilKit
import AppKit

private struct PencilVaultReply<Value: Decodable>: Decodable {
    let ok: Bool
    let value: Value?
    let status: Int?
}

private struct PencilVaultFailure: Error { let status: Int }

private struct PencilVaultBridge {
    func run<Value: Decodable>(_ request: [String: Any], as: Value.Type) throws -> Value {
        let environment = ProcessInfo.processInfo.environment
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment["PENCIL_NODE"]!)
        process.arguments = [environment["PENCIL_VAULT_HELPER"]!]
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        let response = try JSONDecoder().decode(PencilVaultReply<Value>.self, from: bytes)
        guard response.ok, let value = response.value else { throw PencilVaultFailure(status: response.status ?? 500) }
        return value
    }

    func note(_ path: String) throws -> VaultNoteSnapshot {
        try run(["operation":"readNote", "path":path], as: VaultNoteSnapshot.self)
    }

    func saveNote(_ path: String, _ sha: String?, _ text: String) throws -> VaultNoteSnapshot {
        try run(["operation":"saveNote", "path":path, "baseSha256":sha as Any? ?? NSNull(), "text":text],
                as: VaultNoteSnapshot.self)
    }

    func canvas(_ id: UUID) throws -> CanvasRelay.VaultCanvas {
        try run(["operation":"readCanvas", "id":id.uuidString], as: CanvasRelay.VaultCanvas.self)
    }

    func saveCanvas(_ scene: CanvasScene, png: Data, sha: String?) throws -> CanvasRelay.VaultCanvasSaved {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try run(["operation":"saveCanvas", "id":scene.id.uuidString, "revision":scene.revision,
                 "scene":encoder.encode(scene).base64EncodedString(), "png":png.base64EncodedString(),
                 "baseSha256":sha as Any? ?? NSNull()], as: CanvasRelay.VaultCanvasSaved.self)
    }
}

@MainActor
func checkPencilVaultRoundtrip(_ check: (Bool, String) -> Void) async throws {
    let bridge = PencilVaultBridge()
    let path = "펜 편집 자동 왕복.md"
    let original = "# 자동 검증\r\n\r\n가구\r\ne\u{301} 👩🏽‍💻\r\n"
    let base = try bridge.saveNote(path, nil, original)
    func store(journal: URL? = nil) -> CanvasStore {
        let journal = journal ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName:journal.appendingPathComponent("preferences").path)!
        let value = CanvasStore(noteRecoveryURL:journal.appendingPathComponent("note.json"),defaults:defaults)
        value.setNoteConnection(address:"http://fixture.invalid",token:"fixture-only")
        return value
    }
    let editor = store()
    await editor.openVaultNote(path) { try bridge.note($0) }
    let range = (original as NSString).range(of:"가구")
    let edit = CanvasPencilTextCorrection.replacement(in:original, selection:range, with:"가방")!
    editor.vaultDraft = (original as NSString).replacingCharacters(in:edit.range, with:edit.replacement)
    await editor.saveVaultNote { try bridge.saveNote($0, $1, $2) }
    let saved = try PencilVaultBridge().note(path)
    check(saved.text == original.replacingOccurrences(of:"가구",with:"가방"),
          "actual correction output persists in Obsidian Markdown without added spaces or full stop")
    check(!editor.vaultDirty && editor.noteRecovery == nil && editor.vaultNote?.sha256 == saved.sha256,
          "Store save consumes actual vault SHA and clears only the saved draft")
    _ = editor.closeVaultEditor()
    let reopened = store()
    await reopened.openVaultNote(path) { try bridge.note($0) }
    check(reopened.vaultDraft == saved.text && reopened.vaultNote?.sha256 == saved.sha256,
          "a new Store and a new ObsidianVault process reopen the corrected word")
    let macText = saved.text.replacingOccurrences(of:"가방",with:"Mac에서 보완한 가방")
    let mac = try bridge.saveNote(path, saved.sha256, macText)
    await reopened.refreshVaultNotes { try bridge.note($0) }
    check(reopened.vaultDraft == macText && reopened.vaultNote?.sha256 == mac.sha256,
          "external Markdown edit is received by the open Store through production refresh")
    let staleEditor = store()
    await staleEditor.openVaultNote(path) { try bridge.note($0) }
    staleEditor.vaultDraft = macText + "보존할 별도 입력"
    reopened.vaultDraft += "보존할 iPad 초안"
    let localDraft = reopened.vaultDraft
    let newer = try bridge.saveNote(path, mac.sha256, macText + "Mac의 동시 입력")
    await reopened.refreshVaultNotes { try bridge.note($0) }
    check(reopened.vaultDraft == localDraft && reopened.vaultDirty,
          "external refresh does not replace an unsaved local Pencil draft")
    var staleWrites = 0, actualConflicts = 0
    await staleEditor.saveVaultNote { path, sha, text in
        staleWrites += 1
        do { return try bridge.saveNote(path,sha,text) }
        catch let error as PencilVaultFailure {
            if error.status == 409 { actualConflicts += 1 }
            throw error
        }
    }
    check(staleWrites == 1 && actualConflicts == 1 && staleEditor.vaultBlocked && staleEditor.vaultDirty,
          "an unblocked Store submits once, receives actual vault CAS409 and preserves its draft")
    var blockedWrites = 0
    await reopened.saveVaultNote { path, sha, text in
        blockedWrites += 1
        return try bridge.saveNote(path,sha,text)
    }
    let conflictNote = try bridge.note(path)
    check(blockedWrites == 0 && reopened.vaultDraft == localDraft && reopened.vaultBlocked && conflictNote.sha256 == newer.sha256,
          "a Store already blocked by external refresh refuses submission and preserves both edits")

    let points = (0..<5).map { i in PKStrokePoint(location:CGPoint(x:20 + i * 25,y:40),
        timeOffset:Double(i) * 0.1,size:CGSize(width:5,height:5),opacity:1,force:0.5,azimuth:0,altitude:1) }
    let islands = NSBezierPath(rect:CGRect(x:15,y:10,width:35,height:60))
    islands.appendRect(CGRect(x:90,y:10,width:35,height:60))
    let stroke = PKStroke(ink:PKInk(.pen,color:.white),
        path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)),
        transform:CGAffineTransform(translationX:8,y:12),mask:islands)
    let drawing = PKDrawing(strokes:[stroke])
    let canvas = store()
    canvas.scene = CanvasScene()
    canvas.scene.width = 256
    canvas.scene.height = 192
    canvas.updateDrawing(drawing)
    _ = canvas.scene.addNode(kind:.note,at:CanvasPoint(x:140,y:20),text:"iPad 글자 교정 결과 가방")
    let firstScene = canvas.scene
    let image = drawing.image(from:CGRect(x:0,y:0,width:256,height:192),scale:1)
    let png = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
    check(png.count > 100 && firstScene.strokes[0].visibility?.kind == .masked,
          "native PencilKit fixture contains rendered ink and partial-mask geometry")
    let firstSave = try bridge.saveCanvas(firstScene,png:png,sha:nil)
    let firstRead = try PencilVaultBridge().canvas(firstScene.id)
    let firstBytes = Data(base64Encoded:firstRead.sceneJSONBase64)!
    let firstDecoded = try JSONDecoder().decode(CanvasScene.self,from:firstBytes)
    let restored = store()
    try restored.importScene(firstDecoded)
    check(restored.scene == firstScene && firstRead.noteSha256 == firstSave.noteSha256,
          "actual Obsidian scene JSON is reimported with the same scene and source identities")
    let nativeStroke = restored.drawing.strokes[0]
    check(restored.scene.drawingBase64 == firstScene.drawingBase64 && restored.scene.strokes == firstScene.strokes,
          "the frozen native source bytes and complete structured erased visibility survive unchanged")
    check(nativeStroke.id == stroke.id && nativeStroke.transform == stroke.transform && nativeStroke.mask != nil &&
          nativeStroke.maskedPathRanges == stroke.maskedPathRanges && nativeStroke.path.count == stroke.path.count &&
          zip(nativeStroke.path,stroke.path).allSatisfy({ a,b in
              a.location == b.location && a.size == b.size && a.force == b.force && a.opacity == b.opacity
          }), "decoded native stroke retains IDs, transform, path, pressure and partial-mask ranges")
    func pixels(_ image: NSImage) -> [UInt8] {
        let representation = NSBitmapImageRep(data:image.tiffRepresentation!)!
        let context = CGContext(data:nil,width:256,height:192,bitsPerComponent:8,bytesPerRow:256 * 4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(representation.cgImage!,in:CGRect(x:0,y:0,width:256,height:192))
        return Array(UnsafeBufferPointer(start:context.data!.assumingMemoryBound(to:UInt8.self),count:256 * 192 * 4))
    }
    let reopenedImage = restored.drawing.image(from:CGRect(x:0,y:0,width:256,height:192),scale:1)
    check(pixels(image) == pixels(reopenedImage),
          "native ink pixels including the erased gap remain identical after Obsidian reopen")
    var changedScene = firstDecoded
    changedScene.revision += 1
    changedScene.nodes[0].text = "에이전트가 Obsidian 자료를 보완했습니다"
    let changedSave = try bridge.saveCanvas(changedScene,png:png,sha:firstSave.noteSha256)
    let changedRead = try bridge.canvas(firstScene.id)
    let changed = try JSONDecoder().decode(CanvasScene.self,from:Data(base64Encoded:changedRead.sceneJSONBase64)!)
    try restored.importScene(changed)
    check(restored.scene.nodes[0].text == changedScene.nodes[0].text &&
          restored.scene.drawingBase64 == firstScene.drawingBase64 && changedRead.noteSha256 == changedSave.noteSha256,
          "external structured edit returns to the Store without replacing original ink")
    do {
        _ = try bridge.saveCanvas(firstScene,png:png,sha:firstSave.noteSha256)
        check(false,"stale scene save must be refused")
    } catch let error as PencilVaultFailure {
        check(error.status == 409,"actual Obsidian scene CAS refuses the old scene version")
    }
    let afterConflict = try bridge.canvas(firstScene.id)
    check(afterConflict.sceneSha256 == changedRead.sceneSha256,
          "conflict readback keeps the externally edited scene")
    _ = try bridge.saveNote(path,newer.sha256,original)
    _ = try bridge.saveCanvas(firstScene,png:png,sha:afterConflict.noteSha256)
    let resetNote = try bridge.note(path), resetCanvas = try bridge.canvas(firstScene.id)
    check(resetNote.text == base.text && resetCanvas.sceneSha256 == firstRead.sceneSha256,
          "owned test note and scene return to their original fixture values")
    let reviewPath = "복습 카드 자동 왕복.md"
    let reviewSource = ["\u{feff}# 원문 👩🏽‍💻 e\u{301}","그대로 둘 문단 ^keep","",
        "<!-- ccr-review-card:v1 {\"cardID\":\"11111111-1111-4111-8111-111111111111\",\"dueAt\":null,\"eventID\":null,\"ratedAt\":null} -->",
        "<!-- ccr-review-front -->","가방의 안에는 무엇이 있나요?","<!-- ccr-review-back -->",
        "정답 A: e\u{301} 👩🏽‍💻","<!-- /ccr-review-card -->","","마지막 원문 문단"].joined(separator:"\r\n")
    _ = try bridge.saveNote(reviewPath,nil,reviewSource)
    let reviewStore = store()
    await reviewStore.openVaultNote(reviewPath) { try bridge.note($0) }
    let session = reviewStore.beginVaultReview()!
    var ratingWrites = 0
    let rated = await reviewStore.rateVaultReviewGood(session,
        injectedDate:Date(timeIntervalSince1970:1_800_000_000), save:{ path,sha,text in
            ratingWrites += 1
            return try bridge.saveNote(path,sha,text)
        }, load:{ try bridge.note($0) })
    let ratingNote = try PencilVaultBridge().note(reviewPath)
    let parsed = try VaultReviewCard.parse(ratingNote.text)!
    check(rated && ratingWrites == 1 && parsed.metadata.ratedAt == 1_800_000_000 &&
          parsed.metadata.dueAt == 1_800_086_400 && parsed.metadata.eventID == session.id.uuidString.lowercased(),
          "review grade is saved once and read back with the same event and explicit 24-hour due time")
    check(parsed.front == session.card.front && parsed.back == session.card.back &&
          ratingNote.text.hasPrefix("\u{feff}# 원문 👩🏽‍💻 e\u{301}\r\n그대로 둘 문단 ^keep\r\n") &&
          ratingNote.text.hasSuffix("\r\n마지막 원문 문단"),
          "review metadata update preserves front/back and surrounding Unicode/CRLF source bytes")
    let reopenedReview = store()
    await reopenedReview.openVaultNote(reviewPath) { try bridge.note($0) }
    let reopenedSession = reopenedReview.beginVaultReview()!
    check(reopenedSession.card.metadata == parsed.metadata && reopenedSession.card.front == parsed.front &&
          reopenedSession.card.back == parsed.back,
          "new Store and actual vault process reopen the same review card and due date")
    let changedAnswer = ratingNote.text.replacingOccurrences(of:"정답 A:",with:"정답 B:")
    let answerNote = try bridge.saveNote(reviewPath,ratingNote.sha256,changedAnswer)
    await reopenedReview.refreshVaultNotes { try bridge.note($0) }
    let answerSession = reopenedReview.beginVaultReview()!
    check(answerSession.card.back.contains("정답 B:") && answerSession.card.metadata == parsed.metadata,
          "external Obsidian answer edit is received while preserving the existing review schedule")
    let duplicate = await reviewStore.rateVaultReviewGood(session,
        injectedDate:Date(timeIntervalSince1970:1_800_000_010), save:{ path,sha,text in
            ratingWrites += 1
            return try bridge.saveNote(path,sha,text)
        }, load:{ try bridge.note($0) })
    let afterDuplicate = try bridge.note(reviewPath)
    check(!duplicate && ratingWrites == 1 && afterDuplicate.sha256 == answerNote.sha256,
          "late duplicate review callback does not submit a second grade or overwrite the external answer")

    let lostJournal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let lostStore = store(journal:lostJournal)
    await lostStore.openVaultNote(reviewPath) { try bridge.note($0) }
    let lostSession = lostStore.beginVaultReview()!
    var lostWrites = 0
    let lostResult = await lostStore.rateVaultReviewGood(lostSession,
        injectedDate:Date(timeIntervalSince1970:1_800_000_100), save:{ path,sha,text in
            lostWrites += 1
            _ = try bridge.saveNote(path,sha,text)
            throw URLError(.networkConnectionLost)
        }, load:{ try bridge.note($0) })
    let committedReview = try bridge.note(reviewPath)
    check(!lostResult && lostWrites == 1 && lostStore.noteRecovery?.submittedText == committedReview.text,
          "lost grade response preserves the exact submitted event and source in the existing journal")
    let committedCard = try VaultReviewCard.parse(committedReview.text)!
    let recoveredStore = store(journal:lostJournal)
    recoveredStore.scene = lostStore.scene
    await recoveredStore.restoreNoteDraft { try bridge.note($0) }
    check(lostWrites == 1 && recoveredStore.noteRecovery == nil && recoveredStore.vaultNote?.sha256 == committedReview.sha256 &&
          committedCard.metadata.eventID == lostSession.id.uuidString.lowercased(),
          "actual vault readback reconciles the committed grade without a new event or duplicate write")
    _ = try bridge.saveNote(reviewPath,committedReview.sha256,reviewSource)
    check(try bridge.note(reviewPath).text == reviewSource,
          "owned review fixture returns to the exact unrated source")
    print("SCOPE actual Store + PencilKit + ObsidianVault file roundtrip; no HTTP, UI, device or physical Pencil input")
}
