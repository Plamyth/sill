import Foundation
import Darwin

@MainActor enum Boundary {
    static var swap = false
    static func open(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
        let fd = Darwin.open(path, flags, mode)
        if fd >= 0 && swap {
            swap = false
            precondition(rename(path, path + ".created") == 0)
            let replacement = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            precondition(replacement >= 0)
            let data = Data("unowned-replacement".utf8)
            precondition(data.withUnsafeBytes { Darwin.write(replacement, $0.baseAddress!, $0.count) } == data.count)
            Darwin.close(replacement)
        }
        return fd
    }
}
@MainActor final class Files {
    // FILE_IDENTITY
    let directory: URL
    var lifecycleLock: Int32 = -1
    var ownedSocket: FileIdentity?
    var ownedDiscovery: FileIdentity?
    var socketURL: URL { directory.appendingPathComponent("rpc.sock") }
    var discoveryURL: URL { directory.appendingPathComponent("discovery.json") }
    init(_ root: URL) { directory = root.appendingPathComponent("CCR Sill/LocalInput") }
    // METHODS
}
func createSocket(_ path: String, listening: Bool) -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    precondition(fd >= 0)
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size); address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    precondition(result == 0 && chmod(path, 0o600) == 0)
    if listening { precondition(Darwin.listen(fd, 1) == 0) }
    return fd
}
@main struct Checks {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        var checks = 0
        func check(_ condition: Bool) { precondition(condition); checks += 1 }
        let f = Files(root), other = Files(root)
        check(f.prepareDirectory() && f.acquireLifecycleLock())
        check(!other.acquireLifecycleLock())
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,os,sys\nf=os.open(sys.argv[1],os.O_RDWR)\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(0)\nsys.exit(1)", f.directory.appendingPathComponent("lifecycle.lock").path]
        try child.run(); child.waitUntilExit()
        check(child.terminationStatus == 0)
        Boundary.swap = true
        check(!f.writeDiscovery(Data("{}".utf8)))
        f.removeOwnedFiles()
        check(try Data(contentsOf: f.discoveryURL) == Data("unowned-replacement".utf8))
        try FileManager.default.removeItem(at: f.discoveryURL)
        try FileManager.default.removeItem(atPath: f.discoveryURL.path + ".created")
        f.releaseLifecycleLock()
        check(other.acquireLifecycleLock())
        other.releaseLifecycleLock()
        check(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("lifecycle.lock").path))

        let staleRoot = root.appendingPathComponent("stale")
        try FileManager.default.createDirectory(at: staleRoot, withIntermediateDirectories: true)
        let stale = Files(staleRoot)
        check(stale.prepareDirectory() && stale.acquireLifecycleLock())
        let socket = createSocket(stale.socketURL.path, listening: false)
        let socketIdentity = stale.identity(stale.socketURL, kind: mode_t(S_IFSOCK))!
        Darwin.close(socket)
        let dead = Int32.max
        precondition(kill(dead, 0) != 0 && errno == ESRCH)
        let manifest: [String: Any] = ["schema": 1, "hostPID": Int(dead), "hostBootID": UUID().uuidString,
            "socketPath": stale.socketURL.path, "socketDevice": Int(socketIdentity.device), "socketInode": socketIdentity.inode]
        check(stale.writeDiscovery(try JSONSerialization.data(withJSONObject: manifest)))
        check(stale.clearStaleEndpoint())
        check(!FileManager.default.fileExists(atPath: stale.socketURL.path) && !FileManager.default.fileExists(atPath: stale.discoveryURL.path))
        let live = createSocket(stale.socketURL.path, listening: true)
        defer { Darwin.close(live) }
        let liveIdentity = stale.identity(stale.socketURL, kind: mode_t(S_IFSOCK))!
        var liveManifest = manifest; liveManifest["socketDevice"] = Int(liveIdentity.device); liveManifest["socketInode"] = liveIdentity.inode
        check(stale.writeDiscovery(try JSONSerialization.data(withJSONObject: liveManifest)))
        check(!stale.clearStaleEndpoint())
        check(stale.identity(stale.socketURL, kind: mode_t(S_IFSOCK)) == liveIdentity)
        stale.ownedSocket = liveIdentity
        stale.removeOwnedFiles(); stale.releaseLifecycleLock()
        print("PASS \(checks) actual inode and cross-process lock checks; temporary test namespace only")
    }
}
