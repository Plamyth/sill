import Foundation
import StreamProtocol
import os

struct MobileEnrollmentTime: Sendable {
    let milliseconds: Int64
    let uptime: TimeInterval
    static func epochMilliseconds(_ seconds: TimeInterval) -> Int64 {
        let raw = seconds * 1000
        guard raw.isFinite, raw >= 0, raw <= Double(MobileEnrollment.maximumSafeInteger) else { return -1 }
        return Int64(raw.rounded(.down))
    }
}

struct MobileEnrollmentDependencies: Sendable {
    var connect: @Sendable (String, TimeInterval) async throws -> any MobileEnrollmentTransport = {
        try await MobileEnrollmentSocket.open(path: $0, until: $1)
    }
    var clock: @Sendable () -> MobileEnrollmentTime = {
        MobileEnrollmentTime(milliseconds: MobileEnrollmentTime.epochMilliseconds(Date().timeIntervalSince1970),
                                    uptime: ProcessInfo.processInfo.systemUptime)
    }
    var sleep: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
    }
}

@MainActor
final class MobileEnrollmentHostRuntime {
    struct Observation: Sendable {
        let reason: MobileEnrollment.ActiveReason
        let checkedAtMilliseconds: Int64
    }
    typealias ObserveActive = @MainActor @Sendable (MobileEnrollment.ActiveChallenge) throws -> Observation
    private let identity: HostIdentity
    private let host: MobileEnrollment.HostProfile
    private let observeActive: ObserveActive
    private let currentRemoteAccess: @MainActor @Sendable () -> Bool
    private let dependencies: MobileEnrollmentDependencies
    private let commandPath: String
    private let history = MobileEnrollmentHistory()
    private var task: Task<Void, Never>?
    private var lifetime: MobileEnrollmentLifetime?

    init(identity: HostIdentity, host: MobileEnrollment.HostProfile,
         observeActive: @escaping ObserveActive,
         currentRemoteAccess: @escaping @MainActor @Sendable () -> Bool,
         commandPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexControlRoom/command.sock").path,
         dependencies: MobileEnrollmentDependencies = MobileEnrollmentDependencies()) {
        self.identity = identity; self.host = host; self.observeActive = observeActive
        self.currentRemoteAccess = currentRemoteAccess; self.commandPath = commandPath; self.dependencies = dependencies
    }

    func start() {
        guard task == nil, currentRemoteAccess() else { return }
        let lease = MobileEnrollmentLifetime()
        lifetime = lease
        let identity = identity, host = host, observe = observeActive, remote = currentRemoteAccess
        let dependencies = dependencies, path = commandPath, history = history
        task = Task.detached { [weak self] in
            var delay: TimeInterval = 0.25
            while !Task.isCancelled && !lease.isStopped {
                do {
                    try lease.check()
                    guard await remote() else { break }
                    let now = try history.time(dependencies.clock)
                    let transport = try await dependencies.connect(path, now.uptime + 5)
                    try lease.install(transport)
                    let channel = MobileEnrollmentChannel(identity: identity, host: host, observe: observe,
                        remote: remote, transport: transport, dependencies: dependencies, history: history, lifetime: lease)
                    defer { transport.invalidate(); lease.clear() }
                    try await channel.run()
                } catch {
                    if Task.isCancelled || lease.isStopped { break }
                    if let failure = error as? MobileEnrollmentRuntimeFailure {
                        switch failure {
                        case .unavailable: break
                        default: lease.stop(); break
                        }
                    } else { lease.stop() }
                    if lease.isStopped { break }
                }
                do {
                    try await dependencies.sleep(delay)
                    delay = min(30, delay * 2)
                }
                catch { break }
            }
            lease.stop()
            await self?.finished(lease)
        }
    }

    func stop() {
        lifetime?.stop()
        task?.cancel()
        task = nil; lifetime = nil
    }

    func remoteAccessChanged() { if !currentRemoteAccess() { stop() } }

    private func finished(_ lease: MobileEnrollmentLifetime) {
        guard lifetime === lease else { return }
        task = nil; lifetime = nil
    }

    deinit { lifetime?.stop(); task?.cancel() }
}

private final class MobileEnrollmentLifetime: Sendable {
    private struct State: Sendable {
        var stopped = false
        var transport: (any MobileEnrollmentTransport)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var isStopped: Bool { state.withLock { $0.stopped } }
    func check() throws {
        guard !isStopped, !Task.isCancelled else { throw MobileEnrollmentRuntimeFailure.stopped }
    }
    func install(_ value: any MobileEnrollmentTransport) throws {
        let installed = state.withLock { state in
            guard !state.stopped else { return false }
            state.transport = value
            return true
        }
        guard installed else {
            value.invalidate(); throw MobileEnrollmentRuntimeFailure.stopped
        }
    }
    func clear() {
        state.withLock { $0.transport = nil }
    }
    func stop() {
        let value = state.withLock { state in
            state.stopped = true
            let value = state.transport
            state.transport = nil
            return value
        }
        value?.invalidate()
    }
}

private final class MobileEnrollmentHistory: Sendable {
    private struct State: Sendable {
        var last: MobileEnrollmentTime?
        var lastGeneration: String?
        var lastHostNonce: String?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func time(_ clock: @Sendable () -> MobileEnrollmentTime) throws -> MobileEnrollmentTime {
        try state.withLock { state in
            let value = clock()
            guard value.milliseconds >= 0, value.milliseconds <= MobileEnrollment.maximumSafeInteger,
                  value.uptime.isFinite, value.uptime >= 0,
                  state.last.map({ value.milliseconds >= $0.milliseconds && value.uptime >= $0.uptime }) ?? true else {
                throw MobileEnrollmentRuntimeFailure.clockRollback
            }
            state.last = value; return value
        }
    }
    func host(_ value: MobileEnrollment.HostChallenge) throws {
        try state.withLock { state in
            guard value.coreGeneration != state.lastGeneration, value.nonce != state.lastHostNonce else {
                throw MobileEnrollmentRuntimeFailure.replay
            }
            state.lastGeneration = value.coreGeneration; state.lastHostNonce = value.nonce
        }
    }
}

private actor MobileEnrollmentChannel {
    private struct Pending {
        let challenge: MobileEnrollment.ActiveChallenge
        let uptimeDeadline: TimeInterval
    }
    private let identity: HostIdentity
    private let host: MobileEnrollment.HostProfile
    private let observe: MobileEnrollmentHostRuntime.ObserveActive
    private let remote: @MainActor @Sendable () -> Bool
    private let transport: any MobileEnrollmentTransport
    private let dependencies: MobileEnrollmentDependencies
    private let history: MobileEnrollmentHistory
    private let lifetime: MobileEnrollmentLifetime
    private var generation: String?
    private var hostNonce: String?
    private var usedRequests: [String: Int64] = [:]
    private var usedNonces: [String: Int64] = [:]
    private var buffer = Data()
    private var partialSince: TimeInterval?
    private var pending: [Pending] = []
    private var processing: Pending?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var failure: Error?
    private var handshakeDeadline: TimeInterval = 0

    init(identity: HostIdentity, host: MobileEnrollment.HostProfile,
         observe: @escaping MobileEnrollmentHostRuntime.ObserveActive,
         remote: @escaping @MainActor @Sendable () -> Bool,
         transport: any MobileEnrollmentTransport, dependencies: MobileEnrollmentDependencies,
         history: MobileEnrollmentHistory, lifetime: MobileEnrollmentLifetime) {
        self.identity = identity; self.host = host; self.observe = observe; self.remote = remote
        self.transport = transport; self.dependencies = dependencies; self.history = history; self.lifetime = lifetime
    }

    private func time() throws -> MobileEnrollmentTime { try history.time(dependencies.clock) }
    private func current() throws {
        try lifetime.check()
        if let failure { throw failure }
    }
    private func admitted() async throws {
        try current()
        guard await remote() else { throw MobileEnrollmentRuntimeFailure.stopped }
        try current()
    }
    private func close(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        timer?.cancel(); worker?.cancel()
        pending.removeAll(); buffer.removeAll()
        transport.invalidate()
    }

    func run() async throws {
        defer {
            timer?.cancel(); worker?.cancel(); transport.invalidate()
            pending.removeAll(); buffer.removeAll()
        }
        do {
            handshakeDeadline = try time().uptime + 5
            armTimer()
            try await write(MobileEnrollment.HostAttach(), until: handshakeDeadline)
            while true {
                try current()
                let now = try time()
                try checkDeadlines(now)
                let chunk = try await transport.receive(until: now.uptime + 0.25)
                try current()
                let received = try time()
                try checkDeadlines(received)
                guard let chunk else { try await admitted(); continue }
                guard !chunk.isEmpty else { throw MobileEnrollmentRuntimeFailure.unavailable }
                for byte in chunk {
                    if byte == 10 {
                        guard !buffer.isEmpty else { throw MobileEnrollmentRuntimeFailure.invalidFrame }
                        let frame = buffer; buffer.removeAll(keepingCapacity: true); partialSince = nil
                        try await accept(frame, at: received)
                    } else {
                        if buffer.isEmpty { partialSince = received.uptime }
                        guard buffer.count < 16_384 else { throw MobileEnrollmentRuntimeFailure.invalidFrame }
                        buffer.append(byte)
                    }
                }
            }
        } catch {
            let result = failure ?? error
            close(result)
            throw result
        }
    }

    private func accept(_ frame: Data, at received: MobileEnrollmentTime) async throws {
        try current()
        guard String(data: frame, encoding: .utf8) != nil else { throw MobileEnrollmentRuntimeFailure.invalidFrame }
        if generation == nil {
            let challenge = try MobileEnrollment.decodeHostChallenge(frame)
            try history.host(challenge)
            try await admitted()
            try await transport.checkPeer()
            try current(); try checkDeadlines(time())
            let response = try MobileEnrollmentSigner.hostIdentity(challenge, host: host, identity: identity)
            try await write(response, until: handshakeDeadline)
            generation = challenge.coreGeneration
            hostNonce = challenge.nonce
            armTimer()
            return
        }
        let challenge = try MobileEnrollment.decodeActiveChallenge(frame, receivedAtMilliseconds: received.milliseconds)
        guard challenge.coreGeneration == generation else { throw MobileEnrollmentRuntimeFailure.replay }
        guard pending.count + (processing == nil ? 0 : 1) < 32 else { throw MobileEnrollmentRuntimeFailure.capacity }
        usedRequests = usedRequests.filter { $0.value > received.milliseconds }
        usedNonces = usedNonces.filter { $0.value > received.milliseconds }
        guard usedRequests[challenge.requestId] == nil, usedNonces[challenge.nonce] == nil,
              challenge.nonce != hostNonce else { throw MobileEnrollmentRuntimeFailure.replay }
        guard usedRequests.count < 4096, usedNonces.count < 4096 else { throw MobileEnrollmentRuntimeFailure.capacity }
        usedRequests[challenge.requestId] = challenge.deadline
        usedNonces[challenge.nonce] = challenge.deadline
        pending.append(Pending(challenge: challenge,
            uptimeDeadline: received.uptime + Double(challenge.deadline - received.milliseconds) / 1000))
        armTimer()
        if worker == nil { worker = Task { await drain() } }
    }

    private func drain() async {
        do {
            while !pending.isEmpty {
                try current()
                let item = pending.removeFirst(); processing = item; armTimer()
                try await admitted()
                try await transport.checkPeer()
                try current(); try checkDeadlines(time())
                let observation = try await observe(item.challenge)
                try await admitted()
                let now = try time()
                try current(); try checkDeadlines(now)
                guard observation.checkedAtMilliseconds >= 0,
                      observation.checkedAtMilliseconds <= MobileEnrollment.maximumSafeInteger else {
                    throw MobileEnrollmentRuntimeFailure.invalidFrame
                }
                let expiry = min(item.challenge.deadline, observation.checkedAtMilliseconds + 2000)
                let payload = try MobileEnrollment.ActiveResultPayload(challenge: item.challenge, host: host,
                    reason: observation.reason, checkedAtMilliseconds: observation.checkedAtMilliseconds,
                    expiresAtMilliseconds: expiry, nowMilliseconds: now.milliseconds)
                let response = try MobileEnrollmentSigner.activeResult(payload, challenge: item.challenge, host: host,
                    identity: identity, nowMilliseconds: now.milliseconds)
                try await write(response, until: item.uptimeDeadline)
                processing = nil; armTimer()
            }
            worker = nil
        } catch { close(error) }
    }

    private func write<T: Encodable>(_ message: T, until deadline: TimeInterval) async throws {
        try await admitted()
        try await transport.checkPeer()
        let now = try time()
        try current(); try checkDeadlines(now)
        guard now.uptime < deadline else { throw MobileEnrollmentRuntimeFailure.expired }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(message)
        guard !bytes.isEmpty, bytes.count <= 16_384, !bytes.contains(10) else {
            throw MobileEnrollmentRuntimeFailure.invalidFrame
        }
        bytes.append(10)
        try await transport.send(bytes, until: deadline)
        try current(); try checkDeadlines(time())
    }

    private func checkDeadlines(_ now: MobileEnrollmentTime) throws {
        if generation == nil, now.uptime >= handshakeDeadline { throw MobileEnrollmentRuntimeFailure.expired }
        if let partialSince, now.uptime - partialSince >= 5 { throw MobileEnrollmentRuntimeFailure.expired }
        for item in pending + (processing.map { [$0] } ?? []) {
            guard now.uptime < item.uptimeDeadline, now.milliseconds < item.challenge.deadline else {
                throw MobileEnrollmentRuntimeFailure.expired
            }
        }
    }

    private func armTimer() {
        timer?.cancel(); timer = nil
        let deadlines = pending.map(\.uptimeDeadline) + (processing.map { [$0.uptimeDeadline] } ?? [])
            + (generation == nil ? [handshakeDeadline] : [])
        guard let deadline = deadlines.min() else { return }
        let dependencies = dependencies
        timer = Task {
            do {
                let now = try time()
                try await dependencies.sleep(max(0, deadline - now.uptime))
                try Task.checkCancellation()
                try checkDeadlines(time())
                armTimer()
            } catch is CancellationError { }
            catch { close(error) }
        }
    }
}
