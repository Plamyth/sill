import Foundation

enum LocalAudioParticipantID: String, Codable, CaseIterable { case native = "native.sill", relay = "s23.audio.relay" }

struct LocalAudioParticipantRequest: Codable, Equatable {
    let schemaVersion: Int
    let operationId: UUID
    let privacyGeneration: UUID
    let registryRevision: String
    let participantId: LocalAudioParticipantID
    let bootId: UUID
    let budgetMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion, operationId, privacyGeneration, registryRevision, participantId, bootId, budgetMilliseconds
    }
    init(schemaVersion: Int, operationId: UUID, privacyGeneration: UUID, registryRevision: String,
         participantId: LocalAudioParticipantID, bootId: UUID, budgetMilliseconds: Int) {
        self.schemaVersion = schemaVersion; self.operationId = operationId; self.privacyGeneration = privacyGeneration
        self.registryRevision = registryRevision; self.participantId = participantId; self.bootId = bootId
        self.budgetMilliseconds = budgetMilliseconds
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            operationId: try c.decode(UUID.self, forKey: .operationId),
            privacyGeneration: try c.decode(UUID.self, forKey: .privacyGeneration),
            registryRevision: try c.decode(String.self, forKey: .registryRevision),
            participantId: try c.decode(LocalAudioParticipantID.self, forKey: .participantId),
            bootId: try c.decode(UUID.self, forKey: .bootId), budgetMilliseconds: try c.decode(Int.self, forKey: .budgetMilliseconds))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid v1 participant request"))
        }
    }

    var isValid: Bool {
        schemaVersion == 1 && (1...30_000).contains(budgetMilliseconds) &&
        UInt64(registryRevision).map { String($0) == registryRevision } == true
    }
}

struct LocalAudioParticipantFacts: Codable, Equatable {
    let admissionFenced: Bool?
    let startsSettled: Bool?
    let mediaDetached: Bool?
    let callbacksDrained: Bool?
    let buffersEmpty: Bool?
    let workersExited: Bool?
    var quiescent: Bool {
        [admissionFenced, startsSettled, mediaDetached, callbacksDrained, buffersEmpty, workersExited].allSatisfy { $0 == true }
    }
    static let unknown = Self(admissionFenced: nil, startsSettled: nil, mediaDetached: nil,
                              callbacksDrained: nil, buffersEmpty: nil, workersExited: nil)

    private struct FactKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case admissionFenced, startsSettled, mediaDetached, callbacksDrained, buffersEmpty, workersExited
    }
    init(admissionFenced: Bool?, startsSettled: Bool?, mediaDetached: Bool?, callbacksDrained: Bool?, buffersEmpty: Bool?, workersExited: Bool?) {
        self.admissionFenced = admissionFenced; self.startsSettled = startsSettled; self.mediaDetached = mediaDetached
        self.callbacksDrained = callbacksDrained; self.buffersEmpty = buffersEmpty; self.workersExited = workersExited
    }
    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: FactKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected exactly six facts"))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        admissionFenced = try c.decodeIfPresent(Bool.self, forKey: .admissionFenced)
        startsSettled = try c.decodeIfPresent(Bool.self, forKey: .startsSettled)
        mediaDetached = try c.decodeIfPresent(Bool.self, forKey: .mediaDetached)
        callbacksDrained = try c.decodeIfPresent(Bool.self, forKey: .callbacksDrained)
        buffersEmpty = try c.decodeIfPresent(Bool.self, forKey: .buffersEmpty)
        workersExited = try c.decodeIfPresent(Bool.self, forKey: .workersExited)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(admissionFenced, forKey: .admissionFenced); try c.encode(startsSettled, forKey: .startsSettled)
        try c.encode(mediaDetached, forKey: .mediaDetached); try c.encode(callbacksDrained, forKey: .callbacksDrained)
        try c.encode(buffersEmpty, forKey: .buffersEmpty); try c.encode(workersExited, forKey: .workersExited)
    }
}

struct LocalAudioParticipantReceipt: Codable, Equatable {
    enum State: String, Codable { case pending, quiescent, blocked, unknown }
    let schemaVersion: Int
    let operationId: UUID
    let privacyGeneration: UUID
    let registryRevision: String
    let participantId: LocalAudioParticipantID
    let bootId: UUID
    let state: State
    let facts: LocalAudioParticipantFacts
    let reason: String?

    init(_ request: LocalAudioParticipantRequest, state: State, facts: LocalAudioParticipantFacts, reason: String? = nil) {
        schemaVersion = request.schemaVersion; operationId = request.operationId; privacyGeneration = request.privacyGeneration
        registryRevision = request.registryRevision; participantId = request.participantId; bootId = request.bootId
        self.state = state; self.facts = facts; self.reason = reason
    }
    func proves(_ request: LocalAudioParticipantRequest) -> Bool {
        request.isValid && schemaVersion == 1 && operationId == request.operationId && privacyGeneration == request.privacyGeneration &&
        registryRevision == request.registryRevision && participantId == request.participantId && bootId == request.bootId &&
        state == .quiescent && facts.quiescent
    }
}

@MainActor
final class LocalAudioCompletion<Value> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var completed = false
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    static func wait(until deadline: ContinuousClock.Instant, operation: @escaping @MainActor () async -> Value) async -> Value? {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        let completion = LocalAudioCompletion<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.continuation = continuation
                completion.worker = Task { completion.finish(await operation()) }
                completion.timer = Task {
                    try? await ContinuousClock().sleep(until: deadline)
                    if !Task.isCancelled { completion.finish(nil) }
                }
            }
        } onCancel: { Task { @MainActor in completion.finish(nil) } }
    }
    private func finish(_ value: Value?) {
        guard !completed else { return }
        completed = true
        let pending = continuation; continuation = nil
        worker?.cancel(); worker = nil
        timer?.cancel(); timer = nil
        pending?.resume(returning: value)
    }
}

@MainActor
final class LocalAudioParticipantRegistry {
    enum MembershipChange { case willChange, didChange }
    var membershipChanged: (@MainActor (MembershipChange) -> Void)?

    struct ForwardingPreparation {
        let intentGeneration: UUID
        let bindingEpoch: UUID
        let request: LocalAudioParticipantRequest
    }
    struct Control {
        let fenceAndQuiesce: @MainActor (LocalAudioParticipantRequest) async -> LocalAudioParticipantReceipt
        let inspect: @MainActor (UUID) async -> LocalAudioParticipantReceipt?
        let supportsForwarding: Bool
        let forwardingPrepare: (@MainActor (ForwardingPreparation) async -> LocalAudioParticipantReceipt?)?
        init(fenceAndQuiesce: @escaping @MainActor (LocalAudioParticipantRequest) async -> LocalAudioParticipantReceipt,
             inspect: @escaping @MainActor (UUID) async -> LocalAudioParticipantReceipt?, supportsForwarding: Bool = false,
             forwardingPrepare: (@MainActor (ForwardingPreparation) async -> LocalAudioParticipantReceipt?)? = nil) {
            self.fenceAndQuiesce = fenceAndQuiesce; self.inspect = inspect; self.supportsForwarding = supportsForwarding
            self.forwardingPrepare = forwardingPrepare
        }
    }
    struct Snapshot: Equatable {
        let revision: UInt64
        let boots: [LocalAudioParticipantID: UUID]
    }
    private struct Member { let boot: UUID; let control: Control }
    private struct Operation {
        let id: UUID
        let generation: UUID
        let snapshot: Snapshot
        let budget: Int
        let deadline: ContinuousClock.Instant
        let requests: [LocalAudioParticipantRequest]
        var result: Task<Bool, Never>?
        var uncertain = false
        var inspected = false
        var closed = false
    }
    struct LocalReturnTicket: Equatable {
        fileprivate let id: UUID
        fileprivate let operationId: UUID
        fileprivate let generation: UUID
        fileprivate let membership: Snapshot
    }
    struct ForwardingTicket: Equatable {
        fileprivate let id: UUID
        fileprivate let epoch: UUID
        fileprivate let intentGeneration: UUID
        fileprivate let operationId: UUID
        fileprivate let generation: UUID
        fileprivate let membership: Snapshot
        fileprivate let identity: [String]
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
    private final class Preparation {
        let request: LocalAudioParticipantRequest
        var task: Task<LocalAudioParticipantReceipt?, Never>?
        var ready = false
        init(_ request: LocalAudioParticipantRequest) { self.request = request }
    }
    private final class Forwarding {
        let ticket: ForwardingTicket
        let cancellation = Cancellation()
        var preparations: [LocalAudioParticipantID: Preparation] = [:]
        init(_ ticket: ForwardingTicket) { self.ticket = ticket }
    }
    private var localReturn: LocalReturnTicket?
    private var forwarding: Forwarding?
    private var consumedEpochs: Set<UUID> = []
    private var tail: Task<Void, Never>?
    private var pendingCalls = 0
    private var members: [LocalAudioParticipantID: Member] = [:]
    private var revision: UInt64 = 0
    private var operation: Operation?
    private(set) var isFenced = false

    var snapshot: Snapshot { Snapshot(revision: revision, boots: members.mapValues(\.boot)) }
    var available: Bool { Set(members.keys) == Set(LocalAudioParticipantID.allCases) && revision < UInt64.max }
    var unavailableReason: String? {
        if isFenced { return "로컬 복귀 경계가 유지되고 있습니다. 인증된 오디오 재개 연결은 아직 지원되지 않습니다." }
        return available ? nil : "S23를 포함한 전체 오디오 참여자의 인증된 중지 연결이 없어 로컬 복귀를 사용할 수 없습니다."
    }
    private var forwardingCapable: Bool { available && members.values.allSatisfy { $0.control.supportsForwarding && $0.control.forwardingPrepare != nil } }
    var authenticatedLocalReturnUnavailableReason: String? {
        guard available else { return unavailableReason }
        if localReturn != nil || operation?.closed == false { return "이전 로컬 복귀 작업을 정리하고 있습니다." }
        if operation?.uncertain == true { return "이전 로컬 복귀의 실제 종료를 확인할 수 없습니다." }
        if pendingCalls > 0 { return "이전 오디오 중지 작업의 실제 종료를 기다리고 있습니다." }
        if isFenced && !forwardingCapable { return unavailableReason }
        return nil
    }

    func register(_ id: LocalAudioParticipantID, bootId: UUID, control: Control) {
        guard revision < UInt64.max else { return }
        invalidateForwarding()
        membershipChanged?(.willChange)
        revision += 1
        members[id] = Member(boot: bootId, control: control)
        membershipChanged?(.didChange)
    }
    func unregister(_ id: LocalAudioParticipantID) {
        guard revision < UInt64.max else { return }
        invalidateForwarding()
        membershipChanged?(.willChange)
        revision += 1; members.removeValue(forKey: id)
        membershipChanged?(.didChange)
    }
    func matches(_ frozen: Snapshot) -> Bool { available && snapshot == frozen }

    func beginLocalReturn(operationId: UUID, privacyGeneration: UUID, membership: Snapshot) -> LocalReturnTicket? {
        guard authenticatedLocalReturnUnavailableReason == nil, matches(membership), !Task.isCancelled else { return nil }
        invalidateForwarding()
        let ticket = LocalReturnTicket(id: UUID(), operationId: operationId, generation: privacyGeneration, membership: membership)
        localReturn = ticket
        return ticket
    }

    func endLocalReturn(_ ticket: LocalReturnTicket) {
        guard localReturn == ticket else { return }
        if operation?.id == ticket.operationId {
            if pendingCalls > 0 { operation?.uncertain = true }
            operation?.closed = true
        }
        localReturn = nil
    }

    func beginForwarding(epoch: UUID, intentGeneration: UUID, operationId: UUID, privacyGeneration: UUID,
                         membership: Snapshot, identity: [String]) -> ForwardingTicket? {
        guard localReturn == nil, operation?.closed != false, operation?.uncertain != true,
              forwardingCapable, matches(membership), !Task.isCancelled else { return nil }
        if let current = forwarding, current.ticket.epoch == epoch {
            let ticket = current.ticket
            return !current.cancellation.isCancelled && ticket.intentGeneration == intentGeneration && ticket.operationId == operationId &&
                ticket.generation == privacyGeneration && ticket.membership == membership && ticket.identity == identity ? ticket : nil
        }
        guard !consumedEpochs.contains(epoch) else { return nil }
        invalidateForwarding()
        consumedEpochs.insert(epoch)
        let ticket = ForwardingTicket(id: UUID(), epoch: epoch, intentGeneration: intentGeneration, operationId: operationId,
                                      generation: privacyGeneration, membership: membership, identity: identity)
        forwarding = Forwarding(ticket)
        isFenced = true
        return ticket
    }

    func cancelForwarding(_ ticket: ForwardingTicket) {
        if forwarding?.ticket == ticket { invalidateForwarding() }
    }

    private func invalidateForwarding() {
        forwarding?.cancellation.cancel()
        forwarding = nil
    }

    private func owns(_ work: Forwarding) -> Bool {
        forwarding === work && !work.cancellation.isCancelled && localReturn == nil &&
        operation?.closed != false && operation?.uncertain != true && matches(work.ticket.membership)
    }

    private func matches(_ request: LocalAudioParticipantRequest, ticket: ForwardingTicket) -> Bool {
        request.isValid && request.operationId == ticket.operationId && request.privacyGeneration == ticket.generation &&
        request.registryRevision == String(ticket.membership.revision) && ticket.membership.boots[request.participantId] == request.bootId
    }

    private func sameRequest(_ first: LocalAudioParticipantRequest, _ second: LocalAudioParticipantRequest) -> Bool {
        first.schemaVersion == second.schemaVersion && first.operationId == second.operationId &&
        first.privacyGeneration == second.privacyGeneration && first.registryRevision == second.registryRevision &&
        first.participantId == second.participantId && first.bootId == second.bootId
    }

    func requestIsCurrent(_ request: LocalAudioParticipantRequest) -> Bool {
        guard request.isValid, !Task.isCancelled else { return false }
        if let operation, !operation.closed, !operation.uncertain, matches(operation.snapshot),
           operation.requests.contains(where: { sameRequest($0, request) }) { return true }
        guard let work = forwarding, owns(work), matches(request, ticket: work.ticket),
              let prepared = work.preparations[request.participantId] else { return false }
        return sameRequest(prepared.request, request)
    }

    private func serialized<Value>(until deadline: ContinuousClock.Instant, allowed: @escaping @MainActor () -> Bool,
                                   operation: @escaping @MainActor () async -> Value) async -> Value? {
        let previous = tail
        pendingCalls += 1
        let task = Task { @MainActor () -> Value? in
            defer { self.pendingCalls -= 1 }
            if let previous { await previous.value }
            guard ContinuousClock.now < deadline, allowed() else { return nil }
            return await operation()
        }
        tail = Task { @MainActor in _ = await task.value }
        guard let value = await LocalAudioCompletion<Value?>.wait(until: deadline, operation: { await task.value }),
              ContinuousClock.now < deadline, allowed() else { return nil }
        return value
    }

    private func forwardingResult(_ task: Task<LocalAudioParticipantReceipt?, Never>, work: Forwarding,
                                  until deadline: ContinuousClock.Instant) async -> LocalAudioParticipantReceipt? {
        let cancellation = work.cancellation
        return await withTaskCancellationHandler {
            guard let value = await LocalAudioCompletion<LocalAudioParticipantReceipt?>.wait(until: deadline, operation: {
                await task.value
            }), let value, !Task.isCancelled, ContinuousClock.now < deadline, owns(work) else {
                work.cancellation.cancel()
                return nil
            }
            return value
        } onCancel: { cancellation.cancel() }
    }

    func prepareForwarding(_ ticket: ForwardingTicket, request: LocalAudioParticipantRequest,
                           until deadline: ContinuousClock.Instant) async -> LocalAudioParticipantReceipt? {
        guard let work = forwarding, work.ticket == ticket, owns(work), matches(request, ticket: ticket),
              ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
        if let existing = work.preparations[request.participantId] {
            guard sameRequest(existing.request, request), let task = existing.task else { return nil }
            return await forwardingResult(task, work: work, until: deadline)
        }
        guard let prepare = members[request.participantId]?.control.forwardingPrepare else { return nil }
        let preparation = Preparation(request)
        work.preparations[request.participantId] = preparation
        let stopDeadline = min(deadline, ContinuousClock.now.advanced(by: .milliseconds(request.budgetMilliseconds)))
        let task = Task { @MainActor () -> LocalAudioParticipantReceipt? in
            guard let result = await self.serialized(until: stopDeadline, allowed: {
                self.owns(work) && self.requestIsCurrent(request)
            }, operation: { await prepare(ForwardingPreparation(intentGeneration: ticket.intentGeneration,
                bindingEpoch: ticket.epoch, request: request)) }), let receipt = result, receipt.proves(request),
                  self.owns(work), self.requestIsCurrent(request) else { return nil }
            preparation.ready = true
            return receipt
        }
        preparation.task = task
        return await forwardingResult(task, work: work, until: deadline)
    }

    func inspectForwarding(_ ticket: ForwardingTicket, request: LocalAudioParticipantRequest,
                           until deadline: ContinuousClock.Instant) async -> LocalAudioParticipantReceipt? {
        guard let work = forwarding, work.ticket == ticket, owns(work), matches(request, ticket: ticket),
              work.preparations.count == members.count, work.preparations.values.allSatisfy({ $0.ready }),
              let preparation = work.preparations[request.participantId], preparation.ready,
              sameRequest(preparation.request, request), let control = members[request.participantId]?.control,
              ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
        let task = Task { @MainActor () -> LocalAudioParticipantReceipt? in
            guard let result = await self.serialized(until: deadline, allowed: {
                self.owns(work) && self.requestIsCurrent(request)
            }, operation: { await control.inspect(request.operationId) }), let receipt = result,
                  receipt.proves(request), self.owns(work), self.requestIsCurrent(request) else { return nil }
            return receipt
        }
        return await forwardingResult(task, work: work, until: deadline)
    }

    func fenceAndQuiesce(operationId: UUID, privacyGeneration: UUID, membership: Snapshot, budgetMilliseconds: Int, deadline originalDeadline: ContinuousClock.Instant? = nil) async -> Bool {
        guard (1...30_000).contains(budgetMilliseconds), matches(membership), !Task.isCancelled else { return false }
        if let ticket = localReturn {
            guard ticket.operationId == operationId, ticket.generation == privacyGeneration, ticket.membership == membership else { return false }
        }
        guard operation?.closed != true || localReturn != nil else { return false }
        invalidateForwarding()
        if let old = operation, !old.closed {
            guard old.id == operationId, old.generation == privacyGeneration, old.snapshot == membership,
                  old.budget == budgetMilliseconds, !old.uncertain, let result = old.result else { return false }
            let completed = await LocalAudioCompletion<Bool>.wait(until: old.deadline) { await result.value } == true
            if !completed, operation?.id == operationId, operation?.closed == false { operation?.uncertain = true }
            return completed && !Task.isCancelled
        }
        guard operation == nil || localReturn != nil else { return false }
        let budgetDeadline = ContinuousClock.now.advanced(by: .milliseconds(budgetMilliseconds))
        let deadline = min(originalDeadline ?? budgetDeadline, budgetDeadline)
        guard ContinuousClock.now < deadline else { return false }
        let requests = LocalAudioParticipantID.allCases.map {
            LocalAudioParticipantRequest(schemaVersion: 1, operationId: operationId, privacyGeneration: privacyGeneration,
                registryRevision: String(membership.revision), participantId: $0, bootId: membership.boots[$0]!, budgetMilliseconds: budgetMilliseconds)
        }
        isFenced = true
        operation = Operation(id: operationId, generation: privacyGeneration, snapshot: membership,
            budget: budgetMilliseconds, deadline: deadline, requests: requests)
        let controls = members.mapValues(\.control)
        let task = Task { @MainActor in
            for request in requests {
                guard !Task.isCancelled, self.matches(membership), let control = controls[request.participantId],
                      let receipt = await self.serialized(until: deadline, allowed: { self.requestIsCurrent(request) }, operation: {
                          await control.fenceAndQuiesce(request)
                      }), receipt.proves(request), self.requestIsCurrent(request) else { return false }
            }
            return self.matches(membership) && ContinuousClock.now < deadline && !Task.isCancelled
        }
        operation?.result = task
        let result = await LocalAudioCompletion<Bool>.wait(until: deadline) { await task.value } == true
        if !result || Task.isCancelled {
            if operation?.id == operationId, operation?.closed == false { operation?.uncertain = true }
            task.cancel(); return false
        }
        return true
    }

    func inspectAll(operationId: UUID, privacyGeneration: UUID, membership: Snapshot) async -> Bool {
        guard let old = operation, old.id == operationId, old.generation == privacyGeneration,
              old.snapshot == membership, !old.closed, !old.uncertain, matches(membership) else { return false }
        operation?.inspected = false
        for request in old.requests {
            guard let member = members[request.participantId],
                  let response = await serialized(until: old.deadline, allowed: { self.requestIsCurrent(request) }, operation: {
                      await member.control.inspect(operationId)
                  }), let receipt = response, receipt.proves(request), requestIsCurrent(request), matches(membership), !Task.isCancelled else {
                if operation?.id == operationId, operation?.closed == false { operation?.uncertain = true }
                return false
            }
        }
        let valid = matches(membership) && ContinuousClock.now < old.deadline && !Task.isCancelled
        if operation?.id == operationId, operation?.closed == false {
            operation?.inspected = valid
            if !valid { operation?.uncertain = true }
        }
        return valid
    }
    func proofCurrent(operationId: UUID, privacyGeneration: UUID, membership: Snapshot) -> Bool {
        guard let old = operation else { return false }
        return old.id == operationId && old.generation == privacyGeneration && old.snapshot == membership &&
            !old.closed && !old.uncertain && old.inspected && matches(membership) && ContinuousClock.now < old.deadline && !Task.isCancelled
    }
}
