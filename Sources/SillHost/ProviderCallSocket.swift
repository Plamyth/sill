import Foundation
import Darwin

final class ProviderCallSocket: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ccr.provider.command-socket")
    private var descriptor: Int32?
    private static let limit = 32_768

    static func open(path: String, until deadline: TimeInterval) async throws -> ProviderCallSocket {
        let work = Task.detached { try ProviderCallSocket(path: path, until: deadline) }
        return try await withTaskCancellationHandler {
            let value = try await work.value
            guard !Task.isCancelled else { value.invalidate(); throw CancellationError() }
            return value
        } onCancel: { work.cancel() }
    }

    private init(path: String, until deadline: TimeInterval) throws {
        guard !Task.isCancelled, path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 104,
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              deadline.isFinite, deadline > ProcessInfo.processInfo.systemUptime else { throw ProviderCallFailure.unavailable }
        let expected = try Self.endpoint(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProviderCallFailure.unavailable }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw ProviderCallFailure.unavailable }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ProviderCallFailure.unavailable
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [UInt8(0)]
        withUnsafeMutableBytes(of: &address.sun_path) { output in
            output.copyBytes(from: bytes + Array(repeating: 0, count: output.count - bytes.count))
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw ProviderCallFailure.unavailable }
            try Self.wait(fd, events: Int16(POLLOUT), until: deadline)
            var code: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) == 0, code == 0 else {
                throw ProviderCallFailure.unavailable
            }
        }
        guard try Self.endpoint(path) == expected, ProcessInfo.processInfo.systemUptime < deadline else {
            throw ProviderCallFailure.superseded
        }
        descriptor = fd
        retained = true
    }

    deinit { invalidate() }
    func invalidate() {
        lock.lock()
        let fd = descriptor
        descriptor = nil
        if let fd { _ = shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        lock.unlock()
    }

    func exchange<Request: Encodable, Reply: Decodable>(_ request: Request, as: Reply.Type,
                                                       until deadline: TimeInterval) async throws -> Reply {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var message = try encoder.encode(request)
        guard !message.isEmpty, message.count < Self.limit, !message.contains(10),
              deadline.isFinite else { throw ProviderCallFailure.invalidFields }
        message.append(10)
        let frame = message
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        lock.lock()
                        let fd = descriptor.map { dup($0) } ?? -1
                        lock.unlock()
                        guard fd >= 0 else { throw ProviderCallFailure.unavailable }
                        defer { Darwin.close(fd) }
                        try Self.write(frame, to: fd, until: deadline)
                        let bytes = try Self.read(fd, until: deadline)
                        try LocalAudioRelayJSON.validate(bytes)
                        let reply = try JSONDecoder().decode(Reply.self, from: bytes)
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProviderCallFailure.expired }
                        continuation.resume(returning: reply)
                    } catch {
                        invalidate()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [self] in invalidate() }
    }

    private static func wait(_ fd: Int32, events: Int16, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard !Task.isCancelled, remaining.isFinite, remaining > 0 else { throw ProviderCallFailure.expired }
            var poller = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&poller, 1, Int32(min(remaining * 1000, 2_000).rounded(.up)))
            if result < 0, errno == EINTR { continue }
            guard result > 0, poller.revents & Int16(POLLERR | POLLNVAL) == 0,
                  poller.revents & events != 0 else { throw ProviderCallFailure.unavailable }
            return
        }
    }
    private static func write(_ data: Data, to fd: Int32, until deadline: TimeInterval) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                try wait(fd, events: Int16(POLLOUT), until: deadline)
                let count = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard count > 0 else { throw ProviderCallFailure.unavailable }
                sent += count
            }
        }
    }
    private static func read(_ fd: Int32, until deadline: TimeInterval) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(fd, events: Int16(POLLIN), until: deadline)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count > 0, data.count + count <= limit else { throw ProviderCallFailure.unavailable }
            data.append(contentsOf: chunk.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                guard newline == data.index(before: data.endIndex), newline > data.startIndex else {
                    throw ProviderCallFailure.invalidFields
                }
                return data.prefix(upTo: newline)
            }
        }
    }
    private static func endpoint(_ path: String) throws -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var pieces: [String] = []
        var current = parent
        while true {
            var item = stat()
            guard lstat(current, &item) == 0, item.st_mode & S_IFMT == S_IFDIR,
                  item.st_uid == 0 || item.st_uid == getuid(),
                  item.st_mode & 0o022 == 0 || item.st_uid == 0 && item.st_mode & S_ISVTX != 0,
                  current != parent || item.st_uid == getuid() && item.st_mode & 0o777 == 0o700 else {
                throw ProviderCallFailure.unavailable
            }
            pieces.append("\(item.st_dev):\(item.st_ino)")
            let next = URL(fileURLWithPath: current).deletingLastPathComponent().path
            if next == current { break }
            current = next
        }
        var item = stat()
        guard lstat(path, &item) == 0, item.st_mode & S_IFMT == S_IFSOCK,
              item.st_uid == getuid(), item.st_mode & 0o777 == 0o600 else { throw ProviderCallFailure.unavailable }
        pieces.append("\(item.st_dev):\(item.st_ino)")
        return pieces.joined(separator: "/")
    }
}
