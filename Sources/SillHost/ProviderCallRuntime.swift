import Foundation
import StreamProtocol

@MainActor
struct ProviderCallSession {
    let relay: LocalAudioRelay
    let peer: AudioForwardingPairedDevice
    let credential: AudioForwardingCredential
    let snapshot: AudioForwardingSnapshot
    let admitted: @MainActor () -> Bool
    let readSnapshot: @MainActor () async -> AudioForwardingSnapshot?
}

@MainActor
final class ProviderCallRuntime {
    private final class Record {
        enum Stage { case preflight, authority }
        let request: ProviderCallRequest
        let generation: UUID
        weak var relay: LocalAudioRelay?
        let authority: LocalAudioRelay.ProviderAuthorityIdentity
        var stage = Stage.preflight
        let startedAt = ProcessInfo.processInfo.systemUptime
        var lastQueryAt: TimeInterval?
        var queries = 0
        var result: ProviderCallResult
        init(_ request: ProviderCallRequest, generation: UUID, session: ProviderCallSession,
             authority: LocalAudioRelay.ProviderAuthorityIdentity) throws {
            self.request = request; self.generation = generation
            relay = session.relay; self.authority = authority
            result = try ProviderCallResult(requestId: request.requestId, status: .pending, reason: "provider_pending")
        }
    }
    private var records: [UUID: Record] = [:]
    private let identity: HostIdentity
    private let recoveryReady: @MainActor () async -> Bool
    private let commandPath: String
    private let open: @MainActor (String, TimeInterval) async throws -> any ProviderCallTransport

    init(identity: HostIdentity, recoveryReady: @escaping @MainActor () async -> Bool = { await ProviderCallRecovery.ready() },
         open: @escaping @MainActor (String, TimeInterval) async throws -> any ProviderCallTransport = {
             try await ProviderCallSocket.open(path: $0, until: $1)
         }) {
        self.identity = identity; self.recoveryReady = recoveryReady
        self.open = open
        commandPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexControlRoom/command.sock").path
    }

    func exchange(_ control: ProviderCallControl, context: AudioForwardingConnectionContext,
                  session: ProviderCallSession?) async -> ProviderCallState? {
        let request = control.request
        guard context.role == .viewer, context.isCurrent(), request.pairedDeviceId == context.peer.id,
              let session, session.admitted(), let authority = session.relay.providerAuthorityIdentity else { return nil }
        if let prior = records[request.requestId] {
            guard prior.request == request, prior.generation == context.peer.pairingGeneration else {
                return state(request, .failed, "request_id_conflict")
            }
            guard prior.relay === session.relay, prior.authority == authority else {
                return state(request, .unknown, "provider_authority_changed")
            }
            if control.operation == .query, prior.result.status == .pending {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - prior.startedAt < 10, prior.queries < 4,
                      prior.lastQueryAt.map({ now - $0 >= 0.5 }) ?? true else {
                    return state(request, .unknown, "provider_query_budget_exhausted")
                }
                prior.lastQueryAt = now; prior.queries += 1
            }
            return try? ProviderCallState(request: request, result: prior.result)
        }
        guard control.operation == .perform else { return state(request, .unknown, "provider_result_unavailable") }
        guard request.matches(session.snapshot) else { return state(request, .failed, "audio_lease_changed") }
        guard records.values.filter({ $0.request.pairedDeviceId == request.pairedDeviceId && $0.stage == .preflight }).count < 4 else {
            return state(request, .failed, "provider_preflight_busy")
        }
        guard records.count < 256 else { return state(request, .failed, "request_capacity") }
        guard let record = try? Record(request, generation: context.peer.pairingGeneration,
                                      session: session, authority: authority) else { return nil }
        records[request.requestId] = record
        defer { if record.stage == .preflight { records.removeValue(forKey: request.requestId) } }
        guard let result = try? await perform(record, context: context, session: session) else { return nil }
        record.result = result
        guard context.isCurrent() else { return nil }
        return try? ProviderCallState(request: request, result: result)
    }

    private func state(_ request: ProviderCallRequest, _ status: ProviderCallResult.Status, _ reason: String) -> ProviderCallState? {
        guard let result = try? ProviderCallResult(requestId: request.requestId, status: status, reason: reason) else { return nil }
        return try? ProviderCallState(request: request, result: result)
    }

    private func perform(_ record: Record, context: AudioForwardingConnectionContext,
                         session: ProviderCallSession) async throws -> ProviderCallResult {
        let request = record.request
        func result(_ status: ProviderCallResult.Status, _ reason: String) throws -> ProviderCallResult {
            try ProviderCallResult(requestId: request.requestId, status: status, reason: reason)
        }
        let current = { !Task.isCancelled && context.isCurrent() && session.admitted() &&
            record.relay === session.relay && record.authority == session.relay.providerAuthorityIdentity }
        guard current(), request.matches(session.snapshot) else { return try result(.failed, "audio_lease_changed") }
        guard await recoveryReady(), current() else { return try result(.failed, "compatible_recovery_unavailable") }
        let overall = ProcessInfo.processInfo.systemUptime + 8
        var prepared: ProviderCallPrepared?
        var approval: ProviderCallApproval?
        var released = false
        var sentDispatch = false
        do {
            let socket = try await open(commandPath, min(overall, ProcessInfo.processInfo.systemUptime + 1))
            defer { socket.invalidate() }
            guard current() else { throw ProviderCallFailure.superseded }
            let challengeStarted = ProcessInfo.processInfo.systemUptime
            let challenge = try await socket.exchange(ChallengeRequest(request: request), as: ProviderCallChallenge.self,
                until: min(overall, challengeStarted + 1.5))
            try challenge.validate(request)
            let challengeExpiry = challengeStarted + Double(challenge.remainingMilliseconds) / 1000
            guard current() else { throw ProviderCallFailure.superseded }
            let signer = ProviderCallSigner(identity: identity)
            let identityReply = try await socket.exchange(ProofRequest(op: "provider.identity",
                envelope: signer.identityProof(challenge, request: request)), as: IdentityReply.self, until: challengeExpiry)
            try identityReply.validate(challenge, request: request)
            guard current(), let initial = await session.readSnapshot(), current(),
                  providerSameSnapshot(initial, session.snapshot) else { throw ProviderCallFailure.superseded }
            record.stage = .authority
            switch await session.relay.providerAcquire(request, challenge: challenge, challengeStartedAt: challengeStarted,
                snapshot: initial, peer: session.peer, credential: session.credential, admission: current) {
            case .prepared(let value): prepared = value
            case .recorded: return try result(.unknown, "provider_action_already_recorded")
            case .refused: return try result(.failed, "provider_scope_refused")
            case .unavailable: return try result(.failed, "provider_scope_unavailable")
            }
            guard let prepared, current() else { throw ProviderCallFailure.superseded }
            switch await session.relay.providerDispatch(prepared) {
            case .approved(let value): approval = value
            case .notDispatched: throw ProviderCallFailure.superseded
            case .unknown: sentDispatch = true; throw ProviderCallFailure.unavailable
            }
            guard let approval, current() else { throw ProviderCallFailure.superseded }
            let proof = try signer.dispatchProof(approval, context: context)
            guard current(), approval.isCurrent else { throw ProviderCallFailure.superseded }
            sentDispatch = true
            let delivered = try await socket.exchange(ProofRequest(op: "provider.dispatch", envelope: proof),
                as: DeliveryReply.self, until: min(overall, approval.expiresAt))
            try delivered.validate(challenge, request: request)
            let outcome: ProviderCallScope.Outcome = delivered.state == .activated ? .dispatched : .unknown
            released = await session.relay.providerRelease(approval, outcome: outcome)
            guard released, current() else { throw ProviderCallFailure.superseded }
            guard delivered.state == .activated else { return try result(.unknown, "provider_button_not_confirmed") }
            let readback = try await socket.exchange(ResultRequest(challenge: challenge, request: request),
                as: ResultReply.self, until: overall)
            try readback.validate(challenge, request: request)
            guard current(), let final = await session.readSnapshot(), current(),
                  providerSameSnapshot(final, session.snapshot), request.matches(final) else {
                throw ProviderCallFailure.superseded
            }
            let value = readback.result
            guard value.status != .pending else { return try result(.unknown, "provider_readback_timeout") }
            guard value.status != .started || request.action == .start,
                  value.status != .stopped || request.action == .stop else { throw ProviderCallFailure.invalidFields }
            return value
        } catch {
            if let approval, !released { _ = await session.relay.providerRelease(approval, outcome: .unknown) }
            else if let prepared, approval == nil { await session.relay.providerCancel(prepared) }
            return try result(sentDispatch ? .unknown : .failed, sentDispatch ? "provider_dispatch_uncertain" : "provider_not_dispatched")
        }
    }
}

private struct ChallengeRequest: Encodable {
    let op = "provider.challenge"
    let schemaVersion = 1
    let request: ProviderCallRequest
}
private struct ProofRequest: Encodable {
    let op: String
    let schemaVersion = 1
    let envelope: ProviderCallSignedEnvelope
}
private struct ResultRequest: Encodable {
    let op = "provider.result"
    let schemaVersion = 1
    let requestId: String
    let coreGeneration: String
    let challenge: String
    let requestDigest: String
    let targetHash: String
    init(challenge: ProviderCallChallenge, request: ProviderCallRequest) {
        requestId = request.requestId.uuidString.lowercased(); coreGeneration = challenge.coreGeneration.uuidString.lowercased()
        self.challenge = challenge.challenge; requestDigest = request.digest; targetHash = challenge.targetHash
    }
}

private struct ProviderCallCorrelation: Decodable {
    let schemaVersion: Int
    let requestId: UUID
    let coreGeneration: UUID
    let challenge: String
    let requestDigest: String
    let targetHash: String
    func validate(_ expected: ProviderCallChallenge, request: ProviderCallRequest) throws {
        guard schemaVersion == 1, requestId == request.requestId, coreGeneration == expected.coreGeneration,
              challenge == expected.challenge, requestDigest == request.digest, targetHash == expected.targetHash else {
            throw ProviderCallFailure.invalidIdentity
        }
    }
}

private struct IdentityReply: Decodable {
    let correlation: ProviderCallCorrelation
    let state: String
    private enum CodingKeys: String, CodingKey { case state }
    init(from decoder: Decoder) throws {
        try providerExactKeys(decoder, required: ["schemaVersion", "requestId", "coreGeneration", "challenge", "requestDigest", "targetHash", "state"])
        correlation = try ProviderCallCorrelation(from: decoder)
        state = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .state)
    }
    func validate(_ expected: ProviderCallChallenge, request: ProviderCallRequest) throws {
        try correlation.validate(expected, request: request)
        guard state == "identity_verified" else { throw ProviderCallFailure.invalidIdentity }
    }
}

private struct DeliveryReply: Decodable {
    enum State: String, Decodable { case activated, notDispatched = "not_dispatched", unknown }
    let correlation: ProviderCallCorrelation
    let state: State
    let reason: String
    private enum CodingKeys: String, CodingKey { case state, reason }
    init(from decoder: Decoder) throws {
        try providerExactKeys(decoder, required: ["schemaVersion", "requestId", "coreGeneration", "challenge", "requestDigest", "targetHash", "state", "reason"])
        correlation = try ProviderCallCorrelation(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state); reason = try c.decode(String.self, forKey: .reason)
    }
    func validate(_ expected: ProviderCallChallenge, request: ProviderCallRequest) throws {
        try correlation.validate(expected, request: request)
        guard reason.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil else { throw ProviderCallFailure.invalidFields }
    }
}

private struct ResultReply: Decodable {
    let correlation: ProviderCallCorrelation
    let result: ProviderCallResult
    private enum CodingKeys: String, CodingKey { case result }
    init(from decoder: Decoder) throws {
        try providerExactKeys(decoder, required: ["schemaVersion", "requestId", "coreGeneration", "challenge", "requestDigest", "targetHash", "result"])
        correlation = try ProviderCallCorrelation(from: decoder)
        result = try decoder.container(keyedBy: CodingKeys.self).decode(ProviderCallResult.self, forKey: .result)
    }
    func validate(_ expected: ProviderCallChallenge, request: ProviderCallRequest) throws {
        try correlation.validate(expected, request: request)
        guard result.requestId == request.requestId else { throw ProviderCallFailure.invalidFields }
    }
}
