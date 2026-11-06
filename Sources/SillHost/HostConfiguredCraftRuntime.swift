import Foundation
import StreamProtocol

@MainActor
struct HostConfiguredCraftSession {
    let deviceId: AudioForwardingDeviceID
    let deviceSessionId: UUID
    let pairingGeneration: UUID
    let sentryProtected: @MainActor () -> Bool
    let isCurrent: @MainActor () -> Bool
    let currentSelection: @MainActor () -> AudioForwardingSnapshot?
    let readSnapshot: @MainActor () async -> AudioForwardingSnapshot?
    let withSendAdmission: @MainActor (_ requiresInactive: Bool, _ write: () throws -> Void) throws -> Void
    var canPrepareHost: @MainActor () -> Bool = { false }
    var withPreparedHostAdmission: @MainActor (_ write: () throws -> Void) throws -> Void = { _ in throw ProviderCallFailure.superseded }
    var executeHost: @MainActor (HostConfiguredCraftExecution, AudioForwardingSnapshot) async -> Bool = { _, _ in false }
}

@MainActor
final class HostConfiguredCraftRuntime {
    private final class Record {
        let request: ConfiguredCraftActionRequest
        let pairingGeneration: UUID
        var result: ConfiguredCraftActionResult
        init(request: ConfiguredCraftActionRequest, pairingGeneration: UUID, result: ConfiguredCraftActionResult) {
            self.request = request; self.pairingGeneration = pairingGeneration; self.result = result
        }
    }
    private let open: @MainActor (TimeInterval) async throws -> any ProviderCallTransport
    private let now: () -> Int64
    private var records: [UUID: Record] = [:]
    private var order: [UUID] = []
    private var invoking: UUID?

    init(open: @escaping @MainActor (TimeInterval) async throws -> any ProviderCallTransport,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.open = open; self.now = now
    }

    static func eligible(_ snapshot: AudioForwardingSnapshot, deviceId: AudioForwardingDeviceID) -> Bool {
        guard let intent = snapshot.intent, let binding = snapshot.binding,
              intent.pairedDeviceId == deviceId, binding.pairedDeviceId == deviceId,
              binding.transportKind == .native else { return false }
        switch binding.phase {
        case .active: return intent.inputDesired || intent.outputDesired
        case .off: return !intent.inputDesired && !intent.outputDesired
        case .quiescing: return false
        }
    }

    static func same(_ first: AudioForwardingSnapshot, _ second: AudioForwardingSnapshot) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let left = try? encoder.encode(first), let right = try? encoder.encode(second) else { return false }
        return left == right
    }

    private func remember(_ request: ConfiguredCraftActionRequest, generation: UUID, result: ConfiguredCraftActionResult) {
        if let record = records[request.operationId] {
            guard record.request == request, record.pairingGeneration == generation else { return }
            record.result = result
            return
        }
        if order.count == 128, let index = order.firstIndex(where: { $0 != invoking }) {
            records.removeValue(forKey: order.remove(at: index))
        }
        order.append(request.operationId)
        records[request.operationId] = Record(request: request, pairingGeneration: generation, result: result)
    }

    func exchange(_ control: ConfiguredCraftActionControl, session: HostConfiguredCraftSession) async -> ConfiguredCraftActionState? {
        func current() -> Bool { !Task.isCancelled && session.isCurrent() }
        func failure(_ code: String) -> ConfiguredCraftActionState? {
            try? ConfiguredCraftActionState(control: control, deviceId: session.deviceId, error: code)
        }
        func state(_ result: ConfiguredCraftActionResult) -> ConfiguredCraftActionState? {
            try? ConfiguredCraftActionState(control: control, deviceId: session.deviceId, result: result)
        }
        func action(_ outcome: ConfiguredCraftActionResult.Outcome, _ reason: String) -> ConfiguredCraftActionResult? {
            guard let id = control.targetOperationId else { return nil }
            return try? ConfiguredCraftActionResult(outcome: outcome, operationId: id, deviceId: session.deviceId,
                bindingSha256: nil, invoked: false, reason: reason)
        }
        guard current() else { return nil }
        if control.operation == .query, let operationId = control.operationId, let record = records[operationId] {
            guard record.request.deviceId == session.deviceId, record.pairingGeneration == session.pairingGeneration else {
                return failure("operation_owner_mismatch")
            }
        }
        var localOperation = control.operation
        if let request = control.client {
            guard request.deviceId == session.deviceId else { return failure("device_mismatch") }
            if let record = records[request.operationId] {
                guard record.request == request, record.pairingGeneration == session.pairingGeneration else {
                    return failure("operation_id_conflict")
                }
                if record.result.outcome != .unknown { return state(record.result) }
                localOperation = .query
            }
        }
        let priorRecord = control.targetOperationId.flatMap { records[$0] }
        let prior = priorRecord?.result
        let dispatching = localOperation == .invoke
        let preparingHost = dispatching && session.sentryProtected()
        func writeStateCurrent() -> Bool { preparingHost ? session.canPrepareHost() : !session.sentryProtected() }
        func hostUnknown(_ result: ConfiguredCraftActionResult, _ reason: String) -> ConfiguredCraftActionResult {
            (try? ConfiguredCraftActionResult(outcome: .unknown, operationId: result.operationId,
                deviceId: result.deviceId, bindingSha256: result.bindingSha256, invoked: result.invoked, reason: reason)) ?? result
        }
        func knownResult() -> ConfiguredCraftActionResult? {
            if let id = control.targetOperationId, let record = records[id],
               record.request.deviceId == session.deviceId, record.pairingGeneration == session.pairingGeneration,
               control.client == nil || control.client == record.request,
               localOperation != .query || record === priorRecord { return record.result }
            return prior
        }
        func rejected(_ reason: String) -> ConfiguredCraftActionState? {
            if let known = knownResult(), known.invoked { return current() ? state(known) : nil }
            guard let result = action(.rejected, reason), let request = control.client else { return nil }
            // Retain a definite zero-byte outcome for reconnect even when the old TLS has expired.
            remember(request, generation: session.pairingGeneration, result: result)
            return current() ? state(result) : nil
        }
        func queryFailure(_ reason: String) -> ConfiguredCraftActionState? {
            // A query's notSent says nothing about the original invocation.
            knownResult().flatMap(state) ?? failure(reason)
        }
        if dispatching {
            guard writeStateCurrent() else { return rejected("sentry_protected") }
            guard invoking == nil else { return rejected("busy") }
            invoking = control.client!.operationId
            guard let uncertain = action(.unknown, "invocation_uncertain") else { invoking = nil; return nil }
            remember(control.client!, generation: session.pairingGeneration, result: uncertain)
        }
        defer { if dispatching { invoking = nil } }
        var initial: AudioForwardingSnapshot?
        if dispatching {
            guard let snapshot = await session.readSnapshot(), current(), writeStateCurrent(),
                  Self.eligible(snapshot, deviceId: session.deviceId) else {
                return rejected("audio_selection_unavailable")
            }
            initial = snapshot
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var sentInvoke = false
        do {
            let socket = try await open(min(deadline, ProcessInfo.processInfo.systemUptime + 1))
            defer { socket.invalidate() }
            guard current() else { return dispatching ? rejected("superseded") : nil }
            if let initial {
                guard let latest = await session.readSnapshot(), current(), writeStateCurrent(),
                      Self.eligible(latest, deviceId: session.deviceId), Self.same(initial, latest) else {
                    return rejected("audio_selection_unavailable")
                }
            }
            guard current() else { return dispatching ? rejected("superseded") : nil }
            let clock = now, deviceId = session.deviceId, sessionId = session.deviceSessionId
            let reply = try await socket.exchange(admittedSend: { (write: (HostConfiguredCraftCommand) throws -> Void) in
                guard current(), !dispatching || writeStateCurrent() else { throw ProviderCallFailure.superseded }
                let writeCommand = {
                    // No await from this selection proof through the first nonblocking send.
                    // Host audio selection updates share MainActor with this transaction.
                    if let initial {
                        guard let latest = session.currentSelection(), Self.same(initial, latest),
                              Self.eligible(latest, deviceId: deviceId) else { throw ProviderCallFailure.superseded }
                    }
                    let acceptedAt = clock()
                    guard acceptedAt > 0, acceptedAt <= 9_007_199_254_740_991 else { throw ProviderCallFailure.invalidFields }
                    try write(HostConfiguredCraftCommand(control: control, operation: localOperation,
                        deviceId: deviceId, deviceSessionId: sessionId, acceptedAt: acceptedAt, preparingHost: preparingHost))
                    // write returns only after a positive first send. EAGAIN/EINTR do not mark dispatch.
                    sentInvoke = dispatching
                }
                if preparingHost { try session.withPreparedHostAdmission(writeCommand) }
                else { try session.withSendAdmission(dispatching, writeCommand) }
            }, as: HostConfiguredCraftReply.self, until: deadline, decode: { try HostConfiguredCraftReply.decode($0, preparingHost: preparingHost) })
            if preparingHost, reply.requestId == control.requestId, let request = control.client,
               let result = reply.actionResult, result.operationId == request.operationId,
               result.deviceId == session.deviceId, result.invoked {
                // Craft handed off once even if TLS expired while the reply was in flight.
                remember(request, generation: session.pairingGeneration, result: hostUnknown(result, "host_effect_unconfirmed"))
            }
            guard current() else { return nil }
            guard reply.requestId == control.requestId else { return localOperation == .query ? knownResult().flatMap(state) : nil }
            let response: ConfiguredCraftActionState?
            switch reply.outcome {
            case .ok:
                if control.operation == .catalog {
                    guard let catalog = reply.catalog, reply.actionResult == nil else { return nil }
                    response = try? ConfiguredCraftActionState(control: control, deviceId: session.deviceId, catalog: catalog)
                } else {
                    guard let result = reply.actionResult, reply.catalog == nil,
                          result.deviceId == session.deviceId, result.operationId == control.targetOperationId else {
                        return localOperation == .query ? knownResult().flatMap(state) : nil
                    }
                    if preparingHost, result.invoked {
                        let uncertain = hostUnknown(result, "host_effect_unconfirmed")
                        if let request = control.client, let initial, let plan = reply.hostExecution,
                           plan.matches(request, session: session.deviceSessionId, result: result), plan.fresh(at: now()),
                           await session.executeHost(plan, initial) {
                            response = state(result)
                        } else { response = state(uncertain) }
                    } else if let known = knownResult(), known.invoked, !result.invoked {
                        response = state(known)
                    } else { response = state(result) }
                }
            case .rejected:
                guard let reason = reply.reason else { return nil }
                response = dispatching ? rejected(reason) : queryFailure(reason)
            case .unknown:
                guard let reason = reply.reason else { return nil }
                if localOperation == .query { response = queryFailure(reason) }
                else if dispatching {
                    if let known = knownResult(), known.invoked { response = state(known) }
                    else { response = action(.unknown, reason).flatMap(state) }
                }
                else { response = failure(reason) }
            }
            if let result = response?.result {
                if localOperation == .query {
                    // MainActor CAS: a readback may update only the original resident entry.
                    // Eviction/reinsertion is a different object even with identical client9.
                    if let priorRecord, let record = records[result.operationId], record === priorRecord,
                       record.request == priorRecord.request, record.request.deviceId == session.deviceId,
                       record.pairingGeneration == priorRecord.pairingGeneration,
                       record.pairingGeneration == session.pairingGeneration {
                        remember(record.request, generation: record.pairingGeneration, result: result)
                    }
                } else if let request = control.client {
                    remember(request, generation: session.pairingGeneration, result: result)
                }
            }
            if let initial {
                guard let latest = await session.readSnapshot(), current(), writeStateCurrent(),
                      Self.same(initial, latest) else { return nil }
            }
            return current() ? response : nil
        } catch {
            if dispatching, !sentInvoke { return rejected("unavailable") }
            guard current() else { return nil }
            if localOperation == .query { return queryFailure("unavailable") }
            if error is DecodingError || error is ConfiguredCraftActionFailure { return nil }
            if case ProviderCallFailure.invalidFields = error { return nil }
            if sentInvoke {
                if let initial {
                    guard let latest = await session.readSnapshot(), current(), writeStateCurrent(),
                          Self.same(initial, latest) else { return nil }
                }
                return (knownResult() ?? action(.unknown, "invocation_uncertain")).flatMap(state)
            }
            return failure("unavailable")
        }
    }
}

struct HostConfiguredCraftCommand: Encodable {
    let op: String
    let schemaVersion = 1
    let requestId: String
    let deviceId: AudioForwardingDeviceID
    let deviceSessionId: String
    let acceptedAt: Int64
    let client: ConfiguredCraftActionRequest?
    let sentryState: String?
    let operationId: String?
    init(control: ConfiguredCraftActionControl, operation: ConfiguredCraftActionControl.Operation,
         deviceId: AudioForwardingDeviceID, deviceSessionId: UUID, acceptedAt: Int64, preparingHost: Bool = false) {
        op = "configuredCraftAction." + (preparingHost ? "prepareHost" : operation.rawValue)
        requestId = control.requestId.uuidString.lowercased(); self.deviceId = deviceId
        self.deviceSessionId = deviceSessionId.uuidString.lowercased(); self.acceptedAt = acceptedAt
        client = operation == .invoke ? control.client : nil
        sentryState = operation == .invoke ? (preparingHost ? "userSessionProtected" : "inactive") : nil
        operationId = operation == .query ? control.targetOperationId?.uuidString.lowercased() : nil
    }
}

struct HostConfiguredCraftReply: Decodable {
    enum Outcome: String, Decodable { case ok, rejected, unknown }
    let requestId: UUID
    let outcome: Outcome
    let catalog: ConfiguredCraftActionCatalog?
    let actionResult: ConfiguredCraftActionResult?
    let reason: String?
    let hostExecution: HostConfiguredCraftExecution?
    private let hasHostExecution: Bool
    private enum CodingKeys: String, CodingKey { case op, schemaVersion, requestId, outcome, catalog, actionResult, notSent, reason, hostExecution }
    static func decode(_ data: Data, preparingHost: Bool = false) throws -> Self {
        let reply = try ConfiguredCraftActionJSON.decode(Self.self, from: data)
        guard preparingHost ? (reply.outcome != .ok || reply.actionResult != nil && reply.hasHostExecution) : !reply.hasHostExecution else {
            throw ProviderCallFailure.invalidFields
        }
        return reply
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        var keys: Set<String> = ["op", "schemaVersion", "requestId", "outcome"]
        if outcome == .ok {
            guard c.contains(.catalog) != c.contains(.actionResult) else { throw ProviderCallFailure.invalidFields }
            keys.insert(c.contains(.catalog) ? "catalog" : "actionResult")
            if c.contains(.hostExecution) { keys.insert("hostExecution") }
        } else { keys.formUnion(["notSent", "reason"]) }
        try providerExactKeys(decoder, required: keys)
        let raw = try c.decode(String.self, forKey: .requestId)
        guard try c.decode(String.self, forKey: .op) == "configuredCraftAction.reply",
              try c.decode(Int.self, forKey: .schemaVersion) == 1,
              let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw else { throw ProviderCallFailure.invalidFields }
        requestId = id
        catalog = try c.decodeIfPresent(ConfiguredCraftActionCatalog.self, forKey: .catalog)
        actionResult = try c.decodeIfPresent(ConfiguredCraftActionResult.self, forKey: .actionResult)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        hasHostExecution = c.contains(.hostExecution)
        hostExecution = try c.decodeIfPresent(HostConfiguredCraftExecution.self, forKey: .hostExecution)
        guard !hasHostExecution || actionResult != nil else { throw ProviderCallFailure.invalidFields }
        if outcome != .ok {
            guard let reason, reason.range(of: "^[a-z][a-z0-9_]{0,79}$", options: .regularExpression) != nil,
                  try c.decode(Bool.self, forKey: .notSent) == (outcome == .rejected) else { throw ProviderCallFailure.invalidFields }
        } else {
            guard catalog != nil || actionResult != nil else { throw ProviderCallFailure.invalidFields }
        }
    }
}
