import Foundation
import StreamProtocol

enum VisionCallTarget: String, CaseIterable {
    case nativeCodex, chatgptDots, grok

    var providerKind: ProviderCallKind? {
        switch self {
        case .nativeCodex: return .nativeCodex
        case .chatgptDots: return .chatgptDots
        case .grok: return nil
        }
    }
    var title: String {
        switch self {
        case .nativeCodex: return "Mac Codex 음성"
        case .chatgptDots: return "ChatGPT Dots"
        case .grok: return "Grok"
        }
    }
}

// This consumes an authenticated producer observation. It cannot create a challenge,
// grant media authority, or enable provider control.
struct VisionNativePreparedCall {
    struct Fence: Equatable {
        let connection: UUID
        let hostKey: String
        let scope: VisionRemoteAudioIntent.Scope
        let coreGeneration: UUID
        let revision: AudioForwardingRevision
        let intentGeneration: UUID
        let bindingEpoch: UUID
        let transport: UUID

        init?(connection: UUID, context: VisionRemoteAudioIntent.Context,
              snapshot: AudioForwardingSnapshot, device: AudioForwardingDeviceID,
              coreGeneration: UUID, ownsAudio: Bool) {
            guard ownsAudio, context.admitted, context.protected,
                  let scope = context.scope, scope.connection == connection,
                  let key = context.hostKey,
                  key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let intent = snapshot.intent, let binding = snapshot.binding,
                  intent.pairedDeviceId == device, binding.pairedDeviceId == device,
                  intent.intentGeneration == binding.intentGeneration,
                  binding.transportKind == .native,
                  binding.phase == .active || binding.phase == .off else { return nil }
            self.connection = connection; hostKey = key; self.scope = scope
            self.coreGeneration = coreGeneration; revision = snapshot.revision
            intentGeneration = intent.intentGeneration; bindingEpoch = binding.bindingEpoch
            transport = binding.transportId
        }
    }
    let target: CodexRealtimePreparedTarget
    let fence: Fence
    let observedAt: TimeInterval
    let expiresAt: TimeInterval

    init?(target: CodexRealtimePreparedTarget, challengeTargetHash: String,
          coreGeneration: UUID, fence: Fence, observedAt: TimeInterval, expiresAt: TimeInterval) {
        guard (try? target.hash()) == challengeTargetHash,
              coreGeneration == fence.coreGeneration,
              observedAt.isFinite, observedAt >= 0, expiresAt.isFinite,
              expiresAt > observedAt, expiresAt - observedAt <= VisionAudioForwarding.freshness else { return nil }
        self.target = target; self.fence = fence
        self.observedAt = observedAt; self.expiresAt = expiresAt
    }
    func isCurrent(_ current: Fence, now: TimeInterval) -> Bool {
        fence == current && now.isFinite && now >= observedAt && now < expiresAt
    }
}

struct VisionProviderCall {
    struct Pending {
        let control: ProviderCallControl
        let connection: UUID
        let sentAt: TimeInterval
        let expiresAt: TimeInterval
    }
    private(set) var connection: UUID
    private(set) var target: VisionCallTarget
    private(set) var supported = false
    private(set) var nativeSupported = false
    private(set) var requestProviderKind: ProviderCallKind?
    private(set) var hostKey: String?
    private(set) var pending: Pending?
    private(set) var request: ProviderCallRequest?
    private(set) var result: ProviderCallResult?
    private(set) var firstSentAt: TimeInterval?
    private(set) var nativePreparation: VisionNativePreparedCall?
    private(set) var queries = 0
    private var lastQueryAt: TimeInterval?
    private let clock: () -> TimeInterval

    init(connection: UUID, target: VisionCallTarget = .nativeCodex,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.connection = connection; self.target = target; self.clock = clock
    }
    var canChangeTarget: Bool {
        pending == nil && (request == nil ||
            result.map { [.stopped, .failed, .unsupported].contains($0.status) } == true)
    }
    @discardableResult
    mutating func selectTarget(_ next: VisionCallTarget) -> Bool {
        guard next != target else { return true }
        guard canChangeTarget else { return false }
        nativePreparation = nil
        target = next
        return true
    }
    var targetSupported: Bool {
        switch target {
        case .nativeCodex: return nativeSupported
        case .chatgptDots: return supported
        case .grok: return false
        }
    }
    var selectedResult: ProviderCallResult? {
        result?.provider == target.providerKind?.rawValue ? result : nil
    }
    var canPerform: Bool {
        targetSupported && pending == nil &&
            (request == nil || result.map { [.started, .stopped, .failed, .unsupported].contains($0.status) } == true)
    }
    mutating func observe(connection next: UUID, capability: Int?, hostKey: String?, providerCallKinds: [String]? = nil) {
        let trusted = hostKey.flatMap { $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil ? $0 : nil }
        guard let trusted else {
            supported = false; nativeSupported = false
            nativePreparation = nil
            if connection != next { disconnected(); connection = next }
            return
        }
        if self.hostKey != trusted {
            guard pending == nil || connection != next else { supported = false; nativeSupported = false; return }
            self = VisionProviderCall(connection: next, target: target, clock: clock)
            self.hostKey = trusted
        }
        if connection != next { disconnected(); connection = next }
        supported = capability == 1
        nativeSupported = supported && providerCallKinds?.contains(ProviderCallKind.nativeCodex.rawValue) == true
    }
    mutating func disconnected() {
        nativePreparation = nil
        supported = false; nativeSupported = false
        pending = nil
        if let request, let kind = requestProviderKind, result == nil || result?.status == .pending {
            result = try? .init(requestId: request.requestId, status: .unknown, reason: "provider_connection_changed",
                provider: kind.rawValue)
        }
    }
    mutating func perform(_ value: ProviderCallRequest) -> ProviderCallControl? {
        let now = clock()
        guard canPerform, let kind = target.providerKind, now.isFinite, now >= 0 else { return nil }
        guard value.action != .stop || (requestProviderKind == kind && selectedResult?.status == .started &&
            selectedResult?.callSessionId == value.callSessionId && value.callSessionId != nil) else { return nil }
        request = value; requestProviderKind = kind
        result = nil; firstSentAt = now; queries = 0; lastQueryAt = nil
        return enqueue(.init(operation: .perform, request: value, providerKind: kind), now: now)
    }
    mutating func query() -> ProviderCallControl? {
        let now = clock()
        guard targetSupported, let kind = target.providerKind, requestProviderKind == kind,
              pending == nil, let request, let firstSentAt,
              result == nil || result?.status == .pending || result?.status == .unknown else { return nil }
        guard now.isFinite, now >= firstSentAt, now - firstSentAt < 10, queries < 4 else {
            result = try? .init(requestId: request.requestId, status: .unknown, reason: "provider_query_budget_exhausted", provider: kind.rawValue)
            return nil
        }
        guard lastQueryAt.map({ now >= $0 && now - $0 >= 0.5 }) ?? true else { return nil }
        queries += 1; lastQueryAt = now
        return enqueue(.init(operation: .query, request: request, providerKind: kind), now: now)
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
              state.result.provider == pending.control.providerKind.rawValue,
              requestProviderKind == pending.control.providerKind, target.providerKind == pending.control.providerKind,
              now.isFinite, now >= pending.sentAt, now < pending.expiresAt else { return false }
        guard state.result.status != .started || pending.control.request.action == .start,
              state.result.status != .stopped || pending.control.request.action == .stop else { return false }
        self.pending = nil
        result = targetSupported ? state.result : try? .init(requestId: pending.control.request.requestId,
            status: .unknown, reason: "provider_authentication_unverified", provider: pending.control.providerKind.rawValue)
        return true
    }
    mutating func drain(_ state: ProviderCallState, from incoming: UUID) -> Bool {
        supported = false; nativeSupported = false
        return receive(state, from: incoming)
    }
    mutating func timeout(_ pending: Pending) -> Bool {
        guard self.pending?.connection == pending.connection,
              self.pending?.sentAt == pending.sentAt,
              self.pending?.control.request == pending.control.request,
              self.pending?.control.providerKind == pending.control.providerKind else { return false }
        let now = clock()
        guard !now.isFinite || now < pending.sentAt || now >= pending.expiresAt else { return false }
        self.pending = nil
        supported = false; nativeSupported = false
        result = try? .init(requestId: pending.control.request.requestId, status: .unknown, reason: "provider_response_timeout", provider: pending.control.providerKind.rawValue)
        return true
    }
    mutating func discardNativePreparation() { nativePreparation = nil }

    @discardableResult
    mutating func consumeNativePreparation(_ preparation: VisionNativePreparedCall,
                                          fence: VisionNativePreparedCall.Fence) -> Bool {
        guard target == .nativeCodex, supported, pending == nil,
              preparation.isCurrent(fence, now: clock()),
              fence.connection == connection, fence.hostKey == hostKey else {
            nativePreparation = nil
            return false
        }
        nativePreparation = preparation
        return true
    }
    var message: String {
        guard target != .grok else { return "Grok 통화의 원격 시작·종료는 미확인입니다." }
        let name = target == .nativeCodex ? "Mac Codex 음성" : "Dots 통화"
        if pending != nil { return "\(name) 상태를 확인하고 있습니다." }
        guard let result = selectedResult else {
            return targetSupported ? "\(name)와 음성 입출력 상태는 각각 확인합니다." :
                target == .nativeCodex ? "Mac Codex 음성의 원격 시작·종료는 미확인입니다." :
                "이 Mac 연결은 Dots 통화 제어를 지원하지 않습니다."
        }
        switch result.status {
        case .started: return "Mac의 \(name) 시작을 확인했습니다."
        case .stopped: return "Mac의 \(name) 종료를 확인했습니다."
        case .pending: return "\(name) 결과를 기다립니다. 대상은 확인 후 바꿀 수 있습니다."
        case .unsupported: return "현재 Mac에서는 \(name) 동작을 확인할 수 없습니다."
        case .failed: return "\(name) 명령을 완료하지 못했습니다. Mac을 확인하세요."
        case .unknown: return "\(name) 결과를 확인하지 못했습니다. 자동 재시도하지 않습니다."
        }
    }
}

#if os(visionOS)
import Network

extension StreamClient {
    // Called only by the eventual authenticated Host prepared-target producer. No
    // endpoint is inferred from the Host's private command socket.
    @discardableResult
    func consumeVisionNativePreparedTarget(_ data: Data, challengeTargetHash: String,
        coreGeneration: UUID, currentCoreGeneration: UUID, observedAt: TimeInterval,
        expiresAt: TimeInterval, from peer: NWConnection) -> Bool {
        visionProviderCall.discardNativePreparation()
        guard connection === peer, authenticatedVisionMacAudioPeer == ObjectIdentifier(peer),
              data.count <= 4096, let model = visionForwarding,
              let snapshot = model.providerCallSnapshot,
              let fence = VisionNativePreparedCall.Fence(connection: visionAudioIntentConnection,
                context: visionAudioIntentContext, snapshot: snapshot, device: model.device,
                coreGeneration: currentCoreGeneration,
                ownsAudio: VisionRemoteAudioStore.shared.model.owner == visionAudioOwnerID),
              let target = try? JSONDecoder().decode(CodexRealtimePreparedTarget.self, from: data),
              let prepared = VisionNativePreparedCall(target: target, challengeTargetHash: challengeTargetHash,
                coreGeneration: coreGeneration, fence: fence, observedAt: observedAt, expiresAt: expiresAt) else { return false }
        return visionProviderCall.consumeNativePreparation(prepared, fence: fence)
    }

    var visionProviderCanStart: Bool {
        VisionRemoteAudioStore.shared.model.owner == visionAudioOwnerID &&
            visionProviderCall.hostKey == visionAudioTrustedHostKey && visionProviderCall.canPerform && visionProviderCall.selectedResult?.status != .started &&
            visionForwarding?.binding != nil && visionAudioIntentContext.admitted
    }
    var visionProviderCanStop: Bool {
        VisionRemoteAudioStore.shared.model.owner == visionAudioOwnerID &&
            visionProviderCall.hostKey == visionAudioTrustedHostKey && visionProviderCall.canPerform && visionProviderCall.selectedResult?.status == .started &&
            visionProviderCall.selectedResult?.callSessionId != nil && visionForwarding?.providerCallSnapshot != nil && visionAudioIntentContext.admitted
    }
    func performVisionProviderCall(_ action: ProviderCallRequest.Action) {
        guard action == .start ? visionProviderCanStart : visionProviderCanStop,
              let peer = connection, authenticatedVisionMacAudioPeer == ObjectIdentifier(peer),
              let model = visionForwarding, let snapshot = model.providerCallSnapshot,
              let request = try? ProviderCallRequest(requestId: UUID(), action: action,
                expectedLeaseRevision: snapshot.revision, pairedDeviceId: model.device,
                desiredInput: visionForwardingDesire.microphone, desiredOutput: visionForwardingDesire.playback,
                callSessionId: action == .stop ? visionProviderCall.selectedResult?.callSessionId : nil),
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
        guard control.providerKind == visionProviderCall.target.providerKind,
              VisionRemoteAudioStore.shared.model.owner == visionAudioOwnerID,
              visionProviderCall.connection == generation, let pending = visionProviderCall.pending else { return }
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
                  VisionRemoteAudioStore.shared.model.owner == self.visionAudioOwnerID,
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
                  self.visionAudioIntentContext.admitted,
                  VisionRemoteAudioStore.shared.model.owner == self.visionAudioOwnerID,
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
