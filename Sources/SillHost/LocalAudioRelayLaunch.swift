import Foundation
import CryptoKit
import Darwin
import Security

enum LocalAudioRelayLaunchFailure: Error, LocalizedError, Equatable {
    case invalidPackage(String)
    case signature(Int32)
    case unsupportedRuntimeABI
    case runtimePackagingUnverified

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let detail): return "오디오 중계 패키지를 확인할 수 없습니다: \(detail)"
        case .signature: return "오디오 중계 앱의 서명을 확인할 수 없습니다."
        case .unsupportedRuntimeABI: return "현재 오디오 중계 버전은 봉인된 실행 경로와 서버 준비 상태 증명을 지원하지 않습니다."
        case .runtimePackagingUnverified: return "오디오 중계 런타임과 외부 실행 도구의 전체 의존성 검증이 필요합니다."
        }
    }
}

struct LocalAudioRelayManifest: Codable {
    enum Kind: String, Codable { case file, directory }
    struct Entry: Codable {
        let path: String
        let kind: Kind
        let mode: UInt16
        let size: UInt64?
        let sha256: String?
    }
    struct Dependency: Codable {
        let source: String
        let bundled: [String]
        let system: [String]
    }
    let schemaVersion: Int
    let runtimeABI: String
    let nodeSourceCommit: String
    let port: Int
    let entries: [Entry]
    let dependencies: [Dependency]

    static let nodeCommit = "d0df44d788574ee5393d846f03aeadffc1eee318"
    static let requiredFiles = ["node/bin/node", "server/control-room-server.js", "server/audio-router.py",
                                "python/bin/python3.13", "python/Python"]
    static let requiredDirectory = "python/lib/python3.13"

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024 else { throw LocalAudioRelayLaunchFailure.invalidPackage("매니페스트 크기") }
        try UniqueJSON.check(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "runtimeABI", "nodeSourceCommit", "port", "entries", "dependencies"],
              let entries = object["entries"] as? [[String: Any]],
              let dependencies = object["dependencies"] as? [[String: Any]],
              entries.allSatisfy({ Set($0.keys).isSubset(of: ["path", "kind", "mode", "size", "sha256"]) &&
                  Set($0.keys).isSuperset(of: ["path", "kind", "mode"]) }),
              dependencies.allSatisfy({ Set($0.keys) == ["source", "bundled", "system"] }) else {
            throw LocalAudioRelayLaunchFailure.invalidPackage("매니페스트 필드")
        }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.schemaVersion == 1,
              ["native-audio-forwarding-stdio-v3"].contains(manifest.runtimeABI),
              manifest.nodeSourceCommit == nodeCommit, manifest.port == 17648 else {
            throw LocalAudioRelayLaunchFailure.unsupportedRuntimeABI
        }
        return manifest
    }
}

private enum UniqueJSON {
    static func check(_ data: Data) throws {
        guard !data.starts(with: [0xef, 0xbb, 0xbf]), String(data: data, encoding: .utf8) != nil else {
            throw LocalAudioRelayLaunchFailure.invalidPackage("JSON 인코딩")
        }
        _ = try JSONSerialization.jsonObject(with: data)
        let bytes = Array(data)
        var stack: [Set<String>?] = []
        var expectsKey = false
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 123: stack.append(Set<String>()); expectsKey = true
            case 91: stack.append(nil); expectsKey = false
            case 125, 93: stack.removeLast(); expectsKey = false
            case 44: expectsKey = stack.last != nil && stack.last! != nil
            case 58: expectsKey = false
            case 34:
                let start = i
                i += 1
                while bytes[i] != 34 { i += bytes[i] == 92 ? 2 : 1 }
                if expectsKey, let keys = stack.last, var keys {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...i]))
                    guard keys.insert(key).inserted else { throw LocalAudioRelayLaunchFailure.invalidPackage("중복 JSON 필드") }
                    stack[stack.count - 1] = keys
                }
            default: break
            }
            guard stack.count < 64 else { throw LocalAudioRelayLaunchFailure.invalidPackage("JSON 깊이") }
            i += 1
        }
    }
}

struct LocalAudioRelayInventory {
    struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let mode: UInt16
        let links: UInt16
        let uid: UInt32
        let gid: UInt32
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        let sha256: String?
    }
    let package: URL
    let manifest: LocalAudioRelayManifest
    private let identities: [String: Identity]

    static func capture(package: URL) throws -> Self {
        try noLinks(package)
        let manifestURL = package.appendingPathComponent("manifest.json")
        let manifestIdentity = try identity(manifestURL, directory: false)
        let manifest = try LocalAudioRelayManifest.decode(Data(contentsOf: manifestURL))
        guard try identity(manifestURL, directory: false) == manifestIdentity else { throw failure("매니페스트 변경") }
        let runtime = package.appendingPathComponent("runtime")
        var expected: [String: LocalAudioRelayManifest.Entry] = [:]
        for entry in manifest.entries {
            guard validRelative(entry.path), expected[entry.path] == nil,
                  entry.mode & 0o7022 == 0, entry.mode & 0o444 != 0 else { throw failure("파일 목록 경로 또는 권한") }
            switch entry.kind {
            case .directory:
                guard entry.size == nil, entry.sha256 == nil, entry.mode & 0o111 != 0 else { throw failure("디렉터리 필드") }
            case .file:
                guard let hash = entry.sha256, hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                      entry.size != nil else { throw failure("파일 해시") }
            }
            expected[entry.path] = entry
        }
        for path in LocalAudioRelayManifest.requiredFiles {
            guard expected[path]?.kind == .file else { throw failure("필수 런타임 파일 누락") }
        }
        guard expected[LocalAudioRelayManifest.requiredDirectory]?.kind == .directory,
              expected["node/bin/node"]!.mode & 0o111 != 0,
              expected["python/bin/python3.13"]!.mode & 0o111 != 0 else { throw failure("실행 파일 또는 표준 라이브러리 누락") }
        let files = Set(expected.values.filter { $0.kind == .file }.map(\.path))
        guard Set(manifest.dependencies.map(\.source)) == files,
              manifest.dependencies.count == files.count else { throw failure("의존성 목록 누락 또는 중복") }
        for dependency in manifest.dependencies {
            guard dependency.bundled.allSatisfy({ files.contains($0) }),
                  Set(dependency.bundled).count == dependency.bundled.count,
                  Set(dependency.system).count == dependency.system.count,
                  dependency.system.allSatisfy({ path in
                      (path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/")) && validRelative(String(path.dropFirst()))
                  }) else { throw failure("외부 의존성") }
        }
        var identities = ["manifest.json": manifestIdentity]
        identities["runtime"] = try identity(runtime, directory: true)
        var seen = Set<String>()
        func walk(_ directory: URL, prefix: String) throws {
            let before = try identity(directory, directory: true)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard let entry = expected[path], seen.insert(path).inserted else { throw failure("목록 외 파일") }
                let url = runtime.appendingPathComponent(path)
                let actual = try identity(url, directory: entry.kind == .directory)
                guard actual.mode & 0o7777 == entry.mode,
                      entry.kind == .directory || (UInt64(actual.size) == entry.size && actual.sha256 == entry.sha256) else {
                    throw failure("파일 내용 또는 형식 불일치")
                }
                identities["runtime/" + path] = actual
                if entry.kind == .directory { try walk(url, prefix: path) }
            }
            guard try identity(directory, directory: true) == before else { throw failure("검사 중 디렉터리 변경") }
        }
        try walk(runtime, prefix: "")
        guard seen == Set(expected.keys),
              Set(try FileManager.default.contentsOfDirectory(atPath: package.path)) == ["manifest.json", "runtime"] else {
            throw failure("패키지 목록 불일치")
        }
        identities["."] = try identity(package, directory: true)
        let snapshot = Self(package: package, manifest: manifest, identities: identities)
        try snapshot.recheckFiles()
        return snapshot
    }

    func recheck() throws {
        let fresh = try Self.capture(package: package)
        guard fresh.identities == identities else { throw Self.failure("실행 전후 파일 정체성 변경") }
    }

    private func recheckFiles() throws {
        for (path, expected) in identities {
            let url = path == "." ? package : package.appendingPathComponent(path)
            guard try Self.identity(url, directory: expected.sha256 == nil) == expected else { throw Self.failure("검사 중 파일 변경") }
        }
    }

    static func validRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\0") && !path.contains("\\") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func noLinks(_ url: URL) throws {
        guard url.path == url.standardizedFileURL.path, url.path == url.resolvingSymlinksInPath().path else { throw failure("정본 경로 불일치") }
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            ancestor.appendPathComponent(component)
            var info = stat()
            guard lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw failure("심볼릭 링크 또는 누락 경로") }
        }
    }

    private static func identity(_ url: URL, directory: Bool) throws -> Identity {
        try noLinks(url)
        var before = stat()
        guard lstat(url.path, &before) == 0,
              before.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              before.st_mode & 0o7022 == 0,
              directory || before.st_nlink == 1 else { throw failure("파일 형식 또는 쓰기 권한") }
        var hash: String?
        if !directory {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw failure("파일 열기") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var opened = stat()
            guard fstat(fd, &opened) == 0, same(before, opened) else { throw failure("파일 교체") }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
            var after = stat()
            guard fstat(fd, &after) == 0, same(before, after) else { throw failure("해시 중 파일 변경") }
            hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var after = stat()
        guard lstat(url.path, &after) == 0, same(before, after) else { throw failure("경로 교체") }
        return Identity(device: before.st_dev, inode: before.st_ino, mode: before.st_mode, links: before.st_nlink,
                        uid: before.st_uid, gid: before.st_gid, size: before.st_size,
                        modifiedSeconds: before.st_mtimespec.tv_sec, modifiedNanos: before.st_mtimespec.tv_nsec,
                        changedSeconds: before.st_ctimespec.tv_sec, changedNanos: before.st_ctimespec.tv_nsec, sha256: hash)
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink &&
        a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func failure(_ detail: String) -> LocalAudioRelayLaunchFailure { .invalidPackage(detail) }
}

struct LocalAudioRelayInvocation {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL
    let runtime: LocalAudioRelayRuntimeExpectation

    init(inventory: LocalAudioRelayInventory) {
        let root = inventory.package.appendingPathComponent("runtime")
        executableURL = root.appendingPathComponent("node/bin/node")
        arguments = [root.appendingPathComponent("server/control-room-server.js").path, "--native-audio-forwarding-stdio"]
        environment = ["CCR_MOBILE_PORT": "17648"]
        currentDirectoryURL = root
        runtime = .init(python: root.appendingPathComponent("python/bin/python3.13").path,
                        router: root.appendingPathComponent("server/audio-router.py").path)
    }
}

enum LocalAudioRelayLaunch {
    static let canonicalApp = URL(fileURLWithPath: "/Applications/CCR Sill.app", isDirectory: true)
    static let designatedRequirement = "identifier \"com.ambrion.sillcanvas.mac\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: TAEWAN KANG (X6V8DN2VJ3)\" and certificate 1[field.1.2.840.113635.100.6.2.1]"

    static func validateInstalledRuntime() throws -> LocalAudioRelayInventory {
        try validateSignatureAndSelf()
        let inventory = try LocalAudioRelayInventory.capture(package: canonicalApp.appendingPathComponent("Contents/Resources/LocalAudioRelay"))
        try validateSignatureAndSelf()
        try inventory.recheck()
        return inventory
    }

    static func requireLaunchSupport(_ inventory: LocalAudioRelayInventory) throws {
        try inventory.recheck()
        try LocalAudioRelayClosure.validate(inventory)
    }

    @MainActor
    static func makeForwardingRelay(participants: LocalAudioParticipantRegistry) throws -> LocalAudioRelay {
        let inventory = try validateInstalledRuntime()
        try requireLaunchSupport(inventory)
        let invocation = LocalAudioRelayInvocation(inventory: inventory)
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.currentDirectoryURL
        return LocalAudioRelay(participants: participants, process: process,
            packagedRuntime: invocation.runtime, forwarding: true, validateLaunch: {
                do {
                    try validateSignatureAndSelf()
                    try inventory.recheck()
                    return true
                } catch { return false }
            })
    }

    private static func validateSignatureAndSelf() throws {
        func checked(_ status: OSStatus) throws {
            guard status == errSecSuccess else { throw LocalAudioRelayLaunchFailure.signature(status) }
        }
        guard Bundle.main.bundleURL.path == canonicalApp.path,
              Bundle.main.bundleIdentifier == "com.ambrion.sillcanvas.mac",
              canonicalApp.resolvingSymlinksInPath().path == canonicalApp.path else {
            throw LocalAudioRelayLaunchFailure.invalidPackage("정본 앱 실행 필요")
        }
        let executable = canonicalApp.appendingPathComponent("Contents/MacOS/Sill")
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0,
              String(cString: path) == executable.path,
              executable.resolvingSymlinksInPath().path == executable.path else {
            throw LocalAudioRelayLaunchFailure.invalidPackage("실행 중인 앱 경로 불일치")
        }
        var requirement: SecRequirement?
        try checked(SecRequirementCreateWithString(designatedRequirement as CFString, [], &requirement))
        guard let requirement else { throw LocalAudioRelayLaunchFailure.signature(errSecCSReqInvalid) }
        var disk: SecStaticCode?
        try checked(SecStaticCodeCreateWithPath(canonicalApp as CFURL, [], &disk))
        var myself: SecCode?
        try checked(SecCodeCopySelf([], &myself))
        guard let disk, let myself else { throw LocalAudioRelayLaunchFailure.signature(errSecCSInvalidObjectRef) }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        try checked(SecStaticCodeCheckValidity(disk, flags, requirement))
        try checked(SecCodeCheckValidity(myself, [], requirement))
        var running: SecStaticCode?
        try checked(SecCodeCopyStaticCode(myself, [], &running))
        guard let running else { throw LocalAudioRelayLaunchFailure.signature(errSecCSInvalidObjectRef) }
        func identity(_ code: SecStaticCode) throws -> Data {
            var designated: SecRequirement?
            try checked(SecCodeCopyDesignatedRequirement(code, [], &designated))
            var actual: CFData?, expected: CFData?
            guard let designated else { throw LocalAudioRelayLaunchFailure.signature(errSecCSReqInvalid) }
            try checked(SecRequirementCopyData(designated, [], &actual))
            try checked(SecRequirementCopyData(requirement, [], &expected))
            var dictionary: CFDictionary?
            try checked(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary))
            guard let info = dictionary as? [String: Any], actual == expected,
                  info[kSecCodeInfoIdentifier as String] as? String == "com.ambrion.sillcanvas.mac",
                  info[kSecCodeInfoTeamIdentifier as String] as? String == "ZPTXHJ866D",
                  let hash = info[kSecCodeInfoUnique as String] as? Data else {
                throw LocalAudioRelayLaunchFailure.invalidPackage("서명 식별자 또는 지정 요구사항 불일치")
            }
            return hash
        }
        guard try identity(disk) == identity(running) else { throw LocalAudioRelayLaunchFailure.invalidPackage("실행 파일 서명 변경") }
    }
}
