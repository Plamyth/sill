import Foundation

// Existing note/link/annotation fields keep this readable by older scene consumers.
enum CanvasCardMerge {
    static let markerAuthor = "카드 병합"
    static let markerText = "원본을 보존한 병합입니다. 번호가 있는 연결선의 순서대로 원본 카드를 확인하세요."
    static let linkPrefix = "병합 원본 · "

    enum Failure: LocalizedError {
        case changed, selection, unsupported, tooLarge
        var errorDescription: String? {
            switch self {
            case .changed: return "장면이나 선택이 바뀌었습니다. 원본을 유지하며 병합을 취소합니다."
            case .selection: return "표시 중인 서로 다른 일반 메모 카드를 순서대로 선택하세요."
            case .unsupported: return "병합 출처와 순서를 확정할 수 없어 카드와 연결을 유지합니다."
            case .tooLarge: return "병합 저장 한도를 넘었습니다. 기존 카드와 원본을 유지합니다."
            }
        }
    }

    struct Draft {
        let sceneSHA: String
        let memberIDs: [UUID]

        init(scene: CanvasScene, memberIDs: [UUID]) throws {
            guard (1...20).contains(memberIDs.count), Set(memberIDs).count == memberIDs.count,
                  Set(scene.nodes.map(\.id)).count == scene.nodes.count else { throw Failure.selection }
            for id in memberIDs {
                guard let node = scene.nodes.first(where: { $0.id == id }), node.kind == .note,
                      node.confidence == .confirmed, scene.visibility.nodeIDs.contains(id),
                      !scene.annotations.contains(where: { $0.nodeId == id && $0.author == markerAuthor })
                else { throw Failure.selection }
            }
            sceneSHA = try CanvasFileWorkspace.sceneSHA(scene)
            self.memberIDs = memberIDs
        }

        func appending(_ id: UUID, in scene: CanvasScene) throws -> Draft {
            guard try CanvasFileWorkspace.sceneSHA(scene) == sceneSHA else { throw Failure.changed }
            return try Draft(scene: scene, memberIDs: memberIDs + [id])
        }

        func applying(to scene: CanvasScene) throws -> (scene: CanvasScene, cardID: UUID) {
            guard try CanvasFileWorkspace.sceneSHA(scene) == sceneSHA,
                  scene.revision < Int.max else { throw Failure.changed }
            _ = try Draft(scene: scene, memberIDs: memberIDs)
            guard memberIDs.count >= 2 else { throw Failure.selection }
            let members = memberIDs.map { id in scene.nodes.first { $0.id == id }! }
            let id = UUID()
            var next = scene
            let first = members[0].frame
            next.nodes.append(CanvasNode(id: id, kind: .note,
                frame: .init(x: first.x + 40, y: first.y + 40, width: 320, height: 180),
                text: "병합 카드 · 저장 당시 표시\n\n" + members.enumerated().map {
                    "[\($0.offset + 1)]\n" + $0.element.text
                }.joined(separator: "\n\n"), confidence: .confirmed, sourceStrokeIds: []))
            for (index, source) in members.enumerated() {
                next.links.append(CanvasLink(id: UUID(), from: id, to: source.id,
                    label: linkPrefix + String(index + 1), kind: .general))
            }
            next.annotations.append(CanvasAnnotation(id: UUID(), nodeId: id,
                text: markerText, author: markerAuthor))
            next.revision += 1
            try validateSize(next)
            return (next, id)
        }
    }

    static func members(of id: UUID, in scene: CanvasScene) -> [CanvasNode]? {
        guard Set(scene.nodes.map(\.id)).count == scene.nodes.count,
              Set(scene.links.map(\.id)).count == scene.links.count,
              let card = scene.nodes.first(where: { $0.id == id }), card.kind == .note, card.vaultNote == nil,
              scene.annotations.filter({ $0.nodeId == id && $0.author == markerAuthor }).count == 1,
              scene.annotations.contains(where: {
                  $0.nodeId == id && $0.author == markerAuthor && $0.text.utf8.elementsEqual(markerText.utf8)
              }) else { return nil }
        let links = scene.links.filter { $0.from == id && $0.label.hasPrefix(linkPrefix) }
        guard (2...20).contains(links.count), Set(links.map(\.to)).count == links.count else { return nil }
        var members: [CanvasNode] = []
        for index in 1...links.count {
            let matches = links.filter { $0.label.utf8.elementsEqual((linkPrefix + String(index)).utf8) }
            guard matches.count == 1, let link = matches.first, link.kind != .parentChild, link.to != id,
                  let source = scene.nodes.first(where: { $0.id == link.to }), source.kind == .note else { return nil }
            members.append(source)
        }
        return members
    }

    static func unmerging(_ id: UUID, in scene: CanvasScene) throws -> CanvasScene {
        guard scene.revision < Int.max, members(of: id, in: scene) != nil else { throw Failure.unsupported }
        var next = scene
        next.links.removeAll { $0.from == id && $0.label.hasPrefix(linkPrefix) }
        next.annotations.removeAll { $0.nodeId == id && $0.author == markerAuthor }
        // The combined body may contain unique user edits. Unmerge never deletes it.
        next.revision += 1
        try validateSize(next)
        return next
    }

    private static func validateSize(_ scene: CanvasScene) throws {
        try scene.requireCompatibleNodeKinds()
        guard scene.nodes.count < 1000,
              try CanvasFileWorkspace.bytes(scene).count <= CanvasScene.localByteLimit,
              scene.nodes.allSatisfy(\.hasValidRotation) else { throw Failure.tooLarge }
    }
}

#if canImport(PencilKit)
import SwiftUI

struct CanvasCardMergeMenu: View {
    @ObservedObject var store: CanvasStore

    var body: some View {
        let selected = store.scene.nodes.first { $0.id == store.selectedNode }
        Menu("카드 병합 · 원본 유지") {
            if let draft = store.cardMergeDraft {
                Text("선택한 순서 · \(draft.memberIDs.count)개")
                Button("선택 카드를 다음 순서로 추가") {
                    if let selected { store.appendCardMerge(selected) }
                }.disabled(!store.canAppendCardMerge)
                Button("선택 순서로 병합") { store.confirmCardMerge() }
                    .disabled(!store.canConfirmCardMerge)
                    .accessibilityIdentifier("canvasConfirmCardMerge")
                Button("병합 선택 취소") { store.cancelCardMerge() }
            } else {
                Button("선택 카드부터 병합 준비") {
                    if let selected { store.beginCardMerge(selected) }
                }.disabled(!store.canBeginCardMerge)
            }
            if let selected, let members = CanvasCardMerge.members(of: selected.id, in: store.scene) {
                Text("본문은 저장 당시 표시입니다. 최신 출처는 원본 카드에서 확인하세요.")
                ForEach(Array(members.enumerated()), id: \.element.id) { index, source in
                    Button("원본 \(index + 1) 선택 · \(source.text.prefix(32))") { store.select(source.id) }
                }
                Button("병합 해제 · 본문과 원본 유지") { store.unmergeCard(selected) }
                    .disabled(!store.cardMergeInputAllowed || store.cardMergeDraft != nil)
                    .accessibilityIdentifier("canvasUnmergeCard")
            }
        }
        .accessibilityIdentifier("canvasCardMergeMenu")
        .accessibilityHint("카드를 하나씩 선택해 순서대로 추가합니다. 원본 카드와 부모·자식 관계는 바꾸지 않습니다.")
    }
}
#endif
