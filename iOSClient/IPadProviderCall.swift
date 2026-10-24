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
    var supportsProviderCall: Bool { self == .chatGPTDots }
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

    init(connection: UUID, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.connection = connection; self.clock = clock
    }
    var canPerform: Bool {
        !timedOut && supported && pending == nil && (request == nil || result.map { [.started, .stopped, .failed, .unsupported].contains($0.status) } == true)
    }
    mutating func observe(connection next: UUID, capability: Int?, hostKey: String?) {
        let trusted = hostKey.flatMap { $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil ? $0 : nil }
        guard let trusted else {
            supported = false
            if connection != next { disconnected(); connection = next }
            return
        }
        if self.hostKey != trusted {
            guard pending == nil || connection != next else { supported = false; return }
            self = IPadProviderCall(connection: next, clock: clock)
            self.hostKey = trusted
        }
        if connection != next { disconnected(); connection = next }
        supported = capability == 1 && !timedOut
    }
    mutating func disconnected() {
        supported = false
        pending = nil
        timedOut = false
        if let request {
            result = try? .init(requestId: request.requestId, status: .unknown, reason: "provider_connection_changed")
        }
    }
    mutating func perform(_ value: ProviderCallRequest) -> ProviderCallControl? {
        let now = clock()
        guard canPerform, now.isFinite, now >= 0 else { return nil }
        request = value; result = nil; firstSentAt = now; queries = 0; lastQueryAt = now
        historicalResult = nil; automaticFinished = false
        return enqueue(.init(operation: .perform, request: value), now: now)
    }
    mutating func query() -> ProviderCallControl? {
        let now = clock()
        guard supported, !automaticFinished, pending == nil, let request, let firstSentAt,
              result == nil || result?.status == .pending || result?.status == .unknown else { return nil }
        guard now.isFinite, now >= firstSentAt, now - firstSentAt < 10, queries < 4 else {
            automaticFinished = true
            result = try? .init(requestId: request.requestId, status: .unknown, reason: "provider_query_budget_exhausted")
            return nil
        }
        guard lastQueryAt.map({ now >= $0 && now - $0 >= 0.5 }) ?? true else { return nil }
        queries += 1; lastQueryAt = now
        return enqueue(.init(operation: .query, request: request), now: now)
    }
    private mutating func enqueue(_ control: ProviderCallControl, now: TimeInterval, manual: Bool = false) -> ProviderCallControl {
        pending = .init(manual: manual, control: control, connection: connection, sentAt: now,
                        expiresAt: manual ? now + 10 : min(now + 10, (firstSentAt ?? now) + 10))
        return control
    }
    var needsAutomaticQuery: Bool {
        supported && !timedOut && !automaticFinished && pending == nil && request != nil &&
            (result == nil || result?.status == .pending || result?.status == .unknown)
    }
    var canManuallyQuery: Bool {
        let now = clock()
        guard supported, !timedOut, pending == nil, request != nil, let firstSentAt,
              now.isFinite, now >= firstSentAt, queries >= 4 || now - firstSentAt >= 10 else { return false }
        return result == nil || result?.status == .pending || result?.status == .unknown
    }
    mutating func manualQuery() -> ProviderCallControl? {
        guard canManuallyQuery, let request else { return nil }
        automaticFinished = true
        return enqueue(.init(operation: .query, request: request), now: clock(), manual: true)
    }
    @discardableResult
    mutating func receive(_ state: ProviderCallState, from incoming: UUID) -> Bool {
        let now = clock()
        guard let pending, incoming == connection, pending.connection == incoming,
              state.requestDigest == pending.control.request.digest,
              state.result.requestId == pending.control.request.requestId,
              now.isFinite, now >= pending.sentAt, now < pending.expiresAt else { return false }
        guard state.result.status != .started || pending.control.request.action == .start,
              state.result.status != .stopped || pending.control.request.action == .stop else { return false }
        self.pending = nil
        if !supported {
            result = try? .init(requestId: pending.control.request.requestId, status: .unknown,
                                reason: "provider_authentication_unverified")
        } else if pending.control.operation == .query {
            // A journal result describes the old request, never current call or media ownership.
            historicalResult = state.result
            if pending.manual || state.result.status != .pending {
                automaticFinished = true
                result = try? .init(requestId: pending.control.request.requestId, status: .unknown,
                                    reason: "provider_historical_result")
            } else { result = state.result }
        } else { result = state.result }
        return true
    }
    mutating func drain(_ state: ProviderCallState, from incoming: UUID) -> Bool {
        supported = false
        return receive(state, from: incoming)
    }
    mutating func timeout(_ pending: Pending) -> Bool {
        guard !timedOut, self.pending?.id == pending.id else { return false }
        let now = clock()
        guard !now.isFinite || now < pending.sentAt || now >= pending.expiresAt else { return false }
        // The physical slot stays occupied until this TLS is actually replaced.
        timedOut = true
        supported = false
        result = try? .init(requestId: pending.control.request.requestId, status: .unknown, reason: "provider_response_timeout")
        return true
    }
    var message: String {
        if timedOut { return "통화 응답 기한이 지나 연결을 닫습니다. 이전 요청은 자동으로 실행하지 않습니다." }
        if pending != nil { return "통화 상태를 확인하고 있습니다." }
        guard let result else { return supported ? "통화와 음성 입출력 상태는 각각 확인합니다." : "이 Mac 연결은 ChatGPT Dots 통화 제어를 지원하지 않습니다." }
        switch result.status {
        case .started: return "ChatGPT Dots 통화 화면에서 시작을 확인했습니다."
        case .stopped: return "ChatGPT Dots 통화 화면에서 종료를 확인했습니다."
        case .pending: return "통화 연결 결과를 기다립니다."
        case .unsupported: return "현재 ChatGPT Dots 통화 화면에서는 이 동작을 확인할 수 없습니다."
        case .failed: return "통화 명령을 완료하지 못했습니다. 음성 연결과 ChatGPT Dots 통화 화면을 확인하세요."
        case .unknown: return "통화 결과를 확인하지 못했습니다. 자동으로 다시 누르지 않습니다. ChatGPT Dots 통화 화면을 확인하세요."
        }
    }

    var historicalMessage: String? {
        guard let historicalResult else { return nil }
        let status: String
        switch historicalResult.status {
        case .started: status = "시작 확인"
        case .stopped: status = "종료 확인"
        case .pending: status = "처리 중"
        case .failed: status = "실패"
        case .unsupported: status = "지원 안 함"
        case .unknown: status = "확인 불가"
        }
        return "이전 요청 기록: \(status). 현재 통화나 미디어 사용 권한을 확인한 결과가 아닙니다. ChatGPT Dots 통화 화면을 직접 확인하세요."
    }
}
