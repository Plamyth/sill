import Foundation
import CryptoKit
import Darwin
import CoreGraphics
#if canImport(PencilKit, _version: 616)
import PencilKit
#endif

enum CanvasRuntime {
    enum StateFile: String, CaseIterable {
        case scene = "CanvasScene.json"
        case legacyScene = "CanvasLegacyScene.json"
        case outbox = "CanvasOutbox/ledger.json"
        case blockRecovery = "CanvasBlockEdit/recovery.json"
        case noteRecovery = "CanvasNoteEdit/recovery.json"
        case pdfExcerptRecovery = "CanvasPDFExcerptCreate/recovery.json"
        case checkpoint = "CanvasVaultCheckpoint.json"
        case workspace = "CanvasWorkspace/bookmark.json"
        case preferences = "CanvasPreferences.json"
    }

    enum Defaults {
        case normal(UserDefaults)
        case isolated(URL)
        case unavailable

        func object(forKey key: String) -> Any? {
            switch self {
            case .normal(let defaults): return defaults.object(forKey:key)
            case .isolated(let url):
                guard let data = try? CanvasLocalFile.read(url),
                      let values = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return nil }
                return values[key]
            case .unavailable: return nil
            }
        }

        func string(forKey key: String) -> String? { object(forKey:key) as? String }

        func set(_ value: Any, forKey key: String) throws {
            switch self {
            case .normal(let defaults): defaults.set(value,forKey:key)
            case .isolated(let url):
                var values: [String:Any] = [:]
                if FileManager.default.fileExists(atPath:url.path) {
                    let data = try CanvasLocalFile.read(url)
                    guard let existing = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    values = existing
                }
                values[key] = value
                try CanvasLocalFile.write(JSONSerialization.data(withJSONObject:values,options:.sortedKeys),to:url)
            case .unavailable: throw CocoaError(.fileWriteNoPermission)
            }
        }
    }

    static func defaults(overriding normal: UserDefaults? = nil) -> Defaults {
        #if DEBUG
        switch launch {
        case .normal: break
        case .isolated:
            guard let url = try? stateURL(.preferences) else { return .unavailable }
            return .isolated(url)
        case .invalid: return .unavailable
        }
        #endif
        return .normal(normal ?? .standard)
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

    static func stateURL(_ file: StateFile, blockRecoveryOverride: URL? = nil,
                         noteRecoveryOverride: URL? = nil, pdfExcerptRecoveryOverride: URL? = nil) throws -> URL {
        #if DEBUG
        switch launch {
        case .normal: break
        case .isolated(let context): return try isolatedURL(file,in:context)
        case .invalid: throw TestError.invalid
        }
        #endif
        if file == .blockRecovery, let override = blockRecoveryOverride { return override }
        if file == .noteRecovery, let override = noteRecoveryOverride { return override }
        if file == .pdfExcerptRecovery, let override = pdfExcerptRecoveryOverride { return override }
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

    var isValidLinkFrame: Bool {
        [x,y,width,height,x + width,y + height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

struct InkPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var pressure: Double
}

enum CanvasPenSettingsError: String, LocalizedError {
    case staleRevision = "stale_revision"
    case invalidPenSettings = "invalid_pen_settings"
    case inkBusy = "ink_busy"
    case unreadableDrawing = "unreadable_drawing"
    case unsupportedInkEdit = "unsupported_ink_edit"
    case unsupportedInkProjection = "unsupported_ink_projection"
    case sceneTooLarge = "scene_too_large"
    case persistenceFailed = "pen_settings_not_saved"

    var errorDescription: String? {
        switch self {
        case .staleRevision: return "장면이나 펜 설정이 바뀌었습니다. 최신 설정을 다시 확인하세요."
        case .invalidPenSettings: return "지원하는 펜 색과 굵기를 선택하세요."
        case .inkBusy: return "펜 동작을 마친 뒤 다음 획의 설정을 바꾸세요."
        case .unreadableDrawing: return "원본 그림을 읽을 수 없어 설정과 기존 저장본을 유지합니다."
        case .unsupportedInkEdit: return "다음 획의 펜 설정만 바꿀 수 있습니다. 기존 획과 원본 그림은 교체할 수 없습니다."
        case .unsupportedInkProjection: return "잉크 스타일을 안전하게 해석할 수 없어 원본을 유지합니다."
        case .sceneTooLarge: return "칠판 저장 크기 한도를 넘었습니다. 기존 설정과 저장본을 유지합니다."
        case .persistenceFailed: return "펜 설정을 저장하지 못했습니다. 기존 설정을 유지합니다."
        }
    }
}

private func requireInkFields(_ decoder: Decoder, allowed: Set<String>) throws {
    struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    let fields = try decoder.container(keyedBy: Field.self)
    guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw CanvasPenSettingsError.unsupportedInkEdit
    }
}

struct CanvasPenSettings: Codable, Equatable {
    enum Color: String, Codable, CaseIterable {
        case white, yellow, cyan
        var label: String {
            switch self {
            case .white: return "흰색"
            case .yellow: return "노랑"
            case .cyan: return "시안"
            }
        }
    }
    var version = 1
    var color: Color = .white
    var width: Double = 4
    static let widths: [Double] = [2, 4, 8]
    static let `default` = Self()
    var isValid: Bool { version == 1 && Self.widths.contains(width) }

    private enum CodingKeys: String, CodingKey { case version, color, width }
    init(version: Int = 1, color: Color = .white, width: Double = 4) {
        self.version = version
        self.color = color
        self.width = width
    }
    init(from decoder: Decoder) throws {
        try requireInkFields(decoder, allowed: ["version", "color", "width"])
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            color = try values.decode(Color.self, forKey: .color)
            width = try values.decode(Double.self, forKey: .width)
            guard isValid else { throw CanvasPenSettingsError.invalidPenSettings }
        } catch { throw CanvasPenSettingsError.invalidPenSettings }
    }
}

struct CanvasPenSettingsChange: Codable {
    let expected: CanvasPenSettings
    let settings: CanvasPenSettings
    private enum CodingKeys: String, CodingKey { case expected, settings }
    init(expected: CanvasPenSettings, settings: CanvasPenSettings) {
        self.expected = expected
        self.settings = settings
    }
    init(from decoder: Decoder) throws {
        try requireInkFields(decoder, allowed: ["expected", "settings"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        expected = try values.decode(CanvasPenSettings.self, forKey: .expected)
        settings = try values.decode(CanvasPenSettings.self, forKey: .settings)
    }
}

struct CanvasPenSettingsResult: Equatable {
    enum Disposition { case applied, noop }
    let disposition: Disposition
    let settings: CanvasPenSettings
    let revision: Int
}

struct InkStroke: Codable, Identifiable, Equatable {
    struct Style: Codable, Equatable {
        struct SRGB: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double
            var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
        }
        struct Transform: Codable, Equatable {
            var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
            var isValid: Bool { [a, b, c, d, tx, ty].allSatisfy(\.isFinite) }
        }
        struct Sample: Codable, Equatable {
            var width: Double
            var height: Double
            var opacity: Double
            var isValid: Bool {
                [width, height, opacity].allSatisfy(\.isFinite) && width >= 0 && height >= 0 && (0...1).contains(opacity)
            }
        }
        var version = 1
        var inkType: String
        // nil 색은 sRGB 변환 불가이며, 명목 펜 설정으로 추정하지 않는다.
        var color: SRGB?
        var transform: Transform
        // points는 world 좌표이고 samples의 size는 같은 인덱스의 path-local 값이다.
        var samples: [Sample]

        func isValid(pointCount: Int) -> Bool {
            version == 1 && !inkType.isEmpty && (color?.isValid ?? true) && transform.isValid &&
                samples.count == pointCount && samples.allSatisfy(\.isValid)
        }
    }
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
    var style: Style? = nil

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

enum VaultReviewError: LocalizedError {
    case malformed, empty, changed, time

    var errorDescription: String? {
        switch self {
        case .malformed: return "복습 카드 표식·버전·ID·평가 정보를 확인할 수 없습니다. 원문을 유지합니다."
        case .empty: return "질문과 답을 작성하고 저장한 뒤 복습하세요. 빈 내용은 초안으로 보존됩니다."
        case .changed: return "노트·선택·입력 또는 연결이 바뀌었습니다. 최신 원문에서 복습을 다시 여세요."
        case .time: return "평가 시각과 선택한 고정 간격의 기한을 확인할 수 없습니다. 원문을 유지합니다."
        }
    }
}

struct VaultReviewCard {
    enum Field: String, CaseIterable { case front, back }
    enum Grade: Int64, CaseIterable {
        case again = 300, hard = 600, good = 86_400, easy = 172_800

        var title: String {
            switch self {
            case .again: return "다시"
            case .hard: return "하드"
            case .good: return "좋음"
            case .easy: return "쉬움"
            }
        }

        var intervalLabel: String {
            switch self {
            case .again: return "5분"
            case .hard: return "10분"
            case .good: return "24시간"
            case .easy: return "48시간"
            }
        }
    }
    struct Metadata: Codable, Equatable {
        let cardID: String
        let eventID: String?
        let ratedAt: Int64?
        let dueAt: Int64?

        private enum CodingKeys: String, CodingKey { case cardID, eventID, ratedAt, dueAt }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy:CodingKeys.self)
            try values.encode(cardID,forKey:.cardID)
            try values.encode(eventID,forKey:.eventID)
            try values.encode(ratedAt,forKey:.ratedAt)
            try values.encode(dueAt,forKey:.dueAt)
        }
    }

    let metadata: Metadata
    let front: String
    let back: String
    private let metadataRange: Range<Int>
    private let frontRange: Range<Int>
    private let backRange: Range<Int>
    private let source: String

    var grade: Grade? {
        guard let rated = metadata.ratedAt, let due = metadata.dueAt else { return nil }
        return Grade(rawValue:due - rated)
    }

    var ready: Bool {
        !front.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
        !back.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }

    private static let prefix = "<!-- ccr-review-card:v1 "
    private static let frontMarker = "<!-- ccr-review-front -->"
    private static let backMarker = "<!-- ccr-review-back -->"
    private static let endMarker = "<!-- /ccr-review-card -->"
    private static let lastSecond: Int64 = 253_402_300_799

    private static func validID(_ id: String) -> Bool {
        UUID(uuidString:id)?.uuidString.lowercased() == id &&
        id != "00000000-0000-0000-0000-000000000000"
    }

    static func parse(_ text: String) throws -> Self? {
        let bytes = Array(text.utf8)
        guard bytes.count <= 1024 * 1024 else { throw VaultReviewError.malformed }
        let reserved = text.components(separatedBy:"ccr-review").count - 1
        if reserved == 0 { return nil }
        guard reserved == 4 else { throw VaultReviewError.malformed }
        var lines: [(text:String,start:Int,end:Int)] = []
        var start = 0
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of:10) ?? bytes.count
            let contentEnd = end > start && bytes[end - 1] == 13 ? end - 1 : end
            lines.append((String(decoding:bytes[start..<contentEnd],as:UTF8.self),start,
                          end < bytes.count ? end + 1 : end))
            start = end + 1
        }
        let marked = lines.indices.filter { lines[$0].text.contains("ccr-review") }
        guard marked.count == 4 else { throw VaultReviewError.malformed }
        var fence: (Character,Int)?
        var frontmatter = false
        var comment = false
        for index in lines.indices {
            let line = lines[index].text.trimmingCharacters(in:.whitespaces)
            if marked.contains(index) {
                guard !frontmatter, fence == nil, !comment else { throw VaultReviewError.malformed }
                continue
            }
            if index == 0 && (line == "---" || line == "\u{feff}---") { frontmatter = true; continue }
            if frontmatter {
                if line == "---" || line == "..." { frontmatter = false }
                continue
            }
            if let first = line.first, first == "`" || first == "~" {
                let count = line.prefix(while:{ $0 == first }).count
                if let active = fence {
                    if active.0 == first && count >= active.1 && line.dropFirst(count).isEmpty { fence = nil }
                } else if count >= 3 { fence = (first,count) }
            }
            if fence == nil {
                var cursor = line.startIndex
                while cursor < line.endIndex,
                      let token = line.range(of:comment ? "-->" : "<!--",range:cursor..<line.endIndex) {
                    comment.toggle()
                    cursor = token.upperBound
                }
            }
        }
        let header = lines[marked[0]], question = lines[marked[1]], answer = lines[marked[2]], end = lines[marked[3]]
        guard header.text.hasPrefix(prefix), header.text.hasSuffix(" -->"),
              question.text == frontMarker, answer.text == backMarker, end.text == endMarker,
              marked[1] == marked[0] + 1 else { throw VaultReviewError.malformed }
        let raw = String(header.text.dropFirst(prefix.count).dropLast(4))
        let data = Data(raw.utf8)
        // A fixed canonical JSON header rejects duplicate keys as well as unknown fields.
        let metadata = try? JSONDecoder().decode(Metadata.self,from:data)
        guard let metadata, validID(metadata.cardID),
              try headerJSON(metadata).utf8.elementsEqual(raw.utf8) else { throw VaultReviewError.malformed }
        switch (metadata.eventID, metadata.ratedAt, metadata.dueAt) {
        case (nil,nil,nil): break
        case let (event?,rated?,due?):
            guard validID(event), event != metadata.cardID, rated >= 0, due >= rated,
                  due <= lastSecond, Grade(rawValue:due - rated) != nil else { throw VaultReviewError.malformed }
        default: throw VaultReviewError.malformed
        }
        return Self(metadata:metadata,
            front:String(decoding:bytes[question.end..<answer.start],as:UTF8.self),
            back:String(decoding:bytes[answer.end..<end.start],as:UTF8.self),
            metadataRange:(header.start + prefix.utf8.count)..<(header.start + header.text.utf8.count - 4),
            frontRange:question.end..<answer.start,backRange:answer.end..<end.start,source:text)
    }

    func text(for field: Field) -> String {
        let raw = field == .front ? front : back
        if raw.hasSuffix("\r\n") { return String(decoding:raw.utf8.dropLast(2),as:UTF8.self) }
        if raw.hasSuffix("\n") { return String(raw.dropLast()) }
        return raw
    }

    func replacing(_ field: Field, with text: String) throws -> String {
        if text.utf8.elementsEqual(self.text(for:field).utf8) { return source }
        let raw = field == .front ? front : back
        let range = field == .front ? frontRange : backRange
        let newline = text.utf8.last == 13 || raw.hasSuffix("\r\n") ||
            (raw.isEmpty && source.contains("\r\n")) ? "\r\n" : "\n"
        let bytes = Array(source.utf8)
        let result = String(decoding:bytes[..<range.lowerBound],as:UTF8.self) + text + newline +
            String(decoding:bytes[range.upperBound...],as:UTF8.self)
        guard result.utf8.count <= 1024 * 1024 else { throw VaultReviewError.malformed }
        return result
    }

    private static func headerJSON(_ metadata: Metadata) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding:try encoder.encode(metadata),as:UTF8.self)
    }

    static func insertingTemplate(in text: String, cardID: UUID = UUID()) throws -> String {
        guard try parse(text) == nil, validID(cardID.uuidString.lowercased()) else { throw VaultReviewError.malformed }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let metadata = Metadata(cardID:cardID.uuidString.lowercased(),eventID:nil,ratedAt:nil,dueAt:nil)
        let template = [prefix + (try headerJSON(metadata)) + " -->",frontMarker,"",backMarker,"",endMarker,""]
            .joined(separator:newline)
        let result = text + (text.isEmpty ? "" : newline + newline) + template
        _ = try parse(result)
        return result
    }

    func ratingGood(eventID: UUID, injectedDate: Date) throws -> String {
        try rating(.good,eventID:eventID,injectedDate:injectedDate)
    }

    func rating(_ grade: Grade, eventID: UUID, injectedDate: Date) throws -> String {
        guard ready else { throw VaultReviewError.empty }
        let event = eventID.uuidString.lowercased()
        guard Self.validID(event), event != metadata.cardID else { throw VaultReviewError.malformed }
        if metadata.eventID == event {
            guard self.grade == grade else { throw VaultReviewError.changed }
            return source
        }
        let seconds = injectedDate.timeIntervalSince1970.rounded(.down)
        guard seconds.isFinite, seconds >= 0, seconds <= Double(Self.lastSecond - grade.rawValue),
              metadata.ratedAt.map({ seconds >= Double($0) }) ?? true else { throw VaultReviewError.time }
        let rated = Int64(seconds)
        let updated = Metadata(cardID:metadata.cardID,eventID:event,ratedAt:rated,dueAt:rated + grade.rawValue)
        let bytes = Array(source.utf8)
        let result = String(decoding:bytes[..<metadataRange.lowerBound],as:UTF8.self) +
            (try Self.headerJSON(updated)) + String(decoding:bytes[metadataRange.upperBound...],as:UTF8.self)
        _ = try Self.parse(result)
        return result
    }
}

struct VaultNoteSnapshot: Codable, Equatable {
    let path: String
    let text: String
    let sha256: String
    let modifiedAt: String
    var reconciliationRequired: Bool? = nil

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

enum VaultSaveConflict: String, Codable {
    case reconciliationRequired, unclassified, prepublication, acknowledgementLost
    static let errorKey = "CanvasVaultSaveConflict"
    static func classified(_ error: Error) -> Self? {
        let value = error as NSError
        guard value.domain == "CanvasRelay", value.code == 409 else { return nil }
        return (value.userInfo[errorKey] as? String).flatMap(Self.init(rawValue:)) ?? .unclassified
    }
    var requiresExplicitReconciliation: Bool { self == .reconciliationRequired || self == .unclassified }
}

struct CanvasVaultCheckpoint: Codable {
    let sceneID: UUID
    let address: String
    let sceneSha: String?
    let noteSha: String?
    let pendingSceneSha: String?
    var saveConflict: VaultSaveConflict? = nil
    var requiresExplicitReconciliation: Bool { saveConflict?.requiresExplicitReconciliation == true || (pendingSceneSha != nil && saveConflict != .acknowledgementLost) }
    func acceptingReadMatch(remoteSceneSha: String, remoteNoteSha: String, localSceneSha: String,
                            explicitlyConfirmed: Bool, remoteReconciliationRequired: Bool?) -> Self? {
        guard explicitlyConfirmed, remoteReconciliationRequired == false, remoteSceneSha == localSceneSha else { return nil }
        return Self(sceneID:sceneID,address:address,sceneSha:remoteSceneSha,noteSha:remoteNoteSha,
                    pendingSceneSha:nil,saveConflict:nil)
    }
}


enum VaultBlockRecoveryError: LocalizedError {
    case unavailable, corrupt, context, changed, publicationConflict

    var errorDescription: String? {
        switch self {
        case .unavailable: return "문단 복구 파일을 저장하지 못했습니다. 입력은 유지하며 새 요청은 보내지 않습니다."
        case .corrupt: return "문단 복구 파일을 확인하지 못했습니다. 기존 파일을 보존하며 문단 저장을 중단합니다."
        case .context: return "보존된 입력의 장면·카드·원문·서버가 현재 연결과 다릅니다. 자동 연결하지 않습니다."
        case .changed: return "원문이 기준 또는 예상 결과와 다릅니다. 입력과 작업 ID를 보존하며 다시 쓰지 않습니다."
        case .publicationConflict: return "Obsidian 저장 충돌 또는 결과 미확인입니다. 원격에는 제안본이 반영됐을 수 있습니다. 입력과 보존 자료를 유지하며 자동 재시도·되돌리기를 중단했습니다. 원문을 읽고 대조한 뒤 명시적으로 조정하세요."
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
    var saveConflict: VaultSaveConflict? = nil

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

struct VaultNoteRecovery: Codable, Equatable {
    let schemaVersion: Int
    let sceneID: UUID
    let nodeID: UUID?
    let blockID: String?
    let relayAddress: String
    var base: VaultNoteSnapshot
    var draft: String
    var submittedText: String?
    var saveConflict: VaultSaveConflict? = nil

    func validated() throws -> Self {
        guard schemaVersion == 1, relayAddress.utf8.count <= 2048,
              let url = URLComponents(string:relayAddress),
              url.scheme.map({ ["http","https"].contains($0) }) == true,
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, draft.utf8.count <= 1024 * 1024,
              submittedText.map({ $0.utf8.count <= 1024 * 1024 }) ?? true,
              nodeID != nil || blockID == nil else { throw VaultBlockRecoveryError.corrupt }
        _ = try base.validated(at:base.path)
        return self
    }

    func reconciled(with latest: VaultNoteSnapshot) throws -> Self? {
        guard saveConflict?.requiresExplicitReconciliation != true else { throw VaultBlockRecoveryError.publicationConflict }
        _ = try validated()
        _ = try latest.validated(at:base.path)
        var next = self
        if latest.sha256 != base.sha256 {
            guard let submittedText, latest.text.utf8.elementsEqual(submittedText.utf8) else {
                throw VaultBlockRecoveryError.changed
            }
        }
        next.base = latest
        next.submittedText = nil
        return next.draft.utf8.elementsEqual(latest.text.utf8) ? nil : next
    }
}

struct VaultNoteRecoveryFile: Codable {
    let schemaVersion: Int
    let payload: Data?
    let sha256: String

    init(_ record: VaultNoteRecovery?) throws {
        schemaVersion = 1
        payload = try record.map { try JSONEncoder().encode($0.validated()) }
        sha256 = CanvasPacket.sha(payload ?? Data())
    }

    func record() throws -> VaultNoteRecovery? {
        guard schemaVersion == 1, CanvasPacket.sha(payload ?? Data()) == sha256 else {
            throw VaultBlockRecoveryError.corrupt
        }
        return try payload.map { try JSONDecoder().decode(VaultNoteRecovery.self,from:$0).validated() }
    }
}

struct CanvasNode: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case note, box, ellipse, line }
    enum Confidence: String, Codable { case confirmed, proposal }

    var id: UUID
    var kind: Kind
    var frame: CanvasRect
    var text: String
    var confidence: Confidence
    var sourceStrokeIds: [UUID]
    var vaultNote: VaultNoteReference? = nil
    var isCollapsed: Bool? = nil
    var rotationDegrees: Double? = nil

    var rotationRadians: Double { (rotationDegrees ?? 0).truncatingRemainder(dividingBy:360) * .pi / 180 }

    static func validRotation(_ degrees: Double) -> Bool {
        degrees.isFinite && (degrees * .pi / 180).isFinite
    }

    var hasValidRotation: Bool {
        guard let degrees = rotationDegrees else { return true }
        guard Self.validRotation(degrees) else { return false }
        return degrees == 0 || [CanvasPoint(x:frame.x,y:frame.y),
            .init(x:frame.x + frame.width,y:frame.y),
            .init(x:frame.x,y:frame.y + frame.height),
            .init(x:frame.x + frame.width,y:frame.y + frame.height)].allSatisfy { scenePoint($0) != nil }
    }

    func rotatedVector(_ vector: CanvasPoint, inverse: Bool = false) -> CanvasPoint? {
        guard Self.validRotation(rotationDegrees ?? 0), vector.x.isFinite, vector.y.isFinite else { return nil }
        if rotationRadians == 0 { return vector }
        let angle = inverse ? -rotationRadians : rotationRadians
        let point = CanvasPoint(x:vector.x * cos(angle) - vector.y * sin(angle),
                                y:vector.x * sin(angle) + vector.y * cos(angle))
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    // frame과 anchor는 회전 전 좌표이며 모든 표면이 이 중심 변환을 공유한다.
    func scenePoint(_ point: CanvasPoint, inverse: Bool = false) -> CanvasPoint? {
        guard frame.isValidLinkFrame, point.x.isFinite, point.y.isFinite else { return nil }
        if rotationRadians == 0 && Self.validRotation(rotationDegrees ?? 0) { return point }
        guard let vector = rotatedVector(.init(x:point.x - frame.center.x,y:point.y - frame.center.y),inverse:inverse)
        else { return nil }
        let result = CanvasPoint(x:frame.center.x + vector.x,y:frame.center.y + vector.y)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    func endpoint(anchor: CanvasLinkAnchor?, toward target: CanvasPoint) -> CanvasPoint? {
        guard hasValidRotation, let localTarget = scenePoint(target,inverse:true),
              let local = anchor?.point(in:frame) ?? CanvasLinkAnchor.automatic(in:frame,toward:localTarget)
        else { return nil }
        return scenePoint(local)
    }
}

extension CanvasNode {
    private enum CodingKeys: String, CodingKey {
        case id, kind, frame, text, confidence, sourceStrokeIds, vaultNote, isCollapsed, rotationDegrees
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        id = try values.decode(UUID.self,forKey:.id)
        kind = try values.decode(Kind.self,forKey:.kind)
        frame = try values.decode(CanvasRect.self,forKey:.frame)
        text = try values.decode(String.self,forKey:.text)
        confidence = try values.decode(Confidence.self,forKey:.confidence)
        sourceStrokeIds = try values.decode([UUID].self,forKey:.sourceStrokeIds)
        vaultNote = try values.decodeIfPresent(VaultNoteReference.self,forKey:.vaultNote)
        isCollapsed = try values.decodeIfPresent(Bool.self,forKey:.isCollapsed)
        rotationDegrees = try values.decodeIfPresent(Double.self,forKey:.rotationDegrees)
        guard hasValidRotation else {
            throw DecodingError.dataCorruptedError(forKey:.rotationDegrees,in:values,
                debugDescription:"회전값이나 회전 좌표가 유한 범위를 벗어났습니다. 원본을 보존합니다.")
        }
    }

    func encode(to encoder: Encoder) throws {
        guard hasValidRotation else {
            throw EncodingError.invalidValue(self,.init(codingPath:encoder.codingPath,
                debugDescription:"잘못된 회전값은 저장할 수 없습니다. 마지막 정상 원본을 유지합니다."))
        }
        var values = encoder.container(keyedBy:CodingKeys.self)
        try values.encode(id,forKey:.id)
        try values.encode(kind,forKey:.kind)
        try values.encode(frame,forKey:.frame)
        try values.encode(text,forKey:.text)
        try values.encode(confidence,forKey:.confidence)
        try values.encode(sourceStrokeIds,forKey:.sourceStrokeIds)
        try values.encodeIfPresent(vaultNote,forKey:.vaultNote)
        try values.encodeIfPresent(isCollapsed,forKey:.isCollapsed)
        try values.encodeIfPresent(rotationDegrees,forKey:.rotationDegrees)
    }
}

struct CanvasLinkAnchor: Codable, Equatable {
    enum Side: String, Codable, CaseIterable { case top, right, bottom, left }
    var side: Side
    var offset: Double

    var isValid: Bool { offset.isFinite && (0...1).contains(offset) }

    init(side: Side, offset: Double) { self.side = side; self.offset = offset }

    private enum CodingKeys: String, CodingKey { case side, offset }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy:Field.self)
        guard fields.allKeys.allSatisfy({ CodingKeys(rawValue:$0.stringValue) != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,
                debugDescription:"지원하지 않는 연결점 필드가 있습니다. 원본을 보존하며 읽기를 중단합니다."))
        }
        let values = try decoder.container(keyedBy:CodingKeys.self)
        side = try values.decode(Side.self,forKey:.side)
        offset = try values.decode(Double.self,forKey:.offset)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey:.offset,in:values,
                debugDescription:"연결점 위치는 0부터 1 사이의 유한한 값이어야 합니다.")
        }
    }

    func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self,.init(codingPath:encoder.codingPath,
                debugDescription:"잘못된 연결점은 저장할 수 없습니다."))
        }
        var values = encoder.container(keyedBy:CodingKeys.self)
        try values.encode(side,forKey:.side)
        try values.encode(offset,forKey:.offset)
    }

    func point(in frame: CanvasRect) -> CanvasPoint? {
        guard isValid, frame.isValidLinkFrame else { return nil }
        switch side {
        case .top: return CanvasPoint(x:frame.x + frame.width * offset,y:frame.y)
        case .right: return CanvasPoint(x:frame.x + frame.width,y:frame.y + frame.height * offset)
        case .bottom: return CanvasPoint(x:frame.x + frame.width * offset,y:frame.y + frame.height)
        case .left: return CanvasPoint(x:frame.x,y:frame.y + frame.height * offset)
        }
    }

    static func nearest(to point: CanvasPoint, in frame: CanvasRect) -> Self? {
        guard frame.isValidLinkFrame, point.x.isFinite, point.y.isFinite,
              (point.x - frame.x).isFinite, (point.y - frame.y).isFinite else { return nil }
        let x = min(1,max(0,(point.x - frame.x) / frame.width))
        let y = min(1,max(0,(point.y - frame.y) / frame.height))
        let candidates = [Self(side:.top,offset:x),Self(side:.right,offset:y),
                          Self(side:.bottom,offset:x),Self(side:.left,offset:y)]
        return candidates.min { a,b in
            guard let p = a.point(in:frame), let q = b.point(in:frame) else { return false }
            return hypot(p.x - point.x,p.y - point.y) < hypot(q.x - point.x,q.y - point.y)
        }
    }

    static func automatic(in frame: CanvasRect, toward target: CanvasPoint) -> CanvasPoint? {
        guard frame.isValidLinkFrame, target.x.isFinite, target.y.isFinite else { return nil }
        let center = frame.center
        let dx = target.x - center.x, dy = target.y - center.y
        guard dx.isFinite, dy.isFinite else { return nil }
        if dx == 0 && dy == 0 { return Self(side:.right,offset:0.5).point(in:frame) }
        let scale = max(abs(dx) / (frame.width / 2),abs(dy) / (frame.height / 2))
        guard scale.isFinite, scale > 0 else { return nil }
        return CanvasPoint(x:center.x + dx / scale,y:center.y + dy / scale)
    }
}

struct CanvasLink: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case general, parentChild }
    enum Endpoint: String, CaseIterable { case from, to }

    var id: UUID
    var from: UUID
    var to: UUID
    var label: String
    var kind: Kind? = nil
    var fromAnchor: CanvasLinkAnchor? = nil
    var toAnchor: CanvasLinkAnchor? = nil

    var hasValidAnchors: Bool {
        (fromAnchor?.isValid ?? true) && (toAnchor?.isValid ?? true)
    }
}

struct CanvasAnnotation: Codable, Identifiable, Equatable {
    var id: UUID
    var nodeId: UUID?
    var text: String
    var author: String
}

struct CanvasCommentSession: Identifiable {
    let id = UUID()
    let scene: CanvasScene
    let node: CanvasNode
    let annotation: CanvasAnnotation?

    var text: String { annotation?.text ?? "" }

    func matches(_ current: CanvasScene) -> Bool {
        current.id == scene.id && current.revision == scene.revision &&
            current.hasSameGraph(as:scene) && current.visibility.nodeIDs.contains(node.id)
    }
}

struct CanvasNodeTextEdit: Codable {
    var expected: CanvasNode
    var text: String
}

struct CanvasLinkEdit: Codable {
    var expected: CanvasLink
    var replacement: CanvasLink
}

enum CanvasSceneWireError: LocalizedError {
    case unsupportedVersion, kindRequiresSchema3, relayCapability
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "unsupported_scene_version · 지원하지 않는 장면 버전입니다. 원본을 유지합니다."
        case .kindRequiresSchema3: return "shape_requires_schema3 · 선·타원은 장면 버전 3에서만 읽고 저장합니다. 원본을 유지합니다."
        case .relayCapability: return "scene3_relay_unsupported · 서버의 장면 버전 3 및 도형 투영 지원을 확인하지 못했습니다. Obsidian 미동기화 상태로 원본을 유지합니다."
        }
    }
}

struct CanvasScene: Codable, Equatable {
    static let localByteLimit = 4 * 1024 * 1024
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
    var penSettings: CanvasPenSettings? = nil
    var hasLegacyCompatibleNodeKinds: Bool { nodes.allSatisfy { $0.kind == .note || $0.kind == .box } }
    func requireCompatibleNodeKinds() throws {
        guard [1, 2, 3].contains(schemaVersion) else { throw CanvasSceneWireError.unsupportedVersion }
        guard schemaVersion == 3 || hasLegacyCompatibleNodeKinds else { throw CanvasSceneWireError.kindRequiresSchema3 }
    }
    mutating func promoteSchemaForNodeKinds() {
        if !hasLegacyCompatibleNodeKinds { schemaVersion = max(3, schemaVersion) }
    }
    var effectivePenSettings: CanvasPenSettings { penSettings ?? .default }
    var hasSupportedInkProjection: Bool {
        ([1, 2, 3].contains(schemaVersion)) && (schemaVersion == 3 || hasLegacyCompatibleNodeKinds) && effectivePenSettings.isValid &&
            (schemaVersion >= 2 || (penSettings == nil && strokes.allSatisfy { $0.style == nil })) &&
            strokes.allSatisfy { stroke in
                stroke.style.map { !$0.inkType.isEmpty && !drawingBase64.isEmpty && $0.isValid(pointCount: stroke.points.count) } ?? true
            }
    }

    @discardableResult
    mutating func setPenSettings(_ change: CanvasPenSettingsChange, sceneID: UUID, baseRevision: Int,
                                 inkBusy: Bool = false) throws -> CanvasPenSettingsResult {
        guard sceneID == id, baseRevision == revision, change.expected == effectivePenSettings else {
            throw CanvasPenSettingsError.staleRevision
        }
        guard change.expected.isValid, change.settings.isValid else { throw CanvasPenSettingsError.invalidPenSettings }
        guard !inkBusy else { throw CanvasPenSettingsError.inkBusy }
        guard hasSupportedInkProjection else { throw CanvasPenSettingsError.unsupportedInkProjection }
        if change.settings == effectivePenSettings {
            return .init(disposition: .noop, settings: effectivePenSettings, revision: revision)
        }
        var next = self
        next.schemaVersion = max(2, next.schemaVersion)
        next.penSettings = change.settings
        next.revision += 1
        guard try JSONEncoder().encode(next).count <= Self.localByteLimit else { throw CanvasPenSettingsError.sceneTooLarge }
        self = next
        return .init(disposition: .applied, settings: effectivePenSettings, revision: revision)
    }

    var annotationFrames: [UUID: CanvasRect] {
        let visible = visibility
        var rows: [UUID: Int] = [:]
        var frames: [UUID: CanvasRect] = [:]
        for note in annotations where visible.annotationIDs.contains(note.id) {
            guard let node = nodes.first(where:{ $0.id == note.nodeId }) else { continue }
            let row = rows[node.id,default:0]
            frames[note.id] = CanvasRect(x:node.frame.x,y:node.frame.y + node.frame.height + 8 + Double(row) * 88,
                width:300,height:80)
            rows[node.id] = row + 1
        }
        return frames
    }

    func commentSession(for nodeID: UUID) -> CanvasCommentSession? {
        guard visibility.nodeIDs.contains(nodeID),
              nodes.filter({ $0.id == nodeID }).count == 1,
              let node = nodes.first(where:{ $0.id == nodeID }) else { return nil }
        let comments = annotations.filter { $0.nodeId == nodeID && $0.author == "사용자" }
        guard comments.count <= 1,
              comments.first.map({ comment in annotations.filter { $0.id == comment.id }.count == 1 }) ?? true
        else { return nil }
        return CanvasCommentSession(scene:self,node:node,annotation:comments.first)
    }

    @discardableResult
    mutating func setUserComment(_ text: String, session: CanvasCommentSession) -> Bool {
        guard session.matches(self), commentSession(for:session.node.id) != nil,
              !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return false }
        var next = self
        if let expected = session.annotation {
            guard let index = next.annotations.firstIndex(where:{ $0.id == expected.id }) else { return false }
            next.annotations[index].text = text
        } else {
            next.annotations.append(CanvasAnnotation(id:UUID(),nodeId:session.node.id,text:text,author:"사용자"))
        }
        next.revision += 1
        guard let bytes = try? JSONEncoder().encode(next), bytes.count <= CanvasPacket.sceneByteLimit else { return false }
        self = next
        return true
    }

    func linkEndpoints(_ link: CanvasLink) -> (from: CanvasPoint, to: CanvasPoint)? {
        guard link.hasValidAnchors,
              let from = nodes.first(where:{ $0.id == link.from }),
              let to = nodes.first(where:{ $0.id == link.to }),
              let a = from.endpoint(anchor:link.fromAnchor,toward:to.frame.center),
              let b = to.endpoint(anchor:link.toAnchor,toward:from.frame.center)
        else { return nil }
        return (a,b)
    }

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
        promoteSchemaForNodeKinds()
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
        guard nodes.allSatisfy(\.hasValidRotation),
              nodeEdits.allSatisfy({ $0.expected.hasValidRotation }),
              !nodeEdits.isEmpty || !linkEdits.isEmpty,
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
                  edit.expected.hasValidAnchors, value.hasValidAnchors,
                  value.from != value.to, ids.contains(value.from), ids.contains(value.to),
                  linkEndpoints(value) != nil,
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
        if let settings = change.setPenSettings {
            guard change.isPenSettingsOnly else { return false }
            return (try? setPenSettings(settings, sceneID: change.sceneId, baseRevision: change.baseRevision)) != nil
        }
        guard (try? requireCompatibleNodeKinds()) != nil, change.sceneId == id, nodes.allSatisfy(\.hasValidRotation),
              change.proposedNodes.allSatisfy(\.hasValidRotation),
              (change.nodeEdits ?? []).allSatisfy({ $0.expected.hasValidRotation }) else { return false }
        let annotationIds = change.annotations.map(\.id)
        let proposalIds = change.proposedNodes.map(\.id)
        let proposedLinks = change.proposedLinks ?? []
        let linkIds = proposedLinks.map(\.id)
        let nodeEdits = change.nodeEdits ?? []
        let linkEdits = change.linkEdits ?? []
        guard proposedLinks.allSatisfy(\.hasValidAnchors),
              linkEdits.allSatisfy({ $0.expected.hasValidAnchors && $0.replacement.hasValidAnchors }),
              Set(annotationIds).count == annotationIds.count,
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
                  sent.effectivePenSettings == effectivePenSettings,
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
                  availableIds.contains($0.to) }) else {
            return false
        }
        var next = self
        next.annotations.append(contentsOf: change.annotations)
        next.nodes.append(contentsOf: change.proposedNodes)
        next.promoteSchemaForNodeKinds()
        next.links.append(contentsOf: proposedLinks)
        if !nodeEdits.isEmpty || !linkEdits.isEmpty {
            guard next.editGraph(nodeEdits:nodeEdits,linkEdits:linkEdits) else { return false }
        }
        guard next.links.allSatisfy({ $0.from != $0.to && availableIds.contains($0.from) &&
                  availableIds.contains($0.to) && $0.hasValidAnchors }),
              proposedLinks.allSatisfy({ next.linkEndpoints($0) != nil }),
              Self.validHierarchy(next.links,nodeIds:availableIds) else { return false }
        next.revision = revision + 1
        self = next
        return true
    }
}

extension CanvasScene {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, revision, width, height, drawingBase64, strokes, nodes, links, annotations, penSettings
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard [1, 2, 3].contains(schemaVersion) else { throw CanvasSceneWireError.unsupportedVersion }
        id = try values.decode(UUID.self, forKey: .id)
        revision = try values.decode(Int.self, forKey: .revision)
        width = try values.decode(Double.self, forKey: .width)
        height = try values.decode(Double.self, forKey: .height)
        drawingBase64 = try values.decode(String.self, forKey: .drawingBase64)
        strokes = try values.decode([InkStroke].self, forKey: .strokes)
        nodes = try values.decode([CanvasNode].self, forKey: .nodes)
        links = try values.decode([CanvasLink].self, forKey: .links)
        annotations = try values.decode([CanvasAnnotation].self, forKey: .annotations)
        penSettings = try values.decodeIfPresent(CanvasPenSettings.self, forKey: .penSettings)
        try requireCompatibleNodeKinds()
        guard hasSupportedInkProjection else { throw CanvasPenSettingsError.unsupportedInkProjection }
    }
}

#if canImport(PencilKit, _version: 616)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension CanvasScene {
    private static func inkStyle(_ stroke: PKStroke) -> InkStroke.Style {
        let transform = stroke.transform
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let converted = srgb.flatMap { stroke.ink.color.cgColor.converted(to: $0, intent: .relativeColorimetric, options: nil) }
        let components = converted?.components
        let color: InkStroke.Style.SRGB?
        if let components, components.count == 4 {
            let rgba = InkStroke.Style.SRGB(red: Double(components[0]), green: Double(components[1]),
                blue: Double(components[2]), alpha: Double(components[3]))
            color = rgba.isValid ? rgba : nil
        } else { color = nil }
        return InkStroke.Style(inkType: stroke.ink.inkType.rawValue, color: color,
            transform: .init(a: Double(transform.a), b: Double(transform.b), c: Double(transform.c),
                d: Double(transform.d), tx: Double(transform.tx), ty: Double(transform.ty)),
            samples: stroke.path.map { .init(width: Double($0.size.width), height: Double($0.size.height), opacity: Double($0.opacity)) })
    }

    static func nativeInkStrokes(_ drawing: PKDrawing) -> [InkStroke] {
        drawing.strokes.map { stroke in
            func worldPoint(_ point: PKStrokePoint) -> InkPoint {
                let location = point.location.applying(stroke.transform)
                return InkPoint(x: Double(location.x), y: Double(location.y),
                                pressure: Double(point.force))
            }
            let ranges = stroke.maskedPathRanges
            let full = stroke.mask == nil || (ranges.count == 1 &&
                ranges[0].lowerBound == 0 && ranges[0].upperBound == CGFloat(stroke.path.count - 1))
            let visibility = InkStroke.Visibility(kind: full ? .full : .masked,
                visibleSegments: full ? [] : ranges.map { range in
                    var points = [worldPoint(stroke.path.interpolatedPoint(at: range.lowerBound))]
                    let firstInterior = Int(floor(range.lowerBound)) + 1
                    let endInterior = Int(ceil(range.upperBound))
                    if firstInterior < endInterior {
                        points += (firstInterior..<endInterior).map { worldPoint(stroke.path[$0]) }
                    }
                    if range.upperBound > range.lowerBound {
                        points.append(worldPoint(stroke.path.interpolatedPoint(at: range.upperBound)))
                    }
                    return InkStroke.Visibility.Segment(lowerBound: Double(range.lowerBound),
                        upperBound: Double(range.upperBound), worldPoints: points)
                })
            return InkStroke(id: stroke.id, points: stroke.path.map(worldPoint),
                createdAt: stroke.path.creationDate, visibility: visibility, style: Self.inkStyle(stroke))
        }
    }
}
#endif

extension CanvasScene {
    func validateNativeInkProjection() throws {
        guard hasSupportedInkProjection else { throw CanvasPenSettingsError.unsupportedInkProjection }
        guard strokes.contains(where: { $0.style != nil }) else { return }
        #if canImport(PencilKit, _version: 616)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            guard let bytes = Data(base64Encoded: drawingBase64),
                  let native = try? PKDrawing(data: bytes) else { throw CanvasPenSettingsError.unreadableDrawing }
            let projected = Self.nativeInkStrokes(native)
            guard strokes.count == projected.count,
                  zip(strokes, projected).allSatisfy({ stored, actual in
                      stored.style == nil || stored == actual
                  }) else { throw CanvasPenSettingsError.unsupportedInkProjection }
            return
        }
        #endif
        throw CanvasPenSettingsError.unsupportedInkProjection
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
    var setPenSettings: CanvasPenSettingsChange? = nil
    var isPenSettingsOnly: Bool {
        setPenSettings != nil && annotations.isEmpty && proposedNodes.isEmpty &&
            (proposedLinks?.isEmpty ?? true) && (nodeEdits?.isEmpty ?? true) && (linkEdits?.isEmpty ?? true)
    }
}

extension AgentRevision {
    private enum CodingKeys: String, CodingKey {
        case sceneId, baseRevision, annotations, proposedNodes, proposedLinks, nodeEdits, linkEdits, setPenSettings
    }
    init(from decoder: Decoder) throws {
        try requireInkFields(decoder, allowed: ["sceneId", "baseRevision", "annotations", "proposedNodes",
            "proposedLinks", "nodeEdits", "linkEdits", "setPenSettings"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sceneId = try values.decode(UUID.self, forKey: .sceneId)
        baseRevision = try values.decode(Int.self, forKey: .baseRevision)
        annotations = try values.decode([CanvasAnnotation].self, forKey: .annotations)
        proposedNodes = try values.decode([CanvasNode].self, forKey: .proposedNodes)
        proposedLinks = try values.decodeIfPresent([CanvasLink].self, forKey: .proposedLinks)
        nodeEdits = try values.decodeIfPresent([CanvasNodeTextEdit].self, forKey: .nodeEdits)
        linkEdits = try values.decodeIfPresent([CanvasLinkEdit].self, forKey: .linkEdits)
        setPenSettings = try values.decodeIfPresent(CanvasPenSettingsChange.self, forKey: .setPenSettings)
    }
}

struct CanvasDiagramSnapshot: Codable, Equatable {
    struct Node: Codable, Equatable {
        let diagramID: String
        let id: UUID
        let text: String
        let kind: CanvasNode.Kind
    }
    let sceneID: UUID
    let revision: Int
    let source: String
    let nodes: [Node]
    let displayedNodeCount: Int
    let displayedEdgeCount: Int

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
        try scene.requireCompatibleNodeKinds()
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
            Node(diagramID:diagramID($0.id),id:$0.id,text:$0.text,kind:$0.kind)
        }
        let primitiveCount = nodes.filter { $0.kind == .line }.count
        displayedNodeCount = nodes.count + primitiveCount
        displayedEdgeCount = scene.links.filter { visible.linkIDs.contains($0.id) }.count + primitiveCount
        guard displayedNodeCount <= 512, displayedEdgeCount <= 1024 else { throw Failure.limit }
        var lines = ["flowchart TD"]
        for node in nodes {
            if node.kind == .line {
                let endpoint = "x" + node.diagramID.dropFirst()
                lines += ["\(node.diagramID)[\" \"]", "\(endpoint)[\" \"]",
                    "\(node.diagramID) ---|\"\(label(node.text.isEmpty ? "직선" : node.text))\"| \(endpoint)",
                    "class \(node.diagramID),\(endpoint) ccrLineEndpoint"]
            } else {
                lines.append("\(node.diagramID)[\"\(label(node.text.isEmpty ? "이름 없는 요소" : node.text))\"]")
                if node.kind == .ellipse { lines.append("class \(node.diagramID) ccrEllipse") }
            }
        }
        if nodes.contains(where: { $0.kind == .ellipse }) { lines.append("classDef ccrEllipse rx:50%,ry:50%") }
        if nodes.contains(where: { $0.kind == .line }) { lines.append("classDef ccrLineEndpoint fill:none,stroke:none") }
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
        case .invalidPacket: return "장면 4 MiB, PNG 5 MiB 한도 또는 패킷 바이트를 확인하세요."
        case .unresolvedPacket: return "이전 패킷의 접수 결과를 먼저 확인해야 합니다. 자동 재전송하지 않습니다."
        case .receiptMismatch: return "영수증의 패킷·대화·세션·해시가 일치하지 않습니다."
        case .outboxUnavailable: return "전송 원장을 읽거나 저장하지 못했습니다. 전송을 중단했습니다."
        }
    }
}

struct CanvasPacket: Codable, Equatable {
    static let sceneByteLimit = CanvasScene.localByteLimit
    let packetId: UUID
    let threadId: UUID
    let sessionId: String
    let targetMode: String?
    let imageSha256: String
    let sceneSha256: String
    let imagePNGBase64: String
    let sceneJSONBase64: String

    init(scene: CanvasScene, imagePNG: Data, session: VoiceSession, targetMode: String? = nil) throws {
        try scene.validateNativeInkProjection()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sceneBytes = try encoder.encode(scene)
        guard imagePNG.count <= 5*1024*1024, sceneBytes.count <= Self.sceneByteLimit,
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
              let bytes = Data(base64Encoded:sceneJSONBase64), bytes.count <= Self.sceneByteLimit,
              Self.sha(image) == imageSha256, Self.sha(bytes) == sceneSha256 else {
            throw CanvasSendError.invalidPacket
        }
        let scene = try JSONDecoder().decode(CanvasScene.self,from:bytes)
        try scene.validateNativeInkProjection()
        return scene
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

// current.json commits a complete generation; interrupted writes leave the previous generation readable.
final class CanvasFileWorkspace {
    enum Failure: LocalizedError {
        case permission, staleBookmark, conflict, invalidDocument, missingDocument, sandboxFolder
        var errorDescription: String? {
            switch self {
            case .permission: return "작업 폴더 접근 권한을 확인할 수 없습니다. 파일 앱에서 폴더를 다시 선택하세요."
            case .staleBookmark: return "저장 위치 연결이 오래됐습니다. 폴더를 다시 선택하세요. 원본과 미저장 입력은 보존했습니다."
            case .conflict: return "외부 파일이 변경됐습니다. 자동 저장을 멈췄습니다. 현재 그림을 다른 폴더에 안전 내보내거나 원본을 다시 여세요."
            case .invalidDocument: return "그림·구조·미리보기의 정합성을 확인할 수 없습니다. 기존 파일을 보존했습니다."
            case .missingDocument: return "연결한 원본 문서가 없습니다. 자동으로 새로 만들지 않습니다."
            case .sandboxFolder: return "앱 전용 폴더는 공용 원본으로 선택할 수 없습니다. 나의 iPad 또는 Obsidian 작업 폴더를 선택하세요."
            }
        }
    }
    struct Binding: Codable {
        let bookmark: Data
        let sceneID: UUID
        let savedSceneSHA: String
    }
    struct Head: Codable {
        let schema: String
        let sceneID: UUID
        let generation: UUID
        let sceneSHA: String
        let drawingSHA: String
        let previewSHA: String
    }
    struct Snapshot {
        let scene: CanvasScene
        let token: String
        let preview: Data
    }
    let folder: URL
    private let requiresScope: Bool
    init(folder: URL, requiresScope: Bool = true) {
        self.folder = folder
        self.requiresScope = requiresScope
    }
    static func bytes(_ scene: CanvasScene) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(scene)
    }
    static func sceneSHA(_ scene: CanvasScene) throws -> String { CanvasPacket.sha(try bytes(scene)) }
    func documentURL(_ id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString.lowercased() + ".sill",isDirectory:true)
    }
    private func scoped<T>(_ operation: () throws -> T) throws -> T {
        let access = folder.startAccessingSecurityScopedResource()
        guard access || !requiresScope else { throw Failure.permission }
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]).isDirectory == true,
              folder.resolvingSymlinksInPath().standardizedFileURL == folder.standardizedFileURL
        else { throw Failure.permission }
        return try operation()
    }
    private func coordinated<T>(writing: Bool, _ operation: (URL) throws -> T) throws -> T {
        try scoped {
            var coordinationError: NSError?
            var result: Result<T,Error>?
            let accessor: (URL) -> Void = { url in result = Result { try operation(url) } }
            let coordinator = NSFileCoordinator()
            if writing {
                coordinator.coordinate(writingItemAt:folder,options:.forMerging,error:&coordinationError,byAccessor:accessor)
            } else {
                coordinator.coordinate(readingItemAt:folder,options:[],error:&coordinationError,byAccessor:accessor)
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw Failure.permission }
            return try result.get()
        }
    }
    private func read(_ url: URL, limit: Int) throws -> Data {
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else { throw Failure.invalidDocument }
        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= limit else { throw Failure.invalidDocument }
        let bytes = try Data(contentsOf:url)
        guard bytes.count <= limit else { throw Failure.invalidDocument }
        return bytes
    }
    private func load(_ id: UUID, root: URL) throws -> Snapshot {
        let document = root.appendingPathComponent(id.uuidString.lowercased() + ".sill",isDirectory:true)
        let headBytes = try read(document.appendingPathComponent("current.json"),limit:4096)
        let head = try JSONDecoder().decode(Head.self,from:headBytes)
        guard head.schema == "ccr.sill-files/v1", head.sceneID == id else { throw Failure.invalidDocument }
        let generation = document.appendingPathComponent("revisions",isDirectory:true)
            .appendingPathComponent(head.generation.uuidString.lowercased(),isDirectory:true)
        let sceneBytes = try read(generation.appendingPathComponent("scene.json"),limit:CanvasScene.localByteLimit)
        let drawing = try read(generation.appendingPathComponent("drawing.pkdrawing"),limit:CanvasScene.localByteLimit)
        let preview = try read(generation.appendingPathComponent("preview.png"),limit:32 * 1024 * 1024)
        guard CanvasPacket.sha(sceneBytes) == head.sceneSHA, CanvasPacket.sha(drawing) == head.drawingSHA,
              CanvasPacket.sha(preview) == head.previewSHA else { throw Failure.invalidDocument }
        let scene = try JSONDecoder().decode(CanvasScene.self,from:sceneBytes)
        guard scene.id == id, scene.hasSupportedInkProjection,
              Data(base64Encoded:scene.drawingBase64) == drawing,
              scene.width.isFinite, scene.height.isFinite, scene.width > 0, scene.height > 0,
              scene.width <= 16384, scene.height <= 16384,
              scene.nodes.count < 1000, scene.strokes.count < 10000,
              scene.nodes.allSatisfy(\.hasValidRotation) else { throw Failure.invalidDocument }
        #if canImport(PencilKit, _version: 616)
        try scene.validateNativeInkProjection()
        if !drawing.isEmpty { _ = try PKDrawing(data:drawing) }
        #endif
        return Snapshot(scene:scene,token:CanvasPacket.sha(headBytes),preview:preview)
    }
    func load(_ id: UUID) throws -> Snapshot {
        try coordinated(writing:false) { try self.load(id,root:$0) }
    }
    func documents() throws -> [UUID] {
        try coordinated(writing:false) { root in
            try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
                .filter { $0.pathExtension == "sill" }
                .compactMap { UUID(uuidString:$0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.uuidString < $1.uuidString }
        }
    }
    @discardableResult
    func save(_ scene: CanvasScene, preview: Data, expected: String?) throws -> Snapshot {
        try scene.requireCompatibleNodeKinds()
        let sceneBytes = try Self.bytes(scene)
        guard sceneBytes.count <= CanvasScene.localByteLimit,
              let drawing = Data(base64Encoded:scene.drawingBase64),
              preview.count <= 32 * 1024 * 1024,
              preview.starts(with:[137,80,78,71,13,10,26,10]),
              scene.hasSupportedInkProjection,
              scene.width.isFinite, scene.height.isFinite, scene.width > 0, scene.height > 0,
              scene.width <= 16384, scene.height <= 16384,
              scene.nodes.count < 1000, scene.strokes.count < 10000,
              scene.nodes.allSatisfy(\.hasValidRotation) else { throw Failure.invalidDocument }
        #if canImport(PencilKit, _version: 616)
        try scene.validateNativeInkProjection()
        if !drawing.isEmpty { _ = try PKDrawing(data:drawing) }
        #endif
        return try coordinated(writing:true) { root in
            let document = root.appendingPathComponent(scene.id.uuidString.lowercased() + ".sill",isDirectory:true)
            if FileManager.default.fileExists(atPath:document.path) {
                guard let expected, let current = try? self.load(scene.id,root:root), current.token == expected else { throw Failure.conflict }
            } else if expected != nil { throw Failure.missingDocument }
            let generation = UUID()
            let directory = document.appendingPathComponent("revisions",isDirectory:true)
                .appendingPathComponent(generation.uuidString.lowercased(),isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try sceneBytes.write(to:directory.appendingPathComponent("scene.json"),options:.atomic)
            try drawing.write(to:directory.appendingPathComponent("drawing.pkdrawing"),options:.atomic)
            try preview.write(to:directory.appendingPathComponent("preview.png"),options:.atomic)
            let head = Head(schema:"ccr.sill-files/v1",sceneID:scene.id,generation:generation,
                sceneSHA:CanvasPacket.sha(sceneBytes),drawingSHA:CanvasPacket.sha(drawing),previewSHA:CanvasPacket.sha(preview))
            let headBytes = try JSONEncoder().encode(head)
            try headBytes.write(to:document.appendingPathComponent("current.json"),options:.atomic)
            return try self.load(scene.id,root:root)
        }
    }
}
