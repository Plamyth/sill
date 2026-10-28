import Foundation
import PencilKit
import AppKit

@MainActor final class EvidenceGate {
    var continuation: CheckedContinuation<CanvasInkTextEditing.Evidence, Never>?
    func read(_ d: PKDrawing, _ s: Set<UUID>, _ g: String, _ o: [String]) async -> CanvasInkTextEditing.Evidence {
        await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { while continuation == nil { await Task.yield() } }
    func finish(_ evidence: CanvasInkTextEditing.Evidence) { continuation!.resume(returning: evidence); continuation = nil }
}

@main struct InkGlyphChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INK_GLYPH_OUTPUT"]!)
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        precondition(FileManager.default.homeDirectoryForCurrentUser.path == home)
        var count = 0
        var failed = 0
        func check(_ ok: Bool, _ label: String) {
            count += 1
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label)")
        }
        func stroke(_ x: CGFloat, mask: NSBezierPath? = nil) -> PKStroke {
            var points: [PKStrokePoint] = []
            for i in 0..<4 {
                let offset = CGFloat(i)
                let location = CGPoint(x: x + offset * 8, y: offset * 7)
                let size = CGSize(width: offset + 2, height: offset + 3)
                let opacity: CGFloat = 0.4 + offset * 0.1
                let force: CGFloat = 0.2 + offset * 0.15
                points.append(PKStrokePoint(location: location, timeOffset: Double(i) * 0.2,
                    size: size, opacity: opacity, force: force, azimuth: 0.2, altitude: 1))
            }
            return PKStroke(ink: PKInk(.pen, color: .blue),
                path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: Double(x + 1))),
                transform: CGAffineTransform(a: 1.25, b: 0.1, c: 0.2, d: 0.8, tx: 30, ty: 50), mask: mask)
        }
        func fixture(_ text: String = "가나다", maskedTarget: Bool = false) throws -> (CanvasScene, UUID, Set<UUID>, [UUID]) {
            let mask = NSBezierPath(rect: CGRect(x: 0, y: 0, width: 500, height: 500))
            let native = PKDrawing(strokes: [stroke(10), stroke(50, mask: maskedTarget ? mask : nil),
                                             stroke(90), stroke(150, mask: mask)])
            let bytes = native.dataRepresentation()
            let restored = try PKDrawing(data: bytes)
            let ids = restored.strokes.map(\.id)
            var scene = CanvasScene()
            scene.schemaVersion = 2
            scene.drawingBase64 = bytes.base64EncodedString()
            scene.strokes = CanvasScene.nativeInkStrokes(restored)
            let node = scene.addNode(kind: .note, at: .init(x: 10, y: 20), text: text, sourceStrokeIds: Array(ids.prefix(3)))
            _ = scene.addNode(kind: .box, at: .init(x: 300, y: 20), text: "주변 요소", sourceStrokeIds: [ids[3]])
            return (scene, node, Set(ids.prefix(3)), ids)
        }
        func supplied(_ scene: CanvasScene, _ ids: [UUID], glyph: String = "나", remaining: String = "가다") -> CanvasInkTextEditing.Evidence {
            .init(wholeText: scene.nodes[0].text, matches: [[ids[1]]], targetText: glyph,
                  remainingText: remaining, otherCharacterMatches: [[[ids[0]]], [[ids[2]]]])
        }
        func refused(_ editor: CanvasInkTextEditing, _ reason: CanvasInkTextEditing.Refusal) -> Bool {
            if case .ambiguous(let actual) = editor.phase { return actual == reason }; return false
        }
        let (original, node, selection, ids) = try fixture()
        let originalBytes = try CanvasInkTextEditing.encode(original)
        let reader: CanvasInkTextEditing.ReadEvidence = { _,_,_,_ in supplied(original, ids) }
        let editor = CanvasInkTextEditing()
        await editor.propose(scene: original, nodeID: node, selection: selection,
            range: NSRange(location: 1, length: 1), isCurrent: { $0.matches(scene: original, selection: selection) }, readEvidence: reader)
        check(editor.proposal != nil, "증거주입: 유일한 한 글자와 분리된 native strokeID 대응의 삭제 제안")
        let snapshot = editor.proposal!.snapshot
        check(snapshot.sceneID == original.id && snapshot.revision == original.revision &&
              snapshot.drawingSHA256 == CanvasPacket.sha(Data(base64Encoded: original.drawingBase64)!) &&
              snapshot.selectedStrokeIDs == selection && snapshot.utf16Location == 1 && snapshot.utf16Length == 1,
              "snapshot scene/revision/drawingSHA/selection/UTF16 보존")
        let snapshotCopy = try JSONDecoder().decode(CanvasInkTextEditing.Snapshot.self,
            from: JSONEncoder().encode(snapshot))
        check(snapshotCopy == snapshot, "snapshot Codable 왕복")
        check(try CanvasInkTextEditing.encode(original) == originalBytes, "제안·미리보기는 원본을 변경하지 않음")
        let file = output.appendingPathComponent("scene.json")
        func persist(_ scene: CanvasScene) throws { try CanvasLocalFile.write(CanvasInkTextEditing.encode(scene), to: file) }
        var current = try editor.confirm(current: original, selection: selection, persist: persist)
        check(current.nodes[0].text == "가다" && current.nodes[0].sourceStrokeIds == [ids[0], ids[2]] &&
              current.strokes.map(\.id) == [ids[0], ids[2], ids[3]], "확정은 문자와 실제 target stroke만 함께 삭제")
        check(current.nodes[1] == original.nodes[1] && current.links == original.links && current.annotations == original.annotations,
              "주변 노드·관계·주석 보존")
        check(try JSONDecoder().decode(CanvasScene.self, from: CanvasLocalFile.read(file)) == current,
              "실제 CanvasLocalFile 원자 저장·JSON 재열기")
        let beforeNative = try PKDrawing(data: Data(base64Encoded: original.drawingBase64)!)
        let afterNative = try PKDrawing(data: Data(base64Encoded: current.drawingBase64)!)
        for index in [0, 2, 3] {
            let before = beforeNative.strokes[index]
            let after = afterNative.strokes.first { $0.id == before.id }!
            check(before.path.creationDate == after.path.creationDate && before.path.count == after.path.count &&
                  before.transform == after.transform && before.ink.inkType == after.ink.inkType && before.ink.color.isEqual(after.ink.color) &&
                  zip(before.path, after.path).allSatisfy {
                    $0.location == $1.location && $0.force == $1.force && $0.size == $1.size &&
                    $0.opacity == $1.opacity && $0.timeOffset == $1.timeOffset &&
                    $0.azimuth == $1.azimuth && $0.altitude == $1.altitude
                  } && before.maskedPathRanges == after.maskedPathRanges && (before.mask == nil) == (after.mask == nil),
                  "미삭제 획 \(index)의 ID·점·필압·transform·mask/range·스타일 보존")
        }
        let appliedRevision = current.revision
        current = try editor.undo(current: current, persist: persist)
        check(current.drawingBase64 == original.drawingBase64 && current.strokes == original.strokes &&
              current.nodes == original.nodes && current.revision == appliedRevision + 1,
              "Undo 원래 native 바이트·문자·출처 복원, revision은 단조 증가")
        current = try editor.redo(current: current, persist: persist)
        check(current.nodes[0].text == "가다" && current.revision == appliedRevision + 2,
              "Redo 문자·잉크를 같은 변경으로 재적용")
        var external = current
        external.nodes[1].text = "다른 담당 수정"
        do { _ = try editor.undo(current: external, persist: persist); check(false, "stale Undo 거절") }
        catch { check(error as? CanvasInkTextEditing.Refusal == .stale, "같은 revision 외부 변경도 Undo로 덮지 않음") }
        let retry = CanvasInkTextEditing()
        await retry.propose(scene: original, nodeID: node, selection: selection, range: NSRange(location: 1, length: 1),
            isCurrent: { _ in true }, readEvidence: reader)
        let savedBeforeFailure = try CanvasLocalFile.read(file)
        do {
            _ = try retry.confirm(current: original, selection: selection, persist: { _ in throw CocoaError(.fileWriteNoPermission) })
            check(false, "파일 실패 거절")
        } catch { check(try retry.proposal != nil && CanvasLocalFile.read(file) == savedBeforeFailure, "저장 실패는 미리보기·마지막 정상 파일 보존") }
        for which in ["revision", "scene", "selection", "drawing", "text"] {
            var changed = original
            var selected = selection
            switch which {
            case "revision": changed.revision += 1
            case "scene": changed.id = UUID()
            case "selection": selected = [ids[0]]
            case "drawing": changed.drawingBase64 = PKDrawing(strokes: [stroke(222)]).dataRepresentation().base64EncodedString()
            default: changed.nodes[0].text = "가나 다"
            }
            var writes = 0
            do { _ = try retry.confirm(current: changed, selection: selected, persist: { _ in writes += 1 }); check(false, which) }
            catch { check(writes == 0 && retry.proposal != nil, "\(which) stale 확정은 쓰기0·제안 보존") }
        }
        retry.cancel()
        check(try retry.proposal == nil && CanvasInkTextEditing.encode(original) == originalBytes,
              "취소 원본 불변")
        for variant in ["empty", "unknown", "multiple", "targetText", "remaining", "overlap", "noOther", "whole"] {
            let e = supplied(original, ids)
            let varied = CanvasInkTextEditing.Evidence(
                wholeText: variant == "whole" ? "다른문자" : e.wholeText,
                matches: variant == "empty" ? [] : variant == "unknown" ? [[UUID()]] : variant == "multiple" ? [[ids[1]], [ids[2]]] : e.matches,
                targetText: variant == "targetText" ? "가나" : e.targetText,
                remainingText: variant == "remaining" ? "다" : e.remainingText,
                otherCharacterMatches: variant == "overlap" ? [[[ids[0], ids[1]]], [[ids[2]]]] : variant == "noOther" ? [] : e.otherCharacterMatches)
            let refusedEditor = CanvasInkTextEditing()
            await refusedEditor.propose(scene: original, nodeID: node, selection: selection,
                range: NSRange(location: 1, length: 1), isCurrent: { _ in true }, readEvidence: { _,_,_,_ in varied })
            check(refusedEditor.proposal == nil && refused(refusedEditor, variant == "whole" ? .unsupported : .ambiguousStrokes),
                  "증거주입 \(variant) 모호 대응 거절·삭제0")
        }
        let (repeated, repeatedNode, repeatedSelection, _) = try fixture("가나나")
        var invoked = false
        await retry.propose(scene: repeated, nodeID: repeatedNode, selection: repeatedSelection,
            range: NSRange(location: 1, length: 1), isCurrent: { _ in true }, readEvidence: { _,_,_,_ in invoked = true; return supplied(original, ids) })
        check(refused(retry, .repeatedCharacter) && !invoked, "반복 글자는 검색 순서나 bbox로 소유권을 추측하지 않음")
        let (masked, maskedNode, maskedSelection, maskedIDs) = try fixture(maskedTarget: true)
        await retry.propose(scene: masked, nodeID: maskedNode, selection: maskedSelection,
            range: NSRange(location: 1, length: 1), isCurrent: { _ in true }, readEvidence: { _,_,_,_ in supplied(masked, maskedIDs) })
        check(refused(retry, .maskedTarget), "대상 mask는 지원범위 밖으로 명시 거절·원본 유지")
        var shared = original
        shared.nodes[1].sourceStrokeIds = [ids[1]]
        await retry.propose(scene: shared, nodeID: node, selection: selection,
            range: NSRange(location: 1, length: 1), isCurrent: { _ in true }, readEvidence: { _,_,_,_ in supplied(shared, ids) })
        check(refused(retry, .sharedSource), "다른 노드가 공유하는 sourceStrokeID 삭제 거절")
        for invalid in [NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 0),
                        NSRange(location: 0, length: 2), NSRange(location: -1, length: 1)] {
            await retry.propose(scene: original, nodeID: node, selection: selection, range: invalid,
                isCurrent: { _ in true }, readEvidence: reader)
            check(refused(retry, .invalidRange), "유효하지 않은 UTF16 \(invalid) 거절")
        }
        let (emoji, emojiNode, emojiSelection, emojiIDs) = try fixture("가👩‍💻다")
        await retry.propose(scene: emoji, nodeID: emojiNode, selection: emojiSelection,
            range: NSRange(location: 1, length: 5), isCurrent: { _ in true },
            readEvidence: { _,_,_,_ in supplied(emoji, emojiIDs, glyph: "👩‍💻") })
        check(retry.proposal?.remainingText == "가다", "다중 UTF16 단위 emoji도 한 Character로 삭제")
        await retry.propose(scene: emoji, nodeID: emojiNode, selection: emojiSelection,
            range: NSRange(location: 1, length: 2), isCurrent: { _ in true }, readEvidence: reader)
        check(refused(retry, .invalidRange), "ZWJ grapheme 중간 UTF16 분할 거절")
        let gate = EvidenceGate()
        let pending = Task { await retry.propose(scene: original, nodeID: node, selection: selection,
            range: NSRange(location: 1, length: 1), isCurrent: { _ in true }, readEvidence: gate.read) }
        await gate.wait()
        retry.cancel()
        await retry.propose(scene: repeated, nodeID: repeatedNode, selection: repeatedSelection,
            range: NSRange(location: 1, length: 1), isCurrent: { _ in true }, readEvidence: reader)
        gate.finish(supplied(original, ids)); await pending.value
        check(refused(retry, .repeatedCharacter), "늦은 콜백이 새 거절/요청 상태를 덮지 않음")
        await retry.propose(scene: original, nodeID: node, selection: selection,
            range: NSRange(location: 1, length: 1), isCurrent: { _ in false }, readEvidence: reader)
        check(refused(retry, .stale), "인식 뒤 live snapshot 불일치는 미리보기 전 거절")

        // 이 구간은 증거 주입 없이 실제 Apple recognizer를 호출한다.
        var nativeReports: [[String: Any]] = []
        let fixturePaths = CommandLine.arguments.dropFirst()
        for path in fixturePaths {
            let url = URL(fileURLWithPath: path)
            let bytes = try Data(contentsOf: url)
            let sourceHash = CanvasPacket.sha(bytes)
            let drawing = try PKDrawing(data: bytes)
            let strokeIDs = Set(drawing.strokes.map(\.id))
            let recognizer = PKStrokeRecognizer()
            await recognizer.updateDrawing(drawing)
            let text = await recognizer.recognizedText(strokeIDs: strokeIDs)
            let glyph = text?.first(where: { !$0.isWhitespace }).map(String.init) ?? "a"
            let evidence = await CanvasInkTextEditing.nativeEvidence(drawing, strokeIDs, glyph, [])
            check(try CanvasPacket.sha(Data(contentsOf: url)) == sourceHash, "무주입 ownfixture 원본 불변 \(url.lastPathComponent)")
            var nativeScene = CanvasScene()
            nativeScene.schemaVersion = 2
            nativeScene.drawingBase64 = bytes.base64EncodedString()
            nativeScene.strokes = CanvasScene.nativeInkStrokes(drawing)
            let nativeNode = nativeScene.addNode(kind: .note, at: .init(x: 0, y: 0), text: text ?? "a", sourceStrokeIds: drawing.strokes.map(\.id))
            let nativeEditor = CanvasInkTextEditing()
            await nativeEditor.propose(scene: nativeScene, nodeID: nativeNode, selection: strokeIDs,
                range: NSRange(location: 0, length: (text?.first.map(String.init) ?? "a").utf16.count),
                isCurrent: { $0.matches(scene: nativeScene, selection: strokeIDs) })
            let outcome: String
            switch nativeEditor.phase {
            case .preview: outcome = "preview"
            case .ambiguous(let reason): outcome = reason.rawValue
            default: outcome = "no_proposal"
            }
            nativeReports.append(["fixture": url.lastPathComponent, "sourceSHA256": sourceHash,
                "strokeCount": drawing.strokes.count, "recognitionText": text ?? NSNull(),
                "query": glyph, "searchMatchCount": evidence.matches.count,
                "targetStrokeCounts": evidence.matches.map(\.count), "productOutcome": outcome,
                "evidenceInjected": false, "sensorInput": false])
            check(nativeEditor.proposal == nil || nativeEditor.proposal?.snapshot.drawingSHA256 == sourceHash,
                  "무주입 native 결과는 원본 snapshot에 묶이며 미지원 성공으로 위조하지 않음")
        }
        try JSONSerialization.data(withJSONObject: nativeReports, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-recognizer.json"), options: .atomic)
        #if INK_GLYPH_INTEGRATION
        let store = CanvasStore(defaults: UserDefaults(suiteName: "glyph-" + UUID().uuidString)!)
        try store.importScene(original)
        store.saveNow()
        store.setInkSelection(selection)
        let linked = CanvasInkTextEditing()
        await store.proposeInkTextDeletion(range: NSRange(location: 1, length: 1), editing: linked, readEvidence: reader)
        check(linked.proposal != nil && store.scene == original, "실제 patched Store 제안·미리보기 경로")
        check(store.confirmInkTextDeletion(linked), "실제 patched Store 확정·persistScene")
        let reopened = CanvasStore()
        check(reopened.scene.nodes[0].text == "가다" && reopened.scene == store.scene,
              "새 실제 Store가 파일에서 문자·획 함께 재열기")
        check(store.undoInkTextDeletion(linked), "실제 patched Store Undo")
        check(CanvasStore().scene.drawingBase64 == original.drawingBase64 && CanvasStore().scene.nodes == original.nodes,
              "실제 Store Undo의 원본 바이트·본문 파일 readback")
        check(store.undoInkTextDeletion(linked, redo: true) && CanvasStore().scene.nodes[0].text == "가다",
              "실제 Store Redo·새 Store readback")
        for change in ["selection", "scene", "mode", "trace"] {
            let value = CanvasStore(defaults: UserDefaults(suiteName: "glyph-aba-" + UUID().uuidString)!)
            try value.importScene(original)
            value.setInkSelection(selection)
            let delayed = CanvasInkTextEditing(), delay = EvidenceGate()
            let task = Task { await value.proposeInkTextDeletion(range: NSRange(location: 1, length: 1),
                editing: delayed, readEvidence: delay.read) }
            await delay.wait()
            switch change {
            case "selection": value.setInkSelection([ids[0]]); value.setInkSelection(selection)
            case "scene": value.scene.id = UUID(); value.scene = original; value.setInkSelection(selection)
            case "mode": value.mode = .select; value.mode = .lasso; value.setInkSelection(selection)
            default:
                let owner = UUID(); value.setPencilTraceActive(true, owner: owner); value.setPencilTraceActive(false, owner: owner)
            }
            delay.finish(supplied(original, ids)); await task.value
            check(delayed.proposal == nil && value.scene == original, "실제 Store \(change) ABA는 옛 콜백을 무효화")
            value.saveNow()
        }
        // 아래 Files 원본·복구본 경계도 실제 Store와 실제 파일을 사용한다.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        let filesFolder = output.appendingPathComponent("selected-files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        let files = CanvasFileWorkspace(folder: filesFolder, requiresScope: false)
        _ = try files.save(original, preview: png, expected: nil)
        let binding = CanvasFileWorkspace.Binding(bookmark: try filesFolder.bookmarkData(options: .minimalBookmark,
            includingResourceValuesForKeys: nil, relativeTo: nil), sceneID: original.id,
            savedSceneSHA: try CanvasFileWorkspace.sceneSHA(original))
        try CanvasLocalFile.write(CanvasFileWorkspace.bytes(original), to: CanvasRuntime.stateURL(.scene))
        try CanvasLocalFile.write(JSONEncoder().encode(binding), to: CanvasRuntime.stateURL(.workspace))
        let fileStore = CanvasStore()
        fileStore.filePreview = { _ in png }
        check(fileStore.scene == original && fileStore.fileWorkspaceCanSync, "Files 원본 binding과 합성 fixture 정상 복원")
        fileStore.setInkSelection(selection)
        let fileEditor = CanvasInkTextEditing()
        await fileStore.proposeInkTextDeletion(range: NSRange(location: 1, length: 1), editing: fileEditor, readEvidence: reader)
        let beforeFileToken = try files.load(original.id).token
        check(fileStore.confirmInkTextDeletion(fileEditor) && !fileStore.fileWorkspaceCanSync &&
              fileStore.fileWorkspaceState == .pending && fileStore.status.contains("미저장") && fileStore.status.contains("동기화 대기"),
              "글자 삭제 cache 확정은 Files 저장 성공으로 표시하지 않고 relay 전송 차단")
        try CanvasInkTextEditing.encode(original).write(to: output.appendingPathComponent("glyph-before.json"))
        try CanvasInkTextEditing.encode(fileStore.scene).write(to: output.appendingPathComponent("glyph-after.json"))
        await fileStore.saveFileWorkspace()
        let saved = try files.load(original.id)
        check(fileStore.fileWorkspaceState == .ready && fileStore.fileWorkspaceCanSync && saved.scene == fileStore.scene &&
              saved.scene.id == original.id && saved.scene.revision == original.revision + 1 && saved.token != beforeFileToken,
              "Files 원본 세대 저장·ID/revision·본문/획 readback 이후 relay 허용")
        let head = try JSONDecoder().decode(CanvasFileWorkspace.Head.self,
            from: Data(contentsOf: files.documentURL(original.id).appendingPathComponent("current.json")))
        let drawingURL = files.documentURL(original.id).appendingPathComponent("revisions/" + head.generation.uuidString.lowercased() + "/drawing.pkdrawing")
        check(try Data(contentsOf: drawingURL) == Data(base64Encoded: fileStore.scene.drawingBase64)!, "Files drawing.pkdrawing이 실제 확정 native 원본과 동일")
        let fileRestart = CanvasStore()
        fileRestart.filePreview = { _ in png }
        check(fileRestart.scene == saved.scene && fileRestart.fileWorkspaceCanSync, "새 실제 Store가 선택 Files 원본의 한 글자 삭제 결과 재열기")
        check(fileRestart.undoInkTextDeletion(fileEditor), "Files 원본에서도 문자/획 단위 Undo")
        await fileRestart.saveFileWorkspace()
        check(try files.load(original.id).scene.nodes == original.nodes, "Undo Files 재저장·원문 readback")
        try CanvasInkTextEditing.encode(fileRestart.scene).write(to: output.appendingPathComponent("glyph-undo.json"))
        let revisions = files.documentURL(original.id).appendingPathComponent("revisions")
        let lastHead = try Data(contentsOf: files.documentURL(original.id).appendingPathComponent("current.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: revisions.path)
        check(fileRestart.undoInkTextDeletion(fileEditor, redo: true), "권한 실패 전 변경은 미저장 복구본에만 반영")
        await fileRestart.saveFileWorkspace()
        check(fileRestart.fileWorkspaceState == .blocked && !fileRestart.fileWorkspaceCanSync &&
              fileRestart.fileWorkspaceStatus.contains("미저장") && !fileRestart.status.contains("저장 완료"),
              "실제 외부폴더 실패는 blocked·미저장·동기화 차단")
        check(try Data(contentsOf: files.documentURL(original.id).appendingPathComponent("current.json")) == lastHead,
              "폴더 실패는 기존 원본의 current.json을 바꾸지 않음")
        check(try JSONDecoder().decode(CanvasScene.self, from: CanvasLocalFile.read(CanvasRuntime.stateURL(.scene))) == fileRestart.scene,
              "폴더 실패에도 한 글자 삭제 미저장 캐시가 보존됨")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: revisions.path)
        fileRestart.retryFileWorkspaceSave(); await fileRestart.saveFileWorkspace()
        check(fileRestart.fileWorkspaceCanSync, "명시 재시도로 같은 Files 원본 저장·차단 해제")
        let stable = try files.load(original.id)
        var remoteScene = stable.scene
        remoteScene.nodes[1].text = "외부 원본 수정"; remoteScene.revision += 1
        _ = try files.save(remoteScene, preview: png, expected: stable.token)
        check(fileRestart.undoInkTextDeletion(fileEditor), "다른 원본 변경은 local Undo 이후 Files CAS에서 대조")
        let pendingScene = fileRestart.scene
        await fileRestart.saveFileWorkspace()
        check(fileRestart.fileWorkspaceState == .blocked && !fileRestart.fileWorkspaceCanSync && fileRestart.scene == pendingScene,
              "외부 Files CAS 충돌은 pending 입력을 유지하고 relay 차단")
        check(try files.load(original.id).scene == remoteScene, "glyph CAS 실패가 외부 원본을 덮지 않음")
        fileRestart.setInkSelection(selection)
        let deniedEdit = CanvasInkTextEditing()
        await fileRestart.proposeInkTextDeletion(range: NSRange(location: 1, length: 1), editing: deniedEdit, readEvidence: reader)
        check(deniedEdit.proposal == nil && fileRestart.scene == pendingScene, "blocked 원본에서는 새 glyph 삭제 제안도 차단")
        #endif
        let summary: [String: Any] = ["checks": count, "failed": failed, "nativeRecognizerInjected": false,
            "policyAndStoreEvidenceInjected": true, "physicalPencilAccepted": false,
            "deviceOrHostEffects": 0]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("summary.json"), options: .atomic)
        print("INK_GLYPH_CHECKS total=\(count) failed=\(failed)")
        if failed > 0 { exit(1) }
    }
}
