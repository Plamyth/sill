import Foundation
import PencilKit
import SwiftUI

@MainActor
final class CanvasInkTextEditing: ObservableObject {
    enum Refusal: String, LocalizedError {
        case invalidRange, unsupported, repeatedCharacter, ambiguousStrokes, maskedTarget, sharedSource, stale, cancelled

        var errorDescription: String? {
            switch self {
            case .invalidRange: return "삭제할 한 글자의 전체 범위를 선택하세요. 원본은 유지했습니다."
            case .unsupported: return "문자와 원본 획의 대응을 확인하지 못했습니다. 원본을 유지하며 명시적인 획 선택이 필요합니다."
            case .repeatedCharacter: return "같은 글자가 반복되어 검색 획의 문자 위치를 확정할 수 없습니다. 원본은 유지했습니다."
            case .ambiguousStrokes: return "여러 글자가 획을 공유하거나 검색 결과가 모호합니다. 원본은 유지했습니다."
            case .maskedTarget: return "부분 지워진 대상 획의 문자 대응은 지원하지 않습니다. 원본 마스크를 유지했습니다."
            case .sharedSource: return "다른 요소도 이 획을 참조합니다. 함께 바꾸지 않고 원본을 유지했습니다."
            case .stale: return "장면·선택·문자가 바뀌었습니다. 오래된 삭제를 적용하지 않았습니다."
            case .cancelled: return "삭제 제안을 취소했습니다. 원본은 유지했습니다."
            }
        }
    }

    struct Snapshot: Codable, Equatable {
        let sceneID: UUID
        let revision: Int
        let sceneSHA256: String
        let drawingSHA256: String
        let nodeID: UUID
        let selectedStrokeIDs: Set<UUID>
        let text: String
        let utf16Location: Int
        let utf16Length: Int

        func matches(scene: CanvasScene, selection: Set<UUID>) -> Bool {
            guard scene.id == sceneID, scene.revision == revision,
                  selection == selectedStrokeIDs,
                  let bytes = Data(base64Encoded: scene.drawingBase64),
                  CanvasPacket.sha(bytes) == drawingSHA256,
                  let node = scene.nodes.first(where: { $0.id == nodeID }),
                  node.text.utf8.elementsEqual(text.utf8),
                  let encoded = try? CanvasInkTextEditing.encode(scene) else { return false }
            return CanvasPacket.sha(encoded) == sceneSHA256
        }
    }

    struct Evidence {
        let wholeText: String?
        let matches: [Set<UUID>]
        let targetText: String?
        let remainingText: String?
        let otherCharacterMatches: [[Set<UUID>]]
    }

    typealias ReadEvidence = (PKDrawing, Set<UUID>, String, [String]) async -> Evidence

    struct Proposal: Identifiable {
        let id: UUID
        let snapshot: Snapshot
        let removedStrokeIDs: Set<UUID>
        let removedText: String
        let remainingText: String
        let before: CanvasScene
        let after: CanvasScene
    }

    struct History {
        let before: CanvasScene
        let after: CanvasScene
        var expected: CanvasScene
    }

    enum Phase {
        case idle
        case reading
        case ambiguous(Refusal)
        case preview(Proposal)
        case applied(History)
        case undone(History)
    }

    @Published private(set) var phase: Phase = .idle
    private var request: UUID?

    var proposal: Proposal? {
        if case .preview(let proposal) = phase { return proposal }
        return nil
    }
    var canUndo: Bool { if case .applied = phase { return true }; return false }
    var canRedo: Bool { if case .undone = phase { return true }; return false }
    var hasPendingWork: Bool {
        switch phase { case .reading, .preview: return true; default: return false }
    }

    func invalidatePending() {
        if hasPendingWork { cancel() }
    }

    func cancel() {
        request = nil
        phase = .idle
    }

    func propose(scene: CanvasScene, nodeID: UUID, selection: Set<UUID>, range: NSRange,
                 isCurrent: (Snapshot) -> Bool,
                 readEvidence: ReadEvidence = CanvasInkTextEditing.nativeEvidence) async {
        let token = UUID()
        request = token
        phase = .reading
        do {
            guard scene.revision >= 0, scene.revision < Int.max,
                  let node = scene.nodes.first(where: { $0.id == nodeID }), node.kind == .note,
                  node.vaultNote == nil, !selection.isEmpty,
                  Set(node.sourceStrokeIds).count == node.sourceStrokeIds.count,
                  Set(node.sourceStrokeIds) == selection else { throw Refusal.unsupported }
            let (glyph, remaining) = try Self.deletingCharacter(in: node.text, range: range)
            guard node.text.filter({ String($0).utf8.elementsEqual(glyph.utf8) }).count == 1 else {
                throw Refusal.repeatedCharacter
            }
            try scene.validateNativeInkProjection()
            guard let bytes = Data(base64Encoded: scene.drawingBase64), !bytes.isEmpty else {
                throw Refusal.unsupported
            }
            let drawing = try PKDrawing(data: bytes)
            let allIDs = Set(drawing.strokes.map(\.id))
            guard allIDs.count == drawing.strokes.count, selection.isSubset(of: allIDs),
                  scene.strokes == CanvasScene.nativeInkStrokes(drawing) else { throw Refusal.unsupported }
            let snapshot = Snapshot(sceneID: scene.id, revision: scene.revision,
                sceneSHA256: CanvasPacket.sha(try Self.encode(scene)), drawingSHA256: CanvasPacket.sha(bytes),
                nodeID: nodeID, selectedStrokeIDs: selection, text: node.text,
                utf16Location: range.location, utf16Length: range.length)
            let others = Array(Set(remaining.filter { !$0.isWhitespace }.map(String.init))).sorted()
            let evidence = await readEvidence(drawing, selection, glyph, others)
            guard request == token else { return }
            guard !Task.isCancelled else { throw Refusal.cancelled }
            guard isCurrent(snapshot) else { throw Refusal.stale }
            let removed = try Self.verify(evidence, snapshot: snapshot, glyph: glyph,
                remaining: remaining, otherCharacterCount: others.count)
            guard !drawing.strokes.contains(where: { removed.contains($0.id) && $0.mask != nil }) else {
                throw Refusal.maskedTarget
            }
            guard !scene.nodes.contains(where: {
                $0.id != nodeID && !removed.isDisjoint(with: $0.sourceStrokeIds)
            }) else { throw Refusal.sharedSource }
            let kept = PKDrawing(strokes: drawing.strokes.filter { !removed.contains($0.id) })
            let afterBytes = kept.dataRepresentation()
            let authoritative = try PKDrawing(data: afterBytes)
            var after = scene
            after.schemaVersion = max(2, after.schemaVersion)
            after.drawingBase64 = afterBytes.base64EncodedString()
            after.strokes = CanvasScene.nativeInkStrokes(authoritative)
            let index = after.nodes.firstIndex(where: { $0.id == nodeID })!
            after.nodes[index].text = remaining
            after.nodes[index].sourceStrokeIds.removeAll(where: removed.contains)
            after.revision += 1
            try Self.validate(after)
            phase = .preview(.init(id: token, snapshot: snapshot, removedStrokeIDs: removed,
                removedText: glyph, remainingText: remaining, before: scene, after: after))
            request = nil
        } catch {
            guard request == token else { return }
            request = nil
            phase = .ambiguous(error as? Refusal ?? .unsupported)
        }
    }

    // SearchResult에는 문자 offset이 없다. 단일 검색 획·대상 재인식·잔여 인식을 모두 대조한다.
    static func nativeEvidence(_ drawing: PKDrawing, _ selection: Set<UUID>, _ glyph: String,
                               _ otherCharacters: [String]) async -> Evidence {
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(PKDrawing(strokes: drawing.strokes.filter { selection.contains($0.id) }))
        let whole = await recognizer.recognizedText(strokeIDs: selection)
        let matches = await recognizer.search(glyph, fullWordsOnly: false, caseMatchingOnly: true).map(\.strokes)
        guard matches.count == 1, let ids = matches.first, !ids.isEmpty, ids.isSubset(of: selection) else {
            return .init(wholeText: whole, matches: matches, targetText: nil,
                         remainingText: nil, otherCharacterMatches: [])
        }
        let target = await recognizer.recognizedText(strokeIDs: ids)
        let rest = selection.subtracting(ids)
        let remaining = rest.isEmpty ? "" : await recognizer.recognizedText(strokeIDs: rest)
        var otherMatches: [[Set<UUID>]] = []
        for character in otherCharacters {
            otherMatches.append(await recognizer.search(character, fullWordsOnly: false,
                                                         caseMatchingOnly: true).map(\.strokes))
        }
        return .init(wholeText: whole, matches: matches, targetText: target,
                     remainingText: remaining, otherCharacterMatches: otherMatches)
    }

    private static func verify(_ evidence: Evidence, snapshot: Snapshot, glyph: String,
                               remaining: String, otherCharacterCount: Int) throws -> Set<UUID> {
        guard evidence.wholeText?.utf8.elementsEqual(snapshot.text.utf8) == true else { throw Refusal.unsupported }
        guard evidence.matches.count == 1, let removed = evidence.matches.first,
              !removed.isEmpty, removed.isSubset(of: snapshot.selectedStrokeIDs) else { throw Refusal.ambiguousStrokes }
        guard evidence.targetText?.utf8.elementsEqual(glyph.utf8) == true,
              evidence.remainingText?.utf8.elementsEqual(remaining.utf8) == true,
              evidence.otherCharacterMatches.count == otherCharacterCount else { throw Refusal.ambiguousStrokes }
        for groups in evidence.otherCharacterMatches {
            guard !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty && $0.isSubset(of: snapshot.selectedStrokeIDs) &&
                $0.isDisjoint(with: removed) }) else { throw Refusal.ambiguousStrokes }
        }
        return removed
    }

    private static func deletingCharacter(in text: String, range: NSRange) throws -> (String, String) {
        guard range.location >= 0, range.length > 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location,
              let swiftRange = Range(range, in: text),
              text.indices.contains(swiftRange.lowerBound),
              swiftRange.upperBound == text.endIndex || text.indices.contains(swiftRange.upperBound),
              text[swiftRange].count == 1, !text[swiftRange].allSatisfy(\.isWhitespace) else {
            throw Refusal.invalidRange
        }
        var remaining = text
        remaining.removeSubrange(swiftRange)
        return (String(text[swiftRange]), remaining)
    }

    @discardableResult
    func confirm(current: CanvasScene, selection: Set<UUID>, persist: (CanvasScene) throws -> Void) throws -> CanvasScene {
        guard case .preview(let proposal) = phase,
              proposal.snapshot.matches(scene: current, selection: selection) else { throw Refusal.stale }
        try persist(proposal.after)
        phase = .applied(.init(before: proposal.before, after: proposal.after, expected: proposal.after))
        return proposal.after
    }

    @discardableResult
    func undo(current: CanvasScene, persist: (CanvasScene) throws -> Void) throws -> CanvasScene {
        guard case .applied(var history) = phase else { throw Refusal.stale }
        let restored = try Self.restore(history.before, expected: history.expected, current: current, persist: persist)
        history.expected = restored
        phase = .undone(history)
        return restored
    }

    @discardableResult
    func redo(current: CanvasScene, persist: (CanvasScene) throws -> Void) throws -> CanvasScene {
        guard case .undone(var history) = phase else { throw Refusal.stale }
        let restored = try Self.restore(history.after, expected: history.expected, current: current, persist: persist)
        history.expected = restored
        phase = .applied(history)
        return restored
    }

    private static func restore(_ target: CanvasScene, expected: CanvasScene, current: CanvasScene,
                                persist: (CanvasScene) throws -> Void) throws -> CanvasScene {
        guard current.revision < Int.max, try encode(current) == encode(expected) else { throw Refusal.stale }
        var next = target
        next.revision = current.revision + 1
        try validate(next)
        try persist(next)
        return next
    }

    nonisolated static func encode(_ scene: CanvasScene) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(scene)
    }

    private static func validate(_ scene: CanvasScene) throws {
        try scene.validateNativeInkProjection()
        guard try encode(scene).count <= CanvasScene.localByteLimit else { throw Refusal.unsupported }
    }
}

struct CanvasInkTextDeletePreview: View {
    let proposal: CanvasInkTextEditing.Proposal
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("한 글자 삭제 미리보기").font(.headline)
                Text("삭제할 글자: \(proposal.removedText)")
                Text("변경 전: \(proposal.snapshot.text)")
                Text("변경 후: \(proposal.remainingText)")
                Text("대응이 확인된 획 \(proposal.removedStrokeIDs.count)개를 삭제합니다. 나머지 획은 보존합니다.")
                drawing(proposal.before, label: "변경 전 잉크")
                drawing(proposal.after, label: "변경 후 잉크")
                HStack {
                    Button("취소", action: cancel).accessibilityIdentifier("canvasInkTextDeleteCancel")
                    Spacer()
                    Button("확인한 글자와 획 삭제", action: confirm).accessibilityIdentifier("canvasInkTextDeleteConfirm")
                }.buttonStyle(.bordered).frame(minHeight: 44)
            }.padding()
        }
    }

    @ViewBuilder private func drawing(_ scene: CanvasScene, label: String) -> some View {
        if let data = Data(base64Encoded: scene.drawingBase64), let drawing = try? PKDrawing(data: data) {
            let original = (try? PKDrawing(data: Data(base64Encoded: proposal.before.drawingBase64) ?? Data()))
            let bounds = (original?.bounds ?? drawing.bounds).insetBy(dx: -12, dy: -12)
            if !bounds.isEmpty, !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite {
                #if os(macOS)
                Image(nsImage: drawing.image(from: bounds, scale: min(1, 1024 / max(bounds.width, bounds.height)))).resizable().scaledToFit()
                    .frame(maxHeight: 180).accessibilityLabel(label)
                #else
                Image(uiImage: drawing.image(from: bounds, scale: min(1, 1024 / max(bounds.width, bounds.height)))).resizable().scaledToFit()
                    .frame(maxHeight: 180).accessibilityLabel(label)
                #endif
            }
        }
    }
}

struct CanvasInkTextDeleteSheet: View {
    @ObservedObject var editing: CanvasInkTextEditing
    let text: String
    let propose: (NSRange) -> Void
    let confirm: () -> Void
    let cancel: () -> Void
    @State private var selectedLocation: Int?

    private var characters: [(order: Int, location: Int, length: Int, text: String)] {
        text.indices.enumerated().map { order, index in
            let end = text.index(after: index)
            let range = NSRange(index..<end, in: text)
            return (order, range.location, range.length, String(text[index..<end]))
        }
    }

    var body: some View {
        if let proposal = editing.proposal {
            CanvasInkTextDeletePreview(proposal: proposal, confirm: confirm, cancel: cancel)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("선택한 원본 획의 한 글자 삭제").font(.headline)
                Text("인식된 문장에서 삭제할 글자 하나를 선택하세요. 대응이 모호하면 원본을 바꾸지 않습니다.")
                Picker("삭제할 글자", selection: $selectedLocation) {
                    Text("글자 선택").tag(Int?.none)
                    ForEach(characters, id: \.location) { item in
                        Text("\(item.order + 1)번째 글자 · \(item.text)").tag(Optional(item.location))
                    }
                }.accessibilityIdentifier("canvasInkTextDeleteCharacter")
                    .disabled(editing.hasPendingWork)
                switch editing.phase {
                case .reading: ProgressView("원본 획과 글자를 대조하고 있습니다.")
                case .ambiguous(let reason): Text(reason.localizedDescription).accessibilityIdentifier("canvasInkTextDeleteRefusal")
                default: EmptyView()
                }
                HStack {
                    Button("닫기", action: cancel)
                    Spacer()
                    Button("삭제 미리보기") {
                        guard let item = characters.first(where: { $0.location == selectedLocation }) else { return }
                        propose(NSRange(location: item.location, length: item.length))
                    }.disabled(selectedLocation == nil || editing.hasPendingWork)
                        .accessibilityIdentifier("canvasInkTextDeletePropose")
                }.buttonStyle(.bordered).frame(minHeight: 44)
            }.padding()
        }
    }
}
