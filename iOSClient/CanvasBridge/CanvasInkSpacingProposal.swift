import Foundation
import PencilKit
import SwiftUI

@MainActor
final class CanvasInkSpacingProposal: ObservableObject {
    enum Action: String, CaseIterable { case split = "나누기", join = "합치기" }
    enum Refusal: String, LocalizedError {
        case unsupported, ambiguous, shared, masked, orientation, amount, identity, stale
        var errorDescription: String? {
            switch self {
            case .unsupported: return "두 문자·단어와 원본 획의 대응을 확인하지 못했습니다. 원본은 유지합니다."
            case .ambiguous: return "두 그룹의 검색 대응이 유일하지 않거나 획을 공유합니다. 원본은 유지합니다."
            case .shared: return "다른 요소가 이동할 획을 참조합니다. 함께 바꾸지 않고 원본을 유지합니다."
            case .masked: return "부분 지워진 그룹의 간격 편집은 지원하지 않습니다. 원본 마스크를 유지합니다."
            case .orientation: return "회전·기울기·여러 줄 또는 겹친 그룹의 간격은 확정할 수 없습니다."
            case .amount: return "1~512포인트의 정수를 입력하세요. 소수 간격은 지원하지 않습니다. 합치기 값은 확인한 두 그룹 사이의 빈 간격보다 작아야 합니다."
            case .identity: return "변환 뒤 획 식별자·필압·원본 계약을 보존하지 못해 적용하지 않았습니다."
            case .stale: return "장면·선택·문자가 바뀌었거나 제안이 취소됐습니다. 원본을 유지합니다."
            }
        }
    }
    struct Proposal: Identifiable {
        let id: UUID
        let snapshot: CanvasInkTextEditing.Snapshot
        let leftIDs: Set<UUID>
        let rightIDs: Set<UUID>
        let delta: Double
        let before: CanvasScene
        let after: CanvasScene
    }
    enum Phase {
        case idle, reading, refused(String)
        case preview(Proposal)
        case applied(CanvasInkTextEditing.History), undone(CanvasInkTextEditing.History)
    }
    @Published private(set) var phase: Phase = .idle
    private var request: UUID?
    var proposal: Proposal? { if case .preview(let p) = phase { return p }; return nil }
    var hasPendingWork: Bool { switch phase { case .reading,.preview: return true; default: return false } }
    var canUndo: Bool { if case .applied = phase { return true }; return false }
    var canRedo: Bool { if case .undone = phase { return true }; return false }
    func cancel() { request = nil; phase = .idle }
    func invalidatePending() { if hasPendingWork { cancel() } }

    func propose(scene: CanvasScene, nodeID: UUID, selection: Set<UUID>, left: String, right: String,
                 action: Action, amount: Double, isCurrent: (CanvasInkTextEditing.Snapshot) -> Bool,
                 readEvidence: CanvasInkTextEditing.ReadEvidence = CanvasInkTextEditing.nativeEvidence) async {
        let token = UUID(); request = token; phase = .reading
        do {
            guard amount.isFinite, (1...512).contains(amount), amount.rounded() == amount else { throw Refusal.amount }
            guard let node = scene.nodes.first(where:{ $0.id == nodeID }), node.kind == .note, node.vaultNote == nil,
                  !left.isEmpty, !right.isEmpty, left.count <= 32, right.count <= 32,
                  !left.contains(where: \.isWhitespace), !right.contains(where: \.isWhitespace),
                  !left.utf8.elementsEqual(right.utf8), !selection.isEmpty,
                  Set(node.sourceStrokeIds).count == node.sourceStrokeIds.count,
                  selection == Set(node.sourceStrokeIds), scene.revision >= 0, scene.revision < Int.max else { throw Refusal.unsupported }
            let expectedText = action == .split ? left + right : left + " " + right
            guard node.text.utf8.elementsEqual(expectedText.utf8) else { throw Refusal.unsupported }
            guard (node.rotationDegrees ?? 0) == 0 else { throw Refusal.orientation }
            try scene.validateNativeInkProjection()
            guard let bytes = Data(base64Encoded:scene.drawingBase64), !bytes.isEmpty else { throw Refusal.unsupported }
            let drawing = try PKDrawing(data:bytes)
            guard Set(drawing.strokes.map(\.id)).count == drawing.strokes.count,
                  selection.isSubset(of:Set(drawing.strokes.map(\.id))),
                  scene.strokes == CanvasScene.nativeInkStrokes(drawing) else { throw Refusal.unsupported }
            let snapshot = CanvasInkTextEditing.Snapshot(sceneID:scene.id,revision:scene.revision,
                sceneSHA256:CanvasPacket.sha(try CanvasInkTextEditing.encode(scene)),drawingSHA256:CanvasPacket.sha(bytes),
                nodeID:nodeID,selectedStrokeIDs:selection,text:node.text,utf16Location:left.utf16.count,utf16Length:action == .join ? 1 : 0)
            let leftEvidence = await readEvidence(drawing,selection,left,[right])
            guard request == token else { return }
            guard !Task.isCancelled else { throw Refusal.stale }
            guard isCurrent(snapshot) else { throw Refusal.stale }
            let rightEvidence = await readEvidence(drawing,selection,right,[left])
            guard request == token else { return }
            guard !Task.isCancelled else { throw Refusal.stale }
            guard isCurrent(snapshot) else { throw Refusal.stale }
            func group(_ evidence: CanvasInkTextEditing.Evidence, target: String, rest: String) throws -> Set<UUID> {
                guard evidence.wholeText?.utf8.elementsEqual(node.text.utf8) == true,
                      evidence.targetText?.utf8.elementsEqual(target.utf8) == true,
                      evidence.remainingText?.utf8.elementsEqual(rest.utf8) == true,
                      evidence.matches.count == 1, let ids = evidence.matches.first, !ids.isEmpty,
                      ids.isSubset(of:selection) else { throw Refusal.ambiguous }
                return ids
            }
            let leftIDs = try group(leftEvidence,target:left,rest:right)
            let rightIDs = try group(rightEvidence,target:right,rest:left)
            guard leftIDs.isDisjoint(with:rightIDs), leftIDs.union(rightIDs) == selection,
                  leftEvidence.otherCharacterMatches == [[rightIDs]], rightEvidence.otherCharacterMatches == [[leftIDs]] else { throw Refusal.ambiguous }
            let selected = drawing.strokes.filter { selection.contains($0.id) }
            guard selected.allSatisfy({ $0.mask == nil }) else { throw Refusal.masked }
            guard !scene.nodes.contains(where:{ $0.id != nodeID && !selection.isDisjoint(with:$0.sourceStrokeIds) }) else { throw Refusal.shared }
            guard selected.allSatisfy({ stroke in
                let t = stroke.transform
                return [t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy(\.isFinite) && t.a > 0 && t.d > 0 &&
                    abs(t.b) < 0.000001 && abs(t.c) < 0.000001 && abs(t.a-t.d) < 0.000001
            }) else { throw Refusal.orientation }
            let l = PKDrawing(strokes:drawing.strokes.filter { leftIDs.contains($0.id) }).bounds
            let r = PKDrawing(strokes:drawing.strokes.filter { rightIDs.contains($0.id) }).bounds
            guard !l.isEmpty, !r.isEmpty, !l.isNull, !r.isNull,
                  [l.minX,l.minY,l.maxX,l.maxY,r.minX,r.minY,r.maxX,r.maxY].allSatisfy(\.isFinite),
                  l.maxX < r.minX,
                  min(l.maxY,r.maxY)-max(l.minY,r.minY) >= min(l.height,r.height)*0.6,
                  abs(l.midY-r.midY) <= max(l.height,r.height)*0.25 else { throw Refusal.orientation }
            if action == .join { guard amount < Double(r.minX-l.maxX) else { throw Refusal.amount } }
            let delta = action == .split ? amount : -amount
            let moved = PKDrawing(strokes:drawing.strokes.map { original -> PKStroke in
                guard rightIDs.contains(original.id) else { return original }
                var stroke = original
                stroke.transform = original.transform.concatenating(CGAffineTransform(translationX:delta,y:0))
                return stroke
            })
            let afterBytes = moved.dataRepresentation(), authoritative = try PKDrawing(data:afterBytes)
            guard authoritative.strokes.map(\.id) == drawing.strokes.map(\.id) else { throw Refusal.identity }
            for (before,after) in zip(drawing.strokes,authoritative.strokes) {
                if rightIDs.contains(before.id) {
                    guard before.path.count == after.path.count, before.ink.inkType == after.ink.inkType, before.ink.color.isEqual(after.ink.color),
                          before.randomSeed == after.randomSeed, before.renderGroupID == after.renderGroupID, before.renderState == after.renderState, after.mask == nil,
                          after.transform == before.transform.concatenating(CGAffineTransform(translationX:delta,y:0)),
                          zip(before.path,after.path).allSatisfy({ a,b in
                              a.location == b.location && a.force == b.force && a.timeOffset == b.timeOffset &&
                              a.size == b.size && a.opacity == b.opacity && a.azimuth == b.azimuth && a.altitude == b.altitude
                          }) else { throw Refusal.identity }
                } else {
                    guard CanvasScene.nativeInkStrokes(PKDrawing(strokes:[before])) ==
                        CanvasScene.nativeInkStrokes(PKDrawing(strokes:[after])) else { throw Refusal.identity }
                }
            }
            var after = scene
            after.schemaVersion = max(2,after.schemaVersion)
            after.drawingBase64 = afterBytes.base64EncodedString()
            after.strokes = CanvasScene.nativeInkStrokes(authoritative)
            after.nodes[after.nodes.firstIndex(where:{ $0.id == nodeID })!].text = action == .split ? left + " " + right : left + right
            after.revision += 1
            try after.validateNativeInkProjection()
            guard try CanvasInkTextEditing.encode(after).count <= CanvasScene.localByteLimit else { throw Refusal.unsupported }
            phase = .preview(.init(id:token,snapshot:snapshot,leftIDs:leftIDs,rightIDs:rightIDs,delta:delta,before:scene,after:after))
            request = nil
        } catch {
            guard request == token else { return }
            request = nil; phase = .refused(error.localizedDescription)
        }
    }
    func confirm(current: CanvasScene, selection: Set<UUID>, persist: (CanvasScene) throws -> Void) throws -> CanvasScene {
        guard case .preview(let p) = phase, p.snapshot.matches(scene:current,selection:selection) else { throw Refusal.stale }
        try persist(p.after)
        phase = .applied(.init(before:p.before,after:p.after,expected:p.after));return p.after
    }
    func undo(current: CanvasScene, persist: (CanvasScene) throws -> Void) throws -> CanvasScene {
        guard case .applied(var h) = phase else { throw Refusal.stale }
        let next = try restore(h.before,expected:h.expected,current:current,persist:persist)
        h.expected = next;phase = .undone(h);return next
    }
    func redo(current: CanvasScene, persist: (CanvasScene) throws -> Void) throws -> CanvasScene {
        guard case .undone(var h) = phase else { throw Refusal.stale }
        let next = try restore(h.after,expected:h.expected,current:current,persist:persist)
        h.expected = next;phase = .applied(h);return next
    }
    private func restore(_ target: CanvasScene, expected: CanvasScene, current: CanvasScene,
                         persist: (CanvasScene) throws -> Void) throws -> CanvasScene {
        guard current.revision < Int.max, try CanvasInkTextEditing.encode(current) == CanvasInkTextEditing.encode(expected) else { throw Refusal.stale }
        var next = target;next.revision = current.revision+1
        try persist(next);return next
    }
}

struct CanvasInkSpacingSheet: View {
    @ObservedObject var editing: CanvasInkSpacingProposal
    let text: String
    let propose: (String,String,CanvasInkSpacingProposal.Action,Double) -> Void
    let confirm: () -> Void
    let cancel: () -> Void
    @State private var left = ""
    @State private var right = ""
    @State private var amount = ""
    @State private var action = CanvasInkSpacingProposal.Action.split
    private var requestedAmount: Double? {
        guard let value = Double(amount), value.isFinite, (1...512).contains(value), value.rounded() == value else { return nil }
        return value
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("원본 획 간격 합치기·나누기").font(.headline)
                Text("현재 문구: \(text)")
                Text("원본 필기 인식이 두 그룹을 확인하지 못하면 적용하지 않습니다. 정수 1~512포인트만 지원합니다.").font(.caption)
                if let p = editing.proposal {
                    Text("오른쪽의 대응 획 \(p.rightIDs.count)개를 \(p.delta)포인트 이동합니다. 원본은 확인 후에만 저장합니다.")
                    image(p.before,bounds:p.before,after:p.after,label:"변경 전 원본 잉크")
                    image(p.after,bounds:p.before,after:p.after,label:"변경 후 간격 후보")
                    Button("원본 획 간격 확정",action:confirm).accessibilityIdentifier("inkSpacingConfirm")
                } else {
                    Text("전체 선택 문구를 이루는 두 그룹을 입력하세요. 문자 검색 대응이 유일할 때만 제안하며, 좌표만으로 글자를 판정하지 않습니다.")
                    TextField("왼쪽 글자 또는 단어",text:$left)
                    TextField("오른쪽 글자 또는 단어",text:$right)
                    TextField("이동 또는 줄일 간격 · 정수 1~512포인트",text:$amount)
                    Text("소수 간격은 지원하지 않습니다.").font(.caption)
                    Picker("편집",selection:$action) { ForEach(CanvasInkSpacingProposal.Action.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    if case .reading = editing.phase { ProgressView("원본 필기와 획을 대조합니다.") }
                    if case .refused(let reason) = editing.phase { Text(reason).foregroundStyle(.orange) }
                    Button("원본 간격 미리보기") { if let value = requestedAmount { propose(left,right,action,value) } }
                        .disabled(editing.hasPendingWork || requestedAmount == nil)
                }
                Button("취소",action:cancel)
            }.padding().buttonStyle(.bordered).frame(minHeight:44)
        }
    }
    @ViewBuilder private func image(_ scene: CanvasScene,bounds source: CanvasScene,after candidate: CanvasScene,label: String) -> some View {
        if let data = Data(base64Encoded:scene.drawingBase64), let drawing = try? PKDrawing(data:data),
           let originalData = Data(base64Encoded:source.drawingBase64), let original = try? PKDrawing(data:originalData) {
            let candidateDrawing = Data(base64Encoded:candidate.drawingBase64).flatMap { try? PKDrawing(data:$0) }
            let bounds = original.bounds.union(candidateDrawing?.bounds ?? drawing.bounds).insetBy(dx:-12,dy:-12)
            if !bounds.isNull, !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite {
                #if os(macOS)
                Image(nsImage:drawing.image(from:bounds,scale:min(1,1024/max(bounds.width,bounds.height)))).resizable().scaledToFit().frame(maxHeight:180).accessibilityLabel(label)
                #else
                Image(uiImage:drawing.image(from:bounds,scale:min(1,1024/max(bounds.width,bounds.height)))).resizable().scaledToFit().frame(maxHeight:180).accessibilityLabel(label)
                #endif
            }
        }
    }
}
