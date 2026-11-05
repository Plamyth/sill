import Foundation
import Security
import StreamProtocol
@testable import SillHostCore

private extension OwnerBootstrapSocket.Evidence {
    var sensor: TailnetDeviceAccess {
        guard case .tailnet(let sensor, _) = self else { preconditionFailure("Tailnet fixture required") }
        return sensor
    }
    var proof: TailnetDeviceAccess.Proof {
        guard case .tailnet(_, let proof) = self else { preconditionFailure("Tailnet fixture required") }
        return proof
    }
}

#if OWNER_PUBLIC_PROFILE_NO_PRINCIPAL
private func rejectPublicPrincipal(_ profile: TailnetDeviceAccess.PublicProfile) -> String { profile.principal }
#endif
#if OWNER_PUBLIC_PROFILE_NO_BINDING
private func rejectPublicBinding(_ profile: TailnetDeviceAccess.PublicProfile) -> OwnerBootstrapSocket.Binding? { profile.binding }
#endif
#if OWNER_PUBLIC_PROFILE_NO_PROOF
private func rejectPublicProof(_ profile: TailnetDeviceAccess.PublicProfile) -> TailnetDeviceAccess.Proof { profile }
#endif
#if OWNER_PUBLIC_PROFILE_NO_EVIDENCE
private func rejectPublicEvidence(_ profile: TailnetDeviceAccess.PublicProfile, sensor: TailnetDeviceAccess) -> OwnerBootstrapSocket.Evidence {
    .init(sensor: sensor, proof: profile)
}
#endif
#if OWNER_PUBLIC_PROFILE_NO_ADMIT
private func rejectPublicAdmission(_ profile: TailnetDeviceAccess.PublicProfile, socket: OwnerBootstrapSocket, box: TrustBox) {
    _ = socket.admit(in: box, evidence: profile) { _ in }
}
#endif
#if OWNER_PUBLIC_PROFILE_NO_RECEIPT
private func rejectPublicReceipt(_ profile: TailnetDeviceAccess.PublicProfile, socket: OwnerBootstrapSocket, box: TrustBox) {
    _ = socket.issueReceipt(in: box, evidence: profile, valid: { _ in true }, issue: { PairResult(ok: false) })
}
#endif

private final class SensorFixture: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    var status: [String: Any] = ["BackendState": "Running", "Self": ["ID": "host-node", "UserID": 7,
        "TailscaleIPs": ["100.64.0.1"], "Expired": false]]
    var node: [String: Any] = ["StableID": "peer-node", "User": 7, "MachineAuthorized": true,
        "Addresses": ["100.64.0.2/32"], "Expired": false]
    var user: UInt64 = 7
    var commands: [TailnetDeviceAccess.Command] = []
    var beforeRead: ((TailnetDeviceAccess.Command) throws -> Void)?

    func sensor(signatureCheck: TailnetDeviceAccess.Check? = nil,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                observationStarted: TailnetDeviceAccess.Check? = nil,
                diagnosticSink: (@Sendable (String) -> Void)? = nil) -> TailnetDeviceAccess {
        TailnetDeviceAccess(testingRead: { [self] command, check in
            lock.lock(); defer { lock.unlock() }
            try check()
            try beforeRead?(command)
            commands.append(command)
            switch command {
            case .status: return try JSONSerialization.data(withJSONObject: status)
            case .whois: return try JSONSerialization.data(withJSONObject: ["Node": node, "UserProfile": ["ID": user]])
            }
        }, testingSignatureCheck: signatureCheck, testingClock: clock,
           testingObservationStarted: observationStarted, testingDiagnosticSink: diagnosticSink)
    }
}

private final class PolicyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ nanoseconds: UInt64) { lock.lock(); value += nanoseconds; lock.unlock() }
}

/// 모든 signature/spawn은 가짜 이벤트다. 실제 센서나 CLI를 호출하지 않는다.
private final class PolicyFixture: @unchecked Sendable {
    let clock = PolicyClock()
    let data = SensorFixture()
    let lines = DiagnosticLines()
    private let lock = NSLock()
    private var events: [String] = []
    private var signatures = 0
    private var spawns = 0
    var onSignature: ((Int) throws -> Void)?
    var onSpawn: ((Int) throws -> Void)?

    var trace: [String] { lock.lock(); defer { lock.unlock() }; return events }
    var signatureCount: Int { lock.lock(); defer { lock.unlock() }; return signatures }
    var spawnCount: Int { lock.lock(); defer { lock.unlock() }; return spawns }

    func sensor() -> TailnetDeviceAccess {
        data.beforeRead = { [weak self] _ in
            guard let self else { throw TailnetDeviceAccess.Failure.sensorFailure }
            lock.lock(); spawns += 1; let number = spawns; events.append("spawn-\(number)"); lock.unlock()
            try onSpawn?(number)
        }
        let clock = clock, lines = lines
        return data.sensor(signatureCheck: { [self] in
            lock.lock(); signatures += 1; let number = signatures; events.append("signature-\(number)"); lock.unlock()
            try onSignature?(number)
        }, clock: { clock.now() }, observationStarted: { [self] in
            lock.lock(); events.append("observe"); lock.unlock()
        }, diagnosticSink: { lines.append($0) })
    }
}

private final class SignatureChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var events: [String] = []
    let failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        events.append("signature")
        if calls == failAt { throw TailnetDeviceAccess.Failure.sensorFailure }
    }
    func read() { lock.lock(); events.append("read"); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var trace: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class DiagnosticLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

private func waitForSignal(_ signal: DispatchSemaphore, seconds: Double = 1) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: signal.wait(timeout: .now() + seconds) == .success)
        }
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
    var afterRegistryWrite: (() throws -> Void)?
    var beforePairedSave: (() -> Void)?
    var afterPairedSave: (() throws -> Void)?
    var beforeRegistrySave: (() throws -> Void)?
    var registryWrites = 0
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
        try afterPairedSave?()
    }
    func loadOwnerRegistry() throws -> Data? {
        if readRegistryFailure { throw IdentityStoreError("검사 읽기 실패") }
        if registryMissing { return nil }
        return try memory.loadOwnerRegistry()
    }
    func saveOwnerRegistry(_ record: Data) throws {
        registryWrites += 1
        try beforeRegistrySave?()
        if registryFailure { throw IdentityStoreError("검사 원장 저장 실패") }
        if !registryDrops { try memory.saveOwnerRegistry(record) }
        try afterRegistryWrite?()
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

    func testMachineAuthorizationEvidenceAndDiagnostics() async {
        let cases: [(Any?, TailnetDeviceAccess.Failure?, String?)] = [
            (nil, .machineAuthorizationUnavailable, "[TailnetDeviceAccess] stage=whois code=machineAuthorizationUnavailable"),
            (false, .unauthorizedNode, "[TailnetDeviceAccess] stage=validation code=unauthorizedNode"),
            (NSNull(), .malformedEvidence, "[TailnetDeviceAccess] stage=whois code=malformedEvidence"),
            ("true", .malformedEvidence, "[TailnetDeviceAccess] stage=whois code=malformedEvidence"),
            (1, .malformedEvidence, "[TailnetDeviceAccess] stage=whois code=malformedEvidence"),
            (0, .malformedEvidence, "[TailnetDeviceAccess] stage=whois code=malformedEvidence"),
            ([Any](), .malformedEvidence, "[TailnetDeviceAccess] stage=whois code=malformedEvidence"),
            ([String: Any](), .malformedEvidence, "[TailnetDeviceAccess] stage=whois code=malformedEvidence"),
            (true, nil, nil)
        ]
        for (value, failure, log) in cases {
            let fixture = SensorFixture()
            fixture.node["MachineAuthorized"] = value
            let lines = DiagnosticLines()
            let sensor = fixture.sensor(diagnosticSink: { lines.append($0) })
            let result = await sensor.principal(for: binding())
            switch result {
            case .failure(let actual): expectEqual(Optional(actual), failure)
            case .success(let proof):
                expectNil(failure)
                expectTrue(sensor.isCurrent(proof))
                expectNotNil(proof.binding)
            }
            let decoded = failure == nil || failure == .unauthorizedNode
            expectEqual(fixture.commands, decoded ? [.status, .whois("100.64.0.2"), .status] : [.status, .whois("100.64.0.2")])
            await sensor.drainDiagnosticsForTesting()
            expectEqual(lines.snapshot, log.map { [$0] } ?? [])
        }
    }

    func testSensorFailureStagesAndConstantLogs() async throws {
        for (index, stage) in [(0, "status-before"), (1, "whois"), (2, "status-after")] {
            for malformed in [false, true] {
                let fixture = SensorFixture()
                var reads = 0
                fixture.beforeRead = { command in
                    defer { reads += 1 }
                    guard reads == index else { return }
                    if malformed {
                        switch command {
                        case .status: fixture.status["BackendState"] = NSNull()
                        case .whois: fixture.node["StableID"] = NSNull()
                        }
                    } else {
                        throw NSError(domain: "private-peer-user-node-pin-key-token-rawJSON", code: 7,
                                      userInfo: [NSLocalizedDescriptionKey: "private-error-description"])
                    }
                }
                let lines = DiagnosticLines()
                let sensor = fixture.sensor(diagnosticSink: { lines.append($0) })
                let result = await sensor.principal(for: binding())
                if case .failure(let failure) = result {
                    expectEqual(failure, malformed ? .malformedEvidence : .sensorFailure)
                } else { fail("실패한 센서에서 proof를 발급했습니다.") }
                expectEqual(reads, index + 1)
                let code = malformed ? "malformedEvidence" : "sensorFailure"
                await sensor.drainDiagnosticsForTesting()
                expectEqual(lines.snapshot,
                            ["[TailnetDeviceAccess] stage=\(stage) code=\(code)"])
            }
        }
        let changed = SensorFixture()
        changed.beforeRead = { command in
            if case .whois = command { changed.status["BackendState"] = "Stopped" }
        }
        let changedLines = DiagnosticLines()
        let changedSensor = changed.sensor(diagnosticSink: { changedLines.append($0) })
        if case .failure(let failure) = await changedSensor.principal(for: binding()) {
            expectEqual(failure, .backendNotRunning)
        } else { fail("중지 상태를 허용했습니다.") }
        await changedSensor.drainDiagnosticsForTesting()
        expectEqual(changedLines.snapshot,
                    ["[TailnetDeviceAccess] stage=status-after code=backendNotRunning"])

        let invalid = SensorFixture()
        let invalidLines = DiagnosticLines()
        let invalidSensor = invalid.sensor(diagnosticSink: { invalidLines.append($0) })
        if case .failure(let failure) = await invalidSensor.principal(for: binding(source: "192.168.1.2")) {
            expectEqual(failure, .invalidSource)
        } else { fail("Tailnet 외 주소에서 proof를 발급했습니다.") }
        expectTrue(invalid.commands.isEmpty)
        await invalidSensor.drainDiagnosticsForTesting()
        expectEqual(invalidLines.snapshot,
                    ["[TailnetDeviceAccess] stage=validation code=invalidSource"])

        let stopped = SensorFixture(), stoppedLines = DiagnosticLines()
        let sensor = stopped.sensor(diagnosticSink: { stoppedLines.append($0) })
        stopped.beforeRead = { _ in
            sensor.stop()
            throw NSError(domain: "private-late-error", code: 1)
        }
        if case .failure(let failure) = await sensor.principal(for: binding()) {
            expectEqual(failure, .stopped)
        } else { fail("중지된 센서에서 proof를 발급했습니다.") }
        await sensor.drainDiagnosticsForTesting()
        expectEqual(stoppedLines.snapshot,
                    ["[TailnetDeviceAccess] stage=status-before code=stopped"])
        let lines = stoppedLines.snapshot
        try await Task.sleep(nanoseconds: 2_050_000_000)
        await sensor.drainDiagnosticsForTesting()
        expectEqual(stoppedLines.snapshot, lines)
    }

    func testBlockedDiagnosticsDoNotDelayCompletionOrCleanup() async {
        for expected in [TailnetDeviceAccess.Failure.sensorFailure, .cancelled, .stopped, .deadlineExceeded] {
            let readStarted = DispatchSemaphore(value: 0), cleaned = DispatchSemaphore(value: 0)
            let sinkStarted = DispatchSemaphore(value: 0), releaseSink = DispatchSemaphore(value: 0)
            let sinkFinished = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
            let controlReturned = DispatchSemaphore(value: 0), lockAvailable = DispatchSemaphore(value: 0)
            let lines = DiagnosticLines()
            let sensor = TailnetDeviceAccess(testingRead: { _, check in
                defer { cleaned.signal() }
                readStarted.signal()
                if expected == .sensorFailure { throw TailnetDeviceAccess.Failure.sensorFailure }
                while true { try check(); Thread.sleep(forTimeInterval: 0.001) }
            }, testingDiagnosticSink: { line in
                lines.append(line)
                sinkStarted.signal()
                _ = releaseSink.wait(timeout: .now() + 10)
                sinkFinished.signal()
            })
            let source = binding()
            let query = Task.detached {
                let result = await sensor.principal(for: source)
                completed.signal()
                return result
            }
            let didStart = await waitForSignal(readStarted)
            expectTrue(didStart)
            DispatchQueue.global(qos: .utility).async {
                if expected == .cancelled { query.cancel() }
                else if expected == .stopped { sensor.stop() }
                controlReturned.signal()
            }
            let didBlock = await waitForSignal(sinkStarted, seconds: 3)
            DispatchQueue.global(qos: .utility).async {
                sensor.stop()
                lockAvailable.signal()
            }
            let didComplete = await waitForSignal(completed)
            let didClean = await waitForSignal(cleaned)
            let didReturn = await waitForSignal(controlReturned)
            let didUnlock = await waitForSignal(lockAvailable)
            expectTrue(didBlock)
            expectTrue(didComplete)
            expectTrue(didClean)
            expectTrue(didReturn)
            expectTrue(didUnlock)
            expectEqual(sinkFinished.wait(timeout: .now()), .timedOut)
            releaseSink.signal()
            let result = await query.value
            if case .failure(let actual) = result { expectEqual(actual, expected) }
            else { fail("진단 정체 중 실패한 조회가 proof를 발급했습니다.") }
            await sensor.drainDiagnosticsForTesting()
            expectEqual(lines.snapshot, ["[TailnetDeviceAccess] stage=status-before code=\(expected.rawValue)"])
        }
    }

    func testCanonicalCLIEnvironmentIsFixed() {
        expectEqual(TailnetDeviceAccess.testingCLIEnvironment,
                    ["PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C", "HOME=" + NSHomeDirectory(), "TERM=dumb"])
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
        expectTrue(host.isPaired(socket.binding.fingerprint))
        let restarted = self.remote(store)
        try await assertRestartRequiresFreshSession(store)
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
        expectTrue(active.trust.snapshot.ownerAuthorized.isEmpty)
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
            expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
        }
    }

    @MainActor func testPartialReservationRecoversWithFreshProof() async throws {
        let store = FaultStore(); store.pairedFailure = true
        let host = remote(store)
        assertClosed(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectTrue(try store.loadPaired().isEmpty)
        expectNotNil(try store.loadOwnerRegistry())
        store.pairedFailure = false
        let restarted = remote(store)
        assertClosed(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding(2)))))
        assertOK(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectEqual(try store.loadPaired().count, 1)
        try await assertRestartRequiresFreshSession(store)
    }

    @MainActor func testPairedReadbackAndRemovalFailures() async throws {
        let dropped = FaultStore(); dropped.pairedDrops = true
        let host = remote(dropped)
        assertClosed(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectTrue(host.trust.snapshot.paired.isEmpty)
        expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
        dropped.pairedDrops = false
        assertOK(await remote(dropped).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        let store = FaultStore(), owner = remote(store), fp = Base64URL.encode(binding().fingerprint)
        assertOK(await owner.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        store.registryFailure = true
        expectNotNil(owner.remove(fingerprint: fp))
        expectEqual(try store.loadPaired().count, 1)
        try await assertRestartRequiresFreshSession(store)
        store.registryFailure = false; store.pairedFailure = true
        expectNotNil(owner.remove(fingerprint: fp))
        expectEqual(try store.loadPaired().count, 1)
        expectTrue(owner.trust.snapshot.paired.isEmpty)
        expectTrue(owner.trust.snapshot.ownerAuthorized.isEmpty)
        expectTrue(remote(store).trust.snapshot.paired.isEmpty)
        expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
        store.pairedFailure = false
        let restarted = remote(store)
        assertClosed(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectNil(restarted.remove(fingerprint: fp))
        expectTrue(try store.loadPaired().isEmpty)
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
        expectTrue(damaged.trust.snapshot.ownerAuthorized.isEmpty)
        assertClosed(await damaged.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        try store.memory.saveOwnerRegistry(original)
        try await assertRestartRequiresFreshSession(store)
        store.readRegistryFailure = true
        expectTrue(remote(store).trust.snapshot.paired.isEmpty)
        expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
    }

    @MainActor func testExplicitPairingRemainsIndependentOfAutomaticRevocation() async throws {
        let store = FaultStore()
        let host = remote(store)
        assertOK(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        let fp = Base64URL.encode(binding().fingerprint)
        expectNil(host.remove(fingerprint: fp))
        try store.savePaired([PairedDevice(fingerprint: fp, name: "명시적 허용", model: nil, pairedAt: 1, method: PairRequest.code)])
        let restarted = remote(store)
        expectEqual(remote(store).trust.snapshot.paired.count, 1)
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
        expectTrue(missing.trust.snapshot.ownerAuthorized.isEmpty)
        assertClosed(await missing.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        store.registryMissing = false
        let foreign = FaultStore()
        try foreign.saveOwnerRegistry(record)
        assertClosed(await remote(foreign).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
    }

    func testPublicProfileUsesSingleStatusWithoutApprovalOrKeys() async {
        for approval: Any? in [nil, false, NSNull(), "true", true] {
            let fixture = SensorFixture()
            fixture.node["MachineAuthorized"] = approval
            fixture.node["StableID"] = "private-peer"
            fixture.beforeRead = { command in
                if case .whois = command { throw TailnetDeviceAccess.Failure.sensorFailure }
            }
            fixture.status["Self"] = ["ID": "host-node", "UserID": 7,
                "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0:0:0:0:0:1"], "Expired": false]
            let sensor = fixture.sensor()
            guard case .success(let profile) = await sensor.publicProfile() else {
                fail("공개 관측이 권한 증거를 요구했습니다."); continue
            }
            expectEqual(fixture.commands, [.status])
            expectEqual(profile.nodeID, "host-node")
            expectEqual(profile.userID, 7)
            expectEqual(profile.localIPs, ["100.64.0.1", "fd7a:115c:a1e0::1"])
            expectTrue(sensor.isCurrent(profile))
            expectFalse(sensor.independent().isCurrent(profile))
            let fields = Set(Mirror(reflecting: profile).children.compactMap(\.label))
            expectEqual(fields, Set(["nodeID", "userID", "localIPs", "issuer", "deadline"]))
        }
    }

    func testPublicAndProofSignedReadContracts() async {
        for publicOnly in [true, false] {
            let checks = publicOnly ? 2 : 6
            for failAt in [nil] + (1...checks).map(Optional.some) {
                let signatures = SignatureChecks(failAt: failAt), fixture = SensorFixture()
                fixture.beforeRead = { _ in signatures.read() }
                let sensor = fixture.sensor(signatureCheck: { try signatures.validate() })
                if publicOnly {
                    switch await sensor.publicProfile() {
                    case .success: expectNil(failAt)
                    case .failure(let failure): expectNotNil(failAt); expectEqual(failure, .sensorFailure)
                    }
                } else {
                    switch await sensor.principal(for: binding()) {
                    case .success: expectNil(failAt)
                    case .failure(let failure): expectNotNil(failAt); expectEqual(failure, .sensorFailure)
                    }
                }
                expectEqual(signatures.count, failAt ?? checks)
                let commands: [TailnetDeviceAccess.Command] = publicOnly ? [.status] : [.status, .whois("100.64.0.2"), .status]
                expectEqual(fixture.commands, Array(commands.prefix(failAt.map { $0 / 2 } ?? commands.count)))
                let trace = commands.flatMap { _ in ["signature", "read", "signature"] }
                expectEqual(signatures.trace, Array(trace.prefix(failAt.map { $0 + $0 / 2 } ?? trace.count)))
            }
        }
    }

    func testCandidatePreparationAndObservationDeadline() async {
        // 별도 정책 후보의 양성 대조이며 기존 request 전체 2초와의 동등성 증거가 아니다.
        for preparation: UInt64 in [5_072_580_000, 7_999_000_000] {
            let fixture = PolicyFixture(), started = fixture.clock.now()
            fixture.onSignature = { [clock = fixture.clock] number in
                clock.advance(number == 1 ? preparation : 100_000_000)
            }
            fixture.onSpawn = { [clock = fixture.clock] _ in clock.advance(400_000_000) }
            let sensor = fixture.sensor()
            guard case .success(let proof) = await sensor.principal(for: binding()) else {
                fail("준비 후 짧은 관측을 거부했습니다."); continue
            }
            expectEqual(fixture.trace, ["signature-1", "observe", "spawn-1", "signature-2",
                "signature-3", "spawn-2", "signature-4", "signature-5", "spawn-3", "signature-6"])
            expectEqual(fixture.signatureCount, 6)
            expectEqual(fixture.spawnCount, 3)
            expectEqual(fixture.clock.now() - started, preparation + 1_700_000_000)
            expectTrue(proof.isUnexpired)
            // 발급 당시 남은 0.3초만 유지한다. 발급으로 2초를 다시 주지 않는다.
            fixture.clock.advance(299_999_999)
            expectTrue(sensor.withCurrent(proof) { true })
            fixture.clock.advance(1)
            expectFalse(proof.isUnexpired)
            var used = false
            expectFalse(sensor.withCurrent(proof) { used = true; return true })
            expectFalse(used)
            expectFalse(sensor.independent().isCurrent(proof))
        }
    }

    func testCandidateSignatureFailuresAndCumulativeBudget() async {
        for failAt in 1...6 {
            let fixture = PolicyFixture()
            fixture.onSignature = { number in
                if number == failAt { throw TailnetDeviceAccess.Failure.sensorFailure }
            }
            let sensor = fixture.sensor()
            if case .failure(let failure) = await sensor.principal(for: binding()) { expectEqual(failure, .sensorFailure) }
            else { fail("서명 실패 후 proof를 발급했습니다.") }
            expectEqual(fixture.signatureCount, failAt)
            expectEqual(fixture.spawnCount, failAt / 2)
        }
        for delayed in 1...6 {
            let fixture = PolicyFixture()
            fixture.onSignature = { [clock = fixture.clock] number in
                if number == delayed { clock.advance(number == 1 ? 8_000_000_000 : 2_000_000_000) }
            }
            let sensor = fixture.sensor()
            if case .failure(let failure) = await sensor.principal(for: binding()) { expectEqual(failure, .deadlineExceeded) }
            else { fail("서명 지연으로 만료된 proof를 발급했습니다.") }
            expectEqual(fixture.signatureCount, delayed)
            expectEqual(fixture.spawnCount, delayed / 2)
        }
        for perRead: UInt64 in [666_666_667, 800_000_000] {
            let fixture = PolicyFixture()
            fixture.onSpawn = { [clock = fixture.clock] _ in clock.advance(perRead) }
            let sensor = fixture.sensor()
            if case .failure(let failure) = await sensor.principal(for: binding()) { expectEqual(failure, .deadlineExceeded) }
            else { fail("개별 read가 짧아도 누적 2초 만료를 거부해야 합니다.") }
            expectEqual(fixture.spawnCount, 3)
        }
    }

    func testCandidateRequiresSingleStartMarker() async {
        for markers in 0...2 {
            let fixture = SensorFixture(), clock = PolicyClock()
            let sensor = TailnetDeviceAccess(testingVerifiedRead: { command, check, started in
                for _ in 0..<markers { try? started?() } // 오류를 삼켜도 이중 arm은 종결되어야 한다.
                try check()
                switch command {
                case .status: return try JSONSerialization.data(withJSONObject: fixture.status)
                case .whois: return try JSONSerialization.data(withJSONObject: ["Node": fixture.node, "UserProfile": ["ID": 7]])
                }
            }, testingClock: { clock.now() })
            switch await sensor.principal(for: binding()) {
            case .success: expectEqual(markers, 1)
            case .failure(let failure): expectTrue(markers != 1); expectEqual(failure, .malformedEvidence)
            }
        }
    }

    func testCandidateLateSignaturesCannotReviveFinishedAttempt() async {
        for signature in [1, 2, 6] {
            for terminal in [TailnetDeviceAccess.Failure.cancelled, .stopped, .deadlineExceeded] {
                let fixture = PolicyFixture(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                fixture.onSignature = { number in
                    if number == signature {
                        entered.signal()
                        _ = release.wait(timeout: .now() + 5)
                    }
                }
                let sensor = fixture.sensor(), source = binding()
                let query = Task.detached { await sensor.principal(for: source) }
                let didEnter = await waitForSignal(entered)
                expectTrue(didEnter)
                // 서명이 막혀 있는 동안 busy/cancel/stop/만료가 즉시 종결되어야 한다.
                if case .failure(let failure) = await sensor.principal(for: source) { expectEqual(failure, .busy) }
                else { fail("대기 서명 중 두 번째 관측을 허용했습니다.") }
                let before = fixture.spawnCount
                if terminal == .cancelled { query.cancel() }
                if terminal == .stopped { sensor.stop() }
                if terminal == .deadlineExceeded {
                    fixture.clock.advance(signature == 1 ? 8_000_000_000 : 2_000_000_000)
                    sensor.expireForTesting()
                }
                if case .failure(let failure) = await query.value { expectEqual(failure, terminal) }
                else { fail("늦은 서명 전에 proof를 발급했습니다.") }
                release.signal()
                await sensor.drainDiagnosticsForTesting()
                expectEqual(fixture.spawnCount, before)
                expectEqual(fixture.signatureCount, signature)
                expectEqual(fixture.lines.snapshot.count, 2) // busy와 원래 요청의 종결, 각각 한 번.
                expectEqual(fixture.lines.snapshot.filter { $0.hasSuffix("code=\(terminal.rawValue)") }.count, 1)
            }
        }
    }

    func testCandidatePublicProfileRetainsTenSecondSingleStatus() async {
        for duration: UInt64 in [9_999_999_999, 10_000_000_000] {
            let fixture = PolicyFixture()
            fixture.onSignature = { [clock = fixture.clock] number in if number == 1 { clock.advance(duration) } }
            let sensor = fixture.sensor()
            switch await sensor.publicProfile() {
            case .success(let profile):
                expectTrue(duration < 10_000_000_000)
                expectEqual(fixture.trace, ["signature-1", "spawn-1", "signature-2"])
                expectEqual(fixture.data.commands, [.status])
                expectTrue(sensor.isCurrent(profile))
                fixture.clock.advance(1)
                expectFalse(sensor.isCurrent(profile))
            case .failure(let failure):
                expectEqual(duration, 10_000_000_000)
                expectEqual(failure, .deadlineExceeded)
                expectEqual(fixture.spawnCount, 0)
            }
        }
    }

    @MainActor func testCandidateDeadlineAtFinalSocketAdmission() async throws {
        for mode in 0...4 {
            let (_, host) = try await sessionHost(), fixture = PolicyFixture(), live = LiveFlag()
            let b = binding()
            let socket = OwnerBootstrapSocket.fixture(binding: b, trust: host.trust, purpose: .session) { live.get() }
            fixture.onSignature = { [clock = fixture.clock] number in
                if number == 1 { clock.advance(5_072_580_000) }
            }
            fixture.onSpawn = { [clock = fixture.clock] _ in clock.advance(500_000_000) }
            let sensor = fixture.sensor()
            guard case .success(let proof) = await sensor.principal(for: b) else { return fail("최종 사용 검사 proof 발급 실패") }
            let evidence = OwnerBootstrapSocket.Evidence(sensor: sensor, proof: proof)
            if mode == 1 { fixture.clock.advance(500_000_000) }
            if mode == 3 { host.trust.update { $0.ownerBootstrapEpoch = UUID(); $0.ownerAuthorized = [:] } }
            if mode == 4 { live.set(false) }
            var served = 0
            let accepted = socket.admit(in: host.trust, evidence: evidence, allowed: { _ in
                if mode == 2 { fixture.clock.advance(500_000_000) }
                return true
            }) { _ in served += 1 }
            expectEqual(accepted, mode == 0)
            expectEqual(served, mode == 0 ? 1 : 0)
            expectEqual(host.trust.snapshot.isPaired(b.fingerprint), mode == 0)
        }
    }

    func testPublicObservationCanTakeMoreThanProofDeadline() async {
        for publicOnly in [true, false] {
            let fixture = SensorFixture()
            fixture.beforeRead = { _ in Thread.sleep(forTimeInterval: 2.05) }
            let sensor = fixture.sensor()
            if publicOnly {
                if case .success = await sensor.publicProfile() { expectEqual(fixture.commands, [.status]) }
                else { fail("공개 관측에 권한 증명의 2초 기한을 적용했습니다.") }
            } else {
                if case .failure(let failure) = await sensor.principal(for: binding()) { expectEqual(failure, .deadlineExceeded) }
                else { fail("권한 증명의 2초 기한을 늘렸습니다.") }
            }
            await sensor.drainDiagnosticsForTesting()
        }
    }

    func testPublicProfileRejectsInvalidSelfAndOutput() async {
        let cases: [([String: Any], TailnetDeviceAccess.Failure)] = [
            (["ID": ""], .malformedEvidence), (["ID": "bad id"], .malformedEvidence),
            (["ID": String(repeating: "a", count: 257)], .malformedEvidence),
            (["UserID": 0], .malformedEvidence), (["UserID": "7"], .malformedEvidence),
            (["TailscaleIPs": []], .malformedEvidence),
            (["TailscaleIPs": ["192.168.1.2"]], .malformedEvidence),
            (["TailscaleIPs": ["100.64.0.1", "100.64.0.1"]], .malformedEvidence),
            (["TailscaleIPs": ["fd7a:115c:a1e0::1", "fd7a:115c:a1e0:0:0:0:0:1"]], .malformedEvidence),
            (["TailscaleIPs": ["100.64.0.1%utun9"]], .malformedEvidence),
            (["Expired": true], .expiredNode), (["Expired": "false"], .malformedEvidence),
            (["Tags": ["tag:server"]], .unauthorizedNode), (["ShareeNode": true], .unauthorizedNode)
        ]
        for (changes, expected) in cases {
            let fixture = SensorFixture()
            var node = fixture.status["Self"] as! [String: Any]
            node.merge(changes) { _, new in new }
            fixture.status["Self"] = node
            if case .failure(let failure) = await fixture.sensor().publicProfile() { expectEqual(failure, expected) }
            else { fail("잘못된 Self를 허용했습니다.") }
            expectEqual(fixture.commands, [.status])
        }
        for selfNode: Any in [NSNull(), [], "host"] {
            let fixture = SensorFixture(); fixture.status["Self"] = selfNode
            if case .success = await fixture.sensor().publicProfile() { fail("잘못된 Self를 허용했습니다.") }
        }
        let fixture = SensorFixture(); fixture.status["BackendState"] = "Stopped"
        if case .failure(let failure) = await fixture.sensor().publicProfile() { expectEqual(failure, .backendNotRunning) }
        else { fail("중지 상태의 공개 프로필을 발급했습니다.") }
        let sensor = TailnetDeviceAccess(testingRead: { _, _ in Data(repeating: 32, count: TailnetDeviceAccess.outputLimit + 1) })
        if case .failure(let failure) = await sensor.publicProfile() { expectEqual(failure, .outputLimit) }
        else { fail("공개 관측의 출력 한도를 우회했습니다.") }
    }

    func testPublicProfileStopCancellationBusyAndDeadline() async {
        for expected in [TailnetDeviceAccess.Failure.stopped, .cancelled, .deadlineExceeded] {
            let entered = DispatchSemaphore(value: 0), cleaned = DispatchSemaphore(value: 0)
            let sensor = TailnetDeviceAccess(testingRead: { command, check in
                guard command == .status else { throw TailnetDeviceAccess.Failure.sensorFailure }
                defer { cleaned.signal() }
                entered.signal()
                while true { try check(); Thread.sleep(forTimeInterval: 0.001) }
            })
            let query = Task.detached { await sensor.publicProfile() }
            let started = await waitForSignal(entered)
            expectTrue(started)
            if case .failure(let failure) = await sensor.publicProfile() { expectEqual(failure, .busy) }
            else { fail("동시 공개 조회를 허용했습니다.") }
            if case .failure(let failure) = await sensor.principal(for: binding()) { expectEqual(failure, .busy) }
            else { fail("공개 조회 중 권한 조회를 중복 실행했습니다.") }
            if expected == .stopped { sensor.stop() }
            if expected == .cancelled { query.cancel() }
            if case .failure(let failure) = await query.value { expectEqual(failure, expected) }
            else { fail("중지·취소·기한 이후 공개 결과를 발급했습니다.") }
            let didClean = await waitForSignal(cleaned)
            expectTrue(didClean)
            await sensor.drainDiagnosticsForTesting()
        }
    }

    func testPublicProfileFactoryAndMonotonicExpiryAreSeparateFromProof() async throws {
        let fixture = SensorFixture(), sensor = fixture.sensor()
        let started = DispatchTime.now().uptimeNanoseconds
        guard case .success(let observation) = await sensor.publicProfile() else { return fail("자기 노드 관측 실패") }
        let store = MemoryIdentityStore()
        let identity = try require(HostIdentity(privateKey: store.loadOrCreateKey(), recognitionKey: store.loadOrCreateRecognitionKey()))
        let profile = try require(identity.ownerMacBootstrap(sensor: sensor, profile: observation, remotePort: 7455))
        expectEqual(profile.fingerprintData, identity.fingerprint)
        expectEqual(profile.macID, identity.macID)
        expectEqual(profile.addresses, ["100.64.0.1"])
        let data = try JSONEncoder().encode(profile)
        let fields = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        expectEqual(Set(fields.keys), Set(["schema", "macID", "fingerprint", "addresses", "remotePort"]))
        expectNil(identity.ownerMacBootstrap(sensor: sensor.independent(), profile: observation, remotePort: 7455))
        let peerSensor = SensorFixture().sensor()
        guard case .success(let peerProof) = await peerSensor.principal(for: binding()) else { return fail("기기 proof 발급 실패") }
        expectTrue(peerProof.validUntil.timeIntervalSinceNow <= 2)
        try await Task.sleep(nanoseconds: 2_050_000_000)
        expectFalse(peerSensor.isCurrent(peerProof))
        expectTrue(sensor.isCurrent(observation))
        let expires = started + 10_050_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        if now < expires { try await Task.sleep(nanoseconds: expires - now) }
        expectFalse(sensor.isCurrent(observation))
        expectNil(identity.ownerMacBootstrap(sensor: sensor, profile: observation, remotePort: 7455))
        let stopped = fixture.sensor()
        guard case .success(let fresh) = await stopped.publicProfile() else { return fail("중지 검사 관측 실패") }
        stopped.stop()
        expectFalse(stopped.isCurrent(fresh))
        expectNil(identity.ownerMacBootstrap(sensor: stopped, profile: fresh, remotePort: 7455))
        if case .failure(let failure) = await stopped.publicProfile() { expectEqual(failure, .stopped) }
        else { fail("중지된 센서가 공개 관측을 발급했습니다.") }
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
        expectNil(host.remove(fingerprint: legacy.fingerprint))
        expectTrue(try store.loadPaired().isEmpty)
        expectTrue(host.trust.snapshot.paired.isEmpty)
        expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
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

    @MainActor func testExistingPairingRecoversWithoutChangingMetadata() async throws {
        for method in [PairRequest.qr, PairRequest.code, PairResult.cable, "icloud"] {
            let store = FaultStore(), key = binding().fingerprint
            let original = PairedDevice(fingerprint: Base64URL.encode(key), name: "기존 이름", model: "기존 모델",
                pairedAt: 123, method: method, cableDevice: "기존 케이블 식별자")
            try store.savePaired([original])
            let host = remote(store)
            let result = await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding())))
            assertOK(result)
            expectEqual(result.method, OwnerMacBootstrap.method)
            expectNotNil(result.recognitionKey)
            expectEqual(try store.loadPaired(), [original])
            expectTrue(host.isPaired(binding().fingerprint))
            assertOK(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            expectEqual(try store.loadPaired(), [original])
        }
    }

    @MainActor func testPairedWriteInvalidationNeverActivatesAfterRestart() async throws {
        for expired in [false, true] {
            let store = FaultStore(), live = LiveFlag(), host = remote(store)
            let socket = OwnerBootstrapSocket.fixture(binding: binding()) { live.get() }
            store.beforePairedSave = {
                if expired { Thread.sleep(forTimeInterval: 2.10) }
                else { live.set(false) }
            }
            assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
            expectTrue(host.trust.snapshot.paired.isEmpty)
            expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
            let restarted = remote(store)
            expectTrue(restarted.trust.snapshot.paired.isEmpty)
            expectTrue(restarted.trust.snapshot.ownerAuthorized.isEmpty)
            store.beforePairedSave = nil
            assertOK(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            expectEqual(try store.loadPaired().count, 1)
            try await assertRestartRequiresFreshSession(store)
        }
    }

    @MainActor func testWriteThenFailureRecoversAndPreservesMetadata() async throws {
        let store = FaultStore(), host = remote(store)
        store.afterPairedSave = { throw IdentityStoreError("저장 직후 중단") }
        assertClosed(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        var partial = try store.loadPaired()
        expectEqual(partial.count, 1)
        expectTrue(host.trust.snapshot.paired.isEmpty)
        expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
        store.afterPairedSave = nil
        let restarted = remote(store)
        expectTrue(restarted.trust.snapshot.paired.isEmpty)
        expectTrue(restarted.trust.snapshot.ownerAuthorized.isEmpty)
        assertOK(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        partial[0].ownerActivationPending = nil
        expectEqual(try store.loadPaired(), partial)
        let writes = store.writes, registryWrites = store.registryWrites
        assertOK(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectEqual(store.writes, writes)
        expectEqual(store.registryWrites, registryWrites)
    }

    @MainActor func testCancellationDuringPairedWrite() async throws {
        for cancelTask in [false, true] {
            let store = FaultStore(), host = remote(store)
            let socket = OwnerBootstrapSocket.fixture(binding: binding())
            let result = await Task { @MainActor in
                store.beforePairedSave = {
                    if cancelTask { withUnsafeCurrentTask { $0?.cancel() } }
                    else { socket.cancel() }
                }
                return await host.judgeOwnerBootstrap(self.attempt(socket))
            }.value
            assertClosed(result)
            expectTrue(host.trust.snapshot.paired.isEmpty)
            expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
            expectTrue(remote(store).trust.snapshot.paired.isEmpty)
            expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
            store.beforePairedSave = nil
            assertOK(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        }
    }

    @MainActor func testPendingNeverAcceptsDifferentNodeOrKey() async throws {
        let store = FaultStore(); store.pairedFailure = true
        assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        store.pairedFailure = false
        let changed = SensorFixture(); changed.node["StableID"] = "other-node"
        assertClosed(await remote(store, fixture: changed).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding(2)))))
        assertOK(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        let other = SensorFixture(); other.node["StableID"] = "other-node"
        assertClosed(await remote(store, fixture: other).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
    }

    @MainActor func testActivationAndRemovalInterruptionPoints() async throws {
        for afterWrite in [false, true] {
            let store = FaultStore(), host = remote(store)
            if afterWrite {
                store.afterRegistrySave = { if store.registryWrites == 1 { store.registryFailure = true } }
            } else {
                store.beforeRegistrySave = { if store.registryWrites == 2 { throw IdentityStoreError("활성 저장 직전 중단") } }
            }
            assertClosed(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            expectTrue(remote(store).trust.snapshot.paired.isEmpty)
            expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
            store.afterRegistrySave = nil; store.beforeRegistrySave = nil; store.registryFailure = false
            assertOK(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            let fp = Base64URL.encode(binding().fingerprint)
            store.afterPairedSave = { throw IdentityStoreError("제거 저장 직후 중단") }
            expectNotNil(remote(store).remove(fingerprint: fp))
            store.afterPairedSave = nil
            expectTrue(try store.loadPaired().isEmpty)
            expectTrue(remote(store).trust.snapshot.paired.isEmpty)
            expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
            assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        }
    }

    @MainActor func testLegacyRemovalTombstoneBlocksRecovery() async throws {
        let store = FaultStore(), fp = Base64URL.encode(binding().fingerprint)
        try store.savePaired([PairedDevice(fingerprint: fp, name: "기존 기기", model: nil, pairedAt: 1, method: PairRequest.qr)])
        expectNil(remote(store).remove(fingerprint: fp))
        assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        try store.savePaired([PairedDevice(fingerprint: fp, name: "다시 명시적으로 허용", model: nil, pairedAt: 2, method: PairRequest.code)])
        expectEqual(remote(store).trust.snapshot.paired.count, 1)
        assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
    }

    private func signedRegistry(_ store: FaultStore, schema: Int, bindings: [[String: Any]]) throws {
        let identity = try require(HostIdentity(privateKey: store.loadOrCreateKey(), recognitionKey: store.loadOrCreateRecognitionKey()))
        let payload = try JSONSerialization.data(withJSONObject: ["schema": schema, "macID": identity.macID, "bindings": bindings], options: .sortedKeys)
        let signature = try require(identity.signRecord(Data("sill-owner-registry-v1\n".utf8) + payload))
        try store.memory.saveOwnerRegistry(JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": signature.base64EncodedString()]))
    }

    @MainActor func testRegistrySchemaCompatibilityAndCorruption() async throws {
        let principal = OwnerBootstrapRegistry.principal(user: 7, node: "peer-node")
        let fp = Base64URL.encode(binding().fingerprint)
        let original = PairedDevice(fingerprint: fp, name: "v1 기기", model: "보존", pairedAt: 12,
            method: OwnerMacBootstrap.method, cableDevice: "v1 케이블", ownerPrincipal: principal)
        for revoked in [false, true] {
            for missing in [false, true] {
                let store = FaultStore()
                if !missing { try store.savePaired([original]) }
                try signedRegistry(store, schema: 1, bindings: [["principal": principal, "fingerprint": fp, "revoked": revoked]])
                let host = remote(store)
                let result = await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding())))
                expectEqual(result.ok, !revoked && !missing)
                expectEqual(host.isPaired(binding().fingerprint), !revoked && !missing)
                expectEqual(try store.loadPaired(), missing ? [] : [original])
            }
        }
        for rows: [[String: Any]] in [
            [["principal": principal, "fingerprint": fp, "state": "unknown"]],
            [["fingerprint": fp, "state": "pending"]],
            [["principal": principal, "fingerprint": fp, "state": "active"], ["principal": principal, "fingerprint": fp, "state": "pending"]]
        ] {
            let store = FaultStore()
            try store.savePaired([original])
            try signedRegistry(store, schema: 2, bindings: rows)
            expectTrue(remote(store).trust.snapshot.paired.isEmpty)
            expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
            assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        }
        let future = FaultStore()
        try signedRegistry(future, schema: 99, bindings: [])
        assertClosed(await remote(future).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
    }

    @MainActor func testPendingWithoutPairedCanBeRevoked() async throws {
        let store = FaultStore(); store.pairedFailure = true
        let host = remote(store), fp = Base64URL.encode(binding().fingerprint)
        assertClosed(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectTrue(try store.loadPaired().isEmpty)
        expectNil(host.remove(fingerprint: fp))
        store.pairedFailure = false; store.registryFailure = true
        expectNil(remote(store).remove(fingerprint: fp))
        store.registryFailure = false
        for key: UInt8 in [1, 2] {
            assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding(key)))))
        }
    }

    @MainActor func testActivationWriteInvalidationRemainsPending() async throws {
        for expire in [false, true] {
            let store = FaultStore(), live = LiveFlag(), host = remote(store)
            store.afterRegistrySave = {
                if store.registryWrites == 2 {
                    if expire { Thread.sleep(forTimeInterval: 2.10) }
                    else { live.set(false) }
                }
            }
            let socket = OwnerBootstrapSocket.fixture(binding: binding()) { live.get() }
            assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
            expectTrue(host.trust.snapshot.paired.isEmpty)
            expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
            expectTrue(remote(store).trust.snapshot.paired.isEmpty)
            expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
            var before = try store.loadPaired()
            store.afterRegistrySave = nil
            assertOK(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            before[0].ownerActivationPending = nil
            expectEqual(try store.loadPaired(), before)
        }
    }

    @MainActor func testDurableTombstoneReadbackFailureNeverRestoresTrust() async throws {
        let store = FaultStore(), host = remote(store), fp = Base64URL.encode(binding().fingerprint)
        assertOK(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        store.afterRegistrySave = { store.readRegistryFailure = true }
        expectNotNil(host.remove(fingerprint: fp))
        expectTrue(host.trust.snapshot.paired.isEmpty)
        expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
        store.afterRegistrySave = nil; store.readRegistryFailure = false
        let restarted = remote(store)
        expectTrue(restarted.trust.snapshot.paired.isEmpty)
        expectTrue(restarted.trust.snapshot.ownerAuthorized.isEmpty)
        assertClosed(await restarted.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        expectNil(restarted.remove(fingerprint: fp))
        expectTrue(try store.loadPaired().isEmpty)
    }

    @MainActor func testV1MigrationPreservesExistingBinding() async throws {
        let store = FaultStore(), principal = OwnerBootstrapRegistry.principal(user: 7, node: "peer-node")
        let original = PairedDevice(fingerprint: Base64URL.encode(binding().fingerprint), name: "이전 등록", model: nil,
            pairedAt: 1, method: OwnerMacBootstrap.method, ownerPrincipal: principal)
        try store.savePaired([original])
        try signedRegistry(store, schema: 1, bindings: [["principal": principal, "fingerprint": original.fingerprint, "revoked": false]])
        let other = SensorFixture(); other.node["StableID"] = "second-node"
        assertOK(await remote(store, fixture: other).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding(2)))))
        expectEqual(try store.loadPaired().first, original)
        let record = try require(JSONSerialization.jsonObject(with: store.loadOwnerRegistry()!) as? [String: Any])
        let payload = try require(Data(base64Encoded: record["payload"] as! String))
        let fields = try require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        expectEqual(fields["schema"] as? Int, 3)
        try await assertRestartRequiresFreshSession(store, ownerCount: 2)
        assertOK(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
    }

    @MainActor func testActiveWriteFailureAndFailedCompensationNeverGrantsTrust() async throws {
        for loseCurrent in [false, true] {
            for bothStoresFail in [false, true] {
                let store = FaultStore(), live = LiveFlag(), host = remote(store)
                store.afterRegistryWrite = {
                    if store.registryWrites == 2 {
                        store.registryFailure = true
                        store.pairedFailure = bothStoresFail
                        if loseCurrent { live.set(false) }
                        else { throw IdentityStoreError("active 저장 직후 실패") }
                    }
                }
                let socket = OwnerBootstrapSocket.fixture(binding: binding()) { live.get() }
                assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
                expectTrue(host.trust.snapshot.paired.isEmpty)
                expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
                expectTrue(remote(store).trust.snapshot.paired.isEmpty)
                expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
                store.afterRegistryWrite = nil; store.registryFailure = false; store.pairedFailure = false
                assertOK(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
                try await assertRestartRequiresFreshSession(store)
            }
        }
    }

    @MainActor func testRecoveredLegacyPairingRemovalPreservesRevocation() async throws {
        for method in [PairRequest.qr, PairRequest.code, PairResult.cable, "icloud"] {
            let store = FaultStore(), fp = Base64URL.encode(binding().fingerprint)
            let original = PairedDevice(fingerprint: fp, name: "기존 사용자 이름", model: "기존 모델", pairedAt: 3,
                method: method, cableDevice: "원래 케이블")
            try store.savePaired([original])
            let host = remote(store)
            assertOK(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            expectEqual(try store.loadPaired(), [original])
            store.pairedFailure = true
            expectEqual(host.remove(fingerprint: fp), "자동 등록 철회는 저장했지만 기존 기기 등록 제거를 확인하지 못했습니다. 제거를 다시 시도하세요.")
            expectTrue(host.isPaired(binding().fingerprint))
            expectEqual(try store.loadPaired(), [original])
            assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            store.pairedFailure = false
            expectNil(remote(store).remove(fingerprint: fp))
            expectTrue(try store.loadPaired().isEmpty)
            expectTrue(remote(store).trust.snapshot.paired.isEmpty)
            expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
            assertClosed(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
        }
    }

    @MainActor func testFinalCompletionFailuresDoNotPublishTrust() async throws {
        for mode in 0...4 {
            let store = FaultStore(), live = LiveFlag(), host = remote(store)
            store.beforePairedSave = {
                if store.writes == 1 {
                    if mode == 1 { Thread.sleep(forTimeInterval: 2.10) }
                    else if mode == 3 { store.pairedDrops = true }
                    else if mode != 2 { live.set(false) }
                    if mode == 4 { store.registryFailure = true }
                }
            }
            store.afterPairedSave = {
                if mode == 2 && store.writes == 2 {
                    store.pairedFailure = true
                    throw IdentityStoreError("완료 표시 저장 직후 실패")
                }
            }
            let socket = OwnerBootstrapSocket.fixture(binding: binding()) { live.get() }
            assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
            expectTrue(host.trust.snapshot.paired.isEmpty)
            expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
            expectTrue(remote(store).trust.snapshot.paired.isEmpty)
            expectTrue(remote(store).trust.snapshot.ownerAuthorized.isEmpty)
            store.beforePairedSave = nil; store.afterPairedSave = nil
            store.pairedDrops = false; store.pairedFailure = false; store.registryFailure = false
            assertOK(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            try await assertRestartRequiresFreshSession(store)
        }
    }

    @MainActor func testCommittedTrustSurvivesSocketDisconnection() async throws {
        let store = FaultStore(), host = remote(store), socket = OwnerBootstrapSocket.fixture(binding: binding())
        assertOK(await host.judgeOwnerBootstrap(attempt(socket)))
        let committed = try store.loadPaired()
        expectNil(committed.first?.ownerActivationPending)
        socket.cancel()
        expectTrue(host.isPaired(binding().fingerprint))
        try await assertRestartRequiresFreshSession(store)
        assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
        expectEqual(try store.loadPaired(), committed)
        expectTrue(host.isPaired(binding().fingerprint))
    }

    @MainActor func testV2PairingCompatibility() async throws {
        for state in ["pending", "active"] {
            let store = FaultStore(), principal = OwnerBootstrapRegistry.principal(user: 7, node: "peer-node")
            let original = PairedDevice(fingerprint: Base64URL.encode(binding().fingerprint), name: "v2 등록", model: "기존 모델",
                pairedAt: 2, method: OwnerMacBootstrap.method, cableDevice: "v2 케이블", ownerPrincipal: principal)
            try store.savePaired([original])
            try signedRegistry(store, schema: 2, bindings: [["principal": principal, "fingerprint": original.fingerprint, "state": state]])
            expectEqual(remote(store).trust.snapshot.ownerCandidates.count, state == "active" ? 1 : 0)
            assertOK(await remote(store).judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding()))))
            expectEqual(try store.loadPaired(), [original])
            try await assertRestartRequiresFreshSession(store)
        }
    }

    @MainActor func testTotalStorageOutageRequiresFreshSessionAfterRestart() async throws {
        let store = FaultStore(), live = LiveFlag(), host = remote(store)
        store.afterPairedSave = {
            if store.writes == 2 {
                store.registryFailure = true; store.pairedFailure = true; live.set(false)
            }
        }
        let socket = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust) { live.get() }
        let result = await host.judgeOwnerBootstrap(attempt(socket))
        let restarted = remote(store)
        expectFalse(result.ok)
        expectFalse(host.isPaired(socket.binding.fingerprint))
        expectFalse(restarted.isPaired(socket.binding.fingerprint))
        expectEqual(restarted.trust.snapshot.ownerCandidates.count, 1)
        let writes = store.writes, registryWrites = store.registryWrites
        try await assertRestartRequiresFreshSession(store)
        expectEqual(store.writes, writes)
        expectEqual(store.registryWrites, registryWrites)
        print("전체 저장 실패 반례: bootstrap=false, 현재 권한=0, 재시작 권한=0, fresh proof 없는 serve=0, 새 소켓 proof로 별도 인증 성공.")
    }

    private func usbBinding(cable: InterfaceSnapshot.CableReading? = nil, source: String = "fe80::2",
                            scope: String? = "en14", local: String = "fe80::1", localScope: String? = "en14",
                            own: Set<[UInt8]> = []) -> OwnerBootstrapSocket.Binding? {
        let reading = cable ?? InterfaceSnapshot.CableReading(registered: true, usbDevice: true, ncm: true,
            vendor: CableLink.appleVendor, product: 1, productName: "iPad", serial: "USB-TEST", session: 1)
        return OwnerBootstrapSocket.usbRouteBinding(generation: UUID(), fingerprint: binding().fingerprint,
            source: IPBytes.parse(source)!, scope: scope, local: local, localScope: localScope,
            entries: [.init(name: "en14", address: IPBytes.parse("fe80::1")!, prefixBits: 64,
                up: true, pointToPoint: false, loopback: false)], own: own, cable: reading)
    }

    func testUSBRouteBinding() throws {
        let first = try require(usbBinding())
        expectEqual(first.usb?.deviceID, CableLink.deviceID(serial: "USB-TEST"))
        expectEqual(first.usb?.plugSession, 1)
        for source in ["169.254.1.2", "192.168.1.2", "100.64.0.2", "::1", "fd00::2"] {
            expectNil(usbBinding(source: source))
        }
        for scope in [nil, "en0", "awdl0", "lo0", "utun9"] as [String?] { expectNil(usbBinding(scope: scope)) }
        expectNil(usbBinding(localScope: "en0"))
        expectNil(usbBinding(localScope: nil))
        expectNil(usbBinding(local: "fe80::3"))
        expectNil(usbBinding(local: "192.168.1.1"))
        expectNil(usbBinding(own: [IPBytes.parse("fe80::2")!]))
        var cable = InterfaceSnapshot.CableReading(registered: true, usbDevice: true, ncm: true,
            vendor: CableLink.appleVendor, product: 1, productName: "iPad", serial: "USB-TEST", session: 1)
        for mode in 0...8 {
            var bad = cable
            switch mode {
            case 0: bad.registered = false
            case 1: bad.usbDevice = false
            case 2: bad.ncm = false
            case 3: bad.vendor = 1
            case 4: bad.productName = "Mac"
            case 5: bad.serial = nil
            case 6: bad.serial = ""
            case 7: bad.session = nil
            default: bad.deviceMode = true
            }
            expectNil(usbBinding(cable: bad))
        }
        cable.session = 2
        expectFalse(first.usb == usbBinding(cable: cable)?.usb)
        cable.session = 1; cable.serial = "OTHER"
        expectFalse(first.usb == usbBinding(cable: cable)?.usb)
    }

    @MainActor func testUSBRegisteredSession() async throws {
        for mode in 0...20 {
            let (store, host) = try await sessionHost()
            let b = try require(usbBinding()), live = LiveFlag()
            let writes = store.writes, registryWrites = store.registryWrites
            let socket = OwnerBootstrapSocket.fixture(binding: b, trust: host.trust,
                purpose: mode == 1 ? .bootstrap : .session,
                deadline: mode == 2 ? 0 : DispatchTime.now().uptimeNanoseconds + 10_000_000_000,
                current: { live.get() })
            expectFalse(socket.permitsSession(at: .home))
            expectEqual(socket.permitsSession(at: .remote), mode != 1)
            let evidence = await host.ownerSessionEvidence(for: socket)
            if mode <= 2 {
                if mode == 0 {
                    expectTrue(admit(socket, box: host.trust, evidence: evidence))
                    expectFalse(admit(socket, box: host.trust, evidence: evidence))
                    expectFalse(host.trust.snapshot.doorTrust(b.fingerprint).paired)
                    expectEqual(DoorPolicy.atReady(.home, alpn: RemoteTLS.sessionALPN,
                        host.trust.snapshot.doorTrust(b.fingerprint), remoteSessions: 0), .ownerNeedsProof)
                } else { expectNil(evidence) }
            } else {
                let valid = try require(evidence)
                switch mode {
                case 3: socket.cancel()
                case 4: live.set(false)
                case 5: host.trust.update { $0.ownerBootstrapEpoch = UUID() }
                case 6: host.trust.update { $0.ownerCandidates[b.fingerprint] = nil }
                case 7: host.trust.update {
                    let old = $0.ownerCandidates[b.fingerprint]!
                    $0.ownerCandidates[b.fingerprint] = .init(principal: old.principal, generation: UUID(), name: old.name)
                }
                case 8: store.registryMissing = true
                case 9: store.readRegistryFailure = true
                case 10, 11, 12, 13:
                    let identity = try require(host.identity)
                    var registry = try OwnerBootstrapRegistry.load(store: store, identity: identity)
                    if mode == 10 { registry.bindings[0].state = .revoked }
                    if mode == 11 { registry.bindings[0].state = .pending }
                    if mode == 12 { registry.bindings = [] }
                    if mode == 13 { registry.bindings[0] = .init(principal: String(repeating: "a", count: 64), fingerprint: registry.bindings[0].fingerprint, state: .active) }
                    try registry.save(store: store, identity: identity)
                case 14:
                    var devices = try store.loadPaired(); devices[0].ownerActivationPending = true
                    try store.savePaired(devices)
                case 15: try store.savePaired([])
                case 16:
                    var different = b; different.usb = .init(deviceID: b.usb!.deviceID, plugSession: 2)
                    let other = OwnerBootstrapSocket.fixture(binding: different, trust: host.trust, purpose: .session)
                    expectFalse(admit(other, box: host.trust, evidence: valid))
                    continue
                case 17:
                    var different = b; different = .init(generation: different.generation, fingerprint: binding(2).fingerprint,
                        sourceIP: different.sourceIP, localIP: different.localIP, interface: different.interface, usb: different.usb)
                    let other = OwnerBootstrapSocket.fixture(binding: different, trust: host.trust, purpose: .session)
                    expectFalse(admit(other, box: host.trust, evidence: valid))
                    continue
                case 18:
                    expectFalse(socket.admit(in: host.trust, evidence: valid, allowed: { _ in
                        host.trust.update { $0.ownerBootstrapEpoch = UUID() }; return true
                    }) { _ in fail("변경된 epoch로 serve") })
                    continue
                case 19:
                    expectFalse(socket.admit(in: host.trust, evidence: valid, allowed: { _ in
                        live.set(false); return true
                    }) { _ in fail("교체된 plug로 serve") })
                    continue
                default:
                    expectFalse(socket.admit(in: host.trust, evidence: valid, allowed: { _ in
                        try? store.savePaired([]); return true
                    }) { _ in fail("변경된 등록으로 serve") })
                    continue
                }
                expectFalse(admit(socket, box: host.trust, evidence: valid))
            }
            if mode < 10 {
                expectEqual(store.writes, writes + ((mode == 1 || mode == 2) ? 0 : 1))
                expectEqual(store.registryWrites, registryWrites)
            }
        }
    }

    @MainActor func testUSBAudioGenerationAndIndependentDevices() async throws {
        for mode in 0...7 {
            let (store, host) = try await sessionHost(), b = try require(usbBinding())
            let socket = OwnerBootstrapSocket.fixture(binding: b, trust: host.trust, purpose: .session)
            let before = try store.loadPaired()
            expectNil(before.first?.audioPairingGeneration)
            let evidence = try require(await host.ownerSessionEvidence(for: socket))
            let prepared = try store.loadPaired()
            let audio = try require(prepared.first?.audioPairingGeneration)
            expectTrue(admit(socket, box: host.trust, evidence: evidence))
            let writes = store.writes
            expectEqual(host.forwardingPeer(fingerprint: b.fingerprint)?.pairingGeneration, audio)
            expectEqual(store.writes, writes)
            expectTrue(socket.usbSessionIsCurrent(in: host.trust, evidence: evidence))
            var changed = try store.loadPaired()
            switch mode {
            case 0: changed[0].name = "이름 수정"; changed[0].model = "iPad99,1"
            case 1: changed[0].cableDevice = b.usb!.deviceID
            case 2:
                changed.append(PairedDevice(fingerprint: Base64URL.encode(binding(2).fingerprint),
                    name: "다른 기기", model: nil, pairedAt: 2, method: PairRequest.code))
            case 3: changed[0].audioPairingGeneration = UUID()
            case 4: changed[0].audioPairingGeneration = nil
            case 5: changed[0].cableDevice = "다른 USB 기기"
            case 6: changed[0].pairedAt += 1
            default:
                let identity = try require(host.identity)
                var registry = try OwnerBootstrapRegistry.load(store: store, identity: identity)
                registry.bindings.append(.init(principal: String(repeating: "b", count: 64),
                    fingerprint: Base64URL.encode(binding(2).fingerprint), state: .active))
                try registry.save(store: store, identity: identity)
            }
            try store.savePaired(changed)
            expectEqual(socket.usbSessionIsCurrent(in: host.trust, evidence: evidence), mode <= 2 || mode == 7)
        }
    }

    @MainActor func testUSBInitialRegistryAndGateExpiry() async throws {
        for mode in 0...7 {
            let (store, host) = try await sessionHost(), b = try require(usbBinding())
            let identity = try require(host.identity)
            if mode <= 5 {
                var registry = try OwnerBootstrapRegistry.load(store: store, identity: identity)
                switch mode {
                case 0: registry.bindings[0].state = .revoked
                case 1: registry.bindings[0].state = .pending
                case 2: registry.bindings = []
                case 3:
                    registry.bindings[0] = .init(principal: String(repeating: "b", count: 64),
                        fingerprint: registry.bindings[0].fingerprint, state: .active)
                case 4:
                    let foreign = RemoteAccess(store: FaultStore())
                    var other = OwnerBootstrapRegistry(macID: foreign.identity!.macID)
                    other.bindings = registry.bindings
                    try other.save(store: store.memory, identity: foreign.identity!)
                default:
                    var devices = try store.loadPaired(); devices[0].ownerActivationPending = true
                    try store.savePaired(devices)
                }
                if mode < 4 { try registry.save(store: store, identity: identity) }
            }
            let socket = OwnerBootstrapSocket.fixture(binding: b, trust: host.trust, purpose: .session,
                deadline: DispatchTime.now().uptimeNanoseconds + 200_000_000)
            if mode <= 5 { let evidence = await host.ownerSessionEvidence(for: socket); expectNil(evidence); continue }
            if mode == 6 {
                let evidence = try require(await host.ownerSessionEvidence(for: socket))
                expectFalse(socket.admit(in: host.trust, evidence: evidence, allowed: { _ in
                    Thread.sleep(forTimeInterval: 0.25); return true
                }) { _ in fail("만료 후 USB serve") })
            } else {
                let task = Task { @MainActor in await host.ownerSessionEvidence(for: socket) }
                task.cancel()
                let evidence = await task.value
                expectNil(evidence)
            }
        }
    }

    @MainActor func testUSBSessionLifetimeAndAdmissionLog() async throws {
        for mode in 0...6 {
            let (store, host) = try await sessionHost(), b = try require(usbBinding()), live = LiveFlag()
            let socket = OwnerBootstrapSocket.fixture(binding: b, trust: host.trust, purpose: .session,
                deadline: DispatchTime.now().uptimeNanoseconds + 200_000_000, current: { live.get() })
            let evidence = try require(await host.ownerSessionEvidence(for: socket))
            expectNil(socket.takeUSBAdmissionLog())
            expectFalse(socket.usbSessionIsCurrent(in: host.trust, evidence: evidence))
            expectTrue(admit(socket, box: host.trust, evidence: evidence))
            let log = try require(socket.takeUSBAdmissionLog())
            expectTrue(log.contains("phase=admitted interface=en14"))
            expectTrue(log.contains("socketGeneration=\(b.generation)"))
            expectTrue(log.contains("plugSession=1 tlsFingerprintSHA256="))
            expectFalse(log.contains("USB-TEST"))
            expectFalse(log.contains(Base64URL.encode(b.fingerprint)))
            expectNil(socket.takeUSBAdmissionLog())
            try await Task.sleep(nanoseconds: 250_000_000)
            expectFalse(socket.isLive)
            expectTrue(socket.usbSessionIsCurrent(in: host.trust, evidence: evidence))
            switch mode {
            case 0: live.set(false)
            case 1: host.trust.update { $0.ownerBootstrapEpoch = UUID() }
            case 2: host.trust.update {
                let old = $0.ownerCandidates[b.fingerprint]!
                $0.ownerCandidates[b.fingerprint] = .init(principal: old.principal, generation: UUID(), name: old.name)
            }
            case 3:
                let identity = try require(host.identity)
                var registry = try OwnerBootstrapRegistry.load(store: store, identity: identity)
                registry.bindings[0].state = .revoked
                try registry.save(store: store, identity: identity)
            case 4: try store.savePaired([])
            case 5: socket.cancel()
            default: store.registryMissing = true
            }
            expectFalse(socket.usbSessionIsCurrent(in: host.trust, evidence: evidence))
        }
    }

    private func admit(_ socket: OwnerBootstrapSocket, box: TrustBox, evidence: OwnerBootstrapSocket.Evidence?,
                       sessions: Int = 0, serve: () -> Void = {}) -> Bool {
        socket.admit(in: box, evidence: evidence, allowed: { snapshot in
            DoorPolicy.afterGate(.remote, wasPaired: true, origin: .vpn, snapshot.doorTrust(socket.binding.fingerprint),
                                 remoteSessions: sessions) == nil
        }) { _ in serve() }
    }

    @MainActor private func assertRestartRequiresFreshSession(_ store: FaultStore, ownerCount: Int = 1) async throws {
        let host = remote(store)
        let snapshot = host.trust.snapshot
        expectTrue(snapshot.ownerAuthorized.isEmpty)
        expectEqual(snapshot.ownerCandidates.count, ownerCount)
        for (key, candidate) in snapshot.ownerCandidates {
            let fixture = SensorFixture()
            if candidate.principal == OwnerBootstrapRegistry.principal(user: 7, node: "second-node") {
                fixture.node["StableID"] = "second-node"
            }
            host.configureOwnerBootstrapForTesting(sensor: fixture.sensor(), enabled: true)
            let b = OwnerBootstrapSocket.Binding(generation: UUID(), fingerprint: key, sourceIP: "100.64.0.2", localIP: "100.64.0.1", interface: "utun9")
            let socket = OwnerBootstrapSocket.fixture(binding: b, trust: host.trust, purpose: .session)
            expectFalse(host.isPaired(key))
            expectTrue(DoorPolicy.trusts(.remote, alpn: RemoteTLS.sessionALPN, snapshot.doorTrust(key)))
            expectEqual(DoorPolicy.atReady(.remote, alpn: RemoteTLS.sessionALPN, snapshot.doorTrust(key), remoteSessions: 0), .ownerNeedsProof)
            var served = 0
            expectFalse(admit(socket, box: host.trust, evidence: nil) { served += 1 })
            expectEqual(served, 0)
            let evidence = try require(await host.ownerSessionEvidence(for: socket))
            expectFalse(host.isPaired(key))
            expectTrue(admit(socket, box: host.trust, evidence: evidence) {
                expectTrue(host.trust.snapshot.isPaired(key)); served += 1
            })
            expectTrue(host.isPaired(key))
            expectEqual(served, 1)
            expectFalse(admit(socket, box: host.trust, evidence: evidence) { served += 1 })
            socket.cancel()
            expectTrue(host.isPaired(key))
            let next = OwnerBootstrapSocket.fixture(binding: .init(generation: UUID(), fingerprint: key,
                sourceIP: b.sourceIP, localIP: b.localIP, interface: b.interface), trust: host.trust, purpose: .session)
            expectFalse(admit(next, box: host.trust, evidence: evidence) { served += 1 })
            expectFalse(admit(next, box: host.trust, evidence: nil) { served += 1 })
            expectEqual(served, 1)
            let fresh = try require(await host.ownerSessionEvidence(for: next))
            expectTrue(admit(next, box: host.trust, evidence: fresh) { served += 1 })
            expectEqual(served, 2)
        }
    }

    @MainActor private func sessionHost() async throws -> (FaultStore, RemoteAccess) {
        let store = FaultStore(), host = remote(store)
        assertOK(await host.judgeOwnerBootstrap(attempt(OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust))))
        return (store, remote(store))
    }

    @MainActor private func residualHost() async throws -> (FaultStore, RemoteAccess) {
        let store = FaultStore(), live = LiveFlag(), host = remote(store)
        store.afterPairedSave = {
            if store.writes == 2 { store.registryFailure = true; store.pairedFailure = true; live.set(false) }
        }
        let socket = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust) { live.get() }
        assertClosed(await host.judgeOwnerBootstrap(attempt(socket)))
        return (store, remote(store))
    }

    @MainActor func testSessionProofRefusalCancellationDeadlineAndExpiry() async throws {
        for mode in 0...7 {
            let (store, host) = try await residualHost()
            let fixture = SensorFixture()
            if mode == 0 { fixture.node["User"] = 8 }
            if mode == 1 { fixture.beforeRead = { _ in throw TailnetDeviceAccess.Failure.sensorFailure } }
            if mode == 2 { fixture.beforeRead = { _ in Thread.sleep(forTimeInterval: 2.10) } }
            host.configureOwnerBootstrapForTesting(sensor: fixture.sensor(), enabled: true)
            let socket = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust, purpose: .session,
                deadline: mode == 3 ? 0 : DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
            var evidence: OwnerBootstrapSocket.Evidence?
            if mode == 4 {
                let task = Task { await host.ownerSessionEvidence(for: socket) }
                task.cancel(); evidence = await task.value
            } else {
                evidence = await host.ownerSessionEvidence(for: socket)
            }
            if mode <= 4 { expectNil(evidence) }
            if mode == 5 { socket.cancel() }
            if mode == 6 { try await Task.sleep(nanoseconds: 2_050_000_000) }
            if mode == 7 { evidence?.sensor.stop() }
            var served = 0
            expectFalse(admit(socket, box: host.trust, evidence: evidence) { served += 1 })
            expectEqual(served, 0)
            expectFalse(host.isPaired(socket.binding.fingerprint))
            expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
            expectEqual(store.writes, 2)
        }
    }

    @MainActor func testSessionProofCannotCrossSocketKeyNodeOrIssuer() async throws {
        let (_, host) = try await sessionHost()
        let original = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust, purpose: .session)
        let evidence = try require(await host.ownerSessionEvidence(for: original))
        let b = original.binding
        let alternatives: [OwnerBootstrapSocket.Binding] = [
            binding(), binding(2), binding(source: "100.64.0.3"), binding(local: "100.64.0.3"),
            .init(generation: b.generation, fingerprint: b.fingerprint, sourceIP: b.sourceIP, localIP: b.localIP, interface: "utun8")
        ]
        var served = 0
        for alternative in alternatives {
            let socket = OwnerBootstrapSocket.fixture(binding: alternative, trust: host.trust, purpose: .session)
            expectFalse(admit(socket, box: host.trust, evidence: evidence) { served += 1 })
        }
        let foreign = OwnerBootstrapSocket.Evidence(sensor: SensorFixture().sensor(), proof: evidence.proof)
        expectFalse(admit(original, box: host.trust, evidence: foreign) { served += 1 })
        let other = SensorFixture(); other.node["StableID"] = "different-node"
        host.configureOwnerBootstrapForTesting(sensor: other.sensor(), enabled: true)
        let wrongNode = try require(await host.ownerSessionEvidence(for: original))
        expectFalse(admit(original, box: host.trust, evidence: wrongNode) { served += 1 })
        expectEqual(served, 0)
        expectFalse(host.isPaired(b.fingerprint))
        expectTrue(admit(original, box: host.trust, evidence: evidence) { served += 1 })
        expectEqual(served, 1)
        let next = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust, purpose: .session)
        expectFalse(admit(next, box: host.trust, evidence: nil) { served += 1 })
        expectFalse(admit(next, box: host.trust, evidence: evidence) { served += 1 })
        expectEqual(served, 1)
    }

    @MainActor func testSessionInvalidationAtFinalAdmission() async throws {
        for mode in 0...7 {
            let (store, host) = try await sessionHost()
            let socket = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust, purpose: .session)
            let evidence = try require(await host.ownerSessionEvidence(for: socket))
            switch mode {
            case 0: host.configureOwnerBootstrapForTesting(sensor: SensorFixture().sensor(), enabled: false)
            case 1:
                host.configureOwnerBootstrapForTesting(sensor: SensorFixture().sensor(), enabled: false)
                host.configureOwnerBootstrapForTesting(sensor: SensorFixture().sensor(), enabled: true)
            case 2: expectNil(host.remove(fingerprint: Base64URL.encode(socket.binding.fingerprint)))
            case 3: host.trust.update { $0.ownerBootstrapEpoch = UUID(); $0.ownerAuthorized = [:] }
            case 4:
                host.trust.update {
                    let key = socket.binding.fingerprint, old = $0.ownerCandidates[key]!
                    $0.ownerCandidates[key] = .init(principal: old.principal, generation: UUID(), name: old.name)
                }
            case 5: socket.cancel()
            case 6: evidence.sensor.stop()
            default: break
            }
            var served = 0
            expectFalse(admit(socket, box: host.trust, evidence: evidence,
                              sessions: mode == 7 ? DoorPolicy.maxRemoteSessions : 0) { served += 1 })
            expectEqual(served, 0)
            expectFalse(host.isPaired(socket.binding.fingerprint))
            if mode == 2 {
                let restarted = remote(store)
                expectNil(restarted.trust.snapshot.ownerCandidates[socket.binding.fingerprint])
                var home = restarted.trust.snapshot.doorTrust(socket.binding.fingerprint)
                home.requirePairing = false
                expectEqual(DoorPolicy.atReady(.home, alpn: RemoteTLS.sessionALPN, home, remoteSessions: 0), .refuse("unpaired"))
            }
        }
        for candidate in [false, true] {
            let t = DoorPolicy.Trust(ownerKnown: true, ownerCandidate: candidate, requirePairing: false, remoteAccess: true)
            expectEqual(DoorPolicy.atReady(.home, alpn: RemoteTLS.sessionALPN, t, remoteSessions: 0),
                        candidate ? .ownerNeedsProof : .refuse("unpaired"))
        }
        let (_, host) = try await sessionHost()
        let socket = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust, purpose: .session, current: { false })
        let refused = await host.ownerSessionEvidence(for: socket)
        expectNil(refused)
    }

    @MainActor func testTwoPendingOwnerConnectionsHaveIndependentSensors() async throws {
        let (_, host) = try await sessionHost(), fixture = SensorFixture()
        fixture.beforeRead = { _ in Thread.sleep(forTimeInterval: 0.01) }
        host.configureOwnerBootstrapForTesting(sensor: fixture.sensor(), enabled: true)
        let a = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust, purpose: .session)
        let b = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust, purpose: .session)
        async let first = host.ownerSessionEvidence(for: a)
        async let second = host.ownerSessionEvidence(for: b)
        let (one, two) = await (first, second)
        let ea = try require(one), eb = try require(two)
        expectFalse(ea.sensor === eb.sensor)
        expectNotEqual(ea.proof.binding, eb.proof.binding)
        expectEqual(fixture.commands.count, 6)
        var served = 0
        expectFalse(admit(a, box: host.trust, evidence: eb) { served += 1 })
        expectFalse(admit(b, box: host.trust, evidence: ea) { served += 1 })
        expectTrue(admit(a, box: host.trust, evidence: ea) { served += 1 })
        expectTrue(admit(b, box: host.trust, evidence: eb) { served += 1 })
        expectEqual(served, 2)
        expectTrue(host.isPaired(a.binding.fingerprint))
    }

    @MainActor func testAdmissionDecisionSerializesCancellationAndSettings() async throws {
        for change in 0...2 {
            let (_, host) = try await sessionHost()
            let box = host.trust
            let socket = OwnerBootstrapSocket.fixture(binding: binding(), trust: box, purpose: .session)
            let evidence = try require(await host.ownerSessionEvidence(for: socket))
            let entered = DispatchSemaphore(value: 0), attempted = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            let done = LiveFlag(); done.set(false)
            DispatchQueue.global().async {
                entered.wait(); attempted.signal()
                if change == 1 { box.update { $0.ownerBootstrapEpoch = UUID(); $0.ownerAuthorized = [:] } }
                else if change == 2 { evidence.sensor.stop() }
                else { socket.cancel() }
                done.set(true); finished.signal()
            }
            var served = 0
            expectTrue(socket.admit(in: box, evidence: evidence) { snapshot in
                entered.signal(); attempted.wait()
                expectEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
                expectFalse(done.get())
                expectTrue(snapshot.isPaired(socket.binding.fingerprint))
                served += 1
            })
            expectEqual(finished.wait(timeout: .now() + 1), .success)
            expectEqual(served, 1)
            expectTrue(done.get())
            expectEqual(box.snapshot.isPaired(socket.binding.fingerprint), change != 1)
            expectFalse(admit(socket, box: box, evidence: evidence) { served += 1 })
            expectEqual(served, 1)
        }
    }

    @MainActor func testSessionRefreshRejectsDamagedRevokedOrForeignRecord() async throws {
        for mode in 0...4 {
            let (store, host) = try await sessionHost()
            let socket = OwnerBootstrapSocket.fixture(binding: binding(), trust: host.trust, purpose: .session)
            let fingerprint = Base64URL.encode(socket.binding.fingerprint)
            switch mode {
            case 0: try store.memory.saveOwnerRegistry(Data("{}".utf8))
            case 1: try signedRegistry(store, schema: 99, bindings: [])
            case 2:
                let (other, _) = try await sessionHost()
                try store.memory.saveOwnerRegistry(try require(other.loadOwnerRegistry()))
            case 3: store.registryMissing = true
            default:
                try signedRegistry(store, schema: 3, bindings: [["principal": OwnerBootstrapRegistry.principal(user: 7, node: "peer-node"),
                    "fingerprint": fingerprint, "state": "revoked"]])
            }
            let evidence = await host.ownerSessionEvidence(for: socket)
            expectNil(evidence)
            var served = 0
            expectFalse(admit(socket, box: host.trust, evidence: evidence) { served += 1 })
            expectEqual(served, 0)
            expectFalse(host.isPaired(socket.binding.fingerprint))
            var t = host.trust.snapshot.doorTrust(socket.binding.fingerprint)
            t.requirePairing = false
            expectEqual(DoorPolicy.atReady(.home, alpn: RemoteTLS.sessionALPN, t, remoteSessions: 0), .refuse("unpaired"))
        }
    }

    @MainActor func testAdmissionExpiryAfterBlockingValidation() async throws {
        for mode in 0...3 {
            let (_, host) = try await sessionHost()
            let b = binding(), sensor = SensorFixture().sensor()
            guard case .success(let proof) = await sensor.principal(for: b) else {
                fail("최종 기한 검사의 증거 발급 실패"); continue
            }
            let evidence = OwnerBootstrapSocket.Evidence(sensor: sensor, proof: proof)
            let entered = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            if mode == 2 {
                DispatchQueue.global().async {
                    _ = sensor.withCurrent(proof) {
                        entered.signal()
                        Thread.sleep(forTimeInterval: 0.08)
                        return true
                    }
                    finished.signal()
                }
                expectEqual(entered.wait(timeout: .now() + 1), .success)
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + (mode == 3 ? 10_000_000_000 : 20_000_000)
            let socket = OwnerBootstrapSocket.fixture(binding: b, trust: host.trust, purpose: .session,
                deadline: deadline, current: {
                    if mode == 0 { Thread.sleep(forTimeInterval: 0.08) }
                    return true
                })
            var served = 0
            expectFalse(socket.admit(in: host.trust, evidence: evidence, allowed: { _ in
                if mode == 1 { Thread.sleep(forTimeInterval: 0.08) }
                if mode == 3 { Thread.sleep(forTimeInterval: 2.05) }
                return true
            }) { _ in served += 1 })
            if mode == 2 { expectEqual(finished.wait(timeout: .now() + 1), .success) }
            expectEqual(served, 0)
            expectTrue(host.trust.snapshot.ownerAuthorized.isEmpty)
        }
    }

    @MainActor func testLegacyNormalAdmissionWithoutOwnerProof() async throws {
        for method in [PairRequest.qr, PairRequest.code, PairResult.cable, "icloud"] {
            let store = FaultStore(), key = binding().fingerprint
            let original = PairedDevice(fingerprint: Base64URL.encode(key), name: "기존 명시적 신뢰", model: "보존",
                                        pairedAt: 1, method: method, cableDevice: "기존 케이블")
            try store.savePaired([original])
            let host = remote(store), t = host.trust.snapshot.doorTrust(key)
            expectTrue(host.isPaired(key))
            expectTrue(host.trust.snapshot.ownerCandidates.isEmpty)
            expectEqual(DoorPolicy.atReady(.remote, alpn: RemoteTLS.sessionALPN, t, remoteSessions: 0), .session)
            expectEqual(DoorPolicy.atReady(.home, alpn: RemoteTLS.sessionALPN, t, remoteSessions: 0), .session)
            expectNil(DoorPolicy.afterGate(.remote, wasPaired: true, origin: .lan, t, remoteSessions: 0))
            expectNil(DoorPolicy.afterGate(.home, wasPaired: true, origin: .lan, t, remoteSessions: 0))
            expectEqual(try store.loadPaired(), [original])
            expectNil(host.remove(fingerprint: original.fingerprint))
            expectFalse(host.isPaired(key))
            var guest = host.trust.snapshot.doorTrust(key)
            guest.requirePairing = false
            expectEqual(DoorPolicy.atReady(.home, alpn: RemoteTLS.sessionALPN, guest, remoteSessions: 0), .session)
        }
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
        await checks.testMachineAuthorizationEvidenceAndDiagnostics()
        do { try await checks.testSensorFailureStagesAndConstantLogs() } catch { fail("센서 단계와 고정 로그 검사 예외") }
        await checks.testBlockedDiagnosticsDoNotDelayCompletionOrCleanup()
        checks.testCanonicalCLIEnvironmentIsFixed()
        await checks.testBackendAndStatusChangesDenied()
        await checks.testLANAndOutputLimitDenied()
        do { try await checks.testProductionRegistrationAndPairedReconnect() } catch { fail("testProductionRegistrationAndPairedReconnect 예외") }
        await checks.testRemoteOffWrongDoorAndKeyMismatchDenied()
        await checks.testCancellationAndRouteChangeDenied()
        await checks.testWrongLocalEndpointDenied()
        do { try await checks.testRemovalAndRekeyNeverBootstrapAgain() } catch { fail("testRemovalAndRekeyNeverBootstrapAgain 예외") }
        do { try await checks.testRegistryFailureNeverProducesPairingSuccess() } catch { fail("testRegistryFailureNeverProducesPairingSuccess 예외") }
        do { try await checks.testPartialReservationRecoversWithFreshProof() } catch { fail("testPartialReservationRecoversWithFreshProof 예외") }
        do { try await checks.testPairedReadbackAndRemovalFailures() } catch { fail("testPairedReadbackAndRemovalFailures 예외") }
        do { try await checks.testTamperedMissingRegistryFailClosedOnlyForOwner() } catch { fail("testTamperedMissingRegistryFailClosedOnlyForOwner 예외") }
        do { try await checks.testExplicitPairingRemainsIndependentOfAutomaticRevocation() } catch { fail("testExplicitPairingRemainsIndependentOfAutomaticRevocation 예외") }
        let usbBefore = CheckCounts.shared.result
        do { try await checks.testUSBSessionLifetimeAndAdmissionLog() } catch { fail("USB 수명·수용 로그 검사 예외: \(error)") }
        do { try await checks.testUSBAudioGenerationAndIndependentDevices() } catch { fail("USB 음성 세대·다른 기기 회귀 예외: \(error)") }
        do { try await checks.testUSBInitialRegistryAndGateExpiry() } catch { fail("USB 최초등록·기한 검사 예외: \(error)") }
        do { try checks.testUSBRouteBinding() } catch { fail("USB 경로 검사 예외: \(error)") }
        do { try await checks.testUSBRegisteredSession() } catch { fail("USB 등록 세션 검사 예외: \(error)") }
        let usbAfter = CheckCounts.shared.result
        print("이번 USB 추가 계약 검사 \(usbAfter.0 - usbBefore.0)개 통과, \(usbAfter.1 - usbBefore.1)개 실패.")
        checks.testProductionRouteBindingRequiresTailnetTunnelAndFreshGeneration()
        do { try await checks.testLastCheckAfterReservationDeniesChangedSocket() } catch { fail("testLastCheckAfterReservationDeniesChangedSocket 예외") }
        do { try await checks.testMissingRegistryAndForeignSignatureDenyOnlyAutomaticTrust() } catch { fail("testMissingRegistryAndForeignSignatureDenyOnlyAutomaticTrust 예외") }
        await checks.testPublicProfileUsesSingleStatusWithoutApprovalOrKeys()
        await checks.testPublicAndProofSignedReadContracts()
        let candidateBefore = CheckCounts.shared.result
        await checks.testCandidatePreparationAndObservationDeadline()
        await checks.testCandidateSignatureFailuresAndCumulativeBudget()
        await checks.testCandidateRequiresSingleStartMarker()
        await checks.testCandidateLateSignaturesCannotReviveFinishedAttempt()
        await checks.testCandidatePublicProfileRetainsTenSecondSingleStatus()
        do { try await checks.testCandidateDeadlineAtFinalSocketAdmission() } catch { fail("후보 정책의 최종 소켓 사용 검사 예외") }
        let candidateAfter = CheckCounts.shared.result
        print("별도 미통합 정책 후보 검사 \(candidateAfter.0 - candidateBefore.0)개 통과, \(candidateAfter.1 - candidateBefore.1)개 실패. 기존 request 전체 2초 정책과 동등하지 않음.")
        await checks.testPublicObservationCanTakeMoreThanProofDeadline()
        await checks.testPublicProfileRejectsInvalidSelfAndOutput()
        await checks.testPublicProfileStopCancellationBusyAndDeadline()
        do { try await checks.testPublicProfileFactoryAndMonotonicExpiryAreSeparateFromProof() } catch { fail("공개 관측의 현재성·권한 수명 분리 검사 예외") }
        do { try await checks.testRemoteSettingEpochAndProofExpiryBeforeSave() } catch { fail("설정 세대 및 저장 직전 만료 검사 예외") }
        await checks.testCancelledQueryNeverIssuesProof()
        do { try await checks.testUnsupportedStorePreservesLegacyPairing() } catch { fail("구형 저장소 호환성 검사 예외") }
        do { try checks.testOversizedRegistryNeverOverwritesValidRecord() } catch { fail("원장 크기 한도 검사 예외") }
        do { try await checks.testProofExpirationAndStop() } catch { fail("testProofExpirationAndStop 예외") }
        do { try await checks.testExistingPairingRecoversWithoutChangingMetadata() } catch { fail("기존 paired 복구 검사 예외") }
        do { try await checks.testPairedWriteInvalidationNeverActivatesAfterRestart() } catch { fail("paired 저장 중 현재성 검사 예외") }
        do { try await checks.testWriteThenFailureRecoversAndPreservesMetadata() } catch { fail("저장 직후 실패 복구 검사 예외") }
        do { try await checks.testCancellationDuringPairedWrite() } catch { fail("저장 중 취소 검사 예외") }
        do { try await checks.testPendingNeverAcceptsDifferentNodeOrKey() } catch { fail("node와 key 충돌 검사 예외") }
        do { try await checks.testActivationAndRemovalInterruptionPoints() } catch { fail("활성화와 철회 중단 검사 예외") }
        do { try await checks.testLegacyRemovalTombstoneBlocksRecovery() } catch { fail("기존 paired 철회 검사 예외") }
        do { try await checks.testRegistrySchemaCompatibilityAndCorruption() } catch { fail("원장 schema 호환과 손상 검사 예외") }
        do { try await checks.testPendingWithoutPairedCanBeRevoked() } catch { fail("paired 없는 예약 철회 검사 예외") }
        do { try await checks.testActivationWriteInvalidationRemainsPending() } catch { fail("활성 저장 중 현재성 검사 예외") }
        do { try await checks.testDurableTombstoneReadbackFailureNeverRestoresTrust() } catch { fail("철회 readback 실패 검사 예외") }
        do { try await checks.testV1MigrationPreservesExistingBinding() } catch { fail("v1 원장 이행 검사 예외") }
        do { try await checks.testActiveWriteFailureAndFailedCompensationNeverGrantsTrust() } catch { fail("active 저장 후 실패와 보상 실패 검사 예외") }
        do { try await checks.testRecoveredLegacyPairingRemovalPreservesRevocation() } catch { fail("legacy 복구 후 Remove 검사 예외") }
        do { try await checks.testFinalCompletionFailuresDoNotPublishTrust() } catch { fail("최종 완료 저장 실패 검사 예외") }
        do { try await checks.testCommittedTrustSurvivesSocketDisconnection() } catch { fail("정상 commit 후 연결 해제 검사 예외") }
        do { try await checks.testV2PairingCompatibility() } catch { fail("v2 paired 호환 검사 예외") }
        do { try await checks.testTotalStorageOutageRequiresFreshSessionAfterRestart() } catch { fail("전체 저장 실패 후 재인증 검사 예외") }
        do { try await checks.testSessionProofRefusalCancellationDeadlineAndExpiry() } catch { fail("세션 거부·취소·기한 검사 예외") }
        do { try await checks.testSessionProofCannotCrossSocketKeyNodeOrIssuer() } catch { fail("소켓·키·node·issuer 교차 검사 예외") }
        do { try await checks.testSessionInvalidationAtFinalAdmission() } catch { fail("최종 admission 무효화 검사 예외") }
        do { try await checks.testTwoPendingOwnerConnectionsHaveIndependentSensors() } catch { fail("동시 owner 연결 검사 예외") }
        do { try await checks.testAdmissionDecisionSerializesCancellationAndSettings() } catch { fail("결정 경계 직렬화 검사 예외") }
        do { try await checks.testSessionRefreshRejectsDamagedRevokedOrForeignRecord() } catch { fail("저장 기록의 재조회 거부 검사 예외") }
        do { try await checks.testAdmissionExpiryAfterBlockingValidation() } catch { fail("최종 검사 중 만료 거부 검사 예외") }
        do { try await checks.testLegacyNormalAdmissionWithoutOwnerProof() } catch { fail("명시적 신뢰의 정상 연결 검사 예외") }
        if CommandLine.arguments.contains("--policy-candidate") {
            print("후보 격리 검사: 실제 실행파일 서명 센서 호출 대신 고정 서명 요건의 소스 검사와 가짜 서명 이벤트 사용.")
        } else {
            checks.testCanonicalSignedSensorRejectsUnexpectedExecutable()
        }
        let (passed, failed) = CheckCounts.shared.result
        print("생산 함수 기반 호스트 검사 \(passed)개 통과, \(failed)개 실패. 네트워크·실제 키체인·설치·오디오 호출 0.")
        exit(failed == 0 ? 0 : 1)
    }
}
