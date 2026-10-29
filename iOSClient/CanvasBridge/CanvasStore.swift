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
}

enum CanvasEraserSize: Double, CaseIterable {
    case fine = 18, standard = 20, medium = 30, large = 40, extraLarge = 60, broad = 80

    var label: String {
        switch self {
        case .fine: return "작게 · 18포인트"
        case .standard: return "기본 · 20포인트"
        case .medium: return "보통 · 30포인트"
        case .large: return "크게 · 40포인트"
        case .extraLarge: return "아주 크게 · 60포인트"
        case .broad: return "넓게 · 80포인트"
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
    struct Owner: Hashable { let documentID: UUID; let pageID: UUID; let documentMode: Bool }
    private(set) var owner: Owner?
    private var histories: [Owner:(manager:UndoManager,generation:UUID)] = [:]
    private weak var manager: UndoManager?
    private var observers: [NSObjectProtocol] = []
    private(set) var usingTool = false
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

    @discardableResult
    func activate(_ next: Owner) -> UndoManager {
        if owner == next, let manager { return manager }
        if let owner, let manager { histories[owner] = (manager,generation) }
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        let value = histories[next] ?? (UndoManager(),UUID())
        histories[next] = value; owner = next; manager = value.manager; generation = value.generation; usingTool = false
        for name in [NSNotification.Name.NSUndoManagerDidOpenUndoGroup,.NSUndoManagerDidCloseUndoGroup,.NSUndoManagerDidUndoChange,.NSUndoManagerDidRedoChange] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:value.manager,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        scheduleRefresh(); return value.manager
    }
    func invalidateDocument(_ id: UUID) {
        for (key,value) in histories where key.documentMode && key.documentID == id {
            value.manager.removeAllActions()
            let fresh = UUID(); histories[key] = (value.manager,fresh)
            if owner == key { generation = fresh }
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
        if let owner, let manager { histories[owner] = (manager,generation) }
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
        guard commandAvailability.canUndo, let manager else { return }
        manager.undo()
        scheduleRefresh()
    }

    func redo() {
        guard commandAvailability.canRedo, let manager else { return }
        manager.redo()
        scheduleRefresh()
    }

    var commandAvailability: Availability {
        guard let manager, !usingTool, !manager.isUndoing, !manager.isRedoing,
              manager.groupingLevel <= 1 else { return Availability() }
        return Availability(canUndo: manager.canUndo,
                            canRedo: manager.groupingLevel == 0 && manager.canRedo)
    }

    func scheduleRefresh() {
        guard !refreshScheduled, !refreshing else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshing = true
            defer { self.refreshing = false }
            let next = self.commandAvailability
            if self.availability != next { self.availability = next }
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

enum CanvasConflictChoiceState: String, Codable { case pending, refreshRequired, resolved, superseded }
struct CanvasConflictChoice: Codable {
    let address: String, localSHA: String, backupFilename: String
    let conflict: CanvasRelay.VaultConflict
    let decision: CanvasRelay.ConflictDecision
    var disposition = CanvasConflictChoiceState.pending
}

@MainActor
final class CanvasStore: ObservableObject {
    enum SourceKind: String, Codable { case legacy, document }
    @Published private(set) var document = try! CanvasDocument(legacy:CanvasScene())
    @Published private(set) var sourceKind: SourceKind = .legacy
    var isDocumentSource: Bool { sourceKind == .document }
    var nativeHistoryOwner: CanvasInkHistory.Owner { .init(documentID:document.id,pageID:scene.id,documentMode:isDocumentSource) }
    var scene: CanvasScene {
        get { document.activePage }
        set {
            guard !documentEditingBlocked else { status = "문서 저장·조정 중입니다. 현재 원본을 유지합니다."; return }
            let old = scene
            do {
                if newValue.id != old.id {
                    guard !isDocumentSource else { throw CanvasDocument.Failure.stale }
                    document = try CanvasDocument(legacy:newValue)
                } else { try document.updateActivePageForEditing(newValue) }
                sceneDidChange(from:old)
            } catch { sceneReadable = false; status = "문서 내부 편집을 보존하지 못했습니다. \(error.localizedDescription)" }
        }
    }
    private func sceneDidChange(from oldScene: CanvasScene) {
            cancelCardMerge()
            pendingInkTextEditing?.invalidatePending()
            pendingInkSpacing?.invalidatePending()
            inkMathRequest = nil
            linkSceneGeneration &+= 1
            nodeResizeDrag = nil
            nodeRotationDrag = nil
            if oldScene.id != scene.id { cardTagFilter = nil }
            let visible = cardTagVisibility.nodeIDs
            if oldScene.id != scene.id || selectedLink.map({ !cardTagVisibility.linkIDs.contains($0) }) == true {
                clearLinkSelection()
            }
            if oldScene.id != scene.id || linkStart.map({ !visible.contains($0) }) == true {
                clearPendingLink()
            }
            if selectedNode.map({ !visible.contains($0) }) == true { selectedNode = nil }
            if proposedNode.map({ !visible.contains($0) }) == true { proposedNode = nil }
            if oldScene.id != scene.id { setInkSelection([]); invalidateNoteScene(); if !isDocumentSource && !installingDocument { inkHistory.invalidate() } }
            else if let context = noteContext, !noteContextIsCurrent(context) { invalidateNoteRequests() }
            handwritingRequest = nil
            if fileWorkspaceState != .blocked { fileWorkspaceState = .pending }
            if isDocumentSource && !installingDocument { documentFileReady = false }
            if !installingDocument { scheduleSave() }
    }
    @Published var mode: CanvasMode = .pen {
        didSet {
            if oldValue != mode {
                if let editor = cardTagEditor { cancelCardTagInput(sessionID:editor.id) }
                cancelCardMerge()
                cancelInkMath()
                cancelInkShape()
                pendingInkTextEditing?.invalidatePending()
                pendingInkSpacing?.invalidatePending()
                nodeResizeDrag = nil
                nodeRotationDrag = nil
                clearPendingLink()
                clearLinkSelection()
                if mode != .lasso { setInkSelection([]) }
            }
            handwritingRequest = nil
        }
    }
    @Published var rulerEnabled = false
    @Published private var pencilTraceOwner: UUID?
    var pencilTraceActive: Bool { pencilTraceOwner != nil }
    var inkBusy: Bool { pencilTraceActive || inkHistory.usingTool }
    func setPencilTraceActive(_ active: Bool, owner: UUID) {
        if active {
            if pencilTraceOwner == nil || pencilTraceOwner == owner {
                if let editor = cardTagEditor { cancelCardTagInput(sessionID:editor.id) }
                cancelCardMerge()
                pendingInkTextEditing?.invalidatePending()
                pendingInkSpacing?.invalidatePending()
                cancelInkShape()
                cancelInkMath()
                pencilTraceOwner = owner
            }
        } else if pencilTraceOwner == owner { pencilTraceOwner = nil }
    }

    var penTool: PKInkingTool {
        let settings = scene.effectivePenSettings
        let width = CGFloat(settings.width)
        switch settings.color {
        case .white: return PKInkingTool(.pen, color: .white, width: width)
        case .yellow: return PKInkingTool(.pen, color: .yellow, width: width)
        case .cyan: return PKInkingTool(.pen, color: .cyan, width: width)
        }
    }

    @discardableResult
    func setPenSettings(_ change: CanvasPenSettingsChange, sceneID: UUID,
                        baseRevision: Int) throws -> CanvasPenSettingsResult {
        guard !documentEditingBlocked else { throw CanvasPenSettingsError.persistenceFailed }
        var next = scene
        let result = try next.setPenSettings(change, sceneID: sceneID, baseRevision: baseRevision, inkBusy: inkBusy)
        guard sceneReadable, let data = Data(base64Encoded: scene.drawingBase64),
              data.isEmpty || (try? PKDrawing(data: data)) != nil else {
            throw CanvasPenSettingsError.unreadableDrawing
        }
        guard result.disposition == .applied else { return result }
        do { try persistScene(next) }
        catch ScenePersistenceError.tooLarge { throw CanvasPenSettingsError.sceneTooLarge }
        catch ScenePersistenceError.unreadable { throw CanvasPenSettingsError.unreadableDrawing }
        catch { throw CanvasPenSettingsError.persistenceFailed }
        scene = next
        status = "다음 획에 \(result.settings.color.label) · \(Int(result.settings.width))포인트를 적용합니다."
        return result
    }

    func choosePenSettings(_ settings: CanvasPenSettings, expectedScene: CanvasScene) {
        do {
            let result = try setPenSettings(.init(expected: expectedScene.effectivePenSettings, settings: settings),
                sceneID: expectedScene.id, baseRevision: expectedScene.revision)
            if result.disposition == .noop { status = "이미 같은 펜 설정입니다. 기존 획은 그대로 유지됩니다." }
        } catch { status = "\((error as? CanvasPenSettingsError)?.rawValue ?? "pen_settings_not_saved") · \(error.localizedDescription)" }
    }
    func rulerIsActive(isVisible: Bool) -> Bool {
        rulerEnabled && mode == .pen && isVisible
    }
    @Published private(set) var inkShapeProposal: CanvasInkShapeProposal?
    private var inkShapeGeneration: UInt64?
    private var inkShapeSelectionGeneration: UInt64 = 0
    private var inkShapeExpectedSelectionGeneration: UInt64?

    var inkShapeIsCurrent: Bool {
        guard let proposal = inkShapeProposal else { return false }
        return !documentEditingBlocked && sceneReadable && !inkMathInputBusy && !inkBusy && !fileSaveBusy && fileWorkspaceState != .blocked && !vaultDirty && !vaultSaving &&
            !vaultLoading && !vaultInputBusy && !vaultBlockEditing && mode == .lasso && proposal.source == scene &&
            proposal.selection == inkSelection && inkShapeGeneration == linkSceneGeneration &&
            inkShapeExpectedSelectionGeneration == inkShapeSelectionGeneration
    }

    func proposeInkShape() {
        guard !inkMathInputBusy else { status = "수식 교정 입력을 먼저 마쳐 주세요."; return }
        cancelInkMath()
        cancelInkShape()
        pendingInkTextEditing?.invalidatePending()
        pendingInkSpacing?.invalidatePending()
        guard !documentEditingBlocked, sceneReadable, !fileSaveBusy, fileWorkspaceState != .blocked, !vaultDirty, !vaultSaving,
              !vaultLoading, !vaultInputBusy, !vaultBlockEditing, !inkBusy, mode == .lasso else { status = "영역 선택 도구로 도형을 먼저 선택하세요."; return }
        do {
            inkShapeProposal = try CanvasInkShapeProposal.make(scene:scene,drawing:drawing,selection:inkSelection)
            inkShapeGeneration = linkSceneGeneration
            inkShapeExpectedSelectionGeneration = inkShapeSelectionGeneration
            status = "도형 후보를 원본과 비교한 뒤 확정하세요."
        } catch { status = error.localizedDescription }
    }

    func cancelInkShape() { inkShapeProposal = nil; inkShapeGeneration = nil; inkShapeExpectedSelectionGeneration = nil }

    @discardableResult
    func confirmInkShape() -> Bool {
        guard inkShapeIsCurrent, let proposal = inkShapeProposal else {
            status = "원본이나 선택이 바뀌어 확정하지 않았습니다."
            cancelInkShape()
            return false
        }
        do {
            let before = scene
            let next = try proposal.confirmed(in:scene,selection:inkSelection)
            try persistScene(next)
            scene = next
            recordGraphEdit(before:before)
            cancelInkShape()
            status = "도형을 복구본에 확정하고 원본 획을 보존했습니다. Files 원본 미저장·Obsidian 동기화 대기입니다."
            return true
        } catch { status = error.localizedDescription; return false }
    }

    @Published private(set) var inkMathProposal: CanvasInkMathProposal?
    @Published var inkMathDraft = ""
    @Published var inkMathInputBusy = false
    private var inkMathRequest: UUID?
    private var inkMathGeneration: UInt64?
    private var inkMathSelectionGeneration: UInt64 = 0
    private var inkMathExpectedSelectionGeneration: UInt64?
    var inkMathIsCurrent: Bool {
        guard let proposal = inkMathProposal else { return false }
        return inkMathEditAllowed && mode == .lasso && proposal.source == scene &&
            proposal.selection == inkSelection && inkMathGeneration == linkSceneGeneration &&
            inkMathExpectedSelectionGeneration == inkMathSelectionGeneration
    }
    private var inkMathEditAllowed: Bool {
        !documentEditingBlocked && sceneReadable && !inkBusy && !fileSaveBusy && fileWorkspaceState != .blocked &&
            !vaultDirty && !vaultSaving && !vaultLoading && !vaultInputBusy && !vaultBlockEditing
    }
    func cancelInkMath() { inkMathRequest = nil; inkMathProposal = nil; inkMathInputBusy = false }

    func proposeInkMath(recognize: (PKDrawing) async -> String? = { drawing in
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(drawing)
        return await recognizer.recognizedText()
    }) async {
        guard inkMathEditAllowed, !inkMathInputBusy, mode == .lasso else {
            status = "영역 선택과 저장·입력 상태를 확인하세요. 현재 수식 초안과 원본을 유지합니다."
            return
        }
        cancelInkMath()
        pendingInkTextEditing?.invalidatePending()
        pendingInkSpacing?.invalidatePending()
        cancelInkShape()
        do {
            let snapshot = try CanvasInkMathProposal.capture(scene:scene,drawing:drawing,selection:inkSelection,recognized:nil)
            let request = UUID(), generation = linkSceneGeneration, selectionGeneration = inkMathSelectionGeneration
            let documentOwner = try document.pageSnapshot()
            inkMathRequest = request
            let recognized = await recognize(snapshot.original)
            guard document.accepts(documentOwner), inkMathRequest == request, generation == linkSceneGeneration,
                  selectionGeneration == inkMathSelectionGeneration, snapshot.source == scene,
                  snapshot.selection == inkSelection, mode == .lasso, inkMathEditAllowed else { return }
            inkMathRequest = nil
            inkMathProposal = try CanvasInkMathProposal.capture(scene:scene,drawing:drawing,selection:inkSelection,recognized:recognized)
            inkMathDraft = recognized ?? ""
            inkMathGeneration = generation
            inkMathExpectedSelectionGeneration = selectionGeneration
            status = recognized == nil ? "인식 후보가 없습니다. 원본을 보며 식을 직접 교정하세요." : "인식 후보를 원본과 비교하고 식을 교정한 뒤 확정하세요."
        } catch { status = error.localizedDescription }
    }

    @discardableResult
    func confirmInkMath() -> Bool {
        guard inkMathIsCurrent, !inkMathInputBusy, let proposal = inkMathProposal else {
            status = "원본·선택이 바뀌었거나 입력 중입니다. 현재 초안과 원본을 유지합니다."
            return false
        }
        do {
            let before = scene
            let next = try proposal.confirmed(in:scene,selection:inkSelection,expression:inkMathDraft)
            try persistScene(next)
            scene = next
            recordGraphEdit(before:before)
            cancelInkMath()
            status = "확인한 수식과 계산 결과를 복구본에 반영했습니다. 원본 획은 보존하며 Files 원본 미저장·Obsidian 동기화 대기입니다."
            return true
        } catch { status = error.localizedDescription; return false }
    }

    @Published private(set) var inkSelection: Set<UUID> = []
    static let eraserStyleKey = "canvasEraserStyle"
    static let eraserSizeKey = "canvasPartialEraserWidth"
    private let eraserDefaults: CanvasRuntime.Defaults
    @Published var eraserStyle: CanvasEraserStyle = .partial {
        didSet {
            do { try eraserDefaults.set(eraserStyle.rawValue, forKey: Self.eraserStyleKey) }
            catch { status = "지우개 설정 저장 실패: \(error.localizedDescription)" }
        }
    }
    @Published var eraserSize: CanvasEraserSize = .standard {
        didSet {
            do { try eraserDefaults.set(eraserSize.rawValue, forKey: Self.eraserSizeKey) }
            catch { status = "지우개 설정 저장 실패: \(error.localizedDescription)" }
        }
    }
    var eraserTool: PKEraserTool {
        eraserStyle == .partial ?
            PKEraserTool(.fixedWidthBitmap, width: CGFloat(eraserSize.rawValue)) : PKEraserTool(.vector)
    }
    var eraserPreviewWidth: CGFloat? {
        eraserStyle == .partial ? eraserTool.width : nil
    }
    @Published var selectedNode: UUID? {
        didSet {
            if selectedNode.map({ !cardTagVisibility.nodeIDs.contains($0) }) == true { selectedNode = nil }
            if oldValue != selectedNode {
                noteSelectionGeneration &+= 1
                commentSelectionGeneration &+= 1
                nodeResizeDrag = nil
                nodeRotationDrag = nil
                clearPendingLink()
                if selectedNode != nil { clearLinkSelection() }
            }
            handwritingRequest = nil
        }
    }
    @Published var status = "Pencil로 그린 뒤 구조를 확인하세요."
    @Published private(set) var sceneRecoveryNotice = ""
    private var sceneReadable = true

    enum FileWorkspaceState { case pending, ready, blocked }
    @Published private(set) var fileWorkspaceState: FileWorkspaceState = .pending
    @Published private(set) var fileWorkspaceStatus = "저장 위치 미연결 · 앱 내부에는 미저장 복구본만 보관합니다."
    var filePreview: ((CanvasScene) async -> Data?)?
    private var fileWorkspace: CanvasFileWorkspace?
    private var workspaceBinding: CanvasFileWorkspace.Binding?
    private var workspaceToken: String?
    private var fileSaveBusy = false
    var fileWorkspaceCanSync: Bool {
        if isDocumentSource { return documentFileBinding != nil && documentFileReady && !documentBusy }
        guard (try? scene.requireCompatibleNodeKinds()) != nil, fileWorkspaceState != .blocked else { return false }
        return (workspaceBinding == nil && fileWorkspace == nil) || fileWorkspaceState == .ready
    }

    private func writeWorkspaceBinding(_ binding: CanvasFileWorkspace.Binding) throws {
        try CanvasLocalFile.write(JSONEncoder().encode(binding),to:CanvasRuntime.stateURL(.workspace))
        workspaceBinding = binding
    }

    private static func preserveLegacyScene() throws {
        let workspaceURL = try CanvasRuntime.stateURL(.workspace)
        let sourceURL = try CanvasRuntime.stateURL(.scene)
        let copyURL = try CanvasRuntime.stateURL(.legacyScene)
        guard !FileManager.default.fileExists(atPath:workspaceURL.path),
              FileManager.default.fileExists(atPath:sourceURL.path),
              !FileManager.default.fileExists(atPath:copyURL.path) else { return }
        let bytes = try CanvasLocalFile.read(sourceURL)
        guard bytes.count <= sceneByteLimit else { throw ScenePersistenceError.tooLarge }
        let legacy = try JSONDecoder().decode(CanvasScene.self,from:bytes)
        try legacy.validateNativeInkProjection()
        try CanvasLocalFile.write(bytes,to:copyURL)
        guard CanvasPacket.sha(try CanvasLocalFile.read(copyURL)) == CanvasPacket.sha(bytes) else {
            throw ScenePersistenceError.unreadable
        }
    }

    private func restoreFileWorkspace() {
        do {
            let url = try CanvasRuntime.stateURL(.workspace)
            guard FileManager.default.fileExists(atPath:url.path) else { return }
            let binding = try JSONDecoder().decode(CanvasFileWorkspace.Binding.self,from:CanvasLocalFile.read(url))
            workspaceBinding = binding
            var stale = false
            let folder = try URL(resolvingBookmarkData:binding.bookmark,options:.withoutUI,
                relativeTo:nil,bookmarkDataIsStale:&stale)
            guard !stale else { throw CanvasFileWorkspace.Failure.staleBookmark }
            let workspace = CanvasFileWorkspace(folder:folder)
            fileWorkspace = workspace
            let restored = try workspace.load(binding.sceneID)
            guard try CanvasFileWorkspace.sceneSHA(scene) == binding.savedSceneSHA else {
                throw CanvasFileWorkspace.Failure.conflict
            }
            try importScene(restored.scene)
            try writeWorkspaceBinding(.init(bookmark:binding.bookmark,sceneID:restored.scene.id,
                savedSceneSHA:CanvasFileWorkspace.sceneSHA(restored.scene)))
            try CanvasLocalFile.write(CanvasFileWorkspace.bytes(restored.scene),to:CanvasRuntime.stateURL(.scene))
            workspaceToken = restored.token
            fileWorkspaceState = .ready
            fileWorkspaceStatus = "Files 원본 연결 · \(folder.lastPathComponent) · 복원 완료"
        } catch { blockFileWorkspace(error) }
    }

    private func blockFileWorkspace(_ error: Error) {
        fileWorkspaceState = .blocked
        fileWorkspaceStatus = "Files 원본 저장 중단 · \(error.localizedDescription) · 미저장 복구본 보존"
    }

    func workspaceDocuments(in folder: URL) throws -> [UUID] {
        try CanvasFileWorkspace(folder:folder).documents()
    }

    func connectFileWorkspace(_ folder: URL, opening id: UUID? = nil) async {
        guard !isDocumentSource else { status = "문서는 전체 문서 원본 저장을 사용하세요."; return }
        guard !inkBusy, !vaultDirty, !vaultSaving, !fileSaveBusy else {
            status = "입력 또는 저장이 끝난 뒤 저장 위치를 연결하세요."
            return
        }
        let startingScene = scene
        let priorState = fileWorkspaceState
        let priorStatus = fileWorkspaceStatus
        var switched = false
        fileSaveBusy = true
        defer { fileSaveBusy = false }
        do {
            try Task.checkCancellation()
            let ownRoot = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.deletingLastPathComponent()
            if let ownRoot {
                let ownPath = ownRoot.resolvingSymlinksInPath().standardizedFileURL.path
                let selectedPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
                guard selectedPath != ownPath, !selectedPath.hasPrefix(ownPath + "/") else {
                    throw CanvasFileWorkspace.Failure.sandboxFolder
                }
            }
            let access = folder.startAccessingSecurityScopedResource()
            guard access else { throw CanvasFileWorkspace.Failure.permission }
            defer { folder.stopAccessingSecurityScopedResource() }
            let bookmark = try folder.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
            let workspace = CanvasFileWorkspace(folder:folder)
            // Preserve current work before replacing the in-memory scene or its pending cache.
            if sceneReadable { try persistScene() }
            else {
                guard id != nil else { throw ScenePersistenceError.unreadable }
                let bytes = try CanvasLocalFile.read(CanvasRuntime.stateURL(.scene))
                let recoveryURL = try CanvasRuntime.stateURL(.scene).deletingLastPathComponent()
                    .appendingPathComponent("CanvasUnreadable-\(UUID().uuidString.lowercased()).json")
                try CanvasLocalFile.write(bytes,to:recoveryURL)
                guard CanvasPacket.sha(try CanvasLocalFile.read(recoveryURL)) == CanvasPacket.sha(bytes) else {
                    throw ScenePersistenceError.unreadable
                }
            }
            let source = scene
            let pendingURL = try CanvasRuntime.stateURL(.scene).deletingLastPathComponent()
                .appendingPathComponent("CanvasPending-\(UUID().uuidString.lowercased()).json")
            #if DEBUG
            if case .isolated = CanvasRuntime.launch { throw CanvasFileWorkspace.Failure.permission }
            #endif
            let preserved = try CanvasFileWorkspace.bytes(source)
            try CanvasLocalFile.write(preserved,to:pendingURL)
            guard CanvasPacket.sha(try CanvasLocalFile.read(pendingURL)) == CanvasPacket.sha(preserved) else {
                throw ScenePersistenceError.unreadable
            }
            let snapshot: CanvasFileWorkspace.Snapshot
            if let id {
                snapshot = try workspace.load(id)
            } else {
                guard let preview = await filePreview?(source),
                      try CanvasFileWorkspace.sceneSHA(scene) == CanvasFileWorkspace.sceneSHA(source), !inkBusy else {
                    throw CanvasFileWorkspace.Failure.conflict
                }
                try Task.checkCancellation()
                snapshot = try workspace.save(source,preview:preview,expected:nil)
            }
            guard try CanvasFileWorkspace.sceneSHA(scene) == CanvasFileWorkspace.sceneSHA(source),
                  !inkBusy, !vaultDirty, !vaultSaving else { throw CanvasFileWorkspace.Failure.conflict }
            try Task.checkCancellation()
            let binding = CanvasFileWorkspace.Binding(bookmark:bookmark,sceneID:snapshot.scene.id,
                savedSceneSHA:try CanvasFileWorkspace.sceneSHA(snapshot.scene))
            try writeWorkspaceBinding(binding)
            switched = true
            fileWorkspace = workspace
            workspaceToken = snapshot.token
            if id != nil { try importScene(snapshot.scene) }
            try CanvasLocalFile.write(CanvasFileWorkspace.bytes(snapshot.scene),to:CanvasRuntime.stateURL(.scene))
            sceneReadable = true
            sceneRecoveryNotice = ""
            fileWorkspaceState = .ready
            fileWorkspaceStatus = "Files 원본 · \(folder.lastPathComponent)/\(snapshot.scene.id.uuidString.lowercased()).sill · 저장 완료"
        } catch {
            if switched { blockFileWorkspace(error) }
            else if (try? CanvasFileWorkspace.sceneSHA(scene)) != (try? CanvasFileWorkspace.sceneSHA(startingScene)) {
                fileWorkspaceState = .pending
                fileWorkspaceStatus = "폴더 연결 중 입력이 바뀌었습니다. 기존 위치에 미저장 복구본을 보존합니다."
                scheduleSave()
            } else {
                fileWorkspaceState = priorState
                fileWorkspaceStatus = priorStatus
            }
            status = "저장 위치 연결 실패: \(error.localizedDescription)"
        }
    }

    func refreshFileWorkspace() {
        if isDocumentSource { refreshDocumentWorkspace(); return }
        guard let workspace = fileWorkspace, let binding = workspaceBinding,
              fileWorkspaceState != .blocked, !fileSaveBusy, !inkBusy, !vaultDirty, !vaultSaving else { return }
        do {
            let latest = try workspace.load(binding.sceneID)
            guard latest.token != workspaceToken else { return }
            guard try CanvasFileWorkspace.sceneSHA(scene) == binding.savedSceneSHA else {
                throw CanvasFileWorkspace.Failure.conflict
            }
            try importScene(latest.scene)
            try writeWorkspaceBinding(.init(bookmark:binding.bookmark,sceneID:latest.scene.id,
                savedSceneSHA:CanvasFileWorkspace.sceneSHA(latest.scene)))
            workspaceToken = latest.token
            try CanvasLocalFile.write(CanvasFileWorkspace.bytes(latest.scene),to:CanvasRuntime.stateURL(.scene))
            fileWorkspaceState = .ready
            fileWorkspaceStatus = "Files 원본의 외부 변경을 열었습니다."
        } catch { blockFileWorkspace(error) }
    }

    func saveFileWorkspace() async {
        if isDocumentSource { await saveDocumentWorkspace(); return }
        guard let workspace = fileWorkspace, let binding = workspaceBinding,
              fileWorkspaceState != .blocked, !fileSaveBusy, !inkBusy else { return }
        let source = scene
        fileSaveBusy = true
        defer {
            fileSaveBusy = false
            if !Task.isCancelled, fileWorkspaceState == .pending &&
                (try? CanvasFileWorkspace.sceneSHA(scene)) != (try? CanvasFileWorkspace.sceneSHA(source)) { scheduleSave() }
        }
        do {
            try Task.checkCancellation()
            guard source.id == binding.sceneID else { throw CanvasFileWorkspace.Failure.conflict }
            if try CanvasFileWorkspace.sceneSHA(source) == binding.savedSceneSHA {
                guard try workspace.load(source.id).token == workspaceToken else { throw CanvasFileWorkspace.Failure.conflict }
                fileWorkspaceState = .ready
                fileWorkspaceStatus = "Files 원본 · \(workspace.folder.lastPathComponent) · 저장 확인 완료"
                return
            }
            guard let preview = await filePreview?(source) else { throw CanvasFileWorkspace.Failure.invalidDocument }
            try Task.checkCancellation()
            guard try CanvasFileWorkspace.sceneSHA(source) == CanvasFileWorkspace.sceneSHA(scene), !inkBusy else { return }
            let snapshot = try workspace.save(source,preview:preview,expected:workspaceToken)
            try writeWorkspaceBinding(.init(bookmark:binding.bookmark,sceneID:source.id,
                savedSceneSHA:CanvasFileWorkspace.sceneSHA(source)))
            workspaceToken = snapshot.token
            fileWorkspaceState = .ready
            fileWorkspaceStatus = "Files 원본 · \(workspace.folder.lastPathComponent) · 자동 저장 완료"
        } catch is CancellationError {
            fileWorkspaceStatus = "Files 원본 저장 취소 · 미저장 복구본 보존"
        } catch { blockFileWorkspace(error) }
    }

    func retryFileWorkspaceSave() {
        if isDocumentSource { status = "전체 문서 원본을 다시 확인한 뒤 저장하세요."; return }
        guard let workspace = fileWorkspace, let binding = workspaceBinding, let token = workspaceToken else {
            status = "원본 저장 기준을 확인할 수 없습니다. 원본을 다시 열거나 다른 폴더에 안전 내보내세요."
            return
        }
        do {
            let current = try workspace.load(binding.sceneID)
            guard current.token == token,
                  try CanvasFileWorkspace.sceneSHA(current.scene) == binding.savedSceneSHA else {
                throw CanvasFileWorkspace.Failure.conflict
            }
            fileWorkspaceState = .pending
            saveNow()
        } catch { blockFileWorkspace(error) }
    }

    private enum ScenePersistenceError: LocalizedError {
        case unreadable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "칠판 원본을 복원하지 못했습니다. 기존 파일을 보존하며 저장을 중단합니다. 원본 파일을 복구한 뒤 칠판을 다시 여세요."
            case .tooLarge:
                return "칠판 저장 크기 한도를 넘었습니다. 마지막 정상 저장본을 유지했습니다."
            }
        }
    }
    @Published var proposalText = "" {
        didSet { handwritingRequest = nil }
    }
    @Published var proposedNode: UUID? {
        didSet {
            handwritingRequest = nil
            if oldValue != proposedNode {
                proposalContext = proposedNode.flatMap { id in
                    scene.nodes.first(where:{ $0.id == id }).map {
                        (sessionID:UUID(),sceneID:scene.id,generation:noteSceneGeneration,node:$0)
                    }
                }
            }
        }
    }
    @Published private(set) var commentSession: CanvasCommentSession?
    @Published var commentText = ""
    @Published var commentInputBusy = false
    private var commentSelectionGeneration: UInt64 = 0
    private var commentContext: (sceneGeneration: UInt64, selectionGeneration: UInt64)?

    @discardableResult
    func beginCommentEdit() -> UUID? {
        if commentInputBusy { return commentSession?.id }
        if let session = commentSession {
            if !commentText.utf8.elementsEqual(session.text.utf8) { return session.id }
        }
        guard let id = selectedNode, let session = scene.commentSession(for:id) else {
            status = "선택한 요소의 사용자 댓글을 구분할 수 없습니다. 기존 주석은 그대로 보존합니다."
            return nil
        }
        commentSession = session
        commentText = session.text
        commentInputBusy = false
        commentContext = (linkSceneGeneration,commentSelectionGeneration)
        return session.id
    }

    var commentIsCurrent: Bool {
        guard !documentEditingBlocked else { return false }
        guard let session = commentSession, let context = commentContext else { return false }
        return selectedNode == session.node.id && session.matches(scene) &&
            context.sceneGeneration == linkSceneGeneration &&
            context.selectionGeneration == commentSelectionGeneration
    }

    @discardableResult
    func discardComment(sessionID: UUID) -> Bool {
        guard !commentInputBusy, commentSession?.id == sessionID else { return false }
        commentSession = nil
        commentContext = nil
        commentText = ""
        status = "저장 전 댓글 초안을 버렸습니다. 저장된 댓글은 그대로 유지됩니다."
        return true
    }

    @discardableResult
    func confirmComment(sessionID: UUID) -> Bool {
        guard commentSession?.id == sessionID else { return false }
        guard !commentInputBusy, commentIsCurrent,
              let session = commentSession else {
            status = "요소나 장면이 바뀌었거나 입력 중입니다. 댓글 입력을 보존하며 덮어쓰지 않습니다."
            return false
        }
        let before = scene
        var next = scene
        guard next.setUserComment(commentText,session:session) else {
            status = "댓글이 비어 있거나 장면 전송 한도를 넘었습니다. 입력과 기존 주석을 보존합니다."
            return false
        }
        scene = next
        recordGraphEdit(before:before)
        commentSession = nil
        commentContext = nil
        status = "카드 댓글을 저장했습니다. 원본 요소와 에이전트 주석은 보존했습니다."
        return true
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
    @Published private var graphUndo: (before: CanvasScene, after: CanvasScene)?
    @Published private var graphRedo: (before: CanvasScene, after: CanvasScene)?
    private var graphRequiresPersistence = false
    private var graphPersistenceEpoch: UInt64?

    private func recordGraphEdit(before: CanvasScene, persistHistory: Bool = false) {
        graphUndo = (before,scene)
        graphRedo = nil
        graphRequiresPersistence = persistHistory
        graphPersistenceEpoch = persistHistory ? linkSceneGeneration : nil
    }

    @Published private(set) var cardMergeDraft: CanvasCardMerge.Draft?
    private var cardMergeEpoch: UInt64?
    private var cardMergeSelectionGeneration: UInt64?

    var cardMergeInputAllowed: Bool {
        canApplyReconciledCanvas && mode == .select && nodeResizeDrag == nil &&
        nodeRotationDrag == nil && endpointDrag == nil && linkStart == nil
    }

    var canBeginCardMerge: Bool {
        guard cardMergeInputAllowed, cardMergeDraft == nil, let id = selectedNode else { return false }
        return (try? CanvasCardMerge.Draft(scene:scene,memberIDs:[id])) != nil
    }

    var canAppendCardMerge: Bool {
        guard cardMergeInputAllowed, let draft = cardMergeDraft, let id = selectedNode,
              cardMergeEpoch == linkSceneGeneration else { return false }
        return (try? draft.appending(id,in:scene)) != nil
    }

    var canConfirmCardMerge: Bool {
        guard cardMergeInputAllowed, let draft = cardMergeDraft, draft.memberIDs.count >= 2,
              cardMergeEpoch == linkSceneGeneration, cardMergeSelectionGeneration == noteSelectionGeneration,
              selectedNode == draft.memberIDs.last else { return false }
        return (try? CanvasFileWorkspace.sceneSHA(scene)) == draft.sceneSHA
    }

    func cancelCardMerge() {
        cardMergeDraft = nil
        cardMergeEpoch = nil
        cardMergeSelectionGeneration = nil
    }

    func beginCardMerge(_ expected: CanvasNode) {
        guard canBeginCardMerge, selectedNode == expected.id,
              scene.nodes.contains(where:{ CanvasScene.sameNode($0,expected) }) else { return }
        do {
            cardMergeDraft = try CanvasCardMerge.Draft(scene:scene,memberIDs:[expected.id])
            cardMergeEpoch = linkSceneGeneration
            cardMergeSelectionGeneration = noteSelectionGeneration
            status = "첫 카드를 선택했습니다. 다음 카드를 선택하고 병합 순서에 추가하세요. 원본은 유지됩니다."
        } catch { status = error.localizedDescription }
    }

    func appendCardMerge(_ expected: CanvasNode) {
        guard canAppendCardMerge, selectedNode == expected.id, let draft = cardMergeDraft,
              scene.nodes.contains(where:{ CanvasScene.sameNode($0,expected) }) else { return }
        do {
            cardMergeDraft = try draft.appending(expected.id,in:scene)
            cardMergeSelectionGeneration = noteSelectionGeneration
            status = "병합 순서에 카드를 추가했습니다. 원본과 부모·자식 관계는 바꾸지 않았습니다."
        } catch { status = error.localizedDescription }
    }

    @discardableResult
    func confirmCardMerge() -> Bool {
        guard canConfirmCardMerge, let draft = cardMergeDraft else {
            status = CanvasCardMerge.Failure.changed.localizedDescription
            return false
        }
        do {
            let before = scene
            let applied = try draft.applying(to:before)
            try persistScene(applied.scene)
            scene = applied.scene
            selectedNode = applied.cardID
            recordGraphEdit(before:before,persistHistory:true)
            status = "순서가 있는 병합 카드를 만들고 복구본에 보관했습니다. 원본 카드는 그대로이며 Files 원본 저장은 별도 상태를 확인하세요."
            return true
        } catch { status = "병합하지 않았습니다. \(error.localizedDescription)"; return false }
    }

    @discardableResult
    func unmergeCard(_ expected: CanvasNode) -> Bool {
        guard cardMergeInputAllowed, cardMergeDraft == nil, selectedNode == expected.id,
              scene.nodes.contains(where:{ CanvasScene.sameNode($0,expected) }) else { return false }
        do {
            let before = scene
            let next = try CanvasCardMerge.unmerging(expected.id,in:before)
            try persistScene(next)
            scene = next
            recordGraphEdit(before:before,persistHistory:true)
            status = "병합 연결을 해제하고 복구본에 보관했습니다. 합친 본문·원본·부모자식·다른 연결은 유지했습니다."
            return true
        } catch { status = "병합을 해제하지 않았습니다. \(error.localizedDescription)"; return false }
    }

    @Published private(set) var cardTagFilter: String?
    @Published private(set) var cardTagInputBusy = false
    private var cardTagEditor: (id:UUID, nodeID:UUID, sceneSHA:String, epoch:UInt64, selection:UInt64)?

    var availableCardTags: [String] { CanvasCardTags.available(in:scene) }
    var cardTagVisibility: CanvasScene.Visibility { CanvasCardTags.visibility(in:scene,filter:cardTagFilter) }
    var cardTagDisplayScene: CanvasScene {
        var displayed = displayedScene
        guard cardTagFilter != nil else { return displayed }
        let visible = cardTagVisibility
        displayed.nodes.removeAll { !visible.nodeIDs.contains($0.id) }
        displayed.links.removeAll { !visible.linkIDs.contains($0.id) }
        displayed.annotations.removeAll { !visible.annotationIDs.contains($0.id) }
        return displayed
    }

    func setCardTagFilter(_ input: String?) {
        if let input {
            guard cardMergeInputAllowed, cardMergeDraft == nil,
                  availableCardTags.contains(where:{ CanvasCardTags.key($0) == CanvasCardTags.key(input) }) else { return }
        }
        cardTagFilter = input
        let visible = cardTagVisibility
        if selectedNode.map({ !visible.nodeIDs.contains($0) }) == true { selectedNode = nil }
        if selectedLink.map({ !visible.linkIDs.contains($0) }) == true { clearLinkSelection() }
        status = input.map { "\($0) 카드 필터 · 원본 획과 도형은 표시합니다." } ?? "태그 필터를 해제했습니다. 저장된 카드와 태그는 그대로입니다."
    }

    var canBeginCardTagInput: Bool {
        guard cardMergeInputAllowed, cardMergeDraft == nil, let id = selectedNode,
              let node = scene.nodes.first(where:{ $0.id == id }), node.kind == .note,
              node.confidence == .confirmed else { return false }
        return (try? CanvasCardTags.tags(for:id,in:scene)) != nil
    }

    @discardableResult
    func beginCardTagInput() -> UUID? {
        guard canBeginCardTagInput, let id = selectedNode,
              let sha = try? CanvasFileWorkspace.sceneSHA(scene) else { return nil }
        let owner = UUID()
        cardTagEditor = (owner,id,sha,linkSceneGeneration,noteSelectionGeneration)
        cardTagInputBusy = true
        return owner
    }

    func cancelCardTagInput(sessionID:UUID) {
        guard cardTagEditor?.id == sessionID else { return }
        cardTagEditor = nil
        cardTagInputBusy = false
    }

    @discardableResult
    func finishCardTagInput(_ input: String, sessionID:UUID) -> Bool {
        guard let editor = cardTagEditor, editor.id == sessionID else { return false }
        cancelCardTagInput(sessionID:sessionID)
        guard cardMergeInputAllowed, cardMergeDraft == nil,
              selectedNode == editor.nodeID, linkSceneGeneration == editor.epoch,
              noteSelectionGeneration == editor.selection,
              (try? CanvasFileWorkspace.sceneSHA(scene)) == editor.sceneSHA else {
            status = CanvasCardTags.Failure.changed.localizedDescription
            return false
        }
        do {
            let before = scene
            let next = try CanvasCardTags.adding(input,to:editor.nodeID,in:before)
            guard next.revision != before.revision else {
                status = "이미 같은 태그가 있습니다. 기존 표기와 저장본을 유지했습니다."
                return true
            }
            try persistScene(next)
            scene = next
            recordGraphEdit(before:before,persistHistory:true)
            status = "카드 태그를 복구본에 보관했습니다. 원본 저장 상태를 확인하세요."
            return true
        } catch { status = "태그를 추가하지 않았습니다. \(error.localizedDescription)"; return false }
    }

    struct NodeResizeDrag {
        let owner: UUID
        let generation: UInt64
        let sceneID: UUID
        let revision: Int
        let expected: CanvasNode
        var frame: CanvasRect
    }
    @Published private(set) var nodeResizeDrag: NodeResizeDrag?

    private func nodeResizeIsCurrent(_ drag: NodeResizeDrag) -> Bool {
        !documentEditingBlocked && mode == .select && selectedNode == drag.expected.id &&
            drag.generation == linkSceneGeneration && scene.id == drag.sceneID &&
            scene.revision == drag.revision && scene.visibility.nodeIDs.contains(drag.expected.id) &&
            scene.nodes.contains { CanvasScene.sameNode($0,drag.expected) }
    }

    @discardableResult
    func beginNodeResize(_ expected: CanvasNode, sceneID: UUID, owner: UUID) -> Bool {
        guard nodeResizeDrag == nil, nodeRotationDrag == nil, endpointDrag == nil, scene.id == sceneID,
              expected.hasValidRotation, expected.frame.isValidLinkFrame else { return false }
        let drag = NodeResizeDrag(owner:owner,generation:linkSceneGeneration,sceneID:sceneID,
            revision:scene.revision,expected:expected,frame:expected.frame)
        guard nodeResizeIsCurrent(drag) else { return false }
        nodeResizeDrag = drag
        return true
    }

    @discardableResult
    func cancelNodeResize(owner: UUID) -> Bool {
        guard nodeResizeDrag?.owner == owner else { return false }
        nodeResizeDrag = nil
        return true
    }

    @discardableResult
    func updateNodeResize(owner: UUID, translation: CanvasPoint) -> Bool {
        guard var drag = nodeResizeDrag, drag.owner == owner else { return false }
        guard let delta = drag.expected.rotatedVector(translation,inverse:true),
              let worldHalf = drag.expected.rotatedVector(.init(x:delta.x / 2,y:delta.y / 2)) else {
            cancelNodeResize(owner:owner)
            return false
        }
        var frame = drag.expected.frame
        frame.width += delta.x
        frame.height += delta.y
        // 회전된 좌상단을 고정하고 손잡이는 화면 이동량 그대로 추종한다.
        frame.x += worldHalf.x - delta.x / 2
        frame.y += worldHalf.y - delta.y / 2
        var resized = drag.expected
        resized.frame = frame
        guard nodeResizeIsCurrent(drag), frame.isValidLinkFrame, resized.hasValidRotation else {
            cancelNodeResize(owner:owner)
            status = "요소 상태나 크기가 바뀌어 크기 조절을 취소했습니다. 최신 내용을 유지합니다."
            return false
        }
        drag.frame = frame
        nodeResizeDrag = drag
        return true
    }

    var displayedScene: CanvasScene {
        var preview = scene
        if let drag = nodeResizeDrag, nodeResizeIsCurrent(drag),
           let index = preview.nodes.firstIndex(where:{ $0.id == drag.expected.id }) {
            preview.nodes[index].frame = drag.frame
        }
        if let drag = nodeRotationDrag, nodeRotationIsCurrent(drag),
           let index = preview.nodes.firstIndex(where:{ $0.id == drag.expected.id }) {
            preview.nodes[index].rotationDegrees = drag.degrees
        }
        return preview
    }

    @discardableResult
    func finishNodeResize(owner: UUID) -> Bool {
        guard let drag = nodeResizeDrag, drag.owner == owner else { return false }
        let current = nodeResizeIsCurrent(drag)
        nodeResizeDrag = nil
        guard current, drag.frame.isValidLinkFrame,
              let index = scene.nodes.firstIndex(where:{ $0.id == drag.expected.id }) else { return false }
        guard drag.frame != drag.expected.frame else { return true }
        let before = scene
        var next = scene
        next.nodes[index].frame = drag.frame
        next.revision += 1
        scene = next
        recordGraphEdit(before:before)
        status = "요소 크기를 바꿨습니다. 구조 수정 되돌리기와 다시 실행을 사용할 수 있습니다."
        return true
    }

    @discardableResult
    func adjustNodeSize(_ expected: CanvasNode, sceneID: UUID, by translation: CanvasPoint) -> Bool {
        let owner = UUID()
        guard beginNodeResize(expected,sceneID:sceneID,owner:owner) else { return false }
        guard let world = expected.rotatedVector(translation),
              updateNodeResize(owner:owner,translation:world) else {
            cancelNodeResize(owner:owner)
            return false
        }
        return finishNodeResize(owner:owner)
    }

    struct NodeRotationDrag {
        let owner: UUID
        let generation: UInt64
        let sceneID: UUID
        let revision: Int
        let expected: CanvasNode
        var degrees: Double?
    }
    @Published private(set) var nodeRotationDrag: NodeRotationDrag?

    private func nodeRotationIsCurrent(_ drag: NodeRotationDrag) -> Bool {
        !documentEditingBlocked && mode == .select && selectedNode == drag.expected.id &&
            drag.generation == linkSceneGeneration && scene.id == drag.sceneID &&
            scene.revision == drag.revision && scene.visibility.nodeIDs.contains(drag.expected.id) &&
            scene.nodes.contains { CanvasScene.sameNode($0,drag.expected) }
    }

    @discardableResult
    func beginNodeRotation(_ expected: CanvasNode, sceneID: UUID, owner: UUID) -> Bool {
        guard nodeRotationDrag == nil, nodeResizeDrag == nil, endpointDrag == nil,
              scene.id == sceneID, expected.frame.isValidLinkFrame, expected.hasValidRotation else { return false }
        let drag = NodeRotationDrag(owner:owner,generation:linkSceneGeneration,sceneID:sceneID,
            revision:scene.revision,expected:expected,degrees:expected.rotationDegrees)
        guard nodeRotationIsCurrent(drag) else { return false }
        nodeRotationDrag = drag
        return true
    }

    @discardableResult
    func cancelNodeRotation(owner: UUID) -> Bool {
        guard nodeRotationDrag?.owner == owner else { return false }
        nodeRotationDrag = nil
        return true
    }

    @discardableResult
    func updateNodeRotation(owner: UUID, degrees: Double) -> Bool {
        guard var drag = nodeRotationDrag, drag.owner == owner else { return false }
        var rotated = drag.expected
        rotated.rotationDegrees = degrees
        guard nodeRotationIsCurrent(drag), rotated.hasValidRotation else {
            cancelNodeRotation(owner:owner)
            status = "요소 상태나 회전값을 확인할 수 없어 회전을 취소했습니다. 최신 내용을 유지합니다."
            return false
        }
        // 0도 옛 문서의 nil과 no-op은 저장 표현까지 그대로 둔다.
        drag.degrees = degrees == (drag.expected.rotationDegrees ?? 0) ? drag.expected.rotationDegrees : degrees
        nodeRotationDrag = drag
        return true
    }

    @discardableResult
    func updateNodeRotation(owner: UUID, from start: CanvasPoint, to point: CanvasPoint) -> Bool {
        guard let drag = nodeRotationDrag, drag.owner == owner else { return false }
        let center = drag.expected.frame.center
        let a = CanvasPoint(x:start.x - center.x,y:start.y - center.y)
        let b = CanvasPoint(x:point.x - center.x,y:point.y - center.y)
        guard [a.x,a.y,b.x,b.y].allSatisfy(\.isFinite),
              hypot(a.x,a.y) > 0, hypot(b.x,b.y) > 0 else {
            cancelNodeRotation(owner:owner)
            return false
        }
        let difference = atan2(b.y,b.x) - atan2(a.y,a.x)
        let delta = atan2(sin(difference),cos(difference)) * 180 / .pi
        return updateNodeRotation(owner:owner,degrees:(drag.expected.rotationDegrees ?? 0) + delta)
    }

    @discardableResult
    func finishNodeRotation(owner: UUID) -> Bool {
        guard let drag = nodeRotationDrag, drag.owner == owner else { return false }
        let current = nodeRotationIsCurrent(drag)
        nodeRotationDrag = nil
        guard current, let index = scene.nodes.firstIndex(where:{ $0.id == drag.expected.id }) else { return false }
        guard drag.degrees != drag.expected.rotationDegrees else { return true }
        let before = scene
        var next = scene
        next.nodes[index].rotationDegrees = drag.degrees
        guard next.nodes[index].hasValidRotation else { return false }
        next.revision += 1
        scene = next
        recordGraphEdit(before:before)
        status = "요소를 회전했습니다. 구조 수정 되돌리기와 다시 실행을 사용할 수 있습니다."
        return true
    }

    @discardableResult
    func rotateNode(_ expected: CanvasNode, sceneID: UUID, to degrees: Double) -> Bool {
        let owner = UUID()
        guard beginNodeRotation(expected,sceneID:sceneID,owner:owner),
              updateNodeRotation(owner:owner,degrees:degrees) else { return false }
        return finishNodeRotation(owner:owner)
    }

    var canUndoGraph: Bool {
        guard !documentEditingBlocked else { return false }
        guard let undo = graphUndo, scene.id == undo.after.id else { return false }
        if graphRequiresPersistence {
            guard scene.revision < Int.max, graphPersistenceEpoch == linkSceneGeneration,
                  cardMergeInputAllowed, cardMergeDraft == nil else { return false }
        }
        if undo.before.drawingBase64 != undo.after.drawingBase64 {
            let expected = undo.after
            guard let currentBytes = try? CanvasInkTextEditing.encode(scene), let expectedBytes = try? CanvasInkTextEditing.encode(expected) else { return false }
            return scene.revision < Int.max && inkTextEditAllowed && pendingInkTextEditing?.hasPendingWork != true && pendingInkSpacing?.hasPendingWork != true &&
                currentBytes == expectedBytes && inkSpacingDrawingIsCurrent
        }
        return scene.hasSameGraph(as:undo.after)
    }

    func undoGraphEdit() {
        guard canUndoGraph, let undo = graphUndo else {
            status = "구조가 바뀌어 이전 수정으로 되돌릴 수 없습니다. 최신 내용을 유지합니다."
            return
        }
        if undo.before.drawingBase64 != undo.after.drawingBase64 {
            var next = undo.before; next.revision = scene.revision + 1
            do { try persistScene(next); installInkTextScene(next) }
            catch { status = "원본 획 간격을 되돌리지 않았습니다. \(error.localizedDescription)"; return }
        } else {
            var next = scene
            next.nodes = undo.before.nodes
            next.links = undo.before.links
            next.annotations = undo.before.annotations
            next.revision += 1
            if graphRequiresPersistence {
                do { try persistScene(next) }
                catch { status = "카드 수정을 되돌리지 않았습니다. \(error.localizedDescription)"; return }
            }
            scene = next
        }
        graphUndo = nil
        graphRedo = undo.before.drawingBase64 != undo.after.drawingBase64 ? (scene,undo.after) : undo
        if graphRequiresPersistence { graphPersistenceEpoch = linkSceneGeneration }
        status = undo.before.drawingBase64 != undo.after.drawingBase64 ? "원본 획과 간격 수정을 되돌려 복구본에 저장했습니다." : "구조 수정을 되돌렸습니다. 현재 원본 획은 그대로 보존했습니다."
    }

    var canRedoGraph: Bool {
        guard !documentEditingBlocked else { return false }
        guard let redo = graphRedo, scene.id == redo.before.id else { return false }
        if graphRequiresPersistence {
            guard scene.revision < Int.max, graphPersistenceEpoch == linkSceneGeneration,
                  cardMergeInputAllowed, cardMergeDraft == nil else { return false }
        }
        if redo.before.drawingBase64 != redo.after.drawingBase64 {
            let expected = redo.before
            guard let currentBytes = try? CanvasInkTextEditing.encode(scene), let expectedBytes = try? CanvasInkTextEditing.encode(expected) else { return false }
            return scene.revision < Int.max && inkTextEditAllowed && pendingInkTextEditing?.hasPendingWork != true && pendingInkSpacing?.hasPendingWork != true &&
                currentBytes == expectedBytes && inkSpacingDrawingIsCurrent
        }
        return scene.hasSameGraph(as:redo.before)
    }

    func redoGraphEdit() {
        guard canRedoGraph, let redo = graphRedo else {
            status = "구조가 바뀌어 다시 실행하지 않았습니다. 최신 내용을 유지합니다."
            return
        }
        if redo.before.drawingBase64 != redo.after.drawingBase64 {
            var next = redo.after; next.revision = scene.revision + 1
            do { try persistScene(next); installInkTextScene(next) }
            catch { status = "원본 획 간격을 다시 실행하지 않았습니다. \(error.localizedDescription)"; return }
        } else {
            var next = scene
            next.nodes = redo.after.nodes
            next.links = redo.after.links
            next.annotations = redo.after.annotations
            next.revision += 1
            if graphRequiresPersistence {
                do { try persistScene(next) }
                catch { status = "카드 수정을 다시 실행하지 않았습니다. \(error.localizedDescription)"; return }
            }
            scene = next
        }
        graphUndo = redo.before.drawingBase64 != redo.after.drawingBase64 ? (redo.before,scene) : redo
        graphRedo = nil
        if graphRequiresPersistence { graphPersistenceEpoch = linkSceneGeneration }
        status = redo.before.drawingBase64 != redo.after.drawingBase64 ? "원본 획과 간격 수정을 다시 실행해 복구본에 저장했습니다." : "구조 수정을 다시 실행했습니다. 현재 원본 획은 그대로 보존했습니다."
    }

    struct EndpointDrag {
        let owner: UUID
        let generation: UInt64
        let sceneID: UUID
        let revision: Int
        let expected: CanvasLink
        let endpoint: CanvasLink.Endpoint
        var anchor: CanvasLinkAnchor?
    }
    private var linkSceneGeneration: UInt64 = 0
    @Published private(set) var selectedLink: UUID?
    @Published private(set) var endpointDrag: EndpointDrag?

    func clearLinkSelection() {
        selectedLink = nil
        endpointDrag = nil
    }

    @discardableResult
    func cancelEndpointDrag(owner: UUID) -> Bool {
        guard endpointDrag?.owner == owner else { return false }
        endpointDrag = nil
        return true
    }

    func selectLink(_ id: UUID) {
        guard mode == .select, cardTagVisibility.linkIDs.contains(id),
              let link = scene.links.first(where:{ $0.id == id }), scene.linkEndpoints(link) != nil else { return }
        selectedNode = nil
        clearPendingLink()
        endpointDrag = nil
        selectedLink = id
        status = "연결선을 선택했습니다. 시작점이나 끝점을 끌어 연결 위치를 바꾸세요."
    }

    private func endpointDragIsCurrent(_ drag: EndpointDrag) -> Bool {
        !documentEditingBlocked && mode == .select && selectedLink == drag.expected.id && drag.generation == linkSceneGeneration &&
            scene.id == drag.sceneID && scene.revision == drag.revision &&
            scene.links.contains { CanvasScene.sameLink($0,drag.expected) }
    }

    @discardableResult
    func beginEndpointDrag(_ endpoint: CanvasLink.Endpoint, linkID: UUID, owner: UUID) -> Bool {
        guard endpointDrag == nil, nodeResizeDrag == nil, nodeRotationDrag == nil, mode == .select, selectedLink == linkID,
              let link = scene.links.first(where:{ $0.id == linkID }), scene.linkEndpoints(link) != nil else { return false }
        endpointDrag = EndpointDrag(owner:owner,generation:linkSceneGeneration,sceneID:scene.id,revision:scene.revision,
            expected:link,endpoint:endpoint,anchor:endpoint == .from ? link.fromAnchor : link.toAnchor)
        return true
    }

    @discardableResult
    func updateEndpointDrag(owner: UUID, to point: CanvasPoint) -> Bool {
        guard var drag = endpointDrag, drag.owner == owner else { return false }
        guard endpointDragIsCurrent(drag) else {
            status = "드래그 중 장면이 바뀌어 연결점을 수정하지 않았습니다. 최신 내용을 유지합니다."
            return false
        }
        let nodeID = drag.endpoint == .from ? drag.expected.from : drag.expected.to
        guard let node = scene.nodes.first(where:{ $0.id == nodeID }), node.hasValidRotation,
              let local = node.scenePoint(point,inverse:true),
              let anchor = CanvasLinkAnchor.nearest(to:local,in:node.frame) else {
            endpointDrag = nil
            status = "연결 위치를 확인할 수 없어 드래그를 취소했습니다."
            return false
        }
        drag.anchor = anchor
        endpointDrag = drag
        return true
    }

    func displayedLink(_ link: CanvasLink) -> CanvasLink {
        guard let drag = endpointDrag, drag.expected.id == link.id, endpointDragIsCurrent(drag) else { return link }
        var preview = link
        if drag.endpoint == .from { preview.fromAnchor = drag.anchor }
        else { preview.toAnchor = drag.anchor }
        return preview
    }

    @discardableResult
    func finishEndpointDrag(owner: UUID) -> Bool {
        guard let drag = endpointDrag, drag.owner == owner else { return false }
        let current = endpointDragIsCurrent(drag)
        let replacement = displayedLink(drag.expected)
        endpointDrag = nil
        guard current else {
            status = "드래그 중 장면이 바뀌어 연결점을 수정하지 않았습니다. 최신 내용을 유지합니다."
            return false
        }
        if CanvasScene.sameLink(drag.expected,replacement) { return true }
        let before = scene
        guard scene.editGraph(nodeEdits:[],linkEdits:[.init(expected:drag.expected,replacement:replacement)]) else {
            status = "연결점 상태를 확인할 수 없어 수정하지 않았습니다."
            return false
        }
        recordGraphEdit(before:before)
        status = "연결 위치를 바꿨습니다. 구조 수정 되돌리기와 다시 실행을 사용할 수 있습니다."
        return true
    }
    private var storedDrawing = PKDrawing()
    var drawing: PKDrawing {
        get { storedDrawing }
        set {
            guard !documentEditingBlocked else { return }
            inkMathRequest = nil
            inkMathSelectionGeneration &+= 1
            pendingInkTextEditing?.invalidatePending()
            pendingInkSpacing?.invalidatePending()
            objectWillChange.send()
            storedDrawing = newValue
            setInkSelection([])
            handwritingRequest = nil
            inkHistory.invalidate()
        }
    }
    @Published private(set) var linkStart: UUID?
    private var linkKind: CanvasLink.Kind = .general
    private var saveTask: Task<Void,Never>?
    private var handwritingRequest: UUID?
    private var proposalContext: (sessionID: UUID, sceneID: UUID, generation: UInt64, node: CanvasNode)?
    var proposalInputSessionID: UUID? { proposalContext?.sessionID }
    @Published private(set) var vaultNote: VaultNoteSnapshot?
    @Published var vaultDraft = "" {
        didSet {
            noteEditGeneration &+= 1
            if !changingNoteState { persistNoteDraft() }
        }
    }
    @Published private(set) var noteRecovery: VaultNoteRecovery?
    @Published private(set) var noteRecoveryNotice = ""
    @Published private(set) var noteRecoveryWriteFailed = false
    private let noteRecoveryOverride: URL?
    private var noteRecoveryURL: URL? {
        try? CanvasRuntime.stateURL(.noteRecovery,noteRecoveryOverride:noteRecoveryOverride)
    }
    private let noteRecoveryWrite: (Data,URL) throws -> Void
    private var noteRecoveryBytes: Data?
    private var noteRecoveryAttemptedBytes: Data?
    private var noteRecoveryReadable = true
    @Published private(set) var pdfViewReader: VaultPDFReader?
    @Published private(set) var pdfViewBase: VaultNoteSnapshot?
    @Published private(set) var pdfViewBusy = false
    @Published private(set) var pdfViewConflict: CanvasRelay.NoteConflict?
    private var pdfViewRequest = UUID()
    private var pdfViewMissingConfirmed = false
    private var pdfViewSceneID: UUID?
    private var pdfViewAddress = ""
    private var pdfViewOwner: CanvasDocument.PageSnapshot?
    private var pdfViewSource: VaultPDFExcerpt?
    var hasPendingPDFView: Bool { pdfExcerptRecovery?.viewRecovery != nil }
    var pdfViewCanEdit: Bool { pdfViewReader != nil && pdfViewOwner.map({ document.accepts($0) }) == true && !pdfViewBusy && pdfExcerptRecovery?.saveConflict?.requiresExplicitReconciliation != true && !noteReconciliationHeld }
    var pdfViewCanPersist: Bool { pdfViewCanEdit && pdfViewReader?.hasViewEdits == true && !vaultSaving && pdfExcerptRecovery?.viewRecovery?.submitted == nil && pdfExcerptRecoveryAttemptedBytes == nil }
    @Published private(set) var pdfExcerptRecovery: VaultPDFCreateRecovery?
    @Published private(set) var pdfExcerptRecoveryNotice = ""
    private let pdfExcerptRecoveryOverride: URL?
    private let pdfExcerptRecoveryWrite: (Data,URL) throws -> Void
    private var pdfExcerptRecoveryURL: URL? {
        try? CanvasRuntime.stateURL(.pdfExcerptRecovery,pdfExcerptRecoveryOverride:pdfExcerptRecoveryOverride)
    }
    private var pdfExcerptRecoveryBytes: Data?
    private var pdfExcerptRecoveryAttemptedBytes: Data?
    private var pdfExcerptRecoveryReadable = true
    private var changingNoteState = false
    @Published var vaultSelection = NSRange(location:0,length:0) {
        didSet { if oldValue != vaultSelection { noteSelectionGeneration &+= 1 } }
    }
    @Published var vaultInputBusy = false {
        didSet { if oldValue != vaultInputBusy { noteEditGeneration &+= 1 } }
    }
    private var noteInputSession: UUID?
    var vaultInputSessionID: UUID? {
        guard vaultNote != nil, noteContext.map(noteContextIsCurrent) == true else { return nil }
        return noteInputSession
    }
    @Published private(set) var vaultBlockEditing = false
    @Published var vaultBlockDraft = "" {
        didSet {
            noteEditGeneration &+= 1
            if !changingBlockState { persistBlockDraft() }
        }
    }
    @Published var vaultBlockSelection = NSRange(location:0,length:0)
    private var pendingBlockEdit: VaultBlockEdit?
    @Published private(set) var blockRecovery: VaultBlockRecovery?
    @Published private(set) var blockRecoveryNotice = ""
    private let blockRecoveryOverride: URL?
    private var blockRecoveryURL: URL? {
        try? CanvasRuntime.stateURL(.blockRecovery,blockRecoveryOverride:blockRecoveryOverride)
    }
    private var blockRecoveryBytes: Data?
    private var blockRecoveryReadable = true
    private var changingBlockState = false
    private var blockRecoveryWasRestored = false
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
    private var noteSelectionGeneration: UInt64 = 0
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

    var noteConflictChoice: NoteConflictLocalChoice? {
        guard let url = try? CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json"),
              let data = try? CanvasLocalFile.read(url), data.count <= 12*1024*1024 else { return nil }
        return try? JSONDecoder().decode(NoteConflictLocalChoice.self,from:data).validated()
    }
    var noteReconciliationHeld: Bool {
        guard let url = try? CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json") else { return true }
        if !FileManager.default.fileExists(atPath:url.path) { return false }
        if let bytes = try? CanvasLocalFile.read(url), let choice = try? JSONDecoder().decode(VaultPDFViewChoice.self,from:bytes).validated() { return !choice.closed }
        guard let choice = noteConflictChoice else { return true }
        return choice.sceneID == scene.id && choice.address == noteAddress && choice.phase != .completed && choice.phase != .superseded
    }
    var noteConflictPath: String? {
        noteRecovery?.base.path ?? blockRecovery?.base.path ?? vaultNote?.path ??
            noteConflictChoice.flatMap { $0.sceneID == scene.id && $0.address == noteAddress ? $0.path : nil }
    }
    var canCompareNoteConflict: Bool {
        noteRecoveryReadable && blockRecoveryReadable && pdfExcerptRecoveryReadable && !hasPendingPDFExcerpt && !noteRecoveryWriteFailed &&
        vaultDraft.utf8.count <= 1024*1024 && vaultBlockDraft.utf8.count <= 1024*1024 && noteConflictPath != nil && !vaultSaving && !vaultLoading && !vaultInputBusy && !inkBusy && !fileSaveBusy &&
        !hasPendingInkProposal && !inkMathInputBusy && !commentInputBusy && !noteToken.isEmpty
    }
    func captureNoteConflictLocal(path: String) throws -> NoteConflictLocalState {
        guard canCompareNoteConflict, noteConflictPath.map({ $0.utf8.elementsEqual(path.utf8) }) == true else { throw VaultBlockRecoveryError.context }
        return NoteConflictLocalState(sceneID:scene.id,path:path,address:noteAddress,sceneSHA256:try CanvasFileWorkspace.sceneSHA(scene),note:vaultNote,
            draft:vaultDraft,blockDraft:vaultBlockDraft,noteRecovery:noteRecovery,blockRecovery:blockRecovery,
            connectionGeneration:noteConnectionGeneration,sceneGeneration:noteSceneGeneration,sceneEditGeneration:linkSceneGeneration,
            editorGeneration:noteEditorGeneration,editGeneration:noteEditGeneration)
    }
    func installReconciledNote(_ selected: VaultNoteSnapshot, expected: NoteConflictLocalState,
                               archive: URL, archiveSHA: String) throws {
        guard try captureNoteConflictLocal(path:expected.path) == expected,
              CanvasPacket.sha(try CanvasLocalFile.read(archive)) == archiveSHA else { throw VaultBlockRecoveryError.changed }
        _ = try selected.validated(at:expected.path)
        // The entire original draft/base/submitted bytes and block operation ID already exist in archive.
        // Keep the choice barrier until the UI durably confirms both local records and the selected note.
        if noteRecovery != nil { try writeNoteRecovery(nil) }
        if blockRecovery != nil { try writeBlockRecovery(nil) }
        changingNoteState = true; changingBlockState = true
        defer { changingNoteState = false; changingBlockState = false }
        noteEditorGeneration &+= 1; noteInputSession = UUID(); noteRequest = nil
        noteContext = NoteContext(sceneID:scene.id,sceneGeneration:noteSceneGeneration,
            connectionGeneration:noteConnectionGeneration,editorGeneration:noteEditorGeneration,
            path:selected.path,nodeID:nil,blockID:nil)
        vaultNote = selected; vaultDraft = selected.text; vaultBlockEditing = false
        vaultBlockDraft = ""; pendingBlockEdit = nil; vaultSelection = NSRange(location:0,length:0)
        vaultBlocked = true
        refreshNoteCache(selected)
        vaultStatus = "선택한 원문을 재열었습니다. 이전 입력과 문단 작업 ID는 별도 복구본에 보존하며 완료 기록을 확인합니다."
    }
    func finishNoteReconciliation(_ selected: VaultNoteSnapshot) throws {
        guard let choice = noteConflictChoice, choice.sceneID == scene.id, choice.address == noteAddress,
              choice.phase == .completed, choice.path == selected.path, choice.resolvedSHA256 == selected.sha256,
              vaultNote?.sha256 == selected.sha256, vaultDraft.utf8.elementsEqual(selected.text.utf8),
              noteContext.map(noteContextIsCurrent) == true else { throw VaultBlockRecoveryError.changed }
        vaultBlocked = false
        vaultStatus = "명시 복구와 원문 재열기를 확인했습니다. 이전 미저장 입력·작업 ID는 보존본에서 계속 확인할 수 있습니다."
    }
    func resumeArchivedNoteDraft(_ saved: NoteConflictLocalState) throws {
        guard !noteReconciliationHeld, !vaultBlocked, !vaultDirty, !vaultSaving, !vaultLoading,
              !vaultInputBusy, saved.sceneID == scene.id, saved.address == noteAddress,
              saved.path == vaultNote?.path else { throw VaultBlockRecoveryError.context }
        if let record = saved.noteRecovery { vaultDraft = record.draft }
        else if let record = saved.blockRecovery {
            guard let note = vaultNote else { throw VaultBlockRecoveryError.context }
            // Reuse the selected current anchor; an old pending operation is never replayed on a new base.
            let text = try VaultMarkdownBlocks(note.text).replacing(record.blockID,with:record.draft)
            vaultDraft = text
        } else { vaultDraft = saved.draft }
        vaultStatus = "보존 입력을 새 원문 위 편집 초안으로만 열었습니다. 이전 작업 ID는 재전송하지 않았고 저장은 별도 확인입니다."
    }

    private var vaultWholeNoteDirty: Bool { !vaultDraft.utf8.elementsEqual((vaultNote?.text ?? "").utf8) }
    var vaultDirty: Bool {
        vaultWholeNoteDirty || (vaultBlockEditing && (pendingBlockEdit != nil || vaultBlockTextChanged))
    }
    private var vaultBlockTextChanged: Bool {
        guard let note = vaultNote, let id = vaultLinkedBlockID,
              let block = try? VaultMarkdownBlocks(note.text).resolve(id) else { return vaultBlockEditing }
        return !canonicalBlockText(vaultBlockDraft,original:note.text).utf8.elementsEqual(block.quote.utf8)
    }
    var vaultBlockCanSave: Bool {
        vaultBlockEditing && !noteReconciliationHeld && !vaultBlocked && blockRecovery?.saveConflict?.requiresExplicitReconciliation != true && (pendingBlockEdit != nil || vaultBlockTextChanged) &&
        !vaultInputBusy && !vaultSaving && !vaultLoading && noteContext.map(noteContextIsCurrent) == true
    }
    var vaultBlockHasPendingSave: Bool { pendingBlockEdit != nil }
    var vaultCanSave: Bool {
        !noteReconciliationHeld && noteRecoveryReadable && !noteRecoveryWriteFailed && !vaultBlockEditing && vaultNote != nil && vaultDirty && !vaultInputBusy && !vaultSaving && !vaultLoading && !vaultBlocked &&
        noteContext.map(noteContextIsCurrent) == true
    }
    var vaultCanAttach: Bool {
        !noteReconciliationHeld && !vaultBlockEditing && vaultNote != nil && !vaultDirty && !vaultInputBusy && !vaultSaving && !vaultLoading && !vaultBlocked &&
        noteContext.map(noteContextIsCurrent) == true
    }
    struct VaultPDFEditSession: Hashable {
        let inputSessionID: UUID
        let path: String
        let baseSha256: String
        let excerptID: UUID
    }

    var vaultPDFEditSession: VaultPDFEditSession? {
        guard !vaultBlockEditing, let note = vaultNote, let input = vaultInputSessionID,
              let base = try? VaultPDFCard.parse(note.text), let card = try? VaultPDFCard.parse(vaultDraft),
              card.sourceSHA256 == base.sourceSHA256 else { return nil }
        return VaultPDFEditSession(inputSessionID:input,path:note.path,baseSha256:note.sha256,excerptID:card.source.excerptID)
    }

    var vaultPDFCardMessage: String? {
        do {
            guard let source = try VaultPDFExcerpt.parse(vaultDraft) else { return nil }
            guard let card = try VaultPDFCard.parse(vaultDraft), let note = vaultNote,
                  let base = try VaultPDFCard.parse(note.text), card.sourceSHA256 == base.sourceSHA256 else {
                return "PDF 출처가 열었던 원문과 다릅니다. 제목·메모 편집 전에 Markdown 원문을 확인하세요."
            }
            return "PDF 발췌 · \(source.pdfPath) · \(source.pageIndex + 1)쪽. 인용과 출처는 선택 당시 원문입니다."
        } catch { return "PDF 출처 확인 필요 · \(error.localizedDescription)" }
    }

    func vaultPDFEditIsCurrent(_ session: VaultPDFEditSession) -> Bool {
        vaultPDFEditSession == session && noteContext.map(noteContextIsCurrent) == true
    }

    @discardableResult
    func editVaultPDF(_ field: VaultPDFCard.Field, text: String, session: VaultPDFEditSession) -> Bool {
        guard !noteReconciliationHeld, vaultPDFEditIsCurrent(session), !vaultSaving, !vaultLoading, !vaultBlocked,
              let card = try? VaultPDFCard.parse(vaultDraft) else { return false }
        do {
            let next = try card.replacing(field,with:text)
            if !next.utf8.elementsEqual(vaultDraft.utf8) { vaultDraft = next }
            return true
        } catch { vaultStatus = error.localizedDescription; return false }
    }

    struct VaultReviewSession: Identifiable {
        let id: UUID
        let card: VaultReviewCard
        var path: String { base.path }
        fileprivate let base: VaultNoteSnapshot
        fileprivate let inputSessionID: UUID
        fileprivate let editGeneration: UInt64
        fileprivate let selection: NSRange
        fileprivate let selectedNode: UUID?
        fileprivate let selectionGeneration: UInt64
    }

    struct VaultReviewEditSession: Hashable {
        let inputSessionID: UUID
        let path: String
        let baseSha256: String
        let cardID: String
        let selection: NSRange
        let selectedNode: UUID?
        let selectionGeneration: UInt64
    }

    var vaultReviewEditSession: VaultReviewEditSession? {
        guard !vaultBlockEditing, let note = vaultNote, let input = vaultInputSessionID,
              let card = try? VaultReviewCard.parse(vaultDraft) else { return nil }
        return VaultReviewEditSession(inputSessionID:input,path:note.path,baseSha256:note.sha256,
            cardID:card.metadata.cardID,selection:vaultSelection,selectedNode:selectedNode,
            selectionGeneration:noteSelectionGeneration)
    }

    func vaultReviewEditIsCurrent(_ session: VaultReviewEditSession) -> Bool {
        !vaultBlockEditing && vaultInputSessionID == session.inputSessionID &&
        vaultNote?.path == session.path && vaultNote?.sha256 == session.baseSha256 &&
        vaultSelection == session.selection && selectedNode == session.selectedNode &&
        noteSelectionGeneration == session.selectionGeneration
    }

    @discardableResult
    func editVaultReview(_ field: VaultReviewCard.Field, text: String,
                        session: VaultReviewEditSession) -> Bool {
        guard vaultReviewEditIsCurrent(session), !vaultSaving, !vaultLoading, !vaultBlocked else { return false }
        do {
            guard let card = try VaultReviewCard.parse(vaultDraft), card.metadata.cardID == session.cardID else { return false }
            let next = try card.replacing(field,with:text)
            if !next.utf8.elementsEqual(vaultDraft.utf8) { vaultDraft = next }
            if (try? VaultReviewCard.parse(next)) == nil {
                vaultStatus = "입력은 원문 초안에 보존했습니다. 카드 표식을 확인할 때까지 원문 편집으로 이어갑니다."
            }
            return true
        } catch { vaultStatus = error.localizedDescription; return false }
    }

    @discardableResult
    func pauseVaultNoteEditing() -> Bool {
        guard !vaultBlockEditing, !vaultSaving, !vaultLoading, !vaultInputBusy,
              vaultInputSessionID != nil, persistNoteDraft() else { return false }
        noteInputSession = UUID()
        return true
    }

    var vaultReviewCanInsert: Bool {
        vaultCanAttach && noteRecoveryReadable && !noteRecoveryWriteFailed &&
        ((try? VaultReviewCard.parse(vaultDraft)) == nil) && !vaultDraft.contains("ccr-review")
    }

    var vaultReviewCanBegin: Bool {
        vaultCanAttach && noteRecoveryReadable && !noteRecoveryWriteFailed &&
        (try? VaultReviewCard.parse(vaultDraft))?.ready == true
    }

    var vaultReviewMessage: String {
        do {
            guard let card = try VaultReviewCard.parse(vaultDraft) else {
                return "복습 카드를 추가하면 질문과 답을 나누어 작성할 수 있습니다."
            }
            return card.ready ? "저장된 원문으로 앞면과 뒷면을 복습합니다. 평가는 선택한 고정 간격으로 저장합니다." :
                VaultReviewError.empty.localizedDescription
        } catch { return error.localizedDescription }
    }

    @discardableResult
    func insertVaultReviewTemplate() -> Bool {
        guard vaultReviewCanInsert else { return false }
        do {
            vaultDraft = try VaultReviewCard.insertingTemplate(in:vaultDraft)
            vaultStatus = "복습 카드를 초안에 넣었습니다. 질문과 답을 작성하고 저장하세요."
            return true
        } catch { vaultStatus = error.localizedDescription; return false }
    }

    func beginVaultReview() -> VaultReviewSession? {
        guard vaultCanAttach, noteRecoveryReadable, !noteRecoveryWriteFailed,
              let base = vaultNote, let inputSessionID = vaultInputSessionID else { return nil }
        do {
            guard let card = try VaultReviewCard.parse(base.text) else { return nil }
            guard card.ready else { throw VaultReviewError.empty }
            return VaultReviewSession(id:UUID(),card:card,base:base,inputSessionID:inputSessionID,
                editGeneration:noteEditGeneration,selection:vaultSelection,selectedNode:selectedNode,
                selectionGeneration:noteSelectionGeneration)
        } catch { vaultStatus = error.localizedDescription; return nil }
    }

    func vaultReviewIsCurrent(_ session: VaultReviewSession) -> Bool {
        vaultCanAttach && noteRecoveryReadable && !noteRecoveryWriteFailed &&
        vaultInputSessionID == session.inputSessionID && noteEditGeneration == session.editGeneration &&
        vaultSelection == session.selection && selectedNode == session.selectedNode &&
        noteSelectionGeneration == session.selectionGeneration &&
        vaultNote?.path == session.base.path && vaultNote?.sha256 == session.base.sha256 &&
        vaultDraft.utf8.elementsEqual(session.base.text.utf8)
    }

    @discardableResult
    func rateVaultReviewGood(_ session: VaultReviewSession, injectedDate: Date,
                            save: (String,String,String) async throws -> VaultNoteSnapshot,
                            load: (String) async throws -> VaultNoteSnapshot) async -> Bool {
        await rateVaultReview(session,grade:.good,injectedDate:injectedDate,save:save,load:load)
    }

    @discardableResult
    func rateVaultReview(_ session: VaultReviewSession, grade: VaultReviewCard.Grade, injectedDate: Date,
                         save: (String,String,String) async throws -> VaultNoteSnapshot,
                         load: (String) async throws -> VaultNoteSnapshot) async -> Bool {
        guard vaultReviewIsCurrent(session) else {
            vaultStatus = VaultReviewError.changed.localizedDescription
            return false
        }
        do {
            let submitted = try session.card.rating(grade,eventID:session.id,injectedDate:injectedDate)
            vaultDraft = submitted
            await saveVaultNote(save:save,load:load)
            guard !Task.isCancelled, vaultInputSessionID == session.inputSessionID,
                  vaultSelection == session.selection, selectedNode == session.selectedNode,
                  noteSelectionGeneration == session.selectionGeneration,
                  vaultNote?.text.utf8.elementsEqual(submitted.utf8) == true,
                  vaultDraft.utf8.elementsEqual(submitted.utf8), vaultCanAttach,
                  !noteRecoveryWriteFailed, noteRecovery == nil else { return false }
            vaultStatus = "평가와 \(grade.intervalLabel) 뒤 기한을 원본에 저장하고 다시 읽어 확인했습니다."
            return true
        } catch { vaultStatus = error.localizedDescription; return false }
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
        guard closePDFView() else { return }
        pdfViewConflict = nil
        noteAddress = address
        noteToken = token
        noteConnectionGeneration &+= 1
        invalidateNoteRequests()
    }

    private func invalidateNoteRequests() {
        noteInputSession = nil
        vaultInputBusy = false
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
        _ = closePDFView()
        pdfViewRequest = UUID(); pdfViewBusy = false; pdfViewConflict = nil
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
        guard !vaultSaving, !vaultInputBusy, !vaultDirty || discard else {
            vaultStatus = vaultInputBusy ? "글자 입력과 펜 동작을 마친 뒤 닫아 주세요." : vaultSaving ? "저장 결과를 기다려 주세요. 입력은 유지됩니다." :
                "저장하지 않은 입력이 있습니다. 저장하거나 입력 버리기를 선택하세요."
            return false
        }
        if vaultBlockEditing {
            do { try writeBlockRecovery(nil) }
            catch { vaultStatus = error.localizedDescription; return false }
        }
        if discard, let record = noteRecovery, let context = noteContext,
           record.base.path == context.path, record.sceneID == context.sceneID,
           record.relayAddress == noteAddress {
            do { try writeNoteRecovery(nil) }
            catch { vaultStatus = error.localizedDescription; return false }
        }
        finishClosingVaultEditor()
        return true
    }

    private func finishClosingVaultEditor() {
        changingBlockState = true
        defer { changingBlockState = false }
        noteEditorGeneration &+= 1
        noteInputSession = nil
        noteRequest = nil
        noteContext = nil
        pendingExcerptAnchor = nil
        vaultNote = nil
        vaultBlockEditing = false
        vaultBlockDraft = ""
        pendingBlockEdit = nil
        vaultDraft = ""
        vaultSelection = NSRange(location:0,length:0)
        vaultLoading = false
        vaultBlocked = false
    }

    func openVaultNote(_ path: String, nodeID: UUID? = nil,
                       load: (String) async throws -> VaultNoteSnapshot) async {
        guard !vaultDirty, !vaultSaving, !vaultInputBusy else {
            vaultStatus = "현재 입력을 먼저 저장하거나 명시적으로 버려 주세요."
            return
        }
        if let pending = pendingExcerptAnchor, pending.context == noteContext,
           noteContextIsCurrent(pending.context), pending.context.path == path,
           let record = noteRecovery, noteRecoveryMatches(record) {
            await restoreNoteDraft(load:load)
            if let context = noteContext, let note = vaultNote, !vaultBlocked {
                pendingExcerptAnchor = (context:context,id:pending.id)
                focusOpenedBlock(note)
            }
            return
        }
        guard noteRecoveryReadable, noteRecovery == nil, pdfExcerptRecovery == nil else {
            vaultStatus = "보존된 노트 입력을 먼저 열거나 명시적으로 버려 주세요."
            return
        }
        guard VaultNoteReference.validPath(path), !noteToken.isEmpty else {
            vaultStatus = "노트 경로 또는 Mac 연결을 확인하세요."
            return
        }
        if vaultBlockEditing {
            do { try writeBlockRecovery(nil) }
            catch { vaultStatus = error.localizedDescription; return }
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
        noteInputSession = UUID()
        context.editorGeneration = noteEditorGeneration
        noteContext = context
        pendingExcerptAnchor = pending.map { (context:context,id:$0) }
        vaultNote = nil
        vaultBlockEditing = false
        vaultBlockDraft = ""
        pendingBlockEdit = nil
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
            vaultBlocked = note.reconciliationRequired == true
            vaultDraft = note.text
            vaultLoading = false
            noteRequest = nil
            vaultStatus = note.reconciliationRequired == true ? VaultBlockRecoveryError.publicationConflict.localizedDescription : "Mac Obsidian 원본을 열었습니다."
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

    private func canonicalBlockText(_ text: String, original: String) -> String {
        let lf = text.replacingOccurrences(of:"\r\n",with:"\n")
        return original.contains("\r\n") ? lf.replacingOccurrences(of:"\n",with:"\r\n") : lf
    }

    @discardableResult
    func beginLinkedBlockEdit() -> Bool {
        guard vaultCanAttach, let note = vaultNote, let id = vaultLinkedBlockID else { return false }
        do {
            guard blockRecoveryReadable, blockRecovery == nil, let context = noteContext,
                  let nodeID = context.nodeID else { throw VaultBlockRecoveryError.corrupt }
            let block = try VaultMarkdownBlocks(note.text).resolve(id)
            _ = try VaultMarkdownBlocks(note.text).replacing(id,with:block.quote)
            try persistScene()
            try writeBlockRecovery(VaultBlockRecovery(schemaVersion:1,sceneID:context.sceneID,
                nodeID:nodeID,relayAddress:noteAddress,blockID:id,base:note,
                draft:block.quote.replacingOccurrences(of:"\r\n",with:"\n"),pending:nil))
            changingBlockState = true
            defer { changingBlockState = false }
            vaultBlockDraft = block.quote.replacingOccurrences(of:"\r\n",with:"\n")
            vaultBlockSelection = NSRange(location:0,length:0)
            pendingBlockEdit = nil
            vaultBlockEditing = true
            noteInputSession = UUID()
            blockRecoveryWasRestored = false
            vaultStatus = "연결 문단만 수정합니다. 블록 표식과 다른 원문은 보존됩니다."
            return true
        } catch { vaultStatus = error.localizedDescription; return false }
    }

    private func writeBlockRecovery(_ record: VaultBlockRecovery?) throws {
        guard blockRecoveryReadable, let url = blockRecoveryURL else { throw VaultBlockRecoveryError.corrupt }
        let current: Data?
        do {
            current = FileManager.default.fileExists(atPath:url.path) ? try Self.readBlockRecovery(url) : nil
        } catch { throw VaultBlockRecoveryError.unavailable }
        guard current == blockRecoveryBytes else {
            blockRecoveryReadable = false
            blockRecoveryNotice = VaultBlockRecoveryError.corrupt.localizedDescription
            throw VaultBlockRecoveryError.corrupt
        }
        let bytes = try JSONEncoder().encode(VaultBlockRecoveryFile(record))
        guard bytes.count <= VaultBlockRecoveryFile.byteLimit else { throw VaultBlockRecoveryError.unavailable }
        do {
            try CanvasLocalFile.write(bytes,to:url)
            guard try CanvasLocalFile.read(url) == bytes else { throw VaultBlockRecoveryError.unavailable }
        } catch { throw VaultBlockRecoveryError.unavailable }
        blockRecoveryBytes = bytes
        blockRecovery = record
        blockRecoveryNotice = record == nil ? "" : "연결 문단 입력을 이 기기에 보존했습니다. 자동 전송하지 않습니다."
    }

    private static func readBlockRecovery(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= VaultBlockRecoveryFile.byteLimit else { throw VaultBlockRecoveryError.corrupt }
        return try CanvasLocalFile.read(url)
    }

    private func persistBlockDraft() {
        guard vaultBlockEditing, var record = blockRecovery else { return }
        record.draft = vaultBlockDraft
        record.pending = pendingBlockEdit
        do { try writeBlockRecovery(record) }
        catch {
            blockRecoveryNotice = error.localizedDescription
            vaultStatus = error.localizedDescription
        }
    }

    private func writeNoteRecovery(_ record: VaultNoteRecovery?) throws {
        guard noteRecoveryReadable, let url = noteRecoveryURL else { throw VaultBlockRecoveryError.corrupt }
        let current = FileManager.default.fileExists(atPath:url.path) ? try Self.readBlockRecovery(url) : nil
        guard current == noteRecoveryBytes || noteRecoveryAttemptedBytes.map({ current == $0 }) == true else {
            noteRecoveryReadable = false
            throw VaultBlockRecoveryError.corrupt
        }
        let bytes = try JSONEncoder().encode(VaultNoteRecoveryFile(record))
        guard bytes.count <= VaultBlockRecoveryFile.byteLimit else { throw VaultBlockRecoveryError.unavailable }
        // Keep the observed owned bytes if a later attempt fails before replacement.
        noteRecoveryBytes = current
        noteRecoveryAttemptedBytes = bytes
        try noteRecoveryWrite(bytes,url)
        noteRecoveryBytes = bytes
        noteRecoveryAttemptedBytes = nil
        noteRecovery = record
        noteRecoveryWriteFailed = false
        noteRecoveryNotice = record == nil ? "" : "저장하지 않은 노트 입력을 이 기기에 보존했습니다."
    }

    @discardableResult
    private func persistNoteDraft(submittedText: String? = nil, draft: String? = nil, publicationConfirmed: Bool = false) -> Bool {
        guard !vaultBlockEditing, let base = vaultNote, let context = noteContext,
              noteContextIsCurrent(context) else { return false }
        let draft = draft ?? vaultDraft
        do {
            if let old = noteRecovery {
                guard old.sceneID == context.sceneID, old.nodeID == context.nodeID,
                      old.blockID == context.blockID, old.relayAddress == noteAddress,
                      old.base.path == base.path else { throw VaultBlockRecoveryError.context }
            }
            let submitted = submittedText ?? noteRecovery.flatMap { $0.base.sha256 == base.sha256 ? $0.submittedText : nil }
            if draft.utf8.elementsEqual(base.text.utf8), submitted == nil, (publicationConfirmed || noteRecovery?.saveConflict?.requiresExplicitReconciliation != true) {
                if noteRecovery != nil || noteRecoveryAttemptedBytes != nil { try writeNoteRecovery(nil) }
                noteRecoveryWriteFailed = false
                return true
            }
            if noteRecovery == nil {
                try persistScene()
            }
            try writeNoteRecovery(VaultNoteRecovery(schemaVersion:1,sceneID:context.sceneID,
                nodeID:context.nodeID,blockID:context.blockID,relayAddress:noteAddress,
                base:base,draft:draft,submittedText:submitted,saveConflict:publicationConfirmed ? nil : (submittedText != nil ? .unclassified : noteRecovery?.saveConflict)))
            return true
        } catch {
            noteRecoveryNotice = error.localizedDescription
            vaultStatus = error.localizedDescription
            noteRecoveryWriteFailed = true
            return false
        }
    }

    func retryNoteDraftPreservation() {
        guard noteRecoveryReadable, !vaultBlocked, !vaultSaving, !vaultLoading, !vaultInputBusy else { return }
        if persistNoteDraft() { vaultStatus = "현재 입력을 이 기기에 다시 보존했습니다. 서버에는 전송하지 않았습니다." }
    }

    private func noteRecoveryMatches(_ record: VaultNoteRecovery) -> Bool {
        guard record.sceneID == scene.id, record.relayAddress == noteAddress else { return false }
        guard let id = record.nodeID else { return record.blockID == nil }
        guard let ref = scene.nodes.first(where:{ $0.id == id })?.vaultNote else { return false }
        return ref.path == record.base.path && ref.blockID == record.blockID && ref.relayAddress == record.relayAddress
    }

    func restoreNoteDraft(load: (String) async throws -> VaultNoteSnapshot) async {
        guard !noteReconciliationHeld, let record = noteRecovery, noteRecoveryReadable, !vaultDirty, !vaultBlockEditing,
              !vaultSaving, !vaultLoading, !vaultInputBusy, !noteToken.isEmpty else { return }
        do {
            _ = try record.validated()
            guard record.saveConflict?.requiresExplicitReconciliation != true else { throw VaultBlockRecoveryError.publicationConflict }
            guard noteRecoveryMatches(record) else {
                throw VaultBlockRecoveryError.context
            }
            let generation = noteConnectionGeneration
            let sceneGeneration = noteSceneGeneration
            let request = UUID()
            noteRequest = request
            vaultLoading = true
            noteReadSequence &+= 1
            let readSequence = noteReadSequence
            defer { if noteRequest == request { noteRequest = nil; vaultLoading = false } }
            let latest = try await load(record.base.path).validated(at:record.base.path)
            guard !Task.isCancelled, noteRequest == request, noteRecovery == record,
                  generation == noteConnectionGeneration, sceneGeneration == noteSceneGeneration,
                  noteRecoveryMatches(record), !vaultDirty, !vaultInputBusy,
                  readSequence >= acceptedNoteReads[record.base.path,default:0] else { return }
            guard latest.reconciliationRequired != true else { throw VaultBlockRecoveryError.publicationConflict }
            let restored: VaultNoteRecovery?
            do { restored = try record.reconciled(with:latest) }
            catch {
                noteRecoveryNotice = "Mac 원문이 바뀌었습니다. 보존된 입력을 덮어쓰거나 전송하지 않았습니다."
                vaultStatus = noteRecoveryNotice
                return
            }
            try writeNoteRecovery(restored)
            acceptedNoteReads[record.base.path] = readSequence
            changingNoteState = true
            defer { changingNoteState = false }
            noteEditorGeneration &+= 1
            noteInputSession = UUID()
            noteContext = NoteContext(sceneID:scene.id,sceneGeneration:noteSceneGeneration,
                connectionGeneration:noteConnectionGeneration,editorGeneration:noteEditorGeneration,
                path:latest.path,nodeID:record.nodeID,blockID:record.blockID)
            vaultNote = latest
            vaultDraft = restored?.draft ?? latest.text
            vaultSelection = NSRange(location:0,length:0)
            vaultBlocked = false
            refreshNoteCache(latest)
            vaultStatus = restored == nil ? "원본에서 이미 저장된 내용을 확인했습니다." : "보존된 노트 입력을 열었습니다. 전송하지 않았습니다."
        } catch {
            noteRecoveryNotice = error.localizedDescription
            vaultStatus = error.localizedDescription
        }
    }

    @discardableResult
    func discardNoteRecovery() -> Bool {
        guard !noteReconciliationHeld, !vaultSaving, !vaultLoading, !vaultDirty, !vaultInputBusy else { return false }
        do { try writeNoteRecovery(nil); return true }
        catch { noteRecoveryNotice = error.localizedDescription; return false }
    }

    @discardableResult
    func discardLinkedBlockRecovery() -> Bool {
        guard !vaultSaving, !vaultLoading, !vaultDirty, !vaultBlockEditing, !vaultInputBusy else { return false }
        do { try writeBlockRecovery(nil); return true }
        catch { vaultStatus = error.localizedDescription; return false }
    }

    @discardableResult
    func restoreLinkedBlockDraft() -> Bool {
        do {
            guard !noteReconciliationHeld, noteRecoveryReadable, noteRecovery == nil else { throw VaultBlockRecoveryError.context }
            guard blockRecoveryReadable, let record = blockRecovery else { throw VaultBlockRecoveryError.corrupt }
            guard record.saveConflict?.requiresExplicitReconciliation != true else { throw VaultBlockRecoveryError.publicationConflict }
            _ = try record.validated()
            guard !vaultDirty, !vaultSaving, !vaultLoading, !vaultInputBusy, !noteToken.isEmpty,
                  record.sceneID == scene.id, record.relayAddress == noteAddress,
                  let ref = scene.nodes.first(where:{ $0.id == record.nodeID })?.vaultNote,
                  ref.path == record.base.path, ref.blockID == record.blockID,
                  ref.relayAddress == record.relayAddress else { throw VaultBlockRecoveryError.context }
            changingBlockState = true
            changingNoteState = true
            defer { changingBlockState = false; changingNoteState = false }
            noteEditorGeneration &+= 1
            noteInputSession = UUID()
            noteRequest = nil
            noteContext = NoteContext(sceneID:scene.id,sceneGeneration:noteSceneGeneration,
                connectionGeneration:noteConnectionGeneration,editorGeneration:noteEditorGeneration,
                path:record.base.path,nodeID:record.nodeID,blockID:record.blockID)
            vaultNote = record.base
            vaultDraft = record.base.text
            pendingBlockEdit = record.pending
            vaultBlockDraft = record.draft
            vaultBlockSelection = NSRange(location:0,length:0)
            vaultBlockEditing = true
            vaultBlocked = false
            blockRecoveryWasRestored = true
            vaultStatus = record.pending == nil ? "보존된 문단 입력을 열었습니다. 저장 전 원문을 확인합니다." :
                "미확인 작업과 이후 입력을 복원했습니다. 저장 결과 확인은 같은 작업 ID만 사용합니다."
            return true
        } catch { vaultStatus = error.localizedDescription; return false }
    }

    func saveLinkedBlock(replace: (String,String,VaultBlockEdit) async throws -> VaultBlockEditResult,
                         load: (String) async throws -> VaultNoteSnapshot) async {
        guard vaultBlockCanSave, let context = noteContext, let base = vaultNote,
              let blockID = context.blockID else { return }
        let request = UUID()
        do {
            let block = try VaultMarkdownBlocks(base.text).resolve(blockID)
            noteRequest = request
            vaultSaving = true
            defer {
                if noteRequest == request { noteRequest = nil; vaultSaving = false }
            }
            if blockRecoveryWasRestored {
                let current = try await load(base.path).validated(at:base.path)
                guard !Task.isCancelled, noteRequest == request, noteContext == context,
                      noteContextIsCurrent(context), vaultNote?.sha256 == base.sha256,
                      !vaultInputBusy else { return }
                guard current.reconciliationRequired != true else { throw VaultBlockRecoveryError.publicationConflict }
                let expected = try pendingBlockEdit.map {
                    try VaultMarkdownBlocks(base.text).replacing(blockID,with:$0.replacementText)
                }
                guard current.text.utf8.elementsEqual(base.text.utf8) ||
                      expected.map({ current.text.utf8.elementsEqual($0.utf8) }) == true else {
                    throw VaultBlockRecoveryError.changed
                }
            }
            let submitted = pendingBlockEdit ?? VaultBlockEdit(base:base,block:block,
                text:canonicalBlockText(vaultBlockDraft,original:base.text))
            _ = try VaultMarkdownBlocks(base.text).replacing(blockID,with:submitted.replacementText)
            guard var recovery = blockRecovery, recovery.sceneID == context.sceneID,
                  recovery.nodeID == context.nodeID, recovery.relayAddress == noteAddress,
                  recovery.base == base, recovery.blockID == blockID else {
                throw VaultBlockRecoveryError.context
            }
            recovery.draft = vaultBlockDraft
            recovery.pending = submitted
            recovery.saveConflict = .unclassified
            try writeBlockRecovery(recovery)
            pendingBlockEdit = submitted
            let draftAtSubmission = vaultBlockDraft
            let result = try await replace(base.path,blockID,submitted)
            let saved = try result.validated(edit:submitted,base:base,blockID:blockID)
            guard !Task.isCancelled, noteRequest == request, noteContext == context,
                  noteContextIsCurrent(context), vaultNote?.sha256 == base.sha256 else { return }
            noteReadSequence &+= 1
            let readSequence = noteReadSequence
            let readback = try await load(base.path).validated(at:base.path)
            guard readback.sha256 == saved.sha256,
                  readback.text.utf8.elementsEqual(saved.text.utf8) else { throw URLError(.badServerResponse) }
            guard !Task.isCancelled, noteRequest == request, noteContext == context,
                  noteContextIsCurrent(context), vaultNote?.sha256 == base.sha256,
                  readSequence >= acceptedNoteReads[base.path,default:0],
                  pendingBlockEdit == submitted else { return }
            recovery.base = saved
            recovery.draft = vaultBlockDraft
            recovery.pending = nil
            recovery.saveConflict = nil
            try writeBlockRecovery(recovery)
            changingBlockState = true
            defer { changingBlockState = false }
            acceptedNoteReads[base.path] = readSequence
            vaultNote = saved
            vaultDraft = saved.text
            // A retry may resolve an earlier submission while newer typing remains unsaved.
            if !vaultInputBusy, vaultBlockDraft.utf8.elementsEqual(draftAtSubmission.utf8),
               canonicalBlockText(vaultBlockDraft,original:base.text).utf8.elementsEqual(submitted.replacementText.utf8) {
                vaultBlockDraft = submitted.replacementText.replacingOccurrences(of:"\r\n",with:"\n")
            }
            pendingBlockEdit = nil
            blockRecoveryWasRestored = false
            vaultBlocked = false
            refreshNoteCache(saved)
            vaultStatus = vaultBlockTextChanged ? "제출한 문단은 저장됐습니다. 이후 입력은 아직 저장하지 않았습니다." :
                "Obsidian 문단 저장과 카드 반영을 확인했습니다."
        } catch {
            guard noteContext == context, noteContextIsCurrent(context),
                  noteRequest == nil || noteRequest == request else { return }
            guard pendingBlockEdit != nil else {
                vaultStatus = "문단 형식 확인: \(error.localizedDescription). 입력은 보존했으며 저장 요청은 보내지 않았습니다."
                return
            }
            let failure = error as NSError
            if let conflict = VaultSaveConflict.classified(failure), conflict.requiresExplicitReconciliation {
                vaultBlocked = true
                if var recovery = blockRecovery {
                    recovery.saveConflict = conflict
                    do { try writeBlockRecovery(recovery) }
                    catch { blockRecoveryNotice = "충돌 보존 상태 기록 실패 · 입력과 작업 ID를 유지합니다." }
                }
                vaultStatus = VaultBlockRecoveryError.publicationConflict.localizedDescription
                return
            }
            if var recovery = blockRecovery {
                recovery.saveConflict = VaultSaveConflict.classified(failure) ?? .acknowledgementLost
                do { try writeBlockRecovery(recovery) }
                catch { blockRecoveryNotice = "저장 결과 보존 실패 · 기존 미확인 표식을 유지합니다." }
            }
            let reason = VaultSaveConflict.classified(failure) == .prepublication ?
                "게시 전 거부 · 원문 변경 또는 작업 결과 불일치" : "통신 또는 원문 검증 실패"
            vaultStatus = "\(reason). 입력과 작업 ID를 보존했습니다. ‘저장 결과 확인’은 같은 작업만 확인합니다. 원문을 새로 열려면 입력을 명시적으로 버려 주세요."
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
            guard persistNoteDraft(submittedText:anchor.text,draft:anchor.text) else { return nil }
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
            var publicationState = VaultSaveConflict.acknowledgementLost
            do {
                let saved = try await save(base.path,base.sha256,anchor.text).validated(at:base.path)
                guard saved.text.utf8.elementsEqual(anchor.text.utf8) else { throw URLError(.badServerResponse) }
            } catch {
                guard current() else { return nil }
                if let conflict = VaultSaveConflict.classified(error), conflict.requiresExplicitReconciliation {
                    vaultBlocked = true
                    if var recovery = noteRecovery {
                        recovery.saveConflict = conflict
                        do { try writeNoteRecovery(recovery) }
                        catch { noteRecoveryWriteFailed = true }
                    }
                    vaultStatus = VaultBlockRecoveryError.publicationConflict.localizedDescription
                    return nil
                }
                publicationState = VaultSaveConflict.classified(error) ?? .acknowledgementLost
            }
            guard current() else { return nil }
            noteReadSequence &+= 1
            let readSequence = noteReadSequence
            do {
                let saved = try await load(base.path).validated(at:base.path)
                guard current() else { return nil }
                guard saved.reconciliationRequired != true else { throw VaultBlockRecoveryError.publicationConflict }
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
                guard persistNoteDraft(publicationConfirmed:true) else { return nil }
                refreshNoteCache(saved)
                let id = attachVaultBlock(confirmed,note:saved)
                vaultStatus = vaultBlocked ? "블록 저장과 발췌를 확인했습니다. 이후 입력은 보존했으며 원본을 다시 확인해야 합니다." :
                    "블록 ^\(anchor.blockID) 저장과 원본 재조회를 확인해 발췌했습니다."
                noteRequest = nil
                vaultSaving = false
                return id
            } catch {
                guard current() else { return nil }
                if var recovery = noteRecovery {
                    recovery.saveConflict = VaultSaveConflict.classified(error) ?? publicationState
                    if let failure = error as? VaultBlockRecoveryError, case .publicationConflict = failure {
                        recovery.saveConflict = .reconciliationRequired
                    }
                    do { try writeNoteRecovery(recovery) }
                    catch { noteRecoveryWriteFailed = true }
                }
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

    private func pdfViewIsCurrent(_ reader: VaultPDFReader, request: UUID, owner: CanvasDocument.PageSnapshot, connection: UInt64) -> Bool {
        pdfViewReader === reader && pdfViewRequest == request && document.accepts(owner) &&
            connection == noteConnectionGeneration && !Task.isCancelled
    }
    @discardableResult
    func openPDFView(_ path: String, source: VaultPDFExcerpt? = nil,
                     loadPDF: (String) async throws -> VaultPDFSnapshot,
                     loadNote: (String) async throws -> VaultNoteSnapshot) async -> Bool {
        guard !vaultDirty, !vaultSaving, !vaultLoading, !vaultInputBusy, !pdfViewBusy, !documentEditingBlocked,
              noteRecoveryReadable, noteRecovery == nil, blockRecovery == nil, !noteToken.isEmpty,
              pdfExcerptRecoveryReadable, pdfExcerptRecovery?.viewRecovery != nil || pdfExcerptRecovery == nil else { return false }
        if let current = pdfViewReader, !preservePDFViewDraft(current) { return false }
        let request = UUID(), connection = noteConnectionGeneration
        do {
            let owner = try document.pageSnapshot()
            pdfViewRequest = request; pdfViewBusy = true
            defer { if pdfViewRequest == request { pdfViewBusy = false } }
            let snapshot = try await loadPDF(path)
            let basic = try VaultPDFReader(snapshot:snapshot,source:source)
            let expected = VaultPDFViewState(snapshot:snapshot,pageCount:basic.pageCount)
            var base: VaultNoteSnapshot?, missing = false
            if pdfExcerptRecovery?.viewRecovery == nil {
                do {
                    base = try await loadNote(expected.notePath).validated(at:expected.notePath)
                    try VaultPDFViewState.SaveRequest.checkHeld(base!)
                    _ = try VaultPDFViewState.parse(base!.text,snapshot:snapshot,pageCount:basic.pageCount)
                } catch let error as NSError where error.domain == "CanvasRelay" && error.code == 404 { missing = true }
            }
            guard pdfViewRequest == request, document.accepts(owner), connection == noteConnectionGeneration, !Task.isCancelled else { return false }
            let reader: VaultPDFReader
            if let record = pdfExcerptRecovery, let recovery = record.viewRecovery {
                guard record.sceneID == scene.id, record.relayAddress == noteAddress,
                      record.path.utf8.elementsEqual(expected.notePath.utf8) else { throw VaultBlockRecoveryError.context }
                try recovery.validate()
                let prior = try recovery.base.map { try VaultPDFViewState.parse($0.text,snapshot:snapshot,pageCount:basic.pageCount) }
                reader = try VaultPDFReader(snapshot:snapshot,source:source,viewState:prior)
                try reader.applyViewState(recovery.draft.state)
                base = recovery.base; missing = base == nil
            } else {
                let state = try base.map { try VaultPDFViewState.parse($0.text,snapshot:snapshot,pageCount:basic.pageCount) }
                reader = try VaultPDFReader(snapshot:snapshot,source:source,viewState:state)
            }
            pdfViewReader = reader; pdfViewBase = base; pdfViewMissingConfirmed = missing
            pdfViewSceneID = scene.id; pdfViewAddress = noteAddress; pdfViewOwner = owner; pdfViewSource = source
            vaultStatus = "PDF 원본과 보기 설정 Markdown을 확인했습니다. 원문 앵커는 유지됩니다."
            return true
        } catch {
            if pdfViewRequest == request { vaultStatus = "PDF 보기를 바꾸지 않았습니다. " + error.localizedDescription }
            return false
        }
    }
    @discardableResult
    func preservePDFViewDraft(_ reader: VaultPDFReader) -> Bool {
        guard pdfViewReader === reader else { return false }
        do {
            guard pdfViewBase != nil || pdfViewMissingConfirmed, let sceneID = pdfViewSceneID else { throw VaultBlockRecoveryError.context }
            let draft = try reader.prepareViewStateSave(base:pdfViewBase)
            let old = pdfExcerptRecovery
            guard old == nil || (old?.viewRecovery != nil && old?.path.utf8.elementsEqual(draft.path.utf8) == true) else { throw VaultBlockRecoveryError.context }
            if !reader.hasViewEdits && old?.viewRecovery?.submitted == nil {
                if old != nil { try writePDFExcerptRecovery(nil) }; return true
            }
            let recovery = VaultPDFViewRecovery(id:old?.viewRecovery?.id ?? UUID(),base:pdfViewBase,draft:draft,submitted:old?.viewRecovery?.submitted)
            try writePDFExcerptRecovery(.init(sceneID:sceneID,relayAddress:pdfViewAddress,path:draft.path,draft:draft.markdown,
                submittedText:recovery.submitted?.markdown,saveConflict:old?.saveConflict,viewRecovery:recovery))
            return true
        } catch { vaultStatus = "보기 초안을 보존하지 못했습니다. 화면과 기존 입력을 유지합니다. " + error.localizedDescription; return false }
    }
    @discardableResult
    func closePDFView() -> Bool {
        if let reader = pdfViewReader, !preservePDFViewDraft(reader) { return false }
        pdfViewRequest = UUID(); pdfViewBusy = false; pdfViewReader = nil; pdfViewBase = nil
        pdfViewMissingConfirmed = false; pdfViewOwner = nil
        return true
    }
    func savePDFView(_ submitted: VaultPDFViewState.SaveRequest, reader: VaultPDFReader,
                     save: (String,String?,String) async throws -> VaultNoteSnapshot,
                     load: (String) async throws -> VaultNoteSnapshot) async {
        guard pdfViewReader === reader, pdfViewCanPersist, !noteReconciliationHeld,
              preservePDFViewDraft(reader), var record = pdfExcerptRecovery, var recovery = record.viewRecovery,
              recovery.submitted == nil else { return }
        let request = UUID(), connection = noteConnectionGeneration
        do {
            let owner = try document.pageSnapshot()
            pdfViewRequest = request
            guard submitted.path.utf8.elementsEqual(recovery.draft.path.utf8), submitted.baseSHA256 == recovery.base?.sha256 else { throw VaultBlockRecoveryError.changed }
            recovery.submitted = submitted
            record = .init(sceneID:record.sceneID,relayAddress:record.relayAddress,path:record.path,draft:record.draft,
                submittedText:submitted.markdown,saveConflict:.unclassified,viewRecovery:recovery)
            try writePDFExcerptRecovery(record) // PUT보다 먼저 동일 path/base/text와 작업 ID를 보존한다.
            pdfViewRequest = request; vaultSaving = true
            defer { if pdfViewRequest == request { vaultSaving = false } }
            let note = try await submitted.submit(save:save,load:load)
            guard pdfViewIsCurrent(reader,request:request,owner:owner,connection:connection) else { return }
            try finishPDFViewSave(submitted,reader:reader,note:note)
        } catch {
            guard pdfViewRequest == request else { return }
            if let current = pdfExcerptRecovery, let recovery = current.viewRecovery {
                let kind = VaultSaveConflict.classified(error) ?? .acknowledgementLost
                try? writePDFExcerptRecovery(.init(sceneID:current.sceneID,relayAddress:current.relayAddress,path:current.path,draft:current.draft,
                    submittedText:recovery.submitted?.markdown,saveConflict:kind,viewRecovery:recovery))
            }
            vaultStatus = "보기 설정 저장 결과 미확인·조정 대기. 입력을 보존하고 자동 재전송하지 않습니다. " + error.localizedDescription
        }
    }
    private func finishPDFViewSave(_ submitted: VaultPDFViewState.SaveRequest, reader: VaultPDFReader, note: VaultNoteSnapshot) throws {
        _ = try submitted.confirmed(note)
        guard let current = pdfExcerptRecovery, current.viewRecovery?.submitted == submitted else { throw VaultBlockRecoveryError.changed }
        try reader.confirmViewStateSave(submitted,note:note)
        pdfViewBase = note; pdfViewMissingConfirmed = false
        if reader.hasViewEdits {
            let next = try reader.prepareViewStateSave(base:note)
            let recovery = VaultPDFViewRecovery(id:current.viewRecovery!.id,base:note,draft:next,submitted:nil)
            try writePDFExcerptRecovery(.init(sceneID:current.sceneID,relayAddress:current.relayAddress,path:next.path,draft:next.markdown,submittedText:nil,viewRecovery:recovery))
        } else { try writePDFExcerptRecovery(nil) }
        vaultStatus = "보기 설정 Markdown 저장과 전체 재조회를 확인했습니다. PDF와 원문 앵커는 변경하지 않았습니다."
    }
    func reloadPDFView(reader: VaultPDFReader, load: (String) async throws -> VaultNoteSnapshot) async {
        guard pdfViewReader === reader, !pdfViewBusy, !vaultSaving else { return }
        let request = UUID(), connection = noteConnectionGeneration
        do {
            let owner = try document.pageSnapshot()
            pdfViewRequest = request; pdfViewBusy = true
            defer { if pdfViewRequest == request { pdfViewBusy = false } }
            let note = try await load(reader.viewState.notePath).validated(at:reader.viewState.notePath)
            guard pdfViewIsCurrent(reader,request:request,owner:owner,connection:connection) else { return }
            if let record = pdfExcerptRecovery, let submitted = record.viewRecovery?.submitted {
                guard record.saveConflict?.requiresExplicitReconciliation != true else { throw VaultBlockRecoveryError.publicationConflict }
                try finishPDFViewSave(submitted,reader:reader,note:note)
            } else {
                try reader.applyViewStateNote(note); pdfViewBase = note; pdfViewMissingConfirmed = false
                vaultStatus = "외부 Markdown의 표시 순서·자르기를 역수신했습니다. 원문 PDF·발췌는 유지됩니다."
            }
        } catch { if pdfViewRequest == request { vaultStatus = "보기 설정 원본을 적용하지 않았습니다. " + error.localizedDescription } }
    }
    var pdfViewChoice: VaultPDFViewChoice? {
        guard let url = try? CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json"),
              let data = try? CanvasLocalFile.read(url), data.count <= 12*1024*1024 else { return nil }
        return try? JSONDecoder().decode(VaultPDFViewChoice.self,from:data).validated()
    }
    private func writePDFViewChoice(_ choice: VaultPDFViewChoice, expected: Data?) throws {
        let url = try CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json")
        let current = FileManager.default.fileExists(atPath:url.path) ? try CanvasLocalFile.read(url) : nil
        guard current == expected else { throw VaultBlockRecoveryError.changed }
        let bytes = try JSONEncoder().encode(choice.validated())
        guard bytes.count <= 12*1024*1024 else { throw VaultBlockRecoveryError.unavailable }
        try CanvasLocalFile.write(bytes,to:url)
        guard try CanvasLocalFile.read(url) == bytes else { throw VaultBlockRecoveryError.changed }
    }
    private func archivePDFViewChoice(_ data: Data) throws {
        // Content identity makes an interrupted archival write converge without a new operation ID.
        let h = CanvasPacket.sha(data)
        let id = String(h.prefix(8))+"-"+String(h.dropFirst(8).prefix(4))+"-"+String(h.dropFirst(12).prefix(4))+"-"+String(h.dropFirst(16).prefix(4))+"-"+String(h.dropFirst(20).prefix(12))
        let url = try CanvasRuntime.conflictRecoveryURL("NoteConflictAttempt-"+id+".json")
        if FileManager.default.fileExists(atPath:url.path) {
            guard try CanvasLocalFile.read(url) == data else { throw VaultBlockRecoveryError.changed }
        } else { try CanvasLocalFile.write(data,to:url) }
        guard try CanvasLocalFile.read(url) == data else { throw VaultBlockRecoveryError.changed }
    }
    func comparePDFViewConflict(reader: VaultPDFReader,
                                load: (String) async throws -> CanvasRelay.NoteConflict) async {
        guard pdfViewReader === reader, !pdfViewBusy, !vaultSaving, preservePDFViewDraft(reader),
              let original = pdfExcerptRecovery, original.viewRecovery != nil else { return }
        let request = UUID(), connection = noteConnectionGeneration
        do {
            let owner = try document.pageSnapshot()
            pdfViewRequest = request; pdfViewBusy = true
            defer { if pdfViewRequest == request { pdfViewBusy = false } }
            let conflict = try await load(original.path).validated(path:original.path)
            guard pdfViewIsCurrent(reader,request:request,owner:owner,connection:connection), pdfExcerptRecovery == original else { throw VaultBlockRecoveryError.changed }
            let url = try CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json")
            let previous = FileManager.default.fileExists(atPath:url.path) ? try CanvasLocalFile.read(url) : nil
            if let previous {
                if var old = try? JSONDecoder().decode(VaultPDFViewChoice.self,from:previous).validated() {
                    guard old.original.sceneID == original.sceneID, old.original.relayAddress == original.relayAddress, old.original.path == original.path || old.closed else { throw VaultBlockRecoveryError.context }
                    // An explicit fresh comparison supersedes the prior snapshot, preserving its full inputs.
                    old.phase = .superseded
                    try archivePDFViewChoice(JSONEncoder().encode(old.validated()))
                } else {
                    let old = try JSONDecoder().decode(NoteConflictLocalChoice.self,from:previous).validated()
                    guard old.phase == .completed || old.phase == .superseded else { throw VaultBlockRecoveryError.publicationConflict }
                    try archivePDFViewChoice(previous)
                }
            }
            let choice = VaultPDFViewChoice(schema:VaultPDFViewChoice.schemaName,original:original,conflict:conflict,phase:.compared)
            try writePDFViewChoice(choice,expected:previous)
            pdfViewConflict = conflict
            vaultStatus = "현재·기준·외부·제안 원문을 비교했습니다. 명시 선택 전에는 다시 저장하지 않습니다."
        } catch { if pdfViewRequest == request { vaultStatus = "보기 설정 비교를 적용하지 않았습니다. " + error.localizedDescription } }
    }
    func resolvePDFViewConflict(_ decision: CanvasRelay.ConflictDecision, reader: VaultPDFReader,
                               resolve: (CanvasRelay.NoteConflict,CanvasRelay.ConflictDecision) async throws -> VaultNoteSnapshot) async {
        guard pdfViewReader === reader, !pdfViewBusy, !vaultSaving, let originalChoice = pdfViewChoice, originalChoice.phase != .superseded,
              originalChoice.phase != .resolved || originalChoice.decision == decision,
              originalChoice.original == pdfExcerptRecovery,
              originalChoice.original.sceneID == scene.id, originalChoice.original.relayAddress == noteAddress else { return }
        let request = UUID(), connection = noteConnectionGeneration
        do {
            let owner = try document.pageSnapshot()
            let material = originalChoice.conflict.selected(decision)
            guard let material, material.validNote, let markdown = material.markdown else { throw VaultBlockRecoveryError.unavailable }
            // Reject malformed/other-PDF candidates before changing the server's active file.
            _ = try VaultPDFViewState.parse(markdown,snapshot:reader.snapshot,pageCount:reader.pageCount)
            let url = try CanvasRuntime.conflictRecoveryURL("NoteConflictChoice.json")
            let previous = try CanvasLocalFile.read(url)
            var choice = originalChoice; choice.decision = decision; choice.phase = .resolving
            pdfViewRequest = request; pdfViewBusy = true
            defer { if pdfViewRequest == request { pdfViewBusy = false } }
            try writePDFViewChoice(choice,expected:previous)
            let submittedChoice = try CanvasLocalFile.read(url)
            let selected = try await resolve(choice.conflict,decision).validated(at:choice.original.path)
            try VaultPDFViewState.SaveRequest.checkHeld(selected)
            guard selected.sha256 == material.sha256, selected.text.utf8.elementsEqual(markdown.utf8),
                  pdfViewIsCurrent(reader,request:request,owner:owner,connection:connection), pdfExcerptRecovery == choice.original else { throw VaultBlockRecoveryError.changed }
            let state = try VaultPDFViewState.parse(selected.text,snapshot:reader.snapshot,pageCount:reader.pageCount)
            let replacement = try VaultPDFReader(snapshot:reader.snapshot,source:pdfViewSource,viewState:state)
            // The full former base/draft/submitted remains in the durable resolved choice.
            choice.phase = .resolved; choice.resolved = selected
            try writePDFViewChoice(choice,expected:submittedChoice)
            try writePDFExcerptRecovery(nil)
            pdfViewReader = replacement; pdfViewBase = selected; pdfViewMissingConfirmed = false
            pdfViewConflict = nil; pdfViewOwner = owner
            vaultStatus = "선택한 보기 설정과 전체 재조회를 확인했습니다. 이전 초안·원본·제안은 복구 자료에 보존했습니다."
        } catch { if pdfViewRequest == request { vaultStatus = "보기 설정 조정 결과 미확인. 원문과 선택 의도를 보존합니다. " + error.localizedDescription } }
    }
    var hasPendingPDFExcerpt: Bool { pdfExcerptRecovery != nil }

    private func writePDFExcerptRecovery(_ record: VaultPDFCreateRecovery?) throws {
        guard pdfExcerptRecoveryReadable, let url = pdfExcerptRecoveryURL else { throw VaultBlockRecoveryError.corrupt }
        let current = FileManager.default.fileExists(atPath:url.path) ? try Self.readBlockRecovery(url) : nil
        guard current == pdfExcerptRecoveryBytes || pdfExcerptRecoveryAttemptedBytes.map({ current == $0 }) == true else {
            pdfExcerptRecoveryReadable = false
            throw VaultBlockRecoveryError.corrupt
        }
        let bytes = try JSONEncoder().encode(VaultPDFCreateRecoveryFile(record))
        guard bytes.count <= VaultBlockRecoveryFile.byteLimit else { throw VaultBlockRecoveryError.unavailable }
        pdfExcerptRecoveryBytes = current
        pdfExcerptRecoveryAttemptedBytes = bytes
        try pdfExcerptRecoveryWrite(bytes,url)
        pdfExcerptRecoveryBytes = bytes
        pdfExcerptRecoveryAttemptedBytes = nil
        pdfExcerptRecovery = record
        pdfExcerptRecoveryNotice = record == nil ? "" : (record?.viewRecovery != nil ? "보존된 PDF 보기 초안·저장 의도가 있습니다. 자동 재전송하지 않습니다." : "보존된 PDF 발췌 생성 의도가 있습니다. 같은 ID의 저장 결과만 확인합니다.")
    }

    @discardableResult
    func discardPDFExcerptRecovery() -> Bool {
        guard !vaultSaving, !vaultLoading, !vaultDirty, !vaultInputBusy else { return false }
        do { try writePDFExcerptRecovery(nil); return true }
        catch { pdfExcerptRecoveryNotice = error.localizedDescription; return false }
    }

    @discardableResult
    func preparePDFExcerpt(_ excerpt: VaultPDFExcerpt) -> Bool {
        guard !noteReconciliationHeld, !vaultDirty, !vaultSaving, !vaultLoading, !vaultInputBusy,
              noteRecoveryReadable, noteRecovery == nil, pdfExcerptRecoveryReadable, pdfExcerptRecovery == nil,
              !noteToken.isEmpty else {
            vaultStatus = "현재 노트 입력 또는 보존된 저장 결과를 먼저 확인하세요."
            return false
        }
        do {
            let text = try excerpt.markdown()
            try persistScene()
            try writePDFExcerptRecovery(VaultPDFCreateRecovery(sceneID:scene.id,relayAddress:noteAddress,
                path:excerpt.notePath,draft:text,submittedText:nil))
            do {
                if vaultBlockEditing { try writeBlockRecovery(nil) }
            } catch {
                try? writePDFExcerptRecovery(nil)
                throw error
            }
            finishClosingVaultEditor()
            return true
        } catch { vaultStatus = error.localizedDescription; return false }
    }

    @discardableResult
    func savePDFExcerpt(allowCreate: Bool,
                        create: (String,String) async throws -> VaultNoteSnapshot,
                        load: (String) async throws -> VaultNoteSnapshot) async -> UUID? {
        guard !noteReconciliationHeld, var record = pdfExcerptRecovery, record.viewRecovery == nil, pdfExcerptRecoveryReadable,
              record.sceneID == scene.id, record.relayAddress == noteAddress,
              noteRecoveryReadable, noteRecovery == nil, !vaultDirty, !vaultInputBusy,
              !vaultSaving, !vaultLoading, !noteToken.isEmpty else { return nil }
        let connection = noteConnectionGeneration, generation = noteSceneGeneration
        let request = UUID()
        noteRequest = request
        vaultSaving = true
        defer { if noteRequest == request { noteRequest = nil; vaultSaving = false } }
        func current() -> Bool {
            !Task.isCancelled && !noteReconciliationHeld && noteRequest == request && pdfExcerptRecovery == record &&
                connection == noteConnectionGeneration && generation == noteSceneGeneration &&
                record.sceneID == scene.id && record.relayAddress == noteAddress
        }
        do {
            _ = try record.validated()
            guard record.saveConflict?.requiresExplicitReconciliation != true else { throw VaultBlockRecoveryError.publicationConflict }
            let path = record.path
            let latest: VaultNoteSnapshot
            do { latest = try await load(path).validated(at:path) }
            catch let error as NSError where error.domain == "CanvasRelay" && error.code == 404 {
                guard current(), allowCreate else { throw VaultPDFError.unconfirmed }
                record.submittedText = record.draft
                try writePDFExcerptRecovery(record)
                do {
                    let saved = try await create(path,record.draft).validated(at:path)
                    guard saved.text.utf8.elementsEqual(record.draft.utf8) else { throw VaultBlockRecoveryError.changed }
                } catch {
                    guard current() else { return nil }
                    if let conflict = VaultSaveConflict.classified(error), conflict.requiresExplicitReconciliation {
                        record.saveConflict = conflict
                        try writePDFExcerptRecovery(record)
                        throw VaultBlockRecoveryError.publicationConflict
                    }
                    // Only ordinary lost acknowledgements may reconcile through the same path.
                }
                guard current() else { return nil }
                latest = try await load(path).validated(at:path)
            }
            guard current() else { return nil }
            guard latest.reconciliationRequired != true else { throw VaultBlockRecoveryError.publicationConflict }
            guard latest.text.utf8.elementsEqual(record.draft.utf8) else { throw VaultBlockRecoveryError.changed }
            let id: UUID
            if let node = scene.nodes.first(where:{ $0.vaultNote?.path == path && $0.vaultNote?.relayAddress == noteAddress }) {
                id = node.id
            } else {
                changingNoteState = true
                noteEditorGeneration &+= 1
                noteInputSession = UUID()
                noteContext = NoteContext(sceneID:scene.id,sceneGeneration:noteSceneGeneration,
                    connectionGeneration:noteConnectionGeneration,editorGeneration:noteEditorGeneration,
                    path:path,nodeID:nil,blockID:nil)
                vaultNote = latest
                vaultDraft = latest.text
                changingNoteState = false
                vaultBlocked = false
                vaultSaving = false
                guard let attached = attachOpenedVaultNote() else { throw VaultBlockRecoveryError.context }
                id = attached
            }
            try persistScene()
            try writePDFExcerptRecovery(nil)
            vaultStatus = "PDF 발췌의 저장과 원본 GET을 확인하고 편집 가능한 노트 카드를 연결했습니다."
            return id
        } catch {
            if current() {
                vaultStatus = "발췌 저장 결과 미확인: \(error.localizedDescription). 같은 ID와 입력을 보존했습니다."
            }
            return nil
        }
    }

    func saveVaultNote(save: (String,String,String) async throws -> VaultNoteSnapshot,
                       load: (String) async throws -> VaultNoteSnapshot) async {
        await saveVaultNote { path,sha,text in
            let saved = try await save(path,sha,text).validated(at:path)
            guard saved.text.utf8.elementsEqual(text.utf8) else { throw URLError(.badServerResponse) }
            let readback = try await load(path).validated(at:path)
            guard readback.sha256 == saved.sha256,
                  readback.text.utf8.elementsEqual(text.utf8) else { throw VaultBlockRecoveryError.changed }
            return readback
        }
    }

    func saveVaultNote(save: (String, String, String) async throws -> VaultNoteSnapshot) async {
        guard vaultCanSave, let context = noteContext, let base = vaultNote else { return }
        let request = UUID()
        let submitted = vaultDraft
        let editGeneration = noteEditGeneration
        guard persistNoteDraft(submittedText:submitted) else { return }
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
            if !vaultInputBusy, noteEditGeneration == editGeneration { vaultDraft = saved.text }
            guard persistNoteDraft(publicationConfirmed:true) else {
                vaultBlocked = true
                vaultStatus = "서버 응답은 확인했지만 로컬 복구 기록 정리를 확인하지 못했습니다. 입력과 보존본을 유지합니다."
                return
            }
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
            let failure = error as NSError
            if let conflict = VaultSaveConflict.classified(failure), conflict.requiresExplicitReconciliation {
                if var recovery = noteRecovery {
                    recovery.saveConflict = conflict
                    do { try writeNoteRecovery(recovery) }
                    catch { noteRecoveryWriteFailed = true }
                }
                vaultStatus = VaultBlockRecoveryError.publicationConflict.localizedDescription
            } else {
                if var recovery = noteRecovery {
                    recovery.saveConflict = VaultSaveConflict.classified(failure) ?? .acknowledgementLost
                    do { try writeNoteRecovery(recovery) }
                    catch { noteRecoveryWriteFailed = true }
                }
                vaultStatus = "저장 실패 또는 결과 미확인: \(error.localizedDescription). 입력을 보존했습니다. 원본을 다시 확인하세요."
            }
        }
    }

    @discardableResult
    func attachOpenedVaultNote() -> UUID? {
        guard vaultCanAttach, let note = vaultNote else { return nil }
        let preview = VaultPDFCard.preview(note.text)
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
            let preview = ref.blockID == nil ? VaultPDFCard.preview(source) : VaultNoteSnapshot.preview(source)
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
        guard !documentEditingBlocked, !noteToken.isEmpty else { return }
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
                guard !documentEditingBlocked, !Task.isCancelled, scene.id == sceneID, noteSceneGeneration == sceneGeneration,
                      noteConnectionGeneration == connectionGeneration else { return }
                guard readSequence >= acceptedNoteReads[path,default:0] else { continue }
                acceptedNoteReads[path] = readSequence
                refreshNoteCache(latest,expected:references)
                if vaultBlockEditing { continue }
                guard let context, noteContext == context, noteContextIsCurrent(context),
                      editorGeneration == noteEditorGeneration, context.path == path,
                      noteRequest == request, !vaultSaving, !vaultInputBusy,
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
                guard !documentEditingBlocked, !Task.isCancelled, scene.id == sceneID, noteSceneGeneration == sceneGeneration,
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

    init(blockRecoveryURL: URL? = nil, noteRecoveryURL: URL? = nil, pdfExcerptRecoveryURL: URL? = nil,
         defaults: UserDefaults? = nil,
         noteRecoveryWrite: @escaping (Data,URL) throws -> Void = CanvasLocalFile.write,
         pdfExcerptRecoveryWrite: @escaping (Data,URL) throws -> Void = CanvasLocalFile.write) {
        let defaults = CanvasRuntime.defaults(overriding:defaults)
        self.eraserDefaults = defaults
        _eraserStyle = Published(initialValue: defaults.string(forKey: Self.eraserStyleKey)
            .flatMap(CanvasEraserStyle.init(rawValue:)) ?? .partial)
        _eraserSize = Published(initialValue: (defaults.object(forKey: Self.eraserSizeKey) as? NSNumber)
            .flatMap { CanvasEraserSize(rawValue: $0.doubleValue) } ?? .standard)
        self.noteRecoveryWrite = noteRecoveryWrite
        self.pdfExcerptRecoveryWrite = pdfExcerptRecoveryWrite
        self.pdfExcerptRecoveryOverride = pdfExcerptRecoveryURL
        self.blockRecoveryOverride = blockRecoveryURL
        self.noteRecoveryOverride = noteRecoveryURL ?? blockRecoveryURL.map {
            $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + ".note")
        }
        #if DEBUG
        if case .invalid = CanvasRuntime.launch {
            outboxReadable = false
            blockRecoveryReadable = false
            noteRecoveryReadable = false
            pdfExcerptRecoveryReadable = false
            status = CanvasRuntime.TestError.invalid.localizedDescription
            return
        }
        #endif
        do {
            try Self.preserveLegacyScene()
            if let restored = try Self.restoreScene() {
                scene = restored.scene
                drawing = restored.drawing
                status = "저장된 칠판 복원 · 획 \(scene.strokes.count)개"
            }
        } catch {
            sceneReadable = false
            sceneRecoveryNotice = ScenePersistenceError.unreadable.localizedDescription
            status = sceneRecoveryNotice
        }
        do {
            let url = try Self.outboxURL()
            if FileManager.default.fileExists(atPath:url.path) {
                outbox = try JSONDecoder().decode(CanvasOutbox.self,from:CanvasLocalFile.read(url))
                try outbox.validate()
                packet = outbox.entries.last?.receipt
                if outbox.unresolved != nil { status = "미확인 전송 복원 · 같은 패킷의 영수증만 조회합니다." }
            }
        } catch {
            outboxReadable = false
            status = CanvasSendError.outboxUnavailable.localizedDescription
        }
        do {
            guard let url = self.blockRecoveryURL else { throw VaultBlockRecoveryError.unavailable }
            if FileManager.default.fileExists(atPath:url.path) {
                let bytes = try Self.readBlockRecovery(url)
                blockRecovery = try JSONDecoder().decode(VaultBlockRecoveryFile.self,from:bytes).record()
                blockRecoveryBytes = bytes
                if blockRecovery != nil {
                    blockRecoveryNotice = "보존된 연결 문단 입력이 있습니다. 열기 전에는 전송하지 않습니다."
                }
            }
        } catch {
            blockRecoveryReadable = false
            blockRecoveryNotice = VaultBlockRecoveryError.corrupt.localizedDescription
        }
        do {
            guard let url = self.noteRecoveryURL else { throw VaultBlockRecoveryError.unavailable }
            if FileManager.default.fileExists(atPath:url.path) {
                let bytes = try Self.readBlockRecovery(url)
                noteRecovery = try JSONDecoder().decode(VaultNoteRecoveryFile.self,from:bytes).record()
                noteRecoveryBytes = bytes
                if noteRecovery != nil { noteRecoveryNotice = "보존된 노트 입력이 있습니다. 열기 전에는 전송하지 않습니다." }
            }
        } catch {
            noteRecoveryReadable = false
            noteRecoveryNotice = VaultBlockRecoveryError.corrupt.localizedDescription
        }
        do {
            guard let url = self.pdfExcerptRecoveryURL else { throw VaultBlockRecoveryError.unavailable }
            if FileManager.default.fileExists(atPath:url.path) {
                let bytes = try Self.readBlockRecovery(url)
                pdfExcerptRecovery = try JSONDecoder().decode(VaultPDFCreateRecoveryFile.self,from:bytes).record()
                pdfExcerptRecoveryBytes = bytes
                if pdfExcerptRecovery != nil { pdfExcerptRecoveryNotice = "보존된 PDF 발췌 생성 의도가 있습니다. 자동 전송하지 않습니다." }
            }
        } catch {
            pdfExcerptRecoveryReadable = false
            pdfExcerptRecoveryNotice = VaultBlockRecoveryError.corrupt.localizedDescription
        }
        restoreDocumentSource()
        if !documentSourcePresent { restoreFileWorkspace() }
    }

    private static func outboxURL() throws -> URL {
        try CanvasRuntime.stateURL(.outbox)
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
        guard !isDocumentSource else { throw CanvasDocument.Failure.unsupported }
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
        try? CanvasRuntime.stateURL(.scene)
    }

    private static func restoreScene() throws -> (scene: CanvasScene, drawing: PKDrawing)? {
        guard let url = sceneURL() else { throw ScenePersistenceError.unreadable }
        do { _ = try FileManager.default.attributesOfItem(atPath:url.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let data = try CanvasLocalFile.read(url)
        guard data.count <= sceneByteLimit else { throw ScenePersistenceError.unreadable }
        let scene = try JSONDecoder().decode(CanvasScene.self,from:data)
        guard scene.hasSupportedInkProjection,
              let drawingData = Data(base64Encoded:scene.drawingBase64) else { throw ScenePersistenceError.unreadable }
        let drawing: PKDrawing
        if drawingData.isEmpty { drawing = PKDrawing() }
        else { drawing = try PKDrawing(data:drawingData) }
        try scene.validateNativeInkProjection()
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
        do {
            try persistScene()
            Task { [weak self] in await self?.saveFileWorkspace() }
        } catch { status = "미저장 복구본 보관 실패: \(error.localizedDescription)" }

    }

    private func persistScene(_ candidate: CanvasScene? = nil) throws {
        if isDocumentSource {
            var next = document
            if let candidate {
                guard !documentEditingBlocked else { throw CanvasDocument.Failure.stale }
                try next.updateActivePageForEditing(candidate)
            }
            try writeDocumentSource(next,binding:documentFileBinding)
            documentFileReady = documentFileBinding?.savedSHA == CanvasPacket.sha(try next.bytes()) && fileWorkspaceState != .blocked
            fileWorkspaceStatus = documentFileReady ? "전체 문서 Files 원본 저장 확인 · 동기화 별도" : "전체 문서 복구본 보관 · Files 원본 저장 대기"
            return
        }
        guard sceneReadable else { throw ScenePersistenceError.unreadable }
        guard let url = Self.sceneURL() else { throw ScenePersistenceError.unreadable }
        let candidate = candidate ?? scene
        try candidate.requireCompatibleNodeKinds()
        try candidate.validateNativeInkProjection()
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= Self.sceneByteLimit else { throw ScenePersistenceError.tooLarge }
        try CanvasLocalFile.write(data,to:url)
        if fileWorkspaceState != .blocked {
            fileWorkspaceState = .pending
            fileWorkspaceStatus = fileWorkspace == nil ?
                "저장 위치 미연결 · 미저장 복구본 보관 중. Files 폴더를 선택하세요." :
                "Files 원본 저장 대기 · 미저장 복구본 보관 중"
        }
    }

    private static let sceneByteLimit = CanvasScene.localByteLimit


    @discardableResult
    func updateDrawing(_ next: PKDrawing) -> Bool {
        guard !documentEditingBlocked else { return false }
        guard drawing != next else { return true }
        let nativeBytes = next.dataRepresentation()
        guard let authoritative = try? PKDrawing(data: nativeBytes) else {
            status = "unreadable_drawing · 원본 그림을 읽을 수 없어 기존 원본을 유지합니다."
            return false
        }
        var changed = scene
        changed.schemaVersion = max(2, changed.schemaVersion)
        changed.drawingBase64 = nativeBytes.base64EncodedString()
        changed.strokes = CanvasScene.nativeInkStrokes(authoritative)
        changed.revision += 1
        guard sceneReadable, changed.hasSupportedInkProjection,
              changed.strokes.allSatisfy({ $0.points.allSatisfy { [$0.x, $0.y, $0.pressure].allSatisfy(\.isFinite) } }) else {
            status = "unsupported_ink_projection · 잉크 투영을 확인할 수 없어 기존 원본을 유지합니다."
            return false
        }
        guard let bytes = try? JSONEncoder().encode(changed), bytes.count <= Self.sceneByteLimit else {
            status = "scene_too_large · 칠판 저장 한도를 넘어서 마지막 정상 원본을 유지합니다."
            return false
        }
        storedDrawing = next
        setInkSelection(inkSelection)
        handwritingRequest = nil
        scene = changed
        status = "Pencil 입력 확인 · 획 \(scene.strokes.count)개 · \(mode.rawValue)"
        return true
    }

    func addNode(_ kind: CanvasNode.Kind) {
        guard !documentEditingBlocked else { return }
        selectedNode = scene.addNode(kind: kind,
            at: CanvasPoint(x: 700 - pan.width, y: 430 - pan.height),
            text: kind == .box ? "새 요소" : "새 메모")
        mode = .select
    }

    func addSpokenNote(_ text: String) {
        guard !documentEditingBlocked else { return }
        let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = "저장할 음성 설명이 없습니다."; return }
        selectedNode = scene.addNode(kind:.note,
            at:CanvasPoint(x:700 - pan.width,y:430 - pan.height),text:trimmed)
        mode = .select
        status = "확인한 음성 설명을 캔버스에 저장했습니다. 대화 전송은 별도 버튼으로 진행합니다."
    }

    func select(_ id: UUID) {
        guard !documentEditingBlocked else { return }
        let from = linkStart
        let kind = linkKind
        clearPendingLink()
        let visible = cardTagVisibility.nodeIDs
        guard visible.contains(id), from.map(visible.contains) ?? true else {
            status = "표시 중인 요소가 아니어서 선택하거나 연결하지 않았습니다."
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
        guard !documentEditingBlocked else { return }
        clearPendingLink()
        guard let selectedNode, scene.visibility.nodeIDs.contains(selectedNode) else {
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

    func toggleSelectedChildren() {
        guard !documentEditingBlocked else { return }
        clearPendingLink()
        guard let selectedNode, scene.visibility.nodeIDs.contains(selectedNode),
              scene.toggleChildren(of: selectedNode) else { return }
        let collapsed = scene.nodes.first { $0.id == selectedNode }?.isCollapsed == true
        status = collapsed ? "하위 요소를 접었습니다. 원본 데이터는 보존됩니다." : "하위 요소를 펼쳤습니다."
    }

    func unlinkFromParent() {
        guard !documentEditingBlocked else { return }
        clearPendingLink()
        guard let selectedNode, scene.nodes.contains(where:{ $0.id == selectedNode }) else { return }
        let removed = scene.links.contains(where:{ $0.kind == .parentChild && $0.to == selectedNode })
        guard removed else { status = "해제할 상위 연결이 없습니다."; return }
        scene.links.removeAll(where:{ $0.kind == .parentChild && $0.to == selectedNode })
        scene.revision += 1
        status = "상위 연결을 해제했습니다. 요소와 원문은 보존됐습니다."
    }

    func moveSelected(to point: CGPoint) {
        guard let selectedNode, scene.visibility.nodeIDs.contains(selectedNode) else { return }
        scene.moveNode(selectedNode, to: CanvasPoint(x: Double(point.x), y: Double(point.y)))
    }

    func setInkSelection(_ ids: Set<UUID>) {
        let next = ids.intersection(drawing.strokes.map(\.id))
        guard next != inkSelection else { return }
        pendingInkTextEditing?.invalidatePending()
        pendingInkSpacing?.invalidatePending()
        inkShapeSelectionGeneration &+= 1
        inkMathRequest = nil
        inkMathSelectionGeneration &+= 1
        inkSelection = next
        handwritingRequest = nil
    }

    func proposeHandwriting(selectedOnly: Bool = false, recognize: (PKDrawing) async -> String? = { drawing in
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(drawing)
        return await recognizer.recognizedText()
    }) async {
        guard !documentEditingBlocked else { return }
        let request = UUID()
        handwritingRequest = request
        let sourceDrawing = selectedOnly ? PKDrawing(strokes:drawing.strokes.filter { inkSelection.contains($0.id) }) : drawing
        guard !sourceDrawing.strokes.isEmpty else {
            handwritingRequest = nil
            status = selectedOnly ? "영역 선택 도구로 인식할 글자를 먼저 선택하세요." : "인식할 획이 없습니다."
            return
        }
        let owner = try? document.pageSnapshot()
        let recognized = await recognize(sourceDrawing)
        guard owner.map(document.accepts) == true, handwritingRequest == request else { return }
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


    private weak var pendingInkTextEditing: CanvasInkTextEditing?
    private weak var pendingInkSpacing: CanvasInkSpacingProposal?

    private var inkSpacingDrawingIsCurrent: Bool {
        guard let bytes = Data(base64Encoded:scene.drawingBase64), let native = try? PKDrawing(data:bytes) else { return false }
        return drawing == native
    }

    var canProposeInkSpacing: Bool {
        inkTextEditAllowed && mode == .lasso && inkTextDeletionTarget != nil &&
            inkMathRequest == nil && inkMathProposal == nil && inkShapeProposal == nil &&
            pendingInkTextEditing?.hasPendingWork != true
    }

    func proposeInkSpacing(left: String, right: String, action: CanvasInkSpacingProposal.Action,
                           amount: Double, editing: CanvasInkSpacingProposal,
                           readEvidence: CanvasInkTextEditing.ReadEvidence = CanvasInkTextEditing.nativeEvidence) async {
        guard canProposeInkSpacing, let node = inkTextDeletionTarget,
              inkSpacingDrawingIsCurrent else {
            editing.cancel(); status = "원본 필기 전체에 대응하는 메모 하나를 선택하고 다른 입력·저장을 마쳐 주세요."; return
        }
        pendingInkSpacing?.invalidatePending()
        pendingInkSpacing = editing
        let generation = linkSceneGeneration
        let documentOwner = try? document.pageSnapshot()
        await editing.propose(scene:scene,nodeID:node.id,selection:inkSelection,left:left,right:right,action:action,amount:amount,
            isCurrent:{ [weak self] snapshot in
                guard let self else { return false }
                return documentOwner.map(self.document.accepts) == true && self.inkTextEditAllowed && self.mode == .lasso && generation == self.linkSceneGeneration &&
                    snapshot.matches(scene:self.scene,selection:self.inkSelection)
            },readEvidence:readEvidence)
    }

    @discardableResult
    func confirmInkSpacing(_ editing: CanvasInkSpacingProposal) -> Bool {
        guard inkTextEditAllowed, mode == .lasso, pendingInkSpacing === editing else {
            status = "다른 입력이나 저장이 진행 중입니다. 원본 간격을 유지합니다."; return false
        }
        do {
            let before = scene
            let next = try editing.confirm(current:scene,selection:inkSelection,persist:{ try self.persistScene($0) })
            installInkTextScene(next)
            recordGraphEdit(before:before)
            status = "원본 획 간격을 복구본에 반영했습니다. 구조 수정 되돌리기를 사용할 수 있습니다. 파일 원본 저장·동기화는 별도 상태를 확인하세요."
            return true
        } catch { status = "원본 간격을 저장하지 않았습니다. \(error.localizedDescription)"; return false }
    }


    var inkTextDeletionTarget: CanvasNode? {
        guard !inkSelection.isEmpty else { return nil }
        let candidates = scene.nodes.filter {
            $0.kind == .note && $0.vaultNote == nil && Set($0.sourceStrokeIds) == inkSelection
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private var inkTextEditAllowed: Bool {
        !documentEditingBlocked && !inkMathInputBusy && sceneReadable && !inkBusy && !vaultDirty && !vaultSaving && !vaultLoading && !vaultInputBusy && !vaultBlockEditing &&
            !fileSaveBusy && fileWorkspaceState != .blocked
    }

    func proposeInkTextDeletion(range: NSRange, editing: CanvasInkTextEditing,
                               readEvidence: CanvasInkTextEditing.ReadEvidence = CanvasInkTextEditing.nativeEvidence) async {
        guard !inkMathInputBusy else { status = "수식 교정 입력을 먼저 마쳐 주세요."; return }
        cancelInkMath()
        pendingInkTextEditing?.invalidatePending()
        pendingInkSpacing?.invalidatePending()
        pendingInkTextEditing = editing
        cancelInkShape()
        guard inkTextEditAllowed, let node = inkTextDeletionTarget else {
            editing.cancel()
            status = "인식된 문장에 대응하는 원본 획만 선택하세요. 편집 중인 입력은 먼저 마쳐 주세요."
            return
        }
        let documentOwner = try? document.pageSnapshot()
        await editing.propose(scene: scene, nodeID: node.id, selection: inkSelection, range: range,
            isCurrent: { [weak self] snapshot in
                guard let self else { return false }
                return documentOwner.map(self.document.accepts) == true && self.inkTextEditAllowed && snapshot.matches(scene: self.scene, selection: self.inkSelection)
            }, readEvidence: readEvidence)
    }

    @discardableResult
    func confirmInkTextDeletion(_ editing: CanvasInkTextEditing) -> Bool {
        guard inkTextEditAllowed else { status = "다른 입력이 진행 중이어서 원본을 유지했습니다."; return false }
        do {
            let next = try editing.confirm(current: scene, selection: inkSelection, persist: { try self.persistScene($0) })
            installInkTextScene(next)
            status = "한 글자와 대응 획을 기기 복구본에 반영했습니다. Files 원본 미저장·Obsidian 동기화 대기입니다."
            return true
        } catch { status = "글자 삭제를 저장하지 않았습니다. \(error.localizedDescription)"; return false }
    }

    @discardableResult
    func undoInkTextDeletion(_ editing: CanvasInkTextEditing, redo: Bool = false) -> Bool {
        guard inkTextEditAllowed else { status = "다른 입력이 진행 중이어서 원본을 유지했습니다."; return false }
        do {
            let next = try redo ? editing.redo(current: scene, persist: { try self.persistScene($0) }) :
                editing.undo(current: scene, persist: { try self.persistScene($0) })
            installInkTextScene(next)
            status = redo ? "한 글자 삭제를 복구본에 다시 반영했습니다. Files 원본 미저장·Obsidian 동기화 대기입니다." : "원래 글자와 원본 획을 복구본에 복원했습니다. Files 원본 미저장·Obsidian 동기화 대기입니다."
            return true
        } catch { status = "장면을 덮어쓰지 않았습니다. \(error.localizedDescription)"; return false }
    }

    private func installInkTextScene(_ next: CanvasScene) {
        // 확정 전에 네이티브 원본과 투영을 검증하고 저장했으므로 같은 바이트만 설치한다.
        guard let bytes = Data(base64Encoded: next.drawingBase64), let restored = try? PKDrawing(data: bytes) else { return }
        scene = next
        drawing = restored
        packet = nil
    }

    func searchHandwriting(_ query: String, search: (PKDrawing, String) async -> [Set<UUID>] = { drawing, query in
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(drawing)
        return await recognizer.search(query).map(\.strokes)
    }) async {
        handwritingRequest = nil
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { status = "찾을 글자를 입력하세요."; return }
        let source = drawing
        guard !source.strokes.isEmpty else { status = "검색할 획이 없습니다."; return }
        guard !documentEditingBlocked else { return }
        let request = UUID()
        handwritingRequest = request
        let owner = try? document.pageSnapshot()
        let matches = await search(source, query)
        guard owner.map(document.accepts) == true, handwritingRequest == request else { return }
        handwritingRequest = nil
        let validIDs = Set(source.strokes.map(\.id))
        let validMatches = matches.map { $0.intersection(validIDs) }.filter { !$0.isEmpty }
        guard !validMatches.isEmpty else {
            status = "일치하는 손글씨를 찾지 못했습니다. 원본과 선택은 유지했습니다."
            return
        }
        mode = .lasso
        setInkSelection(validMatches.reduce(into:Set<UUID>()) { $0.formUnion($1) })
        status = "손글씨 검색 결과 \(validMatches.count)곳을 선택했습니다."
    }

    var proposalIsCurrent: Bool {
        guard !documentEditingBlocked else { return false }
        guard let context = proposalContext, context.sceneID == scene.id,
              context.generation == noteSceneGeneration, context.node.id == proposedNode else { return false }
        guard let current = scene.nodes.first(where:{ $0.id == context.node.id }) else { return false }
        return current == context.node && current.text.utf8.elementsEqual(context.node.text.utf8)
    }

    func confirmProposal() {
        guard let proposedNode else { return }
        guard proposalIsCurrent else {
            status = "다른 곳에서 요소나 장면이 바뀌었습니다. 입력은 유지하며 덮어쓰지 않습니다. 닫고 최신 요소를 다시 열어 주세요."
            return
        }
        let text = proposalContext?.node.confidence == .confirmed ? proposalText :
            proposalText.trimmingCharacters(in:.whitespacesAndNewlines)
        let before = scene
        guard scene.confirmNode(proposedNode, text: text) else {
            status = "내용 한도나 요소 상태를 확인하세요. 연결된 노트는 원본 노트 편집에서 수정하세요."
            return
        }
        recordGraphEdit(before:before)
        self.proposedNode = nil
        status = "수정한 글자를 확정했습니다. 원본 획 출처는 남겼습니다."
    }

    func importScene(_ imported: CanvasScene) throws {
        guard !isDocumentSource || imported.id == document.activePageID else { throw CanvasDocument.Failure.unsupported }
        guard !vaultDirty, !vaultSaving, !cardTagInputBusy else { throw CocoaError(.userCancelled) }
        guard !inkBusy else { throw CanvasPenSettingsError.inkBusy }
        guard imported.hasSupportedInkProjection, imported.width > 0, imported.height > 0,
              imported.nodes.count < 1000, imported.strokes.count < 10000,
              imported.nodes.allSatisfy(\.hasValidRotation) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard try JSONEncoder().encode(imported).count <= Self.sceneByteLimit else { throw CanvasPenSettingsError.sceneTooLarge }
        guard let drawingData = Data(base64Encoded: imported.drawingBase64) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let next = try drawingData.isEmpty ? PKDrawing() : PKDrawing(data: drawingData)
        try imported.validateNativeInkProjection()
        invalidateNoteScene()
        scene = imported
        drawing = next
        selectedNode = nil
        packet = nil
        status = "장면을 가져왔습니다. 그림과 구조 데이터를 함께 복원했습니다."
    }

    var hasPendingInkProposal: Bool {
        pendingInkSpacing?.hasPendingWork == true || pendingInkTextEditing?.hasPendingWork == true ||
        inkShapeProposal != nil || inkMathRequest != nil || inkMathProposal != nil || handwritingRequest != nil
    }
    var canApplyReconciledCanvas: Bool {
        !documentEditingBlocked && sceneReadable && !cardTagInputBusy && !noteReconciliationHeld && !hasPendingInkProposal && pdfExcerptRecoveryReadable && !hasPendingPDFExcerpt &&
        fileWorkspaceState != .blocked && !fileSaveBusy && !inkBusy &&
        !vaultDirty && !vaultSaving && !vaultLoading && !vaultInputBusy && !vaultBlockEditing &&
        !inkMathInputBusy && inkMathProposal == nil && !commentInputBusy && commentSession == nil && proposedNode == nil
    }
    // Explicit server reconciliation only. Preserve the exact local scene before replacing its cache.
    func applyReconciledCanvas(_ imported: CanvasScene, expectedLocalSHA: String, preservedAt: URL) throws {
        guard !isDocumentSource, canApplyReconciledCanvas else { throw CocoaError(.userCancelled) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(scene)
        guard CanvasPacket.sha(before) == expectedLocalSHA,
              CanvasPacket.sha(try CanvasLocalFile.read(preservedAt)) == expectedLocalSHA,
              imported.id == scene.id, imported.hasSupportedInkProjection,
              imported.width > 0, imported.height > 0, imported.nodes.count < 1000, imported.strokes.count < 10000,
              imported.nodes.allSatisfy(\.hasValidRotation), let native = Data(base64Encoded:imported.drawingBase64) else {
            throw VaultBlockRecoveryError.changed
        }
        _ = try native.isEmpty ? PKDrawing() : PKDrawing(data:native)
        try imported.requireCompatibleNodeKinds(); try imported.validateNativeInkProjection()
        // Both operations are synchronous after identical import guards. Cache IO fails before memory replacement.
        try persistScene(imported)
        try importScene(imported)
        status = "명시적으로 선택한 서버 원본을 열었습니다. 이전 iPad 입력은 복구본에 보존했으며 Files 저장은 별도 대기 상태입니다."
    }

    @discardableResult
    func applyAgentRevision(_ revision: AgentRevision) -> Bool {
        guard !isDocumentSource else { status = "문서 전체 API의 수정만 받을 수 있습니다."; return false }
        if let settings = revision.setPenSettings {
            do {
                guard revision.isPenSettingsOnly else { throw CanvasPenSettingsError.unsupportedInkEdit }
                let result = try setPenSettings(settings, sceneID: revision.sceneId, baseRevision: revision.baseRevision)
                if result.disposition == .noop { status = "이미 같은 펜 설정입니다. 기존 획은 그대로 유지됩니다." }
                return true
            } catch {
                status = "\((error as? CanvasPenSettingsError)?.rawValue ?? "pen_settings_not_saved") · \(error.localizedDescription)"
                return false
            }
        }
        let sent = outbox.entries.first(where: { $0.id == packet?.packetId })
            .flatMap { try? $0.packet.frozenScene() }
        var next = scene
        guard next.apply(revision, basedOn:sent) else {
            status = "에이전트 제안이 현재 그림과 충돌해 자동 반영하지 않았습니다."
            return false
        }
        if next.revision != scene.revision {
            let before = scene
            scene = next
            recordGraphEdit(before:before)
        }
        status = "에이전트의 구조 수정과 제안을 반영했습니다. 원본 획과 요소 출처는 보존했습니다."
        return true
    }

    struct DocumentSyncState: Codable {
        enum Phase: String, Codable { case synchronized, sending, held, resolving }
        let schema: String
        let id: UUID
        let address: String
        var phase: Phase
        var base: CanvasDocumentRelay.Base? = nil
        var localSHA: String? = nil
        var operationID: UUID? = nil
        var proposalBinding: DocumentFileBinding? = nil
        var conflict: CanvasDocumentRelay.Conflict? = nil
        var decision: CanvasRelay.ConflictDecision? = nil
        func validate(id expected: UUID) throws {
            guard schema == "ccr.document-sync/v1", id == expected,
                  let origin = URL(string:address), origin.scheme == "http" || origin.scheme == "https",
                  origin.host != nil, origin.user == nil, origin.password == nil,
                  localSHA.map(CanvasDocumentRelay.hash) ?? true else { throw CanvasDocument.Failure.invalid }
            try base?.validate()
            if phase != .synchronized {
                guard operationID != nil, let proposalBinding, proposalBinding.id == expected,
                      CanvasDocumentRelay.hash(proposalBinding.savedSHA), CanvasDocumentRelay.hash(proposalBinding.token) else { throw CanvasDocument.Failure.invalid }
            }
            if let conflict { _ = try conflict.validated(id:expected) }
        }
    }
    @Published private(set) var documentSync: DocumentSyncState?
    @Published private(set) var documentConflict: CanvasDocumentRelay.Conflict?
    @Published private(set) var documentCandidates: [CanvasDocumentRelay.MaterialName:CanvasDocumentRelay.Validated] = [:]
    @Published private(set) var documentSyncStatus = "문서 전체 동기화 대기"
    private var documentAddress = "", documentToken = ""
    var documentSyncHeld: Bool { isDocumentSource && documentSync.map { $0.phase != .synchronized } == true }
    var documentEditingBlocked: Bool { isDocumentSource && (documentBusy || documentSyncHeld || !sceneReadable) }
    func setDocumentConnection(address: String, token: String) {
        guard address != documentAddress || token != documentToken else { return }
        documentAddress = address; documentToken = token
        documentRequest = UUID(); documentBusy = false
        documentConflict = nil; documentCandidates = [:]
    }
    private func documentCurrent(_ owner: CanvasDocument.PageSnapshot, request: UUID, relay: CanvasRelay) -> Bool {
        documentRequest == request && documentRequestPresentationEpoch == documentPresentationEpoch && document.accepts(owner) &&
            documentAddress == relay.address && documentToken == relay.token && !Task.isCancelled
    }
    private func documentCurrentCheck(_ owner: CanvasDocument.PageSnapshot, request: UUID, relay: CanvasRelay) -> @Sendable () async -> Bool {
        { [weak self] in await self?.documentCurrent(owner,request:request,relay:relay) == true }
    }
    private func holdDocumentSync(_ error: Error, request: UUID) {
        guard documentRequest == request, var state = documentSync, state.phase != .synchronized else { return }
        state.phase = .held
        // 실패·연결 변경 뒤에도 sending/resolving 자체가 지속 barrier다. 이 갱신 실패로 이를 해제하지 않는다.
        do { try writeDocumentSource(document,binding:documentFileBinding,sync:state); documentSync = state }
        catch { sceneReadable = false }
        documentSyncStatus = "문서 전체 저장 결과 미확인·조정 필요. 자동 재시도하지 않습니다. " + error.localizedDescription
    }
    private func installRemoteDocument(_ received: CanvasDocumentRelay.Validated, sync: DocumentSyncState,
                                       owner: CanvasDocument.PageSnapshot, request: UUID, relay: CanvasRelay) throws {
        guard documentCurrent(owner,request:request,relay:relay), let files = documentFiles,
              let prior = documentFileBinding, received.document.id == document.id else { throw CanvasDocument.Failure.stale }
        // 기존 전체 세대는 Files immutable generation에 남긴다. 선택 페이지만 따로 설치하지 않는다.
        let reopened = try files.save(received.document,previews:received.previews,expected:prior.token)
        guard !reopened.publicationPending, reopened.document == received.document,
              reopened.previews == received.previews, documentCurrent(owner,request:request,relay:relay) else { throw CanvasDocumentFiles.Failure.publicationUnconfirmed }
        let binding = DocumentFileBinding(bookmark:prior.bookmark,id:document.id,token:reopened.token,savedSHA:CanvasPacket.sha(try received.document.bytes()))
        try writeDocumentSource(received.document,binding:binding,sync:sync)
        let sameDocument = document == received.document
        documentSync = sync
        if sameDocument { documentFileBinding = binding }
        else { try installDocument(received.document,binding:binding,preservingHistory:false) }
        documentFileReady = true; fileWorkspaceState = .ready
        documentSyncStatus = "문서 전체·모든 페이지 자산을 Files에 저장하고 서버에서 다시 확인했습니다."
    }
    func synchronizeDocumentToVault(_ relay: CanvasRelay) async {
        guard isDocumentSource, documentOperationsEnabled, !documentBusy, !documentSyncHeld,
              documentFileReady, let binding = documentFileBinding,
              documentAddress == relay.address, documentToken == relay.token else { return }
        let request = UUID()
        do {
            try documentBarrierCheck()
            let owner = try document.pageSnapshot(), bytes = try document.bytes(), sha = CanvasPacket.sha(bytes)
            if let prior = documentSync {
                guard prior.address == relay.address else { throw CanvasDocument.Failure.stale }
                if prior.localSHA == sha { return }
            }
            documentRequest = request; documentRequestPresentationEpoch = documentPresentationEpoch; documentBusy = true
            defer { if documentRequest == request { documentBusy = false } }
            let previews = try await documentPreviews(document,owner:owner)
            guard documentCurrent(owner,request:request,relay:relay) else { throw CanvasDocument.Failure.stale }
            let intent = DocumentSyncState(schema:"ccr.document-sync/v1",id:document.id,address:relay.address,phase:.sending,
                base:documentSync?.base,localSHA:documentSync?.localSHA,operationID:UUID(),proposalBinding:binding)
            try intent.validate(id:document.id)
            try writeDocumentSource(document,binding:binding,sync:intent); documentSync = intent
            let returned = try await relay.saveVaultDocument(documentJSON:bytes,previews:previews,base:intent.base,
                isCurrent:documentCurrentCheck(owner,request:request,relay:relay))
            guard documentCurrent(owner,request:request,relay:relay) else { throw CanvasDocument.Failure.stale }
            let checkpoint = DocumentSyncState(schema:intent.schema,id:document.id,address:relay.address,phase:.synchronized,
                base:returned.summary.base,localSHA:sha)
            try installRemoteDocument(returned,sync:checkpoint,owner:owner,request:request,relay:relay)
        } catch { holdDocumentSync(error,request:request) }
    }
    func refreshDocumentFromVault(_ relay: CanvasRelay) async {
        guard isDocumentSource, documentOperationsEnabled, !documentBusy, !documentSyncHeld,
              let prior = documentSync, prior.address == relay.address, prior.phase == .synchronized,
              prior.localSHA == (try? CanvasPacket.sha(document.bytes())), documentFileReady else { return }
        let request = UUID()
        do {
            try documentBarrierCheck()
            let owner = try document.pageSnapshot()
            documentRequest = request; documentRequestPresentationEpoch = documentPresentationEpoch; documentBusy = true
            defer { if documentRequest == request { documentBusy = false } }
            let received = try await relay.vaultDocument(id:document.id,isCurrent:documentCurrentCheck(owner,request:request,relay:relay))
            guard documentCurrent(owner,request:request,relay:relay) else { throw CanvasDocument.Failure.stale }
            if received.summary.base == prior.base { return }
            let checkpoint = DocumentSyncState(schema:prior.schema,id:document.id,address:relay.address,phase:.synchronized,
                base:received.summary.base,localSHA:CanvasPacket.sha(try received.document.bytes()))
            try installRemoteDocument(received,sync:checkpoint,owner:owner,request:request,relay:relay)
        } catch {
            guard documentRequest == request else { return }
            documentSyncStatus = "문서 전체 역수신을 적용하지 않았습니다. " + error.localizedDescription
        }
    }
    /// 사용자가 직접 누른 읽기 재확인이다. 서버 미조정 journal은 typed GET 거부로 그대로 유지한다.
    func confirmDocumentAcknowledgement(_ relay: CanvasRelay) async {
        guard isDocumentSource, documentSyncHeld, !documentBusy, !inkBusy, !documentPresentationBusy,
              let intent = documentSync, intent.address == relay.address, let binding = documentFileBinding,
              let proposal = intent.proposalBinding, proposal.id == binding.id, proposal.token == binding.token,
              proposal.savedSHA == binding.savedSHA, let files = documentFiles else { return }
        let request = UUID()
        do {
            try documentBarrierCheck(reconciling:true)
            let owner = try document.pageSnapshot(), before = try files.load(document.id)
            guard !before.publicationPending, before.token == binding.token, before.document == document else { throw CanvasDocumentFiles.Failure.conflict }
            documentRequest = request; documentRequestPresentationEpoch = documentPresentationEpoch; documentBusy = true
            defer { if documentRequest == request { documentBusy = false } }
            let received = try await relay.vaultDocument(id:document.id,isCurrent:documentCurrentCheck(owner,request:request,relay:relay))
            guard documentCurrent(owner,request:request,relay:relay), received.document == document,
                  received.previews == before.previews else { throw CanvasDocument.Failure.stale }
            let after = try files.load(document.id)
            guard !after.publicationPending, after.token == before.token, after.document == before.document,
                  after.previews == before.previews else { throw CanvasDocumentFiles.Failure.conflict }
            let checkpoint = DocumentSyncState(schema:intent.schema,id:document.id,address:relay.address,phase:.synchronized,
                base:received.summary.base,localSHA:CanvasPacket.sha(try document.bytes()))
            try writeDocumentSource(document,binding:binding,sync:checkpoint); documentSync = checkpoint
            documentSyncStatus = "사용자가 서버 전체 원본과 모든 페이지 자산의 일치를 재확인했습니다. 새 쓰기는 보내지 않았습니다."
        } catch {
            guard documentRequest == request else { return }
            documentSyncStatus = "미확인 상태를 유지합니다. 전체 원본 재확인: " + error.localizedDescription
        }
    }
    // 사용자가 비교를 열었을 때만 읽는다. 409/같은 SHA/재실행 자체로 barrier를 해제하지 않는다.
    func readDocumentConflict(_ relay: CanvasRelay) async {
        guard isDocumentSource, documentSyncHeld, !documentBusy, !inkBusy, !documentPresentationBusy,
              documentSync?.address == relay.address else { return }
        let request = UUID()
        do {
            let owner = try document.pageSnapshot()
            documentRequest = request; documentRequestPresentationEpoch = documentPresentationEpoch; documentBusy = true
            defer { if documentRequest == request { documentBusy = false } }
            let current = documentCurrentCheck(owner,request:request,relay:relay)
            let conflict = try await relay.vaultDocumentConflict(id:document.id,isCurrent:current)
            var candidates: [CanvasDocumentRelay.MaterialName:CanvasDocumentRelay.Validated] = [:]
            for name in CanvasDocumentRelay.MaterialName.allCases where conflict.materials[name]?.validDocument == true {
                candidates[name] = try await relay.vaultDocumentCandidate(conflict,material:name,isCurrent:current)
            }
            guard documentCurrent(owner,request:request,relay:relay), var state = documentSync else { throw CanvasDocument.Failure.stale }
            state.conflict = conflict
            try writeDocumentSource(document,binding:documentFileBinding,sync:state)
            documentSync = state; documentConflict = conflict; documentCandidates = candidates
            documentSyncStatus = "전체 문서의 현재·이전·외부·제안 자료를 비교한 뒤 명시적으로 선택하세요."
        } catch {
            guard documentRequest == request else { return }
            documentSyncStatus = "미확인 상태를 유지합니다. 충돌 자료 읽기 실패: " + error.localizedDescription
        }
    }
    func resolveDocumentConflict(_ decision: CanvasRelay.ConflictDecision, relay: CanvasRelay) async {
        guard isDocumentSource, !documentBusy, !inkBusy, documentSyncHeld,
              let conflict = documentConflict, var intent = documentSync,
              let candidate = documentCandidates[conflict.chosen(decision)], let files = documentFiles,
              let binding = documentFileBinding else { return }
        let request = UUID()
        do {
            try documentBarrierCheck(reconciling:true)
            let latest = try files.load(document.id)
            guard !latest.publicationPending, latest.token == binding.token,
                  latest.document == document else { throw CanvasDocumentFiles.Failure.conflict }
            let owner = try document.pageSnapshot()
            documentRequest = request; documentRequestPresentationEpoch = documentPresentationEpoch; documentBusy = true
            defer { if documentRequest == request { documentBusy = false } }
            intent.phase = .resolving; intent.operationID = intent.operationID ?? UUID(); intent.decision = decision
            try writeDocumentSource(document,binding:binding,sync:intent); documentSync = intent
            let result = try await relay.resolveVaultDocumentConflict(conflict,decision:decision,candidate:candidate,
                isCurrent:documentCurrentCheck(owner,request:request,relay:relay))
            guard documentCurrent(owner,request:request,relay:relay) else { throw CanvasDocument.Failure.stale }
            let checkpoint = DocumentSyncState(schema:intent.schema,id:document.id,address:relay.address,phase:.synchronized,
                base:result.summary.base,localSHA:CanvasPacket.sha(try result.document.bytes()))
            try installRemoteDocument(result,sync:checkpoint,owner:owner,request:request,relay:relay)
            documentConflict = nil; documentCandidates = [:]
        } catch { holdDocumentSync(error,request:request) }
    }
    struct DocumentFileBinding: Codable {
        let bookmark: Data
        let id: UUID
        let token: String
        let savedSHA: String
    }
    private struct DocumentSourceState: Codable {
        let schema: String
        let kind: SourceKind
        let document: CanvasDocument?
        let binding: DocumentFileBinding?
        var sync: DocumentSyncState? = nil
    }
    // 저장 재사용 ded8020의 독립 SOURCE_CLEAR와 공식486 통합을 전제로 한 제품 진입이다.
    @Published private(set) var documentOperationsEnabled = true
    @Published private(set) var documentBusy = false
    @Published var documentPresentationBusy = false { didSet { if oldValue != documentPresentationBusy { documentPresentationEpoch &+= 1 } } }
    private var documentPresentationEpoch: UInt64 = 0
    private var documentRequestPresentationEpoch: UInt64 = 0
    @Published private(set) var documentFileReady = false
    private var documentFileBinding: DocumentFileBinding?
    private var documentFiles: CanvasDocumentFiles?
    private var installingDocument = false
    private var documentSourcePresent = false
    private var documentRequiresScope = true
    private var documentRequest = UUID()
    private struct PageOwner: Hashable { let documentID: UUID; let pageID: UUID }
    private struct PageGraphHistory {
        let undo: (before:CanvasScene,after:CanvasScene)?
        let redo: (before:CanvasScene,after:CanvasScene)?
        let persistence: Bool
    }
    private var documentGraphHistories: [PageOwner:PageGraphHistory] = [:]
    private var legacyGraphHistory: PageGraphHistory?
    private var documentGlyphEditors: [PageOwner:CanvasInkTextEditing] = [:]
    private var documentSpacingEditors: [PageOwner:CanvasInkSpacingProposal] = [:]
    var documentGlyphEditor: CanvasInkTextEditing {
        let owner = PageOwner(documentID:document.id,pageID:scene.id)
        if let editing = documentGlyphEditors[owner] { return editing }
        let editing = CanvasInkTextEditing(); documentGlyphEditors[owner] = editing; return editing
    }
    var documentSpacingEditor: CanvasInkSpacingProposal {
        let owner = PageOwner(documentID:document.id,pageID:scene.id)
        if let editing = documentSpacingEditors[owner] { return editing }
        let editing = CanvasInkSpacingProposal(); documentSpacingEditors[owner] = editing; return editing
    }
    #if DEBUG
    func enableDocumentChecks() {
        if case .isolated = CanvasRuntime.launch { documentOperationsEnabled = true; documentRequiresScope = false }
    }
    #endif
    var canTransitionDocument: Bool { !documentBusy && documentInputsClear }
    private var documentInputsClear: Bool { documentRecoveryInputsClear() && !documentPresentationBusy && !documentSyncHeld }
    private func documentRecoveryInputsClear(recoveringFiles: Bool = false) -> Bool {
        documentOperationsEnabled && !pdfViewBusy && pdfViewReader?.hasViewEdits != true && (sceneReadable || recoveringFiles) &&
        !fileSaveBusy && (fileWorkspaceState != .blocked || recoveringFiles) && !inkBusy && !hasPendingInkProposal &&
        !inkMathInputBusy && !cardTagInputBusy && cardTagEditor == nil && cardMergeDraft == nil &&
        proposedNode == nil && commentSession == nil && !commentInputBusy &&
        nodeResizeDrag == nil && nodeRotationDrag == nil && endpointDrag == nil && linkStart == nil &&
        !vaultDirty && !vaultSaving && !vaultLoading && !vaultInputBusy && !vaultBlockEditing &&
        noteInputSession == nil && outboxReadable && outbox.unresolved == nil && !sendBusy &&
        noteRecoveryReadable && noteRecovery == nil && !noteRecoveryWriteFailed && noteRecoveryAttemptedBytes == nil &&
        blockRecoveryReadable && blockRecovery == nil && pendingBlockEdit == nil &&
        pdfExcerptRecoveryReadable && pdfExcerptRecovery == nil && pdfExcerptRecoveryAttemptedBytes == nil &&
        !noteReconciliationHeld
    }
    private func documentBarrierCheck(checkFiles: Bool = true, reconciling: Bool = false, recoveringFiles: Bool = false) throws {
        let recovering = recoveringFiles && isDocumentSource && (try? document.bytes()) != nil
        let allowed = recovering ? (!documentBusy && !documentPresentationBusy && !documentSyncHeld && documentRecoveryInputsClear(recoveringFiles:true)) :
            reconciling ? (!documentBusy && documentRecoveryInputsClear()) : canTransitionDocument
        guard allowed else { throw CocoaError(.userCancelled) }
        let checkpointURL = try CanvasRuntime.stateURL(.checkpoint)
        if FileManager.default.fileExists(atPath:checkpointURL.path) {
            let checkpoint = try JSONDecoder().decode(CanvasVaultCheckpoint.self,from:CanvasLocalFile.read(checkpointURL))
            guard !checkpoint.requiresExplicitReconciliation, checkpoint.pendingSceneSha == nil else { throw VaultBlockRecoveryError.changed }
        }
        try checkDocumentRecoveryJournals()
        if checkFiles, let files = documentFiles, let binding = documentFileBinding {
            let latest = try files.load(document.id)
            guard !latest.publicationPending, latest.token == binding.token else { throw CanvasDocumentFiles.Failure.conflict }
        }
    }
    private func checkpointCurrentDocumentForReplacement() throws {
        guard isDocumentSource, !documentBusy else { return }
        try writeDocumentSource(document,binding:documentFileBinding)
    }
    private func requireCurrentDocumentPreserved() throws {
        guard isDocumentSource else { return }
        guard let files = documentFiles, let binding = documentFileBinding,
              binding.id == document.id, try CanvasPacket.sha(document.bytes()) == binding.savedSHA else {
            throw CanvasDocumentFiles.Failure.pending
        }
        let reopened = try files.load(document.id)
        guard !reopened.publicationPending, reopened.token == binding.token,
              reopened.document == document else { throw CanvasDocumentFiles.Failure.conflict }
    }
    private func writeDocumentSource(_ next: CanvasDocument, binding: DocumentFileBinding?, sync: DocumentSyncState? = nil) throws {
        try next.validate()
        if isDocumentSource, next.id != document.id { try requireCurrentDocumentPreserved() }
        let state = DocumentSourceState(schema:"ccr.canvas-document-source/v1",kind:.document,document:next,binding:binding,sync:sync ?? documentSync.flatMap { $0.id == next.id ? $0 : nil })
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= CanvasDocument.byteLimit + CanvasDocumentRelay.conflictLimit + 1024*1024 else { throw CanvasDocument.Failure.tooLarge }
        let url = try CanvasRuntime.stateURL(.documentSource)
        try CanvasLocalFile.write(bytes,to:url)
        guard try CanvasLocalFile.read(url) == bytes else { throw CanvasDocumentFiles.Failure.corrupt }
    }
    private func restoreDocumentSource() {
        do {
            let url = try CanvasRuntime.stateURL(.documentSource)
            guard FileManager.default.fileExists(atPath:url.path) else { return }
            documentSourcePresent = true
            let bytes = try CanvasLocalFile.read(url)
            guard bytes.count <= CanvasDocument.byteLimit + CanvasDocumentRelay.conflictLimit + 1024*1024,
                  let fields = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                  Set(fields.keys).isSubset(of:["schema","kind","document","binding","sync"]) else { throw CanvasDocument.Failure.unsupported }
            let state = try JSONDecoder().decode(DocumentSourceState.self,from:bytes)
            guard state.schema == "ccr.canvas-document-source/v1" else { throw CanvasDocument.Failure.unsupported }
            if state.kind == .legacy { documentSourcePresent = false; return }
            guard let next = state.document else { throw CanvasDocument.Failure.invalid }
            try next.validate()
            try state.sync?.validate(id:next.id)
            documentSync = state.sync
            document = next; sourceKind = .document; documentFileBinding = state.binding
            guard let raw = Data(base64Encoded:scene.drawingBase64) else { throw CanvasDocument.Failure.invalid }
            storedDrawing = try raw.isEmpty ? PKDrawing() : PKDrawing(data:raw)
            sceneReadable = true; sceneRecoveryNotice = ""
            if let binding = state.binding {
                var stale = false
                let folder = try URL(resolvingBookmarkData:binding.bookmark,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale)
                guard !stale, binding.id == next.id else { throw CanvasFileWorkspace.Failure.staleBookmark }
                #if DEBUG
                if case .isolated = CanvasRuntime.launch { documentRequiresScope = false }
                #endif
                let files = CanvasDocumentFiles(folder:folder,requiresScope:documentRequiresScope)
                let loaded = try files.load(next.id)
                documentFiles = files
                guard !loaded.publicationPending, loaded.token == binding.token else { throw CanvasDocumentFiles.Failure.conflict }
                documentFileReady = try CanvasPacket.sha(next.bytes()) == binding.savedSHA
            }
            fileWorkspaceStatus = documentFileReady ? "전체 문서 Files 원본 복원 완료" : "전체 문서 복구본 복원 · Files 원본 미저장"
        } catch { sceneReadable = false; fileWorkspaceState = .blocked; sceneRecoveryNotice = "문서 원본을 보존하며 열기를 중단했습니다. \(error.localizedDescription)" }
    }
    private func installDocument(_ next: CanvasDocument, binding: DocumentFileBinding?, preservingHistory: Bool) throws {
        try next.validate()
        guard let raw = Data(base64Encoded:next.activePage.drawingBase64) else { throw CanvasDocument.Failure.invalid }
        let native = try raw.isEmpty ? PKDrawing() : PKDrawing(data:raw)
        let previous = scene
        if !preservingHistory {
            inkHistory.invalidateDocument(next.id)
            documentGraphHistories = documentGraphHistories.filter { $0.key.documentID != next.id }
            documentGlyphEditors = documentGlyphEditors.filter { $0.key.documentID != next.id }
            documentSpacingEditors = documentSpacingEditors.filter { $0.key.documentID != next.id }
        }
        if !isDocumentSource { legacyGraphHistory = .init(undo:graphUndo,redo:graphRedo,persistence:graphRequiresPersistence) }
        if preservingHistory {
            documentGraphHistories[PageOwner(documentID:document.id,pageID:previous.id)] = .init(undo:graphUndo,redo:graphRedo,persistence:graphRequiresPersistence)
        }
        saveTask?.cancel(); installingDocument = true
        if document.id != next.id { documentSync = nil }
        document = next; sourceKind = .document; documentFileBinding = binding
        inkHistory.activate(nativeHistoryOwner)
        if !preservingHistory { inkHistory.invalidate() }
        sceneDidChange(from:previous)
        storedDrawing = native; setInkSelection([]); selectedNode = nil; packet = nil
        invalidateNoteScene(); clearPendingLink(); clearLinkSelection()
        let history = preservingHistory ? documentGraphHistories[PageOwner(documentID:next.id,pageID:scene.id)] : nil
        graphUndo = history?.undo; graphRedo = history?.redo; graphRequiresPersistence = history?.persistence ?? false
        graphPersistenceEpoch = graphRequiresPersistence ? linkSceneGeneration : nil
        installingDocument = false
        saveTask?.cancel()
    }
    private func documentStorageInputsClear(recoveringFiles: Bool) -> Bool {
        documentInputsClear || (recoveringFiles && isDocumentSource && !documentSyncHeld &&
            !documentPresentationBusy && documentRecoveryInputsClear(recoveringFiles:true))
    }
    private func documentPreviews(_ next: CanvasDocument, owner: CanvasDocument.PageSnapshot, recoveringFiles: Bool = false) async throws -> [UUID:Data] {
        var result: [UUID:Data] = [:]
        for page in next.pages {
            guard let png = await filePreview?(page), document.accepts(owner), documentStorageInputsClear(recoveringFiles:recoveringFiles), !Task.isCancelled else { throw CanvasDocument.Failure.stale }
            result[page.id] = png
        }
        return result
    }
    private func savedDocument(_ next: CanvasDocument, files: CanvasDocumentFiles, bookmark: Data,
                               expected: String?, owner: CanvasDocument.PageSnapshot, recoveringFiles: Bool = false) async throws -> DocumentFileBinding {
        let previews = try await documentPreviews(next,owner:owner,recoveringFiles:recoveringFiles)
        guard document.accepts(owner), documentStorageInputsClear(recoveringFiles:recoveringFiles) else { throw CanvasDocument.Failure.stale }
        try checkDocumentRecoveryJournals()
        let readback = try files.save(next,previews:previews,expected:expected)
        guard readback.document == next, !readback.publicationPending else { throw CanvasDocumentFiles.Failure.publicationUnconfirmed }
        return DocumentFileBinding(bookmark:bookmark,id:next.id,token:readback.token,savedSHA:CanvasPacket.sha(try next.bytes()))
    }
    func createDocument() throws {
        try documentBarrierCheck()
        guard !isDocumentSource else { throw CocoaError(.userCancelled) }
        try persistScene()
        let next = try CanvasDocument(legacy:scene)
        documentSync = nil
        try writeDocumentSource(next,binding:nil)
        try installDocument(next,binding:nil,preservingHistory:false)
        documentFileReady = false; fileWorkspaceStatus = "새 전체 문서 복구본 · Files 원본 저장 위치를 선택하세요."
    }
    private func preserveDocumentBeforeOpening(owner: CanvasDocument.PageSnapshot, request: UUID) async throws {
        guard isDocumentSource else { return }
        guard let files = documentFiles, let prior = documentFileBinding else { throw CanvasDocumentFiles.Failure.pending }
        let source = document, sha = CanvasPacket.sha(try source.bytes())
        let reopened = try files.load(source.id)
        guard !reopened.publicationPending, reopened.token == prior.token else { throw CanvasDocumentFiles.Failure.conflict }
        if sha != prior.savedSHA {
            let saved = try await savedDocument(source,files:files,bookmark:prior.bookmark,expected:prior.token,owner:owner)
            guard documentRequest == request, documentRequestPresentationEpoch == documentPresentationEpoch,
                  document.accepts(owner), !Task.isCancelled else { throw CanvasDocument.Failure.stale }
            try writeDocumentSource(source,binding:saved)
            documentFileBinding = saved
        }
        try requireCurrentDocumentPreserved()
        documentFileReady = true
        fileWorkspaceStatus = "현재 문서 전체를 원래 Files에서 재열어 보존을 확인했습니다."
    }
    func connectDocumentWorkspace(_ folder: URL, opening id: UUID? = nil) async {
        do {
            // 거부·충돌에서도 현재 전체 입력은 먼저 남긴다. 캐시만으로 교체를 승인하지는 않는다.
            try checkpointCurrentDocumentForReplacement()
            try documentBarrierCheck(checkFiles:false,recoveringFiles:isDocumentSource && id == nil)
            let owner = try document.pageSnapshot(), request = UUID()
            documentRequest = request; documentRequestPresentationEpoch = documentPresentationEpoch; documentBusy = true
            defer { if documentRequest == request { documentBusy = false } }
            if !isDocumentSource { try persistScene() }
            if documentRequiresScope, let own = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.deletingLastPathComponent() {
                let selected = folder.resolvingSymlinksInPath().standardizedFileURL.path, app = own.resolvingSymlinksInPath().standardizedFileURL.path
                guard selected != app, !selected.hasPrefix(app + "/") else { throw CanvasFileWorkspace.Failure.sandboxFolder }
            }
            let access = folder.startAccessingSecurityScopedResource()
            guard access || !documentRequiresScope else { throw CanvasDocumentFiles.Failure.permission }
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            #if os(macOS)
            let bookmark = try folder.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            #else
            let bookmark = try folder.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
            #endif
            if id != nil { try await preserveDocumentBeforeOpening(owner:owner,request:request) }
            let files = CanvasDocumentFiles(folder:folder,requiresScope:documentRequiresScope)
            let next: CanvasDocument, binding: DocumentFileBinding
            if let id {
                let snapshot = try files.load(id)
                guard !snapshot.publicationPending else { throw CanvasDocumentFiles.Failure.pending }
                // legacy Files 원본은 명시 승격을 선택한 새 Document 진입에서만 감싼다.
                next = snapshot.document
                binding = DocumentFileBinding(bookmark:bookmark,id:next.id,token:snapshot.token,savedSHA:CanvasPacket.sha(try next.bytes()))
            } else {
                next = document
                binding = try await savedDocument(next,files:files,bookmark:bookmark,expected:nil,owner:owner,recoveringFiles:isDocumentSource)
            }
            guard documentRequest == request, documentRequestPresentationEpoch == documentPresentationEpoch,
                  document.accepts(owner), !Task.isCancelled else { throw CanvasDocument.Failure.stale }
            try writeDocumentSource(next,binding:binding)
            if isDocumentSource, next == document { documentFileBinding = binding }
            else { try installDocument(next,binding:binding,preservingHistory:false) }
            documentFiles = files; documentFileReady = true; sceneReadable = true; fileWorkspaceState = .ready
            fileWorkspaceStatus = "전체 문서 Files 원본 저장·재열기 확인 완료"
        } catch { status = "전체 문서 원본 연결을 완료하지 않았습니다. \(error.localizedDescription)" }
    }
    func saveDocumentWorkspace() async {
        guard isDocumentSource, documentInputsClear, !documentBusy, !fileSaveBusy, !inkBusy,
              let files = documentFiles, let prior = documentFileBinding else { return }
        do {
            let owner = try document.pageSnapshot(), next = document, request = UUID()
            documentRequest = request; documentRequestPresentationEpoch = documentPresentationEpoch; documentBusy = true
            defer { if documentRequest == request { documentBusy = false } }
            let binding = try await savedDocument(next,files:files,bookmark:prior.bookmark,expected:prior.token,owner:owner)
            guard documentRequest == request, document.accepts(owner) else { throw CanvasDocument.Failure.stale }
            try writeDocumentSource(next,binding:binding)
            documentFileBinding = binding; documentFileReady = true; fileWorkspaceState = .ready
            fileWorkspaceStatus = "전체 문서 Files 원본 저장·재열기 확인 완료"
        } catch { documentFileReady = false; fileWorkspaceState = .blocked; fileWorkspaceStatus = "전체 문서 미저장·동기화 대기: \(error.localizedDescription)" }
    }
    func refreshDocumentWorkspace() {
        guard isDocumentSource, !documentBusy, !inkBusy, !vaultDirty, !vaultSaving,
              let files = documentFiles, let binding = documentFileBinding else { return }
        do {
            let latest = try files.load(document.id)
            guard !latest.publicationPending else { throw CanvasDocumentFiles.Failure.pending }
            guard latest.token != binding.token else { return }
            try documentBarrierCheck(checkFiles:false,recoveringFiles:true)
            guard try CanvasPacket.sha(document.bytes()) == binding.savedSHA else { throw CanvasDocumentFiles.Failure.conflict }
            let changed = DocumentFileBinding(bookmark:binding.bookmark,id:latest.document.id,token:latest.token,savedSHA:CanvasPacket.sha(try latest.document.bytes()))
            try writeDocumentSource(latest.document,binding:changed)
            try installDocument(latest.document,binding:changed,preservingHistory:false)
            documentFileReady = true; sceneReadable = true; sceneRecoveryNotice = ""; fileWorkspaceState = .ready
            fileWorkspaceStatus = "전체 문서 Files 외부 변경을 재열었습니다."
        } catch { documentFileReady = false; fileWorkspaceState = .blocked; status = error.localizedDescription }
    }
    func selectDocumentPage(_ id: UUID) async {
        await changeDocumentPage(id,duplicate:false)
    }
    func duplicateDocumentPage() async {
        await changeDocumentPage(scene.id,duplicate:true)
    }
    private func changeDocumentPage(_ id: UUID, duplicate: Bool) async {
        do {
            try documentBarrierCheck()
            guard isDocumentSource else { throw CanvasDocument.Failure.unsupported }
            let owner = try document.pageSnapshot(), request = UUID()
            documentRequest = request; documentRequestPresentationEpoch = documentPresentationEpoch; documentBusy = true
            defer { if documentRequest == request { documentBusy = false } }
            var next = document
            if duplicate { try next.duplicatePage(id,expectedRevision:next.revision) }
            else { try next.selectPage(id,expectedRevision:next.revision) }
            let binding: DocumentFileBinding?
            if let files = documentFiles, let prior = documentFileBinding {
                binding = try await savedDocument(next,files:files,bookmark:prior.bookmark,expected:prior.token,owner:owner)
            } else { binding = nil }
            guard documentRequest == request, document.accepts(owner) else { throw CanvasDocument.Failure.stale }
            try writeDocumentSource(next,binding:binding)
            try installDocument(next,binding:binding,preservingHistory:true)
            documentFileReady = binding != nil
            fileWorkspaceStatus = binding == nil ? "전체 문서 복구본 저장 · Files 원본 미저장" : "페이지 변경을 전체 문서 원본에 저장했습니다."
        } catch { status = "페이지를 바꾸지 않았습니다. \(error.localizedDescription)" }
        documentBusy = false
    }

    func returnToLegacySource() throws {
        guard isDocumentSource else { throw CanvasDocument.Failure.unsupported }
        try checkpointCurrentDocumentForReplacement()
        try documentBarrierCheck(checkFiles:false)
        try requireCurrentDocumentPreserved()
        guard isDocumentSource, let restored = try Self.restoreScene() else { throw CanvasDocumentFiles.Failure.pending }
        let previous = scene
        let marker = DocumentSourceState(schema:"ccr.canvas-document-source/v1",kind:.legacy,document:nil,binding:nil)
        try CanvasLocalFile.write(JSONEncoder().encode(marker),to:CanvasRuntime.stateURL(.documentSource))
        saveTask?.cancel(); documentRequest = UUID(); installingDocument = true; sourceKind = .legacy
        document = try CanvasDocument(legacy:restored.scene)
        inkHistory.activate(nativeHistoryOwner)
        storedDrawing = restored.drawing; documentFiles = nil; documentFileBinding = nil; documentFileReady = false
        sceneDidChange(from:previous)
        graphUndo = legacyGraphHistory?.undo; graphRedo = legacyGraphHistory?.redo
        graphRequiresPersistence = legacyGraphHistory?.persistence ?? false
        graphPersistenceEpoch = graphRequiresPersistence ? linkSceneGeneration : nil
        installingDocument = false; restoreFileWorkspace()
    }
    func documentWorkspaceDocuments(in folder: URL) throws -> [UUID] {
        guard documentOperationsEnabled else { throw CanvasDocument.Failure.unsupported }
        let access = folder.startAccessingSecurityScopedResource()
        guard access || !documentRequiresScope else { throw CanvasDocumentFiles.Failure.permission }
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL else { throw CanvasDocumentFiles.Failure.permission }
        let files = CanvasDocumentFiles(folder:folder,requiresScope:documentRequiresScope)
        return try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isSymbolicLinkKey])
            .filter { $0.pathExtension == "sill" }
            .map { url in
                guard try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == false,
                      let id = UUID(uuidString:url.deletingPathExtension().lastPathComponent),
                      url.lastPathComponent == id.uuidString.lowercased() + ".sill" else { throw CanvasDocumentFiles.Failure.unsupported }
                let loaded = try files.load(id)
                guard !loaded.publicationPending else { throw CanvasDocumentFiles.Failure.pending }
                return id
            }.sorted { $0.uuidString < $1.uuidString }
    }
    func importSourceBytes(_ bytes: Data) throws {
        guard bytes.count <= CanvasDocument.byteLimit,
              let root = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw CanvasDocument.Failure.invalid }
        if root["format"] != nil || root["pages"] != nil || root["version"] != nil {
            try checkpointCurrentDocumentForReplacement()
            try documentBarrierCheck(checkFiles:false)
            let next = try CanvasDocument.decode(bytes)
            if isDocumentSource { try requireCurrentDocumentPreserved() }
            else { try persistScene() }
            // 다른 문서로 진입한다. 기존 Files 원본과 구 scene 캐시는 수정하지 않는다.
            try writeDocumentSource(next,binding:nil)
            try installDocument(next,binding:nil,preservingHistory:false)
            documentFiles = nil; documentFileReady = false
        } else {
            guard !isDocumentSource else { throw CanvasDocument.Failure.unsupported }
            try importScene(CanvasDocument.decodeLegacy(bytes).activePage)
        }
    }
    func sourceBytes() throws -> Data {
        if isDocumentSource { return try document.bytes() }
        try scene.validateNativeInkProjection(); return try JSONEncoder().encode(scene)
    }
    private struct RecoveryKey: Hashable {
        let note: Bool
        let sceneID: UUID
        let address: String
        let recoveryID: String
        let backup: String
        let sha: String
    }
    private struct RecoveryDescriptor { let key: RecoveryKey; let closed: Bool }
    private func checkDocumentRecoveryJournals() throws {
        let folder = try CanvasRuntime.conflictRecoveryURL("CanvasConflictChoice.json").deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath:folder.path) else { return }
        let entries = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isSymbolicLinkKey])
        var descriptors: [RecoveryDescriptor] = [], locals: Set<String> = []
        for entry in entries {
            guard try entry.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw VaultBlockRecoveryError.corrupt }
            let name = entry.lastPathComponent
            let url = try CanvasRuntime.conflictRecoveryURL(name)
            if name.hasPrefix("CanvasConflictLocal-") || name.hasPrefix("NoteConflictLocal-") { locals.insert(name); continue }
            let bytes = try CanvasLocalFile.read(url)
            guard bytes.count <= 65*1024*1024 else { throw VaultBlockRecoveryError.corrupt }
            if name == "CanvasConflictChoice.json" || name.hasPrefix("CanvasConflictAttempt-") {
                guard let raw = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                      Set(raw.keys).isSubset(of:["address","localSHA","backupFilename","conflict","decision","disposition"]) else { throw VaultBlockRecoveryError.corrupt }
                let record = try JSONDecoder().decode(CanvasConflictChoice.self,from:bytes)
                _ = try record.conflict.validated(id:record.conflict.id)
                let backup = try CanvasRuntime.conflictRecoveryURL(record.backupFilename)
                let original = try CanvasLocalFile.read(backup)
                guard record.backupFilename.hasPrefix("CanvasConflictLocal-"), CanvasPacket.sha(original) == record.localSHA,
                      try CanvasDocument.decodeLegacy(original).id == record.conflict.id else { throw VaultBlockRecoveryError.corrupt }
                let key = RecoveryKey(note:false,sceneID:record.conflict.id,address:record.address,recoveryID:record.conflict.recoveryID.uuidString,backup:record.backupFilename,sha:record.localSHA)
                descriptors.append(.init(key:key,closed:record.disposition == .resolved || record.disposition == .superseded))
            } else if name == "NoteConflictChoice.json" || name.hasPrefix("NoteConflictAttempt-") {
                if let choice = try? JSONDecoder().decode(VaultPDFViewChoice.self,from:bytes).validated() {
                    guard choice.closed else { throw VaultBlockRecoveryError.publicationConflict }; continue
                }
                let record = try JSONDecoder().decode(NoteConflictLocalChoice.self,from:bytes).validated()
                let snapshot = try JSONDecoder().decode(CanvasRelay.NoteConflict.self,from:record.snapshot).validated(path:record.path)
                let backup = try CanvasLocalFile.read(CanvasRuntime.conflictRecoveryURL(record.backupFilename))
                let saved = try JSONDecoder().decode(NoteConflictLocalState.self,from:backup)
                guard CanvasPacket.sha(backup) == record.backupSHA256, saved.sceneID == record.sceneID,
                      saved.address == record.address, saved.path == record.path else { throw VaultBlockRecoveryError.corrupt }
                let key = RecoveryKey(note:true,sceneID:record.sceneID,address:record.address,recoveryID:snapshot.recoveryID.uuidString,backup:record.backupFilename,sha:record.backupSHA256)
                descriptors.append(.init(key:key,closed:record.phase == .completed || record.phase == .superseded))
            } else { throw VaultBlockRecoveryError.corrupt }
        }
        let closed = Set(descriptors.filter(\.closed).map(\.key))
        guard descriptors.allSatisfy({ $0.closed || closed.contains($0.key) }),
              locals.isSubset(of:Set(descriptors.filter { $0.closed || closed.contains($0.key) }.map { $0.key.backup })) else { throw VaultBlockRecoveryError.changed }
    }

}
