import Foundation
import CryptoKit
import Darwin
import CoreGraphics

enum CanvasRuntime {
    enum StateFile: String, CaseIterable {
        case scene = "CanvasScene.json"
        case outbox = "CanvasOutbox/ledger.json"
        case blockRecovery = "CanvasBlockEdit/recovery.json"
        case checkpoint = "CanvasVaultCheckpoint.json"
    }

    #if DEBUG
    enum LaunchState {
        case normal
        case isolated(TestContext)
        case invalid
    }

    struct TestContext {
        let id: UUID
        let commit: String
        let tree: String
        let relayAddress: String
        let token: String
        fileprivate let support: URL
        fileprivate let root: URL
    }

    enum TestError: LocalizedError {
        case invalid
        var errorDescription: String? { "격리 테스트 설정을 확인할 수 없습니다. 앱을 종료한 뒤 테스트 설정을 다시 준비하세요." }
    }

    static let contextByteLimit = 16 * 1024
    static let launch = resolve(arguments:ProcessInfo.processInfo.arguments,
        applicationSupport:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first,
        sourceCommit:Bundle.main.object(forInfoDictionaryKey:"CCRSourceCommit") as? String,
        sourceTree:Bundle.main.object(forInfoDictionaryKey:"CCRSourceTree") as? String)

    static func resolve(arguments: [String], applicationSupport: URL?,
                        sourceCommit: String?, sourceTree: String?) -> LaunchState {
        let flags = arguments.indices.filter { arguments[$0] == "--ccr-test-runtime" }
        guard !flags.isEmpty else { return .normal }
        guard flags.count == 1, let index = flags.first, index + 1 < arguments.count,
              let id = UUID(uuidString:arguments[index + 1]),
              arguments[index + 1].lowercased() == id.uuidString.lowercased(),
              let support = applicationSupport else { return .invalid }
        do {
            try requireDirectory(support)
            let support = support.resolvingSymlinksInPath().standardizedFileURL
            let root = support.appendingPathComponent("CCRIntegrationTests",isDirectory:true)
                .appendingPathComponent(id.uuidString.lowercased(),isDirectory:true)
            let file = root.appendingPathComponent("context.json")
            try checkPath(file, beneath:support, allowMissing:false)
            let data = try readFile(file,beneath:support,limit:contextByteLimit)
            struct Payload: Decodable {
                let schema: String
                let id: String
                let commit: String
                let tree: String
                let relayAddress: String
                let token: String
            }
            let value = try JSONDecoder().decode(Payload.self,from:data)
            guard value.schema == "ccr.ipad-test-context/v1", UUID(uuidString:value.id) == id,
                  isHash(value.commit), isHash(value.tree),
                  value.commit == sourceCommit, value.tree == sourceTree,
                  privateEndpoint(value.relayAddress), value.token.count >= 24 else { throw TestError.invalid }
            try checkPath(root.appendingPathComponent("state",isDirectory:true),beneath:support)
            let context = TestContext(id:id,commit:value.commit,tree:value.tree,
                relayAddress:value.relayAddress,token:value.token,support:support,root:root)
            for file in StateFile.allCases { _ = try isolatedURL(file,in:context) }
            return .isolated(context)
        } catch { return .invalid }
    }

    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    static func privateEndpoint(_ value: String) -> Bool {
        guard value.hasPrefix("http://"),
              let parts = URLComponents(string:value), parts.scheme == "http",
              parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil,
              let host = parts.host, let port = parts.port, (1...65535).contains(port) else { return false }
        let octets = host.split(separator:".",omittingEmptySubsequences:false)
        guard octets.count == 4 else { return false }
        let numbers = octets.compactMap { octet -> Int? in
            guard let number = Int(octet), (0...255).contains(number), String(number) == octet else { return nil }
            return number
        }
        guard numbers.count == 4, value == "http://\(host):\(port)" else { return false }
        return numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1])) ||
            (numbers[0] == 192 && numbers[1] == 168)
    }

    private static func requireDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw TestError.invalid }
    }

    private static func checkPath(_ url: URL, beneath root: URL, allowMissing: Bool = true) throws {
        let root = root.standardizedFileURL
        let url = url.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw TestError.invalid }
        try requireDirectory(root)
        let components = url.pathComponents.dropFirst(root.pathComponents.count)
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            let attributes: [FileAttributeKey:Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath:current.path) }
            catch CocoaError.fileReadNoSuchFile where allowMissing { continue }
            let kind = attributes[.type] as? FileAttributeType
            guard kind == (index == components.count - 1 && !url.hasDirectoryPath ? .typeRegular : .typeDirectory)
            else { throw TestError.invalid }
            if kind == .typeRegular, (attributes[.referenceCount] as? NSNumber)?.intValue != 1 {
                throw TestError.invalid
            }
        }
    }

    static func isolatedURL(_ file: StateFile, in context: TestContext) throws -> URL {
        let url = context.root.appendingPathComponent("state",isDirectory:true).appendingPathComponent(file.rawValue)
        try checkPath(url,beneath:context.support)
        return url
    }

    static func writeRuntimeReceipt(bundle: Bundle = .main) throws {
        do {
            guard case .isolated(let context) = launch,
                  bundle.object(forInfoDictionaryKey:"CCRSourceCommit") as? String == context.commit,
                  bundle.object(forInfoDictionaryKey:"CCRSourceTree") as? String == context.tree,
                  let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty,
                  let build = bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String, !build.isEmpty,
                  let executable = bundle.executableURL else { throw TestError.invalid }
            let executableBytes = try Data(contentsOf:executable)
            struct Receipt: Encodable {
                let schema = "ccr.ipad-test-runtime/v1"
                let id: String
                let commit: String
                let tree: String
                let bundleID: String
                let build: String
                let storageRoot: String
                let relayAddress: String
                let executableSHA256: String
                let processID: Int32
            }
            let state = context.root.appendingPathComponent("state",isDirectory:true)
            let receipt = Receipt(id:context.id.uuidString.lowercased(),commit:context.commit,tree:context.tree,
                bundleID:bundleID,build:build,storageRoot:state.path,relayAddress:context.relayAddress,
                executableSHA256:SHA256.hash(data:executableBytes).map { String(format:"%02x",$0) }.joined(),
                processID:getpid())
            let url = state.appendingPathComponent("runtime.json")
            try checkPath(url,beneath:context.support)
            try CanvasLocalFile.write(JSONEncoder().encode(receipt),to:url)
        } catch { throw TestError.invalid }
    }

    static func validateStateURL(_ url: URL) throws {
        switch launch {
        case .normal: return
        case .invalid: throw TestError.invalid
        case .isolated(let context):
            let receipt = context.root.appendingPathComponent("state",isDirectory:true).appendingPathComponent("runtime.json")
            if url == receipt {
                try checkPath(url,beneath:context.support)
                return
            }
            guard let file = StateFile.allCases.first(where: {
                context.root.appendingPathComponent("state").appendingPathComponent($0.rawValue).path == url.path
            }), try isolatedURL(file,in:context) == url else { throw TestError.invalid }
        }
    }

    private static func withParent<T>(of url: URL, beneath root: URL, create: Bool = false,
                                      _ operation: (Int32,String) throws -> T) throws -> T {
        guard url.standardizedFileURL.path == url.path, url.path.hasPrefix(root.path + "/")
        else { throw TestError.invalid }
        var directory = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw TestError.invalid }
        defer { close(directory) }
        for component in url.deletingLastPathComponent().pathComponents.dropFirst(root.pathComponents.count) {
            var next = openat(directory,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0 && errno == ENOENT && create {
                guard mkdirat(directory,component,0o700) == 0 || errno == EEXIST,
                      fsync(directory) == 0 else { throw TestError.invalid }
                next = openat(directory,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard next >= 0 else { throw TestError.invalid }
            close(directory)
            directory = next
        }
        return try operation(directory,url.lastPathComponent)
    }

    fileprivate static func readFile(_ url: URL, beneath root: URL, limit: Int? = nil) throws -> Data {
        try withParent(of:url,beneath:root) { directory, name in
            let fd = openat(directory,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw TestError.invalid }
            let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1
            else { throw TestError.invalid }
            if let limit {
                guard info.st_size <= limit, let data = try handle.read(upToCount:limit + 1), data.count <= limit
                else { throw TestError.invalid }
                return data
            }
            return try handle.readToEnd() ?? Data()
        }
    }

    fileprivate static func writeFile(_ data: Data, to url: URL, beneath root: URL) throws {
        try withParent(of:url,beneath:root,create:true) { directory, name in
            var info = stat()
            if fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw TestError.invalid }
            } else if errno != ENOENT { throw TestError.invalid }
            let temporary = ".\(UUID().uuidString).tmp"
            let fd = openat(directory,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
            guard fd >= 0 else { throw TestError.invalid }
            let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer { try? handle.close(); unlinkat(directory,temporary,0) }
            try handle.write(contentsOf:data)
            try handle.synchronize()
            guard renameat(directory,temporary,directory,name) == 0, fsync(directory) == 0 else { throw TestError.invalid }
        }
    }
    #endif

    static func stateURL(_ file: StateFile, blockRecoveryOverride: URL? = nil) throws -> URL {
        #if DEBUG
        switch launch {
        case .normal: break
        case .isolated(let context): return try isolatedURL(file,in:context)
        case .invalid: throw TestError.invalid
        }
        #endif
        if file == .blockRecovery, let override = blockRecoveryOverride { return override }
        guard let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first
        else { throw CanvasSendError.outboxUnavailable }
        if file == .scene { try? FileManager.default.createDirectory(at:support,withIntermediateDirectories:true) }
        return support.appendingPathComponent(file.rawValue)
    }
}

func canvasSelectedCharacterRange(in text: String, selection: NSRange) -> NSRange? {
    let count = text.utf16.count
    guard selection.location >= 0, selection.location < count, selection.length > 0,
          selection.length <= count - selection.location else { return nil }
    let end = selection.location + selection.length
    var offset = 0
    var lower: Int?
    for character in text {
        let next = offset + String(character).utf16.count
        if lower == nil, next > selection.location { lower = offset }
        if next >= end, let lower { return NSRange(location:lower,length:next - lower) }
        offset = next
    }
    return nil
}

struct CanvasPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct CanvasViewport: Equatable {
    var zoom = 1.0
    var pan = CGSize.zero

    func translated(by shift: CGSize) -> CanvasViewport {
        CanvasViewport(zoom: zoom,
                       pan: CGSize(width: pan.width + shift.width, height: pan.height + shift.height))
    }

    func scaled(by factor: Double, around anchor: CGPoint, centerShift: CGSize) -> CanvasViewport {
        guard factor.isFinite, factor > 0 else { return self }
        let nextZoom = min(3, max(0.5, zoom * factor))
        let difference = CGFloat(zoom - nextZoom)
        return CanvasViewport(zoom: nextZoom,
                              pan: CGSize(width: pan.width + difference * anchor.x + centerShift.width,
                                          height: pan.height + difference * anchor.y + centerShift.height))
    }
}

struct CanvasRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var center: CanvasPoint { CanvasPoint(x: x + width / 2, y: y + height / 2) }
}

struct InkPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var pressure: Double
}

struct InkStroke: Codable, Identifiable, Equatable {
    struct Visibility: Codable, Equatable {
        enum Kind: String, Codable { case full, masked }
        struct Segment: Codable, Equatable {
            var lowerBound: Double
            var upperBound: Double
            var worldPoints: [InkPoint]
        }
        var kind: Kind
        var visibleSegments: [Segment] = []
    }

    var id: UUID
    var points: [InkPoint]
    var createdAt: Date
    var visibility: Visibility? = nil

    // Legacy points are a best-effort fallback; nil visibility still means unknown.
    var visiblePointSegments: [[InkPoint]] {
        switch visibility?.kind {
        case .full: return [points]
        case .masked: return visibility?.visibleSegments.map(\.worldPoints) ?? []
        case nil: return [points]
        }
    }
}

struct VaultNoteReference: Codable, Equatable {
    enum SourceState: String, Codable { case current, changed, missing, ambiguous, unsupported, unavailable }
    let path: String
    var sha256: String
    let relayAddress: String
    var cacheTruncated: Bool? = nil
    var blockID: String? = nil
    var sourceState: SourceState? = nil
    var observedSha256: String? = nil
    var quoteSha256: String? = nil

    var sourceStateLabel: String {
        switch sourceState {
        case .current: return "원본 확인됨 · 표시 텍스트는 캐시입니다."
        case .changed: return "원본 변경됨 · 최신 표시 캐시입니다."
        case .missing: return "출처 없음 · 마지막 확인 발췌를 유지합니다."
        case .ambiguous: return "블록 ID 중복 · 마지막 확인 발췌를 유지합니다."
        case .unsupported: return "지원하지 않는 블록 · 마지막 확인 발췌를 유지합니다."
        case .unavailable, nil: return "원본 확인 필요 · 저장된 표시 캐시입니다."
        }
    }

    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.count <= 1024 && path.hasSuffix(".md") &&
        !path.contains("\\") && !path.contains("\0") &&
        path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".")
        }
    }
}

enum VaultBlockError: LocalizedError {
    case unsupported, ambiguous, missing, selection

    var errorDescription: String? {
        switch self {
        case .unsupported: return "일반 문단만 발췌할 수 있습니다. 복합 블록이나 분리된 표식은 지원하지 않습니다."
        case .ambiguous: return "같은 블록 ID가 여러 곳에 있어 출처를 확정할 수 없습니다."
        case .missing: return "원본에서 블록 표식을 찾지 못했습니다. 저장된 발췌는 유지합니다."
        case .selection: return "한 문단 안을 누르거나 해당 문단의 텍스트를 선택하세요."
        }
    }
}

struct VaultExcerptBlock: Equatable {
    let byteRange: Range<Int>
    let utf16Range: NSRange
    let quote: String
    let blockID: String?

    func selection(in text: String) -> NSRange? {
        guard Range(utf16Range,in:text) != nil else { return nil }
        return utf16Range
    }
}

struct VaultMarkdownBlocks {
    private struct Line {
        let range: Range<Int>
        let utf16Range: NSRange
        let text: String
        let excluded: Bool
        var blank: Bool { text.trimmingCharacters(in:.whitespaces).isEmpty }
    }
    let text: String
    private let blocks: [VaultExcerptBlock]
    private let markers: [String:Int]

    init(_ text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        var lines: [Line] = []
        var start = 0
        var utf16Offset = 0
        var fence: (UInt8, Int)?
        var frontmatter = false
        let opaqueDocument = text.contains("<") || text.contains("%%") || text.contains("$$")
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of:10) ?? bytes.count
            let contentEnd = end > start && bytes[end - 1] == 13 ? end - 1 : end
            let line = String(decoding:bytes[start..<contentEnd],as:UTF8.self)
            let trimmed = line.trimmingCharacters(in:.whitespaces)
            var excluded = opaqueDocument || frontmatter || fence != nil
            if start == 0 && (trimmed == "---" || trimmed == "\u{feff}---") {
                frontmatter = true
                excluded = true
            } else if frontmatter && (trimmed == "---" || trimmed == "...") {
                frontmatter = false
            } else if !frontmatter, let first = trimmed.utf8.first, first == 96 || first == 126 {
                let count = trimmed.utf8.prefix(while:{ $0 == first }).count
                if count >= 3 {
                    excluded = true
                    if let open = fence {
                        if open.0 == first && count >= open.1 && trimmed.utf8.count == count { fence = nil }
                    } else { fence = (first,count) }
                }
            }
            lines.append(Line(range:start..<contentEnd,utf16Range:NSRange(location:utf16Offset,length:line.utf16.count),
                              text:line,excluded:excluded))
            utf16Offset += line.utf16.count + (end - contentEnd) + (end < bytes.count ? 1 : 0)
            start = end + 1
        }
        let marker = try! NSRegularExpression(pattern:"(?:^|[ \\t])\\^([A-Za-z0-9-]+)(?=[ \\t]*\\r?$)",
                                               options:.anchorsMatchLines)
        let ns = text as NSString
        var counts: [String:Int] = [:]
        for match in marker.matches(in:text,range:NSRange(location:0,length:ns.length)) {
            counts[ns.substring(with:match.range(at:1)),default:0] += 1
        }
        markers = counts
        let structural = try! NSRegularExpression(pattern:"^(?:[ #>+*\\-_=~`!\\[\\\\:]|[0-9]+[.)](?:[ \\t]|$))")
        var parsed: [VaultExcerptBlock] = []
        var cursor = 0
        while cursor < lines.count {
            if lines[cursor].blank { cursor += 1; continue }
            let lower = cursor
            while cursor < lines.count && !lines[cursor].blank { cursor += 1 }
            let chunk = Array(lines[lower..<cursor])
            guard !chunk.contains(where: { $0.excluded }), let first = chunk.first, let last = chunk.last else { continue }
            var quoteEnd = last.range.upperBound
            var id: String?
            let lastText = last.text as NSString
            if let match = marker.firstMatch(in:last.text,range:NSRange(location:0,length:lastText.length)),
               match.range.location > 0 {
                id = lastText.substring(with:match.range(at:1))
                quoteEnd = last.range.lowerBound + lastText.substring(to:match.range.location).utf8.count
            }
            let quote = String(decoding:bytes[first.range.lowerBound..<quoteEnd],as:UTF8.self)
            let plainLines = quote.components(separatedBy:"\n")
            guard plainLines.allSatisfy({ raw in
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                return !line.isEmpty && !line.hasPrefix("\u{feff}") && !line.hasSuffix(" ") && !line.hasSuffix("\t") &&
                    !line.contains(where:{ "\t\r^`|<>[\\".contains($0) }) &&
                    structural.firstMatch(in:line,range:NSRange(location:0,length:(line as NSString).length)) == nil
            }) else { continue }
            var following = cursor
            while following < lines.count && lines[following].blank { following += 1 }
            if following < lines.count && lines[following].text.hasPrefix("^") { continue }
            parsed.append(VaultExcerptBlock(byteRange:first.range.lowerBound..<last.range.upperBound,
                                            utf16Range:NSRange(location:first.utf16Range.location,
                                                length:NSMaxRange(last.utf16Range) - first.utf16Range.location),
                                            quote:quote,blockID:id))
        }
        blocks = parsed
    }

    func selected(_ selection: NSRange) throws -> VaultExcerptBlock {
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= text.utf16.count, selection.length <= text.utf16.count - selection.location,
              Range(selection,in:text) != nil else { throw VaultBlockError.selection }
        guard let block = blocks.first(where:{ block in
            let range = block.utf16Range
            return selection.location >= range.location && selection.location <= NSMaxRange(range) &&
                NSMaxRange(selection) <= NSMaxRange(range)
        }) else { throw VaultBlockError.unsupported }
        if let id = block.blockID, markers[id] != 1 { throw VaultBlockError.ambiguous }
        return block
    }

    func resolve(_ id: String) throws -> VaultExcerptBlock {
        guard markers[id,default:0] > 0 else { throw VaultBlockError.missing }
        guard markers[id] == 1 else { throw VaultBlockError.ambiguous }
        guard let block = blocks.first(where:{ $0.blockID == id }) else { throw VaultBlockError.unsupported }
        return block
    }

    func anchored(_ block: VaultExcerptBlock) throws -> (text: String, blockID: String) {
        guard blocks.contains(block) else { throw VaultBlockError.selection }
        if let id = block.blockID { _ = try resolve(id); return (text,id) }
        let id = "sill-" + UUID().uuidString.lowercased()
        let bytes = Array(text.utf8)
        let insertion = Array(" ^\(id)".utf8)
        guard bytes.count + insertion.count <= 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return (String(decoding:bytes[..<block.byteRange.upperBound] + insertion + bytes[block.byteRange.upperBound...],
                       as:UTF8.self),id)
    }

    func replacing(_ id: String, with replacement: String) throws -> String {
        let sourceLF = text.replacingOccurrences(of:"\r\n",with:"\n")
        let replacementLF = replacement.replacingOccurrences(of:"\r\n",with:"\n")
        guard !sourceLF.contains("\r"), !replacementLF.contains("\r") else { throw VaultBlockError.unsupported }
        if text.contains("\r\n") {
            guard !text.replacingOccurrences(of:"\r\n",with:"").contains("\n"),
                  !replacement.replacingOccurrences(of:"\r\n",with:"").contains("\n") else { throw VaultBlockError.unsupported }
        } else {
            guard !replacement.contains("\r\n") else { throw VaultBlockError.unsupported }
        }
        let block = try resolve(id)
        let candidate = try VaultMarkdownBlocks(replacement + " ^" + id).resolve(id)
        guard candidate.quote.utf8.elementsEqual(replacement.utf8) else { throw VaultBlockError.unsupported }
        let bytes = Array(text.utf8)
        let start = block.byteRange.lowerBound
        let end = start + block.quote.utf8.count
        let result = bytes[..<start] + Array(replacement.utf8) + bytes[end...]
        guard result.count <= 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return String(decoding:result,as:UTF8.self)
    }
}

struct VaultBlockEdit: Codable, Equatable {
    let schemaVersion: Int
    let operationId: UUID
    let baseSha256: String
    let baseQuoteSha256: String
    let replacementText: String

    init(base: VaultNoteSnapshot, block: VaultExcerptBlock, text: String) {
        schemaVersion = 1
        operationId = UUID()
        baseSha256 = base.sha256
        baseQuoteSha256 = CanvasPacket.sha(Data(block.quote.utf8))
        replacementText = text
    }
}

struct VaultBlockEditResult: Decodable {
    let schemaVersion: Int
    let operationId: UUID
    let blockID: String
    let disposition: String
    let quoteSha256: String
    let note: VaultNoteSnapshot

    func validated(edit: VaultBlockEdit, base: VaultNoteSnapshot, blockID expectedID: String) throws -> VaultNoteSnapshot {
        let saved = try note.validated(at:base.path)
        let original = try VaultMarkdownBlocks(base.text).resolve(expectedID)
        let expected = try VaultMarkdownBlocks(base.text).replacing(expectedID,with:edit.replacementText)
        let block = try VaultMarkdownBlocks(saved.text).resolve(expectedID)
        guard edit.baseSha256 == base.sha256,
              edit.baseQuoteSha256 == CanvasPacket.sha(Data(original.quote.utf8)),
              schemaVersion == 1, operationId == edit.operationId, blockID == expectedID,
              ["committed","reconciled"].contains(disposition),
              quoteSha256 == CanvasPacket.sha(Data(edit.replacementText.utf8)),
              block.quote.utf8.elementsEqual(edit.replacementText.utf8),
              saved.text.utf8.elementsEqual(expected.utf8) else { throw URLError(.badServerResponse) }
        return saved
    }
}

struct VaultNoteSnapshot: Codable, Equatable {
    let path: String
    let text: String
    let sha256: String
    let modifiedAt: String

    var preview: String {
        Self.preview(text)
    }

    static func preview(_ text: String) -> String {
        var bytes = Data(text.utf8.prefix(512))
        while !bytes.isEmpty {
            if let text = String(data:bytes,encoding:.utf8) { return text }
            bytes.removeLast()
        }
        return ""
    }

    func validated(at expected: String) throws -> Self {
        guard path == expected, VaultNoteReference.validPath(path),
              text.utf8.count <= 1024 * 1024,
              CanvasPacket.sha(Data(text.utf8)) == sha256 else {
            throw URLError(.badServerResponse)
        }
        return self
    }
}

enum VaultBlockRecoveryError: LocalizedError {
    case unavailable, corrupt, context, changed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "문단 복구 파일을 저장하지 못했습니다. 입력은 유지하며 새 요청은 보내지 않습니다."
        case .corrupt: return "문단 복구 파일을 확인하지 못했습니다. 기존 파일을 보존하며 문단 저장을 중단합니다."
        case .context: return "보존된 입력의 장면·카드·원문·서버가 현재 연결과 다릅니다. 자동 연결하지 않습니다."
        case .changed: return "원문이 기준 또는 예상 결과와 다릅니다. 입력과 작업 ID를 보존하며 다시 쓰지 않습니다."
        }
    }
}

struct VaultBlockRecovery: Codable, Equatable {
    let schemaVersion: Int
    let sceneID: UUID
    let nodeID: UUID
    let relayAddress: String
    let blockID: String
    var base: VaultNoteSnapshot
    var draft: String
    var pending: VaultBlockEdit?

    func validated() throws -> Self {
        guard schemaVersion == 1, relayAddress.utf8.count <= 2048,
              let url = URLComponents(string:relayAddress), url.scheme.map({ ["http","https"].contains($0) }) == true,
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, draft.utf8.count <= 1024 * 1024 else {
            throw VaultBlockRecoveryError.corrupt
        }
        _ = try base.validated(at:base.path)
        let block = try VaultMarkdownBlocks(base.text).resolve(blockID)
        _ = try VaultMarkdownBlocks(base.text).replacing(blockID,with:block.quote)
        if let pending {
            guard pending.schemaVersion == 1, pending.baseSha256 == base.sha256,
                  pending.baseQuoteSha256 == CanvasPacket.sha(Data(block.quote.utf8)) else {
                throw VaultBlockRecoveryError.corrupt
            }
            _ = try VaultMarkdownBlocks(base.text).replacing(blockID,with:pending.replacementText)
        }
        return self
    }
}

struct VaultBlockRecoveryFile: Codable {
    let schemaVersion: Int
    let payload: Data?
    let sha256: String
    static let byteLimit = 24 * 1024 * 1024

    init(_ record: VaultBlockRecovery?) throws {
        schemaVersion = 1
        payload = try record.map { try JSONEncoder().encode($0.validated()) }
        sha256 = CanvasPacket.sha(payload ?? Data())
    }

    func record() throws -> VaultBlockRecovery? {
        guard schemaVersion == 1, CanvasPacket.sha(payload ?? Data()) == sha256 else {
            throw VaultBlockRecoveryError.corrupt
        }
        return try payload.map { try JSONDecoder().decode(VaultBlockRecovery.self,from:$0).validated() }
    }
}

struct CanvasNode: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case note, box }
    enum Confidence: String, Codable { case confirmed, proposal }

    var id: UUID
    var kind: Kind
    var frame: CanvasRect
    var text: String
    var confidence: Confidence
    var sourceStrokeIds: [UUID]
    var vaultNote: VaultNoteReference? = nil
    var isCollapsed: Bool? = nil
}

struct CanvasLink: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case general, parentChild }

    var id: UUID
    var from: UUID
    var to: UUID
    var label: String
    var kind: Kind? = nil
}

struct CanvasAnnotation: Codable, Identifiable, Equatable {
    var id: UUID
    var nodeId: UUID?
    var text: String
    var author: String
}

struct CanvasNodeTextEdit: Codable {
    var expected: CanvasNode
    var text: String
}

struct CanvasLinkEdit: Codable {
    var expected: CanvasLink
    var replacement: CanvasLink
}

struct CanvasScene: Codable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var revision = 0
    var width: Double = 2048
    var height: Double = 1536
    var drawingBase64 = ""
    var strokes: [InkStroke] = []
    var nodes: [CanvasNode] = []
    var links: [CanvasLink] = []
    var annotations: [CanvasAnnotation] = []

    struct Visibility: Equatable {
        let nodeIDs: Set<UUID>
        let linkIDs: Set<UUID>
        let annotationIDs: Set<UUID>
    }

    var visibility: Visibility {
        let nodeIDs = Set(nodes.map(\.id))
        var hierarchy = links.filter { $0.kind == .parentChild }
        if !Self.validHierarchy(hierarchy, nodeIds: nodeIDs) {
            let ordered = hierarchy.sorted {
                ($0.id.uuidString, $0.from.uuidString, $0.to.uuidString) <
                    ($1.id.uuidString, $1.from.uuidString, $1.to.uuidString)
            }
            hierarchy = []
            for link in ordered where Self.validHierarchy(hierarchy + [link], nodeIds: nodeIDs) {
                hierarchy.append(link)
            }
        }
        let children = Dictionary(grouping: hierarchy, by: \.from)
        var hidden = Set<UUID>()
        var pending = nodes.filter { $0.isCollapsed == true }
            .flatMap { children[$0.id, default: []].map(\.to) }
        while let node = pending.popLast() {
            guard hidden.insert(node).inserted else { continue }
            pending.append(contentsOf: children[node, default: []].map(\.to))
        }
        let visible = nodeIDs.subtracting(hidden)
        return Visibility(nodeIDs: visible,
            linkIDs: Set(links.filter { visible.contains($0.from) && visible.contains($0.to) }.map(\.id)),
            annotationIDs: Set(annotations.filter { $0.nodeId.map(visible.contains) == true }.map(\.id)))
    }

    func canToggleChildren(of id: UUID) -> Bool {
        nodes.contains { $0.id == id && $0.isCollapsed == true } ||
            links.contains { link in
                link.kind == .parentChild && link.from == id && link.to != id &&
                    nodes.contains { $0.id == link.to }
            }
    }

    @discardableResult
    mutating func toggleChildren(of id: UUID) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == id }),
              canToggleChildren(of: id) else { return false }
        nodes[index].isCollapsed = nodes[index].isCollapsed != true
        revision += 1
        return true
    }

    mutating func addNode(kind: CanvasNode.Kind, at point: CanvasPoint, text: String = "",
                          confidence: CanvasNode.Confidence = .confirmed,
                          sourceStrokeIds: [UUID] = []) -> UUID {
        let id = UUID()
        nodes.append(CanvasNode(id: id, kind: kind,
            frame: CanvasRect(x: point.x, y: point.y, width: 260, height: 120),
            text: text, confidence: confidence, sourceStrokeIds: sourceStrokeIds))
        revision += 1
        return id
    }

    mutating func moveNode(_ id: UUID, to point: CanvasPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].frame.x = point.x
        nodes[index].frame.y = point.y
        revision += 1
    }

    mutating func connect(_ from: UUID, to: UUID, label: String = "") -> Bool {
        guard from != to, nodes.contains(where: { $0.id == from }),
              nodes.contains(where: { $0.id == to }) else { return false }
        links.append(CanvasLink(id: UUID(), from: from, to: to, label: label))
        revision += 1
        return true
    }

    mutating func connectAsChild(parent: UUID, child: UUID, label: String = "") -> Bool {
        let link = CanvasLink(id: UUID(), from: parent, to: child, label: label, kind: .parentChild)
        guard Self.validHierarchy(links + [link], nodeIds: Set(nodes.map(\.id))) else { return false }
        links.append(link)
        revision += 1
        return true
    }

    private static func validHierarchy(_ links: [CanvasLink], nodeIds: Set<UUID>) -> Bool {
        var parents: [UUID: UUID] = [:]
        for link in links where link.kind == .parentChild {
            guard link.from != link.to, nodeIds.contains(link.from), nodeIds.contains(link.to),
                  parents[link.to] == nil else { return false }
            parents[link.to] = link.from
        }
        var checked = Set<UUID>()
        for node in parents.keys {
            var path = Set<UUID>()
            var cursor = node
            while !checked.contains(cursor) {
                guard path.insert(cursor).inserted else { return false }
                guard let parent = parents[cursor] else { break }
                cursor = parent
            }
            checked.formUnion(path)
        }
        return true
    }

    mutating func confirmNode(_ id: UUID, text: String) -> Bool {
        guard let node = nodes.first(where: { $0.id == id }) else { return false }
        return editGraph(nodeEdits:[CanvasNodeTextEdit(expected:node,text:text)],linkEdits:[])
    }

    static func sameNode(_ lhs: CanvasNode, _ rhs: CanvasNode) -> Bool {
        lhs == rhs && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    static func sameLink(_ lhs: CanvasLink, _ rhs: CanvasLink) -> Bool {
        lhs == rhs && lhs.label.utf8.elementsEqual(rhs.label.utf8)
    }

    func hasSameGraph(as other: CanvasScene) -> Bool {
        nodes.count == other.nodes.count && links.count == other.links.count &&
            zip(nodes,other.nodes).allSatisfy { Self.sameNode($0,$1) } &&
            zip(links,other.links).allSatisfy { Self.sameLink($0,$1) } && annotations == other.annotations &&
            zip(annotations,other.annotations).allSatisfy {
                $0.text.utf8.elementsEqual($1.text.utf8) && $0.author.utf8.elementsEqual($1.author.utf8)
            }
    }

    @discardableResult
    mutating func editGraph(nodeEdits: [CanvasNodeTextEdit], linkEdits: [CanvasLinkEdit]) -> Bool {
        guard !nodeEdits.isEmpty || !linkEdits.isEmpty,
              Set(nodes.map(\.id)).count == nodes.count,
              Set(links.map(\.id)).count == links.count,
              Set(nodeEdits.map { $0.expected.id }).count == nodeEdits.count,
              Set(linkEdits.map { $0.expected.id }).count == linkEdits.count else { return false }
        var nextNodes = nodes
        var nextLinks = links
        for edit in nodeEdits {
            guard edit.text.utf8.count <= 16_384, edit.expected.vaultNote == nil,
                  let index = nextNodes.firstIndex(where: { $0.id == edit.expected.id }),
                  Self.sameNode(nextNodes[index],edit.expected) else { return false }
            nextNodes[index].text = edit.text
            nextNodes[index].confidence = .confirmed
        }
        let ids = Set(nodes.map(\.id))
        for edit in linkEdits {
            let value = edit.replacement
            guard value.id == edit.expected.id, value.label.utf8.count <= 4096,
                  value.from != value.to, ids.contains(value.from), ids.contains(value.to),
                  let index = nextLinks.firstIndex(where: { $0.id == edit.expected.id }),
                  Self.sameLink(nextLinks[index],edit.expected) else { return false }
            nextLinks[index] = value
        }
        guard Self.validHierarchy(nextLinks,nodeIds:ids) else { return false }
        nodes = nextNodes
        links = nextLinks
        revision += 1
        return true
    }

    mutating func apply(_ change: AgentRevision, basedOn sent: CanvasScene? = nil) -> Bool {
        guard change.sceneId == id else { return false }
        let annotationIds = change.annotations.map(\.id)
        let proposalIds = change.proposedNodes.map(\.id)
        let proposedLinks = change.proposedLinks ?? []
        let linkIds = proposedLinks.map(\.id)
        let nodeEdits = change.nodeEdits ?? []
        let linkEdits = change.linkEdits ?? []
        guard Set(annotationIds).count == annotationIds.count,
              Set(proposalIds).count == proposalIds.count,
              Set(linkIds).count == linkIds.count,
              Set(nodeEdits.map { $0.expected.id }).count == nodeEdits.count,
              Set(linkEdits.map { $0.expected.id }).count == linkEdits.count,
              Set(proposalIds).isDisjoint(with:nodeEdits.map { $0.expected.id }),
              Set(linkIds).isDisjoint(with:linkEdits.map { $0.expected.id }) else { return false }
        if change.baseRevision < revision {
            guard !annotationIds.isEmpty || !proposalIds.isEmpty || !linkIds.isEmpty ||
                    !nodeEdits.isEmpty || !linkEdits.isEmpty else { return false }
            if change.annotations.allSatisfy({ incoming in
                annotations.contains { $0 == incoming && $0.text.utf8.elementsEqual(incoming.text.utf8) &&
                    $0.author.utf8.elementsEqual(incoming.author.utf8) }
            }) && change.proposedNodes.allSatisfy({ incoming in
                nodes.contains { Self.sameNode($0,incoming) }
            }) && proposedLinks.allSatisfy({ incoming in
                links.contains { Self.sameLink($0,incoming) }
            }) && nodeEdits.allSatisfy({ edit in
                guard edit.expected.vaultNote == nil else { return false }
                var desired = edit.expected
                desired.text = edit.text
                desired.confidence = .confirmed
                return nodes.contains { Self.sameNode($0,desired) }
            }) && linkEdits.allSatisfy({ edit in
                edit.expected.id == edit.replacement.id && links.contains { Self.sameLink($0,edit.replacement) }
            }) { return true }
            guard nodeEdits.isEmpty, linkEdits.isEmpty else { return false }
            guard let sent, sent.id == id, sent.revision == change.baseRevision,
                  sent.schemaVersion == schemaVersion,
                  sent.width == width, sent.height == height,
                  sent.hasSameGraph(as:self),
                  strokes.count > sent.strokes.count,
                  Array(strokes.prefix(sent.strokes.count)) == sent.strokes else {
                return false
            }
        }
        guard change.baseRevision <= revision else { return false }
        let existingIds = Set(nodes.map(\.id))
        let existingAnnotationIds = Set(annotations.map(\.id))
        let existingLinkIds = Set(links.map(\.id))
        let originalStrokes = change.baseRevision == revision ? strokes : sent?.strokes ?? []
        let sentStrokeIds = Set(originalStrokes.map(\.id))
        guard change.annotations.allSatisfy({ !existingAnnotationIds.contains($0.id) }),
              proposedLinks.allSatisfy({ !existingLinkIds.contains($0.id) }),
              change.proposedNodes.allSatisfy({ $0.vaultNote == nil && $0.confidence == .proposal && !existingIds.contains($0.id) &&
                  $0.sourceStrokeIds.allSatisfy(sentStrokeIds.contains) }) else {
            return false
        }
        let availableIds = existingIds.union(proposalIds)
        guard change.annotations.allSatisfy({ $0.nodeId.map(availableIds.contains) ?? true }),
              proposedLinks.allSatisfy({ $0.from != $0.to && availableIds.contains($0.from) &&
                  availableIds.contains($0.to) }),
              Self.validHierarchy(links + proposedLinks, nodeIds: availableIds) else {
            return false
        }
        var next = self
        if !nodeEdits.isEmpty || !linkEdits.isEmpty {
            guard next.editGraph(nodeEdits:nodeEdits,linkEdits:linkEdits) else { return false }
        }
        next.annotations.append(contentsOf: change.annotations)
        next.nodes.append(contentsOf: change.proposedNodes)
        next.links.append(contentsOf: proposedLinks)
        guard Self.validHierarchy(next.links,nodeIds:availableIds) else { return false }
        next.revision = revision + 1
        self = next
        return true
    }
}

struct AgentRevision: Codable {
    var sceneId: UUID
    var baseRevision: Int
    var annotations: [CanvasAnnotation]
    var proposedNodes: [CanvasNode]
    var proposedLinks: [CanvasLink]? = nil
    var nodeEdits: [CanvasNodeTextEdit]? = nil
    var linkEdits: [CanvasLinkEdit]? = nil
}

struct CanvasDiagramSnapshot: Codable, Equatable {
    struct Node: Codable, Equatable {
        let diagramID: String
        let id: UUID
        let text: String
    }
    let sceneID: UUID
    let revision: Int
    let source: String
    let nodes: [Node]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sceneID == rhs.sceneID && lhs.revision == rhs.revision &&
            lhs.source.utf8.elementsEqual(rhs.source.utf8) && lhs.nodes == rhs.nodes &&
            zip(lhs.nodes,rhs.nodes).allSatisfy { $0.text.utf8.elementsEqual($1.text.utf8) }
    }

    enum Failure: LocalizedError {
        case limit, invalidGraph
        var errorDescription: String? {
            switch self {
            case .limit: return "다이어그램 표시 한도를 넘었습니다. 원본 그림과 구조 데이터는 보존됩니다."
            case .invalidGraph: return "중복 요소나 끊어진 관계가 있어 다이어그램을 표시하지 않았습니다."
            }
        }
    }

    init(scene: CanvasScene) throws {
        guard scene.nodes.count <= 512, scene.links.count <= 1024 else { throw Failure.limit }
        let ids = Set(scene.nodes.map(\.id))
        guard ids.count == scene.nodes.count, Set(scene.links.map(\.id)).count == scene.links.count,
              scene.links.allSatisfy({ ids.contains($0.from) && ids.contains($0.to) }) else {
            throw Failure.invalidGraph
        }
        func diagramID(_ id: UUID) -> String { "n" + id.uuidString.lowercased().replacingOccurrences(of:"-",with:"") }
        func label(_ text: String) -> String {
            text.unicodeScalars.map { value in
                if value.value < 128 && !CharacterSet.alphanumerics.contains(value) && value != " " {
                    return "#\(value.value);"
                }
                return String(value)
            }.joined()
        }
        let visible = scene.visibility
        nodes = scene.nodes.filter { visible.nodeIDs.contains($0.id) }.map {
            Node(diagramID:diagramID($0.id),id:$0.id,text:$0.text)
        }
        var lines = ["flowchart TD"]
        lines += nodes.map { "\($0.diagramID)[\"\(label($0.text.isEmpty ? "이름 없는 요소" : $0.text))\"]" }
        lines += scene.links.filter { visible.linkIDs.contains($0.id) }.map {
            let relation = $0.label.isEmpty ? ($0.kind == .parentChild ? "하위 요소" : "연결") : $0.label
            return "\(diagramID($0.from)) -->|\"\(label(relation))\"| \(diagramID($0.to))"
        }
        source = lines.joined(separator:"\n")
        guard source.utf8.count <= 50_000 else { throw Failure.limit }
        sceneID = scene.id
        revision = scene.revision
    }
}

struct VoiceSession: Codable, Equatable {
    let threadId: UUID
    let sessionId: String
    let observedAt: String

    func samePair(as other: VoiceSession) -> Bool {
        threadId == other.threadId && sessionId == other.sessionId
    }
}

struct VoiceProjection: Codable {
    let generatedAt: String
    let activeVoiceSession: VoiceSession?

    func session(matching displayed: VoiceSession?, now: Date = Date()) throws -> VoiceSession {
        func recent(_ text: String) -> Bool {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            let fractional = formatter.date(from:text)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? formatter.date(from:text) else { return false }
            return now.timeIntervalSince(date) <= 30 && date.timeIntervalSince(now) <= 5
        }
        guard recent(generatedAt), let session = activeVoiceSession,
              !session.sessionId.isEmpty, recent(session.observedAt) else { throw CanvasSendError.unavailable }
        if let displayed, !displayed.samePair(as:session) { throw CanvasSendError.changedSession }
        return session
    }
}

enum CanvasSendError: LocalizedError {
    case unavailable, changedSession, missingTarget, invalidPacket, unresolvedPacket, receiptMismatch, outboxUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "현재 열린 음성 세션을 확인하지 못했습니다."
        case .changedSession: return "표시한 음성 대화 또는 세션이 바뀌었습니다. 다시 확인하세요."
        case .missingTarget: return "음성 대화가 없으면 받는 대화 카드를 먼저 선택하세요."
        case .invalidPacket: return "장면 1 MiB, PNG 5 MiB 한도 또는 패킷 바이트를 확인하세요."
        case .unresolvedPacket: return "이전 패킷의 접수 결과를 먼저 확인해야 합니다. 자동 재전송하지 않습니다."
        case .receiptMismatch: return "영수증의 패킷·대화·세션·해시가 일치하지 않습니다."
        case .outboxUnavailable: return "전송 원장을 읽거나 저장하지 못했습니다. 전송을 중단했습니다."
        }
    }
}

struct CanvasPacket: Codable, Equatable {
    let packetId: UUID
    let threadId: UUID
    let sessionId: String
    let targetMode: String?
    let imageSha256: String
    let sceneSha256: String
    let imagePNGBase64: String
    let sceneJSONBase64: String

    init(scene: CanvasScene, imagePNG: Data, session: VoiceSession, targetMode: String? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sceneBytes = try encoder.encode(scene)
        guard imagePNG.count <= 5*1024*1024, sceneBytes.count <= 1024*1024,
              imagePNG.starts(with:[137,80,78,71,13,10,26,10]), !session.sessionId.isEmpty else {
            throw CanvasSendError.invalidPacket
        }
        packetId = UUID()
        threadId = session.threadId
        sessionId = session.sessionId
        self.targetMode = targetMode
        imageSha256 = Self.sha(imagePNG)
        sceneSha256 = Self.sha(sceneBytes)
        imagePNGBase64 = imagePNG.base64EncodedString()
        sceneJSONBase64 = sceneBytes.base64EncodedString()
    }

    static func sha(_ bytes: Data) -> String {
        SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
    }

    func frozenScene() throws -> CanvasScene {
        guard let image = Data(base64Encoded:imagePNGBase64), image.count <= 5*1024*1024,
              let bytes = Data(base64Encoded:sceneJSONBase64), bytes.count <= 1024*1024,
              Self.sha(image) == imageSha256, Self.sha(bytes) == sceneSha256 else {
            throw CanvasSendError.invalidPacket
        }
        return try JSONDecoder().decode(CanvasScene.self,from:bytes)
    }
}

enum PacketState: String, Codable {
    case stored, dispatching, queued, steered, started, unknown, rejected
    var terminal: Bool { self == .queued || self == .steered || self == .started || self == .rejected }
}

struct PacketReceipt: Codable {
    struct Continuity: Codable {
        let status: String
        let atomic: Bool
        let before: VoiceSession?
        let after: VoiceSession?
    }
    let packetId: UUID
    let threadId: UUID
    let sessionId: String
    let targetMode: String?
    let state: PacketState
    let imageSha256: String
    let sceneSha256: String
    let queuedId: UUID?
    let turnId: UUID?
    let canonicalPacketId: UUID?
    let clientUserMessageId: UUID
    let deliveryScope: String
    let sessionContinuity: Continuity
    let reason: String?

    func matches(_ packet: CanvasPacket) -> Bool {
        packetId == packet.packetId && threadId == packet.threadId && sessionId == packet.sessionId &&
        targetMode == packet.targetMode &&
        imageSha256 == packet.imageSha256 && sceneSha256 == packet.sceneSha256 &&
        clientUserMessageId == (canonicalPacketId ?? packet.packetId) &&
        ["exact-chat-queue-only", "active-turn-steer", "exact-chat-start"].contains(deliveryScope) &&
        !sessionContinuity.atomic &&
        (state != .queued || (deliveryScope == "exact-chat-queue-only" && queuedId != nil)) &&
        (state != .steered || (deliveryScope == "active-turn-steer" && turnId != nil)) &&
        (state != .started || (deliveryScope == "exact-chat-start" && turnId != nil))
    }
}

struct CanvasOutboxEntry: Codable, Identifiable {
    enum Phase: String, Codable { case prepared, submitting, reconciling, settled }
    var id: UUID { packet.packetId }
    let packet: CanvasPacket
    let relayAddress: String
    var phase: Phase = .prepared
    var receipt: PacketReceipt?
}

struct CanvasOutbox: Codable {
    private(set) var entries: [CanvasOutboxEntry] = []
    var unresolved: CanvasOutboxEntry? { entries.first { $0.phase != .settled } }

    func existing(for scene: CanvasScene, threadId: UUID, sessionId: String) throws -> CanvasOutboxEntry? {
        if let unresolved { return unresolved }
        return try entries.last { entry in
            let frozen = try entry.packet.frozenScene()
            return frozen == scene &&
                entry.packet.threadId == threadId && entry.packet.sessionId == sessionId &&
                entry.receipt?.state != .rejected
        }
    }

    mutating func reserve(_ packet: CanvasPacket, relayAddress: String) throws {
        let scene = try packet.frozenScene()
        guard try existing(for:scene,threadId:packet.threadId,sessionId:packet.sessionId) == nil else { throw CanvasSendError.unresolvedPacket }
        entries.append(CanvasOutboxEntry(packet:packet,relayAddress:relayAddress))
    }

    mutating func beginSubmission(_ id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].phase == .prepared else {
            throw CanvasSendError.unresolvedPacket
        }
        entries[index].phase = .submitting
    }

    mutating func accept(_ receipt: PacketReceipt) throws {
        guard let index = entries.firstIndex(where: { $0.id == receipt.packetId }),
              receipt.matches(entries[index].packet) else { throw CanvasSendError.receiptMismatch }
        if entries[index].receipt?.state.terminal == true { return }
        entries[index].receipt = receipt
        entries[index].phase = receipt.state.terminal ? .settled : .reconciling
    }

    func validate() throws {
        guard Set(entries.map(\.id)).count == entries.count,
              entries.filter({ $0.phase != .settled }).count <= 1 else { throw CanvasSendError.outboxUnavailable }
        for entry in entries {
            _ = try entry.packet.frozenScene()
            if let receipt = entry.receipt, !receipt.matches(entry.packet) { throw CanvasSendError.receiptMismatch }
            if entry.phase == .settled && entry.receipt?.state.terminal != true {
                throw CanvasSendError.outboxUnavailable
            }
        }
    }
}

enum CanvasLocalFile {
    static func read(_ url: URL) throws -> Data {
        #if DEBUG
        try CanvasRuntime.validateStateURL(url)
        if case .isolated(let context) = CanvasRuntime.launch {
            return try CanvasRuntime.readFile(url,beneath:context.support)
        }
        #endif
        return try Data(contentsOf:url)
    }

    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path,O_RDONLY)
        guard fd >= 0 else { throw CanvasSendError.outboxUnavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CanvasSendError.outboxUnavailable }
    }

    static func write(_ data: Data, to url: URL) throws {
        #if DEBUG
        try CanvasRuntime.validateStateURL(url)
        if case .isolated(let context) = CanvasRuntime.launch {
            try CanvasRuntime.writeFile(data,to:url,beneath:context.support)
            return
        }
        #endif
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,
                                                attributes:[.posixPermissions:0o700])
        try syncDirectory(directory.deletingLastPathComponent())
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path,O_WRONLY | O_CREAT | O_EXCL,0o600)
        guard fd >= 0 else { throw CanvasSendError.outboxUnavailable }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at:temporary) }
        try handle.write(contentsOf:data)
        try handle.synchronize()
        guard rename(temporary.path,url.path) == 0 else { throw CanvasSendError.outboxUnavailable }
        try syncDirectory(directory)
    }
}
