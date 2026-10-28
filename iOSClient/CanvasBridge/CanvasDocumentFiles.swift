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
        case permission, corrupt, conflict, pending, publicationUnconfirmed, unsupported
        var errorDescription: String? {
            switch self {
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
            guard result.count == Int(info.st_size) else { throw Failure.corrupt }
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
            return Snapshot(document:document,token:CanvasPacket.sha(headBytes),previews:[id:preview],legacy:true,publicationPending:try pending(directory))
        }
        guard schema == Self.headSchema else { throw Failure.unsupported }
        let head = try JSONDecoder().decode(Head.self,from:headBytes)
        guard head.documentID == id else { throw Failure.corrupt }
        let generation = try revisions.child(head.generation.uuidString.lowercased())
        let bytes = try generation.read("document.json",limit:CanvasDocument.byteLimit)
        let document = try JSONDecoder().decode(CanvasDocument.self,from:bytes)
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
            previews[scene.id] = preview
        }
        return Snapshot(document:document,token:CanvasPacket.sha(headBytes),previews:previews,legacy:false,publicationPending:try pending(directory))
    }
    func load(_ id: UUID) throws -> Snapshot {
        try coordinated(writing:false) { root in
            let dir = try root.child(id.uuidString.lowercased() + ".sill")
            return try snapshot(id,directory:dir,headBytes:dir.read("current.json",limit:256*1024))
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
            let dir = try root.child(document.id.uuidString.lowercased() + ".sill",create:true)
            try root.sync()
            let lock = openat(dir.fd,"writer.lock",O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,0o600)
            guard lock >= 0 else { throw Failure.permission }; defer { close(lock) }
            var lockInfo = stat()
            guard fstat(lock,&lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG else { throw Failure.permission }
            guard flock(lock,LOCK_EX) == 0 else { throw Failure.permission }; defer { _ = flock(lock,LOCK_UN) }
            guard try !pending(dir) else { throw Failure.pending }
            let base = try dir.exists("current.json") ? dir.read("current.json",limit:256*1024) : nil
            guard base.map(CanvasPacket.sha) == expected else { throw Failure.conflict }
            if let base { _ = try snapshot(document.id,directory:dir,headBytes:base) }
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
            try hooks.afterGeneration?()
            let key = generationID.uuidString.lowercased(), stage = "head-\(key).json", intent = "publish-\(key).json"
            if let base { try dir.writeNew("base-\(key).json",base) }
            try dir.writeNew(stage,headBytes)
            try dir.writeNew(intent,Data("문서 전체 세대 발행 결과 확인 전\n".utf8)); try dir.sync()
            var published = false
            do {
                let latest = try dir.exists("current.json") ? dir.read("current.json",limit:256*1024) : nil
                guard latest.map(CanvasPacket.sha) == expected else { throw Failure.conflict }
                try hooks.beforeExchange?()
                let flag = UInt32(base == nil ? RENAME_EXCL : RENAME_SWAP)
                guard renameatx_np(dir.fd,stage,dir.fd,"current.json",flag) == 0 else { throw Failure.conflict }
                published = true; try dir.sync()
                // 교환 후 충돌이면 외부 head가 stage에 남는다. 자동 rollback/성공 처리를 하지 않는다.
                if let base { guard try dir.read(stage,limit:256*1024) == base else { throw Failure.conflict } }
                try hooks.afterExchange?()
                guard try dir.read("current.json",limit:256*1024) == headBytes else { throw Failure.conflict }
                _ = try snapshot(document.id,directory:dir,headBytes:headBytes)
                guard renameatx_np(dir.fd,intent,dir.fd,"commit-\(key).json",UInt32(RENAME_EXCL)) == 0 else { throw Failure.publicationUnconfirmed }
                try dir.sync()
                return try snapshot(document.id,directory:dir,headBytes:headBytes)
            } catch {
                if published {
                    // 마지막 commit rename/readback 뒤 실패도 미확인으로 다시 표시한다.
                    if (try? dir.exists(intent)) == false {
                        try? dir.writeNew(intent,Data("문서 발행 후 확인 실패\n".utf8))
                        try? dir.sync()
                    }
                    throw Failure.publicationUnconfirmed
                }
                _ = renameatx_np(dir.fd,intent,dir.fd,"aborted-\(key).json",UInt32(RENAME_EXCL))
                throw error
            }
        }
    }
}
