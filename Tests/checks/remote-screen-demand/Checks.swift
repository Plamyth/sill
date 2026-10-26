import Foundation
import Darwin

private var assertions = 0
private func expect(_ condition: Bool, _ message: String = #function) {
    precondition(condition, message)
    assertions += 1
}
private func rejects(_ body: () throws -> Void) {
    do { try body(); fatalError("거절해야 하는 입력을 수용했습니다") }
    catch { assertions += 1 }
}

private let host = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let core = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
private typealias Observation = RemoteScreenDemandObservation
private let window = Observation.Source.window(.init(windowID: 42, ownerPID: 123,
    ownerStartSeconds: UInt64.max, ownerStartMicroseconds: 123456, bundleIdentifier: "md.obsidian"))

private func observation(_ revision: UInt64, hostGeneration: UUID = host, expires: Double = 105,
                         observedAt: Double = 100, source: Observation.Source = window,
                         count: Int = 1, complete: Bool = true, generation: String = "epoch-generation") -> Observation {
    Observation(hostGeneration: hostGeneration, revision: revision, complete: complete,
        consumers: (0..<count).map { _ in .init(incarnation: UUID(),
            epoch: .init(id: UUID(), generation: generation), source: source, expiresAt: expires) },
        observedAt: observedAt)
}

private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}

private func ack(_ request: [String: Any], coreGeneration: UUID = core) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "op": "provider.screenDemand",
        "hostGeneration": request["hostGeneration"]!, "revision": request["revision"]!,
        "coreGeneration": coreGeneration.uuidString, "accepted": true])
}

@MainActor
private final class Wire {
    var requests: [[String: Any]] = []
    var continuations: [CheckedContinuation<Data, Error>] = []
    func exchange(_ data: Data) async throws -> Data {
        requests.append(try JSONSerialization.jsonObject(with: data) as! [String: Any])
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func reply(_ data: Data? = nil, coreGeneration: UUID = core) throws {
        let request = requests[requests.count - continuations.count]
        continuations.removeFirst().resume(returning: try data ?? ack(request, coreGeneration: coreGeneration))
    }
    func fail() { continuations.removeFirst().resume(throwing: ProviderCallFailure.unavailable) }
}

private final class Transport: ProviderCallTransport, @unchecked Sendable {
    let wire: Wire
    private let lock = NSLock()
    private var invalidations = 0
    init(_ wire: Wire) { self.wire = wire }
    var invalidated: Int { lock.lock(); defer { lock.unlock() }; return invalidations }
    func invalidate() { lock.lock(); invalidations += 1; lock.unlock() }
    func exchange<Request: Encodable, Reply: Decodable>(_ request: Request, as: Reply.Type,
                                                       until deadline: TimeInterval) async throws -> Reply {
        let data = try await wire.exchange(JSONEncoder().encode(request))
        try LocalAudioRelayJSON.validate(data)
        return try JSONDecoder().decode(Reply.self, from: data)
    }
}

private final class SocketFixture: @unchecked Sendable {
    let path: String
    private let directory: String
    private let listener: Int32
    private let done = DispatchGroup()
    private var closed = false

    init(replies: Int = 1, respond: @escaping @Sendable (Data) throws -> Data) throws {
        directory = CommandLine.arguments[1] + "/" + UUID().uuidString
        path = directory + "/command.sock"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [UInt8(0)]
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes + Array(repeating: 0, count: target.count - bytes.count))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && chmod(path, 0o600) == 0 && listen(listener, 1) == 0)
        done.enter()
        DispatchQueue.global().async { [self] in
            defer { done.leave() }
            do {
                var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 3000) > 0 else { throw ProviderCallFailure.expired }
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { throw ProviderCallFailure.unavailable }
                defer { Darwin.close(peer) }
                var noSignal: Int32 = 1
                _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                for _ in 0..<replies {
                    let request = try ProductionFraming.read(peer, until: ProcessInfo.processInfo.systemUptime + 3)
                    let reply = try respond(request)
                    try ProductionFraming.write(reply, to: peer, until: ProcessInfo.processInfo.systemUptime + 3)
                }
            } catch {
                FileHandle.standardError.write(Data("socket fixture: \(error)\n".utf8))
            }
        }
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        done.wait()
        Darwin.close(listener)
        try FileManager.default.removeItem(atPath: directory)
        expect(!FileManager.default.fileExists(atPath: directory))
    }
}

@main private struct Checks {
    @MainActor static func settle(_ predicate: @MainActor () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            await Task.yield()
        }
        expect(predicate(), "비동기 상태가 기한 안에 도달해야 합니다")
    }

    static func dto() throws {
        let request = try observation(.max).request(now: 100)
        let wire = try object(request)
        expect(Set(wire.keys) == ["schemaVersion", "op", "hostGeneration", "revision", "complete", "consumers"])
        expect(wire["revision"] as? String == "18446744073709551615")
        expect(wire["hostGeneration"] as? String == host.uuidString.lowercased())
        expect(wire["op"] as? String == "provider.screenDemand")
        let consumer = (wire["consumers"] as! [[String: Any]])[0]
        expect(Set(consumer.keys) == ["incarnation", "epoch", "source", "validForMs"])
        expect(consumer["validForMs"] as? Int == 5000)
        let source = consumer["source"] as! [String: Any]
        expect(Set(source.keys) == ["kind", "windowID", "ownerPID", "ownerStartSeconds", "ownerStartMicroseconds", "bundleIdentifier"])
        expect(source["ownerStartSeconds"] as? String == "18446744073709551615")
        expect(source["ownerPID"] as? Int == 123)
        expect(window == window)
        let display = Observation.Source.display(.init(displayID: UInt32.max, displayUUID: core))
        let displayJSON = try object(display)
        expect(Set(displayJSON.keys) == ["kind", "displayID", "displayUUID"])
        expect(displayJSON["displayUUID"] as? String == core.uuidString.lowercased())
        expect(try observation(1, source: display).request(now: 100).complete)
        expect(try observation(1).request(now: 102).consumers[0].validForMs == 3000)
        expect(try !observation(1, complete: false).request(now: 100).complete)
        for now in [105, 106, 99, Double.nan, .infinity] {
            let value = try observation(1).request(now: now)
            expect(!value.complete && value.consumers.isEmpty)
        }
        for expiry in [100, 100.0001, 106, Double.nan, .infinity] {
            let value = try observation(1, expires: expiry).request(now: 100)
            expect(!value.complete && value.consumers.isEmpty)
        }
        for count in [16, 17, 100] {
            let value = try observation(1, count: count).request(now: 100)
            expect(value.consumers.count == min(count, 16))
            expect(value.complete == (count <= 16))
        }
        let invalid: [Observation.Source] = [
            .window(.init(windowID: 0, ownerPID: 1, ownerStartSeconds: 1, ownerStartMicroseconds: 0, bundleIdentifier: "md.obsidian")),
            .window(.init(windowID: 1, ownerPID: 0, ownerStartSeconds: 1, ownerStartMicroseconds: 0, bundleIdentifier: "md.obsidian")),
            .window(.init(windowID: 1, ownerPID: -1, ownerStartSeconds: 1, ownerStartMicroseconds: 0, bundleIdentifier: "md.obsidian")),
            .window(.init(windowID: 1, ownerPID: 1, ownerStartSeconds: 0, ownerStartMicroseconds: 0, bundleIdentifier: "md.obsidian")),
            .window(.init(windowID: 1, ownerPID: 1, ownerStartSeconds: 1, ownerStartMicroseconds: 1_000_000, bundleIdentifier: "md.obsidian")),
            .window(.init(windowID: 1, ownerPID: 1, ownerStartSeconds: 1, ownerStartMicroseconds: 0, bundleIdentifier: "")),
            .window(.init(windowID: 1, ownerPID: 1, ownerStartSeconds: 1, ownerStartMicroseconds: 0, bundleIdentifier: String(repeating: "한", count: 86))),
            .display(.init(displayID: 0, displayUUID: core))]
        for source in invalid {
            let value = try observation(1, source: source).request(now: 100)
            expect(!value.complete && value.consumers.isEmpty)
        }
        for generation in ["", String(repeating: "한", count: 43)] {
            let value = try observation(1, generation: generation).request(now: 100)
            expect(!value.complete && value.consumers.isEmpty)
        }
        let escaped = Observation.Source.window(.init(windowID: 1, ownerPID: 1, ownerStartSeconds: 1,
            ownerStartMicroseconds: 0, bundleIdentifier: String(repeating: "\u{01}", count: 255)))
        let large = try observation(1, source: escaped, count: 16,
            generation: String(repeating: "\u{01}", count: 128)).request(now: 100)
        expect(!large.complete && large.consumers.count < 16)
        expect(try JSONEncoder().encode(large).count + 1 < 16_384)
        let empty = try observation(1, count: 0).request(now: 100)
        expect(empty.complete && empty.consumers.isEmpty)
        expect(try !observation(1, observedAt: .nan, count: 0).request(now: 100).complete)
        rejects { _ = try observation(0).request(now: 100) }
    }

    static func acknowledgements() throws {
        let request = try observation(1).request(now: 100)
        let body = try object(request)
        let good = try ack(body)
        let decoded = try JSONDecoder().decode(RemoteScreenDemandAcknowledgement.self, from: good)
        try decoded.validate(request, coreGeneration: core)
        expect(decoded.coreGeneration == core)
        var values = try JSONSerialization.jsonObject(with: good) as! [String: Any]
        let mutations: [(String, Any)] = [("schemaVersion", 2), ("schemaVersion", true),
            ("op", "provider.challenge"), ("accepted", false), ("accepted", 1),
            ("hostGeneration", "bad"), ("coreGeneration", "bad"), ("revision", "01"),
            ("revision", "0"), ("revision", "-1"), ("revision", "+1"),
            ("revision", "18446744073709551616"), ("revision", 1), ("extra", "field")]
        for (key, value) in mutations {
            var malformed = values
            malformed[key] = value
            rejects {
                _ = try JSONDecoder().decode(RemoteScreenDemandAcknowledgement.self,
                    from: JSONSerialization.data(withJSONObject: malformed))
            }
        }
        for key in values.keys {
            var malformed = values
            malformed.removeValue(forKey: key)
            rejects { _ = try JSONDecoder().decode(RemoteScreenDemandAcknowledgement.self,
                from: JSONSerialization.data(withJSONObject: malformed)) }
        }
        for (key, value) in [("hostGeneration", UUID().uuidString), ("revision", "2")] {
            values = try JSONSerialization.jsonObject(with: good) as! [String: Any]
            values[key] = value
            rejects { try JSONDecoder().decode(RemoteScreenDemandAcknowledgement.self,
                from: JSONSerialization.data(withJSONObject: values)).validate(request, coreGeneration: core) }
        }
        rejects { try decoded.validate(request, coreGeneration: UUID()) }
        let duplicate = Data("{\"op\":\"provider.screenDemand\",\"op\":\"provider.screenDemand\"}".utf8)
        rejects { try LocalAudioRelayJSON.validate(duplicate) }
    }

    @MainActor static func publisher() async throws {
        let wire = Wire()
        let socket = Transport(wire)
        var now = 100.0
        var opens = 0
        let publisher = RemoteScreenDemandPublisher(clock: { now }, open: { path, _ in
            expect(path.hasSuffix("/CodexControlRoom/command.sock"))
            opens += 1
            return socket
        })
        publisher.submit(observation(1))
        await settle { wire.requests.count == 1 }
        publisher.submit(observation(2))
        publisher.submit(observation(3))
        publisher.submit(observation(3, count: 0))
        publisher.submit(observation(2))
        publisher.submit(observation(100, hostGeneration: UUID()))
        now = 102
        try wire.reply()
        await settle { wire.requests.count == 2 }
        expect(wire.requests.map { $0["revision"] as! String } == ["1", "3"])
        let consumers = wire.requests[1]["consumers"] as! [[String: Any]]
        expect(consumers[0]["validForMs"] as? Int == 3000)
        expect(opens == 1 && socket.invalidated == 0)
        try wire.reply()
        publisher.submit(observation(4))
        await settle { wire.requests.count == 3 }
        try wire.reply(coreGeneration: UUID())
        await settle { socket.invalidated == 1 }
        for _ in 0..<30 { await Task.yield() }
        expect(opens == 1 && wire.requests.count == 3)
        publisher.submit(observation(5))
        await settle { opens == 2 && wire.requests.count == 4 }
        wire.fail()
        await settle { socket.invalidated == 2 }
        expect(opens == 2)
        publisher.submit(observation(6))
        await settle { wire.requests.count == 5 }
        publisher.submit(observation(7))
        publisher.stop()
        expect(socket.invalidated == 3)
        try wire.reply()
        publisher.submit(observation(8))
        for _ in 0..<30 { await Task.yield() }
        expect(wire.requests.count == 5 && opens == 3)

        var openAttempts = 0
        let failing = RemoteScreenDemandPublisher(clock: { 100 }, open: { _, _ in
            openAttempts += 1
            throw ProviderCallFailure.unavailable
        })
        failing.submit(observation(1))
        await settle { openAttempts == 1 }
        for _ in 0..<30 { await Task.yield() }
        expect(openAttempts == 1)
        failing.submit(observation(1))
        for _ in 0..<30 { await Task.yield() }
        expect(openAttempts == 1)
        failing.submit(observation(2))
        await settle { openAttempts == 2 }
        failing.stop()

        var openContinuation: CheckedContinuation<any ProviderCallTransport, Error>?
        let lateWire = Wire()
        let lateSocket = Transport(lateWire)
        let stopping = RemoteScreenDemandPublisher(clock: { 100 }, open: { _, _ in
            try await withCheckedThrowingContinuation { openContinuation = $0 }
        })
        stopping.submit(observation(1))
        await settle { openContinuation != nil }
        stopping.stop()
        openContinuation!.resume(returning: lateSocket)
        await settle { lateSocket.invalidated == 1 }
        expect(lateWire.requests.isEmpty)

        let delayedWire = Wire()
        let delayedSocket = Transport(delayedWire)
        var delayed: CheckedContinuation<any ProviderCallTransport, Error>?
        now = 100
        let opening = RemoteScreenDemandPublisher(clock: { now }, open: { _, _ in
            try await withCheckedThrowingContinuation { delayed = $0 }
        })
        opening.submit(observation(1))
        await settle { delayed != nil }
        now = 106
        delayed!.resume(returning: delayedSocket)
        await settle { delayedWire.requests.count == 1 }
        expect(delayedWire.requests[0]["complete"] as? Bool == false)
        expect((delayedWire.requests[0]["consumers"] as! [Any]).isEmpty)
        try delayedWire.reply()
        opening.stop()
    }

    @MainActor static func socketExchange() async throws {
        FileHandle.standardError.write(Data("socket exchange: valid ACK\n".utf8))
        let fixture = try SocketFixture(replies: 2) { bytes in
            let request = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            expect(request["op"] as? String == "provider.screenDemand")
            return try ack(request) + Data([10])
        }
        defer { try? fixture.close() }
        let socket = try await ProviderCallSocket.open(path: fixture.path,
            until: ProcessInfo.processInfo.systemUptime + 1)
        for revision in [UInt64(1), 2] {
            let request = try observation(revision).request(now: 100)
            let value = try await socket.exchange(request, as: RemoteScreenDemandAcknowledgement.self,
                until: ProcessInfo.processInfo.systemUptime + 1)
            try value.validate(request, coreGeneration: core)
            expect(value.revision == revision)
        }
        socket.invalidate()
        try fixture.close()

        for size in [16_383, 16_384, 16_385] {
            let fixture = try SocketFixture { bytes in
                let body = try ack(JSONSerialization.jsonObject(with: bytes) as! [String: Any])
                return body + Data(repeating: 32, count: size - body.count - 1) + Data([10])
            }
            defer { try? fixture.close() }
            let socket = try await ProviderCallSocket.open(path: fixture.path,
                until: ProcessInfo.processInfo.systemUptime + 1, frameLimit: 16_384)
            let request = try observation(1).request(now: 100)
            var accepted = false
            do {
                let value = try await socket.exchange(request, as: RemoteScreenDemandAcknowledgement.self,
                    until: ProcessInfo.processInfo.systemUptime + 1)
                try value.validate(request, coreGeneration: core)
                accepted = true
            } catch {}
            expect(accepted == (size < 16_384), "ACK 줄바꿈 포함 프레임 상한 \(size)")
            socket.invalidate()
        }

        let broken: [Data] = [Data("{\n".utf8), Data([10]), Data([0xff, 10]),
            Data("{}\n{}\n".utf8), Data(repeating: 32, count: 16_384) + Data("{}\n".utf8),
            Data("{\"schemaVersion\":1,\"schemaVersion\":1}\n".utf8)]
        for reply in broken {
            FileHandle.standardError.write(Data("socket exchange: invalid frame \(reply.count) bytes\n".utf8))
            let fixture = try SocketFixture { _ in reply }
            defer { try? fixture.close() }
            let socket = try await ProviderCallSocket.open(path: fixture.path,
                until: ProcessInfo.processInfo.systemUptime + 1)
            do {
                _ = try await socket.exchange(observation(1).request(now: 100),
                    as: RemoteScreenDemandAcknowledgement.self, until: ProcessInfo.processInfo.systemUptime + 1)
                fatalError("잘못된 실제 소켓 프레임을 수용했습니다")
            } catch { assertions += 1 }
            do {
                _ = try await socket.exchange(observation(2).request(now: 100),
                    as: RemoteScreenDemandAcknowledgement.self, until: ProcessInfo.processInfo.systemUptime + 1)
                fatalError("오류 후 폐기한 소켓이 다시 응답했습니다")
            } catch { assertions += 1 }
            socket.invalidate()
            try fixture.close()
        }

        let cancelled = try SocketFixture { bytes in
            Thread.sleep(forTimeInterval: 0.1)
            return try ack(JSONSerialization.jsonObject(with: bytes) as! [String: Any]) + Data([10])
        }
        defer { try? cancelled.close() }
        FileHandle.standardError.write(Data("socket exchange: cancellation\n".utf8))
        let cancelSocket = try await ProviderCallSocket.open(path: cancelled.path,
            until: ProcessInfo.processInfo.systemUptime + 1)
        let exchange = Task {
            try await cancelSocket.exchange(observation(1).request(now: 100),
                as: RemoteScreenDemandAcknowledgement.self, until: ProcessInfo.processInfo.systemUptime + 1)
        }
        await Task.yield()
        exchange.cancel()
        do { _ = try await exchange.value; fatalError("취소한 실제 소켓이 성공했습니다") }
        catch { assertions += 1 }
        cancelSocket.invalidate()
        try cancelled.close()
    }

    static func framing() throws {
        func read(_ chunks: [Data], delay: Double = 0) throws -> Data {
            var fds: [Int32] = [-1, -1]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            let reader = fds[0], writer = fds[1]
            var noSignal: Int32 = 1
            _ = setsockopt(writer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let done = DispatchGroup()
            done.enter()
            DispatchQueue.global().async {
                defer { Darwin.close(writer); done.leave() }
                for bytes in chunks {
                    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                    bytes.withUnsafeBytes { _ = send(writer, $0.baseAddress, $0.count, 0) }
                }
            }
            defer { Darwin.close(reader); done.wait() }
            return try ProductionFraming.read(reader, until: ProcessInfo.processInfo.systemUptime + 1)
        }
        let request = try observation(1).request(now: 100)
        let good = try ack(object(request))
        let line = good + Data([10])
        let actual = try read([line])
        try LocalAudioRelayJSON.validate(actual)
        try JSONDecoder().decode(RemoteScreenDemandAcknowledgement.self, from: actual)
            .validate(request, coreGeneration: core)
        expect(actual == good)
        expect(try read([Data(line.prefix(15)), Data(line.dropFirst(15))], delay: 0.01) == good)
        for bytes in [Data(), good, Data([10]), line + line,
                      Data(repeating: 32, count: 32_769) + Data([10])] {
            rejects { _ = try read([bytes]) }
        }
        for bytes in [Data("{".utf8) + Data([10]), Data([0xff, 10]),
                      Data(repeating: 32, count: 16_384) + line] {
            rejects { try LocalAudioRelayJSON.validate(read([bytes])) }
        }
    }

    @MainActor static func main() async throws {
        try dto()
        try acknowledgements()
        try framing()
        try await socketExchange()
        try await publisher()
        print("PASS \(assertions) DTO·ACK·실제 프레임·지연·병합·중지·취소 검사. 실제 Host·기기·UI·오디오 효과 0.")
    }
}
