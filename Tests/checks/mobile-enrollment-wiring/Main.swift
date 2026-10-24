import Foundation
import Security
import StreamProtocol
@testable import SillHostCore

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


private final class Store: IdentityStore {
    let memory = MemoryIdentityStore()
    var registryReads = 0
    var pairedReads = 0
    var keyLoads = 0
    var failRead = false
    var summary: String { "격리 메모리" }
    var testDirectory: URL? { nil }
    func loadOrCreateKey() throws -> SecKey { keyLoads += 1; return try memory.loadOrCreateKey() }
    func loadOrCreateRecognitionKey() throws -> Data { try memory.loadOrCreateRecognitionKey() }
    func loadPaired() throws -> [PairedDevice] { pairedReads += 1; return try memory.loadPaired() }
    func savePaired(_ devices: [PairedDevice]) throws { try memory.savePaired(devices) }
    func loadOwnerRegistry() throws -> Data? {
        registryReads += 1
        if failRead { throw IdentityStoreError("격리 읽기 실패") }
        return try memory.loadOwnerRegistry()
    }
    func saveOwnerRegistry(_ value: Data) throws { try memory.saveOwnerRegistry(value) }
    func loadRequirePairing() throws -> Data? { try memory.loadRequirePairing() }
    func saveRequirePairing(_ value: Data) throws { try memory.saveRequirePairing(value) }
}

@MainActor private final class Fixture {
    let store = Store()
    let socket = MemoryTransport()
    let factory: Factory
    var remote: RemoteAccess?
    let principal = String(repeating: "a", count: 64)
    let fingerprint = Base64URL.encode(Data(repeating: 3, count: 32))
    init() {
        factory = Factory([socket])
        let factory = factory
        var dependencies = MobileEnrollmentDependencies()
        dependencies.connect = { _, _ in try factory.next() }
        dependencies.sleep = { seconds in
            factory.recordSleep(seconds)
            try await Task.sleep(nanoseconds: UInt64((seconds == 0.25 ? 0.005 : seconds) * 1_000_000_000))
        }
        remote = RemoteAccess(store: store, mobileEnrollmentDependencies: dependencies)
        remote!.skipsNetworkWatchersForTesting = true
    }
    var identity: HostIdentity { remote!.identity! }
    func profile() throws -> MobileEnrollment.HostProfile {
        let point = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(identity.remote.privateKey)!, nil)! as Data
        return try .init(macID: identity.macID, trustedFingerprint: Base64URL.encode(identity.fingerprint),
                         publicSPKIDER: SPKI.der(point: point))
    }
    func apply(_ enabled: Bool) {
        var config = HostConfig.standard
        config.remoteAccess = enabled
        config.internetAccess = false
        remote!.apply(config)
    }
    func register(_ state: OwnerBootstrapRegistry.Binding.State = .active,
                  pending: Bool = false, method: String = OwnerMacBootstrap.method) throws {
        var registry = OwnerBootstrapRegistry(macID: identity.macID)
        registry.bindings = [.init(principal: principal, fingerprint: fingerprint, state: state)]
        try registry.save(store: store, identity: identity)
        try store.savePaired([.init(fingerprint: fingerprint, name: "격리 기기", model: nil, pairedAt: 10,
            method: method, ownerPrincipal: method == OwnerMacBootstrap.method ? principal : nil,
            ownerActivationPending: pending)])
    }
}

@main struct Checks {
    static var groups: [String] = []
    static let generation = "10000000-0000-0000-0000-000000000001"
    static func now() -> Int64 { MobileEnrollmentTime.epochMilliseconds(Date().timeIntervalSince1970) }
    static func frame<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([10])
    }
    static func hostFrame(_ generation: String = generation, nonce: UInt8 = 7) throws -> Data {
        try frame(MobileEnrollment.HostChallenge(coreGeneration: generation,
            nonce: Base64URL.encode(Data(repeating: nonce, count: 32)), origin: MobileEnrollment.origin))
    }
    static func envelope(_ raw: Data) throws -> MobileEnrollment.Envelope {
        let value = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        return try MobileEnrollment.Envelope.decode(JSONSerialization.data(withJSONObject: value["envelope"]!))
    }
    @MainActor static func wait(_ label: String, _ condition: @MainActor () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < until {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        precondition(condition(), label)
    }
    @MainActor private static func challenge(_ fixture: Fixture, index: Int = 1,
                                            generation: String = generation) throws -> MobileEnrollment.ActiveChallenge {
        let id = String(format: "20000000-0000-0000-0000-%012d", index)
        let nonce = Base64URL.encode(Data(repeating: UInt8(index + 20), count: 32))
        let time = now(), deadline = time + 1500
        let digest = try MobileEnrollment.hexDigest(MobileEnrollment.activeRequestBytes(coreGeneration: generation,
            requestId: id, nonce: nonce, deviceFingerprint: fixture.fingerprint, ownerPrincipal: fixture.principal,
            origin: MobileEnrollment.origin, deadlineMilliseconds: deadline))
        return try .init(requestId: id, coreGeneration: generation, nonce: nonce, origin: MobileEnrollment.origin,
            deviceFingerprint: fixture.fingerprint, ownerPrincipal: fixture.principal, requestDigest: digest,
            deadlineMilliseconds: deadline, receivedAtMilliseconds: time)
    }
    @MainActor private static func ask(_ fixture: Fixture, socket: MemoryTransport, index: Int,
                                     reason: MobileEnrollment.ActiveReason, generation: String = generation) async throws {
        let request = try challenge(fixture, index: index, generation: generation)
        let before = socket.sent.count
        socket.feed(try frame(request))
        try await wait("현재 원장 관측 응답") { socket.sent.count == before + 1 }
        let result = try MobileEnrollment.verifyActiveResult(envelope(socket.sent.last!), challenge: request,
            host: fixture.profile(), nowMilliseconds: now())
        precondition(result.reason == reason && result.active == (reason == .active))
    }
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let f = Fixture()
        f.apply(false)
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(f.factory.attempts == 0 && f.socket.sent.isEmpty)
        groups.append("설정 off에서 connect와 attach 0")
        try f.register()
        f.socket.feed(try hostFrame())
        f.apply(true)
        for _ in 0..<20 { f.apply(true) }
        try await wait("정본 Host identity") { f.socket.sent.count == 2 }
        precondition(f.factory.attempts == 1 && f.store.keyLoads == 1)
        let profile = try f.profile()
        try MobileEnrollment.verifyHostIdentity(envelope(f.socket.sent[1]),
            challenge: MobileEnrollment.decodeHostChallenge(hostFrame().dropLast()), host: profile)
        groups.append("실제 apply 21회에서 connect·attach 1회, 정본 identity·profile 일치")
        let reads = f.store.registryReads, pairedReads = f.store.pairedReads
        try await ask(f, socket: f.socket, index: 1, reason: .active)
        precondition(f.store.registryReads == reads + 2 && f.store.pairedReads == pairedReads + 2)
        let request = try challenge(f, index: 2)
        let before = f.socket.sent.count
        f.socket.feed(try frame(request))
        try await wait("Node 호환 응답") { f.socket.sent.count == before + 1 }
        try f.socket.sent[0].write(to: output.appendingPathComponent("attach.json"))
        try f.socket.sent[1].write(to: output.appendingPathComponent("identity.json"))
        try f.socket.sent.last!.write(to: output.appendingPathComponent("active.json"))
        try frame(request).write(to: output.appendingPathComponent("challenge.json"))
        try hostFrame().write(to: output.appendingPathComponent("host-challenge.json"))
        try f.register(.revoked)
        try await ask(f, socket: f.socket, index: 3, reason: .revoked)
        try f.register(pending: true)
        try await ask(f, socket: f.socket, index: 4, reason: .notRegistered)
        try f.register(method: PairRequest.qr)
        try await ask(f, socket: f.socket, index: 5, reason: .active)
        try f.store.savePaired([])
        try await ask(f, socket: f.socket, index: 6, reason: .notRegistered)
        try f.register()
        f.store.failRead = true
        try await ask(f, socket: f.socket, index: 7, reason: .unavailable)
        f.store.failRead = false
        groups.append("각 요청의 registry·paired 이중 재조회와 철회·pending·QR·누락·읽기 오류 반영")
        let second = MemoryTransport()
        f.factory.add(second)
        let generation2 = "10000000-0000-0000-0000-000000000002"
        second.feed(try hostFrame(generation2, nonce: 8))
        f.socket.feed(Data())
        try await wait("EOF 재접속") { second.sent.count == 2 }
        precondition(f.socket.ended && f.factory.attempts == 2 && f.store.keyLoads == 1)
        try await ask(f, socket: second, index: 8, reason: .active, generation: generation2)
        groups.append("EOF 뒤 같은 identity·현재 원장의 새 채널 재접속")
        f.apply(false)
        precondition(second.ended)
        let attempts = f.factory.attempts, sent = second.sent.count
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(f.factory.attempts == attempts && second.sent.count == sent)
        let disabled = try f.remote!.mobileEnrollmentObservation(challenge: challenge(f, index: 9), nowMS: now())
        precondition(disabled.reason == .disabled && !disabled.active)
        groups.append("off에서 즉시 transport 무효화·재접속과 추가 응답 0·disabled 관측")
        let third = MemoryTransport()
        f.factory.add(third)
        third.feed(try hostFrame("10000000-0000-0000-0000-000000000003", nonce: 9))
        f.apply(true)
        try await wait("다시 on") { third.sent.count == 2 }
        precondition(f.factory.attempts == 3 && f.store.keyLoads == 1)
        f.remote!.stopMobileEnrollment()
        precondition(third.ended)
        groups.append("off 뒤 on의 단일 새 채널과 Host 종료의 stop")
        weak var weakRemote = f.remote
        f.remote = nil
        precondition(weakRemote == nil)
        let weakFixture = Fixture()
        weak var liveRemote = weakFixture.remote
        weakFixture.socket.feed(try hostFrame())
        weakFixture.apply(true)
        try await wait("해제 전 활성 채널") { weakFixture.socket.sent.count == 2 }
        weakFixture.remote = nil
        precondition(liveRemote == nil && weakFixture.socket.ended)
        let lifetimeAttempts = weakFixture.factory.attempts
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(weakFixture.factory.attempts == lifetimeAttempts)
        groups.append("활성 runtime closure의 weak capture·소유자 해제 뒤 채널 폐쇄")
        let missing = Fixture()
        missing.factory.failure = .unavailable
        missing.socket.feed(Data())
        missing.apply(true)
        try await wait("transport 부재 재접속") { missing.factory.attempts >= 2 }
        missing.apply(false)
        let stopped = missing.factory.attempts
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(missing.factory.attempts == stopped)
        groups.append("부재 재접속 대기 중 off의 취소")
        let report: [String: Any] = ["passed": true, "groups": groups, "groupCount": groups.count,
            "actualKeychainCalls": 0, "actualTLSConnections": 0, "actualCommandSocketConnections": 0,
            "actualOSSocketConnections": 0, "actualHostLaunches": 0, "installedHostChanges": 0,
            "UIAudioDeviceEffects": 0, "scope": "production RemoteAccess.apply and mobile runtime, memory store/transport"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("wiring-report.json"))
        print("모바일 등록 실제 배선 검사 \(groups.count)개 묶음 통과. 실제 소켓·Host·키체인 효과 0.")
    }
}
