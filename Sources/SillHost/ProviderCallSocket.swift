import Foundation
import Darwin

protocol ProviderCallTransport: Sendable {
    func exchange<Request: Encodable, Reply: Decodable>(_ request: Request, as: Reply.Type,
                                                       until deadline: TimeInterval) async throws -> Reply
    func invalidate()
}

final class ProviderCallSocket: ProviderCallTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ccr.provider.command-socket")
    private var descriptor: Int32?
    private enum Mode { case command, transitioning, media, closed }
    private enum Direction { case read, write }
    private var mode = Mode.command
    private var readingMedia = false
    private var writingMedia = false
    private let readQueue = DispatchQueue(label: "ccr.provider.media-read")
    private let writeQueue = DispatchQueue(label: "ccr.provider.media-write")
    private static let mediaBodyLimit = 4_578
    private static let limit = 32_768
    private let frameLimit: Int

    static func open(path: String, until deadline: TimeInterval, frameLimit: Int = 32_769) async throws -> ProviderCallSocket {
        let work = Task.detached { try ProviderCallSocket(path: path, until: deadline, frameLimit: frameLimit) }
        return try await withTaskCancellationHandler {
            let value = try await work.value
            guard !Task.isCancelled else { value.invalidate(); throw CancellationError() }
            return value
        } onCancel: { work.cancel() }
    }

    private init(path: String, until deadline: TimeInterval, frameLimit: Int) throws {
        guard !Task.isCancelled, path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 104,
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              (2...Self.limit + 1).contains(frameLimit),
              deadline.isFinite, deadline > ProcessInfo.processInfo.systemUptime else { throw ProviderCallFailure.unavailable }
        self.frameLimit = frameLimit
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
        _ = try ProviderPeerAnchor.verify(fd, policy: .core)
        descriptor = fd
        retained = true
    }

    deinit { invalidate() }
    func invalidate() {
        lock.lock()
        let fd = descriptor
        descriptor = nil
        mode = .closed
        if let fd { _ = shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        lock.unlock()
    }

    func exchange<Request: Encodable, Reply: Decodable>(_ request: Request, as: Reply.Type,
                                                       until deadline: TimeInterval) async throws -> Reply {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var message = try encoder.encode(request)
        guard !message.isEmpty, message.count + 1 < frameLimit, !message.contains(10),
              deadline.isFinite else { throw ProviderCallFailure.invalidFields }
        message.append(10)
        let frame = message
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        lock.lock()
                        let fd = mode == .command ? descriptor.map { dup($0) } ?? -1 : -1
                        lock.unlock()
                        guard fd >= 0 else { throw ProviderCallFailure.unavailable }
                        defer { Darwin.close(fd) }
                        _ = try ProviderPeerAnchor.verify(fd, policy: .core)
                        try Self.write(frame, to: fd, until: deadline)
                        let bytes = try Self.read(fd, until: deadline, frameLimit: frameLimit)
                        _ = try ProviderPeerAnchor.verify(fd, policy: .core)
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

    func beginMedia(ready: Data, until deadline: TimeInterval) async throws {
        let header = try Self.mediaHeader(ready)
        let object = try JSONSerialization.jsonObject(with: header) as? [String: Any]
        guard object?["kind"] as? String == "ready", ready.count == 6 + header.count,
              deadline.isFinite else { throw ProviderCallFailure.invalidFields }
        try reserveMediaTransition()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async { [self] in
                        do {
                            let fd = try duplicate(transition: true)
                            defer { Darwin.close(fd) }
                            _ = try ProviderPeerAnchor.verify(fd, policy: .core)
                            try Self.write(ready, to: fd, until: deadline)
                            _ = try ProviderPeerAnchor.verify(fd, policy: .core)
                            try finishMediaTransition(until: deadline)
                            continuation.resume()
                        } catch { invalidate(); continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { [self] in invalidate() }
            try Task.checkCancellation()
            try requireCurrentMedia(until: deadline)
        } catch { invalidate(); throw error }
    }

    func sendMedia(_ frame: Data, until deadline: TimeInterval) async throws {
        _ = try Self.mediaHeader(frame)
        try await mediaIO(.write, until: deadline) { fd in
            try Self.write(frame, to: fd, until: deadline)
        }
    }

    func receiveMedia(until deadline: TimeInterval) async throws -> Data {
        try await mediaIO(.read, until: deadline) { fd in
            let prefix = try Self.readExactly(4, from: fd, until: deadline)
            let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
            guard (3...Self.mediaBodyLimit).contains(length) else { throw ProviderCallFailure.invalidFields }
            let body = try Self.readExactly(length, from: fd, until: deadline)
            let frame = prefix + body
            _ = try Self.mediaHeader(frame)
            return frame
        }
    }

    private func reserveMediaTransition() throws {
        lock.lock(); defer { lock.unlock() }
        guard mode == .command, descriptor != nil else { throw ProviderCallFailure.unavailable }
        mode = .transitioning
    }
    private func finishMediaTransition(until deadline: TimeInterval) throws {
        lock.lock(); defer { lock.unlock() }
        guard mode == .transitioning, descriptor != nil else { throw ProviderCallFailure.unavailable }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProviderCallFailure.expired }
        mode = .media
    }
    private func duplicate(transition: Bool = false) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard mode == (transition ? .transitioning : .media), let descriptor else { throw ProviderCallFailure.unavailable }
        let fd = dup(descriptor)
        guard fd >= 0 else { throw ProviderCallFailure.unavailable }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(fd); throw ProviderCallFailure.unavailable }
        return fd
    }
    private func reserve(_ direction: Direction) throws {
        lock.lock(); defer { lock.unlock() }
        guard mode == .media, descriptor != nil,
              direction == .read ? !readingMedia : !writingMedia else { throw ProviderCallFailure.unavailable }
        if direction == .read { readingMedia = true } else { writingMedia = true }
    }
    private func release(_ direction: Direction) {
        lock.lock(); defer { lock.unlock() }
        if direction == .read { readingMedia = false } else { writingMedia = false }
    }
    private func mediaIO<Value: Sendable>(_ direction: Direction, until deadline: TimeInterval,
                                         operation: @escaping @Sendable (Int32) throws -> Value) async throws -> Value {
        guard deadline.isFinite else { throw ProviderCallFailure.invalidFields }
        try reserve(direction)
        defer { release(direction) }
        do {
            let value: Value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    (direction == .read ? readQueue : writeQueue).async { [self] in
                        do {
                            let fd = try duplicate()
                            defer { Darwin.close(fd) }
                            _ = try ProviderPeerAnchor.verify(fd, policy: .core)
                            let value = try operation(fd)
                            _ = try ProviderPeerAnchor.verify(fd, policy: .core)
                            try requireCurrentMedia(until: deadline)
                            continuation.resume(returning: value)
                        } catch { invalidate(); continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { [self] in invalidate() }
            try Task.checkCancellation()
            try requireCurrentMedia(until: deadline)
            return value
        } catch { invalidate(); throw error }
    }

    private func requireCurrentMedia(until deadline: TimeInterval) throws {
        lock.lock(); defer { lock.unlock() }
        guard mode == .media, descriptor != nil else { throw ProviderCallFailure.unavailable }
        guard deadline.isFinite, ProcessInfo.processInfo.systemUptime < deadline else { throw ProviderCallFailure.expired }
    }

    private static func mediaHeader(_ frame: Data) throws -> Data {
        guard frame.count >= 7, frame.count <= mediaBodyLimit + 4 else { throw ProviderCallFailure.invalidFields }
        let bytes = [UInt8](frame.prefix(6))
        let bodyLength = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let headerLength = Int(bytes[4]) << 8 | Int(bytes[5])
        guard bodyLength == frame.count - 4, (1...4096).contains(headerLength),
              bodyLength >= headerLength + 2, bodyLength - headerLength - 2 <= 480 else {
            throw ProviderCallFailure.invalidFields
        }
        let header = Data(frame.dropFirst(6).prefix(headerLength))
        try LocalAudioRelayJSON.validate(header)
        return header
    }
    private static func readExactly(_ size: Int, from fd: Int32, until deadline: TimeInterval) throws -> Data {
        guard (1...mediaBodyLimit).contains(size) else { throw ProviderCallFailure.invalidFields }
        var bytes = [UInt8](repeating: 0, count: size)
        var received = 0
        defer {
            bytes.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) }
            }
        }
        try bytes.withUnsafeMutableBytes { raw in
            while received < size {
                try wait(fd, events: Int16(POLLIN), until: deadline)
                let count = recv(fd, raw.baseAddress!.advanced(by: received), size - received, 0)
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard count > 0 else { throw ProviderCallFailure.unavailable }
                received += count
            }
        }
        return Data(bytes)
    }

    private static func wait(_ fd: Int32, events: Int16, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard !Task.isCancelled, remaining.isFinite, remaining > 0 else { throw ProviderCallFailure.expired }
            var poller = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&poller, 1, Int32(min(remaining * 1000, 2_000).rounded(.up)))
            if result == 0 { continue }
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
    private static func read(_ fd: Int32, until deadline: TimeInterval, frameLimit: Int = 32_769) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(fd, events: Int16(POLLIN), until: deadline)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count > 0, data.count + count < frameLimit else { throw ProviderCallFailure.unavailable }
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
