import Foundation
import Darwin

/// 네트워크/로그 큐에서 await한다. CLI 대기는 전용 utility 큐에서만 수행한다.
/// 인스턴스당 진행 중인 조회와 자식 프로세스는 각각 최대 하나다.
final class TailnetDeviceAccess: @unchecked Sendable {
    enum Failure: Error, Equatable, Sendable {
        case invalidSource, busy, stopped, cancelled, deadlineExceeded
        case sensorFailure, outputLimit, malformedEvidence, backendNotRunning
        case snapshotChanged, differentUser, unauthorizedNode, expiredNode, addressMismatch
    }

    struct Proof: Sendable {
        let principal: AutomaticDevicePrincipal
        let sourceIP: String
        let localIPs: [String]
        let nodeExpiry: Date
        let validUntil: Date
        fileprivate let issuer: UUID
        fileprivate let deadline: UInt64
    }

    enum Command: Equatable, Sendable {
        case status
        case whois(String)

        var arguments: [String] {
            switch self {
            case .status: return ["status", "--json"]
            case .whois(let ip): return ["whois", "--json", ip]
            }
        }
    }

    typealias Check = @Sendable () throws -> Void
    typealias Read = @Sendable (Command, Check) throws -> Data
    private typealias Outcome = Result<Proof, Failure>
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "sill.tailnet-device-access", qos: .utility)
    private let issuer = UUID()
    private let read: Read
    private var stopped = false
    private var active: Attempt?
    static let outputLimit = 512 * 1024

    init() { read = { command, check in try Self.readCLI(command, check) } }

    #if AUTOMATIC_DEVICE_ACCESS_CONTRACT
    /// 계약 검사만 가짜 센서 결과를 주입한다. 생산 초기화는 고정 CLI를 사용한다.
    init(testingRead: @escaping Read) { read = testingRead }
    #endif

    func principal(for sourceIP: String) async -> Result<Proof, Failure> {
        guard let ip = Self.numericSource(sourceIP) else { return .failure(.invalidSource) }
        let attempt = Attempt()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attempt.attach(continuation)
                start(attempt, ip: ip)
            }
        } onCancel: {
            attempt.finish(.failure(.cancelled))
        }
    }

    /// Door 종료 시 호출한다. 진행 중인 결과와 발급된 짧은 proof를 모두 무효화한다.
    func stop() {
        lock.lock()
        stopped = true
        let attempt = active
        lock.unlock()
        attempt?.finish(.failure(.stopped))
    }

    /// 부모는 원래 소켓/연결 세대도 대조해야 한다. 재연결에 proof를 저장·재사용하지 않는다.
    func isCurrent(_ proof: Proof, sourceIP: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && proof.issuer == issuer && Self.numericSource(sourceIP) == proof.sourceIP
            && DispatchTime.now().uptimeNanoseconds < proof.deadline && Date() < proof.validUntil
    }

    private func start(_ attempt: Attempt, ip: String) {
        lock.lock()
        if stopped {
            lock.unlock()
            attempt.finish(.failure(.stopped))
            return
        }
        guard active == nil else {
            lock.unlock()
            attempt.finish(.failure(.busy))
            return
        }
        active = attempt
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .init(uptimeNanoseconds: attempt.deadline)) {
            attempt.finish(.failure(.deadlineExceeded))
        }
        queue.async { [self] in
            defer {
                lock.lock()
                active = nil
                lock.unlock()
            }
            do {
                let check: Check = { try attempt.check() }
                try check()
                let before = try Self.decode(Status.self, read(.status, check))
                try before.validate()
                try check()
                let who = try Self.decode(WhoIs.self, read(.whois(ip), check))
                try check()
                let after = try Self.decode(Status.self, read(.status, check))
                try after.validate()
                guard before == after else { throw Failure.snapshotChanged }
                let expiry = try who.validate(source: ip, user: before.selfNode.UserID)
                try check()
                let until = min(Date().addingTimeInterval(2), expiry)
                let proof = Proof(principal: .tailnet(userId: who.Node.User, nodeStableId: who.Node.StableID),
                                  sourceIP: ip, localIPs: before.selfNode.TailscaleIPs.compactMap(Self.numericSource),
                                  nodeExpiry: expiry, validUntil: until, issuer: issuer,
                                  deadline: min(attempt.deadline, DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
                lock.lock()
                let wasStopped = stopped
                lock.unlock()
                attempt.finish(wasStopped ? .failure(.stopped) : .success(proof))
            } catch let failure as Failure {
                attempt.finish(.failure(failure))
            } catch {
                attempt.finish(.failure(.sensorFailure))
            }
        }
    }

    private static func numericSource(_ value: String) -> String? {
        guard value.utf8.count <= 64, !value.contains(where: { "[]%/".contains($0) }),
              let bytes = IPBytes.parse(value), !IPBytes.isLoopback(bytes) else { return nil }
        let overlay = IPBytes.isCarrierShared(bytes) || IPBytes.contains(
            network: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + [UInt8](repeating: 0, count: 10),
            bits: 48, address: bytes)
        return overlay ? IPBytes.text(bytes) : nil
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= outputLimit else { throw Failure.outputLimit }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw Failure.malformedEvidence }
    }

    private struct Status: Decodable, Equatable {
        struct LocalNode: Decodable, Equatable {
            let ID: String
            let UserID: UInt64
            let TailscaleIPs: [String]
            let Expired: Bool?
        }
        let BackendState: String
        let selfNode: LocalNode
        enum CodingKeys: String, CodingKey { case BackendState; case selfNode = "Self" }

        func validate() throws {
            guard BackendState == "Running" else { throw Failure.backendNotRunning }
            guard TailnetDeviceAccess.validID(selfNode.ID), selfNode.UserID > 0 else { throw Failure.malformedEvidence }
            guard selfNode.Expired != true else { throw Failure.expiredNode }
            let ips = selfNode.TailscaleIPs.compactMap(TailnetDeviceAccess.numericSource)
            guard !ips.isEmpty, ips.count <= 8, ips.count == selfNode.TailscaleIPs.count,
                  Set(ips).count == ips.count else { throw Failure.malformedEvidence }
        }
    }

    private struct WhoIs: Decodable {
        struct UserProfileValue: Decodable { let ID: UInt64 }
        struct NodeValue: Decodable {
            let StableID: String
            let User: UInt64
            let MachineAuthorized: Bool
            let Addresses: [String]
            let KeyExpiry: String
            let Expired: Bool?
            let Sharer: UInt64?
            let Tags: [String]?
            let UnsignedPeerAPIOnly: Bool?
            let IsJailed: Bool?
            let IsWireGuardOnly: Bool?
        }
        let Node: NodeValue
        let UserProfile: UserProfileValue

        func validate(source: String, user: UInt64) throws -> Date {
            guard Node.User == user, UserProfile.ID == user else { throw Failure.differentUser }
            guard Node.MachineAuthorized, TailnetDeviceAccess.validID(Node.StableID),
                  (Node.Sharer ?? 0) == 0, (Node.Tags ?? []).isEmpty,
                  Node.UnsignedPeerAPIOnly != true, Node.IsJailed != true,
                  Node.IsWireGuardOnly != true else { throw Failure.unauthorizedNode }
            guard Node.Expired != true else { throw Failure.expiredNode }
            // 공식 tailcfg.Node와 expiryManager에서 zero time은 만료 비활성이다.
            // 필드 자체가 없거나 null이면 이 계약은 안전하게 미발급한다.
            let expiry: Date
            if Node.KeyExpiry == "0001-01-01T00:00:00Z" { expiry = .distantFuture }
            else {
                let grammar = "\\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]{1,9})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])\\z"
                guard Node.KeyExpiry.utf8.count <= 40,
                      Node.KeyExpiry.range(of: grammar, options: .regularExpression) != nil else {
                    throw Failure.malformedEvidence
                }
                let civil = DateFormatter()
                civil.locale = Locale(identifier: "en_US_POSIX")
                civil.calendar = Calendar(identifier: .gregorian)
                civil.timeZone = TimeZone(secondsFromGMT: 0)
                civil.dateFormat = "yyyy-MM-dd"
                civil.isLenient = false
                guard civil.date(from: String(Node.KeyExpiry.prefix(10))) != nil else { throw Failure.malformedEvidence }
                let format = ISO8601DateFormatter()
                format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fractional = format.date(from: Node.KeyExpiry)
                format.formatOptions = [.withInternetDateTime]
                guard let parsed = fractional ?? format.date(from: Node.KeyExpiry), parsed.timeIntervalSince1970 > 0 else {
                    throw Failure.malformedEvidence
                }
                expiry = parsed
            }
            guard expiry > Date() else { throw Failure.expiredNode }
            var matched = false
            guard !Node.Addresses.isEmpty, Node.Addresses.count <= 32 else { throw Failure.addressMismatch }
            for prefix in Node.Addresses {
                let parts = prefix.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, let ip = TailnetDeviceAccess.numericSource(String(parts[0])),
                      let bytes = IPBytes.parse(String(parts[0])),
                      parts[1] == (bytes.count == 4 ? "32" : "128") else { throw Failure.addressMismatch }
                matched = matched || ip == source
            }
            guard matched else { throw Failure.addressMismatch }
            return expiry
        }
    }

    private final class Attempt: @unchecked Sendable {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        private let lock = NSLock()
        private var result: Outcome?
        private var continuation: CheckedContinuation<Outcome, Never>?

        func attach(_ continuation: CheckedContinuation<Outcome, Never>) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(returning: result) }
            else { self.continuation = continuation; lock.unlock() }
        }

        func finish(_ outcome: Outcome) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            let accepted: Outcome = DispatchTime.now().uptimeNanoseconds >= deadline
                ? .failure(.deadlineExceeded) : outcome
            result = accepted
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: accepted)
        }

        func check() throws {
            lock.lock()
            let current = result
            lock.unlock()
            if case .failure(let failure) = current { throw failure }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.deadlineExceeded }
        }
    }

    /// CLI wrapper가 띄운 자식까지 전용 프로세스 그룹에 둔다. 다른 작업의 그룹은 건드리지 않는다.
    private static func readCLI(_ command: Command, _ check: Check) throws -> Data {
        try check()
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Failure.sensorFailure }
        defer { close(descriptors[0]); close(descriptors[1]) }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else { throw Failure.sensorFailure }
        for fd in descriptors {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.sensorFailure }
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.sensorFailure }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0 else { throw Failure.sensorFailure }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.sensorFailure }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw Failure.sensorFailure }
        let executable = "/usr/local/bin/tailscale"
        let argv = ([executable] + command.arguments).map { strdup($0) } + [nil]
        let environment = ["PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C", "HOME=" + NSHomeDirectory()]
        let envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes,
                            UnsafeMutablePointer(mutating: args.baseAddress!),
                            UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard spawned == 0 else { throw Failure.sensorFailure }
        var reaped = false
        var status: Int32 = 0
        defer {
            if !reaped {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try check()
            let count = Darwin.read(descriptors[0], &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= outputLimit else { throw Failure.outputLimit }
                output.append(contentsOf: buffer.prefix(count))
                continue
            }
            guard count == 0 || errno == EAGAIN || errno == EINTR else { throw Failure.sensorFailure }
            if !reaped {
                let exited = waitpid(pid, &status, WNOHANG)
                if exited == pid { reaped = true }
                else if exited < 0 && errno != EINTR { throw Failure.sensorFailure }
            }
            if reaped {
                // 자식 종료 후 남은 pipe 바이트까지 읽고 JSON을 해석한다.
                let remaining = Darwin.read(descriptors[0], &buffer, buffer.count)
                if remaining > 0 {
                    guard output.count + remaining <= outputLimit else { throw Failure.outputLimit }
                    output.append(contentsOf: buffer.prefix(remaining))
                    continue
                }
                guard status == 0 else { throw Failure.sensorFailure }
                return output
            }
            usleep(5_000)
        }
    }
}
