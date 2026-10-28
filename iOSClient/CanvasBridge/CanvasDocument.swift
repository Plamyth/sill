import Foundation
#if canImport(PencilKit, _version: 616)
import PencilKit
#endif

/// 독립 문서 계약이다. 기존 CanvasScene/packet/relay의 형식을 바꾸지 않는다.
struct CanvasDocument: Codable, Equatable {
    static let formatName = "ccr.canvas-document"
    static let currentVersion = 1
    static let byteLimit = 16 * 1024 * 1024
    static let pageLimit = 128
    let format: String
    let version: Int
    let id: UUID
    private(set) var revision: Int
    private(set) var activePageID: UUID
    private(set) var pages: [CanvasScene]
    private(set) var pageEpoch: UInt64 = 0
    private var sessionID = UUID()

    enum Failure: LocalizedError {
        case unsupported, invalid, stale, tooLarge
        var errorDescription: String? {
            switch self {
            case .unsupported: return "지원하지 않는 문서 형식입니다. 원본을 보존합니다."
            case .invalid: return "페이지와 원본 참조를 확인할 수 없습니다. 문서를 바꾸지 않았습니다."
            case .stale: return "문서가 바뀌었습니다. 최신 문서를 확인하세요."
            case .tooLarge: return "문서 저장 한도를 넘었습니다. 원본을 유지합니다."
            }
        }
    }
    struct Duplication {
        let pageID: UUID
        let nodeIDs: [UUID: UUID]
        let linkIDs: [UUID: UUID]
        let annotationIDs: [UUID: UUID]
    }
    struct PageSnapshot {
        let sessionID: UUID
        let documentID: UUID
        let documentSHA: String
        let pageID: UUID
        let pageRevision: Int
        let epoch: UInt64
    }
    init(legacy scene: CanvasScene) throws {
        format = Self.formatName; version = Self.currentVersion; id = scene.id
        revision = scene.revision; activePageID = scene.id; pages = [scene]
        try validate()
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, version, id, revision, activePageID, pages
    }
    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static let sceneKeys: Set<String> = ["schemaVersion","id","revision","width","height","drawingBase64","strokes","nodes","links","annotations","penSettings"]
    private struct SceneReader: Decodable {
        let scene: CanvasScene
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy:Field.self)
            guard fields.allKeys.allSatisfy({ CanvasDocument.sceneKeys.contains($0.stringValue) }) else { throw Failure.unsupported }
            scene = try CanvasScene(from:decoder)
        }
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy:Field.self)
        guard fields.allKeys.allSatisfy({ CodingKeys(rawValue:$0.stringValue) != nil }) else { throw Failure.unsupported }
        let c = try decoder.container(keyedBy:CodingKeys.self)
        format = try c.decode(String.self,forKey:.format)
        version = try c.decode(Int.self,forKey:.version)
        guard format == Self.formatName, version == Self.currentVersion else { throw Failure.unsupported }
        id = try c.decode(UUID.self,forKey:.id); revision = try c.decode(Int.self,forKey:.revision)
        activePageID = try c.decode(UUID.self,forKey:.activePageID)
        pages = try c.decode([SceneReader].self,forKey:.pages).map(\.scene)
        try validate()
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= byteLimit else { throw Failure.tooLarge }
        guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw Failure.invalid }
        if object["format"] != nil || object["pages"] != nil || object["version"] != nil {
            return try JSONDecoder().decode(Self.self,from:bytes)
        }
        return try decodeLegacy(bytes)
    }
    static func decodeLegacy(_ bytes: Data) throws -> Self {
        guard bytes.count <= CanvasScene.localByteLimit else { throw Failure.tooLarge }
        guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw Failure.invalid }
        guard Set(object.keys).isSubset(of:sceneKeys) else { throw Failure.unsupported }
        return try Self(legacy:JSONDecoder().decode(CanvasScene.self,from:bytes))
    }
    func bytes() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.byteLimit else { throw Failure.tooLarge }
        return bytes
    }
    var activePage: CanvasScene { pages.first { $0.id == activePageID }! }
    func validate() throws {
        guard format == Self.formatName, version == Self.currentVersion else { throw Failure.unsupported }
        guard revision >= 0, !pages.isEmpty, pages.count <= Self.pageLimit,
              Set(pages.map(\.id)).count == pages.count, pages.contains(where:{ $0.id == activePageID }) else { throw Failure.invalid }
        for page in pages {
            try page.requireCompatibleNodeKinds(); try page.validateNativeInkProjection()
            guard let drawing = Data(base64Encoded:page.drawingBase64) else { throw Failure.invalid }
            #if canImport(PencilKit, _version: 616)
            if !drawing.isEmpty { _ = try PKDrawing(data:drawing) }
            #endif
            guard page.revision >= 0, page.width.isFinite, page.height.isFinite,
                  page.width > 0, page.height > 0, page.width <= 16384, page.height <= 16384,
                  page.nodes.count < 1000, page.strokes.count < 10000,
                  page.nodes.allSatisfy(\.hasValidRotation),
                  Set(page.nodes.map(\.id)).count == page.nodes.count,
                  Set(page.links.map(\.id)).count == page.links.count,
                  Set(page.annotations.map(\.id)).count == page.annotations.count else { throw Failure.invalid }
            let nodes = Set(page.nodes.map(\.id))
            guard page.links.allSatisfy({ nodes.contains($0.from) && nodes.contains($0.to) && $0.hasValidAnchors }),
                  page.annotations.allSatisfy({ $0.nodeId.map(nodes.contains) ?? true }),
                  try JSONEncoder().encode(page).count <= CanvasScene.localByteLimit else { throw Failure.invalid }
        }
        _ = try bytes()
    }
    mutating func selectPage(_ pageID: UUID, expectedRevision: Int) throws {
        guard revision == expectedRevision, revision < Int.max, pageEpoch < UInt64.max else { throw Failure.stale }
        guard pages.contains(where:{ $0.id == pageID }) else { throw Failure.invalid }
        if pageID != activePageID { activePageID = pageID; revision += 1; pageEpoch += 1 }
    }
    func pageSnapshot() throws -> PageSnapshot {
        PageSnapshot(sessionID:sessionID,documentID:id,documentSHA:CanvasPacket.sha(try bytes()),pageID:activePageID,
                     pageRevision:activePage.revision,epoch:pageEpoch)
    }
    func accepts(_ snapshot: PageSnapshot) -> Bool {
        snapshot.sessionID == sessionID && snapshot.documentID == id && snapshot.pageID == activePageID && snapshot.pageRevision == activePage.revision &&
            snapshot.epoch == pageEpoch && (try? CanvasPacket.sha(bytes())) == snapshot.documentSHA
    }
    mutating func replacePage(_ page: CanvasScene, expectedRevision: Int) throws {
        guard revision == expectedRevision, revision < Int.max, pageEpoch < UInt64.max else { throw Failure.stale }
        guard let index = pages.firstIndex(where:{ $0.id == page.id }) else { throw Failure.invalid }
        var next = self; next.pages[index] = page; next.revision += 1
        try next.validate(); self = next
    }
    @discardableResult
    mutating func duplicatePage(_ sourceID: UUID, expectedRevision: Int) throws -> Duplication {
        guard revision == expectedRevision, revision < Int.max, pageEpoch < UInt64.max else { throw Failure.stale }
        try validate()
        guard pages.count < Self.pageLimit, let index = pages.firstIndex(where:{ $0.id == sourceID }) else { throw Failure.invalid }
        var copy = pages[index]
        // native strokeID와 sourceStrokeIds는 raw drawing과 함께 페이지 범위에서 보존한다.
        let nodeIDs = Dictionary(uniqueKeysWithValues:copy.nodes.map { ($0.id, UUID()) })
        let linkIDs = Dictionary(uniqueKeysWithValues:copy.links.map { ($0.id, UUID()) })
        let annotationIDs = Dictionary(uniqueKeysWithValues:copy.annotations.map { ($0.id, UUID()) })
        copy.id = UUID(); copy.revision = 0
        for i in copy.nodes.indices { copy.nodes[i].id = nodeIDs[copy.nodes[i].id]! }
        for i in copy.links.indices {
            copy.links[i].id = linkIDs[copy.links[i].id]!
            copy.links[i].from = nodeIDs[copy.links[i].from]!
            copy.links[i].to = nodeIDs[copy.links[i].to]!
        }
        for i in copy.annotations.indices {
            copy.annotations[i].id = annotationIDs[copy.annotations[i].id]!
            copy.annotations[i].nodeId = copy.annotations[i].nodeId.map { nodeIDs[$0]! }
        }
        var next = self; next.pages.insert(copy,at:index + 1); next.activePageID = copy.id; next.revision += 1; next.pageEpoch += 1
        try next.validate(); self = next
        return Duplication(pageID:copy.id,nodeIDs:nodeIDs,linkIDs:linkIDs,annotationIDs:annotationIDs)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard let a = try? lhs.bytes(), let b = try? rhs.bytes() else { return false }
        return a == b
    }
}
