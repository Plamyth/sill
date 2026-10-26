import Foundation
import StreamProtocol

/// Main-thread consumer. Only explicit actions return bytes; observations never send.
struct IPadSentryControl {
    struct Binding: Codable, Equatable {
        let macID: String
        let hostPin: Data
        let deviceFingerprint: Data
    }

    struct Store {
        let load: () -> Data?
        let save: (Data) throws -> Void

        static func defaults(_ defaults: UserDefaults = .standard) -> Self {
            let key = "Sill.sentryPending.v2"
            return Self(load: { defaults.data(forKey: key) }, save: { data in
                defaults.set(data, forKey: key)
                guard defaults.synchronize(), defaults.data(forKey: key) == data else {
                    throw StoreFailure.unconfirmed
                }
            })
        }
    }

    enum Phase: Equatable {
        case idle, pending, unknown, applied, superseded
        case rejected(String)
    }

    private struct Stored: Codable {
        let binding: Binding
        let rawRequest: Data
        let priorRawRequest: Data?
        let ledgerAccepted: Bool?
        let priorLedgerAccepted: Bool?
    }
    private struct Epoch: Codable, Equatable {
        let binding: Binding
        let hostBootID: UUID
        let sessionID: UUID
        let authorizationGeneration: UUID
    }
    private struct Retired: Codable {
        let epoch: Epoch
        let request: Stored?
    }
    private struct Ledger: Codable {
        let version: Int
        let active: Stored?
        let retired: [Retired]
    }
    private struct Pending {
        let stored: Stored
        let request: SentryControlRequest
    }
    private struct Context {
        let binding: Binding
        let state: SentryState
        let control: SentryControlCapability
        var epoch: Epoch {
            .init(binding: binding, hostBootID: state.hostBootID, sessionID: state.sessionID,
                  authorizationGeneration: control.authorizationGeneration)
        }
    }
    private enum StoreFailure: Error { case unconfirmed }

    static let requestKind: UInt8 = 213
    static let responseKind: UInt8 = 214
    static let requestCap = SentryControlRequest.maximumPayload
    static let responseCap = SentryControlResponse.maximumPayload
    private let store: Store
    private var peer: ObjectIdentifier?
    private var context: Context?
    private var pending: Pending?
    private var retired: [Retired] = []
    private var restorationFailed = false
    private var inFlight = false
    private var deadline: TimeInterval?
    private(set) var phase: Phase = .idle
    private(set) var problem: String?

    init(store: Store) {
        self.store = store
        guard let data = store.load() else { return }
        phase = .unknown
        restorationFailed = true
        let active: Stored?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["version"] != nil {
            guard let ledger = try? JSONDecoder().decode(Ledger.self, from: data), ledger.version == 3,
                  ledger.retired.count <= 64,
                  ledger.active.map(Self.validStored) ?? true,
                  ledger.retired.allSatisfy(Self.validRetired),
                  ledger.retired.enumerated().allSatisfy({ index, item in !ledger.retired.prefix(index).contains(where: { $0.epoch == item.epoch }) }) else {
                problem = "이전 센트리 요청 이력을 확인하지 못했습니다."
                return
            }
            let requests = [ledger.active].compactMap { $0 } + ledger.retired.compactMap(\.request)
            let ids = requests.flatMap { [$0.rawRequest] + [$0.priorRawRequest].compactMap { $0 } }
                .compactMap(Self.request).map(\.requestID)
            guard Set(ids).count == ids.count,
                  ledger.active.flatMap(Self.epoch).map({ epoch in !ledger.retired.contains(where: { $0.epoch == epoch }) }) ?? true else {
                problem = "이전 센트리 요청 이력의 식별자가 충돌합니다."
                return
            }
            active = ledger.active
            retired = ledger.retired
        } else {
            guard let stored = try? JSONDecoder().decode(Stored.self, from: data), Self.validStored(stored) else {
                problem = "이전 센트리 요청 저장 내용을 확인하지 못했습니다."
                return
            }
            active = stored
        }
        if let active, let request = Self.request(active.rawRequest) {
            pending = Pending(stored: active, request: request)
        } else {
            phase = .idle
        }
        restorationFailed = false
    }

    mutating func bind(_ next: ObjectIdentifier?) {
        guard peer != next else { return }
        peer = next
        context = nil
        unconfirmed()
    }

    mutating func observe(catalog: Data, observation: IPadSentryObservation, binding: Binding?, from peer: ObjectIdentifier) {
        guard self.peer == peer, !restorationFailed else { return }
        guard case .reported(let state) = observation.status,
              let binding, let report = IPadSentryObservation.decodeCatalog(catalog),
              report == state, let control = report.control else {
            context = nil
            unconfirmed()
            return
        }
        let next = Context(binding: binding, state: state, control: control)
        guard !retired.contains(where: { $0.epoch == next.epoch }) else { return }
        if let previous = context,
           previous.binding == binding && previous.state.hostBootID == state.hostBootID &&
           previous.state.sessionID == state.sessionID &&
           previous.control.authorizationGeneration != control.authorizationGeneration {
            guard retire(previous) else { context = nil; phase = .unknown; unconfirmed(); return }
        } else if let previous = context, previous.epoch != next.epoch {
            unconfirmed()
        }
        context = next
        if let pending, !matches(pending) { unconfirmed() }
    }

    private mutating func retire(_ previous: Context) -> Bool {
        guard retired.count < 64 else {
            problem = "센트리 요청 이력이 가득 찼습니다. 원래 요청을 보존합니다."
            return false
        }
        if let pending {
            guard matches(pending), pending.request.sessionID == previous.state.sessionID else { return false }
        }
        let history = retired + [Retired(epoch: previous.epoch, request: pending?.stored)]
        guard persist(active: nil, retired: history) else { return false }
        retired = history
        pending = nil
        phase = .idle
        inFlight = false
        deadline = nil
        problem = nil
        return true
    }

    var canSet: Bool { canSet(desired: true) || canSet(desired: false) }

    func canSet(desired: Bool) -> Bool {
        guard !restorationFailed, context != nil, peer != nil, !inFlight else { return false }
        guard let pending else { return phase == .idle }
        guard matches(pending) else { return false }
        switch phase {
        case .applied, .rejected, .superseded: return true
        case .pending:
            return !desired && pending.request.desired && context?.control.manualIntent == .on
        default: return false
        }
    }
    var canQuery: Bool {
        guard let pending, !inFlight else { return false }
        return matches(pending) && (pending.stored.ledgerAccepted == true ||
            pending.request.sessionID != context?.state.sessionID)
    }
    var originalRequest: Data? { pending?.stored.rawRequest }
    var priorRequest: Data? { pending?.stored.priorRawRequest }
    var retiredRequests: [Data] {
        retired.flatMap { item in
            guard let request = item.request else { return [Data]() }
            return [request.rawRequest] + [request.priorRawRequest].compactMap { $0 }
        }
    }

    mutating func perform(desired: Bool, binding: Binding?, from peer: ObjectIdentifier,
                          now: TimeInterval, requestID: UUID? = nil) -> Data? {
        guard self.peer == peer else { return nil }
        revalidate(binding: binding)
        guard canSet(desired: desired), let context, context.binding == binding else { return nil }
        let requestID = requestID ?? UUID()
        guard pending?.request.requestID != requestID,
              pending?.stored.priorRawRequest.flatMap(Self.request)?.requestID != requestID,
              !retiredRequests.compactMap(Self.request).contains(where: { $0.requestID == requestID }),
              let request = try? SentryControlRequest(requestID: requestID,
                hostBootID: context.state.hostBootID, sessionID: context.state.sessionID,
                revision: context.state.revision,
                authorizationGeneration: context.control.authorizationGeneration, desired: desired) else { return nil }
        let prior = phase == .pending ? pending?.stored.rawRequest : nil
        let stored = Stored(binding: context.binding, rawRequest: request.rawRequest, priorRawRequest: prior,
                            ledgerAccepted: false, priorLedgerAccepted: prior == nil ? nil : pending?.stored.ledgerAccepted)
        guard persist(stored) else { return nil }
        pending = Pending(stored: stored, request: request)
        problem = nil
        return begin(request.rawRequest, now: now)
    }

    mutating func query(binding: Binding?, from peer: ObjectIdentifier, now: TimeInterval) -> Data? {
        guard self.peer == peer else { return nil }
        revalidate(binding: binding)
        guard canQuery, let pending, context?.binding == binding else { return nil }
        return begin(pending.stored.rawRequest, now: now)
    }

    private mutating func begin(_ raw: Data, now: TimeInterval) -> Data? {
        guard now.isFinite, now >= 0, let packet = Self.packet(raw) else { unconfirmed(); return nil }
        phase = .pending
        inFlight = true
        deadline = now + 10
        return packet
    }

    /// Called by the existing link measurement tick; no extra timer or freshness inference.
    mutating func checkTimeout(now: TimeInterval) {
        guard let deadline else { return }
        if !now.isFinite || now < deadline - 10 || now >= deadline { unconfirmed() }
    }

    mutating func unconfirmed() {
        if pending != nil || phase != .idle { phase = .unknown }
        inFlight = false
        deadline = nil
    }

    mutating func receive(_ data: Data, binding: Binding?, from peer: ObjectIdentifier) -> SentryState? {
        guard self.peer == peer else { return nil }
        revalidate(binding: binding)
        if data.count <= Self.responseCap, let reply = try? SentryControlResponse.decodePayload(data),
           isRetired(reply.state, binding: binding) { return nil }
        guard var pending, matches(pending), let context, context.binding == binding,
              data.count <= Self.responseCap,
              let reply = try? SentryControlResponse.decodePayload(data),
              reply.requestID == pending.request.requestID,
              IPadSentryObservation.isConsistent(reply.state),
              reply.state.hostBootID == context.state.hostBootID,
              reply.state.sessionID == context.state.sessionID,
              let control = reply.state.control,
              control.authorizationGeneration == context.control.authorizationGeneration else {
            unconfirmed()
            return nil
        }
        if reply.accepted && pending.stored.ledgerAccepted != true {
            let stored = Stored(binding: pending.stored.binding, rawRequest: pending.stored.rawRequest,
                                priorRawRequest: pending.stored.priorRawRequest,
                                ledgerAccepted: true, priorLedgerAccepted: pending.stored.priorLedgerAccepted)
            guard persist(stored) else { return nil }
            pending = Pending(stored: stored, request: pending.request)
            self.pending = pending
        }
        let state = reply.state
        switch (reply.operationState, reply.code) {
        case (.applied, .applied):
            guard reply.accepted,
                  pending.request.desired ? state.requested && state.phase == .userSessionProtected : !state.requested && state.phase == .inactive else {
                unconfirmed(); return nil
            }
            phase = .applied
        case (.pending, .pending): phase = .pending
        case (.unknown, .unknown): phase = .unknown
        case (.superseded, .superseded): phase = .superseded
        case (.rejected, let code): phase = .rejected(code.rawValue)
        default: unconfirmed(); return nil
        }
        inFlight = false
        deadline = nil
        self.context = Context(binding: context.binding, state: state, control: control)
        if case .rejected = phase {
            let rejection = statusText
            problem = rejection
            if !pending.request.desired, let raw = pending.stored.priorRawRequest,
               let request = Self.request(raw), request.desired {
                let stored = Stored(binding: pending.stored.binding, rawRequest: raw,
                                    priorRawRequest: pending.stored.rawRequest,
                                    ledgerAccepted: pending.stored.priorLedgerAccepted,
                                    priorLedgerAccepted: pending.stored.ledgerAccepted)
                if persist(stored) {
                    self.pending = Pending(stored: stored, request: request)
                } else {
                    problem = rejection + " " + (problem ?? "")
                }
                unconfirmed()
            }
        }
        return state
    }

    private func matches(_ pending: Pending) -> Bool {
        guard let context else { return false }
        return context.binding == pending.stored.binding &&
            context.state.hostBootID == pending.request.hostBootID &&
            context.control.authorizationGeneration == pending.request.authorizationGeneration
    }
    private mutating func revalidate(binding: Binding?) {
        if let context, context.binding != binding {
            self.context = nil
            unconfirmed()
        }
    }

    func permits(_ packet: Data, binding: Binding?, from peer: ObjectIdentifier) -> Bool {
        guard self.peer == peer, inFlight, let pending, matches(pending), context?.binding == binding else { return false }
        return Self.packet(pending.stored.rawRequest) == packet
    }
    private mutating func persist(_ stored: Stored) -> Bool {
        persist(active: stored, retired: retired)
    }
    private mutating func persist(active: Stored?, retired: [Retired]) -> Bool {
        do {
            let data: Data
            if retired.isEmpty, let active {
                data = try JSONEncoder().encode(active)
            } else {
                data = try JSONEncoder().encode(Ledger(version: 3, active: active, retired: retired))
            }
            try store.save(data)
            guard store.load() == data else { throw StoreFailure.unconfirmed }
            return true
        } catch {
            problem = "센트리 요청 저장을 확인하지 못했습니다. 원래 요청을 보존하고 결과를 다시 확인하세요."
            unconfirmed()
            return false
        }
    }
    private static func validStored(_ stored: Stored) -> Bool {
        stored.binding.hostPin.count == 32 && stored.binding.deviceFingerprint.count == 32 &&
        !stored.binding.macID.isEmpty && Self.request(stored.rawRequest).map { validPrior(stored.priorRawRequest, for: $0) } == true
    }
    private static func epoch(_ stored: Stored) -> Epoch? {
        request(stored.rawRequest).map { .init(binding: stored.binding, hostBootID: $0.hostBootID,
            sessionID: $0.sessionID, authorizationGeneration: $0.authorizationGeneration) }
    }
    private static func validRetired(_ retired: Retired) -> Bool {
        let epoch = retired.epoch
        guard epoch.binding.hostPin.count == 32, epoch.binding.deviceFingerprint.count == 32,
              !epoch.binding.macID.isEmpty else { return false }
        guard let stored = retired.request else { return true }
        return validStored(stored) && Self.epoch(stored) == epoch
    }
    private func isRetired(_ state: SentryState, binding: Binding?) -> Bool {
        guard let binding, let control = state.control else { return false }
        let epoch = Epoch(binding: binding, hostBootID: state.hostBootID, sessionID: state.sessionID,
                          authorizationGeneration: control.authorizationGeneration)
        return retired.contains { $0.epoch == epoch }
    }
    func isRetired(catalog: Data, binding: Binding?, from peer: ObjectIdentifier) -> Bool {
        guard self.peer == peer, let state = IPadSentryObservation.decodeCatalog(catalog) else { return false }
        return isRetired(state, binding: binding)
    }
    private static func request(_ raw: Data) -> SentryControlRequest? {
        try? SentryControlRequest(rawRequest: raw)
    }
    private static func validPrior(_ raw: Data?, for request: SentryControlRequest) -> Bool {
        guard let raw else { return true }
        guard let prior = Self.request(raw) else { return false }
        return prior.requestID != request.requestID && prior.desired != request.desired &&
            prior.hostBootID == request.hostBootID &&
            prior.authorizationGeneration == request.authorizationGeneration
    }
    static func packet(_ raw: Data) -> Data? {
        guard request(raw) != nil else { return nil }
        return StreamMessage(kind: .activateSentry, timestamp: 0, isKeyframe: false, payload: raw).serialized()
    }

    var statusText: String {
        switch phase {
        case .idle: return ""
        case .pending: return "센트리 요청 결과 대기 중"
        case .unknown:
            if let pending, matches(pending), pending.stored.ledgerAccepted != true,
               pending.request.sessionID == context?.state.sessionID {
                return "호스트 접수 미확인 · 연결을 다시 맺은 뒤 원래 요청 결과를 확인하세요."
            }
            return "센트리 요청 결과 미확인 · 원래 요청 보존"
        case .applied: return "센트리 요청 적용 확인"
        case .superseded: return "다른 명시 요청으로 대체됨 · 현재 호스트 보고 확인"
        case .rejected(let code):
            switch code {
            case "SENTRY_UNSUPPORTED": return "호스트가 센트리 제어를 지원하지 않습니다."
            case "SENTRY_NOT_AUTHORIZED": return "센트리 제어 권한이 확인되지 않았습니다."
            case "SENTRY_STALE_STATE": return "센트리 상태가 변경되어 요청이 거절되었습니다."
            case "SENTRY_REQUEST_CONFLICT": return "센트리 요청 원문이 일치하지 않습니다."
            case "SENTRY_BUSY": return "호스트가 다른 센트리 요청을 처리 중입니다."
            case "SENTRY_CONTROL_FAILED": return "호스트에서 센트리 제어를 완료하지 못했습니다."
            case "SENTRY_TARGET_UNCONFIRMED": return "호스트의 센트리 적용 대상을 확인하지 못했습니다."
            default: return "다른 명시 요청으로 대체되었습니다."
            }
        }
    }
}
