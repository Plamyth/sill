import Foundation
import PDFKit

struct VaultPDFCreateRecovery: Codable, Equatable {
    let sceneID: UUID
    let relayAddress: String
    let path: String
    let draft: String
    var submittedText: String?

    func validated() throws -> Self {
        guard relayAddress.utf8.count <= 2048, let url = URLComponents(string:relayAddress),
              url.scheme.map({ ["http","https"].contains($0) }) == true,
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let source = try VaultPDFExcerpt.parse(draft), source.notePath == path,
              submittedText == nil || submittedText?.utf8.elementsEqual(draft.utf8) == true
        else { throw VaultBlockRecoveryError.corrupt }
        return self
    }
}

struct VaultPDFCreateRecoveryFile: Codable {
    let schema: String
    let payload: Data?
    let sha256: String

    init(_ record: VaultPDFCreateRecovery?) throws {
        schema = "ccr.pdf-create-recovery/v1"
        payload = try record.map { try JSONEncoder().encode($0.validated()) }
        sha256 = CanvasPacket.sha(payload ?? Data())
    }

    func record() throws -> VaultPDFCreateRecovery? {
        guard schema == "ccr.pdf-create-recovery/v1", CanvasPacket.sha(payload ?? Data()) == sha256
        else { throw VaultBlockRecoveryError.corrupt }
        return try payload.map { try JSONDecoder().decode(VaultPDFCreateRecovery.self,from:$0).validated() }
    }
}

struct VaultPDFSnapshot: Decodable {
    static let byteLimit = 20 * 1024 * 1024
    let path: String
    let sha256: String
    let dataBase64: String

    static func validPath(_ path: String) -> Bool {
        VaultNoteReference.validPath(String(path.dropLast(4)) + ".md") && path.hasSuffix(".pdf") &&
        !path.contains(where:{ $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) &&
        !path.contains("[") && !path.contains("]") && !path.contains("#") && !path.contains("|")
    }

    func bytes(at expected: String) throws -> Data {
        guard path == expected, Self.validPath(path), dataBase64.utf8.count <= (Self.byteLimit + 2) / 3 * 4,
              let bytes = Data(base64Encoded:dataBase64), bytes.count <= Self.byteLimit,
              bytes.starts(with:Data("%PDF-".utf8)), CanvasPacket.sha(bytes) == sha256 else {
            throw VaultPDFError.invalid
        }
        return bytes
    }
}

enum VaultPDFError: LocalizedError {
    case invalid, selection, changed, missing, unsupported, unconfirmed, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: return "PDF 출처 형식 또는 좌표를 확인하지 못했습니다."
        case .selection: return "한 PDF 페이지에서 텍스트를 선택하세요."
        case .changed: return "원본 변경 · PDF 원본이 바뀌었습니다. 기존 좌표로 확정하지 않으며 카드와 캐시는 보존합니다."
        case .missing: return "원본 없음 · PDF 원본이 없습니다. 카드와 캐시는 보존합니다."
        case .unconfirmed: return "발췌 노트의 저장 결과를 확인하지 못했습니다. 같은 ID로 저장 재확인을 선택하세요."
        case .tooLarge: return "20 MiB 이하의 PDF만 열 수 있습니다."
        case .unavailable: return "Mac PDF 연결 권한 또는 응답을 확인하지 못했습니다. 저장된 카드와 캐시는 유지됩니다."
        case .unsupported: return "이 후보는 회전 없는 PDF 텍스트 발췌만 지원합니다."
        }
    }
}

struct VaultPDFExcerpt: Codable, Equatable {
    struct TextRange: Codable, Equatable {
        let location: Int
        let length: Int
        init(_ range: NSRange) { location = range.location; length = range.length }
        var ns: NSRange { NSRange(location:location,length:length) }
        var valid: Bool { location >= 0 && location != NSNotFound && length > 0 && length <= Int.max - location }
    }
    struct Rect: Codable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        init(_ rect: CGRect) {
            x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height
        }
        var cg: CGRect { CGRect(x:x,y:y,width:width,height:height) }
        var valid: Bool {
            [x,y,width,height].allSatisfy(\.isFinite) && width > 0 && height > 0 &&
            abs(x) <= 1_000_000 && abs(y) <= 1_000_000 && width <= 1_000_000 && height <= 1_000_000
        }
    }
    let schemaVersion: Int
    let excerptID: UUID
    let pdfPath: String
    let pdfSha256: String
    let pageIndex: Int
    let mediaBox: Rect
    let cropBox: Rect
    let rotation: Int
    let selectionRects: [Rect]
    let quote: String
    var textRanges: [TextRange]? = nil

    static let fence = "```ccr-pdf-source-v1\n"
    var notePath: String {
        let parent = pdfPath.split(separator:"/").dropLast().joined(separator:"/")
        return (parent.isEmpty ? "" : parent + "/") + "발췌-\(excerptID.uuidString.lowercased()).md"
    }

    func validated() throws -> Self {
        guard (schemaVersion == 1 && textRanges == nil || schemaVersion == 2 &&
               textRanges.map({ !$0.isEmpty && $0.count <= 256 && $0.allSatisfy(\.valid) }) == true),
              VaultPDFSnapshot.validPath(pdfPath),
              pdfSha256.count == 64, pdfSha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              pageIndex >= 0, pageIndex < 100_000, rotation == 0,
              mediaBox.valid, cropBox.valid, mediaBox.cg.contains(cropBox.cg),
              !selectionRects.isEmpty, selectionRects.count <= 256,
              selectionRects.allSatisfy({ $0.valid && cropBox.cg.contains($0.cg) }),
              !quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              quote.utf8.count <= 64 * 1024 else { throw VaultPDFError.invalid }
        return self
    }

    func markdown() throws -> String {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let source = String(decoding:try encoder.encode(self),as:UTF8.self)
        let quoted = quote.components(separatedBy:.newlines).map { line in
            "> " + line.unicodeScalars.map { scalar in
                scalar.isASCII && !CharacterSet.alphanumerics.contains(scalar) ? "&#\(scalar.value);" : String(scalar)
            }.joined()
        }.joined(separator:"\n")
        return "# PDF 발췌\n\n원문: [[\(pdfPath)#page=\(pageIndex + 1)]]\n\n\(quoted)\n\n## 메모\n\n\n" +
            "```ccr-pdf-source-v\(schemaVersion)\n" + source + "\n```\n"
    }

    static func parse(_ text: String) throws -> Self? {
        guard text.utf8.count <= 1024 * 1024 else { throw VaultPDFError.invalid }
        let lines = text.components(separatedBy:"\n")
        let fences = lines.indices.filter {
            lines[$0].range(of:"^ {0,3}(`{3,}|~{3,})ccr-pdf-source",options:.regularExpression) != nil
        }
        guard !fences.isEmpty else { return nil }
        guard fences.count == 1, let start = fences.first,
              let version = [1,2].first(where:{ lines[start] == "```ccr-pdf-source-v\($0)" }),
              let end = lines.indices.dropFirst(start + 1).first(where:{ lines[$0] == "```" })
        else { throw VaultPDFError.invalid }
        let bytes = Data(lines[(start + 1)..<end].joined(separator:"\n").utf8)
        guard bytes.count <= 96 * 1024 else { throw VaultPDFError.invalid }
        var allowed: Set<String> = ["schemaVersion","excerptID","pdfPath","pdfSha256","pageIndex","mediaBox","cropBox","rotation","selectionRects","quote"]
        if version == 2 { allowed.insert("textRanges") }
        guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              Set(object.keys) == allowed else { throw VaultPDFError.invalid }
        let rectKeys: Set<String> = ["x","y","width","height"]
        guard let media = object["mediaBox"] as? [String:Any], Set(media.keys) == rectKeys,
              let crop = object["cropBox"] as? [String:Any], Set(crop.keys) == rectKeys,
              let rects = object["selectionRects"] as? [[String:Any]],
              rects.allSatisfy({ Set($0.keys) == rectKeys }) else { throw VaultPDFError.invalid }
        if version == 2 {
            guard let ranges = object["textRanges"] as? [[String:Any]],
                  ranges.allSatisfy({ Set($0.keys) == ["location","length"] }) else { throw VaultPDFError.invalid }
        }
        let value = try JSONDecoder().decode(Self.self,from:bytes).validated()
        guard value.schemaVersion == version else { throw VaultPDFError.invalid }
        return value
    }

    static func capture(snapshot: VaultPDFSnapshot, document: PDFDocument, selection: PDFSelection) throws -> Self {
        _ = try snapshot.bytes(at:snapshot.path)
        guard selection.pages.count == 1, let page = selection.pages.first,
              let quote = selection.string, document.index(for:page) != NSNotFound else { throw VaultPDFError.selection }
        guard page.rotation == 0 else { throw VaultPDFError.unsupported }
        let rects = selection.selectionsByLine().map { Rect($0.bounds(for:page)) }
        let ranges = (0..<selection.numberOfTextRanges(on:page)).map { TextRange(selection.range(at:$0,on:page)) }
        let value = try Self(schemaVersion:2,excerptID:UUID(),pdfPath:snapshot.path,pdfSha256:snapshot.sha256,
            pageIndex:document.index(for:page),mediaBox:Rect(page.bounds(for:.mediaBox)),
            cropBox:Rect(page.bounds(for:.cropBox)),rotation:page.rotation,selectionRects:rects,quote:quote,textRanges:ranges).validated()
        _ = try value.sourcePage(in:snapshot)
        return value
    }

    func sourcePage(in snapshot: VaultPDFSnapshot) throws -> (PDFDocument, PDFPage, PDFSelection) {
        _ = try validated()
        let bytes = try snapshot.bytes(at:pdfPath)
        guard snapshot.sha256 == pdfSha256 else { throw VaultPDFError.changed }
        guard let document = PDFDocument(data:bytes), let page = document.page(at:pageIndex),
              Rect(page.bounds(for:.mediaBox)) == mediaBox, Rect(page.bounds(for:.cropBox)) == cropBox,
              page.rotation == rotation else { throw VaultPDFError.changed }
        let selection = PDFSelection(document:document)
        if let ranges = textRanges {
            for range in ranges {
                guard let part = page.selection(for:range.ns), part.numberOfTextRanges(on:page) == 1,
                      part.range(at:0,on:page) == range.ns else { throw VaultPDFError.changed }
                selection.add(part)
            }
            guard selection.string?.utf8.elementsEqual(quote.utf8) == true,
                  selection.selectionsByLine().map({ Rect($0.bounds(for:page)) }) == selectionRects
            else { throw VaultPDFError.changed }
        } else {
            for rect in selectionRects {
                guard let part = page.selection(for:rect.cg) else { throw VaultPDFError.changed }
                selection.add(part)
            }
            guard selection.string?.trimmingCharacters(in:.whitespacesAndNewlines) == quote.trimmingCharacters(in:.whitespacesAndNewlines)
            else { throw VaultPDFError.changed }
        }
        return (document,page,selection)
    }
}
