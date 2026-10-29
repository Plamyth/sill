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
        return CanvasGroup.orderedMembers(of:id,in:scene,prefix:linkPrefix,count:2...20)
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

    fileprivate static func validateSize(_ scene: CanvasScene) throws {
        try scene.requireCompatibleNodeKinds()
        guard scene.nodes.count < 1000,
              try CanvasFileWorkspace.bytes(scene).count <= CanvasScene.localByteLimit,
              scene.nodes.allSatisfy(\.hasValidRotation) else { throw Failure.tooLarge }
    }
}

extension CanvasGroup {
    struct Draft {
        let selection: CanvasCardMerge.Draft
        var memberIDs: [UUID] { selection.memberIDs }
        var sceneSHA: String { selection.sceneSHA }

        init(scene: CanvasScene, memberIDs: [UUID]) throws {
            let entries = try CanvasGroup.entries(in:scene)
            guard !entries.contains(where:{ !$0.memberIDs.filter(memberIDs.contains).isEmpty }),
                  !scene.links.contains(where:{ $0.kind == .parentChild && (memberIDs.contains($0.from) || memberIDs.contains($0.to)) })
            else { throw Failure.selection }
            selection = try CanvasCardMerge.Draft(scene:scene,memberIDs:memberIDs)
        }
        func appending(_ id: UUID, in scene: CanvasScene) throws -> Draft {
            guard try CanvasFileWorkspace.sceneSHA(scene) == sceneSHA else { throw Failure.changed }
            return try Draft(scene:scene,memberIDs:memberIDs + [id])
        }
        func applying(to scene: CanvasScene) throws -> (scene:CanvasScene, groupID:UUID) {
            guard try CanvasFileWorkspace.sceneSHA(scene) == sceneSHA, scene.revision < Int.max else { throw Failure.changed }
            _ = try Draft(scene:scene,memberIDs:memberIDs)
            let members = memberIDs.map { id in scene.nodes.first { $0.id == id }! }
            guard members.allSatisfy({ $0.frame.isValidLinkFrame }) else { throw Failure.selection }
            let corners = members.flatMap { node in
                [CanvasPoint(x:node.frame.x,y:node.frame.y),.init(x:node.frame.x + node.frame.width,y:node.frame.y),
                 .init(x:node.frame.x,y:node.frame.y + node.frame.height),.init(x:node.frame.x + node.frame.width,y:node.frame.y + node.frame.height)]
                    .compactMap { node.scenePoint($0) }
            }
            guard corners.count == members.count * 4 else { throw Failure.selection }
            let x = corners.map(\.x).min()! - 24, y = corners.map(\.y).min()! - 60
            let right = corners.map(\.x).max()! + 24, bottom = corners.map(\.y).max()! + 24
            let frame = CanvasRect(x:x,y:y,width:right - x,height:bottom - y)
            guard frame.isValidLinkFrame else { throw Failure.selection }
            var next = scene
            let id = UUID()
            // Put the outline behind the unchanged member cards; no card body or ink is copied.
            next.nodes.insert(.init(id:id,kind:.box,frame:frame,text:"그룹",confidence:.confirmed,sourceStrokeIds:[],isCollapsed:false),at:0)
            for (index,member) in memberIDs.enumerated() {
                next.links.append(.init(id:UUID(),from:id,to:member,label:linkPrefix + String(index + 1),kind:.general))
            }
            next.annotations.append(.init(id:UUID(),nodeId:id,text:marker,author:author))
            next.revision += 1
            _ = try entries(in:next); try CanvasCardMerge.validateSize(next)
            return (next,id)
        }
    }

    static func toggling(_ expected: CanvasNode, in scene: CanvasScene) throws -> CanvasScene {
        guard scene.revision < Int.max, let entry = try entries(in:scene).first(where:{ $0.node.id == expected.id }),
              CanvasScene.sameNode(entry.node,expected), let index = scene.nodes.firstIndex(where:{ $0.id == expected.id })
        else { throw Failure.changed }
        var next = scene; next.nodes[index].isCollapsed = expected.isCollapsed != true; next.revision += 1
        try CanvasCardMerge.validateSize(next)
        return next
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

struct CanvasGroupMenu: View {
    @ObservedObject var store: CanvasStore
    var body: some View {
        let owner = store.groupCommandOwner
        return Menu("그룹 · 하위 지도") {
            if let draft = store.groupDraft {
                Text("그룹 순서 · \(draft.memberIDs.count)개")
                Button("선택 카드를 다음 순서로 추가") { store.appendGroupCard(owner:owner) }.disabled(!store.canAppendGroupCard)
                Button("이 순서로 그룹 만들기") { store.confirmGroup() }.disabled(!store.canConfirmGroup)
                    .accessibilityIdentifier("canvasCreateGroup")
                Button("그룹 선택 취소") { store.cancelGroupDraft() }
            } else {
                Button("선택 카드부터 그룹 준비") { store.beginGroup(owner:owner) }.disabled(!store.canBeginGroup)
            }
            if let selected = store.selectedNode.flatMap({ id in store.scene.nodes.first { $0.id == id } }),
               store.groups.contains(where:{ $0.node.id == selected.id }) {
                Button(selected.isCollapsed == true ? "그룹 펼치기" : "하위 지도로 접기") { store.toggleGroup(selected,owner:owner) }
                    .disabled(!store.groupInputAllowed || store.groupDraft != nil)
            }
            ForEach(store.groups.filter { $0.node.isCollapsed == true },id:\.node.id) { group in
                Button("하위 지도 열기 · \(group.node.text)") { store.enterGroup(group.node,owner:owner) }
                    .disabled(!store.groupInputAllowed || store.groupDraft != nil)
            }
            if let id = store.openedGroupID, let group = store.groups.first(where:{ $0.node.id == id }) {
                ForEach(Array(group.memberIDs.enumerated()),id:\.element) { index,id in
                    if let node = store.scene.nodes.first(where:{ $0.id == id }) {
                        Button("\(index + 1) · \(node.text.prefix(32))") {
                            if owner == store.groupCommandOwner { store.select(id) }
                        }
                    }
                }
                Button("전체 지도로 돌아가기") { store.leaveGroup(owner:owner) }
            }
            if let error = store.groupReadError { Text(error) }
        }
        .accessibilityIdentifier("canvasGroupMenu")
        .accessibilityHint("원본 메모 카드를 순서대로 선택합니다. 그룹 소속은 부모·자식 관계와 별개입니다.")
    }
}
#endif
