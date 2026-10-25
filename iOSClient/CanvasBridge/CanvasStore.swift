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
            linkSceneGeneration &+= 1
            nodeResizeDrag = nil
            nodeRotationDrag = nil
            let visible = scene.visibility.nodeIDs
            if oldValue.id != scene.id || selectedLink.map({ !scene.visibility.linkIDs.contains($0) }) == true {
                clearLinkSelection()
            }
            if oldValue.id != scene.id || linkStart.map({ !visible.contains($0) }) == true {
                clearPendingLink()
            }
            if selectedNode.map({ !visible.contains($0) }) == true { selectedNode = nil }
            if proposedNode.map({ !visible.contains($0) }) == true { proposedNode = nil }
            if oldValue.id != scene.id { setInkSelection([]); invalidateNoteScene(); inkHistory.invalidate() }
            else if let context = noteContext, !noteContextIsCurrent(context) { invalidateNoteRequests() }
            handwritingRequest = nil
            scheduleSave()
        }
    }
    @Published var mode: CanvasMode = .pen {
        didSet {
            if oldValue != mode {
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
            if pencilTraceOwner == nil || pencilTraceOwner == owner { pencilTraceOwner = owner }
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
    @Published private(set) var inkSelection: Set<UUID> = []
    static let eraserStyleKey = "canvasEraserStyle"
    static let eraserSizeKey = "canvasPartialEraserWidth"
    private let eraserDefaults: UserDefaults
    @Published var eraserStyle: CanvasEraserStyle = .partial {
        didSet { eraserDefaults.set(eraserStyle.rawValue, forKey: Self.eraserStyleKey) }
    }
    @Published var eraserSize: CanvasEraserSize = .standard {
        didSet { eraserDefaults.set(eraserSize.rawValue, forKey: Self.eraserSizeKey) }
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
            if selectedNode.map({ !scene.visibility.nodeIDs.contains($0) }) == true { selectedNode = nil }
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

    private func recordGraphEdit(before: CanvasScene) {
        graphUndo = (before,scene)
        graphRedo = nil
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
        mode == .select && selectedNode == drag.expected.id &&
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
        mode == .select && selectedNode == drag.expected.id &&
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
        guard let undo = graphUndo, scene.id == undo.after.id else { return false }
        return scene.hasSameGraph(as:undo.after)
    }

    func undoGraphEdit() {
        guard canUndoGraph, let undo = graphUndo else {
            status = "구조가 바뀌어 이전 수정으로 되돌릴 수 없습니다. 최신 내용을 유지합니다."
            return
        }
        var next = scene
        next.nodes = undo.before.nodes
        next.links = undo.before.links
        next.annotations = undo.before.annotations
        next.revision += 1
        scene = next
        graphUndo = nil
        graphRedo = undo
        status = "구조 수정을 되돌렸습니다. 현재 원본 획은 그대로 보존했습니다."
    }

    var canRedoGraph: Bool {
        guard let redo = graphRedo, scene.id == redo.before.id else { return false }
        return scene.hasSameGraph(as:redo.before)
    }

    func redoGraphEdit() {
        guard canRedoGraph, let redo = graphRedo else {
            status = "구조가 바뀌어 다시 실행하지 않았습니다. 최신 내용을 유지합니다."
            return
        }
        var next = scene
        next.nodes = redo.after.nodes
        next.links = redo.after.links
        next.annotations = redo.after.annotations
        next.revision += 1
        scene = next
        graphUndo = redo
        graphRedo = nil
        status = "구조 수정을 다시 실행했습니다. 현재 원본 획은 그대로 보존했습니다."
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
        guard mode == .select, scene.visibility.linkIDs.contains(id),
              let link = scene.links.first(where:{ $0.id == id }), scene.linkEndpoints(link) != nil else { return }
        selectedNode = nil
        clearPendingLink()
        endpointDrag = nil
        selectedLink = id
        status = "연결선을 선택했습니다. 시작점이나 끝점을 끌어 연결 위치를 바꾸세요."
    }

    private func endpointDragIsCurrent(_ drag: EndpointDrag) -> Bool {
        mode == .select && selectedLink == drag.expected.id && drag.generation == linkSceneGeneration &&
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
        didSet { if !changingBlockState { persistBlockDraft() } }
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
        vaultBlockEditing && (pendingBlockEdit != nil || vaultBlockTextChanged) &&
        !vaultInputBusy && !vaultSaving && !vaultLoading && noteContext.map(noteContextIsCurrent) == true
    }
    var vaultBlockHasPendingSave: Bool { pendingBlockEdit != nil }
    var vaultCanSave: Bool {
        noteRecoveryReadable && !noteRecoveryWriteFailed && !vaultBlockEditing && vaultNote != nil && vaultDirty && !vaultInputBusy && !vaultSaving && !vaultLoading && !vaultBlocked &&
        noteContext.map(noteContextIsCurrent) == true
    }
    var vaultCanAttach: Bool {
        !vaultBlockEditing && vaultNote != nil && !vaultDirty && !vaultInputBusy && !vaultSaving && !vaultLoading && !vaultBlocked &&
        noteContext.map(noteContextIsCurrent) == true
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
            return card.ready ? "저장된 원문으로 앞면과 뒷면을 복습합니다. 평가는 자체 24시간 규칙입니다." :
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
        guard vaultReviewIsCurrent(session) else {
            vaultStatus = VaultReviewError.changed.localizedDescription
            return false
        }
        do {
            let submitted = try session.card.ratingGood(eventID:session.id,injectedDate:injectedDate)
            vaultDraft = submitted
            await saveVaultNote(save:save,load:load)
            guard !Task.isCancelled, vaultInputSessionID == session.inputSessionID,
                  vaultSelection == session.selection, selectedNode == session.selectedNode,
                  noteSelectionGeneration == session.selectionGeneration,
                  vaultNote?.text.utf8.elementsEqual(submitted.utf8) == true,
                  vaultDraft.utf8.elementsEqual(submitted.utf8), vaultCanAttach,
                  !noteRecoveryWriteFailed, noteRecovery == nil else { return false }
            vaultStatus = "평가와 24시간 뒤 기한을 원본에 저장하고 다시 읽어 확인했습니다."
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
        return true
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
        guard noteRecoveryReadable, noteRecovery == nil else {
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
    private func persistNoteDraft(submittedText: String? = nil, draft: String? = nil) -> Bool {
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
            if draft.utf8.elementsEqual(base.text.utf8), submitted == nil {
                if noteRecovery != nil || noteRecoveryAttemptedBytes != nil { try writeNoteRecovery(nil) }
                noteRecoveryWriteFailed = false
                return true
            }
            if noteRecovery == nil {
                try persistScene()
            }
            try writeNoteRecovery(VaultNoteRecovery(schemaVersion:1,sceneID:context.sceneID,
                nodeID:context.nodeID,blockID:context.blockID,relayAddress:noteAddress,
                base:base,draft:draft,submittedText:submitted))
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
        guard let record = noteRecovery, noteRecoveryReadable, !vaultDirty, !vaultBlockEditing,
              !vaultSaving, !vaultLoading, !vaultInputBusy, !noteToken.isEmpty else { return }
        do {
            _ = try record.validated()
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
        guard !vaultSaving, !vaultLoading, !vaultDirty, !vaultInputBusy else { return false }
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
            guard noteRecoveryReadable, noteRecovery == nil else { throw VaultBlockRecoveryError.context }
            guard blockRecoveryReadable, let record = blockRecovery else { throw VaultBlockRecoveryError.corrupt }
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
            let reason = failure.domain == "CanvasRelay" && failure.code == 409 ?
                "원문 변경 또는 작업 결과 불일치" : "통신 또는 원문 검증 실패"
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
                persistNoteDraft()
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
            persistNoteDraft()
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

    init(blockRecoveryURL: URL? = nil, noteRecoveryURL: URL? = nil,
         defaults: UserDefaults = .standard,
         noteRecoveryWrite: @escaping (Data,URL) throws -> Void = CanvasLocalFile.write) {
        self.eraserDefaults = defaults
        _eraserStyle = Published(initialValue: defaults.string(forKey: Self.eraserStyleKey)
            .flatMap(CanvasEraserStyle.init(rawValue:)) ?? .partial)
        _eraserSize = Published(initialValue: (defaults.object(forKey: Self.eraserSizeKey) as? NSNumber)
            .flatMap { CanvasEraserSize(rawValue: $0.doubleValue) } ?? .standard)
        self.noteRecoveryWrite = noteRecoveryWrite
        self.blockRecoveryOverride = blockRecoveryURL
        self.noteRecoveryOverride = noteRecoveryURL ?? blockRecoveryURL.map {
            $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + ".note")
        }
        #if DEBUG
        if case .invalid = CanvasRuntime.launch {
            outboxReadable = false
            blockRecoveryReadable = false
            noteRecoveryReadable = false
            status = CanvasRuntime.TestError.invalid.localizedDescription
            return
        }
        #endif
        do {
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
        do { try persistScene() }
        catch { status = "칠판 자동 저장 실패: \(error.localizedDescription)" }
    }

    private func persistScene(_ candidate: CanvasScene? = nil) throws {
        guard sceneReadable else { throw ScenePersistenceError.unreadable }
        guard let url = Self.sceneURL() else { throw ScenePersistenceError.unreadable }
        let candidate = candidate ?? scene
        try candidate.validateNativeInkProjection()
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= Self.sceneByteLimit else { throw ScenePersistenceError.tooLarge }
        try CanvasLocalFile.write(data,to:url)
    }

    private static let sceneByteLimit = CanvasScene.localByteLimit


    @discardableResult
    func updateDrawing(_ next: PKDrawing) -> Bool {
        guard drawing != next else { return true }
        let nativeBytes = next.dataRepresentation()
        guard let authoritative = try? PKDrawing(data: nativeBytes) else {
            status = "unreadable_drawing · 원본 그림을 읽을 수 없어 기존 원본을 유지합니다."
            return false
        }
        var changed = scene
        changed.schemaVersion = 2
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
        let visible = scene.visibility.nodeIDs
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
        clearPendingLink()
        guard let selectedNode, scene.visibility.nodeIDs.contains(selectedNode),
              scene.toggleChildren(of: selectedNode) else { return }
        let collapsed = scene.nodes.first { $0.id == selectedNode }?.isCollapsed == true
        status = collapsed ? "하위 요소를 접었습니다. 원본 데이터는 보존됩니다." : "하위 요소를 펼쳤습니다."
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
        guard let selectedNode, scene.visibility.nodeIDs.contains(selectedNode) else { return }
        scene.moveNode(selectedNode, to: CanvasPoint(x: Double(point.x), y: Double(point.y)))
    }

    func setInkSelection(_ ids: Set<UUID>) {
        let next = ids.intersection(drawing.strokes.map(\.id))
        guard next != inkSelection else { return }
        inkSelection = next
        handwritingRequest = nil
    }

    func proposeHandwriting(selectedOnly: Bool = false, recognize: (PKDrawing) async -> String? = { drawing in
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(drawing)
        return await recognizer.recognizedText()
    }) async {
        let request = UUID()
        handwritingRequest = request
        let sourceDrawing = selectedOnly ? PKDrawing(strokes:drawing.strokes.filter { inkSelection.contains($0.id) }) : drawing
        guard !sourceDrawing.strokes.isEmpty else {
            handwritingRequest = nil
            status = selectedOnly ? "영역 선택 도구로 인식할 글자를 먼저 선택하세요." : "인식할 획이 없습니다."
            return
        }
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
        let request = UUID()
        handwritingRequest = request
        let matches = await search(source, query)
        guard handwritingRequest == request else { return }
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
        guard !vaultDirty, !vaultSaving else { throw CocoaError(.userCancelled) }
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

    @discardableResult
    func applyAgentRevision(_ revision: AgentRevision) -> Bool {
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
}
