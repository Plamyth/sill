import Foundation
import CryptoKit
import Security
import StreamProtocol

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ProcessInfo.processInfo.systemUptime
    private var wallOffset: Int64 = 0
    func read() -> MobileEnrollmentTime {
        lock.lock(); defer { lock.unlock() }
        let uptime = ProcessInfo.processInfo.systemUptime
        return MobileEnrollmentTime(milliseconds: 1_800_000_000_000 + Int64((uptime - base) * 1000) + wallOffset,
                                    uptime: uptime)
    }
    func moveWall(_ delta: Int64) { lock.lock(); wallOffset += delta; lock.unlock() }
}

private final class MemoryTransport: MobileEnrollmentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var frames: [Data] = []
    private var closed = false
    private var peerOK = true
    private var peerChecks = 0
    private var loseResult = false
    func feed(_ data: Data) { lock.lock(); chunks.append(data); lock.unlock() }
    func invalidate() { lock.lock(); closed = true; lock.unlock() }
    func rejectPeer() { lock.lock(); peerOK = false; lock.unlock() }
    func failResultWrite() { lock.lock(); loseResult = true; lock.unlock() }
    var ended: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    var sent: [Data] { lock.lock(); defer { lock.unlock() }; return frames }
    var verified: Int { lock.lock(); defer { lock.unlock() }; return peerChecks }
    private func take() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw MobileEnrollmentRuntimeFailure.unavailable }
        return chunks.isEmpty ? nil : chunks.removeFirst()
    }
    func receive(until deadline: TimeInterval) async throws -> Data? {
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let data = try take() { return data }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return nil
    }
    private func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, peerOK else { throw MobileEnrollmentRuntimeFailure.unavailable }
        if loseResult, String(decoding: data, as: UTF8.self).contains("enrollment.active.result") {
            closed = true
            throw MobileEnrollmentRuntimeFailure.unavailable
        }
        frames.append(data)
    }
    func send(_ frame: Data, until deadline: TimeInterval) async throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MobileEnrollmentRuntimeFailure.expired }
        try append(frame)
    }
    private func verify() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, peerOK else { throw MobileEnrollmentRuntimeFailure.invalidFrame }
        peerChecks += 1
    }
    func checkPeer() async throws { try verify() }
}

private final class Factory: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [MemoryTransport]
    private var count = 0
    private var delays: [Double] = []
    var failure: MobileEnrollmentRuntimeFailure = .unavailable
    init(_ sockets: [MemoryTransport]) { self.sockets = sockets }
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
    var sleeps: [Double] { lock.lock(); defer { lock.unlock() }; return delays }
    func add(_ socket: MemoryTransport) { lock.lock(); sockets.append(socket); lock.unlock() }
    func recordSleep(_ value: Double) { lock.lock(); delays.append(value); lock.unlock() }
    func next() throws -> any MobileEnrollmentTransport {
        lock.lock(); defer { lock.unlock() }; count += 1
        guard !sockets.isEmpty else { throw failure }
        return sockets.removeFirst()
    }
}

@MainActor private final class Fixture {
    let clock = Clock()
    let factory: Factory
    let socket: MemoryTransport
    var runtime: MobileEnrollmentHostRuntime!
    var enabled = true
    var observed: [String] = []
    var reason = MobileEnrollment.ActiveReason.active
    var stale = false
    var beforeObserve: (() -> Void)?
    init(identity: HostIdentity, host: MobileEnrollment.HostProfile, sockets: [MemoryTransport]? = nil) {
        socket = sockets?.first ?? MemoryTransport()
        factory = Factory(sockets ?? [socket])
        let clock = clock, factory = factory
        var deps = MobileEnrollmentDependencies()
        deps.clock = { clock.read() }
        deps.connect = { _, _ in try factory.next() }
        deps.sleep = { seconds in
            factory.recordSleep(seconds)
            // 재접속만 가속한다. 요청 deadline timer는 실제 기한을 사용한다.
            if seconds == 0.25 || seconds >= 2 {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
        }
        runtime = MobileEnrollmentHostRuntime(identity: identity, host: host, observeActive: { [weak self] challenge in
            guard let self else { throw MobileEnrollmentRuntimeFailure.stopped }
            self.beforeObserve?()
            self.observed.append(challenge.requestId)
            return .init(reason: self.reason, checkedAtMilliseconds: self.clock.read().milliseconds - (self.stale ? 3000 : 0))
        }, currentRemoteAccess: { [weak self] in self?.enabled ?? false }, dependencies: deps)
    }
    func start() { runtime.start() }
    func stop() { runtime?.stop() }
}

@main struct Checks {
    static var passed: [String] = []
    static let generation = "10000000-0000-0000-0000-000000000001"
    static let nonce = Base64URL.encode(Data(repeating: 7, count: 32))
    static func frame<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([10])
    }
    static func hostFrame(_ generation: String = generation, nonce: String = nonce) throws -> Data {
        try frame(MobileEnrollment.HostChallenge(coreGeneration: generation, nonce: nonce, origin: MobileEnrollment.origin))
    }
    @MainActor private static func challenge(_ fixture: Fixture, index: Int = 1, generation: String = generation,
                          overrideNonce: String? = nil,
                          duration: Int64 = 1400) throws -> MobileEnrollment.ActiveChallenge {
        let id = String(format: "20000000-0000-0000-0000-%012d", index)
        let nonce = overrideNonce ?? Base64URL.encode(Data(SHA256.hash(data: Data("request-nonce-\(index)".utf8))))
        let fingerprint = Base64URL.encode(Data(repeating: 3, count: 32)), principal = String(repeating: "a", count: 64)
        let now = fixture.clock.read().milliseconds, deadline = now + duration
        let digest = try MobileEnrollment.hexDigest(MobileEnrollment.activeRequestBytes(coreGeneration: generation,
            requestId: id, nonce: nonce, deviceFingerprint: fingerprint, ownerPrincipal: principal,
            origin: MobileEnrollment.origin, deadlineMilliseconds: deadline))
        return try MobileEnrollment.ActiveChallenge(requestId: id, coreGeneration: generation, nonce: nonce,
            origin: MobileEnrollment.origin, deviceFingerprint: fingerprint, ownerPrincipal: principal,
            requestDigest: digest, deadlineMilliseconds: deadline, receivedAtMilliseconds: now)
    }
    @MainActor static func wait(_ name: String, seconds: Double = 3,
                                _ condition: @MainActor () -> Bool) async {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < until {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        precondition(condition(), name)
    }
    static func envelope(_ raw: Data) throws -> MobileEnrollment.Envelope {
        let value = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        return try MobileEnrollment.Envelope.decode(JSONSerialization.data(withJSONObject: value["envelope"]!))
    }
    @MainActor private static func ready(_ f: Fixture) async throws {
        f.socket.feed(try hostFrame()); f.start()
        await wait("identity") { f.socket.sent.count == 2 }
    }
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let privateBytes = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).x963Representation
        let key = RemoteKey.importPrivate(privateBytes)!
        let identity = HostIdentity(privateKey: key, recognitionKey: Data(repeating: 0, count: 32))!
        let der = SPKI.der(point: RemoteKey.publicPoint(key)!)
        let host = try MobileEnrollment.HostProfile(macID: identity.macID,
            trustedFingerprint: Base64URL.encode(identity.fingerprint), publicSPKIDER: der)
        for seconds in [Double.nan, Double.infinity, -Double.infinity, -1,
                        Double(MobileEnrollment.maximumSafeInteger)] {
            precondition(MobileEnrollmentTime.epochMilliseconds(seconds) == -1)
        }
        precondition(MobileEnrollmentTime.epochMilliseconds(1.999) == 1999)
        passed.append("기본 Date 변환의 NaN·무한대·음수·JS safe integer 경계")

        let normal = Fixture(identity: identity, host: host)
        let hf = try hostFrame()
        for byte in hf { normal.socket.feed(Data([byte])) }
        normal.start(); normal.start()
        await wait("split identity") { normal.socket.sent.count == 2 }
        precondition(normal.factory.attempts == 1)
        try MobileEnrollment.verifyHostIdentity(envelope(normal.socket.sent[1]),
            challenge: MobileEnrollment.decodeHostChallenge(hf.dropLast()), host: host)
        try await Task.sleep(nanoseconds: 1_650_000_000)
        precondition(!normal.socket.ended && normal.factory.attempts == 1)
        let first = try challenge(normal), second = try challenge(normal, index: 2)
        normal.socket.feed(try frame(first) + frame(second))
        await wait("coalesced sequential active") { normal.socket.sent.count == 4 }
        precondition(normal.observed == [first.requestId, second.requestId])
        _ = try MobileEnrollment.verifyActiveResult(envelope(normal.socket.sent[2]), challenge: first,
            host: host, nowMilliseconds: normal.clock.read().milliseconds)
        precondition(normal.socket.verified >= 5)
        try normal.socket.sent[0].write(to: output.appendingPathComponent("attach.json"))
        try normal.socket.sent[1].write(to: output.appendingPathComponent("identity.json"))
        try normal.socket.sent[2].write(to: output.appendingPathComponent("active.json"))
        try frame(first).write(to: output.appendingPathComponent("challenge.json"))
        try hf.write(to: output.appendingPathComponent("host-challenge.json"))
        passed.append("분할 UTF8 프레임·coalesced 요청·순차 관측·attach 1회·idle 1500ms 초과 유지·typed 서명")
        normal.socket.feed(try frame(first))
        await wait("replay") { normal.socket.ended }; normal.stop()
        precondition(normal.socket.sent.count == 4)
        passed.append("동일 requestId·nonce 재생 거부와 응답 캐시 없음")

        for reason in MobileEnrollment.ActiveReason.allCases {
            let f = Fixture(identity: identity, host: host); f.reason = reason
            try await ready(f)
            let c = try challenge(f); f.socket.feed(try frame(c))
            await wait("reason") { f.socket.sent.count == 3 }
            let result = try MobileEnrollment.verifyActiveResult(envelope(f.socket.sent[2]), challenge: c,
                host: host, nowMilliseconds: f.clock.read().milliseconds)
            precondition(result.reason == reason && result.active == (reason == .active)); f.stop()
        }
        passed.append("실제 관측 closure의 6개 reason과 checkedAt 서명")

        let volume = Fixture(identity: identity, host: host); try await ready(volume)
        var expiredFrame = Data()
        for batch in 0..<129 {
            var bytes = Data()
            for offset in 1...32 {
                let c = try challenge(volume, index: batch * 32 + offset)
                let raw = try frame(c); bytes.append(raw)
                if batch == 0 && offset == 1 { expiredFrame = raw }
            }
            volume.socket.feed(bytes)
            await wait("volume batch \(batch)", seconds: 5) { volume.socket.sent.count == 2 + (batch + 1) * 32 }
            volume.clock.moveWall(2000)
        }
        precondition(volume.observed.count == 4128 && !volume.socket.ended)
        volume.socket.feed(expiredFrame)
        await wait("expired original remains rejected") { volume.socket.ended }
        precondition(volume.socket.sent.count == 4130); volume.stop()
        passed.append("현재 세대 TTL 창의 4128건 정상 처리·이력 누적 종료 없음·만료 원본 frame 복구 금지")

        let nonceReplay = Fixture(identity: identity, host: host); try await ready(nonceReplay)
        let original = try challenge(nonceReplay)
        nonceReplay.socket.feed(try frame(original))
        await wait("original nonce") { nonceReplay.socket.sent.count == 3 }
        nonceReplay.socket.feed(try frame(challenge(nonceReplay, index: 2, overrideNonce: original.nonce)))
        await wait("same nonce new id valid digest") { nonceReplay.socket.ended }
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(nonceReplay.factory.attempts == 1 && nonceReplay.socket.sent.count == 3)
        nonceReplay.stop()
        passed.append("유효한 새 digest·다른 requestId라도 TTL 내 nonce 재생 거부·암호/재생 실패 자동 재접속 0")

        let overflow = Fixture(identity: identity, host: host); try await ready(overflow)
        var burst = Data()
        for index in 1...33 { burst.append(try frame(challenge(overflow, index: index))) }
        overflow.socket.feed(burst); holdMainActor(0.1)
        await wait("pending cap 32") { overflow.socket.ended }; overflow.stop()
        passed.append("MainActor 관측 대기 중 채널당 동시 상한 32")

        for mutation in ["unknown", "duplicate", "op", "generation", "digest", "uuid", "deadline", "utf8", "oversize", "empty", "hostAgain", "nonce"] {
            let f = Fixture(identity: identity, host: host); try await ready(f)
            let c = try challenge(f)
            var raw = String(decoding: try frame(c), as: UTF8.self)
            switch mutation {
            case "unknown": raw = raw.replacingOccurrences(of: "{", with: "{\"extra\":1,")
            case "duplicate": raw = raw.replacingOccurrences(of: "{", with: "{\"op\":\"enrollment.active.challenge\",")
            case "op": raw = raw.replacingOccurrences(of: "active.challenge", with: "active.cancel")
            case "generation": raw = String(decoding: try frame(challenge(f, generation: "10000000-0000-0000-0000-000000000002")), as: UTF8.self)
            case "digest": raw = raw.replacingOccurrences(of: c.requestDigest, with: String(repeating: "f", count: 64))
            case "uuid": raw = raw.replacingOccurrences(of: c.requestId, with: c.requestId.uppercased() + "A")
            case "deadline": raw = raw.replacingOccurrences(of: String(c.deadline), with: "0")
            case "hostAgain": raw = String(decoding: try hostFrame(), as: UTF8.self)
            case "nonce": raw = raw.replacingOccurrences(of: c.nonce, with: nonce)
            case "empty": raw = "\n"
            default: break
            }
            let bytes = mutation == "utf8" ? Data([0xff, 10]) : mutation == "oversize" ? Data(repeating: 65, count: 16_385) : Data(raw.utf8)
            f.socket.feed(bytes)
            await wait(mutation) { f.socket.ended }; f.stop()
            precondition(f.socket.sent.count == 2, mutation)
        }
        passed.append("unknown·중복 키·op·세대·digest·UUID·기한·nonce·UTF8·cap·빈 프레임·중복 host.challenge 거부")

        for mode in ["stale", "late", "rollback", "peer", "stop", "remoteOff", "deinit"] {
            let f = Fixture(identity: identity, host: host); try await ready(f)
            let c = try challenge(f, duration: mode == "late" ? 30 : 1400)
            if mode == "stale" { f.stale = true }
            if mode == "late" {
                f.socket.feed(try frame(c)); holdMainActor(0.09)
            } else if mode == "rollback" {
                f.clock.moveWall(-10_000)
            } else if mode == "peer" { f.socket.rejectPeer(); f.socket.feed(try frame(c))
            } else if mode == "stop" {
                f.beforeObserve = { [weak f] in f?.stop() }; f.socket.feed(try frame(c))
            } else if mode == "remoteOff" {
                f.beforeObserve = { [weak f] in f?.enabled = false; f?.runtime.remoteAccessChanged() }
                f.socket.feed(try frame(c))
            } else if mode == "deinit" { f.runtime = nil
            } else { f.socket.feed(try frame(c)) }
            await wait(mode) { f.socket.ended }; f.stop()
            precondition(f.socket.sent.count == 2, mode)
        }
        passed.append("stale·late·MainActor 지연·시계 역행·peer 실패·stop·Remote Access off·deinit의 늦은 서명 차단")

        let a = MemoryTransport(), b = MemoryTransport()
        let reconnect = Fixture(identity: identity, host: host, sockets: [a, b])
        try await ready(reconnect)
        let lost = try challenge(reconnect); a.failResultWrite(); a.feed(try frame(lost))
        b.feed(try hostFrame("10000000-0000-0000-0000-000000000002", nonce: Base64URL.encode(Data(repeating: 8, count: 32))))
        await wait("reconnect") { b.sent.count == 2 }
        precondition(a.sent.count == 2 && reconnect.observed == [lost.requestId])
        precondition(b.sent.count == 2 && reconnect.factory.attempts == 2)
        reconnect.stop(); passed.append("미확정 결과 폐기·기존 결과 재발행 0·새 연결 attach 1회")

        let stopA = MemoryTransport(), stopB = MemoryTransport()
        let restart = Fixture(identity: identity, host: host, sockets: [stopA, stopB]); try await ready(restart)
        let old = try challenge(restart)
        restart.beforeObserve = { [weak restart] in
            guard let restart else { return }
            restart.beforeObserve = nil; restart.stop(); restart.start()
        }
        stopB.feed(try hostFrame("10000000-0000-0000-0000-000000000004", nonce: Base64URL.encode(Data(repeating: 20, count: 32))))
        stopA.feed(try frame(old))
        await wait("stop start race") { stopB.sent.count == 2 }
        precondition(stopA.ended && stopA.sent.count == 2 && !stopB.ended)
        stopB.feed(try frame(old))
        await wait("old generation packet") { stopB.ended }
        precondition(stopB.sent.count == 2); restart.stop()
        passed.append("stop/start 경쟁에서 이전 lifetime 종료가 새 채널을 닫지 않음·이전 세대 frame 거부")

        let eofA = MemoryTransport(), eofB = MemoryTransport()
        let eof = Fixture(identity: identity, host: host, sockets: [eofA, eofB]); try await ready(eof)
        eofA.feed(Data("{\"op\":".utf8)); eofA.invalidate()
        eofB.feed(try hostFrame("10000000-0000-0000-0000-000000000003", nonce: Base64URL.encode(Data(repeating: 9, count: 32))))
        await wait("partial EOF reconnect") { eofB.sent.count == 2 }
        eof.stop(); passed.append("부분 frame 뒤 EOF·새 연결에서 버퍼 재사용 0")

        let absent = Fixture(identity: identity, host: host, sockets: [])
        absent.start(); await wait("absent beyond eight", seconds: 5) { absent.factory.attempts >= 10 }
        let lateCore = MemoryTransport()
        lateCore.feed(try hostFrame())
        absent.factory.add(lateCore)
        await wait("Core appears after ten attempts") { lateCore.sent.count == 2 }
        absent.stop()
        let stoppedAttempts = absent.factory.attempts
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(absent.factory.attempts == stoppedAttempts)
        precondition(Array(absent.factory.sleeps.prefix(9)) == [0.25, 0.5, 1, 2, 4, 8, 16, 30, 30])
        passed.append("서버 부재 10회 뒤 Core 등장 자동 연결·30초 backoff 상한·stop 뒤 추가 접속 0")
        let unsafe = Fixture(identity: identity, host: host, sockets: [])
        unsafe.factory.failure = .unsafeEndpoint
        unsafe.start(); await wait("unsafe endpoint") { unsafe.factory.attempts == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(unsafe.factory.attempts == 1 && unsafe.factory.sleeps.isEmpty); unsafe.stop()
        passed.append("보안 경로 실패는 transport 부재와 구분해 자동 재시도 0")
        let report: [String: Any] = ["passed": passed, "count": passed.count,
            "actualCommandSocketConnections": 0, "OSSocketFixture": false,
            "transport": "inert memory chunks; production runtime and signer",
            "runtimeAccepted": false, "productionWiring": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
        print("runtime checks passed: \(passed.count); actual command.sock connections=0")
    }
    @MainActor private static func holdMainActor(_ duration: TimeInterval) { Thread.sleep(forTimeInterval: duration) }
}
