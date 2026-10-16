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
        didSet { scheduleSave() }
    }
    @Published var mode: CanvasMode = .pen
    @Published var selectedNode: UUID?
    @Published var status = "Pencil로 그린 뒤 구조를 확인하세요."
    @Published var proposalText = ""
    @Published var proposedNode: UUID?
    @Published var displayedVoice: VoiceSession?
    @Published private(set) var outbox = CanvasOutbox()
    @Published var sendBusy = false
    private var outboxReadable = true
    @Published var packet: PacketReceipt?
    @Published var viewport = CanvasViewport()
    var zoom: Double { viewport.zoom }
    var pan: CGSize { viewport.pan }
    var drawing = PKDrawing()
    var linkStart: UUID?
    private var saveTask: Task<Void,Never>?

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
            status = "현재 대화 턴에 그림 전달 확인 · 턴 ID \(accepted.turnId.map { String($0.uuidString.prefix(8)) } ?? "미확인")"
        case .started:
            status = "선택한 대화에서 새 턴 시작 확인 · 턴 ID \(accepted.turnId.map { String($0.uuidString.prefix(8)) } ?? "미확인")"
        case .queued:
            let continuity = accepted.sessionContinuity.status == "observed-same" ?
                "음성 세션 전후 동일 관측" : "음성 세션 연속성 미확인"
            status = "정확한 대화 대기열 접수 확인 · \(continuity) · 세션 내 전달 보장 아님"
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
              data.count <= 4*1024*1024,
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
        do { try CanvasLocalFile.write(data,to:url) }
        catch { status = "칠판 자동 저장 실패: \(error.localizedDescription)" }
    }

    func updateDrawing(_ next: PKDrawing) {
        guard drawing != next else { return }
        drawing = next
        var changed = scene
        changed.drawingBase64 = next.dataRepresentation().base64EncodedString()
        changed.strokes = next.strokes.map { stroke in
            InkStroke(id: stroke.id,
                points: stroke.path.map { point in
                    InkPoint(x: Double(point.location.x), y: Double(point.location.y),
                             pressure: Double(point.force))
                }, createdAt: stroke.path.creationDate)
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

    func proposeHandwriting() async {
        guard !drawing.strokes.isEmpty else { status = "인식할 획이 없습니다."; return }
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(drawing)
        guard let text = await recognizer.recognizedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { status = "글자 후보를 찾지 못했습니다. 원본 획은 유지했습니다."; return }
        let bounds = drawing.bounds
        let id = scene.addNode(kind: .note,
            at: CanvasPoint(x: Double(bounds.midX), y: Double(bounds.midY)),
            text: text, confidence: .proposal,
            sourceStrokeIds: drawing.strokes.map(\.id))
        proposedNode = id
        proposalText = text
        mode = .select
        status = "글자 후보입니다. 수정한 뒤 확인하면 구조 데이터에 확정됩니다."
    }

    func confirmProposal() {
        guard let proposedNode else { return }
        _ = scene.confirmNode(proposedNode, text: proposalText.trimmingCharacters(in: .whitespacesAndNewlines))
        self.proposedNode = nil
        status = "수정한 글자를 확정했습니다. 원본 획 출처는 남겼습니다."
    }

    func importScene(_ imported: CanvasScene) throws {
        guard imported.schemaVersion == 1, imported.width > 0, imported.height > 0,
              imported.nodes.count < 1000, imported.strokes.count < 10000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let next = try PKDrawing(data: Data(base64Encoded: imported.drawingBase64) ?? Data())
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
