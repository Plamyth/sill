import Foundation
import StreamProtocol

@MainActor
struct HostConfiguredCraftSession {
    let deviceId: AudioForwardingDeviceID
    let deviceSessionId: UUID
    let pairingGeneration: UUID
    let sentryProtected: @MainActor () -> Bool
    let isCurrent: @MainActor () -> Bool
    let readSnapshot: @MainActor () async -> AudioForwardingSnapshot?
    let withSendAdmission: @MainActor (_ requiresInactive: Bool, _ write: () throws -> Void) throws -> Void
}

@MainActor
final class HostConfiguredCraftRuntime {
    private struct Record {
        let request: ConfiguredCraftActionRequest
        let pairingGeneration: UUID
        var result: ConfiguredCraftActionResult
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

    private static func same(_ first: AudioForwardingSnapshot, _ second: AudioForwardingSnapshot) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let left = try? encoder.encode(first), let right = try? encoder.encode(second) else { return false }
        return left == right
    }

    private func remember(_ request: ConfiguredCraftActionRequest, generation: UUID, result: ConfiguredCraftActionResult) {
        if records[request.operationId] == nil {
            if order.count == 128 { records.removeValue(forKey: order.removeFirst()) }
            order.append(request.operationId)
        }
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
        var initial: AudioForwardingSnapshot?
        let dispatching = localOperation == .invoke
        if dispatching {
            guard !session.sentryProtected() else { return failure("sentry_protected") }
            guard invoking == nil else { return failure("busy") }
            invoking = control.client!.operationId
            guard let uncertain = action(.unknown, "invocation_uncertain") else { invoking = nil; return nil }
            remember(control.client!, generation: session.pairingGeneration, result: uncertain)
        }
        defer { if dispatching { invoking = nil } }
        if dispatching {
            guard let snapshot = await session.readSnapshot(), current(), !session.sentryProtected(),
                  Self.eligible(snapshot, deviceId: session.deviceId) else {
                guard let refused = action(.rejected, "audio_selection_unavailable") else { return nil }
                remember(control.client!, generation: session.pairingGeneration, result: refused)
                return current() ? state(refused) : nil
            }
            initial = snapshot
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var sentInvoke = false
        do {
            let socket = try await open(min(deadline, ProcessInfo.processInfo.systemUptime + 1))
            defer { socket.invalidate() }
            guard current() else { return nil }
            if let initial {
                guard let latest = await session.readSnapshot(), current(), !session.sentryProtected(),
                      Self.eligible(latest, deviceId: session.deviceId), Self.same(initial, latest) else { return nil }
            }
            guard current(), !dispatching || !session.sentryProtected() else { return nil }
            let clock = now, deviceId = session.deviceId, sessionId = session.deviceSessionId
            sentInvoke = dispatching
            let reply = try await socket.exchange(admittedSend: { (write: (HostConfiguredCraftCommand) throws -> Void) in
                guard current(), !dispatching || !session.sentryProtected() else { throw ProviderCallFailure.superseded }
                try session.withSendAdmission(dispatching) {
                    let acceptedAt = clock()
                    guard acceptedAt > 0, acceptedAt <= 9_007_199_254_740_991 else { throw ProviderCallFailure.invalidFields }
                    try write(HostConfiguredCraftCommand(control: control, operation: localOperation,
                        deviceId: deviceId, deviceSessionId: sessionId, acceptedAt: acceptedAt))
                }
            }, as: HostConfiguredCraftReply.self, until: deadline, decode: { try HostConfiguredCraftReply.decode($0) })
            guard current() else { return nil }
            guard reply.requestId == control.requestId else { return nil }
            let response: ConfiguredCraftActionState?
            switch reply.outcome {
            case .ok:
                if control.operation == .catalog {
                    guard let catalog = reply.catalog, reply.actionResult == nil else { return nil }
                    response = try? ConfiguredCraftActionState(control: control, deviceId: session.deviceId, catalog: catalog)
                } else {
                    guard let result = reply.actionResult, reply.catalog == nil,
                          result.deviceId == session.deviceId, result.operationId == control.targetOperationId else { return nil }
                    response = state(result)
                }
            case .rejected:
                guard let reason = reply.reason else { return nil }
                response = failure(reason)
            case .unknown:
                guard let reason = reply.reason else { return nil }
                if control.operation == .catalog { response = failure(reason) }
                else { response = action(.unknown, reason).flatMap(state) }
            }
            if let request = control.client, let result = response?.result {
                remember(request, generation: session.pairingGeneration, result: result)
            }
            if let initial {
                guard let latest = await session.readSnapshot(), current(), !session.sentryProtected(),
                      Self.same(initial, latest) else { return nil }
            }
            return current() ? response : nil
        } catch is DecodingError { return nil }
        catch ProviderCallFailure.invalidFields { return nil }
        catch is ConfiguredCraftActionFailure { return nil }
        catch {
            guard current() else { return nil }
            if sentInvoke {
                if let initial {
                    guard let latest = await session.readSnapshot(), current(), !session.sentryProtected(),
                          Self.same(initial, latest) else { return nil }
                }
                return action(.unknown, "invocation_uncertain").flatMap(state)
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
         deviceId: AudioForwardingDeviceID, deviceSessionId: UUID, acceptedAt: Int64) {
        op = "configuredCraftAction." + operation.rawValue
        requestId = control.requestId.uuidString.lowercased(); self.deviceId = deviceId
        self.deviceSessionId = deviceSessionId.uuidString.lowercased(); self.acceptedAt = acceptedAt
        client = operation == .invoke ? control.client : nil
        sentryState = operation == .invoke ? "inactive" : nil
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
    private enum CodingKeys: String, CodingKey { case op, schemaVersion, requestId, outcome, catalog, actionResult, notSent, reason }
    static func decode(_ data: Data) throws -> Self {
        try ConfiguredCraftActionJSON.decode(Self.self, from: data)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        var keys: Set<String> = ["op", "schemaVersion", "requestId", "outcome"]
        if outcome == .ok {
            guard c.contains(.catalog) != c.contains(.actionResult) else { throw ProviderCallFailure.invalidFields }
            keys.insert(c.contains(.catalog) ? "catalog" : "actionResult")
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
        if outcome != .ok {
            guard let reason, reason.range(of: "^[a-z][a-z0-9_]{0,79}$", options: .regularExpression) != nil,
                  try c.decode(Bool.self, forKey: .notSent) == (outcome == .rejected) else { throw ProviderCallFailure.invalidFields }
        } else {
            guard catalog != nil || actionResult != nil else { throw ProviderCallFailure.invalidFields }
        }
    }
}
