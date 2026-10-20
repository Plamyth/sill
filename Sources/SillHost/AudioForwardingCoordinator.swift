import Foundation

@MainActor
final class AudioForwardingCoordinator {
    struct Scope: Equatable, Sendable {
        let binding: AudioForwardingBinding
        let intentId: UUID
        let intentRevision: AudioForwardingRevision
        let inputDesired: Bool
        let outputDesired: Bool

        init?(_ snapshot: AudioForwardingSnapshot) {
            guard let binding = snapshot.binding, binding.phase == .quiescing, let intent = snapshot.intent,
                  Set(binding.configuration.members.map(\.participantId)) == Set(LocalAudioParticipantID.allCases.map(\.rawValue)),
                  binding.configuration.members.count == LocalAudioParticipantID.allCases.count else { return nil }
            self.binding = binding
            intentId = intent.intentId; intentRevision = intent.intentRevision
            inputDesired = intent.inputDesired; outputDesired = intent.outputDesired
        }

        func matches(_ snapshot: AudioForwardingSnapshot, committed: Bool = false) -> Bool {
            guard let actual = snapshot.binding, let intent = snapshot.intent else { return false }
            let phase: AudioForwardingBinding.Phase = committed ? (inputDesired || outputDesired ? .active : .off) : .quiescing
            return actual.phase == phase && actual.pairedDeviceId == binding.pairedDeviceId &&
                actual.intentGeneration == binding.intentGeneration && actual.bindingEpoch == binding.bindingEpoch &&
                actual.transportId == binding.transportId && actual.transportKind == binding.transportKind &&
                actual.operationId == binding.operationId && actual.configuration == binding.configuration &&
                intent.intentId == intentId && intent.intentRevision == intentRevision &&
                intent.intentGeneration == binding.intentGeneration && intent.pairedDeviceId == binding.pairedDeviceId &&
                intent.inputDesired == inputDesired && intent.outputDesired == outputDesired &&
                intent.sentryDesired && intent.localMutedDesired
        }
    }

    struct ProtectionReadback: Equatable {
        let scope: Scope
        let observedAt: ContinuousClock.Instant
        let sentryVerified: Bool
        let localMutedVerified: Bool
    }

    struct Commit: Encodable {
        struct LocalProtection: Encodable {
            let sentryVerified: Bool
            let localMutedVerified: Bool
        }
        let intentGeneration: UUID
        let bindingEpoch: UUID
        let operationId: UUID
        let configuration: AudioForwardingConfiguration
        let receipts: [LocalAudioParticipantReceipt]
        let localProtection: LocalProtection

        fileprivate init(scope: Scope, receipts: [LocalAudioParticipantReceipt]) {
            intentGeneration = scope.binding.intentGeneration; bindingEpoch = scope.binding.bindingEpoch
            operationId = scope.binding.operationId; configuration = scope.binding.configuration
            self.receipts = receipts
            localProtection = .init(sentryVerified: true, localMutedVerified: true)
        }
    }

    enum Failure: Equatable, Sendable {
        case invalidScope, consumed, cancelled, stale, deadline, prepare, inspect, protection, commit
    }
    enum Outcome: Sendable {
        case waiting
        case committed(Scope, AudioForwardingSnapshot)
        case blocked(Failure)
    }
    struct Dependencies {
        let configuration: @MainActor () -> AudioForwardingConfiguration?
        let snapshot: @MainActor () async -> AudioForwardingSnapshot?
        let fence: @MainActor (Scope) -> Void
        let prepare: @MainActor (Scope, LocalAudioParticipantRequest) async -> LocalAudioParticipantReceipt?
        let inspect: @MainActor (Scope, LocalAudioParticipantRequest) async -> LocalAudioParticipantReceipt?
        let protection: @MainActor (Scope, ContinuousClock.Instant) async -> ProtectionReadback?
        let protectionCurrent: @MainActor (ProtectionReadback) -> Bool
        let commit: @MainActor (Commit) async -> AudioForwardingResult<AudioForwardingSnapshot>?
    }

    private final class Consumption: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
    private let dependencies: Dependencies
    private let budget: Duration
    private var seen: Set<UUID> = []
    private var scope: Scope?
    private var consumption: Consumption?
    private var work: Task<Outcome, Never>?
    private var drain: Task<Void, Never>?
    private var completed: Outcome?
    private var protection: ProtectionReadback?

    init(dependencies: Dependencies, budgetMilliseconds: Int = 25_000) {
        precondition((1...25_000).contains(budgetMilliseconds))
        self.dependencies = dependencies
        budget = .milliseconds(budgetMilliseconds)
    }

    func reconcile(_ snapshot: AudioForwardingSnapshot) async -> Outcome {
        guard !Task.isCancelled else { return .blocked(.cancelled) }
        if let scope, scope.matches(snapshot, committed: true), let work, let consumption {
            return await result(of: work, consumption: consumption)
        }
        if let scope, scope.matches(snapshot, committed: true), isCurrent(scope), let completed { return completed }
        guard let next = Scope(snapshot) else {
            invalidate()
            return snapshot.binding == nil ? .waiting : .blocked(.invalidScope)
        }
        if scope == next, let work, let consumption { return await result(of: work, consumption: consumption) }
        if scope == next, let completed {
            if case .committed = completed, !isCurrent(next) {
                invalidate()
                return .blocked(.protection)
            }
            return completed
        }
        guard !seen.contains(next.binding.bindingEpoch) else {
            if scope?.binding.bindingEpoch == next.binding.bindingEpoch { invalidate() }
            return .blocked(.consumed)
        }
        let previous = work
        invalidate()
        seen.insert(next.binding.bindingEpoch)
        scope = next
        let token = Consumption()
        consumption = token
        dependencies.fence(next)
        let deadline = ContinuousClock.now.advanced(by: budget)
        let task = Task { @MainActor in
            if let previous { _ = await previous.value }
            if let drain = self.drain { await drain.value }
            return await self.consume(next, token: token, deadline: deadline)
        }
        work = task
        let outcome = await result(of: task, consumption: token)
        if consumption === token {
            work = nil
            completed = outcome
            if case .blocked = outcome { dependencies.fence(next); protection = nil }
        }
        return outcome
    }

    func invalidate() {
        consumption?.cancel()
        if let scope { dependencies.fence(scope) }
        consumption = nil; scope = nil; completed = nil; protection = nil
    }

    func isCurrent(_ candidate: Scope) -> Bool {
        guard let proof = protection, dependencies.protectionCurrent(proof) else { return false }
        let configuration = dependencies.configuration()
        guard scope == candidate, let consumption, !consumption.isCancelled,
              configuration == candidate.binding.configuration, protection == proof,
              proof.scope == candidate else { return false }
        if case .committed = completed { return true }
        return false
    }

    func allowsInput(_ candidate: Scope, transport: AudioForwardingTransport) -> Bool {
        candidate.binding.transportKind == transport && candidate.inputDesired && isCurrent(candidate)
    }

    func allowsOutput(_ candidate: Scope, transport: AudioForwardingTransport) -> Bool {
        candidate.binding.transportKind == transport && candidate.outputDesired && isCurrent(candidate)
    }

    private func result(of task: Task<Outcome, Never>, consumption: Consumption) async -> Outcome {
        await withTaskCancellationHandler {
            let outcome = await task.value
            return Task.isCancelled || consumption.isCancelled ? .blocked(.cancelled) : outcome
        } onCancel: { consumption.cancel() }
    }

    private func owns(_ scope: Scope, token: Consumption, deadline: ContinuousClock.Instant) -> Bool {
        let configuration = dependencies.configuration()
        return self.scope == scope && consumption === token && !token.isCancelled && !Task.isCancelled &&
            ContinuousClock.now < deadline && configuration == scope.binding.configuration
    }

    private func call<Value>(until deadline: ContinuousClock.Instant,
                             operation: @escaping @MainActor () async -> Value) async -> Value? {
        let operationTask = Task { @MainActor in await operation() }
        drain = Task { @MainActor in _ = await operationTask.value }
        return await LocalAudioCompletion<Value>.wait(until: deadline) { await operationTask.value }
    }

    private func current(_ scope: Scope, token: Consumption, deadline: ContinuousClock.Instant, committed: Bool = false) async -> Bool {
        guard owns(scope, token: token, deadline: deadline),
              let value = await call(until: deadline, operation: {
                  guard self.owns(scope, token: token, deadline: deadline) else { return nil as AudioForwardingSnapshot? }
                  return await self.dependencies.snapshot()
              }), let value else { return false }
        return owns(scope, token: token, deadline: deadline) && scope.matches(value, committed: committed)
    }

    private func consume(_ scope: Scope, token: Consumption, deadline: ContinuousClock.Instant) async -> Outcome {
        guard await current(scope, token: token, deadline: deadline) else { return .blocked(.stale) }
        var requests: [LocalAudioParticipantRequest] = []
        for participant in LocalAudioParticipantID.allCases {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = Int(remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000)
            guard owns(scope, token: token, deadline: deadline),
                  let request = scope.binding.participantRequest(for: participant, budgetMilliseconds: min(5000, milliseconds)) else {
                return .blocked(.deadline)
            }
            guard let receipt = await call(until: deadline, operation: {
                guard self.owns(scope, token: token, deadline: deadline) else { return nil as LocalAudioParticipantReceipt? }
                return await self.dependencies.prepare(scope, request)
            }), let receipt, receipt.proves(request) else { return .blocked(.prepare) }
            guard await current(scope, token: token, deadline: deadline) else { return .blocked(.stale) }
            requests.append(request)
        }
        var receipts: [LocalAudioParticipantReceipt] = []
        for request in requests {
            guard let receipt = await call(until: deadline, operation: {
                guard self.owns(scope, token: token, deadline: deadline) else { return nil as LocalAudioParticipantReceipt? }
                return await self.dependencies.inspect(scope, request)
            }), let receipt, receipt.proves(request) else { return .blocked(.inspect) }
            guard await current(scope, token: token, deadline: deadline) else { return .blocked(.stale) }
            receipts.append(receipt)
        }
        let requestedAt = ContinuousClock.now
        guard let readback = await call(until: deadline, operation: {
            guard self.owns(scope, token: token, deadline: deadline) else { return nil as ProtectionReadback? }
            return await self.dependencies.protection(scope, deadline)
        }), let readback, readback.scope == scope, readback.observedAt >= requestedAt,
              readback.observedAt <= ContinuousClock.now, readback.sentryVerified, readback.localMutedVerified,
              dependencies.protectionCurrent(readback) else { return .blocked(.protection) }
        guard await current(scope, token: token, deadline: deadline), dependencies.protectionCurrent(readback) else {
            return .blocked(.stale)
        }
        guard let response = await call(until: deadline, operation: {
            guard self.dependencies.protectionCurrent(readback), self.owns(scope, token: token, deadline: deadline) else {
                return nil as AudioForwardingResult<AudioForwardingSnapshot>?
            }
            return await self.dependencies.commit(Commit(scope: scope, receipts: receipts))
        }), let response, case .accepted(let committed) = response,
              owns(scope, token: token, deadline: deadline), scope.matches(committed, committed: true),
              dependencies.protectionCurrent(readback) else { return .blocked(.commit) }
        guard await current(scope, token: token, deadline: deadline, committed: true),
              dependencies.protectionCurrent(readback) else { return .blocked(.stale) }
        protection = readback
        return .committed(scope, committed)
    }
}
