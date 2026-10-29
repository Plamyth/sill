import Foundation
import ImageIO
import PencilKit
import zlib

/// 문서 wire 검증만 소유한다. Store/Files의 원본·dirty·복구 상태를 변경하지 않는다.
enum CanvasDocumentRelay {
    static let requestLimit = 67_139_536
    static let bundleLimit = requestLimit + 64 * 1024
    static let conflictLimit = 8 * 1024 * 1024
    static let safeInteger = 9_007_199_254_740_991
    enum Failure: LocalizedError {
        case invalid, unsupported, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: return "문서 전체의 원문·순서·자산을 확인하지 못했습니다. 원본과 요청 의도를 보존하세요."
            case .unsupported: return "서버의 문서 전체 지원을 확인하지 못했습니다. 선택 장면으로 축소해 저장하지 않습니다."
            case .tooLarge: return "문서 전체 전송 한도를 넘었습니다. 원본을 보존합니다."
            }
        }
    }
    static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func uuid(_ value: String) -> Bool { UUID(uuidString:value)?.uuidString.lowercased() == value }
    static func opaqueID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func data(_ base64: String, limit: Int) throws -> Data {
        guard base64.utf8.count <= 4 * ((limit + 2) / 3), let bytes = Data(base64Encoded:base64),
              bytes.count <= limit, bytes.base64EncodedString() == base64 else { throw Failure.invalid }
        return bytes
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]; return encoder
    }
    private static func completePNG(_ bytes: Data) throws {
        guard bytes.count <= 32 * 1024 * 1024, bytes.starts(with:[137,80,78,71,13,10,26,10]) else { throw Failure.invalid }
        var compressed = Data()
        try bytes.withUnsafeBytes { raw in
            let input = raw.bindMemory(to:UInt8.self)
            func word(_ at: Int) -> UInt32 {
                UInt32(input[at]) << 24 | UInt32(input[at + 1]) << 16 | UInt32(input[at + 2]) << 8 | UInt32(input[at + 3])
            }
            var offset = 8, header = false, ended = false
            while offset + 12 <= input.count {
                let length = Int(word(offset))
                guard length <= input.count - offset - 12,
                      let kind = String(bytes:input[(offset + 4)..<(offset + 8)],encoding:.ascii) else { throw Failure.invalid }
                let actual = crc32(0,input.baseAddress!.advanced(by:offset + 4),uInt(length + 4))
                guard UInt32(actual) == word(offset + 8 + length) else { throw Failure.invalid }
                if kind == "IHDR" {
                    guard !header, offset == 8, length == 13 else { throw Failure.invalid }
                    header = true
                }
                if kind == "IDAT" { compressed.append(contentsOf:input[(offset + 8)..<(offset + 8 + length)]) }
                offset += length + 12
                if kind == "IEND" {
                    guard length == 0 else { throw Failure.invalid }
                    ended = true
                    break
                }
            }
            guard header, ended, offset == input.count, !compressed.isEmpty else { throw Failure.invalid }
        }
        // 서버와 같은 64MiB 해제 한도를 작은 작업 버퍼로 검사한다.
        try compressed.withUnsafeBytes { raw in
            var stream = z_stream()
            guard inflateInit_(&stream,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalid }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer(mutating:raw.bindMemory(to:Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            var buffer = [UInt8](repeating:0,count:64 * 1024)
            try buffer.withUnsafeMutableBytes { output in
                var result: Int32
                repeat {
                    stream.next_out = output.bindMemory(to:Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    result = inflate(&stream,Z_NO_FLUSH)
                    guard stream.total_out <= 64 * 1024 * 1024 else { throw Failure.invalid }
                } while result == Z_OK
                guard result == Z_STREAM_END else { throw Failure.invalid }
            }
        }
    }
    static func png(_ bytes: Data) throws {
        try completePNG(bytes)
        guard bytes.starts(with:[137,80,78,71,13,10,26,10]),
              let source = CGImageSourceCreateWithData(bytes as CFData,nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) != nil else { throw Failure.invalid }
    }
    struct Capabilities: Decodable {
        let schema: String
        let document: Capability?
        func require() throws {
            guard schema == "ccr.canvas-capabilities/v1", let document else { throw Failure.unsupported }
            try document.require()
        }
    }
    struct Capability: Decodable {
        let schema: String, format: String
        let versions: [Int]
        let wholeDocument: Bool, explicitConflictResolution: Bool
        let maxDocumentJSONBytes: Int, maxPageCount: Int, maxPreviewTotalBytes: Int, maxRequestBytes: Int
        func require() throws {
            guard schema == "ccr.vault-document/v1", format == CanvasDocument.formatName, versions.contains(1),
                  wholeDocument, explicitConflictResolution, maxDocumentJSONBytes == CanvasDocument.byteLimit,
                  maxPageCount == CanvasDocument.pageLimit, maxPreviewTotalBytes == 32 * 1024 * 1024,
                  maxRequestBytes == requestLimit else { throw Failure.unsupported }
        }
    }
    struct Base: Codable, Equatable {
        let noteSha256: String, documentSha256: String, manifestSha256: String
        func validate() throws {
            guard [noteSha256,documentSha256,manifestSha256].allSatisfy(hash) else { throw Failure.invalid }
        }
    }
    struct PageMetadata: Codable, Equatable {
        let id: String, drawingSha256: String, previewSha256: String
    }
    struct PageWire: Codable {
        let id: String, drawingSha256: String, previewSha256: String, previewPNGBase64: String
        var metadata: PageMetadata { .init(id:id,drawingSha256:drawingSha256,previewSha256:previewSha256) }
    }
    struct Summary: Codable, Equatable {
        let schema: String, id: String, path: String
        let revision: Int
        let activePageID: String, noteSha256: String, documentSha256: String, manifestSha256: String, generation: String
        let pages: [PageMetadata]
        var base: Base { .init(noteSha256:noteSha256,documentSha256:documentSha256,manifestSha256:manifestSha256) }
        func validate(id expected: UUID) throws {
            guard schema == "ccr.vault-document/v1", id == expected.uuidString.lowercased(),
                  path == "CCR Documents/\(id).md", uuid(generation), uuid(activePageID),
                  revision >= 0, revision <= safeInteger, !pages.isEmpty, pages.count <= CanvasDocument.pageLimit,
                  Set(pages.map(\.id)).count == pages.count, pages.contains(where: { $0.id == activePageID }),
                  pages.allSatisfy({ uuid($0.id) && hash($0.drawingSha256) && hash($0.previewSha256) }) else { throw Failure.invalid }
            try base.validate()
        }
        func matches(_ document: CanvasDocument, bytes: Data, assets: [PageMetadata]) throws {
            try validate(id:document.id)
            guard revision == document.revision, activePageID == document.activePageID.uuidString.lowercased(),
                  documentSha256 == CanvasPacket.sha(bytes), pages == assets,
                  pages.map(\.id) == document.pages.map({ $0.id.uuidString.lowercased() }) else { throw Failure.invalid }
        }
    }
    struct Bundle: Decodable {
        let summary: Summary
        let documentJSONBase64: String
        let pages: [PageWire]
        private enum CodingKeys: CodingKey { case documentJSONBase64, pages }
        init(from decoder: Decoder) throws {
            summary = try Summary(from:decoder)
            let c = try decoder.container(keyedBy:CodingKeys.self)
            documentJSONBase64 = try c.decode(String.self,forKey:.documentJSONBase64)
            pages = try c.decode([PageWire].self,forKey:.pages)
        }
        func validated(id: UUID) throws -> Validated {
            try summary.validate(id:id)
            let bytes = try data(documentJSONBase64,limit:CanvasDocument.byteLimit)
            // 문서 decoder만 사용한다. legacy scene을 문서 응답으로 승격하지 않는다.
            let document = try CanvasDocument.decodeDocument(bytes)
            try validate(document,bytes:bytes,pages:pages)
            try summary.matches(document,bytes:bytes,assets:pages.map(\.metadata))
            return Validated(summary:summary,document:document,documentJSON:bytes,
                             previews:try Dictionary(uniqueKeysWithValues:pages.map { (UUID(uuidString:$0.id)!,try data($0.previewPNGBase64,limit:32 * 1024 * 1024)) }))
        }
    }
    struct Validated {
        let summary: Summary
        let document: CanvasDocument
        let documentJSON: Data
        let previews: [UUID:Data]
        fileprivate init(summary: Summary, document: CanvasDocument, documentJSON: Data, previews: [UUID:Data]) {
            self.summary = summary; self.document = document; self.documentJSON = documentJSON; self.previews = previews
        }
        func sameOriginals(as other: Self) -> Bool {
            summary == other.summary && documentJSON == other.documentJSON && previews == other.previews
        }
    }
    static func validate(_ document: CanvasDocument, bytes: Data, pages: [PageWire]) throws {
        try document.validate()
        guard document.revision <= safeInteger, document.pages.allSatisfy({ $0.revision <= safeInteger }),
              bytes.count <= CanvasDocument.byteLimit, pages.count == document.pages.count,
              pages.map(\.id) == document.pages.map({ $0.id.uuidString.lowercased() }) else { throw Failure.invalid }
        var total = 0
        for (page,asset) in zip(document.pages,pages) {
            let drawing = try data(page.drawingBase64,limit:CanvasScene.localByteLimit)
            // 서버의 구조 검증과 별개인 Apple native PKDrawing 검증이다.
            if drawing.isEmpty { _ = PKDrawing() } else { _ = try PKDrawing(data:drawing) }
            let preview = try data(asset.previewPNGBase64,limit:32 * 1024 * 1024)
            total += preview.count
            guard total <= 32 * 1024 * 1024, hash(asset.drawingSha256), hash(asset.previewSha256),
                  CanvasPacket.sha(drawing) == asset.drawingSha256,
                  CanvasPacket.sha(preview) == asset.previewSha256 else { throw Failure.invalid }
            try png(preview)
        }
    }
    struct Put: Encodable {
        let base: Base?
        let documentJSONBase64: String, documentSha256: String
        let pages: [PageWire]
        private enum CodingKeys: CodingKey { case base, documentJSONBase64, documentSha256, pages }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy:CodingKeys.self)
            try c.encode(base,forKey:.base); try c.encode(documentJSONBase64,forKey:.documentJSONBase64)
            try c.encode(documentSha256,forKey:.documentSha256); try c.encode(pages,forKey:.pages)
        }
        static func make(bytes: Data, previews: [UUID:Data], base: Base?) throws -> (Self,CanvasDocument,Data) {
            guard bytes.count <= CanvasDocument.byteLimit else { throw Failure.tooLarge }
            let document = try CanvasDocument.decodeDocument(bytes)
            guard Set(previews.keys) == Set(document.pages.map(\.id)) else { throw Failure.invalid }
            try base?.validate()
            let assets = document.pages.map { page in
                PageWire(id:page.id.uuidString.lowercased(),drawingSha256:CanvasPacket.sha(Data(base64Encoded:page.drawingBase64) ?? Data()),
                         previewSha256:CanvasPacket.sha(previews[page.id]!),previewPNGBase64:previews[page.id]!.base64EncodedString())
            }
            try validate(document,bytes:bytes,pages:assets)
            let value = Self(base:base,documentJSONBase64:bytes.base64EncodedString(),documentSha256:CanvasPacket.sha(bytes),pages:assets)
            let body = try encoder().encode(value)
            guard body.count <= requestLimit else { throw Failure.tooLarge }
            return (value,document,body)
        }
    }
    struct Expected: Codable, Equatable {
        let activeSha256: String?, baseSha256: String?, displacedSha256: String?, proposalSha256: String?
        let historySha256: String, bundlesSha256: String
        private enum CodingKeys: String, CodingKey, CaseIterable { case activeSha256,baseSha256,displacedSha256,proposalSha256,historySha256,bundlesSha256 }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy:WireKey.self)
            guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else { throw Failure.invalid }
            let c = try decoder.container(keyedBy:CodingKeys.self)
            guard CodingKeys.allCases.allSatisfy({ c.contains($0) }) else { throw Failure.invalid }
            activeSha256 = try c.decodeIfPresent(String.self,forKey:.activeSha256); baseSha256 = try c.decodeIfPresent(String.self,forKey:.baseSha256)
            displacedSha256 = try c.decodeIfPresent(String.self,forKey:.displacedSha256); proposalSha256 = try c.decodeIfPresent(String.self,forKey:.proposalSha256)
            historySha256 = try c.decode(String.self,forKey:.historySha256); bundlesSha256 = try c.decode(String.self,forKey:.bundlesSha256)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy:CodingKeys.self)
            try c.encode(activeSha256,forKey:.activeSha256); try c.encode(baseSha256,forKey:.baseSha256)
            try c.encode(displacedSha256,forKey:.displacedSha256); try c.encode(proposalSha256,forKey:.proposalSha256)
            try c.encode(historySha256,forKey:.historySha256); try c.encode(bundlesSha256,forKey:.bundlesSha256)
        }
    }
    private struct WireKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    enum MaterialName: String, CaseIterable { case active, base, displaced, proposal }
    struct Material: Codable {
        let sha256: String, markdownBase64: String
        let validDocument: Bool
        let document: Summary?
        let refusal: String?
    }
    struct Materials: Codable {
        let active: Material?, base: Material?, displaced: Material?, proposal: Material?
        subscript(_ name: MaterialName) -> Material? {
            switch name { case .active: return active; case .base: return base; case .displaced: return displaced; case .proposal: return proposal }
        }
    }
    struct History: Codable { let recoveryID: String; let files: [String:String?] }
    struct Conflict: Codable {
        let schema: String, id: String, recoveryID: String, code: String
        let reconciliationRequired: Bool, publicationAttempted: Bool
        let expected: Expected, materials: Materials, history: [History]
        func validated(id expectedID: UUID) throws -> Self {
            guard schema == "ccr.document-conflict/v1", id == expectedID.uuidString.lowercased(), opaqueID(recoveryID),
                  code == "note_reconciliation_required", reconciliationRequired, hash(expected.historySha256), hash(expected.bundlesSha256),
                  history.count <= 32, Set(history.map(\.recoveryID)).count == history.count,
                  history.allSatisfy({ opaqueID($0.recoveryID) && $0.files.count <= 7 && $0.files.values.allSatisfy { $0.map(hash) ?? true } }) else { throw Failure.invalid }
            let hashes = [expected.activeSha256,expected.baseSha256,expected.displacedSha256,expected.proposalSha256]
            for (name,expectedSHA) in zip(MaterialName.allCases,hashes) {
                if let m = materials[name] {
                    guard m.sha256 == expectedSHA, hash(m.sha256), CanvasPacket.sha(try data(m.markdownBase64,limit:conflictLimit)) == m.sha256 else { throw Failure.invalid }
                    if m.validDocument {
                        guard let summary = m.document, summary.noteSha256 == m.sha256 else { throw Failure.invalid }
                        try summary.validate(id:expectedID)
                    } else { guard m.document == nil, m.refusal?.isEmpty == false else { throw Failure.invalid } }
                } else if expectedSHA != nil { throw Failure.invalid }
            }
            return self
        }
        func chosen(_ decision: CanvasRelay.ConflictDecision) -> MaterialName { decision == .keepCurrent ? .active : .displaced }
    }
    struct Resolve: Encodable {
        let recoveryID: String, expected: Expected, decision: CanvasRelay.ConflictDecision
    }
    struct Resolved: Decodable {
        let summary: Summary
        let recoveryID: String, decision: CanvasRelay.ConflictDecision
        let resolved: Bool, reconciliationRequired: Bool
        private enum CodingKeys: CodingKey { case recoveryID,decision,resolved,reconciliationRequired }
        init(from decoder: Decoder) throws {
            summary = try Summary(from:decoder)
            let c = try decoder.container(keyedBy:CodingKeys.self)
            recoveryID = try c.decode(String.self,forKey:.recoveryID); decision = try c.decode(CanvasRelay.ConflictDecision.self,forKey:.decision)
            resolved = try c.decode(Bool.self,forKey:.resolved); reconciliationRequired = try c.decode(Bool.self,forKey:.reconciliationRequired)
        }
    }
}
