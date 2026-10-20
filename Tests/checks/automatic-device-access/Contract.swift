import Foundation

private let user: UInt64 = 7_583_687_675_853_032
private let source = "100.112.191.3"

private func status(id: String = "nLocal", uid: UInt64 = user, backend: String = "Running") -> Data {
    Data("{\"BackendState\":\"\(backend)\",\"Self\":{\"ID\":\"\(id)\",\"UserID\":\(uid)}}".utf8)
}

private func whois(_ changes: [String: Any] = [:], remove: String? = nil, profile: UInt64 = user) -> Data {
    var node: [String: Any] = [
        "StableID": "nPeerTest", "User": user, "MachineAuthorized": true,
        "KeyExpiry": "2099-11-01T20:48:23Z", "Expired": false,
        "Addresses": ["100.112.191.3/32", "fd7a:115c:a1e0::1234/128"],
        "AllowedIPs": ["0.0.0.0/0", "::/0"]
    ]
    node.merge(changes) { _, new in new }
    if let remove { node.removeValue(forKey: remove) }
    return try! JSONSerialization.data(withJSONObject: ["Node": node, "UserProfile": ["ID": profile]])
}

private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [Result<Data, TailnetDeviceAccess.Failure>]
    private var seen: [TailnetDeviceAccess.Command] = []
    init(_ inputs: [Data]) { self.inputs = inputs.map { .success($0) } }
    init(failure: TailnetDeviceAccess.Failure) { inputs = [.failure(failure)] }
    func read(_ command: TailnetDeviceAccess.Command, _ check: TailnetDeviceAccess.Check) throws -> Data {
        try check()
        lock.lock()
        seen.append(command)
        let next = inputs.isEmpty ? .failure(.sensorFailure) : inputs.removeFirst()
        lock.unlock()
        return try next.get()
    }
    var commands: [TailnetDeviceAccess.Command] {
        lock.lock(); defer { lock.unlock() }; return seen
    }
}

@main @MainActor struct Contract {
    private static var checks = 0
    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError("FAIL \(message)") }
    }
    private static func refusal(_ result: Result<TailnetDeviceAccess.Proof, TailnetDeviceAccess.Failure>,
                                _ reason: TailnetDeviceAccess.Failure, _ message: String) {
        if case .failure(let actual) = result { expect(actual == reason, "\(message), 실제 \(actual)") }
        else { expect(false, message) }
    }

    static func main() async {
        let fingerprint = Data32(Data(repeating: 0x42, count: 32))!
        expect(Data32(Data(repeating: 0, count: 31)) == nil, "TLS digest 길이 검증")
        expect(Data32(Data(repeating: 0, count: 33)) == nil, "긴 TLS digest 거부")
        let tailnet = AutomaticDevicePrincipal.tailnet(userId: user, nodeStableId: "nPeerTest")
        let cable = AutomaticDevicePrincipal.cable(deviceId: "nPeerTest")
        let lan = AutomaticDevicePrincipal.localNetwork(transportFingerprint: fingerprint)
        expect(Set([tailnet.stableIdentifier, cable.stableIdentifier, lan.stableIdentifier]).count == 3,
               "세 namespace 분리")
        expect(tailnet.stableIdentifier == tailnet.stableIdentifier, "식별자 결정성")
        expect(tailnet.stableIdentifier != AutomaticDevicePrincipal.tailnet(userId: user + 1, nodeStableId: "nPeerTest").stableIdentifier,
               "다른 사용자 분리")
        expect(tailnet.stableIdentifier != AutomaticDevicePrincipal.tailnet(userId: user, nodeStableId: "nOther").stableIdentifier,
               "다른 노드 분리")
        expect(lan.stableIdentifier.hasPrefix("sill-principal-local-network-v1:"), "LAN namespace 명시")

        let fixture = Fixture([status(), whois(), status()])
        let access = TailnetDeviceAccess(testingRead: fixture.read)
        let issued = await access.principal(for: source)
        guard case .success(let proof) = issued else { fatalError("정상 증거에서 미발급 \(issued)") }
        expect(proof.principal == tailnet, "실제 parser의 동일 사용자 발급")
        expect(fixture.commands == [.status, .whois(source), .status], "status 전후 검사 순서")
        expect(access.isCurrent(proof, sourceIP: source), "원래 source 유효")
        expect(access.isCurrent(proof, sourceIP: "::ffff:100.112.191.3"), "소켓 mapped IPv4 정규화")
        expect(!access.isCurrent(proof, sourceIP: "100.112.191.4"), "다른 source proof 재사용 거부")
        expect(!TailnetDeviceAccess().isCurrent(proof, sourceIP: source), "다른 발급자 proof 거부")
        access.stop()
        expect(!access.isCurrent(proof, sourceIP: source), "stop 이후 기존 proof 거부")
        refusal(await access.principal(for: source), .stopped, "stop 이후 조회 거부")

        for invalid in ["localhost", "peer.ts.net", "127.0.0.1", "127.77.1.1", "::1", "::ffff:127.0.0.1",
                        "192.168.0.2", "8.8.8.8", "100.112.191.3:23", "[fd7a:115c:a1e0::1234]",
                        "100.112.191.3/32", "fd7a:115c:a1e0::1234%en0", "100.128.0.1", "fd7b::1", ""] {
            let f = Fixture([])
            refusal(await TailnetDeviceAccess(testingRead: f.read).principal(for: invalid), .invalidSource, "숫자 endpoint 검증 \(invalid)")
            expect(f.commands.isEmpty, "잘못된 source는 CLI를 실행하지 않음")
        }
        let ipv6 = Fixture([status(), whois(), status()])
        if case .success(let v6) = await TailnetDeviceAccess(testingRead: ipv6.read).principal(for: "fd7a:115c:a1e0:0:0:0:0:1234") {
            expect(v6.sourceIP == "fd7a:115c:a1e0::1234", "IPv6 바이트 일치")
        } else { expect(false, "IPv6 발급") }

        let denied: [([String: Any], TailnetDeviceAccess.Failure)] = [
            (["User": user + 1], .differentUser), (["MachineAuthorized": false], .unauthorizedNode),
            (["StableID": ""], .unauthorizedNode), (["StableID": "bad\nname"], .unauthorizedNode),
            (["Expired": true], .expiredNode), (["KeyExpiry": "2001-01-01T00:00:00Z"], .expiredNode),
            (["KeyExpiry": "yesterday"], .malformedEvidence), (["KeyExpiry": "1970-01-01T00:00:00Z"], .malformedEvidence),
            (["KeyExpiry": "2099-11-01T20:48:23Zgarbage"], .malformedEvidence),
            (["KeyExpiry": "2099-02-31T20:48:23Z"], .malformedEvidence),
            (["KeyExpiry": "2099-11-01T24:48:23Z"], .malformedEvidence),
            (["Sharer": user + 1], .unauthorizedNode), (["Tags": ["tag:server"]], .unauthorizedNode),
            (["UnsignedPeerAPIOnly": true], .unauthorizedNode), (["IsJailed": true], .unauthorizedNode),
            (["IsWireGuardOnly": true], .unauthorizedNode),
            (["Addresses": ["100.112.191.4/32"]], .addressMismatch),
            (["Addresses": ["100.112.191.3/24"]], .addressMismatch),
            (["Addresses": ["0.0.0.0/0", "::/0"]], .addressMismatch),
            (["Addresses": ["192.168.0.2/32"]], .addressMismatch),
            (["Addresses": ["100.112.191.3/32", "fd7a:115c:a1e0::1234/64"]], .addressMismatch),
            (["Addresses": []], .addressMismatch),
            (["User": "7583687675853032"], .malformedEvidence),
            (["User": -1], .malformedEvidence), (["MachineAuthorized": "true"], .malformedEvidence),
            (["KeyExpiry": NSNull()], .malformedEvidence)
        ]
        for (change, failure) in denied {
            let f = Fixture([status(), whois(change), status()])
            refusal(await TailnetDeviceAccess(testingRead: f.read).principal(for: source), failure, "손상·권한·경로 거부 \(change.keys.sorted())")
        }
        for key in ["User", "MachineAuthorized", "StableID", "Addresses", "KeyExpiry"] {
            let f = Fixture([status(), whois(remove: key), status()])
            refusal(await TailnetDeviceAccess(testingRead: f.read).principal(for: source), .malformedEvidence, "필수 증거 누락 \(key)")
        }
        for expiry in ["0001-01-01T00:00:00Z", "2099-11-01T20:48:23.123456789Z", "2099-11-01T20:48:23+09:00"] {
            let f = Fixture([status(), whois(["KeyExpiry": expiry]), status()])
            if case .success = await TailnetDeviceAccess(testingRead: f.read).principal(for: source) {
                expect(true, "공식 zero 및 나노초 expiry")
            } else { expect(false, "공식 zero 및 나노초 expiry \(expiry)") }
        }
        let wrongProfile = Fixture([status(), whois(profile: user + 1), status()])
        refusal(await TailnetDeviceAccess(testingRead: wrongProfile.read).principal(for: source), .differentUser, "whois 프로필 사용자 불일치")
        for last in [status(id: "nChanged"), status(uid: user + 1)] {
            let f = Fixture([status(), whois(), last])
            refusal(await TailnetDeviceAccess(testingRead: f.read).principal(for: source), .snapshotChanged, "조회 중 identity 전환")
        }
        for backend in ["Stopped", "NeedsLogin", "Starting", "NeedsMachineAuth", ""] {
            for first in [true, false] {
                let f = Fixture(first ? [status(backend: backend)] : [status(), whois(), status(backend: backend)])
                refusal(await TailnetDeviceAccess(testingRead: f.read).principal(for: source), .backendNotRunning, "조회 전후 백엔드 \(backend)")
            }
        }
        for bad in [Data(), Data("null".utf8), Data("{\"Self\":{}}".utf8), Data("{".utf8)] {
            let f = Fixture([bad])
            refusal(await TailnetDeviceAccess(testingRead: f.read).principal(for: source), .malformedEvidence, "센서 JSON 누락·손상")
        }
        let huge = Fixture([Data(repeating: 0x20, count: TailnetDeviceAccess.outputLimit + 1)])
        refusal(await TailnetDeviceAccess(testingRead: huge.read).principal(for: source), .outputLimit, "출력 상한")
        let failed = Fixture(failure: .sensorFailure)
        refusal(await TailnetDeviceAccess(testingRead: failed.read).principal(for: source), .sensorFailure, "센서 실행 실패")

        await lifecycle()
        if CommandLine.arguments.contains("--live-self") { await liveSelf() }
        print("자동 기기 접근 계약 \(checks)개 통과")
    }

    private static func lifecycle() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let f = Fixture([status(), whois(), status()])
        let access = TailnetDeviceAccess(testingRead: { command, check in
            if command == .status && f.commands.isEmpty { entered.signal(); release.wait() }
            return try f.read(command, {})
        })
        let pending = Task { await access.principal(for: source) }
        await waitFor(entered)
        refusal(await access.principal(for: source), .busy, "중복 조회는 새 자식을 만들지 않음")
        pending.cancel()
        refusal(await pending.value, .cancelled, "Task 취소 즉시 결과")
        release.signal()
        try? await Task.sleep(for: .milliseconds(30))
        expect(f.commands == [.status], "취소된 늦은 센서 결과는 다음 단계로 진행하지 않음")

        let stopEntered = DispatchSemaphore(value: 0)
        let stopRelease = DispatchSemaphore(value: 0)
        let slow = Fixture([status(), whois(), status()])
        let stopping = TailnetDeviceAccess(testingRead: { command, check in
            if command == .whois(source) { stopEntered.signal(); stopRelease.wait() }
            return try slow.read(command, {})
        })
        let task = Task { await stopping.principal(for: source) }
        await waitFor(stopEntered)
        stopping.stop()
        refusal(await task.value, .stopped, "Door stop은 취소와 구분")
        stopRelease.signal()
        try? await Task.sleep(for: .milliseconds(30))
        expect(slow.commands == [.status, .whois(source)], "stop 이후 whois 늦은 결과 무시")

        let delayed = Fixture([status(), whois(), status()])
        let timeout = TailnetDeviceAccess(testingRead: { command, check in
            Thread.sleep(forTimeInterval: 2.15)
            return try delayed.read(command, {})
        })
        let begin = ContinuousClock.now
        refusal(await timeout.principal(for: source), .deadlineExceeded, "절대 2초 마감")
        expect(begin.duration(to: .now) < .milliseconds(2300), "센서 대기 중에도 호출자 마감")
        refusal(await timeout.principal(for: source), .busy, "기존 실행 회수 전 슬롯 유지")
        try? await Task.sleep(for: .milliseconds(200))
        expect(delayed.commands == [.status], "마감 뒤 늦은 성공 미수용")

        let expires = Fixture([status(), whois(), status()])
        let short = TailnetDeviceAccess(testingRead: expires.read)
        guard case .success(let proof) = await short.principal(for: source) else { fatalError("proof 발급 실패") }
        try? await Task.sleep(for: .milliseconds(2050))
        expect(!short.isCurrent(proof, sourceIP: source), "짧은 proof 만료")

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let noRead = Fixture([])
            let result = await TailnetDeviceAccess(testingRead: noRead.read).principal(for: source)
            refusal(result, .cancelled, "continuation 설치 전 취소")
            expect(noRead.commands.isEmpty, "취소된 진입에서 센서 미실행")
        }
        await cancelled.value
    }

    private static func waitFor(_ semaphore: DispatchSemaphore) async {
        let arrived = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 3) == .success)
            }
        }
        expect(arrived, "utility 센서 단계 진입")
    }

    private static func liveSelf() async {
        // 로컬 self 조회는 parser/CLI 경로의 증거다. 실제 peer 연결 검증은 아니다.
        let access = TailnetDeviceAccess()
        let result = await access.principal(for: source)
        guard case .success(let proof) = result else {
            try? await Task.sleep(for: .milliseconds(300))
            fatalError("읽기 전용 실제 CLI self 조회 실패 \(result)")
        }
        expect(proof.principal == .tailnet(userId: user, nodeStableId: "nRWmCkHUn621CNTRL"), "실제 로컬 CLI self identity")
        expect(access.isCurrent(proof, sourceIP: source), "실제 CLI proof 유효")
        access.stop()
        print("실제 읽기 전용 CLI self 조회 통과. peer TLS·기기 승인은 미검증")
    }
}
