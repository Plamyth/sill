import Foundation
import Darwin
#if canImport(FoundationXML)
import FoundationXML
#endif
import zlib

enum VaultEPUBError: LocalizedError {
    case invalid, unsupported, tooLarge, changed, selection
    var errorDescription: String? {
        switch self {
        case .invalid: return "EPUB 원본·구조·자산을 확인하지 못했습니다. 원본을 보존합니다."
        case .unsupported: return "이 EPUB의 압축·보안·본문 형식은 지원하지 않습니다. 원본을 실행하거나 바꾸지 않았습니다."
        case .tooLarge: return "EPUB 읽기 한도를 넘었습니다. 원본을 보존합니다."
        case .changed: return "EPUB 원문이 바뀌었습니다. 이전 앵커를 적용하지 않으며 발췌 노트를 보존합니다."
        case .selection: return "한 원문 문단 안의 글자를 선택하세요."
        }
    }
}

struct VaultEPUBSnapshot: Codable {
    static let byteLimit = 32 * 1024 * 1024
    let path: String, sha256: String, dataBase64: String
    var sourceID: String { "epub-" + CanvasPacket.sha(Data(path.utf8)) }
    static func validPath(_ value: String) -> Bool {
        value.hasSuffix(".epub") && !value.contains(":") && VaultNoteReference.validPath(String(value.dropLast(5)) + ".md") &&
        !value.contains(where:{ $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) &&
        !value.contains(where:{ "[]#|".contains($0) })
    }
    init(path: String, bytes: Data) throws {
        guard Self.validPath(path) else { throw VaultEPUBError.invalid }
        guard bytes.count <= Self.byteLimit else { throw VaultEPUBError.tooLarge }
        self.path = path; sha256 = CanvasPacket.sha(bytes); dataBase64 = bytes.base64EncodedString()
    }
    func bytes(at expected: String) throws -> Data {
        guard path.utf8.elementsEqual(expected.utf8), Self.validPath(path),
              dataBase64.utf8.count <= 4 * ((Self.byteLimit + 2) / 3),
              let bytes = Data(base64Encoded:dataBase64), bytes.count <= Self.byteLimit,
              bytes.base64EncodedString() == dataBase64, CanvasPacket.sha(bytes) == sha256 else { throw VaultEPUBError.changed }
        return bytes
    }
    static func read(_ url: URL, path: String, expectedSHA: String? = nil) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?, result: Result<Self,Error>?
        NSFileCoordinator().coordinate(readingItemAt:url,options:[],error:&error) { coordinated in
            result = Result {
                let fd = open(coordinated.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw VaultEPUBError.invalid }; defer { close(fd) }
                var before = stat(), after = stat(), named = stat()
                guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG,
                      before.st_size >= 0, before.st_size <= byteLimit else { throw VaultEPUBError.tooLarge }
                let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
                var bytes = Data()
                while let chunk = try handle.read(upToCount:min(65536,byteLimit+1-bytes.count)), !chunk.isEmpty {
                    bytes.append(chunk); guard bytes.count <= byteLimit else { throw VaultEPUBError.tooLarge }
                }
                guard fstat(fd,&after) == 0, lstat(coordinated.path,&named) == 0,
                      before.st_ino == named.st_ino, before.st_dev == named.st_dev,
                      before.st_size == after.st_size, bytes.count == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw VaultEPUBError.changed }
                let snapshot = try Self(path:path,bytes:bytes)
                guard expectedSHA == nil || snapshot.sha256 == expectedSHA else { throw VaultEPUBError.changed }
                return snapshot
            }
        }
        if let error { throw error }; guard let result else { throw VaultEPUBError.invalid }; return try result.get()
    }
    func writeVerifiedCopy(to url: URL) throws {
        let bytes = try self.bytes(at:path)
        // Exclusive create: an existing user original is never replaced by an import/copy.
        try bytes.write(to:url,options:.withoutOverwriting)
        guard try Self.read(url,path:path,expectedSHA:sha256).bytes(at:path) == bytes else { throw VaultEPUBError.changed }
    }
}

// No extraction, subprocess, WebView, resource fetch, or executable HTML enters this boundary.
private struct EPUBArchive {
    static let entryLimit = 4 * 1024 * 1024
    let files: [String:Data]
    static func name(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf8.count <= 1024, !name.hasPrefix("/"), !name.contains("\\"),
              !name.contains(":"), !name.contains("%"), !name.contains("#"), !name.contains("?"),
              name.utf8.elementsEqual(name.precomposedStringWithCanonicalMapping.utf8),
              !name.contains(where:{ $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }),
              name.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw VaultEPUBError.unsupported }
        return name
    }
    static func resolve(_ href: String, from path: String) throws -> (String,String?) {
        let parts = href.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)
        guard !href.contains(":"), !href.contains("%"), !href.contains("\\"), !href.hasPrefix("/"), !href.contains("?") else { throw VaultEPUBError.unsupported }
        var result = path.split(separator:"/").dropLast().map(String.init)
        if parts[0].isEmpty { result = path.split(separator:"/").map(String.init) }
        else {
            for component in parts[0].split(separator:"/",omittingEmptySubsequences:false) {
                if component == ".." { guard !result.isEmpty else { throw VaultEPUBError.invalid }; result.removeLast() }
                else if component != "." { guard !component.isEmpty else { throw VaultEPUBError.invalid }; result.append(String(component)) }
            }
        }
        return (try name(result.joined(separator:"/")),parts.count == 2 ? String(parts[1]) : nil)
    }
    init(_ data: Data) throws {
        let b = [UInt8](data)
        func number(_ at: Int,_ count: Int) throws -> Int {
            guard at >= 0, at <= b.count, count <= b.count-at else { throw VaultEPUBError.invalid }
            return (0..<count).reduce(0) { $0 | Int(b[at+$1]) << (8*$1) }
        }
        guard b.count >= 22 else { throw VaultEPUBError.invalid }
        let end = (max(0,b.count-65557)...b.count-22).reversed().first { (try? number($0,4)) == 0x06054b50 }
        guard let end, try end + 22 + number(end+20,2) == b.count,
              try number(end+4,2) == 0, try number(end+6,2) == 0,
              try number(end+8,2) == number(end+10,2) else { throw VaultEPUBError.unsupported }
        let count = try number(end+10,2), size = try number(end+12,4), start = try number(end+16,4)
        guard count > 0, count <= 512, start <= end, size == end-start else { throw VaultEPUBError.tooLarge }
        var offset = start, total = 0, values: [String:Data] = [:], names = Set<String>(), spans = [(Int,Int)]()
        for _ in 0..<count {
            guard try number(offset,4) == 0x02014b50 else { throw VaultEPUBError.invalid }
            let flags = try number(offset+8,2), method = try number(offset+10,2), crc = try number(offset+16,4)
            let packed = try number(offset+20,4), length = try number(offset+24,4), n = try number(offset+28,2)
            let extra = try number(offset+30,2), comment = try number(offset+32,2), local = try number(offset+42,4)
            let kind = try number(offset+38,4) >> 16 & 0xf000
            guard flags & ~0x080e == 0, [0,8].contains(method), extra == 0,
                  try number(offset+34,2) == 0, [0,0x8000,0x4000].contains(kind) else { throw VaultEPUBError.unsupported }
            guard n > 0, offset+46+n+comment <= end, packed <= data.count, length <= Self.entryLimit,
                  length <= max(1024,packed*128) else { throw VaultEPUBError.tooLarge }
            let raw = Data(b[(offset+46)..<(offset+46+n)])
            guard let rawName = String(data:raw,encoding:.utf8), flags & 0x800 != 0 || raw.allSatisfy({ $0 < 128 }) else { throw VaultEPUBError.unsupported }
            let directory = rawName.hasSuffix("/"), name = try Self.name(directory ? String(rawName.dropLast()) : rawName)
            guard kind != 0x4000 || directory, kind != 0x8000 || !directory else { throw VaultEPUBError.invalid }
            guard names.insert(name).inserted else { throw VaultEPUBError.invalid }
            total += length; guard total <= 64*1024*1024 else { throw VaultEPUBError.tooLarge }
            guard local < start, try number(local,4) == 0x04034b50,
                  try number(local+6,2) == flags, try number(local+8,2) == method,
                  try number(local+26,2) == n, try number(local+28,2) == 0 else { throw VaultEPUBError.invalid }
            let body = local+30+n
            guard body <= start, packed <= start-body, Data(b[(local+30)..<body]) == raw else { throw VaultEPUBError.invalid }
            if flags & 8 == 0 {
                guard try number(local+14,4) == crc, try number(local+18,4) == packed, try number(local+22,4) == length else { throw VaultEPUBError.invalid }
            }
            var bodyEnd = body+packed
            if flags & 8 != 0 {
                let descriptor = try number(bodyEnd,4) == 0x08074b50 ? bodyEnd+4 : bodyEnd
                guard descriptor+12 <= start, try number(descriptor,4) == crc,
                      try number(descriptor+4,4) == packed, try number(descriptor+8,4) == length else { throw VaultEPUBError.invalid }
                bodyEnd = descriptor+12
            }
            if name == "mimetype" { guard local == 0, method == 0, flags & 8 == 0 else { throw VaultEPUBError.unsupported } }
            spans.append((local,bodyEnd))
            let compressed = Data(b[body..<(body+packed)]), decoded: Data
            if method == 0 { guard packed == length else { throw VaultEPUBError.invalid }; decoded = compressed }
            else {
                var stream = z_stream(), output = [UInt8](repeating:0,count:length+1)
                guard inflateInit2_(&stream,-15,zlibVersion(),Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw VaultEPUBError.invalid }
                defer { inflateEnd(&stream) }
                let code = compressed.withUnsafeBytes { input in output.withUnsafeMutableBytes { target in
                    stream.next_in = UnsafeMutablePointer(mutating:input.bindMemory(to:Bytef.self).baseAddress)
                    stream.avail_in = uInt(packed); stream.next_out = target.bindMemory(to:Bytef.self).baseAddress; stream.avail_out = uInt(length+1)
                    return inflate(&stream,Z_FINISH)
                } }
                guard code == Z_STREAM_END, stream.total_in == packed, stream.total_out == length else { throw VaultEPUBError.invalid }
                decoded = Data(output.prefix(length))
            }
            let actual = decoded.withUnsafeBytes { crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(decoded.count)) }
            guard actual == crc else { throw VaultEPUBError.invalid }
            if directory { guard decoded.isEmpty else { throw VaultEPUBError.invalid } }
            else { values[name] = decoded }
            offset += 46+n+comment
        }
        let ordered = spans.sorted(by:{$0.0 < $1.0})
        guard offset == end, ordered.enumerated().allSatisfy({ i,s in i == 0 || ordered[i-1].1 <= s.0 }),
              values["mimetype"] == Data("application/epub+zip".utf8),
              !names.contains("META-INF/encryption.xml"), !names.contains("META-INF/rights.xml") else { throw VaultEPUBError.unsupported }
        files = values
    }
}

private final class EPUBXML: NSObject, XMLParserDelegate {
    final class Element {
        let name: String, namespace: String?, attributes: [String:String]
        var children: [Element] = [], content: [Any] = []
        init(_ name: String,_ namespace: String?,_ attributes: [String:String]) { self.name = name; self.namespace = namespace; self.attributes = attributes }
        var text: String { name == "br" ? "\n" : content.map { ($0 as? String) ?? ($0 as! Element).text }.joined() }
        func all(_ name: String) -> [Element] { (self.name == name ? [self] : []) + children.flatMap { $0.all(name) } }
    }
    var root: Element?, stack: [Element] = [], failed = false, count = 0
    static func read(_ bytes: Data) throws -> Element {
        guard bytes.count <= EPUBArchive.entryLimit, let text = String(data:bytes,encoding:.utf8), !text.contains("\0") else { throw VaultEPUBError.invalid }
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw VaultEPUBError.unsupported }
        if let declaration = text.range(of:"^\\s*<\\?xml[^?]*encoding\\s*=\\s*['\"]([^'\"]+)['\"]",options:[.regularExpression,.caseInsensitive]) {
            guard text[declaration].lowercased().hasSuffix("'utf-8'") || text[declaration].lowercased().hasSuffix("\"utf-8\"") else { throw VaultEPUBError.unsupported }
        }
        let delegate = EPUBXML(), parser = XMLParser(data:bytes)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.failed, let root = delegate.root, delegate.stack.isEmpty else { throw VaultEPUBError.unsupported }
        return root
    }
    func parser(_ parser: XMLParser,didStartElement name: String,namespaceURI: String?,qualifiedName: String?,attributes: [String:String]) {
        count += 1
        if count > 20000 || stack.count >= 64 || attributes.count > 64 || attributes.values.contains(where:{$0.utf8.count > 65536}) { failed = true; parser.abortParsing(); return }
        let element = Element(name,namespaceURI,attributes)
        if let parent = stack.last { parent.children.append(element); parent.content.append(element) }
        else { if root != nil { failed = true }; root = element }
        stack.append(element)
    }
    func parser(_ parser: XMLParser,foundCharacters text: String) { stack.last?.content.append(text) }
    func parser(_ parser: XMLParser,foundCDATA data: Data) { if let text = String(data:data,encoding:.utf8) { stack.last?.content.append(text) } else { failed = true } }
    func parser(_ parser: XMLParser,didEndElement: String,namespaceURI: String?,qualifiedName: String?) { if !stack.isEmpty { stack.removeLast() } }
    func parser(_ parser: XMLParser,resolveExternalEntityName: String,systemID: String?) -> Data? { failed = true; parser.abortParsing(); return nil }
}

struct VaultEPUBBook {
    struct Paragraph { let xpath: String, text: String, fragment: String? }
    struct Chapter { let id: String, path: String, paragraphs: [Paragraph] }
    struct TOCEntry: Identifiable { let id: Int, title: String, chapter: Int, fragment: String?, depth: Int }
    let snapshot: VaultEPUBSnapshot
    let chapters: [Chapter], toc: [TOCEntry]
    init(snapshot: VaultEPUBSnapshot) throws {
        let archive = try EPUBArchive(snapshot.bytes(at:snapshot.path))
        func xml(_ path: String) throws -> EPUBXML.Element { guard let data = archive.files[path] else { throw VaultEPUBError.invalid }; return try EPUBXML.read(data) }
        // Even unused XML resources must not smuggle active or externally resolved content into a later caller.
        for (path,bytes) in archive.files {
            let ext = (path as NSString).pathExtension.lowercased()
            guard !["js","mjs","wasm"].contains(ext) else { throw VaultEPUBError.unsupported }
            if ext == "css" {
                guard let css = String(data:bytes,encoding:.utf8), css.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VaultEPUBError.unsupported }
            }
            if ["xml","xhtml","html","opf","ncx"].contains(ext) {
                func safe(_ node: EPUBXML.Element) throws {
                    guard !["script","iframe","object","embed","form","input","audio","video"].contains(node.name.lowercased()) else { throw VaultEPUBError.unsupported }
                    if node.name.lowercased() == "style", !node.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw VaultEPUBError.unsupported }
                    for (name,value) in node.attributes {
                        guard !name.lowercased().hasPrefix("on"), name.lowercased() != "hidden",
                              name.lowercased() != "style" || value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VaultEPUBError.unsupported }
                        if ["href","src","action"].contains(String(name.lowercased().split(separator:":").last ?? "")) { _ = try EPUBArchive.resolve(value,from:path) }
                    }
                    for child in node.children { try safe(child) }
                }
                try safe(EPUBXML.read(bytes))
            }
        }
        let container = try xml("META-INF/container.xml"), roots = container.all("rootfile")
        guard container.name == "container", container.namespace == "urn:oasis:names:tc:opendocument:xmlns:container",
              roots.count == 1, let opf = roots[0].attributes["full-path"] else { throw VaultEPUBError.invalid }
        _ = try EPUBArchive.name(opf)
        let package = try xml(opf)
        guard package.name == "package", package.namespace == "http://www.idpf.org/2007/opf", ["2.0","3.0"].contains(package.attributes["version"] ?? ""),
              package.all("manifest").count == 1, package.all("spine").count == 1 else { throw VaultEPUBError.unsupported }
        var manifest: [String:(String,String)] = [:]
        for item in package.all("manifest")[0].children {
            guard item.name == "item", let id = item.attributes["id"], !id.isEmpty, id.utf8.count <= 256,
                  manifest[id] == nil, let href = item.attributes["href"], let type = item.attributes["media-type"],
                  !(item.attributes["properties"] ?? "").split(separator:" ").contains(where:{ ["scripted","remote-resources"].contains($0) }) else { throw VaultEPUBError.unsupported }
            let (path,fragment) = try EPUBArchive.resolve(href,from:opf)
            guard fragment == nil, archive.files[path] != nil else { throw VaultEPUBError.invalid }
            manifest[id] = (path,type)
        }
        let spine = package.all("spine")[0]
        guard !spine.children.isEmpty, spine.children.count <= 128 else { throw VaultEPUBError.tooLarge }
        var chapters: [Chapter] = [], paths = Set<String>()
        for item in spine.children {
            guard item.name == "itemref", let id = item.attributes["idref"], let (path,type) = manifest[id],
                  type == "application/xhtml+xml", paths.insert(path).inserted else { throw VaultEPUBError.unsupported }
            let root = try xml(path)
            guard root.name == "html", root.namespace == "http://www.w3.org/1999/xhtml", root.all("body").count == 1 else { throw VaultEPUBError.invalid }
            let allowed: Set<String> = ["html","head","title","meta","link","style","body","div","section","article","p","span","h1","h2","h3","h4","h5","h6","a","em","strong","i","b","u","s","small","sup","sub","br","hr","ol","ul","li","blockquote","pre","code"]
            let blocks: Set<String> = ["p","h1","h2","h3","h4","h5","h6","li","blockquote","pre"]
            var paragraphs: [Paragraph] = [], fragments = Set<String>()
            func walk(_ node: EPUBXML.Element,_ xpath: String,_ insideBody: Bool = false,_ insideBlock: Bool = false) throws {
                guard allowed.contains(node.name) else { throw VaultEPUBError.unsupported }
                if let id = node.attributes["id"] { guard fragments.insert(id).inserted else { throw VaultEPUBError.invalid } }
                for (name,value) in node.attributes {
                    guard !name.lowercased().hasPrefix("on") else { throw VaultEPUBError.unsupported }
                    if ["href","src"].contains(name) { _ = try EPUBArchive.resolve(value,from:path) }
                }
                let leaf = blocks.contains(node.name) && !node.children.contains(where:{ child in blocks.contains(child.name) || blocks.contains(where:{!child.all($0).isEmpty}) })
                if leaf {
                    if !node.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { paragraphs.append(.init(xpath:xpath,text:node.text,fragment:node.attributes["id"])) }
                }
                let body = insideBody || node.name == "body", block = insideBlock || leaf
                if body && !block && node.content.contains(where:{ ($0 as? String)?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false }) { throw VaultEPUBError.unsupported }
                var indexes: [String:Int] = [:]
                for child in node.children { indexes[child.name,default:0] += 1; try walk(child,xpath + "/\(child.name)[\(indexes[child.name]!)]",body,block) }
            }
            try walk(root,"/html[1]")
            guard !paragraphs.isEmpty else { throw VaultEPUBError.unsupported }
            chapters.append(.init(id:id,path:path,paragraphs:paragraphs))
        }
        var toc: [TOCEntry] = []
        if let id = spine.attributes["toc"] {
            guard let (ncx,type) = manifest[id], type == "application/x-dtbncx+xml" else { throw VaultEPUBError.invalid }
            let nav = try xml(ncx)
            guard nav.name == "ncx", nav.namespace == "http://www.daisy.org/z3986/2005/ncx/", nav.all("navMap").count == 1 else { throw VaultEPUBError.invalid }
            func visit(_ node: EPUBXML.Element,_ depth: Int) throws {
                guard depth <= 8, toc.count < 256, node.name == "navPoint",
                      let content = node.children.first(where:{$0.name == "content"}), let src = content.attributes["src"],
                      let label = node.children.first(where:{$0.name == "navLabel"})?.text, !label.isEmpty, label.utf8.count <= 1024 else { throw VaultEPUBError.unsupported }
                let (path,fragment) = try EPUBArchive.resolve(src,from:ncx)
                guard let chapter = chapters.firstIndex(where:{$0.path == path}), fragment == nil || chapters[chapter].paragraphs.contains(where:{$0.fragment == fragment}) else { throw VaultEPUBError.unsupported }
                toc.append(.init(id:toc.count,title:label,chapter:chapter,fragment:fragment,depth:depth))
                for child in node.children where child.name == "navPoint" { try visit(child,depth+1) }
            }
            for point in nav.all("navMap")[0].children { try visit(point,0) }
        }
        self.snapshot = snapshot; self.chapters = chapters; self.toc = toc
    }
}
