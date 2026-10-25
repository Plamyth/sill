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
    func store() -> CanvasStore {
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
    print("SCOPE actual Store + PencilKit + ObsidianVault file roundtrip; no HTTP, UI, device or physical Pencil input")
}
