import Foundation
import StreamProtocol

enum IPadCallTarget: String, CaseIterable, Identifiable {
    case nativeCodex, chatGPTDots, grokBot
    static let defaultTarget = Self.nativeCodex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nativeCodex: "Mac 순정 Codex 음성"
        case .chatGPTDots: "ChatGPT Dots"
        case .grokBot: "Grok Bot"
        }
    }
    var providerKind: ProviderCallKind? {
        switch self {
        case .nativeCodex: .nativeCodex
        case .chatGPTDots: .chatgptDots
        case .grokBot: nil
        }
    }
    var supportsProviderCall: Bool { providerKind != nil }

    /// Decode only the confirmed prepared-target payload. Delivery, final-event matching,
    /// authorization and media remain separate contracts; this never sends 221 or starts audio.
    func preparedNativeTarget(from data: Data) throws -> CodexRealtimePreparedTarget {
        guard self == .nativeCodex else { throw ProviderCallWireFailure.invalidTarget }
        return try JSONDecoder().decode(CodexRealtimePreparedTarget.self, from: data)
    }
}

struct IPadProviderCall {
    struct Pending {
        let id = UUID()
        let manual: Bool
        let control: ProviderCallControl
        let connection: UUID
        let sentAt: TimeInterval
        let expiresAt: TimeInterval
    }
    private(set) var connection: UUID
    private(set) var target: IPadCallTarget
    private(set) var nativeSupported = false
    private(set) var requestProviderKind: ProviderCallKind?
    private(set) var activeCall: ProviderCallResult?
    private(set) var supported = false
    private(set) var hostKey: String?
    private(set) var pending: Pending?
    private(set) var request: ProviderCallRequest?
    private(set) var result: ProviderCallResult?
    private(set) var firstSentAt: TimeInterval?
    private(set) var queries = 0
    private(set) var historicalResult: ProviderCallResult?
    private var automaticFinished = false
    private var timedOut = false
    private var lastQueryAt: TimeInterval?
    private let clock: () -> TimeInterval

    init(connection: UUID, target: IPadCallTarget = .chatGPTDots, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.connection = connection; self.target = target; self.clock = clock
    }
    var canChangeTarget: Bool {
        !timedOut && activeCall == nil && pending == nil && (request == nil ||
            result.map { [.stopped, .failed, .unsupported].contains($0.status) } == true)
    }
    @discardableResult
    mutating func selectTarget(_ next: IPadCallTarget) -> Bool {
        guard next != target else { return true }
        guard canChangeTarget else { return false }
        target = next
        return true
    }
    var targetSupported: Bool {
        switch target {
        case .nativeCodex: nativeSupported
        case .chatGPTDots: supported
        case .grokBot: false
        }
    }
    var selectedResult: ProviderCallResult? {
        result?.provider == target.providerKind?.rawValue ? result : nil
    }
    var selectedActiveCall: ProviderCallResult? {
        activeCall?.provider == target.providerKind?.rawValue ? activeCall : nil
    }
    var canPerform: Bool {
        guard !timedOut, targetSupported, pending == nil else { return false }
        if activeCall != nil { return selectedActiveCall != nil && result?.status != .pending }
        return request == nil || result.map { [.stopped, .failed, .unsupported].contains($0.status) } == true
    }
    mutating func observe(connection next: UUID, capability: Int?, hostKey: String?, providerCallKinds: [String]? = nil) {
        let trusted = hostKey.flatMap { $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil ? $0 : nil }
        guard let trusted else {
            supported = false; nativeSupported = false
            if connection != next { disconnected(); connection = next }
            return
        }
        if self.hostKey != trusted {
            if activeCall != nil {
                supported = false; nativeSupported = false
                if connection != next { disconnected(); connection = next }
                return
            }
            guard pending == nil || connection != next else { supported = false; nativeSupported = false; return }
            self = IPadProviderCall(connection: next, target: target, clock: clock)
            self.hostKey = trusted
        }
        if connection != next { disconnected(); connection = next }
        supported = capability == 1 && !timedOut
        nativeSupported = supported && providerCallKinds?.contains(ProviderCallKind.nativeCodex.rawValue) == true
    }
    mutating func disconnected() {
        supported = false; nativeSupported = false
        pending = nil
        timedOut = false
        if let request {
            result = try? .init(requestId: request.requestId, status: .unknown, reason: "provider_connection_changed", provider: requestProviderKind?.rawValue ?? ProviderCallKind.chatgptDots.rawValue)
        }
    }
    mutating func perform(_ value: ProviderCallRequest) -> ProviderCallControl? {
        let now = clock()
        guard canPerform, let kind = target.providerKind, now.isFinite, now >= 0 else { return nil }
        if value.action == .start { guard activeCall == nil else { return nil } }
        else {
            guard let active = selectedActiveCall, active.callSessionId != nil,
                  active.callSessionId == value.callSessionId else { return nil }
        }
        requestProviderKind = kind
        request = value; result = nil; firstSentAt = now; queries = 0; lastQueryAt = now
        historicalResult = nil; automaticFinished = false
        return enqueue(.init(operation: .perform, request: value, providerKind: kind), now: now)
    }
    mutating func query() -> ProviderCallControl? {
        let now = clock()
        guard targetSupported, requestProviderKind == target.providerKind, !automaticFinished, pending == nil, let request, let firstSentAt,
              result == nil || result?.status == .pending || result?.status == .unknown else { return nil }
        guard now.isFinite, now >= firstSentAt, now - firstSentAt < 10, queries < 4 else {
            automaticFinished = true
            result = try? .init(requestId: request.requestId, status: .unknown, reason: "provider_query_budget_exhausted", provider: requestProviderKind?.rawValue ?? ProviderCallKind.chatgptDots.rawValue)
            return nil
        }
        guard lastQueryAt.map({ now >= $0 && now - $0 >= 0.5 }) ?? true else { return nil }
        queries += 1; lastQueryAt = now
        return enqueue(.init(operation: .query, request: request, providerKind: requestProviderKind ?? .chatgptDots), now: now)
    }
    private mutating func enqueue(_ control: ProviderCallControl, now: TimeInterval, manual: Bool = false) -> ProviderCallControl {
        pending = .init(manual: manual, control: control, connection: connection, sentAt: now,
                        expiresAt: manual ? now + 10 : min(now + 10, (firstSentAt ?? now) + 10))
        return control
    }
    var needsAutomaticQuery: Bool {
        targetSupported && requestProviderKind == target.providerKind && !timedOut && !automaticFinished && pending == nil && request != nil &&
            (result == nil || result?.status == .pending || result?.status == .unknown)
    }
    var canManuallyQuery: Bool {
        let now = clock()
        guard targetSupported, requestProviderKind == target.providerKind, !timedOut, pending == nil, request != nil, let firstSentAt,
              now.isFinite, now >= firstSentAt, queries >= 4 || now - firstSentAt >= 10 else { return false }
        return result == nil || result?.status == .pending || result?.status == .unknown
    }
    mutating func manualQuery() -> ProviderCallControl? {
        guard canManuallyQuery, let request else { return nil }
        automaticFinished = true
        return enqueue(.init(operation: .query, request: request, providerKind: requestProviderKind ?? .chatgptDots), now: clock(), manual: true)
    }
    @discardableResult
    mutating func receive(_ state: ProviderCallState, from incoming: UUID) -> Bool {
        let now = clock()
        guard let pending, incoming == connection, pending.connection == incoming,
              state.requestDigest == pending.control.request.digest,
              state.result.requestId == pending.control.request.requestId,
              state.result.provider == pending.control.providerKind.rawValue,
              requestProviderKind == pending.control.providerKind, target.providerKind == pending.control.providerKind,
              now.isFinite, now >= pending.sentAt, now < pending.expiresAt else { return false }
        guard state.result.status != .started || pending.control.request.action == .start,
              state.result.status != .stopped || pending.control.request.action == .stop else { return false }
        if pending.control.providerKind == .nativeCodex && [.started, .stopped].contains(state.result.status) {
            guard let session = state.result.callSessionId, UUID(uuidString: session) != nil else { return false }
            if state.result.status == .stopped && session != pending.control.request.callSessionId { return false }
        }
        if state.result.status == .stopped && pending.control.operation == .perform {
            guard let active = selectedActiveCall, active.callSessionId != nil,
                  active.callSessionId == pending.control.request.callSessionId,
                  state.result.callSessionId == nil || state.result.callSessionId == active.callSessionId else { return false }
        }
        self.pending = nil
        if !targetSupported {
            result = try? .init(requestId: pending.control.request.requestId, status: .unknown,
                                reason: "provider_authentication_unverified", provider: pending.control.providerKind.rawValue)
        } else if pending.control.operation == .query {
            // A journal result describes the old request, never current call or media ownership.
            historicalResult = state.result
            if pending.manual || state.result.status != .pending {
                automaticFinished = true
                result = try? .init(requestId: pending.control.request.requestId, status: .unknown,
                                    reason: "provider_historical_result", provider: pending.control.providerKind.rawValue)
            } else { result = state.result }
        } else {
            result = state.result
            if state.result.status == .started { activeCall = state.result }
            if state.result.status == .stopped { activeCall = nil }
        }
        return true
    }
    mutating func drain(_ state: ProviderCallState, from incoming: UUID) -> Bool {
        supported = false; nativeSupported = false
        return receive(state, from: incoming)
    }
    mutating func timeout(_ pending: Pending) -> Bool {
        guard !timedOut, self.pending?.id == pending.id else { return false }
        let now = clock()
        guard !now.isFinite || now < pending.sentAt || now >= pending.expiresAt else { return false }
        // The physical slot stays occupied until this TLS is actually replaced.
        timedOut = true
        supported = false; nativeSupported = false
        result = try? .init(requestId: pending.control.request.requestId, status: .unknown, reason: "provider_response_timeout", provider: pending.control.providerKind.rawValue)
        return true
    }
    var message: String {
        if timedOut { return "통화 응답 기한이 지나 연결을 닫습니다. 이전 요청은 자동으로 실행하지 않습니다." }
        if pending != nil { return "통화 상태를 확인하고 있습니다." }
        if target == .nativeCodex {
            guard let result = selectedResult else {
                return targetSupported ? "통화와 음성 입출력 상태는 각각 확인합니다." : "이 Mac 연결은 순정 Codex 음성 대화 제어를 지원하지 않습니다."
            }
            switch result.status {
            case .started: return "Mac이 순정 Codex 음성 대화 시작을 확인했습니다."
            case .stopped: return "Mac이 순정 Codex 음성 대화 종료를 확인했습니다."
            case .pending: return "순정 Codex 음성 대화 응답을 기다립니다."
            case .unsupported: return "이 Mac은 순정 Codex 음성 대화 제어를 지원하지 않습니다."
            case .failed: return "Mac이 순정 Codex 음성 대화 명령을 완료하지 못했습니다."
            case .unknown: return "순정 Codex 음성 대화 결과를 확인하지 못했습니다."
            }
        }
        let name = "ChatGPT Dots 통화"
        guard let result = selectedResult else { return targetSupported ? "통화와 음성 입출력 상태는 각각 확인합니다." : "이 Mac 연결은 \(name) 제어를 지원하지 않습니다." }
        switch result.status {
        case .started: return "\(name) 화면에서 시작을 확인했습니다."
        case .stopped: return "\(name) 화면에서 종료를 확인했습니다."
        case .pending: return "통화 연결 결과를 기다립니다."
        case .unsupported: return "현재 \(name) 화면에서는 이 동작을 확인할 수 없습니다."
        case .failed: return "통화 명령을 완료하지 못했습니다. 음성 연결과 \(name) 화면을 확인하세요."
        case .unknown: return "통화 결과를 확인하지 못했습니다. 자동으로 다시 누르지 않습니다. \(name) 화면을 확인하세요."
        }
    }

    var historicalMessage: String? {
        guard let historicalResult, historicalResult.provider == target.providerKind?.rawValue else { return nil }
        let status: String
        switch historicalResult.status {
        case .started: status = "시작 확인"
        case .stopped: status = "종료 확인"
        case .pending: status = "처리 중"
        case .failed: status = "실패"
        case .unsupported: status = "지원 안 함"
        case .unknown: status = "확인 불가"
        }
        if target == .nativeCodex {
            return "이전 Mac 응답 기록: \(status). 현재 통화나 음성 입출력 상태는 미확인입니다."
        }
        let name = "ChatGPT Dots 통화"
        return "이전 요청 기록: \(status). 현재 통화나 미디어 사용 권한을 확인한 결과가 아닙니다. \(name) 화면을 직접 확인하세요."
    }
}
