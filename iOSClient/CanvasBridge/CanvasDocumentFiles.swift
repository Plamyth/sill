import Foundation
import Darwin

/// 문서 전체 세대를 저장한다. Store/UI/relay에 연결되지 않은 첫 구현 단위다.
final class CanvasDocumentFiles {
    static let headSchema = "ccr.sill-document-files/v2"
    struct PageAsset: Codable {
        let id: UUID
        let drawingSHA: String
        let previewSHA: String
    }
    struct Head: Codable {
        let schema: String
        let documentID: UUID
        let generation: UUID
        let documentSHA: String
        let pages: [PageAsset]
    }
    struct Snapshot {
        let document: CanvasDocument
        let token: String
        let previews: [UUID: Data]
        let legacy: Bool
        let publicationPending: Bool
    }
    enum Failure: LocalizedError, Equatable {
        case permission, corrupt, conflict, pending, publicationUnconfirmed, unsupported, busy
        var errorDescription: String? {
            switch self {
            case .busy: return "다른 문서 저장이 진행 중입니다. 현재 원본을 보존하며 저장을 보류합니다."
            case .permission: return "문서 폴더에 접근할 수 없습니다. 기존 원본을 유지합니다."
            case .corrupt: return "문서 세대의 바이트와 페이지 자료가 일치하지 않습니다. 원본을 보존합니다."
            case .conflict: return "외부 문서가 바뀌었습니다. 제안 세대와 원본을 보존했습니다."
            case .pending: return "이전 문서 저장 결과가 미확인입니다. 자동 저장을 중단합니다."
            case .publicationUnconfirmed: return "문서 저장 결과 미확인입니다. 이전·외부·제안 자료를 보존하며 후속 쓰기를 중단합니다."
            case .unsupported: return "지원하지 않는 문서 세대입니다. 구형 단일 장면으로 축소하지 않습니다."
            }
        }
    }
    struct Hooks {
        var afterGeneration: (() throws -> Void)?
        var beforeExchange: (() throws -> Void)?
        var afterExchange: (() throws -> Void)?
        var afterNoOpReadback: (() throws -> Void)?
    }
    // 임의 경로를 받지 않는다. owner/generation UUID에서 root 아래의 proposal 경로만 계산한다.
    struct BaseReference: Codable, Equatable {
        let schema: String
        let documentID: UUID
        let generationID: UUID
        let headSHA: String
    }
    private struct Publication: Codable {
        let schema: String
        let documentID: UUID
        let attemptID: UUID
        let proposalSHA: String
        let baseSHA: String?
        let baseReference: BaseReference?
    }
    private func publication(_ bytes: Data) throws -> Publication {
        guard let fields = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              Set(fields.keys).isSubset(of:["schema","documentID","attemptID","proposalSHA","baseSHA","baseReference"]) else { throw Failure.unsupported }
        if let ref = fields["baseReference"], !(ref is NSNull) {
            guard let object = ref as? [String:Any], Set(object.keys).isSubset(of:["schema","documentID","generationID","headSHA"]) else { throw Failure.unsupported }
        }
        let value = try JSONDecoder().decode(Publication.self,from:bytes)
        func hash(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard ["ccr.document-publication/v1","ccr.document-publication/v2"].contains(value.schema),
              hash(value.proposalSHA), value.baseSHA.map(hash) ?? true else { throw Failure.unsupported }
        if let ref = value.baseReference {
            guard value.schema == "ccr.document-publication/v2", ref.schema == "ccr.document-base-reference/v1",
                  ref.documentID == value.documentID, ref.generationID != value.attemptID,
                  ref.headSHA == value.baseSHA, hash(ref.headSHA) else { throw Failure.corrupt }
        }
        return value
    }
    let folder: URL
    private let requiresScope: Bool
    private let hooks: Hooks
    init(folder: URL, requiresScope: Bool = true, hooks: Hooks = .init()) {
        self.folder = folder.standardizedFileURL; self.requiresScope = requiresScope; self.hooks = hooks
    }
    func documentURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString.lowercased() + ".sill",isDirectory:true) }

    private final class Directory {
        let fd: Int32
        init(_ fd: Int32) throws { guard fd >= 0 else { throw Failure.permission }; self.fd = fd }
        deinit { close(fd) }
        func child(_ name: String, create: Bool = false) throws -> Directory {
            if create, mkdirat(fd,name,0o700) != 0, errno != EEXIST { throw Failure.permission }
            return try Directory(openat(fd,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        }
        func read(_ name: String, limit: Int) throws -> Data {
            let file = openat(fd,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw Failure.corrupt }; defer { close(file) }
            var info = stat()
            guard fstat(file,&info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= limit else { throw Failure.corrupt }
            var result = Data(), buffer = [UInt8](repeating:0,count:16384)
            while true {
                let size = Darwin.read(file,&buffer,buffer.count)
                if size == 0 { break }
                if size < 0 { if errno == EINTR { continue }; throw Failure.corrupt }
                guard result.count <= limit - size else { throw Failure.corrupt }
                result.append(contentsOf:buffer.prefix(size))
            }
            var end = stat(), entry = stat()
            guard result.count == Int(info.st_size), fstat(file,&end) == 0,
                  fstatat(fd,name,&entry,AT_SYMLINK_NOFOLLOW) == 0, (entry.st_mode & S_IFMT) == S_IFREG,
                  info.st_dev == entry.st_dev, info.st_ino == entry.st_ino,
                  info.st_size == end.st_size, info.st_mtimespec.tv_sec == end.st_mtimespec.tv_sec,
                  info.st_mtimespec.tv_nsec == end.st_mtimespec.tv_nsec else { throw Failure.corrupt }
            return result
        }
        func exists(_ name: String) throws -> Bool {
            var info = stat()
            if fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0 { return true }
            guard errno == ENOENT else { throw Failure.corrupt }; return false
        }
        func writeNew(_ name: String, _ bytes: Data) throws {
            let file = openat(fd,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
            guard file >= 0 else { throw Failure.permission }; defer { close(file) }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(file,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw Failure.permission }; offset += written
                }
            }
            guard fsync(file) == 0 else { throw Failure.permission }
        }
        func names() throws -> [String] {
            let copy = openat(fd,".",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard copy >= 0 else { throw Failure.permission }
            guard let stream = fdopendir(copy) else { close(copy); throw Failure.permission }
            defer { closedir(stream) }
            var result: [String] = []
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to:&entry.pointee.d_name) {
                    $0.withMemoryRebound(to:CChar.self,capacity:Int(entry.pointee.d_namlen)+1) { String(cString:$0) }
                }
                result.append(name)
            }
            return result
        }
        func sync() throws { guard fsync(fd) == 0 else { throw Failure.permission } }
        func isChild(_ child: Directory, named name: String) -> Bool {
            var opened = stat(), current = stat()
            return fstat(child.fd,&opened) == 0 && fstatat(fd,name,&current,AT_SYMLINK_NOFOLLOW) == 0 &&
                (current.st_mode & S_IFMT) == S_IFDIR && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
        }
        func requireChild(_ child: Directory, named name: String) throws {
            guard isChild(child,named:name) else { throw Failure.publicationUnconfirmed }
        }
    }
    private func coordinated<T>(writing: Bool, _ operation: (Directory) throws -> T) throws -> T {
        let access = folder.startAccessingSecurityScopedResource()
        guard access || !requiresScope else { throw Failure.permission }
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard folder.resolvingSymlinksInPath().standardizedFileURL == folder else { throw Failure.permission }
        var error: NSError?, result: Result<T,Error>?
        let accessor: (URL) -> Void = { url in
            result = Result {
                let root = try Directory(open(url.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
                var before = stat(); guard fstat(root.fd,&before) == 0 else { throw Failure.permission }
                let value = try operation(root)
                var after = stat()
                guard lstat(url.path,&after) == 0, before.st_dev == after.st_dev,
                      before.st_ino == after.st_ino else { throw Failure.publicationUnconfirmed }
                return value
            }
        }
        let coordinator = NSFileCoordinator()
        if writing { coordinator.coordinate(writingItemAt:folder,options:.forMerging,error:&error,byAccessor:accessor) }
        else { coordinator.coordinate(readingItemAt:folder,options:[],error:&error,byAccessor:accessor) }
        if let error { throw error }; guard let result else { throw Failure.permission }; return try result.get()
    }
    private func pending(_ directory: Directory) throws -> Bool {
        try directory.names().contains { $0.hasPrefix("publish-") && $0.hasSuffix(".json") }
    }
    private func snapshot(_ id: UUID, directory: Directory, headBytes: Data) throws -> Snapshot {
        guard let header = try JSONSerialization.jsonObject(with:headBytes) as? [String:Any],
              let schema = header["schema"] as? String else { throw Failure.corrupt }
        let allowed: Set<String> = schema == "ccr.sill-files/v1" ?
            ["schema","sceneID","generation","sceneSHA","drawingSHA","previewSHA"] :
            ["schema","documentID","generation","documentSHA","pages"]
        guard Set(header.keys).isSubset(of:allowed) else { throw Failure.unsupported }
        if let assets = header["pages"] as? [[String:Any]] {
            guard assets.allSatisfy({ Set($0.keys).isSubset(of:["id","drawingSHA","previewSHA"]) }) else { throw Failure.unsupported }
        }
        let revisions = try directory.child("revisions")
        if schema == "ccr.sill-files/v1" {
            let h = try JSONDecoder().decode(CanvasFileWorkspace.Head.self,from:headBytes)
            guard h.sceneID == id else { throw Failure.corrupt }
            let generation = try revisions.child(h.generation.uuidString.lowercased())
            let raw = try generation.read("scene.json",limit:CanvasScene.localByteLimit)
            let drawing = try generation.read("drawing.pkdrawing",limit:CanvasScene.localByteLimit)
            let preview = try generation.read("preview.png",limit:32*1024*1024)
            let document = try CanvasDocument.decodeLegacy(raw)
            guard document.id == id, CanvasPacket.sha(raw) == h.sceneSHA,
                  CanvasPacket.sha(drawing) == h.drawingSHA, CanvasPacket.sha(preview) == h.previewSHA,
                  Data(base64Encoded:document.activePage.drawingBase64) == drawing else { throw Failure.corrupt }
            try revisions.requireChild(generation,named:h.generation.uuidString.lowercased())
            try directory.requireChild(revisions,named:"revisions")
            return Snapshot(document:document,token:CanvasPacket.sha(headBytes),previews:[id:preview],legacy:true,publicationPending:try pending(directory))
        }
        guard schema == Self.headSchema else { throw Failure.unsupported }
        let head = try JSONDecoder().decode(Head.self,from:headBytes)
        guard head.documentID == id else { throw Failure.corrupt }
        let generation = try revisions.child(head.generation.uuidString.lowercased())
        let bytes = try generation.read("document.json",limit:CanvasDocument.byteLimit)
        let document = try CanvasDocument.decodeDocument(bytes)
        guard document.id == id, CanvasPacket.sha(bytes) == head.documentSHA,
              head.pages.map(\.id) == document.pages.map(\.id) else { throw Failure.corrupt }
        let pages = try generation.child("pages")
        var previews: [UUID:Data] = [:], previewBytes = 0
        for (scene,asset) in zip(document.pages,head.pages) {
            let page = try pages.child(scene.id.uuidString.lowercased())
            let drawing = try page.read("drawing.pkdrawing",limit:CanvasScene.localByteLimit)
            let preview = try page.read("preview.png",limit:32*1024*1024)
            previewBytes += preview.count
            guard previewBytes <= 32*1024*1024, preview.starts(with:[137,80,78,71,13,10,26,10]),
                  Data(base64Encoded:scene.drawingBase64) == drawing,
                  CanvasPacket.sha(drawing) == asset.drawingSHA, CanvasPacket.sha(preview) == asset.previewSHA else { throw Failure.corrupt }
            try pages.requireChild(page,named:scene.id.uuidString.lowercased())
            previews[scene.id] = preview
        }
        try generation.requireChild(pages,named:"pages")
        try revisions.requireChild(generation,named:head.generation.uuidString.lowercased())
        try directory.requireChild(revisions,named:"revisions")
        return Snapshot(document:document,token:CanvasPacket.sha(headBytes),previews:previews,legacy:false,publicationPending:try pending(directory))
    }
    private func pendingName(_ id: UUID) -> String { "document-pending-" + id.uuidString.lowercased() + ".json" }

    // 문서 디렉터리와 독립된 선택 폴더 아래에 완전한 세대를 보존한다.
    private func preserve(_ id: UUID, from source: Directory, headBytes: Data, to archive: Directory) throws {
        try archive.writeNew("observed-head.json",headBytes)
        _ = try snapshot(id,directory:source,headBytes:headBytes)
        let header = try JSONSerialization.jsonObject(with:headBytes) as! [String:Any]
        let revisions = try source.child("revisions"), copies = try archive.child("revisions",create:true)
        if header["schema"] as? String == "ccr.sill-files/v1" {
            let h = try JSONDecoder().decode(CanvasFileWorkspace.Head.self,from:headBytes)
            let src = try revisions.child(h.generation.uuidString.lowercased())
            let dst = try copies.child(h.generation.uuidString.lowercased(),create:true)
            for name in ["scene.json","drawing.pkdrawing","preview.png"] {
                try dst.writeNew(name,src.read(name,limit:name == "preview.png" ? 32*1024*1024 : CanvasScene.localByteLimit))
            }
            try dst.sync()
        } else {
            let h = try JSONDecoder().decode(Head.self,from:headBytes)
            let src = try revisions.child(h.generation.uuidString.lowercased())
            let dst = try copies.child(h.generation.uuidString.lowercased(),create:true)
            try dst.writeNew("document.json",src.read("document.json",limit:CanvasDocument.byteLimit))
            let srcPages = try src.child("pages"), dstPages = try dst.child("pages",create:true)
            for asset in h.pages {
                let name = asset.id.uuidString.lowercased(), a = try srcPages.child(name), b = try dstPages.child(name,create:true)
                try b.writeNew("drawing.pkdrawing",a.read("drawing.pkdrawing",limit:CanvasScene.localByteLimit))
                try b.writeNew("preview.png",a.read("preview.png",limit:32*1024*1024)); try b.sync()
            }
            try dstPages.sync(); try dst.sync()
        }
        try copies.sync(); try archive.writeNew("current.json",headBytes); try archive.sync()
        _ = try snapshot(id,directory:archive,headBytes:headBytes)
    }
    private func recoveryName(_ id: UUID) -> String { "document-recovery-" + id.uuidString.lowercased() }
    private func referencedBase(_ ref: BaseReference, root: Directory) throws -> Snapshot {
        guard ref.schema == "ccr.document-base-reference/v1" else { throw Failure.unsupported }
        let name = recoveryName(ref.documentID), key = ref.generationID.uuidString.lowercased()
        let recovery = try root.child(name), attempt = try recovery.child(key), source = try attempt.child("proposal")
        let committed = try attempt.read("committed.json",limit:256*1024), owner = try publication(committed)
        let raw = try source.read("current.json",limit:256*1024)
        guard owner.documentID == ref.documentID, owner.attemptID == ref.generationID,
              owner.proposalSHA == ref.headSHA, CanvasPacket.sha(raw) == ref.headSHA,
              try source.read("observed-head.json",limit:256*1024) == raw else { throw Failure.corrupt }
        let head = try JSONDecoder().decode(Head.self,from:raw)
        guard head.schema == Self.headSchema, head.documentID == ref.documentID,
              head.generation == ref.generationID else { throw Failure.corrupt }
        let result = try snapshot(ref.documentID,directory:source,headBytes:raw)
        guard !result.publicationPending else { throw Failure.pending }
        guard try attempt.read("committed.json",limit:256*1024) == committed,
              try source.read("current.json",limit:256*1024) == raw else { throw Failure.corrupt }
        try attempt.requireChild(source,named:"proposal"); try recovery.requireChild(attempt,named:key)
        try root.requireChild(recovery,named:name)
        return result
    }
    private func reusableBase(_ id: UUID, raw: Data, root: Directory) throws -> BaseReference? {
        let header = try JSONSerialization.jsonObject(with:raw) as! [String:Any]
        if header["schema"] as? String != Self.headSchema { return nil } // legacy는 독립 사본을 유지한다.
        let head = try JSONDecoder().decode(Head.self,from:raw), name = recoveryName(id)
        guard try root.exists(name) else { return nil }
        let recovery = try root.child(name), key = head.generation.uuidString.lowercased()
        guard try recovery.exists(key) else { return nil } // 외부 generation/첫 편입은 기존 전체 보존 경로.
        let attempt = try recovery.child(key)
        guard try attempt.exists("committed.json") else { throw Failure.pending }
        let ref = BaseReference(schema:"ccr.document-base-reference/v1",documentID:id,generationID:head.generation,headSHA:CanvasPacket.sha(raw))
        _ = try referencedBase(ref,root:root)
        return ref
    }
    /// 명시 복구 비교를 위한 읽기 전용 API. scene 설치·선택·원장 해제는 하지 않는다.
    func recoveryBase(_ id: UUID, attemptID: UUID) throws -> Snapshot {
        try coordinated(writing:false) { root in
            let name = recoveryName(id), key = attemptID.uuidString.lowercased()
            let recovery = try root.child(name), attempt = try recovery.child(key)
            let rawRecord = try attempt.read("attempt.json",limit:256*1024)
            let record = try publication(rawRecord)
            guard record.documentID == id, record.attemptID == attemptID, let expected = record.baseSHA else { throw Failure.corrupt }
            let result: Snapshot
            if try attempt.exists("base") {
                let copy = try attempt.child("base"), raw = try copy.read("current.json",limit:256*1024)
                guard CanvasPacket.sha(raw) == expected else { throw Failure.corrupt }
                result = try snapshot(id,directory:copy,headBytes:raw)
                try attempt.requireChild(copy,named:"base")
            } else {
                guard let ref = record.baseReference else { throw Failure.corrupt }
                result = try referencedBase(ref,root:root)
            }
            guard try attempt.read("attempt.json",limit:256*1024) == rawRecord else { throw Failure.corrupt }
            try recovery.requireChild(attempt,named:key); try root.requireChild(recovery,named:name)
            let held = try root.exists(pendingName(id))
            return Snapshot(document:result.document,token:result.token,previews:result.previews,
                            legacy:result.legacy,publicationPending:held || result.publicationPending)
        }
    }
    func load(_ id: UUID) throws -> Snapshot {
        try coordinated(writing:false) { root in
            let held = try root.exists(pendingName(id)), name = id.uuidString.lowercased() + ".sill"
            do {
                let dir = try root.child(name), head = try dir.read("current.json",limit:256*1024)
                let result = try snapshot(id,directory:dir,headBytes:head)
                try root.requireChild(dir,named:name)
                guard try dir.read("current.json",limit:256*1024) == head else { throw Failure.publicationUnconfirmed }
                let currentHeld = try root.exists(pendingName(id))
                return Snapshot(document:result.document,token:result.token,previews:result.previews,
                                legacy:result.legacy,publicationPending:held || result.publicationPending || currentHeld)
            } catch { if held { throw Failure.pending }; throw error }
        }
    }
    @discardableResult
    func save(_ document: CanvasDocument, previews: [UUID:Data], expected: String?) throws -> Snapshot {
        try document.validate()
        guard Set(previews.keys) == Set(document.pages.map(\.id)),
              previews.values.reduce(0,{ $0 + $1.count }) <= 32*1024*1024,
              previews.values.allSatisfy({ $0.starts(with:[137,80,78,71,13,10,26,10]) }) else { throw Failure.corrupt }
        let bytes = try document.bytes()
        return try coordinated(writing:true) { root in
            let name = document.id.uuidString.lowercased() + ".sill", rootIntent = pendingName(document.id)
            guard try !root.exists(rootIntent) else { throw Failure.pending }
            let dir = try root.child(name,create:true)
            try root.sync()
            let lock = openat(dir.fd,"writer.lock",O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,0o600)
            guard lock >= 0 else { throw Failure.permission }; defer { close(lock) }
            var lockInfo = stat()
            guard fstat(lock,&lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG else { throw Failure.permission }
            guard flock(lock,LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.busy }
                throw Failure.permission
            }
            defer { _ = flock(lock,LOCK_UN) }
            try root.requireChild(dir,named:name)
            guard try !pending(dir) else { throw Failure.pending }
            let base = try dir.exists("current.json") ? dir.read("current.json",limit:256*1024) : nil
            guard base.map(CanvasPacket.sha) == expected else { throw Failure.conflict }
            if let base {
                let original = try snapshot(document.id,directory:dir,headBytes:base)
                if !original.legacy, try original.document.bytes() == bytes, original.previews == previews {
                    try hooks.afterNoOpReadback?()
                    let canonical = try root.child(name)
                    try root.requireChild(dir,named:name)
                    guard try canonical.read("current.json",limit:256*1024) == base else { throw Failure.conflict }
                    let checked = try snapshot(document.id,directory:canonical,headBytes:base)
                    try root.requireChild(canonical,named:name); try root.requireChild(dir,named:name)
                    guard try canonical.read("current.json",limit:256*1024) == base,
                          try !root.exists(rootIntent), !checked.publicationPending else { throw Failure.pending }
                    return checked
                }
            }
            let baseReference = try base.map { try reusableBase(document.id,raw:$0,root:root) } ?? nil
            let revisions = try dir.child("revisions",create:true), generationID = UUID()
            let generation = try revisions.child(generationID.uuidString.lowercased(),create:true)
            let pages = try generation.child("pages",create:true)
            var assets: [PageAsset] = []
            for scene in document.pages {
                guard let drawing = Data(base64Encoded:scene.drawingBase64), let preview = previews[scene.id] else { throw Failure.corrupt }
                let page = try pages.child(scene.id.uuidString.lowercased(),create:true)
                try page.writeNew("drawing.pkdrawing",drawing); try page.writeNew("preview.png",preview); try page.sync()
                assets.append(PageAsset(id:scene.id,drawingSHA:CanvasPacket.sha(drawing),previewSHA:CanvasPacket.sha(preview)))
            }
            try pages.sync(); try generation.writeNew("document.json",bytes); try generation.sync(); try revisions.sync()
            let head = Head(schema:Self.headSchema,documentID:document.id,generation:generationID,
                            documentSHA:CanvasPacket.sha(bytes),pages:assets)
            let headBytes = try JSONEncoder().encode(head)
            _ = try snapshot(document.id,directory:dir,headBytes:headBytes)
            let key = generationID.uuidString.lowercased(), stage = "head-\(key).json", intent = "publish-\(key).json"
            let recovery = try root.child("document-recovery-" + document.id.uuidString.lowercased(),create:true)
            let archive = try recovery.child(key,create:true)
            try archive.sync(); try recovery.sync(); try root.sync()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let intentBytes = try encoder.encode(Publication(schema:"ccr.document-publication/v2",documentID:document.id,
                attemptID:generationID,proposalSHA:CanvasPacket.sha(headBytes),baseSHA:base.map(CanvasPacket.sha),baseReference:baseReference))
            _ = try publication(intentBytes)
            try archive.writeNew("attempt.json",intentBytes); try archive.sync()
            try root.writeNew(rootIntent,intentBytes); try root.sync()
            var published = false
            func canonicalSnapshot() throws -> Snapshot {
                let canonical = try root.child(name)
                try root.requireChild(dir,named:name)
                guard try canonical.read("current.json",limit:256*1024) == headBytes else { throw Failure.conflict }
                let result = try snapshot(document.id,directory:canonical,headBytes:headBytes)
                if let ref = baseReference { _ = try referencedBase(ref,root:root) }
                try root.requireChild(canonical,named:name)
                try root.requireChild(dir,named:name)
                guard try canonical.read("current.json",limit:256*1024) == headBytes else { throw Failure.conflict }
                return result
            }
            do {
                if let ref = baseReference { _ = try referencedBase(ref,root:root) }
                else if let base { try preserve(document.id,from:dir,headBytes:base,to:archive.child("base",create:true)) }
                try preserve(document.id,from:dir,headBytes:headBytes,to:archive.child("proposal",create:true))
                try archive.sync(); try recovery.sync(); try root.sync()
                try hooks.afterGeneration?()
                try root.requireChild(dir,named:name)
                if let base { try dir.writeNew("base-\(key).json",base) }
                try dir.writeNew(stage,headBytes)
                try dir.writeNew(intent,intentBytes); try dir.sync()
                let latest = try dir.exists("current.json") ? dir.read("current.json",limit:256*1024) : nil
                guard latest.map(CanvasPacket.sha) == expected else { throw Failure.conflict }
                try hooks.beforeExchange?()
                if let ref = baseReference { _ = try referencedBase(ref,root:root) }
                try root.requireChild(dir,named:name)
                let flag = UInt32(base == nil ? RENAME_EXCL : RENAME_SWAP)
                guard renameatx_np(dir.fd,stage,dir.fd,"current.json",flag) == 0 else { throw Failure.conflict }
                published = true; try dir.sync()
                if let base { guard try dir.read(stage,limit:256*1024) == base else { throw Failure.conflict } }
                try hooks.afterExchange?()
                _ = try canonicalSnapshot()
                guard renameatx_np(dir.fd,intent,dir.fd,"commit-\(key).json",UInt32(RENAME_EXCL)) == 0 else { throw Failure.publicationUnconfirmed }
                try dir.sync()
                _ = try canonicalSnapshot()
                guard try root.read(rootIntent,limit:256*1024) == intentBytes else { throw Failure.publicationUnconfirmed }
                try root.requireChild(recovery,named:recoveryName(document.id)); try recovery.requireChild(archive,named:key)
                guard renameatx_np(root.fd,rootIntent,archive.fd,"committed.json",UInt32(RENAME_EXCL)) == 0 else { throw Failure.publicationUnconfirmed }
                try archive.sync(); try root.sync()
                return try canonicalSnapshot()
            } catch {
                if published || !root.isChild(dir,named:name) {
                    if (try? root.exists(rootIntent)) == false { try? root.writeNew(rootIntent,intentBytes); try? root.sync() }
                    if (try? dir.exists(intent)) == false { try? dir.writeNew(intent,intentBytes); try? dir.sync() }
                    if baseReference != nil, let base, (try? archive.exists("base")) == false {
                        try? preserve(document.id,from:dir,headBytes:base,to:archive.child("base",create:true))
                    }
                    // 외부 head와 세대도 별도 보존한다. 알 수 없는 head는 raw 관측 바이트만 남긴다.
                    if let displaced = try? dir.read(stage,limit:256*1024), displaced != base {
                        try? preserve(document.id,from:dir,headBytes:displaced,to:archive.child("displaced",create:true))
                    }
                    if let external = try? root.child(name), let observed = try? external.read("current.json",limit:256*1024) {
                        try? preserve(document.id,from:external,headBytes:observed,to:archive.child("external",create:true))
                    }
                    try? archive.sync(); try? recovery.sync(); try? root.sync()
                    throw Failure.publicationUnconfirmed
                }
                _ = renameatx_np(dir.fd,intent,dir.fd,"aborted-\(key).json",UInt32(RENAME_EXCL))
                if renameatx_np(root.fd,rootIntent,archive.fd,"aborted.json",UInt32(RENAME_EXCL)) == 0 {
                    try? archive.sync(); try? root.sync()
                }
                throw error
            }
        }
    }
}
