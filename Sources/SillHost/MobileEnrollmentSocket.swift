import Foundation
import Darwin

enum MobileEnrollmentRuntimeFailure: Error {
    case unavailable, unsafeEndpoint, invalidFrame, expired, clockRollback, replay, capacity, stopped
}

protocol MobileEnrollmentTransport: Sendable {
    func receive(until deadline: TimeInterval) async throws -> Data?
    func send(_ frame: Data, until deadline: TimeInterval) async throws
    func checkPeer() async throws
    func invalidate()
}

/// 클라이언트 전용이다. 수신은 chunk를 돌려주며 newline 조립과 요청 기한은 runtime이 소유한다.
final class MobileEnrollmentSocket: MobileEnrollmentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let input = DispatchQueue(label: "ccr.enrollment.socket.read")
    private let output = DispatchQueue(label: "ccr.enrollment.socket.write")
    private var descriptor: Int32?
    private let path: String
    private let endpoint: String

    static func open(path: String, until deadline: TimeInterval) async throws -> MobileEnrollmentSocket {
        let work = Task.detached { try MobileEnrollmentSocket(path: path, until: deadline) }
        return try await withTaskCancellationHandler {
            let value = try await work.value
            guard !Task.isCancelled else { value.invalidate(); throw CancellationError() }
            return value
        } onCancel: { work.cancel() }
    }

    private init(path: String, until deadline: TimeInterval) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 104,
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw MobileEnrollmentRuntimeFailure.unsafeEndpoint
        }
        self.path = path
        endpoint = try Self.endpointIdentity(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MobileEnrollmentRuntimeFailure.unavailable }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        let flags = fcntl(fd, F_GETFL)
        var noSignal: Int32 = 1
        guard flags >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw MobileEnrollmentRuntimeFailure.unavailable
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [UInt8(0)]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes + Array(repeating: 0, count: buffer.count - bytes.count))
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw MobileEnrollmentRuntimeFailure.unavailable }
            guard try Self.wait(fd, events: Int16(POLLOUT), until: deadline) else {
                throw MobileEnrollmentRuntimeFailure.expired
            }
            var code: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) == 0, code == 0 else {
                throw MobileEnrollmentRuntimeFailure.unavailable
            }
        }
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
            throw MobileEnrollmentRuntimeFailure.unavailable
        }
        try verify(fd)
        descriptor = fd
        retained = true
    }

    deinit { invalidate() }

    func invalidate() {
        lock.lock()
        if let fd = descriptor {
            descriptor = nil
            _ = shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        lock.unlock()
    }

    private func duplicate() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { throw MobileEnrollmentRuntimeFailure.stopped }
        let fd = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw MobileEnrollmentRuntimeFailure.unavailable }
        return fd
    }

    private func verify(_ fd: Int32) throws {
        try checkEndpoint(fd)
        do { _ = try ProviderPeerAnchor.verify(fd, policy: .core) }
        catch let error as ProviderPeerAnchor.Failure {
            if error == .peerUnavailable, Self.ended(fd) { throw MobileEnrollmentRuntimeFailure.unavailable }
            throw error
        }
        try checkEndpoint(fd)
    }

    private func checkEndpoint(_ fd: Int32) throws {
        guard try Self.endpointIdentity(path) == endpoint else {
            if Self.ended(fd) { throw MobileEnrollmentRuntimeFailure.unavailable }
            throw MobileEnrollmentRuntimeFailure.unsafeEndpoint
        }
    }

    private static func ended(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    private func perform<T: Sendable>(on queue: DispatchQueue,
                                     _ body: @escaping @Sendable (Int32) throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        let fd = try duplicate()
                        defer { Darwin.close(fd) }
                        try verify(fd)
                        let result = try body(fd)
                        try verify(fd)
                        continuation.resume(returning: result)
                    } catch {
                        invalidate()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [self] in invalidate() }
    }

    func checkPeer() async throws { try await perform(on: output) { _ in () } }

    func receive(until deadline: TimeInterval) async throws -> Data? {
        try await perform(on: input) { fd in
            while try Self.wait(fd, events: Int16(POLLIN), until: deadline) {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = recv(fd, &bytes, bytes.count, 0)
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard count > 0 else { throw MobileEnrollmentRuntimeFailure.unavailable }
                return Data(bytes.prefix(count))
            }
            return nil
        }
    }

    func send(_ frame: Data, until deadline: TimeInterval) async throws {
        guard frame.count > 1, frame.count <= 16_385, frame.last == 10,
              !frame.dropLast().contains(10) else { throw MobileEnrollmentRuntimeFailure.invalidFrame }
        try await perform(on: output) { fd in
            try frame.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    guard try Self.wait(fd, events: Int16(POLLOUT), until: deadline) else {
                        throw MobileEnrollmentRuntimeFailure.expired
                    }
                    let count = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                    if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    guard count > 0 else { throw MobileEnrollmentRuntimeFailure.unavailable }
                    sent += count
                }
            }
        }
    }

    private static func wait(_ fd: Int32, events: Int16, until deadline: TimeInterval) throws -> Bool {
        guard deadline.isFinite else { throw MobileEnrollmentRuntimeFailure.expired }
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard !Task.isCancelled else { throw CancellationError() }
            if remaining <= 0 { return false }
            var poller = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&poller, 1, Int32(min(remaining * 1000, 100).rounded(.up)))
            if result == 0 || result < 0 && errno == EINTR { continue }
            guard result > 0, poller.revents & Int16(POLLERR | POLLNVAL | POLLHUP) == 0,
                  poller.revents & events != 0 else { throw MobileEnrollmentRuntimeFailure.unavailable }
            return true
        }
    }

    static func endpointIdentity(_ path: String) throws -> String {
        guard let canonical = realpath(path, nil) else {
            throw errno == ENOENT ? MobileEnrollmentRuntimeFailure.unavailable : .unsafeEndpoint
        }
        defer { free(canonical) }
        guard String(cString: canonical) == path else { throw MobileEnrollmentRuntimeFailure.unsafeEndpoint }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var current = parent
        var pieces: [String] = []
        while true {
            var item = stat()
            guard lstat(current, &item) == 0 else {
                throw errno == ENOENT ? MobileEnrollmentRuntimeFailure.unavailable : .unsafeEndpoint
            }
            guard item.st_mode & S_IFMT == S_IFDIR,
                  item.st_uid == 0 || item.st_uid == getuid(), item.st_mode & 0o022 == 0,
                  current != parent || item.st_uid == getuid() && item.st_mode & 0o7777 == 0o700 else {
                throw MobileEnrollmentRuntimeFailure.unsafeEndpoint
            }
            pieces.append("\(item.st_dev):\(item.st_ino):\(item.st_mode):\(item.st_uid):\(item.st_gid)")
            let next = URL(fileURLWithPath: current).deletingLastPathComponent().path
            if next == current { break }
            current = next
        }
        var item = stat()
        guard lstat(path, &item) == 0 else {
            throw errno == ENOENT ? MobileEnrollmentRuntimeFailure.unavailable : .unsafeEndpoint
        }
        guard item.st_mode & S_IFMT == S_IFSOCK,
              item.st_uid == getuid(), item.st_mode & 0o7777 == 0o600 else {
            throw MobileEnrollmentRuntimeFailure.unsafeEndpoint
        }
        pieces.append("\(item.st_dev):\(item.st_ino):\(item.st_mode):\(item.st_uid):\(item.st_gid)")
        return pieces.joined(separator: "/")
    }
}
