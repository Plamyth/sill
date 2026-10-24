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
    }
    private struct Pending {
        let stored: Stored
        let request: Request
    }
    private struct Context {
        let binding: Binding
        let state: SentryState
        let control: Control
    }
    private enum StoreFailure: Error { case unconfirmed }

    // Private transport DTOs are replaced by the Host's exact Swift DTOs when supplied.
    private struct Request: Codable {
        let version: Int
        let requestID: String
        let hostBootID: String
        let sessionID: String
        let revision: String
        let authorizationGeneration: String
        let desired: Bool

        var isValid: Bool {
            version == 2 && [requestID, hostBootID, sessionID, revision, authorizationGeneration]
                .allSatisfy(IPadSentryControl.canonicalUUID)
        }
    }
    private struct Control: Decodable {
        let version: Int
        let role: String
        let authorizationGeneration: String
        let canSet: Bool
        let manualIntent: String

        var isValid: Bool {
            version == 2 && role == "ownerDevice" && canSet &&
                IPadSentryControl.canonicalUUID(authorizationGeneration) &&
                ["automatic", "on", "off"].contains(manualIntent)
        }
    }
    private struct Report: Decodable {
        let state: SentryState
        let control: Control?
        private enum CodingKeys: String, CodingKey { case control }
        init(from decoder: Decoder) throws {
            state = try SentryState(from: decoder)
            control = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Control.self, forKey: .control)
        }
    }
    private struct Catalog: Decodable { let sentry: Report? }
    private struct Reply: Decodable {
        let version: Int
        let requestID: String
        let accepted: Bool
        let operationState: String
        let code: String
        let state: Report
    }

    static let requestKind: UInt8 = 213
    static let responseKind: UInt8 = 214
    static let requestCap = 512
    static let responseCap = 4096
    private static let rejectionCodes: Set<String> = [
        "SENTRY_UNSUPPORTED", "SENTRY_NOT_AUTHORIZED", "SENTRY_STALE_STATE", "SENTRY_REQUEST_CONFLICT",
        "SENTRY_BUSY", "SENTRY_CONTROL_FAILED", "SENTRY_TARGET_UNCONFIRMED", "SENTRY_SUPERSEDED"
    ]
    private let store: Store
    private var peer: ObjectIdentifier?
    private var context: Context?
    private var pending: Pending?
    private var inFlight = false
    private var deadline: TimeInterval?
    private(set) var phase: Phase = .idle
    private(set) var problem: String?

    init(store: Store) {
        self.store = store
        guard let data = store.load() else { return }
        phase = .unknown
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.binding.hostPin.count == 32, stored.binding.deviceFingerprint.count == 32,
              !stored.binding.macID.isEmpty,
              let request = Self.request(stored.rawRequest) else {
            problem = "이전 센트리 요청 저장 내용을 확인하지 못했습니다."
            return
        }
        pending = Pending(stored: stored, request: request)
    }

    mutating func bind(_ next: ObjectIdentifier?) {
        guard peer != next else { return }
        peer = next
        context = nil
        unconfirmed()
    }

    mutating func observe(catalog: Data, observation: IPadSentryObservation, binding: Binding?, from peer: ObjectIdentifier) {
        guard self.peer == peer else { return }
        guard case .reported(let state) = observation.status,
              let binding, let report = try? JSONDecoder().decode(Catalog.self, from: catalog).sentry,
              report.state == state, let control = report.control, control.isValid else {
            context = nil
            unconfirmed()
            return
        }
        if let previous = context,
           previous.binding != binding || previous.state.hostBootID != state.hostBootID ||
           previous.state.sessionID != state.sessionID || previous.control.authorizationGeneration != control.authorizationGeneration {
            unconfirmed()
        }
        context = Context(binding: binding, state: state, control: control)
        if let pending, !matches(pending) { unconfirmed() }
    }

    var canSet: Bool {
        guard context != nil, peer != nil, !inFlight else { return false }
        if pending == nil { return phase == .idle }
        switch phase {
        case .applied, .rejected, .superseded: return true
        default: return false
        }
    }
    var canQuery: Bool {
        guard let pending, !inFlight else { return false }
        return matches(pending)
    }
    var originalRequest: Data? { pending?.stored.rawRequest }

    mutating func perform(desired: Bool, binding: Binding?, from peer: ObjectIdentifier,
                          now: TimeInterval, requestID: UUID? = nil) -> Data? {
        guard self.peer == peer else { return nil }
        revalidate(binding: binding)
        guard canSet, let context, context.binding == binding else { return nil }
        let requestID = requestID ?? UUID()
        guard pending?.request.requestID != requestID.uuidString.lowercased() else { return nil }
        let request = Request(version: 2, requestID: requestID.uuidString.lowercased(),
            hostBootID: context.state.hostBootID.uuidString.lowercased(), sessionID: context.state.sessionID.uuidString.lowercased(),
            revision: context.state.revision.uuidString.lowercased(),
            authorizationGeneration: context.control.authorizationGeneration, desired: desired)
        guard let raw = try? JSONEncoder().encode(request), Self.request(raw) != nil else { return nil }
        let stored = Stored(binding: context.binding, rawRequest: raw)
        guard let data = try? JSONEncoder().encode(stored) else { return nil }
        do {
            try store.save(data)
            guard store.load() == data else { throw StoreFailure.unconfirmed }
        } catch {
            problem = "센트리 요청을 저장하지 못해 전송하지 않았습니다."
            return nil
        }
        pending = Pending(stored: stored, request: request)
        problem = nil
        return begin(raw, now: now)
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
        guard let pending, matches(pending), let context, context.binding == binding,
              data.count <= Self.responseCap,
              let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.version == 2,
              Self.canonicalUUID(reply.requestID), reply.requestID == pending.request.requestID,
              IPadSentryObservation.isConsistent(reply.state.state),
              reply.state.state.hostBootID == context.state.hostBootID,
              reply.state.state.sessionID == context.state.sessionID,
              let control = reply.state.control, control.isValid,
              control.authorizationGeneration == context.control.authorizationGeneration else {
            unconfirmed()
            return nil
        }
        let state = reply.state.state
        switch (reply.operationState, reply.code) {
        case ("applied", "SENTRY_APPLIED"):
            guard reply.accepted,
                  pending.request.desired ? state.requested && state.phase == .userSessionProtected : !state.requested && state.phase == .inactive else {
                unconfirmed(); return nil
            }
            phase = .applied
        case ("pending", "SENTRY_PENDING"): phase = .pending
        case ("unknown", "SENTRY_UNKNOWN"): phase = .unknown
        case ("superseded", "SENTRY_SUPERSEDED"): phase = .superseded
        case ("rejected", let code) where !reply.accepted && Self.rejectionCodes.contains(code): phase = .rejected(code)
        default: unconfirmed(); return nil
        }
        inFlight = false
        deadline = nil
        problem = nil
        self.context = Context(binding: context.binding, state: state, control: control)
        return state
    }

    private func matches(_ pending: Pending) -> Bool {
        guard let context else { return false }
        return context.binding == pending.stored.binding &&
            context.state.hostBootID.uuidString.lowercased() == pending.request.hostBootID &&
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
    private static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
    private static func request(_ raw: Data) -> Request? {
        guard !raw.isEmpty, raw.count <= requestCap,
              let request = try? JSONDecoder().decode(Request.self, from: raw), request.isValid else { return nil }
        return request
    }
    static func packet(_ raw: Data) -> Data? {
        guard request(raw) != nil else { return nil }
        return StreamMessage(kind: .activateSentry, timestamp: 0, isKeyframe: false, payload: raw).serialized()
    }

    var statusText: String {
        switch phase {
        case .idle: return ""
        case .pending: return "센트리 요청 결과 대기 중"
        case .unknown: return "센트리 요청 결과 미확인 · 원래 요청 보존"
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
