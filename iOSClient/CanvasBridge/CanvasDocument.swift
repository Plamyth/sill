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
        let documentRevision: Int
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
    // 새 문서의 byte ingress에서만 엄격 검사한다. 기존 scene wire decoder는 바꾸지 않는다.
    private enum Shape {
        case scene, node, link, annotation, rect, reference, anchor, stroke, point, visibility, segment, style, color, transform, sample, pen
        var fields: Set<String> {
            switch self {
            case .scene: return sceneKeys
            case .node: return ["id","kind","frame","text","confidence","sourceStrokeIds","vaultNote","isCollapsed","rotationDegrees"]
            case .link: return ["id","from","to","label","kind","fromAnchor","toAnchor"]
            case .annotation: return ["id","nodeId","text","author"]
            case .rect: return ["x","y","width","height"]
            case .reference: return ["path","sha256","relayAddress","cacheTruncated","blockID","sourceState","observedSha256","quoteSha256"]
            case .anchor: return ["side","offset"]
            case .stroke: return ["id","points","createdAt","visibility","style"]
            case .point: return ["x","y","pressure"]
            case .visibility: return ["kind","visibleSegments"]
            case .segment: return ["lowerBound","upperBound","worldPoints"]
            case .style: return ["version","inkType","color","transform","samples"]
            case .color: return ["red","green","blue","alpha"]
            case .transform: return ["a","b","c","d","tx","ty"]
            case .sample: return ["width","height","opacity"]
            case .pen: return ["version","color","width"]
            }
        }
        var children: [(String,Shape,Bool)] {
            switch self {
            case .scene: return [("nodes",.node,true),("links",.link,true),("annotations",.annotation,true),("strokes",.stroke,true),("penSettings",.pen,false)]
            case .node: return [("frame",.rect,false),("vaultNote",.reference,false)]
            case .link: return [("fromAnchor",.anchor,false),("toAnchor",.anchor,false)]
            case .stroke: return [("points",.point,true),("visibility",.visibility,false),("style",.style,false)]
            case .visibility: return [("visibleSegments",.segment,true)]
            case .segment: return [("worldPoints",.point,true)]
            case .style: return [("color",.color,false),("transform",.transform,false),("samples",.sample,true)]
            default: return []
            }
        }
        func check(_ decoder: Decoder) throws {
            let c = try decoder.container(keyedBy:Field.self)
            guard c.allKeys.allSatisfy({ fields.contains($0.stringValue) }) else { throw Failure.unsupported }
            for (name,shape,array) in children {
                let key = Field(stringValue:name)!
                guard c.contains(key), try !c.decodeNil(forKey:key) else { continue }
                if array {
                    var items = try c.nestedUnkeyedContainer(forKey:key)
                    while !items.isAtEnd { try shape.check(items.superDecoder()) }
                } else { try shape.check(c.superDecoder(forKey:key)) }
            }
        }
    }
    private struct SceneReader: Decodable {
        let scene: CanvasScene
        init(from decoder: Decoder) throws {
            try Shape.scene.check(decoder)
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
    private static func checkedObject(_ bytes: Data) throws -> [String:Any] {
        guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw Failure.invalid }
        struct Scope {
            let object: Bool
            var expectsKey: Bool
            var keys = Set<String>()
        }
        // Foundation이 문법을 검사한 뒤, 디코더가 값을 선택하기 전에 이스케이프 표기를 포함한 중복 키를 거부한다.
        try bytes.withUnsafeBytes { raw in
            let input = raw.bindMemory(to:UInt8.self)
            var scopes: [Scope] = [], offset = 0
            while offset < input.count {
                switch input[offset] {
                case 123: scopes.append(Scope(object:true,expectsKey:true))
                case 91: scopes.append(Scope(object:false,expectsKey:false))
                case 125, 93:
                    guard !scopes.isEmpty else { throw Failure.invalid }
                    scopes.removeLast()
                case 44:
                    if let last = scopes.indices.last, scopes[last].object { scopes[last].expectsKey = true }
                case 34:
                    let start = offset
                    offset += 1
                    var escaped = false
                    while offset < input.count {
                        let value = input[offset]
                        if escaped { escaped = false }
                        else if value == 92 { escaped = true }
                        else if value == 34 { break }
                        offset += 1
                    }
                    guard offset < input.count else { throw Failure.invalid }
                    if let last = scopes.indices.last, scopes[last].object, scopes[last].expectsKey {
                        let key = try JSONDecoder().decode(String.self,from:Data(input[start...offset]))
                        guard scopes[last].keys.insert(key).inserted else { throw Failure.invalid }
                        scopes[last].expectsKey = false
                    }
                default: break
                }
                offset += 1
            }
            guard scopes.isEmpty else { throw Failure.invalid }
        }
        return object
    }
    static func decodeDocument(_ bytes: Data) throws -> Self {
        guard bytes.count <= byteLimit else { throw Failure.tooLarge }
        _ = try checkedObject(bytes)
        return try JSONDecoder().decode(Self.self,from:bytes)
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= byteLimit else { throw Failure.tooLarge }
        let object = try checkedObject(bytes)
        if object["format"] != nil || object["pages"] != nil || object["version"] != nil {
            return try JSONDecoder().decode(Self.self,from:bytes)
        }
        return try decodeLegacy(bytes)
    }
    static func decodeLegacy(_ bytes: Data) throws -> Self {
        guard bytes.count <= CanvasScene.localByteLimit else { throw Failure.tooLarge }
        let object = try checkedObject(bytes)
        guard Set(object.keys).isSubset(of:sceneKeys) else { throw Failure.unsupported }
        return try Self(legacy:JSONDecoder().decode(SceneReader.self,from:bytes).scene)
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
    /// Store의 같은 MainActor 편집 turn 안에서만 사용한다. 외부 ingress/저장 검증을 대체하지 않는다.
    mutating func updateActivePageForEditing(_ page: CanvasScene) throws {
        guard page.id == activePageID, let index = pages.firstIndex(where:{ $0.id == activePageID }), revision < Int.max else { throw Failure.stale }
        pages[index] = page
        revision += 1
    }
    mutating func selectPage(_ pageID: UUID, expectedRevision: Int) throws {
        guard revision == expectedRevision, revision < Int.max, pageEpoch < UInt64.max else { throw Failure.stale }
        guard pages.contains(where:{ $0.id == pageID }) else { throw Failure.invalid }
        if pageID != activePageID { activePageID = pageID; revision += 1; pageEpoch += 1 }
    }
    func pageSnapshot() throws -> PageSnapshot {
        PageSnapshot(sessionID:sessionID,documentID:id,documentSHA:CanvasPacket.sha(try bytes()),documentRevision:revision,pageID:activePageID,
                     pageRevision:activePage.revision,epoch:pageEpoch)
    }
    /// 획·호버의 현재 입력 소유만 확인한다. 저장·비동기 결과 적용에는 전체 바이트 검사인 accepts를 사용한다.
    func matchesPageActivation(_ snapshot: PageSnapshot) -> Bool {
        snapshot.sessionID == sessionID && snapshot.documentID == id && snapshot.documentRevision == revision &&
            snapshot.pageID == activePageID && snapshot.pageRevision == activePage.revision && snapshot.epoch == pageEpoch
    }
    func accepts(_ snapshot: PageSnapshot) -> Bool {
        matchesPageActivation(snapshot) && (try? CanvasPacket.sha(bytes())) == snapshot.documentSHA
    }
    mutating func replacePage(_ page: CanvasScene, expectedRevision: Int) throws {
        guard revision == expectedRevision, revision < Int.max, pageEpoch < UInt64.max else { throw Failure.stale }
        guard let index = pages.firstIndex(where:{ $0.id == page.id }) else { throw Failure.invalid }
        var next = self; next.pages[index] = page; next.revision += 1
        try next.validate(); self = next
    }
    @discardableResult
    mutating func addBlankPage(after pageID: UUID, expectedRevision: Int) throws -> UUID {
        guard revision == expectedRevision, revision < Int.max, pageEpoch < UInt64.max else { throw Failure.stale }
        try validate()
        guard pages.count < Self.pageLimit, let index = pages.firstIndex(where:{ $0.id == pageID }) else { throw Failure.invalid }
        let source = pages[index]
        var page = CanvasScene()
        page.schemaVersion = source.schemaVersion
        page.width = source.width; page.height = source.height; page.penSettings = source.penSettings
        var next = self
        next.pages.insert(page,at:index + 1); next.activePageID = page.id
        next.revision += 1; next.pageEpoch += 1
        try next.validate(); self = next
        return page.id
    }
    mutating func reorderPages(_ ids: [UUID], expectedRevision: Int) throws {
        guard revision == expectedRevision, revision < Int.max, pageEpoch < UInt64.max else { throw Failure.stale }
        try validate()
        guard ids.count == pages.count, Set(ids).count == ids.count, Set(ids) == Set(pages.map(\.id)) else { throw Failure.invalid }
        guard ids != pages.map(\.id) else { return }
        let originals = Dictionary(uniqueKeysWithValues:pages.map { ($0.id,$0) })
        var next = self
        next.pages = ids.map { originals[$0]! }; next.revision += 1; next.pageEpoch += 1
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
