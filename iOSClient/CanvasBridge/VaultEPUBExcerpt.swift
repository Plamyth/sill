import Foundation

struct VaultEPUBExcerpt: Codable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }
    struct TextRange: Codable, Equatable {
        let location: Int, length: Int
        var ns: NSRange { NSRange(location:location,length:length) }
    }
    let schemaVersion: Int
    let excerptID: UUID
    let sourceID: String, sourcePath: String, sourceSHA256: String
    let spineItem: String, chapterPath: String, xpath: String
    let range: TextRange
    let quote: String
    var notePath: String {
        let parent = sourcePath.split(separator:"/").dropLast().joined(separator:"/")
        return (parent.isEmpty ? "" : parent + "/") + "발췌-\(excerptID.uuidString.lowercased()).md"
    }
    func validated() throws -> Self {
        guard schemaVersion == 1, VaultEPUBSnapshot.validPath(sourcePath),
              sourceID == "epub-" + CanvasPacket.sha(Data(sourcePath.utf8)),
              sourceSHA256.count == 64, sourceSHA256.allSatisfy({"0123456789abcdef".contains($0)}),
              !spineItem.isEmpty, spineItem.utf8.count <= 256, chapterPath.utf8.count <= 1024,
              !chapterPath.hasPrefix("/"), !chapterPath.contains(where:{ "\\:%#?".contains($0) }),
              chapterPath.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              xpath.utf8.count <= 2048, xpath.range(of:"^(/[-a-zA-Z0-9_]+\\[[1-9][0-9]*\\])+$",options:.regularExpression) != nil,
              range.location >= 0, range.length > 0, range.length <= 65536,
              range.location <= Int.max-range.length, !quote.isEmpty, quote.utf8.count <= 65536,
              quote.utf16.count == range.length else { throw VaultEPUBError.invalid }
        return self
    }
    static func capture(book: VaultEPUBBook, chapter: Int, paragraph: Int, range: NSRange,
                        excerptID: UUID = UUID()) throws -> Self {
        guard book.chapters.indices.contains(chapter), book.chapters[chapter].paragraphs.indices.contains(paragraph) else { throw VaultEPUBError.selection }
        let item = book.chapters[chapter], block = item.paragraphs[paragraph]
        guard let textRange = Range(range,in:block.text), !textRange.isEmpty else { throw VaultEPUBError.selection }
        return try Self(schemaVersion:1,excerptID:excerptID,sourceID:book.snapshot.sourceID,
            sourcePath:book.snapshot.path,sourceSHA256:book.snapshot.sha256,spineItem:item.id,
            chapterPath:item.path,xpath:block.xpath,range:.init(location:range.location,length:range.length),
            quote:String(block.text[textRange])).validated()
    }
    func resolve(in book: VaultEPUBBook) throws -> (chapter: Int, paragraph: Int, range: NSRange) {
        _ = try validated()
        guard sourcePath.utf8.elementsEqual(book.snapshot.path.utf8), sourceSHA256 == book.snapshot.sha256,
              sourceID == book.snapshot.sourceID,
              let chapter = book.chapters.firstIndex(where:{$0.id.utf8.elementsEqual(spineItem.utf8) && $0.path.utf8.elementsEqual(chapterPath.utf8)}),
              let paragraph = book.chapters[chapter].paragraphs.firstIndex(where:{$0.xpath == xpath}),
              let native = Range(range.ns,in:book.chapters[chapter].paragraphs[paragraph].text),
              String(book.chapters[chapter].paragraphs[paragraph].text[native]).utf8.elementsEqual(quote.utf8) else { throw VaultEPUBError.changed }
        return (chapter,paragraph,range.ns)
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
        return "# EPUB 발췌\n\n원문: [[\(sourcePath)]]\n장: \(chapterPath)\n출처 ID: \(sourceID)\n\n\(quoted)\n\n## 메모\n\n\n```ccr-epub-source-v1\n\(source)\n```\n"
    }
    static func parse(_ text: String) throws -> Self? {
        guard text.utf8.count <= 1024*1024 else { throw VaultEPUBError.tooLarge }
        let normalized = text.replacingOccurrences(of:"\r\n",with:"\n")
        var probeLines: [String] = []
        for line in normalized.components(separatedBy:"\n") {
            probeLines.append(line)
            if line.range(of:"^ {0,3}(`{3,}|~{3,})[ \t]*ccr-epub-source",options:.regularExpression) != nil { probeLines.append("x") }
        }
        let probe = probeLines.joined(separator:"\n")
        guard let document = try? AttributedString(markdown:probe,options:.init(interpretedSyntax:.full,appliesSourcePositionAttributes:true)) else { throw VaultEPUBError.invalid }
        var source: String?, identity: Int?
        for run in document.runs {
            guard let parts = run.presentationIntent?.components,
                  parts.count == 1, case .codeBlock(let hint) = parts[0].kind,
                  hint?.hasPrefix("ccr-epub-source") == true else { continue }
            if identity == parts[0].identity { continue }
            guard identity == nil, hint == "ccr-epub-source-v1", let position = run.markdownSourcePosition,
                  position.startColumn == 1, let range = Range<String.Index>(position,in:probe) else { throw VaultEPUBError.invalid }
            identity = parts[0].identity; source = String(probe[range])
        }
        guard let source else { return nil }
        let lines = source.components(separatedBy:"\n")
        guard lines.count >= 4, lines[0] == "```ccr-epub-source-v1", lines[1] == "x", lines.last == "```" else { throw VaultEPUBError.invalid }
        let raw = Data(lines.dropFirst(2).dropLast().joined(separator:"\n").utf8)
        guard raw.count <= 96*1024, let object = try JSONSerialization.jsonObject(with:raw) as? [String:Any],
              Set(object.keys) == ["schemaVersion","excerptID","sourceID","sourcePath","sourceSHA256","spineItem","chapterPath","xpath","range","quote"],
              let range = object["range"] as? [String:Any], Set(range.keys) == ["location","length"] else { throw VaultEPUBError.invalid }
        try uniqueKeys(raw)
        return try JSONDecoder().decode(Self.self,from:raw).validated()
    }
    private static func uniqueKeys(_ data: Data) throws {
        let text = Array(String(decoding:data,as:UTF8.self).utf8)
        var scopes: [Set<String>?] = [], keys = [Bool](), offset = 0
        while offset < text.count {
            switch text[offset] {
            case 123,91: scopes.append(text[offset] == 123 ? Set() : nil); keys.append(text[offset] == 123)
            case 125,93: scopes.removeLast(); keys.removeLast()
            case 44: if scopes.last! != nil { keys[keys.count-1] = true }
            case 34:
                let start = offset; var escaped = false; offset += 1
                while offset < text.count {
                    let c = text[offset]
                    if escaped { escaped = false } else if c == 92 { escaped = true } else if c == 34 { break }
                    offset += 1
                }
                if !scopes.isEmpty, scopes.last! != nil, keys.last == true {
                    let name = try JSONDecoder().decode(String.self,from:Data(text[start...offset]))
                    guard scopes[scopes.count-1]!.insert(name).inserted else { throw VaultEPUBError.invalid }
                    keys[keys.count-1] = false
                }
            default: break
            }
            offset += 1
        }
    }
    func reference(note: VaultNoteSnapshot, relayAddress: String) throws -> VaultNoteReference {
        guard note.path.utf8.elementsEqual(notePath.utf8) else { throw VaultEPUBError.changed }
        let verified = try note.validated(at:notePath)
        guard verified.reconciliationRequired != true,
              let parsed = try Self.parse(verified.text), parsed == self else { throw VaultEPUBError.changed }
        return VaultNoteReference(path:verified.path,sha256:verified.sha256,relayAddress:relayAddress,
            sourceState:.current,quoteSha256:CanvasPacket.sha(Data(quote.utf8)))
    }
}
