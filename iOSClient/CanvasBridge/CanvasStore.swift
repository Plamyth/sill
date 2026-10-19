import Foundation
import PencilKit
import SwiftUI

enum CanvasMode: String, CaseIterable {
    case pen = "그리기"
    case eraser = "지우기"
    case lasso = "영역 선택"
    case select = "요소 이동"
}

enum CanvasEraserStyle: String, CaseIterable {
    case partial = "부분 지우기"
    case stroke = "획 전체 지우기"

    var tool: PKEraserTool {
        switch self {
        case .partial: return PKEraserTool(.fixedWidthBitmap, width: 20)
        case .stroke: return PKEraserTool(.vector)
        }
    }
}

@MainActor
final class CanvasInkHistory: ObservableObject {
    struct Availability: Equatable {
        var canUndo = false
        var canRedo = false
    }

    @Published private(set) var availability = Availability()
    private(set) var generation = UUID()
    private weak var manager: UndoManager?
    private var observers: [NSObjectProtocol] = []
    private var usingTool = false
    private var refreshScheduled = false
    private var refreshing = false

    func attach(_ manager: UndoManager) {
        if let previous = self.manager { detach(previous) }
        self.manager = manager
        invalidate()
        for name in [NSNotification.Name.NSUndoManagerDidOpenUndoGroup, .NSUndoManagerDidCloseUndoGroup,
                     .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: manager,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                })
        }
        scheduleRefresh()
    }

    func detach(_ manager: UndoManager) {
        guard self.manager === manager else { return }
        invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        self.manager = nil
    }

    func invalidate() {
        generation = UUID()
        manager?.removeAllActions()
        usingTool = false
        scheduleRefresh()
    }

    func setUsingTool(_ active: Bool) {
        usingTool = active
        if active {
            if availability != Availability() { availability = Availability() }
        } else { scheduleRefresh() }
    }

    func undo() {
        guard let manager, !usingTool, !manager.isUndoing, !manager.isRedoing,
              manager.groupingLevel <= 1, manager.canUndo else { return }
        manager.undo()
        scheduleRefresh()
    }

    func redo() {
        guard let manager, !usingTool, !manager.isUndoing, !manager.isRedoing,
              manager.groupingLevel == 0, manager.canRedo else { return }
        manager.redo()
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard !refreshScheduled, !refreshing else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshing = true
            defer { self.refreshing = false }
            let next: Availability
            if let manager = self.manager, !self.usingTool, !manager.isUndoing,
               !manager.isRedoing, manager.groupingLevel <= 1 {
                next = Availability(canUndo: manager.canUndo,
                    canRedo: manager.groupingLevel == 0 && manager.canRedo)
            } else { next = Availability() }
            if self.availability != next { self.availability = next }
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor
final class CanvasStore: ObservableObject {
    @Published var scene = CanvasScene() {
        didSet {
            if oldValue.id != scene.id || linkStart.map({ from in !scene.nodes.contains(where:{ $0.id == from }) }) == true {
                clearPendingLink()
            }
            if oldValue.id != scene.id { invalidateNoteScene(); inkHistory.invalidate() }
            else if let context = noteContext, !noteContextIsCurrent(context) { invalidateNoteRequests() }
            handwritingRequest = nil
            scheduleSave()
        }
    }
    @Published var mode: CanvasMode = .pen {
        didSet {
            if oldValue != mode { clearPendingLink() }
            handwritingRequest = nil
        }
    }
    @Published var eraserStyle: CanvasEraserStyle = .partial
    @Published var selectedNode: UUID? {
        didSet {
            if oldValue != selectedNode { clearPendingLink() }
            handwritingRequest = nil
        }
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
    let inkHistory = CanvasInkHistory()
    private var storedDrawing = PKDrawing()
    var drawing: PKDrawing {
        get { storedDrawing }
        set {
            objectWillChange.send()
            storedDrawing = newValue
            handwritingRequest = nil
            inkHistory.invalidate()
        }
    }
    @Published private(set) var linkStart: UUID?
    private var linkKind: CanvasLink.Kind = .general
    private var saveTask: Task<Void,Never>?
    private var handwritingRequest: UUID?
    @Published private(set) var vaultNote: VaultNoteSnapshot?
    @Published var vaultDraft = "" {
        didSet { noteEditGeneration &+= 1 }
    }
    @Published var vaultSelection = NSRange(location:0,length:0)
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
        var editorGeneration: UInt64
        let path: String
        let nodeID: UUID?
        let blockID: String?
    }
    private var noteContext: NoteContext?
    private var pendingExcerptAnchor: (context: NoteContext, id: String)?

    var vaultDirty: Bool { !vaultDraft.utf8.elementsEqual((vaultNote?.text ?? "").utf8) }
    var vaultCanSave: Bool {
        vaultNote != nil && vaultDirty && !vaultSaving && !vaultLoading && !vaultBlocked &&
        noteContext.map(noteContextIsCurrent) == true
    }
    var vaultCanAttach: Bool {
        vaultNote != nil && !vaultDirty && !vaultSaving && !vaultLoading && !vaultBlocked &&
        noteContext.map(noteContextIsCurrent) == true
    }
    var vaultLinkedBlockID: String? { noteContext?.blockID }
    var vaultSelectedBlock: VaultExcerptBlock? {
        guard vaultCanAttach, let note = vaultNote else { return nil }
        return try? VaultMarkdownBlocks(note.text).selected(vaultSelection)
    }
    var vaultExcerptMessage: String {
        guard vaultCanAttach, let note = vaultNote else { return "저장된 최신 원본에서 문단을 선택하세요." }
        do {
            let block = try VaultMarkdownBlocks(note.text).selected(vaultSelection)
            return block.blockID.map { "기존 표식 ^\($0)을 사용합니다." } ?? "선택 문단 끝에 새 블록 표식만 저장합니다."
        } catch { return error.localizedDescription }
    }

    func setNoteConnection(address: String, token: String) {
        guard address != noteAddress || token != noteToken else { return }
        noteAddress = address
        noteToken = token
        noteConnectionGeneration &+= 1
        invalidateNoteRequests()
    }

    private func invalidateNoteRequests() {
        pendingExcerptAnchor = nil
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
                  ref.path == context.path, ref.relayAddress == noteAddress,
                  ref.blockID == context.blockID else { return false }
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
        pendingExcerptAnchor = nil
        vaultNote = nil
        vaultDraft = ""
        vaultSelection = NSRange(location:0,length:0)
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
        let pending = pendingExcerptAnchor.flatMap { attempt in
            attempt.context == noteContext && attempt.context.path == path && noteContextIsCurrent(attempt.context) ? attempt.id : nil
        }
        let linkedNodeID = nodeID ?? (noteContext?.path == path ? noteContext?.nodeID : nil)
        var context = NoteContext(sceneID:scene.id,sceneGeneration:noteSceneGeneration,
            connectionGeneration:noteConnectionGeneration,editorGeneration:noteEditorGeneration,
            path:path,nodeID:linkedNodeID,
            blockID:linkedNodeID.flatMap { id in scene.nodes.first(where:{ $0.id == id })?.vaultNote?.blockID })
        guard noteContextIsCurrent(context) else {
            vaultStatus = "연결한 노트의 경로 또는 서버가 바뀌었습니다. 자동 재연결하지 않았습니다."
            return
        }
        noteEditorGeneration &+= 1
        context.editorGeneration = noteEditorGeneration
        noteContext = context
        pendingExcerptAnchor = pending.map { (context:context,id:$0) }
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
            focusOpenedBlock(note)
        } catch {
            guard !Task.isCancelled, noteRequest == request, noteContext == context,
                  noteContextIsCurrent(context) else { return }
            vaultLoading = false
            noteRequest = nil
            vaultBlocked = true
            vaultStatus = "원본을 열지 못했습니다: \(error.localizedDescription). 자동 생성하지 않습니다."
        }
    }

    private func focusOpenedBlock(_ note: VaultNoteSnapshot) {
        vaultSelection = NSRange(location:0,length:0)
        let pending = pendingExcerptAnchor.flatMap { $0.context == noteContext ? $0.id : nil }
        guard let id = pending ?? noteContext?.blockID else { return }
        do {
            let block = try VaultMarkdownBlocks(note.text).resolve(id)
            if let range = block.selection(in:note.text) { vaultSelection = range }
            vaultStatus = "연결 블록 ^\(id)을 선택했습니다."
        } catch {
            vaultSelection = NSRange(location:NSNotFound,length:0)
            vaultStatus = "연결 블록 ^\(id) · \(error.localizedDescription)"
        }
    }

    @discardableResult
    func excerptSelectedVaultBlock(save: (String, String, String) async throws -> VaultNoteSnapshot,
                                   load: (String) async throws -> VaultNoteSnapshot) async -> UUID? {
        guard vaultCanAttach, let base = vaultNote, let context = noteContext else { return nil }
        do {
            let markdown = VaultMarkdownBlocks(base.text)
            let block = try markdown.selected(vaultSelection)
            let anchor = try markdown.anchored(block)
            if block.blockID != nil { return attachVaultBlock(block,note:base) }
            pendingExcerptAnchor = (context:context,id:anchor.blockID)
            let request = UUID(), editGeneration = noteEditGeneration
            noteRequest = request
            vaultSaving = true
            defer {
                if noteRequest == request {
                    noteRequest = nil
                    vaultSaving = false
                    vaultBlocked = true
                }
            }
            func current() -> Bool {
                !Task.isCancelled && noteRequest == request && noteContext == context &&
                    noteContextIsCurrent(context) && vaultNote?.sha256 == base.sha256
            }
            do {
                let saved = try await save(base.path,base.sha256,anchor.text).validated(at:base.path)
                guard saved.text.utf8.elementsEqual(anchor.text.utf8) else { throw URLError(.badServerResponse) }
            } catch {
                // A lost PUT response is reconciled by reading the same marker, never another write.
            }
            guard current() else { return nil }
            noteReadSequence &+= 1
            let readSequence = noteReadSequence
            do {
                let saved = try await load(base.path).validated(at:base.path)
                guard current() else { return nil }
                guard saved.text.utf8.elementsEqual(anchor.text.utf8),
                      readSequence >= acceptedNoteReads[base.path,default:0] else { throw URLError(.badServerResponse) }
                let confirmed = try VaultMarkdownBlocks(saved.text).resolve(anchor.blockID)
                acceptedNoteReads[base.path] = readSequence
                vaultNote = saved
                if noteEditGeneration == editGeneration {
                    vaultDraft = saved.text
                    vaultSelection = confirmed.selection(in:saved.text) ?? NSRange(location:0,length:0)
                } else {
                    vaultBlocked = true
                }
                refreshNoteCache(saved)
                let id = attachVaultBlock(confirmed,note:saved)
                vaultStatus = vaultBlocked ? "블록 저장과 발췌를 확인했습니다. 이후 입력은 보존했으며 원본을 다시 확인해야 합니다." :
                    "블록 ^\(anchor.blockID) 저장과 원본 재조회를 확인해 발췌했습니다."
                noteRequest = nil
                vaultSaving = false
                return id
            } catch {
                guard current() else { return nil }
                vaultBlocked = true
                vaultStatus = "블록 저장 결과를 확인하지 못했습니다: \(error.localizedDescription). 입력을 보존했습니다. 원본 다시 읽기 후 같은 표식을 확인하세요."
                return nil
            }
        } catch {
            vaultStatus = error.localizedDescription
            return nil
        }
    }

    private func attachVaultBlock(_ block: VaultExcerptBlock, note: VaultNoteSnapshot) -> UUID {
        pendingExcerptAnchor = nil
        let preview = VaultNoteSnapshot.preview(block.quote)
        let id = scene.addNode(kind:.note,at:CanvasPoint(x:700-pan.width,y:430-pan.height),text:preview)
        scene.nodes[scene.nodes.count - 1].vaultNote = VaultNoteReference(path:note.path,sha256:note.sha256,
            relayAddress:noteAddress,cacheTruncated:!preview.utf8.elementsEqual(block.quote.utf8),
            blockID:block.blockID,sourceState:.current,observedSha256:note.sha256,
            quoteSha256:CanvasPacket.sha(Data(block.quote.utf8)))
        selectedNode = id
        mode = .select
        vaultStatus = "선택 블록을 원본 표식과 연결했습니다."
        return id
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
        let blocks = VaultMarkdownBlocks(note.text)
        for index in next.nodes.indices {
            guard var ref = next.nodes[index].vaultNote, ref.path == note.path,
                  ref.relayAddress == noteAddress,
                  expected.map({ $0[next.nodes[index].id] == ref }) ?? true else { continue }
            ref.observedSha256 = note.sha256
            let source: String
            if let id = ref.blockID {
                do { source = try blocks.resolve(id).quote }
                catch {
                    switch error as? VaultBlockError {
                    case .ambiguous: ref.sourceState = .ambiguous
                    case .unsupported: ref.sourceState = .unsupported
                    default: ref.sourceState = .missing
                    }
                    next.nodes[index].vaultNote = ref
                    continue
                }
            } else { source = note.text }
            let preview = VaultNoteSnapshot.preview(source)
            let quoteSHA = ref.blockID == nil ? nil : CanvasPacket.sha(Data(source.utf8))
            let changed = (ref.quoteSha256 != nil ? ref.quoteSha256 != quoteSHA :
                !preview.utf8.elementsEqual(next.nodes[index].text.utf8)) ||
                (ref.sourceState == .changed && ref.sha256 == note.sha256)
            ref.sha256 = note.sha256
            ref.cacheTruncated = !preview.utf8.elementsEqual(source.utf8)
            ref.sourceState = changed ? .changed : .current
            ref.quoteSha256 = quoteSHA
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
                    focusOpenedBlock(latest)
                    continue
                }
                guard !vaultLoading, let base, latest.sha256 != base.sha256 else { continue }
                if !vaultDirty && !vaultBlocked {
                    vaultNote = latest
                    vaultDraft = latest.text
                    vaultStatus = "Mac의 최신 수정 내용을 받았습니다."
                    focusOpenedBlock(latest)
                } else {
                    vaultBlocked = true
                    vaultStatus = "Mac에서도 수정됐습니다. 현재 입력은 보존했으며 자동 덮어쓰기를 중단했습니다."
                }
            } catch {
                guard !Task.isCancelled, scene.id == sceneID, noteSceneGeneration == sceneGeneration,
                      noteConnectionGeneration == connectionGeneration else { return }
                guard readSequence >= acceptedNoteReads[path,default:0] else { continue }
                var next = scene
                for index in next.nodes.indices {
                    guard var ref = next.nodes[index].vaultNote, ref.path == path,
                          ref.relayAddress == noteAddress, references[next.nodes[index].id] == ref else { continue }
                    let failure = error as NSError
                    ref.sourceState = failure.domain == "CanvasRelay" && failure.code == 404 ? .missing : .unavailable
                    next.nodes[index].vaultNote = ref
                }
                if next != scene { next.revision += 1; scene = next }
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
        storedDrawing = next
        handwritingRequest = nil
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
        let from = linkStart
        let kind = linkKind
        clearPendingLink()
        guard scene.nodes.contains(where:{ $0.id == id }) else {
            status = "요소가 없어 연결하지 않았습니다."
            return
        }
        if let from {
            if from == id {
                status = "연결을 취소했습니다."
            } else {
                let connected = kind == .parentChild ? scene.connectAsChild(parent:from,child:id) :
                    scene.connect(from,to:id)
                status = connected ? (kind == .parentChild ? "상위·하위 요소를 연결했습니다." : "화살표 관계를 추가했습니다.") :
                    "연결하지 않았습니다. 요소가 없거나 기존 상위 연결·순환 관계와 충돌합니다."
            }
        }
        selectedNode = id
    }

    func beginLink() {
        beginLink(kind:.general)
    }

    func beginChildLink() {
        beginLink(kind:.parentChild)
    }

    private func beginLink(kind: CanvasLink.Kind) {
        clearPendingLink()
        guard let selectedNode, scene.nodes.contains(where:{ $0.id == selectedNode }) else {
            status = "먼저 연결을 시작할 요소를 선택하세요."
            return
        }
        mode = .select
        linkKind = kind
        linkStart = selectedNode
        status = kind == .parentChild ? "하위로 연결할 요소를 탭하세요. 같은 요소를 다시 탭하면 취소합니다." :
            "연결할 두 번째 요소를 탭하세요. 같은 요소를 다시 탭하면 취소합니다."
    }

    private func clearPendingLink() {
        linkStart = nil
        linkKind = .general
    }

    func cancelLink() {
        guard linkStart != nil else { return }
        clearPendingLink()
        status = "연결을 취소했습니다."
    }

    func unlinkFromParent() {
        clearPendingLink()
        guard let selectedNode, scene.nodes.contains(where:{ $0.id == selectedNode }) else { return }
        let removed = scene.links.contains(where:{ $0.kind == .parentChild && $0.to == selectedNode })
        guard removed else { status = "해제할 상위 연결이 없습니다."; return }
        scene.links.removeAll(where:{ $0.kind == .parentChild && $0.to == selectedNode })
        scene.revision += 1
        status = "상위 연결을 해제했습니다. 요소와 원문은 보존됐습니다."
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
