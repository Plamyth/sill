import Foundation

// The annotation's Markdown is the stored value. Tag lists and filters are derived, never persisted separately.
enum CanvasCardTags {
    static let author = "카드 태그"
    enum Failure: LocalizedError {
        case invalid, changed, unsupported, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: return "태그는 영문·한글·숫자·밑줄·붙임표로 입력하세요. 공백과 숫자만인 태그는 지원하지 않습니다."
            case .changed: return "카드나 장면·선택이 바뀌었습니다. 입력과 원본을 유지합니다. 최신 카드를 다시 선택하세요."
            case .unsupported: return "태그 표식이 중복되거나 해석할 수 없습니다. 기존 자료를 보존합니다."
            case .tooLarge: return "태그를 더하면 저장 한도를 넘습니다. 원본을 유지합니다."
            }
        }
    }

    static func markdown(_ input: String) throws -> String {
        let name = input.hasPrefix("#") ? String(input.dropFirst()) : input
        guard !name.isEmpty, name.utf8.count <= 128 else { throw Failure.invalid }
        var nonNumber = false
        for scalar in name.unicodeScalars {
            let n = scalar.value
            let digit = (48...57).contains(n)
            guard digit || (65...90).contains(n) || (97...122).contains(n) || n == 95 || n == 45 ||
                  (0x1100...0x11ff).contains(n) || (0x3130...0x318f).contains(n) || (0xac00...0xd7a3).contains(n)
            else { throw Failure.invalid }
            if !digit { nonNumber = true }
        }
        guard nonNumber else { throw Failure.invalid }
        return "#" + name
    }

    static func key(_ tag: String) -> String {
        tag.precomposedStringWithCanonicalMapping.lowercased(with:Locale(identifier:"en_US_POSIX"))
    }

    static func tags(for nodeID: UUID, in scene: CanvasScene) throws -> [String] {
        guard Set(scene.nodes.map(\.id)).count == scene.nodes.count,
              Set(scene.annotations.map(\.id)).count == scene.annotations.count,
              scene.nodes.contains(where:{ $0.id == nodeID && $0.kind == .note }) else { throw Failure.unsupported }
        return try parsed(scene.annotations.filter { $0.nodeId == nodeID && $0.author.utf8.elementsEqual(author.utf8) })
    }

    private static func parsed(_ records: [CanvasAnnotation]) throws -> [String] {
        var result: [String] = [], seen = Set<String>()
        for record in records {
            let tag = try markdown(record.text)
            guard tag.utf8.elementsEqual(record.text.utf8), seen.insert(key(tag)).inserted else { throw Failure.unsupported }
            result.append(tag)
        }
        return result
    }

    private static func classified(_ scene: CanvasScene) -> [UUID:[String]] {
        guard Set(scene.nodes.map(\.id)).count == scene.nodes.count,
              Set(scene.annotations.map(\.id)).count == scene.annotations.count else { return [:] }
        let groups = Dictionary(grouping:scene.annotations.filter { $0.author.utf8.elementsEqual(author.utf8) },by:\.nodeId)
        var result: [UUID:[String]] = [:]
        for node in scene.nodes where node.kind == .note {
            if let tags = try? parsed(groups[node.id] ?? []) { result[node.id] = tags }
        }
        return result
    }

    static func available(in scene: CanvasScene) -> [String] {
        let table = classified(scene)
        var seen = Set<String>()
        return scene.nodes.flatMap { table[$0.id] ?? [] }
            .filter { seen.insert(key($0)).inserted }.sorted { key($0) < key($1) }
    }

    static func adding(_ input: String, to id: UUID, in scene: CanvasScene) throws -> CanvasScene {
        guard scene.revision < Int.max, Set(scene.nodes.map(\.id)).count == scene.nodes.count,
              scene.nodes.contains(where:{ $0.id == id && $0.kind == .note && $0.confidence == .confirmed }),
              scene.visibility.nodeIDs.contains(id) else { throw Failure.changed }
        let tag = try markdown(input)
        let existing = try tags(for:id,in:scene)
        if existing.contains(where:{ key($0) == key(tag) }) { return scene }
        var next = scene
        next.annotations.append(CanvasAnnotation(id:UUID(),nodeId:id,text:tag,author:author))
        next.revision += 1
        try next.requireCompatibleNodeKinds()
        guard try CanvasFileWorkspace.bytes(next).count <= CanvasScene.localByteLimit else { throw Failure.tooLarge }
        return next
    }

    static func visibility(in scene: CanvasScene, filter: String?) -> CanvasScene.Visibility {
        let original = scene.visibility
        guard let filter else { return original }
        let notes = Set(scene.nodes.filter { $0.kind == .note }.map(\.id))
        let matches = Set(classified(scene).filter { $0.value.contains { key($0) == key(filter) } }.map(\.key))
        let visible = original.nodeIDs.subtracting(notes.subtracting(matches))
        return .init(nodeIDs:visible,
            linkIDs:Set(scene.links.filter { visible.contains($0.from) && visible.contains($0.to) }.map(\.id)).intersection(original.linkIDs),
            annotationIDs:Set(scene.annotations.filter { $0.nodeId.map(visible.contains) == true }.map(\.id)).intersection(original.annotationIDs))
    }
}

#if canImport(PencilKit)
import SwiftUI

struct CanvasCardTagsMenu: View {
    @ObservedObject var store: CanvasStore
    @State private var editing = false
    @State private var draft = ""
    @State private var session: UUID?

    var body: some View {
        Menu(store.cardTagFilter.map { "태그 필터 · " + $0 } ?? "카드 태그") {
            Button("선택 카드에 태그 추가") {
                if let id = store.beginCardTagInput() { session = id; editing = true }
            }
                .disabled(!store.canBeginCardTagInput)
            if let id = store.selectedNode, let tags = try? CanvasCardTags.tags(for:id,in:store.scene) {
                ForEach(tags,id:\.self) { Text($0) }
            }
            Divider()
            ForEach(store.availableCardTags,id:\.self) { tag in
                Button("\(tag) 카드만 보기") { store.setCardTagFilter(tag) }
            }
            Button("태그 필터 해제") { store.setCardTagFilter(nil) }
                .disabled(store.cardTagFilter == nil)
                .accessibilityIdentifier("canvasClearCardTagFilter")
            Text("카드를 분류하며 원문·댓글·원본 획은 보존합니다.")
        }
        .alert("카드 태그 추가",isPresented:$editing) {
            TextField("태그 이름",text:$draft).accessibilityIdentifier("canvasCardTagText")
            Button("추가") { if let session { _ = store.finishCardTagInput(draft,sessionID:session) } }
            Button("취소",role:.cancel) { if let session { store.cancelCardTagInput(sessionID:session) } }
        } message: {
            Text("영문·한글·숫자·밑줄·붙임표를 사용할 수 있습니다. 저장 실패 시 입력은 다시 열어 확인할 수 있습니다.")
        }
        .onChange(of:editing) { _, open in if !open, let session { store.cancelCardTagInput(sessionID:session) } }
        .onDisappear { if let session { store.cancelCardTagInput(sessionID:session) } }
        .accessibilityIdentifier("canvasCardTagsMenu")
    }
}
#endif
