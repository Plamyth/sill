import Foundation
import StreamProtocol

struct VisionProviderCall {
    struct Pending {
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
    private var lastQueryAt: TimeInterval?
    private let clock: () -> TimeInterval

    init(connection: UUID, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.connection = connection; self.clock = clock
    }
    var canPerform: Bool {
        supported && pending == nil && (request == nil || result.map { [.started, .stopped, .failed, .unsupported].contains($0.status) } == true)
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
            self = VisionProviderCall(connection: next, clock: clock)
            self.hostKey = trusted
        }
        if connection != next { disconnected(); connection = next }
        supported = capability == 1
    }
    mutating func disconnected() {
        supported = false
        pending = nil
        if let request, result == nil || result?.status == .pending {
            result = try? .init(requestId: request.requestId, status: .unknown, reason: "provider_connection_changed")
        }
    }
    mutating func perform(_ value: ProviderCallRequest) -> ProviderCallControl? {
        let now = clock()
        guard canPerform, now.isFinite, now >= 0 else { return nil }
        request = value; result = nil; firstSentAt = now; queries = 0; lastQueryAt = nil
        return enqueue(.init(operation: .perform, request: value), now: now)
    }
    mutating func query() -> ProviderCallControl? {
        let now = clock()
        guard supported, pending == nil, let request, let firstSentAt,
              result == nil || result?.status == .pending || result?.status == .unknown else { return nil }
        guard now.isFinite, now >= firstSentAt, now - firstSentAt < 10, queries < 4 else {
            result = try? .init(requestId: request.requestId, status: .unknown, reason: "provider_query_budget_exhausted")
            return nil
        }
        guard lastQueryAt.map({ now >= $0 && now - $0 >= 0.5 }) ?? true else { return nil }
        queries += 1; lastQueryAt = now
        return enqueue(.init(operation: .query, request: request), now: now)
    }
    private mutating func enqueue(_ control: ProviderCallControl, now: TimeInterval) -> ProviderCallControl {
        pending = .init(control: control, connection: connection, sentAt: now,
                        expiresAt: min(now + 10, (firstSentAt ?? now) + 10))
        return control
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
        result = supported ? state.result : try? .init(requestId: pending.control.request.requestId,
            status: .unknown, reason: "provider_authentication_unverified")
        return true
    }
    mutating func drain(_ state: ProviderCallState, from incoming: UUID) -> Bool {
        supported = false
        return receive(state, from: incoming)
    }
    mutating func timeout(_ pending: Pending) -> Bool {
        guard self.pending?.connection == pending.connection,
              self.pending?.sentAt == pending.sentAt,
              self.pending?.control.request == pending.control.request else { return false }
        let now = clock()
        guard !now.isFinite || now < pending.sentAt || now >= pending.expiresAt else { return false }
        self.pending = nil
        supported = false
        result = try? .init(requestId: pending.control.request.requestId, status: .unknown, reason: "provider_response_timeout")
        return true
    }
    var message: String {
        if pending != nil { return "통화 상태를 확인하고 있습니다." }
        guard let result else { return supported ? "통화와 음성 입출력 상태는 각각 확인합니다." : "이 Mac 연결은 통화 제어를 지원하지 않습니다." }
        switch result.status {
        case .started: return "Mac 통화 화면에서 시작을 확인했습니다."
        case .stopped: return "Mac 통화 화면에서 종료를 확인했습니다."
        case .pending: return "통화 연결 결과를 기다립니다."
        case .unsupported: return "현재 Mac 통화 화면에서는 이 동작을 확인할 수 없습니다."
        case .failed: return "통화 명령을 완료하지 못했습니다. 음성 연결과 Mac 통화 화면을 확인하세요."
        case .unknown: return "통화 결과를 확인하지 못했습니다. 자동으로 다시 누르지 않습니다. Mac 통화 화면을 확인하세요."
        }
    }
}

#if os(visionOS)
import Network

extension StreamClient {
    var visionProviderCanStart: Bool {
        visionProviderCall.hostKey == visionAudioTrustedHostKey && visionProviderCall.canPerform && visionProviderCall.result?.status != .started &&
            visionForwarding?.binding != nil && visionAudioIntentContext.admitted
    }
    var visionProviderCanStop: Bool {
        visionProviderCall.hostKey == visionAudioTrustedHostKey && visionProviderCall.canPerform && visionProviderCall.result?.status == .started &&
            visionProviderCall.result?.callSessionId != nil && visionForwarding?.binding != nil && visionAudioIntentContext.admitted
    }
    func performVisionProviderCall(_ action: ProviderCallRequest.Action) {
        guard action == .start ? visionProviderCanStart : visionProviderCanStop,
              let peer = connection, authenticatedVisionMacAudioPeer == ObjectIdentifier(peer),
              let model = visionForwarding, let snapshot = model.snapshot, model.binding != nil,
              let request = try? ProviderCallRequest(requestId: UUID(), action: action,
                expectedLeaseRevision: snapshot.revision, pairedDeviceId: model.device,
                desiredInput: visionForwardingDesire.microphone, desiredOutput: visionForwardingDesire.playback,
                callSessionId: action == .stop ? visionProviderCall.result?.callSessionId : nil),
              let control = visionProviderCall.perform(request) else { return }
        sendVisionProviderCall(control, to: peer)
    }
    func observeVisionProviderCalls(_ list: WindowList, from peer: NWConnection) {
        guard connection === peer else { return }
        visionProviderCall.observe(connection: visionAudioIntentConnection, capability: list.providerCalls, hostKey: visionAudioTrustedHostKey)
        scheduleVisionProviderQuery(peer)
    }
    private func sendVisionProviderCall(_ control: ProviderCallControl, to peer: NWConnection) {
        let generation = visionAudioIntentConnection
        guard visionProviderCall.connection == generation, let pending = visionProviderCall.pending else { return }
        let payload = Wire.encode(control)
        guard !payload.isEmpty, payload.count <= StreamMessage.clientPayloadLimit(for: .providerCallControl) else { return }
        peer.send(content: StreamMessage(kind: .providerCallControl, timestamp: Date().timeIntervalSince1970,
            isKeyframe: false, payload: payload).serialized(), completion: .contentProcessed { [weak self] error in
                if let error { self?.connectionLost(peer, error: error) }
            })
        let remaining = max(0, pending.expiresAt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak peer] in
            guard let self, let peer, self.connection === peer, self.visionAudioIntentConnection == generation,
                  self.visionProviderCall.timeout(pending) else { return }
            peer.cancel()
            self.connectionLost(peer, error: .posix(.ETIMEDOUT))
        }
    }
    private func scheduleVisionProviderQuery(_ peer: NWConnection) {
        let generation = visionAudioIntentConnection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak peer] in
            guard let self, let peer, self.connection === peer, self.visionAudioIntentConnection == generation,
                  self.authenticatedVisionMacAudioPeer == ObjectIdentifier(peer), self.visionAudioIntentContext.admitted,
                  let control = self.visionProviderCall.query() else { return }
            self.sendVisionProviderCall(control, to: peer)
        }
    }
    func receiveVisionProviderCall(_ header: StreamHeader, _ data: Data, from peer: NWConnection) -> Bool {
        guard header.kind == .providerCallState else { return false }
        DispatchQueue.main.async { [weak self, weak peer] in
            guard let self, let peer, self.connection === peer,
                  data.count <= StreamMessage.hostPayloadLimit(for: .providerCallState),
                  let state = Wire.decode(ProviderCallState.self, from: data) else { return }
            guard self.authenticatedVisionMacAudioPeer == ObjectIdentifier(peer),
                  self.visionProviderCall.hostKey == self.visionAudioTrustedHostKey else {
                _ = self.visionProviderCall.drain(state, from: self.visionAudioIntentConnection)
                return
            }
            guard self.visionProviderCall.receive(state, from: self.visionAudioIntentConnection) else { return }
            self.scheduleVisionProviderQuery(peer)
        }
        return true
    }
}
#endif
