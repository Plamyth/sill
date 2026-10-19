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
    struct Control {
        let fenceAndQuiesce: @MainActor (LocalAudioParticipantRequest) async -> LocalAudioParticipantReceipt
        let inspect: @MainActor (UUID) async -> LocalAudioParticipantReceipt?
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
    }
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
    func register(_ id: LocalAudioParticipantID, bootId: UUID, control: Control) {
        guard revision < UInt64.max else { return }
        revision += 1
        members[id] = Member(boot: bootId, control: control)
    }
    func unregister(_ id: LocalAudioParticipantID) {
        guard revision < UInt64.max else { return }
        revision += 1; members.removeValue(forKey: id)
    }
    func matches(_ frozen: Snapshot) -> Bool { available && snapshot == frozen }

    func fenceAndQuiesce(operationId: UUID, privacyGeneration: UUID, membership: Snapshot, budgetMilliseconds: Int, deadline originalDeadline: ContinuousClock.Instant? = nil) async -> Bool {
        guard (1...30_000).contains(budgetMilliseconds), matches(membership), !Task.isCancelled else { return false }
        if let old = operation {
            guard old.id == operationId, old.generation == privacyGeneration, old.snapshot == membership,
                  old.budget == budgetMilliseconds, !old.uncertain, let result = old.result else { return false }
            let completed = await LocalAudioCompletion<Bool>.wait(until: old.deadline) { await result.value } == true
            if !completed { operation?.uncertain = true }
            return completed && !Task.isCancelled
        }
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
                      let receipt = await LocalAudioCompletion<LocalAudioParticipantReceipt>.wait(until: deadline, operation: {
                          await control.fenceAndQuiesce(request)
                      }), receipt.proves(request) else { return false }
            }
            return self.matches(membership) && ContinuousClock.now < deadline && !Task.isCancelled
        }
        operation?.result = task
        let result = await LocalAudioCompletion<Bool>.wait(until: deadline) { await task.value } == true
        if !result || Task.isCancelled { operation?.uncertain = true; task.cancel(); return false }
        return true
    }

    func inspectAll(operationId: UUID, privacyGeneration: UUID, membership: Snapshot) async -> Bool {
        guard let old = operation, old.id == operationId, old.generation == privacyGeneration,
              old.snapshot == membership, !old.uncertain, matches(membership) else { return false }
        operation?.inspected = false
        for request in old.requests {
            guard let member = members[request.participantId],
                  let response = await LocalAudioCompletion<LocalAudioParticipantReceipt?>.wait(until: old.deadline, operation: {
                      await member.control.inspect(operationId)
                  }), let receipt = response, receipt.proves(request), matches(membership), !Task.isCancelled else {
                operation?.uncertain = true; return false
            }
        }
        let valid = matches(membership) && ContinuousClock.now < old.deadline && !Task.isCancelled
        operation?.inspected = valid
        if !valid { operation?.uncertain = true }
        return valid
    }
    func proofCurrent(operationId: UUID, privacyGeneration: UUID, membership: Snapshot) -> Bool {
        guard let old = operation else { return false }
        return old.id == operationId && old.generation == privacyGeneration && old.snapshot == membership &&
            !old.uncertain && old.inspected && matches(membership) && ContinuousClock.now < old.deadline && !Task.isCancelled
    }
}
