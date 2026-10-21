import Foundation
import Darwin

@MainActor
final class LocalCursorUnixChannel {
    @MainActor final class Session {
        let id = UUID()
        let peer: LocalCursorPeer
        fileprivate let descriptor: Int32
        fileprivate weak var owner: LocalCursorUnixChannel?
        fileprivate var closed = false
        fileprivate var buffer = Data()
        fileprivate var reader: DispatchSourceRead?
        var isCurrent: Bool { !closed && peer.isCurrent(socketDescriptor: descriptor) }

        fileprivate init(descriptor: Int32, peer: LocalCursorPeer, owner: LocalCursorUnixChannel) {
            self.descriptor = descriptor; self.peer = peer; self.owner = owner
        }

        @discardableResult func send(_ data: Data) -> Bool {
            guard isCurrent, data.count <= LocalCursorUnixChannel.maxMessage else { owner?.close(self); return false }
            var framed = data; framed.append(10)
            let success = framed.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var offset = 0
                while offset < raw.count {
                    let sent = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                    if sent < 0 && errno == EINTR { continue }
                    guard sent > 0 else { return false }
                    offset += sent
                }
                return true
            }
            if !success { owner?.close(self) }
            return success
        }

        func close() { owner?.close(self) }
    }

    static let maxMessage = 65_536
    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
    }
    private let hostIsCanonical: () -> Bool
    private let onOpen: (Session) -> Void
    private let onRequest: (Data, Session) -> Void
    private let onClose: (Session) -> Void
    private let directory: URL
    private let boot = UUID()
    private var listener: Int32 = -1
    private var lifecycleLock: Int32 = -1
    private var reader: DispatchSourceRead?
    private var sessions: [UUID: Session] = [:]
    private var ownedSocket: FileIdentity?
    private var ownedDiscovery: FileIdentity?
    private var socketURL: URL { directory.appendingPathComponent("rpc.sock") }
    private var discoveryURL: URL { directory.appendingPathComponent("discovery.json") }

    init(hostIsCanonical: @escaping () -> Bool, onOpen: @escaping (Session) -> Void,
         onRequest: @escaping (Data, Session) -> Void, onClose: @escaping (Session) -> Void) {
        self.hostIsCanonical = hostIsCanonical; self.onOpen = onOpen
        self.onRequest = onRequest; self.onClose = onClose
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCR Sill/LocalInput", isDirectory: true)
    }

    @discardableResult func start() -> Bool {
        guard listener < 0 else { return true }
        guard hostIsCanonical(), prepareDirectory(), acquireLifecycleLock() else { return false }
        var started = false
        defer { if !started { releaseLifecycleLock() } }
        guard clearStaleEndpoint() else { return false }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        guard Self.address(socketURL.path, into: &address),
              Self.nonblocking(fd) else { Darwin.close(fd); return false }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); return false }
        ownedSocket = identity(socketURL, kind: mode_t(S_IFSOCK))
        guard let socketIdentity = ownedSocket, Darwin.chmod(socketURL.path, 0o600) == 0,
              Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd); removeOwnedFiles(); return false
        }
        let description: [String: Any] = ["schema": 1, "hostPID": Int(getpid()), "hostBootID": boot.uuidString,
            "socketPath": socketURL.path, "socketDevice": Int64(socketIdentity.device), "socketInode": socketIdentity.inode]
        guard let data = try? JSONSerialization.data(withJSONObject: description, options: [.sortedKeys]),
              writeDiscovery(data) else { Darwin.close(fd); removeOwnedFiles(); return false }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptReady() } }
        source.setCancelHandler { Darwin.close(fd) }
        reader = source; source.resume()
        started = true
        return true
    }

    func stop() {
        for session in Array(sessions.values) { close(session) }
        listener = -1
        reader?.cancel(); reader = nil
        removeOwnedFiles()
        releaseLifecycleLock()
    }

    private func acceptReady() {
        guard listener >= 0 else { return }
        for _ in 0..<8 {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard sessions.count < 8, Self.nonblocking(fd),
                  let peer = LocalCursorPeer.capture(socketDescriptor: fd) else { Darwin.close(fd); continue }
            let session = Session(descriptor: fd, peer: peer, owner: self)
            sessions[session.id] = session
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self, weak session] in
                MainActor.assumeIsolated { if let session { self?.receive(session) } }
            }
            source.setCancelHandler { Darwin.close(fd) }
            session.reader = source; source.resume()
            onOpen(session)
        }
    }

    private func receive(_ session: Session) {
        guard !session.closed, sessions[session.id] === session, session.isCurrent else { close(session); return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<8 {
            var delivered = 0
            while let newline = session.buffer.firstIndex(of: 10) {
                guard newline <= Self.maxMessage, delivered < 64 else { close(session); return }
                let payload = Data(session.buffer.prefix(upTo: newline))
                session.buffer.removeSubrange(...newline)
                guard !payload.isEmpty, session.isCurrent else { close(session); return }
                onRequest(payload, session)
                guard !session.closed else { return }
                delivered += 1
            }
            let count = Darwin.read(session.descriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0 else { close(session); return }
            session.buffer.append(contentsOf: bytes.prefix(count))
            guard session.buffer.count <= Self.maxMessage + 1 else { close(session); return }
        }
        if session.buffer.contains(10) {
            DispatchQueue.main.async { [weak self, weak session] in
                MainActor.assumeIsolated { if let session { self?.receive(session) } }
            }
        }
    }

    private func close(_ session: Session) {
        guard !session.closed else { return }
        session.closed = true
        sessions[session.id] = nil
        session.reader?.cancel(); session.reader = nil
        session.buffer.removeAll()
        onClose(session)
    }

    private static func nonblocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        var noSignal: Int32 = 1
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static func address(_ path: String, into address: inout sockaddr_un) -> Bool {
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        return true
    }

    private func prepareDirectory() -> Bool {
        let base = directory.deletingLastPathComponent().deletingLastPathComponent()
        guard base.resolvingSymlinksInPath().path == base.path else { return false }
        for url in [directory.deletingLastPathComponent(), directory] {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard errno == ENOENT, mkdir(url.path, 0o700) == 0 else { return false }
                guard lstat(url.path, &info) == 0 else { return false }
            }
            guard info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_mode & 0o022 == 0,
                  url != directory || info.st_mode & 0o777 == 0o700 else { return false }
        }
        return true
    }

    private func identity(_ url: URL, kind: mode_t) -> FileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_uid == geteuid(),
              value.st_mode & mode_t(S_IFMT) == kind else { return nil }
        return FileIdentity(device: value.st_dev, inode: value.st_ino)
    }

    private func acquireLifecycleLock() -> Bool {
        let url = directory.appendingPathComponent("lifecycle.lock")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == geteuid(),
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return false }
        let expected = FileIdentity(device: value.st_dev, inode: value.st_ino)
        guard identity(url, kind: mode_t(S_IFREG)) == expected else { Darwin.close(fd); return false }
        lifecycleLock = fd
        return true
    }

    private func releaseLifecycleLock() {
        guard lifecycleLock >= 0 else { return }
        Darwin.close(lifecycleLock)
        lifecycleLock = -1
    }

    private func readDiscovery(identity expected: FileIdentity, size: Int64) -> Data? {
        let fd = Darwin.open(discoveryURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == geteuid(), value.st_size == size,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_mode & 0o777 == 0o600,
              FileIdentity(device: value.st_dev, inode: value.st_ino) == expected else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count == size, identity(discoveryURL, kind: mode_t(S_IFREG)) == expected else { return nil }
        return Data(bytes.prefix(count))
    }

    private func clearStaleEndpoint() -> Bool {
        var socketStat = stat(), discoveryStat = stat()
        let socketExists = lstat(socketURL.path, &socketStat) == 0
        let discoveryExists = lstat(discoveryURL.path, &discoveryStat) == 0
        if !socketExists && !discoveryExists { return true }
        guard discoveryExists, discoveryStat.st_mode & 0o777 == 0o600,
              let discoveryIdentity = identity(discoveryURL, kind: mode_t(S_IFREG)),
              discoveryStat.st_size > 0, discoveryStat.st_size <= 4096,
              let data = readDiscovery(identity: discoveryIdentity, size: discoveryStat.st_size),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["schema"] as? Int == 1, let pid = value["hostPID"] as? Int32, pid > 0,
              let boot = value["hostBootID"] as? String, UUID(uuidString: boot) != nil,
              value["socketPath"] as? String == socketURL.path,
              kill(pid, 0) != 0, errno == ESRCH else { return false }
        if socketExists {
            guard let socketIdentity = identity(socketURL, kind: mode_t(S_IFSOCK)),
                  value["socketDevice"] as? Int32 == socketIdentity.device,
                  value["socketInode"] as? UInt64 == socketIdentity.inode else { return false }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            var address = sockaddr_un()
            guard Self.address(socketURL.path, into: &address) else { Darwin.close(fd); return false }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let refused = result != 0 && errno == ECONNREFUSED
            Darwin.close(fd)
            guard refused, identity(socketURL, kind: mode_t(S_IFSOCK)) == socketIdentity,
                  unlink(socketURL.path) == 0 else { return false }
        }
        return identity(discoveryURL, kind: mode_t(S_IFREG)) == discoveryIdentity && unlink(discoveryURL.path) == 0
    }

    private func writeDiscovery(_ data: Data) -> Bool {
        let fd = Darwin.open(discoveryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        var created = stat()
        guard fstat(fd, &created) == 0, created.st_uid == geteuid(),
              created.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), created.st_mode & 0o777 == 0o600 else {
            Darwin.close(fd); return false
        }
        let createdIdentity = FileIdentity(device: created.st_dev, inode: created.st_ino)
        ownedDiscovery = createdIdentity
        defer { Darwin.close(fd) }
        guard identity(discoveryURL, kind: mode_t(S_IFREG)) == createdIdentity else { return false }
        let written = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            return Darwin.write(fd, base, bytes.count) == bytes.count && fsync(fd) == 0
        }
        return written && identity(discoveryURL, kind: mode_t(S_IFREG)) == createdIdentity
    }

    private func removeOwnedFiles() {
        if let ownedSocket, identity(socketURL, kind: mode_t(S_IFSOCK)) == ownedSocket { _ = unlink(socketURL.path) }
        if let ownedDiscovery, identity(discoveryURL, kind: mode_t(S_IFREG)) == ownedDiscovery { _ = unlink(discoveryURL.path) }
        ownedSocket = nil; ownedDiscovery = nil
    }
}
