import Foundation
import Security
import StreamProtocol
@testable import SillHostCore

private final class SensorFixture: @unchecked Sendable {
    var status: [String: Any] = ["BackendState": "Running", "Self": ["ID": "host-node", "UserID": 7,
        "TailscaleIPs": ["100.64.0.1"], "Expired": false]]
    var node: [String: Any] = ["StableID": "peer-node", "User": 7, "MachineAuthorized": true,
        "Addresses": ["100.64.0.2/32"], "Expired": false]
    var user: UInt64 = 7
    var commands: [TailnetDeviceAccess.Command] = []
    var beforeRead: ((TailnetDeviceAccess.Command) throws -> Void)?

    func sensor() -> TailnetDeviceAccess {
        TailnetDeviceAccess(testingRead: { [self] command, check in
            try check()
            try beforeRead?(command)
            commands.append(command)
            switch command {
            case .status: return try JSONSerialization.data(withJSONObject: status)
            case .whois: return try JSONSerialization.data(withJSONObject: ["Node": node, "UserProfile": ["ID": user]])
            }
        })
    }
}

private final class FaultStore: IdentityStore {
    let memory = MemoryIdentityStore()
    var pairedFailure = false
    var pairedDrops = false
    var registryFailure = false
    var registryDrops = false
    var readRegistryFailure = false
    var registryMissing = false
    var afterRegistrySave: (() -> Void)?
    var beforePairedSave: (() -> Void)?
    var writes = 0
    var summary: String { "격리 검사 메모리" }
    var testDirectory: URL? { nil }
    func loadOrCreateKey() throws -> SecKey { try memory.loadOrCreateKey() }
    func loadOrCreateRecognitionKey() throws -> Data { try memory.loadOrCreateRecognitionKey() }
    func loadPaired() throws -> [PairedDevice] { try memory.loadPaired() }
    func savePaired(_ devices: [PairedDevice]) throws {
        beforePairedSave?()
        if pairedFailure { throw IdentityStoreError("검사 저장 실패") }
        if !pairedDrops { try memory.savePaired(devices) }
        writes += 1
    }
    func loadOwnerRegistry() throws -> Data? {
        if readRegistryFailure { throw IdentityStoreError("검사 읽기 실패") }
        if registryMissing { return nil }
        return try memory.loadOwnerRegistry()
    }
    func saveOwnerRegistry(_ record: Data) throws {
        if registryFailure { throw IdentityStoreError("검사 원장 저장 실패") }
        if !registryDrops { try memory.saveOwnerRegistry(record) }
        afterRegistrySave?()
    }
    func loadRequirePairing() throws -> Data? { try memory.loadRequirePairing() }
    func saveRequirePairing(_ record: Data) throws { try memory.saveRequirePairing(record) }
}

private final class LegacyStore: IdentityStore {
    let memory = MemoryIdentityStore()
    var summary: String { "구형 저장소 격리 검사" }
    var testDirectory: URL? { nil }
    func loadOrCreateKey() throws -> SecKey { try memory.loadOrCreateKey() }
    func loadOrCreateRecognitionKey() throws -> Data { try memory.loadOrCreateRecognitionKey() }
    func loadPaired() throws -> [PairedDevice] { try memory.loadPaired() }
    func savePaired(_ devices: [PairedDevice]) throws { try memory.savePaired(devices) }
    func loadRequirePairing() throws -> Data? { try memory.loadRequirePairing() }
    func saveRequirePairing(_ record: Data) throws { try memory.saveRequirePairing(record) }
}

final class OwnerBootstrapChecks {
    private func assertOK(_ result: PairResult, file: StaticString = #filePath, line: UInt = #line) {
        expectTrue(result.ok, file: file, line: line)
    }
    private func assertClosed(_ result: PairResult, file: StaticString = #filePath, line: UInt = #line) {
        expectFalse(result.ok, file: file, line: line)
    }
    private func binding(_ key: UInt8 = 1, source: String = "100.64.0.2", local: String = "100.64.0.1") -> OwnerBootstrapSocket.Binding {
        .init(generation: UUID(), fingerprint: Data(repeating: key, count: 32), sourceIP: source, localIP: local, interface: "utun9")
    }
    private func request() -> PairRequest {
        PairRequest(v: 2, method: OwnerMacBootstrap.method, proof: "", name: "검사 기기", model: "fixture")
    }
    private func attempt(_ socket: OwnerBootstrapSocket, request: PairRequest? = nil, door: DoorPolicy.Door = .remote) -> Door.PairAttempt {
        .init(door: door, request: request ?? self.request(), deviceFingerprint: socket.binding.fingerprint,
              source: socket.binding.sourceIP, display: "격리 검사", origin: .vpn, interface: socket.binding.interface,
              fromThisMac: false, cable: nil, ownerSocket: socket)
    }
    @MainActor private func remote(_ store: IdentityStore, fixture: SensorFixture = SensorFixture(), enabled: Bool = true) -> RemoteAccess {
        let remote = RemoteAccess(store: store)
        remote.configureOwnerBootstrapForTesting(sensor: fixture.sensor(), enabled: enabled)
        return remote
    }
    private func assertDenied(_ fixture: SensorFixture, file: StaticString = #filePath, line: UInt = #line) async {
        let result = await fixture.sensor().principal(for: binding())
        if case .success = result { fail("허용하면 안 되는 센서 증거", file: file, line: line) }
        else { expectTrue(true, file: file, line: line) }
    }

    func testWireAndALPNIsolation() {
        expectTrue(RemoteTLS.serverALPNs.contains(RemoteTLS.sessionALPN))
        expectTrue(RemoteTLS.serverALPNs.contains(RemoteTLS.pairingALPN))
        expectTrue(RemoteTLS.serverALPNs.contains(OwnerMacBootstrap.alpn))
        expectTrue(OwnerBootstrapWire.accepts(request()))
        for method in [PairRequest.qr, PairRequest.code, PairRequest.ask, PairRequest.cancel, "other"] {
            var r = request(); r.method = method; expectFalse(OwnerBootstrapWire.accepts(r))
        }
        var r = request(); r.v = 1; expectFalse(OwnerBootstrapWire.accepts(r))
        r = request(); r.proof = "untrusted"; expectFalse(OwnerBootstrapWire.accepts(r))
        r = request(); r.cable = true; expectFalse(OwnerBootstrapWire.accepts(r))
        r.cable = false; expectFalse(OwnerBootstrapWire.accepts(r))
        expectFalse(DoorPolicy.trusts(.home, alpn: OwnerMacBootstrap.alpn, .init(remoteAccess: true)))
        expectFalse(DoorPolicy.trusts(.remote, alpn: OwnerMacBootstrap.alpn, .init()))
        expectTrue(DoorPolicy.trusts(.remote, alpn: OwnerMacBootstrap.alpn, .init(remoteAccess: true)))
        expectFalse(DoorPolicy.trusts(.remote, alpn: RemoteTLS.sessionALPN, .init(remoteAccess: true)))
        expectTrue(DoorPolicy.trusts(.remote, alpn: RemoteTLS.sessionALPN, .init(paired: true, remoteAccess: true)))
        expectEqual(DoorPolicy.pairing(.remote, method: OwnerMacBootstrap.method, version: 2), .closed)
        expectEqual(DoorPolicy.atReady(.remote, alpn: OwnerMacBootstrap.alpn, .init(remoteAccess: true), remoteSessions: 8), .pairing)
        expectEqual(DoorPolicy.atReady(.home, alpn: OwnerMacBootstrap.alpn, .init(remoteAccess: true), remoteSessions: 0), .refuse("unpaired"))
    }

    func testMissingAndZeroExpiryFollowApprovedSchema() async {
        for expiry in [nil, "0001-01-01T00:00:00Z", "2099-01-01T00:00:00Z", "2099-01-01T00:00:00.123Z"] {
            let fixture = SensorFixture()
            fixture.node["KeyExpiry"] = expiry
            let sensor = fixture.sensor(), b = binding()
            guard case .success(let proof) = await sensor.principal(for: b) else { fail("승인된 schema를 거부했습니다."); continue }
            expectEqual(proof.binding, b)
            expectEqual(proof.localIPs, ["100.64.0.1"])
            expectTrue(sensor.isCurrent(proof))
            expectEqual(fixture.commands, [.status, .whois("100.64.0.2"), .status])
            sensor.stop()
            expectFalse(sensor.isCurrent(proof))
        }
    }

    func testNullMalformedExpiredEvidenceDenied() async {
        for expiry: Any in [NSNull(), "bad", 5, "2025-02-29T00:00:00Z", "2000-01-01T00:00:00Z", "2099-13-01T00:00:00Z"] {
            let fixture = SensorFixture(); fixture.node["KeyExpiry"] = expiry
            await assertDenied(fixture)
        }
        let fixture = SensorFixture(); fixture.node["Expired"] = true
        await assertDenied(fixture)
    }

    func testOwnershipAndApprovalDenied() async {
        for (key, value): (String, Any) in [("User", 8), ("MachineAuthorized", false), ("MachineAuthorized", NSNull()),
            ("StableID", ""), ("Sharer", 8), ("Tags", ["tag:server"]), ("UnsignedPeerAPIOnly", true),
            ("IsJailed", true), ("IsWireGuardOnly", true), ("Addresses", ["100.64.0.3/32"]),
            ("Addresses", ["100.64.0.2/24"])] {
            let fixture = SensorFixture(); fixture.node[key] = value
            await assertDenied(fixture)
        }
        let fixture = SensorFixture(); fixture.user = 9; await assertDenied(fixture)
    }

    func testBackendAndStatusChangesDenied() async {
        let stopped = SensorFixture(); stopped.status["BackendState"] = "Stopped"; await assertDenied(stopped)
        let changed = SensorFixture()
        changed.beforeRead = { command in
            if case .whois = command { changed.status["Self"] = ["ID": "changed", "UserID": 7, "TailscaleIPs": ["100.64.0.1"]] }
        }
        await assertDenied(changed)
        let expired = SensorFixture(); expired.status["Self"] = ["ID": "host-node", "UserID": 7, "TailscaleIPs": ["100.64.0.1"], "Expired": true]
        await assertDenied(expired)
    }

    func testLANAndOutputLimitDenied() async {
        for address in ["192.168.1.2", "127.0.0.1", "100.64.0.2%utun9", "100.64.0.2/32", "example.com"] {
            let fixture = SensorFixture()
            let result = await fixture.sensor().principal(for: binding(source: address))
            if case .success = result { fail("Tailnet 외 주소를 허용했습니다.") }
            expectTrue(fixture.commands.isEmpty)
        }
        let sensor = TailnetDeviceAccess(testingRead: { _, _ in Data(repeating: 32, count: TailnetDeviceAccess.outputLimit + 1) })
        if case .success = await sensor.principal(for: binding()) { fail("출력 제한을 우회했습니다.") }
    }

    @MainActor func testProductionRegistrationAndPairedReconnect() async throws {
        let store = FaultStore()
        let host = self.remote(store)
        let socket = OwnerBootstrapSocket.fixture(binding: binding())
        let result = await host.judgeOwnerBootstrap(attempt(socket))
        expectTrue(result.ok)
        expectEqual(result.method, OwnerMacBootstrap.method)
        expectNil(result.proof)
        let object = try require(JSONSerialization.jsonObject(with: Wire.encode(result)) as? [String: Any])
        expectEqual(Set(object.keys), Set(["ok", "method", "macID", "name", "recognitionKey"]))
        expectEqual(try store.loadPaired().count, 1)
        expectNotNil(try store.loadPaired()[0].ownerPrincipal)
        expectNotNil(host.trust.snapshot.paired[socket.binding.fingerprint])
        let restarted = self.remote(store)
        expectNotNil(restarted.trust.snapshot.paired[socket.binding.fingerprint])
        assertOK(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
    }

    @MainActor func testRemoteOffWrongDoorAndKeyMismatchDenied() async {
        let store = FaultStore(), host = remote(FaultStore(), enabled: false)
        let socket = OwnerBootstrapSocket.fixture(binding: binding())
        assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
        let enabled = remote(store)
        assertClosed(await enabled.judgeOwnerBootstrap(attempt(socket, door: .home)))
        var wrong = attempt(socket); wrong = .init(door: .remote, request: request(), deviceFingerprint: Data(repeating: 9, count: 32),
            source: socket.binding.sourceIP, display: "검사", origin: .vpn, interface: "utun9", fromThisMac: false, cable: nil, ownerSocket: socket)
        assertClosed(await enabled.judgeOwnerBootstrap(wrong))
        expectEqual(store.writes, 0)
    }

    @MainActor func testCancellationAndRouteChangeDenied() async {
        for routeChanges in [false, true] {
            let fixture = SensorFixture(), store = FaultStore()
            let live = LiveFlag()
            let socket = OwnerBootstrapSocket.fixture(binding: binding()) { live.get() }
            fixture.beforeRead = { command in
                if case .whois = command { if routeChanges { live.set(false) } else { socket.cancel() } }
            }
            let host = remote(store, fixture: fixture)
            assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
            expectEqual(store.writes, 0)
        }
    }

    @MainActor func testWrongLocalEndpointDenied() async {
        let store = FaultStore()
        let host = remote(store)
        let socket = OwnerBootstrapSocket.fixture(binding: binding(local: "100.64.0.3"))
        assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
        expectTrue(try! store.loadPaired().isEmpty)
    }

    @MainActor func testRemovalAndRekeyNeverBootstrapAgain() async throws {
        let store = FaultStore()
        let active = remote(store)
        assertOK(await active.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        assertClosed(await active.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding(2)))))
        let fp = Base64URL.encode(binding().fingerprint)
        expectNil(active.remove(fingerprint: fp))
        expectTrue(try store.loadPaired().isEmpty)
        expectTrue(active.trust.snapshot.paired.isEmpty)
        let restarted = remote(store)
        for key: UInt8 in [1, 2] {
            assertClosed(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding(key)))))
        }
    }

    @MainActor func testRegistryFailureNeverProducesPairingSuccess() async throws {
        for drop in [false, true] {
            let store = FaultStore(); store.registryFailure = !drop; store.registryDrops = drop
            let host = remote(store)
            assertClosed(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            expectTrue(try store.loadPaired().isEmpty)
            expectTrue(host.trust.snapshot.paired.isEmpty)
        }
    }

    @MainActor func testPartialReservationRequiresExplicitRecovery() async throws {
        let store = FaultStore(); store.pairedFailure = true
        let host = remote(store)
        assertClosed(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectTrue(try store.loadPaired().isEmpty)
        expectNotNil(try store.loadOwnerRegistry())
        store.pairedFailure = false
        let restarted = remote(store)
        for key: UInt8 in [1, 2] {
            assertClosed(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding(key)))))
        }
    }

    @MainActor func testPairedReadbackAndRemovalFailures() async throws {
        let dropped = FaultStore(); dropped.pairedDrops = true
        let host = remote(dropped)
        assertClosed(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectTrue(host.trust.snapshot.paired.isEmpty)
        let store = FaultStore()
        let owner = remote(store)
        assertOK(await owner.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        store.pairedFailure = true
        expectNotNil(owner.remove(fingerprint: Base64URL.encode(binding().fingerprint)))
        expectEqual(try store.loadPaired().count, 1)
        store.pairedFailure = false; store.registryFailure = true
        expectNotNil(owner.remove(fingerprint: Base64URL.encode(binding().fingerprint)))
        expectTrue(try store.loadPaired().isEmpty)
        expectTrue(owner.trust.snapshot.paired.isEmpty)
        assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding(2)))))
    }

    @MainActor func testTamperedMissingRegistryFailClosedOnlyForOwner() async throws {
        let store = FaultStore()
        let host = remote(store)
        assertOK(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        let original = try require(store.loadOwnerRegistry())
        try store.memory.saveOwnerRegistry(Data("{}".utf8))
        let damaged = remote(store)
        expectTrue(damaged.trust.snapshot.paired.isEmpty)
        assertClosed(await damaged.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        try store.memory.saveOwnerRegistry(original)
        expectEqual(remote(store).trust.snapshot.paired.count, 1)
        store.readRegistryFailure = true
        expectTrue(remote(store).trust.snapshot.paired.isEmpty)
    }

    @MainActor func testExplicitPairingRemainsIndependentOfAutomaticRevocation() async throws {
        let store = FaultStore()
        let host = remote(store)
        assertOK(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        let fp = Base64URL.encode(binding().fingerprint)
        expectNil(host.remove(fingerprint: fp))
        try store.savePaired([PairedDevice(fingerprint: fp, name: "명시적 허용", model: nil, pairedAt: 1, method: PairRequest.code)])
        let restarted = remote(store)
        expectEqual(restarted.trust.snapshot.paired.count, 1)
        assertClosed(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        let encoded = try JSONEncoder().encode(try store.loadPaired())
        expectFalse(String(decoding: encoded, as: UTF8.self).contains("ownerPrincipal"))
    }

    func testProductionRouteBindingRequiresTailnetTunnelAndFreshGeneration() {
        let local = IPBytes.parse("100.64.0.1")!
        let generation = UUID(), key = Data(repeating: 1, count: 32)
        let good = OriginPolicy.Interfaces(kind: ["utun9": .tunnel], owner: [local: "utun9"])
        let route = OwnerBootstrapSocket.routeBinding(generation: generation, fingerprint: key,
            source: "100.64.0.2", local: "100.64.0.1", interfaces: good)
        expectNotNil(route)
        expectEqual(route?.generation, generation)
        expectNotEqual(route, OwnerBootstrapSocket.routeBinding(generation: UUID(), fingerprint: key,
            source: "100.64.0.2", local: "100.64.0.1", interfaces: good))
        for interfaces in [OriginPolicy.Interfaces(), .init(kind: ["en0": .lan], owner: [local: "en0"]),
                           .init(kind: ["awdl0": .peerToPeer], owner: [local: "awdl0"])] {
            expectNil(OwnerBootstrapSocket.routeBinding(generation: generation, fingerprint: key,
                source: "100.64.0.2", local: "100.64.0.1", interfaces: interfaces))
        }
        for source in ["192.168.1.2", "127.0.0.1", "100.64.0.1"] {
            expectNil(OwnerBootstrapSocket.routeBinding(generation: generation, fingerprint: key,
                source: source, local: "100.64.0.1", interfaces: good))
        }
    }

    @MainActor func testLastCheckAfterReservationDeniesChangedSocket() async throws {
        let store = FaultStore(), live = LiveFlag()
        store.afterRegistrySave = { live.set(false) }
        let host = remote(store)
        let socket = OwnerBootstrapSocket.fixture(binding: binding()) { live.get() }
        assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
        expectTrue(try store.loadPaired().isEmpty)
        expectEqual(store.writes, 0)
    }

    @MainActor func testMissingRegistryAndForeignSignatureDenyOnlyAutomaticTrust() async throws {
        let store = FaultStore()
        let active = remote(store)
        assertOK(await active.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        let record = try require(store.loadOwnerRegistry())
        store.registryMissing = true
        let missing = remote(store)
        expectTrue(missing.trust.snapshot.paired.isEmpty)
        assertClosed(await missing.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        store.registryMissing = false
        let foreign = FaultStore()
        try foreign.saveOwnerRegistry(record)
        assertClosed(await remote(foreign).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
    }

    func testPublicProfileFactoryUsesCurrentIdentityAndOnlyLocalSensorProof() async throws {
        let fixture = SensorFixture()
        fixture.node["StableID"] = "host-node"
        fixture.node["Addresses"] = ["100.64.0.1/32"]
        let sensor = fixture.sensor()
        guard case .success(let proof) = await sensor.localProfile() else { return fail("자기 노드 검증 실패") }
        let store = MemoryIdentityStore()
        let identity = try require(HostIdentity(privateKey: store.loadOrCreateKey(), recognitionKey: store.loadOrCreateRecognitionKey()))
        let profile = try require(identity.ownerMacBootstrap(sensor: sensor, proof: proof, remotePort: 7455))
        expectEqual(profile.fingerprintData, identity.fingerprint)
        expectEqual(profile.macID, identity.macID)
        expectEqual(profile.addresses, ["100.64.0.1"])
        let data = try JSONEncoder().encode(profile)
        let fields = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        expectEqual(Set(fields.keys), Set(["schema", "macID", "fingerprint", "addresses", "remotePort"]))
        let peerSensor = SensorFixture().sensor()
        guard case .success(let peerProof) = await peerSensor.principal(for: binding()) else { return fail("기기 proof 발급 실패") }
        expectNil(identity.ownerMacBootstrap(sensor: peerSensor, proof: peerProof, remotePort: 7455))
        sensor.stop()
        expectNil(identity.ownerMacBootstrap(sensor: sensor, proof: proof, remotePort: 7455))
    }

    @MainActor func testRemoteSettingEpochAndProofExpiryBeforeSave() async throws {
        for expireProof in [false, true] {
            let store = FaultStore(), fixture = SensorFixture(), sensor = fixture.sensor()
            let host = remote(store)
            host.configureOwnerBootstrapForTesting(sensor: sensor, enabled: true)
            let socket = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust)
            store.afterRegistrySave = {
                if expireProof { Thread.sleep(forTimeInterval: 2.05) }
                else {
                    host.configureOwnerBootstrapForTesting(sensor: sensor, enabled: false)
                    host.configureOwnerBootstrapForTesting(sensor: sensor, enabled: true)
                }
            }
            assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
            expectTrue(try store.loadPaired().isEmpty)
            expectEqual(store.writes, 0)
        }
    }

    func testCancelledQueryNeverIssuesProof() async {
        let fixture = SensorFixture()
        fixture.beforeRead = { _ in Thread.sleep(forTimeInterval: 0.01) }
        let sensor = fixture.sensor(), b = binding()
        let task = Task { await sensor.principal(for: b) }
        task.cancel()
        switch await task.value {
        case .success: fail("취소된 조회가 proof를 발급했습니다.")
        case .failure: expectTrue(true)
        }
    }

    @MainActor func testUnsupportedStorePreservesLegacyPairing() async throws {
        let store = LegacyStore(), key = Data(repeating: 9, count: 32)
        let legacy = PairedDevice(fingerprint: Base64URL.encode(key), name: "기존 기기", model: nil,
                                  pairedAt: 1, method: PairRequest.qr)
        try store.savePaired([legacy])
        let host = remote(store)
        expectNotNil(host.trust.snapshot.paired[key])
        assertClosed(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectEqual(try store.loadPaired(), [legacy])
        expectNotNil(host.trust.snapshot.paired[key])
    }

    func testOversizedRegistryNeverOverwritesValidRecord() throws {
        let store = MemoryIdentityStore()
        let identity = try require(HostIdentity(privateKey: store.loadOrCreateKey(), recognitionKey: store.loadOrCreateRecognitionKey()))
        var registry = OwnerBootstrapRegistry(macID: identity.macID)
        try registry.save(store: store, identity: identity)
        let original = try require(store.loadOwnerRegistry())
        registry.bindings = Array(repeating: .init(principal: String(repeating: "a", count: 64),
            fingerprint: Base64URL.encode(Data(repeating: 1, count: 32))), count: 20_000)
        expectThrows(try registry.save(store: store, identity: identity))
        expectEqual(try store.loadOwnerRegistry(), original)
    }

    func testProofExpirationAndStop() async throws {
        let sensor = SensorFixture().sensor()
        guard case .success(let proof) = await sensor.principal(for: binding()) else { return fail("검사 proof 발급 실패") }
        try await Task.sleep(nanoseconds: 2_050_000_000)
        expectFalse(sensor.isCurrent(proof))
        sensor.stop()
        if case .success = await sensor.principal(for: binding()) { fail("중지된 센서가 허용했습니다.") }
    }

    func testCanonicalSignedSensorRejectsUnexpectedExecutable() {
        expectThrows(try SignedHostExecutable.validate(path: "/usr/bin/true", identifier: "io.tailscale.ipn.macsys", team: "W5364U7YZB"))
    }
}

private final class LiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
}

private final class CheckCounts: @unchecked Sendable {
    static let shared = CheckCounts()
    private let lock = NSLock()
    private var passed = 0
    private var failed = 0
    func record(_ ok: Bool, message: String, file: StaticString, line: UInt) {
        lock.lock(); defer { lock.unlock() }
        if ok { passed += 1 }
        else { failed += 1; print("FAIL \(file):\(line) \(message)") }
    }
    var result: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (passed, failed) }
}

private struct CheckFailure: Error {}
private func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    CheckCounts.shared.record(false, message: message, file: file, line: line)
}
private func expectTrue(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { CheckCounts.shared.record(try expression(), message: "조건 불충족", file: file, line: line) }
    catch { fail("검사 중 예외", file: file, line: line) }
}
private func expectFalse(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(try !expression(), file: file, line: line)
}
private func expectEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                      file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(try lhs() == rhs(), file: file, line: line)
}
private func expectNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                         file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(try lhs() != rhs(), file: file, line: line)
}
private func expectNil<T>(_ expression: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(try expression() == nil, file: file, line: line)
}
private func expectNotNil<T>(_ expression: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(try expression() != nil, file: file, line: line)
}
private func require<T>(_ value: T?) throws -> T { guard let value else { throw CheckFailure() }; return value }
private func expectThrows(_ expression: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    do { try expression(); fail("거절해야 하는 호출 성공", file: file, line: line) }
    catch { expectTrue(true, file: file, line: line) }
}

@main
private struct OwnerHostBootstrapCheck {
    @MainActor static func main() async {
        let checks = OwnerBootstrapChecks()
        checks.testWireAndALPNIsolation()
        await checks.testMissingAndZeroExpiryFollowApprovedSchema()
        await checks.testNullMalformedExpiredEvidenceDenied()
        await checks.testOwnershipAndApprovalDenied()
        await checks.testBackendAndStatusChangesDenied()
        await checks.testLANAndOutputLimitDenied()
        do { try await checks.testProductionRegistrationAndPairedReconnect() } catch { fail("testProductionRegistrationAndPairedReconnect 예외") }
        await checks.testRemoteOffWrongDoorAndKeyMismatchDenied()
        await checks.testCancellationAndRouteChangeDenied()
        await checks.testWrongLocalEndpointDenied()
        do { try await checks.testRemovalAndRekeyNeverBootstrapAgain() } catch { fail("testRemovalAndRekeyNeverBootstrapAgain 예외") }
        do { try await checks.testRegistryFailureNeverProducesPairingSuccess() } catch { fail("testRegistryFailureNeverProducesPairingSuccess 예외") }
        do { try await checks.testPartialReservationRequiresExplicitRecovery() } catch { fail("testPartialReservationRequiresExplicitRecovery 예외") }
        do { try await checks.testPairedReadbackAndRemovalFailures() } catch { fail("testPairedReadbackAndRemovalFailures 예외") }
        do { try await checks.testTamperedMissingRegistryFailClosedOnlyForOwner() } catch { fail("testTamperedMissingRegistryFailClosedOnlyForOwner 예외") }
        do { try await checks.testExplicitPairingRemainsIndependentOfAutomaticRevocation() } catch { fail("testExplicitPairingRemainsIndependentOfAutomaticRevocation 예외") }
        checks.testProductionRouteBindingRequiresTailnetTunnelAndFreshGeneration()
        do { try await checks.testLastCheckAfterReservationDeniesChangedSocket() } catch { fail("testLastCheckAfterReservationDeniesChangedSocket 예외") }
        do { try await checks.testMissingRegistryAndForeignSignatureDenyOnlyAutomaticTrust() } catch { fail("testMissingRegistryAndForeignSignatureDenyOnlyAutomaticTrust 예외") }
        do { try await checks.testPublicProfileFactoryUsesCurrentIdentityAndOnlyLocalSensorProof() } catch { fail("testPublicProfileFactoryUsesCurrentIdentityAndOnlyLocalSensorProof 예외") }
        do { try await checks.testRemoteSettingEpochAndProofExpiryBeforeSave() } catch { fail("설정 세대 및 저장 직전 만료 검사 예외") }
        await checks.testCancelledQueryNeverIssuesProof()
        do { try await checks.testUnsupportedStorePreservesLegacyPairing() } catch { fail("구형 저장소 호환성 검사 예외") }
        do { try checks.testOversizedRegistryNeverOverwritesValidRecord() } catch { fail("원장 크기 한도 검사 예외") }
        do { try await checks.testProofExpirationAndStop() } catch { fail("testProofExpirationAndStop 예외") }
        checks.testCanonicalSignedSensorRejectsUnexpectedExecutable()
        let (passed, failed) = CheckCounts.shared.result
        print("생산 함수 기반 호스트 검사 \(passed)개 통과, \(failed)개 실패. 네트워크·실제 키체인·설치·오디오 호출 0.")
        exit(failed == 0 ? 0 : 1)
    }
}
