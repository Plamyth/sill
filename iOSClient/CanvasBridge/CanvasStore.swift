import Foundation
import PencilKit
import SwiftUI

enum CanvasMode: String, CaseIterable {
    case pen = "그리기"
    case eraser = "지우기"
    case lasso = "영역 선택"
    case select = "요소 이동"
}

@MainActor
final class CanvasStore: ObservableObject {
    @Published var scene = CanvasScene() {
        didSet {
            if oldValue.id != scene.id { invalidateNoteScene() }
            else if let context = noteContext, !noteContextIsCurrent(context) { invalidateNoteRequests() }
            handwritingRequest = nil
            scheduleSave()
        }
    }
    @Published var mode: CanvasMode = .pen {
        didSet { handwritingRequest = nil }
    }
    @Published var selectedNode: UUID? {
        didSet { handwritingRequest = nil }
    }
    @Published var status = "Pencil로 그린 뒤 구조를 확인하세요."
    @Published var proposalText = "" {
        didSet { handwritingRequest = nil }
    }
    @Published var proposedNode: UUID? {
        didSet { handwritingRequest = nil }
    }
    @Published var displayedVoice: VoiceSession?
    @Published private(set) var outbox = CanvasOutbox()
    @Published var sendBusy = false
    private var outboxReadable = true
    @Published var packet: PacketReceipt?
    @Published var viewport = CanvasViewport()
    var zoom: Double { viewport.zoom }
    var pan: CGSize { viewport.pan }
    var drawing = PKDrawing() {
        didSet { handwritingRequest = nil }
    }
    var linkStart: UUID?
    private var saveTask: Task<Void,Never>?
    private var handwritingRequest: UUID?
    @Published private(set) var vaultNote: VaultNoteSnapshot?
    @Published var vaultDraft = "" {
        didSet { noteEditGeneration &+= 1 }
    }
    @Published var vaultStatus = ""
    @Published private(set) var vaultSaving = false
    @Published private(set) var vaultLoading = false
    @Published private(set) var vaultBlocked = false
    private var noteAddress = ""
    private var noteToken = ""
    private var noteConnectionGeneration: UInt64 = 0
    private var noteSceneGeneration: UInt64 = 0
    private var noteEditorGeneration: UInt64 = 0
    private var noteEditGeneration: UInt64 = 0
    private var noteRequest: UUID?
    private var noteReadSequence: UInt64 = 0
    private var acceptedNoteReads: [String:UInt64] = [:]
    private struct NoteContext: Equatable {
        let sceneID: UUID
        let sceneGeneration: UInt64
        let connectionGeneration: UInt64
        let editorGeneration: UInt64
        let path: String
        let nodeID: UUID?
    }
    private var noteContext: NoteContext?

    var vaultDirty: Bool { !vaultDraft.utf8.elementsEqual((vaultNote?.text ?? "").utf8) }
    var vaultCanSave: Bool {
        vaultNote != nil && vaultDirty && !vaultSaving && !vaultLoading && !vaultBlocked &&
        noteContext.map(noteContextIsCurrent) == true
    }
    var vaultCanAttach: Bool {
        vaultNote != nil && !vaultDirty && !vaultSaving && !vaultLoading && !vaultBlocked &&
        noteContext.map(noteContextIsCurrent) == true
    }

    func setNoteConnection(address: String, token: String) {
        guard address != noteAddress || token != noteToken else { return }
        noteAddress = address
        noteToken = token
        noteConnectionGeneration &+= 1
        invalidateNoteRequests()
    }

    private func invalidateNoteRequests() {
        noteRequest = nil
        acceptedNoteReads.removeAll()
        vaultLoading = false
        vaultSaving = false
        if vaultNote != nil {
            vaultBlocked = true
            vaultStatus = "장면 또는 연결이 바뀌었습니다. 입력은 보존했으며 원본을 다시 열어야 합니다."
        }
    }

    private func invalidateNoteScene() {
        noteSceneGeneration &+= 1
        invalidateNoteRequests()
    }

    private func noteContextIsCurrent(_ context: NoteContext) -> Bool {
        guard context.sceneID == scene.id, context.sceneGeneration == noteSceneGeneration,
              context.connectionGeneration == noteConnectionGeneration,
              context.editorGeneration == noteEditorGeneration, !noteToken.isEmpty else { return false }
        if let id = context.nodeID {
            guard let ref = scene.nodes.first(where: { $0.id == id })?.vaultNote,
                  ref.path == context.path, ref.relayAddress == noteAddress else { return false }
        }
        return true
    }

    @discardableResult
    func closeVaultEditor(discard: Bool = false) -> Bool {
        guard !vaultSaving, !vaultDirty || discard else {
            vaultStatus = vaultSaving ? "저장 결과를 기다려 주세요. 입력은 유지됩니다." :
                "저장하지 않은 입력이 있습니다. 저장하거나 입력 버리기를 선택하세요."
            return false
        }
        noteEditorGeneration &+= 1
        noteRequest = nil
        noteContext = nil
        vaultNote = nil
        vaultDraft = ""
        vaultLoading = false
        vaultBlocked = false
        return true
    }

    func openVaultNote(_ path: String, nodeID: UUID? = nil,
                       load: (String) async throws -> VaultNoteSnapshot) async {
        guard !vaultDirty, !vaultSaving else {
            vaultStatus = "현재 입력을 먼저 저장하거나 명시적으로 버려 주세요."
            return
        }
        guard VaultNoteReference.validPath(path), !noteToken.isEmpty else {
            vaultStatus = "노트 경로 또는 Mac 연결을 확인하세요."
            return
        }
        let linkedNodeID = nodeID ?? (noteContext?.path == path ? noteContext?.nodeID : nil)
        noteEditorGeneration &+= 1
        let context = NoteContext(sceneID:scene.id,sceneGeneration:noteSceneGeneration,
            connectionGeneration:noteConnectionGeneration,editorGeneration:noteEditorGeneration,
            path:path,nodeID:linkedNodeID)
        guard noteContextIsCurrent(context) else {
            vaultStatus = "연결한 노트의 경로 또는 서버가 바뀌었습니다. 자동 재연결하지 않았습니다."
            return
        }
        noteContext = context
        vaultNote = nil
        vaultDraft = ""
        let request = UUID()
        let editGeneration = noteEditGeneration
        noteRequest = request
        noteReadSequence &+= 1
        let readSequence = noteReadSequence
        vaultLoading = true
        vaultBlocked = false
        defer {
            if noteRequest == request {
                vaultLoading = false
                noteRequest = nil
            }
        }
        do {
            let note = try await load(path).validated(at:path)
            guard !Task.isCancelled, noteRequest == request, noteContext == context,
                  noteContextIsCurrent(context), noteEditGeneration == editGeneration,
                  readSequence >= acceptedNoteReads[path,default:0] else { return }
            acceptedNoteReads[path] = readSequence
            vaultNote = note
            vaultDraft = note.text
            vaultLoading = false
            noteRequest = nil
            vaultStatus = "Mac Obsidian 원본을 열었습니다."
            refreshNoteCache(note)
        } catch {
            guard !Task.isCancelled, noteRequest == request, noteContext == context,
                  noteContextIsCurrent(context) else { return }
            vaultLoading = false
            noteRequest = nil
            vaultBlocked = true
            vaultStatus = "원본을 열지 못했습니다: \(error.localizedDescription). 자동 생성하지 않습니다."
        }
    }

    func saveVaultNote(save: (String, String, String) async throws -> VaultNoteSnapshot) async {
        guard vaultCanSave, let context = noteContext, let base = vaultNote else { return }
        let request = UUID()
        let submitted = vaultDraft
        let editGeneration = noteEditGeneration
        noteRequest = request
        vaultSaving = true
        defer {
            if noteRequest == request {
                vaultSaving = false
                noteRequest = nil
                vaultBlocked = true
            }
        }
        do {
            let saved = try await save(base.path,base.sha256,submitted).validated(at:base.path)
            guard saved.text.utf8.elementsEqual(submitted.utf8) else { throw URLError(.badServerResponse) }
            guard !Task.isCancelled, noteRequest == request, noteContext == context,
                  noteContextIsCurrent(context), vaultNote?.sha256 == base.sha256 else { return }
            noteReadSequence &+= 1
            acceptedNoteReads[base.path] = noteReadSequence
            vaultNote = saved
            if noteEditGeneration == editGeneration { vaultDraft = saved.text }
            vaultSaving = false
            noteRequest = nil
            refreshNoteCache(saved)
            vaultStatus = vaultDirty ? "제출한 내용은 저장됐습니다. 이후 입력은 아직 저장하지 않았습니다." :
                "Mac Obsidian 원본에 저장했습니다."
        } catch {
            guard !Task.isCancelled, noteRequest == request, noteContext == context,
                  noteContextIsCurrent(context) else { return }
            vaultSaving = false
            noteRequest = nil
            vaultBlocked = true
            vaultStatus = "저장 실패 또는 결과 미확인: \(error.localizedDescription). 입력을 보존했습니다. 원본을 다시 확인하세요."
        }
    }

    @discardableResult
    func attachOpenedVaultNote() -> UUID? {
        guard vaultCanAttach, let note = vaultNote else { return nil }
        let preview = note.preview
        let id = scene.addNode(kind:.note,at:CanvasPoint(x:700-pan.width,y:430-pan.height),text:preview)
        scene.nodes[scene.nodes.count - 1].vaultNote = VaultNoteReference(
            path:note.path,sha256:note.sha256,relayAddress:noteAddress,cacheTruncated:preview != note.text)
        selectedNode = id
        mode = .select
        vaultStatus = "원본 노트를 캔버스에 연결했습니다. 표시 텍스트는 저장된 원본의 캐시입니다."
        return id
    }

    private func refreshNoteCache(_ note: VaultNoteSnapshot, expected: [UUID:VaultNoteReference]? = nil) {
        var next = scene
        let preview = note.preview
        for index in next.nodes.indices {
            guard var ref = next.nodes[index].vaultNote, ref.path == note.path,
                  ref.relayAddress == noteAddress,
                  expected.map({ $0[next.nodes[index].id] == ref }) ?? true else { continue }
            ref.sha256 = note.sha256
            ref.cacheTruncated = preview != note.text
            next.nodes[index].vaultNote = ref
            next.nodes[index].text = preview
        }
        guard next != scene else { return }
        next.revision += 1
        scene = next
    }

    func refreshVaultNotes(load: (String) async throws -> VaultNoteSnapshot) async {
        guard !noteToken.isEmpty else { return }
        let sceneID = scene.id, sceneGeneration = noteSceneGeneration
        let connectionGeneration = noteConnectionGeneration
        let references = scene.nodes.reduce(into:[UUID:VaultNoteReference]()) { result,node in
            if let reference = node.vaultNote { result[node.id] = reference }
        }
        var paths = Set(references.values.filter { $0.relayAddress == noteAddress }.map(\.path))
        if let context = noteContext, noteContextIsCurrent(context), vaultNote != nil { paths.insert(context.path) }
        for path in paths.sorted() {
            guard VaultNoteReference.validPath(path) else { continue }
            let context = noteContext
            let base = vaultNote
            let editGeneration = noteEditGeneration
            let editorGeneration = noteEditorGeneration
            let request = noteRequest
            noteReadSequence &+= 1
            let readSequence = noteReadSequence
            do {
                let latest = try await load(path).validated(at:path)
                guard !Task.isCancelled, scene.id == sceneID, noteSceneGeneration == sceneGeneration,
                      noteConnectionGeneration == connectionGeneration else { return }
                guard readSequence >= acceptedNoteReads[path,default:0] else { continue }
                acceptedNoteReads[path] = readSequence
                refreshNoteCache(latest,expected:references)
                guard let context, noteContext == context, noteContextIsCurrent(context),
                      editorGeneration == noteEditorGeneration, context.path == path,
                      noteRequest == request, !vaultSaving,
                      vaultNote?.sha256 == base?.sha256, noteEditGeneration == editGeneration else { continue }
                if vaultLoading && base == nil && !vaultDirty {
                    vaultNote = latest
                    vaultDraft = latest.text
                    vaultLoading = false
                    noteRequest = nil
                    vaultStatus = "Mac의 최신 원본을 열었습니다."
                    continue
                }
                guard !vaultLoading, let base, latest.sha256 != base.sha256 else { continue }
                if !vaultDirty && !vaultBlocked {
                    vaultNote = latest
                    vaultDraft = latest.text
                    vaultStatus = "Mac의 최신 수정 내용을 받았습니다."
                } else {
                    vaultBlocked = true
                    vaultStatus = "Mac에서도 수정됐습니다. 현재 입력은 보존했으며 자동 덮어쓰기를 중단했습니다."
                }
            } catch {
                guard !Task.isCancelled, scene.id == sceneID, noteSceneGeneration == sceneGeneration,
                      noteConnectionGeneration == connectionGeneration else { return }
                guard readSequence >= acceptedNoteReads[path,default:0] else { continue }
                if let context, noteContext == context, noteContextIsCurrent(context),
                   context.path == path, noteRequest == request, !vaultSaving, !vaultLoading,
                   vaultNote?.sha256 == base?.sha256, noteEditGeneration == editGeneration {
                    vaultBlocked = true
                    vaultStatus = "원본 확인 실패: \(error.localizedDescription). 입력은 보존하며 자동 생성하지 않습니다."
                }
                status = "연결된 노트 확인 실패 · \(path) · 저장된 표시 캐시는 유지됩니다."
            }
        }
    }

    init() {
        if let restored = Self.restoreScene() {
            scene = restored.scene
            drawing = restored.drawing
            status = "저장된 칠판 복원 · 획 \(scene.strokes.count)개"
        }
        do {
            let url = try Self.outboxURL()
            if FileManager.default.fileExists(atPath:url.path) {
                outbox = try JSONDecoder().decode(CanvasOutbox.self,from:Data(contentsOf:url))
                try outbox.validate()
                packet = outbox.entries.last?.receipt
                if outbox.unresolved != nil { status = "미확인 전송 복원 · 같은 패킷의 영수증만 조회합니다." }
            }
        } catch {
            outboxReadable = false
            status = CanvasSendError.outboxUnavailable.localizedDescription
        }
    }

    private static func outboxURL() throws -> URL {
        guard let directory = FileManager.default.urls(for:.applicationSupportDirectory,
                                                       in:.userDomainMask).first else {
            throw CanvasSendError.outboxUnavailable
        }
        return directory.appendingPathComponent("CanvasOutbox",isDirectory:true).appendingPathComponent("ledger.json")
    }

    private func updateOutbox(_ change: (inout CanvasOutbox) throws -> Void) throws {
        guard outboxReadable else { throw CanvasSendError.outboxUnavailable }
        var next = outbox
        try change(&next)
        try CanvasLocalFile.write(JSONEncoder().encode(next),to:Self.outboxURL())
        outbox = next
    }

    func unresolvedPacket() throws -> CanvasOutboxEntry? {
        guard outboxReadable else { throw CanvasSendError.outboxUnavailable }
        return outbox.unresolved
    }

    func existingPacket(for frozen: CanvasScene, session: VoiceSession) throws -> CanvasOutboxEntry? {
        guard outboxReadable else { throw CanvasSendError.outboxUnavailable }
        return try outbox.existing(for:frozen,threadId:session.threadId,sessionId:session.sessionId)
    }

    func preparePacket(scene: CanvasScene, imagePNG: Data, session: VoiceSession,
                       targetMode: String? = nil, relayAddress: String) throws -> CanvasPacket {
        let packet = try CanvasPacket(scene:scene,imagePNG:imagePNG,session:session,targetMode:targetMode)
        try updateOutbox { try $0.reserve(packet,relayAddress:relayAddress) }
        return packet
    }

    func beginSubmission(_ id: UUID) throws {
        try updateOutbox { try $0.beginSubmission(id) }
    }

    func acceptReceipt(_ receipt: PacketReceipt) throws {
        try updateOutbox { try $0.accept(receipt) }
        guard let accepted = outbox.entries.first(where: { $0.id == receipt.packetId })?.receipt else { return }
        packet = accepted
        switch accepted.state {
        case .steered:
            status = "\(accepted.targetMode == "inbox" ? "고정 수신함" : "현재 대화") 턴에 그림 전달 확인 · 턴 ID \(accepted.turnId.map { String($0.uuidString.prefix(8)) } ?? "미확인")"
        case .started:
            status = "\(accepted.targetMode == "inbox" ? "고정 수신함" : "선택한 대화")에서 새 턴 시작 확인 · 턴 ID \(accepted.turnId.map { String($0.uuidString.prefix(8)) } ?? "미확인")"
        case .queued:
            if accepted.targetMode == "inbox" {
                status = "고정 그림 수신함 대기열 접수 확인 · 대화 처리 대기"
            } else {
                let continuity = accepted.sessionContinuity.status == "observed-same" ?
                    "음성 세션 전후 동일 관측" : "음성 세션 연속성 미확인"
                status = "정확한 대화 대기열 접수 확인 · \(continuity) · 세션 내 전달 보장 아님"
            }
        case .rejected:
            status = "전송 거부 · \(accepted.reason ?? "대화 또는 세션 확인 실패")"
        case .stored, .dispatching, .unknown:
            status = "접수 결과 미확인 · 같은 패킷 영수증만 조회 · 자동 재전송하지 않습니다."
        }
    }

    private static func sceneURL() -> URL? {
        guard let directory = FileManager.default.urls(for:.applicationSupportDirectory,
                                                       in:.userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        return directory.appendingPathComponent("CanvasScene.json")
    }

    private static func restoreScene() -> (scene: CanvasScene, drawing: PKDrawing)? {
        guard let url = sceneURL(),let data = try? Data(contentsOf:url),
              data.count <= sceneByteLimit,
              let scene = try? JSONDecoder().decode(CanvasScene.self,from:data),
              scene.schemaVersion == 1,
              let drawingData = Data(base64Encoded:scene.drawingBase64) else { return nil }
        let drawing: PKDrawing
        if drawingData.isEmpty { drawing = PKDrawing() }
        else if let restored = try? PKDrawing(data:drawingData) { drawing = restored }
        else { return nil }
        return (scene,drawing)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let url = Self.sceneURL(),let data = try? JSONEncoder().encode(scene) else { return }
        guard data.count <= Self.sceneByteLimit else {
            status = "칠판 저장 크기 한도를 넘었습니다. 마지막 정상 저장본을 유지했습니다."
            return
        }
        do { try CanvasLocalFile.write(data,to:url) }
        catch { status = "칠판 자동 저장 실패: \(error.localizedDescription)" }
    }

    private static let sceneByteLimit = 4*1024*1024

    func updateDrawing(_ next: PKDrawing) {
        guard drawing != next else { return }
        drawing = next
        var changed = scene
        changed.drawingBase64 = next.dataRepresentation().base64EncodedString()
        changed.strokes = next.strokes.map { stroke in
            func worldPoint(_ point: PKStrokePoint) -> InkPoint {
                let location = point.location.applying(stroke.transform)
                return InkPoint(x: Double(location.x), y: Double(location.y),
                                pressure: Double(point.force))
            }
            let ranges = stroke.maskedPathRanges
            let full = stroke.mask == nil || (ranges.count == 1 &&
                ranges[0].lowerBound == 0 && ranges[0].upperBound == CGFloat(stroke.path.count - 1))
            let visibility = InkStroke.Visibility(kind: full ? .full : .masked,
                visibleSegments: full ? [] : ranges.map { range in
                    var points = [worldPoint(stroke.path.interpolatedPoint(at: range.lowerBound))]
                    let firstInterior = Int(floor(range.lowerBound)) + 1
                    let endInterior = Int(ceil(range.upperBound))
                    if firstInterior < endInterior {
                        points += (firstInterior..<endInterior).map { worldPoint(stroke.path[$0]) }
                    }
                    if range.upperBound > range.lowerBound {
                        points.append(worldPoint(stroke.path.interpolatedPoint(at: range.upperBound)))
                    }
                    return InkStroke.Visibility.Segment(lowerBound: Double(range.lowerBound),
                        upperBound: Double(range.upperBound), worldPoints: points)
                })
            return InkStroke(id: stroke.id, points: stroke.path.map(worldPoint),
                createdAt: stroke.path.creationDate, visibility: visibility)
        }
        changed.revision += 1
        scene = changed
        status = "Pencil 입력 확인 · 획 \(scene.strokes.count)개 · \(mode.rawValue)"
    }

    func addNode(_ kind: CanvasNode.Kind) {
        selectedNode = scene.addNode(kind: kind,
            at: CanvasPoint(x: 700 - pan.width, y: 430 - pan.height),
            text: kind == .box ? "새 요소" : "새 메모")
        mode = .select
    }

    func addSpokenNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = "저장할 음성 설명이 없습니다."; return }
        selectedNode = scene.addNode(kind:.note,
            at:CanvasPoint(x:700 - pan.width,y:430 - pan.height),text:trimmed)
        mode = .select
        status = "확인한 음성 설명을 캔버스에 저장했습니다. 대화 전송은 별도 버튼으로 진행합니다."
    }

    func select(_ id: UUID) {
        if let from = linkStart, from != id {
            _ = scene.connect(from, to: id)
            linkStart = nil
            status = "화살표 관계를 추가했습니다."
        }
        selectedNode = id
    }

    func beginLink() {
        guard let selectedNode else { return }
        linkStart = selectedNode
        status = "연결할 두 번째 요소를 탭하세요."
    }

    func moveSelected(to point: CGPoint) {
        guard let selectedNode else { return }
        scene.moveNode(selectedNode, to: CanvasPoint(x: Double(point.x), y: Double(point.y)))
    }

    func proposeHandwriting(recognize: (PKDrawing) async -> String? = { drawing in
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(drawing)
        return await recognizer.recognizedText()
    }) async {
        let request = UUID()
        handwritingRequest = request
        let sourceDrawing = drawing
        guard !sourceDrawing.strokes.isEmpty else { status = "인식할 획이 없습니다."; return }
        let recognized = await recognize(sourceDrawing)
        guard handwritingRequest == request else { return }
        handwritingRequest = nil
        guard let text = recognized, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { status = "글자 후보를 찾지 못했습니다. 원본 획은 유지했습니다."; return }
        let bounds = sourceDrawing.bounds
        let id = scene.addNode(kind: .note,
            at: CanvasPoint(x: Double(bounds.midX), y: Double(bounds.midY)),
            text: text, confidence: .proposal,
            sourceStrokeIds: sourceDrawing.strokes.map(\.id))
        proposedNode = id
        proposalText = text
        mode = .select
        status = "글자 후보입니다. 수정한 뒤 확인하면 구조 데이터에 확정됩니다."
    }

    func confirmProposal() {
        guard let proposedNode else { return }
        guard scene.confirmNode(proposedNode, text: proposalText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = "연결된 노트는 원본 노트 편집에서 수정하세요."
            return
        }
        self.proposedNode = nil
        status = "수정한 글자를 확정했습니다. 원본 획 출처는 남겼습니다."
    }

    func importScene(_ imported: CanvasScene) throws {
        guard !vaultDirty, !vaultSaving else { throw CocoaError(.userCancelled) }
        guard imported.schemaVersion == 1, imported.width > 0, imported.height > 0,
              imported.nodes.count < 1000, imported.strokes.count < 10000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let next = try PKDrawing(data: Data(base64Encoded: imported.drawingBase64) ?? Data())
        invalidateNoteScene()
        scene = imported
        drawing = next
        selectedNode = nil
        packet = nil
        status = "장면을 가져왔습니다. 그림과 구조 데이터를 함께 복원했습니다."
    }

    func applyAgentRevision(_ revision: AgentRevision) {
        let sent = outbox.entries.first(where: { $0.id == packet?.packetId })
            .flatMap { try? $0.packet.frozenScene() }
        guard scene.apply(revision, basedOn:sent) else {
            status = "에이전트 제안이 현재 그림과 충돌해 자동 반영하지 않았습니다."
            return
        }
        status = "에이전트 주석과 제안 요소가 캔버스에 반영됐습니다. 제안은 수정 후 확인할 수 있습니다."
    }
}
