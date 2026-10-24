import Foundation
import StreamProtocol

final class VisionSentryController {
    private struct CapabilityHeader: Decodable {
        let version: Int
        let role: String?
        let canSet: Bool?
        private enum CodingKeys: String, CodingKey { case version, role, canSet }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            role = version == 2 ? try values.decodeIfPresent(String.self, forKey: .role) : nil
            canSet = version == 2 ? try values.decodeIfPresent(Bool.self, forKey: .canSet) : nil
        }
    }

    static func decodeCatalog(_ data: Data) -> WindowList? {
        if let list = Wire.decode(WindowList.self, from: data) { return list }
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var state = root["sentry"] as? [String: Any], let control = state["control"] as? [String: Any],
              let capabilityData = try? JSONSerialization.data(withJSONObject: control),
              let header = try? JSONDecoder().decode(CapabilityHeader.self, from: capabilityData),
              header.version != 2 || header.role != "ownerDevice" || header.canSet != true else { return nil }
        state.removeValue(forKey: "control")
        root["sentry"] = state
        guard let legacyData = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        return Wire.decode(WindowList.self, from: legacyData)
    }

    enum Problem: Equatable {
        case timedOut, sendCancelled, rejected(String?), storage, capacity
    }

    struct Snapshot: Equatable {
        var available = false
        var state: SentryState?
        var pendingID: UUID?
        var problem: Problem?
        var controlAvailable = false
        var canReadback = false
        var readbackNeedsNewSession = false
        var storedRequestID: UUID?
        var accepted: Bool?
        var operationState: SentryControlResponse.OperationState?
        var operationCode: SentryControlResponse.Code?

        var canActivate: Bool {
            guard pendingID == nil, let state else { return false }
            if state.control != nil { return controlAvailable && canStartControl && state.control?.manualIntent != .on }
            return state.phase == .inactive || state.phase == .blocked
        }

        var canDeactivate: Bool {
            pendingID == nil && controlAvailable && canStartControl
        }

        private var canStartControl: Bool {
            problem != .storage && operationState != .unknown && !(storedRequestID != nil && accepted == nil)
        }

        var message: String {
            if state?.phase == .pending {
                return "Mac이 센츄리 보호 설정을 전환하고 있습니다. " + requestMessage
            }
            return requestMessage
        }

        private var requestMessage: String {
            if pendingID != nil { return "센츄리 요청의 Mac 확인을 기다립니다. 전송은 적용 완료가 아닙니다." }
            if problem == .storage { return "요청 원문을 보호 저장소에서 확인하지 못해 전송을 중지했습니다." }
            if problem == .capacity { return "미해결 요청 보관 한도에 도달해 새 요청을 거절했습니다. 보존 원문으로 결과를 확인하세요." }
            if readbackNeedsNewSession {
                let result = operationState == .rejected ? "Mac이 요청을 거절했습니다. " :
                    operationState == .unknown ? "요청 결과 미확인. " : ""
                return result + "원장 접수 미확인 · 같은 세션에서는 재전송하지 않습니다. 같은 Mac의 새 세션에 다시 연결한 뒤 원문으로 확인하세요."
            }
            if problem == .timedOut { return "센츄리 응답 시간 초과 · 현재 보호 상태 미확인" }
            if problem == .sendCancelled { return "센츄리 요청을 보내지 못했습니다. 현재 보호 상태 미확인" }
            if case .rejected(_)? = problem { return "Mac이 센츄리 요청을 수락하지 않았습니다." }
            if let operationState {
                switch operationState {
                case .pending: return accepted == true ? "Mac이 요청을 수락했습니다. 적용 대기 중이며 원문으로 다시 확인할 수 있습니다." : "요청 적용 대기 중"
                case .applied:
                    let confirmation = "Mac이 요청 적용을 확인했습니다."
                    return state?.phase == .pending ?
                        "이전 요청 결과 · \(confirmation) 현재 전환의 완료를 뜻하지 않습니다." : confirmation
                case .rejected: return accepted == true ? "원장 접수는 확인됐지만 Mac이 적용을 거절했습니다." : "Mac이 요청을 거절했습니다."
                case .superseded: return "이 요청은 이후의 명시적 보호 설정으로 대체되었습니다."
                case .unknown: return "요청 결과 미확인 · 새 요청 대신 보존 원문으로 다시 확인하세요."
                }
            }
            if storedRequestID != nil { return "보존된 요청이 있습니다. 원문으로 결과를 확인하세요." }
            switch state?.phase {
            case .inactive: return "센츄리 꺼짐 · Mac의 현재 로그인 세션 보호를 켤 수 있습니다."
            case .pending: return "적용 완료는 확인되지 않았습니다."
            case .userSessionProtected: return "Mac 보고 · 현재 로그인 세션의 화면·일반 입력 보호 중"
            case .blocked: return "Mac이 센츄리 보호 완료를 확인하지 못했습니다."
            case nil: return "현재 Mac의 센츄리 보호 상태 미확인"
            }
        }
    }

    private struct Catalog: Equatable {
        var state: SentryState
        let source: StreamSource
        let generation: String?
        let epoch: VideoEpoch?
        let display: UInt32?
        let launch: String?

        init?(_ list: WindowList) {
            guard let state = list.sentry, state.version == 1,
                  state.phase != .userSessionProtected || state.requested,
                  state.phase != .pending || state.requested || state.control != nil else { return nil }
            self.state = state
            source = list.active; generation = list.inputGeneration; epoch = list.videoEpoch
            display = list.activeDisplayID; launch = list.launchID
        }
    }

    private struct Pending {
        let activation: SentryActivation
        let catalog: Catalog
        let deadline: TimeInterval
        let cancel: () -> Void
        var admitted = false
    }

    static let timeout: TimeInterval = 8
    private let lock = NSLock()
    private var peer: ObjectIdentifier?
    private var trusted = false
    private var catalog: Catalog?
    private var pending: Pending?
    private var retiredRevisions: Set<UUID> = []
    private var value = Snapshot()
    let store: VisionSentryRequestStore
    private var identity: VisionSentryStoredRequest.Binding?
    private var records: [VisionSentryStoredRequest] = []
    private var storageHealthy = true
    private struct ControlPending {
        let attemptID: UUID
        let request: SentryControlRequest
        let catalog: Catalog
        let deadline: TimeInterval
        let cancel: () -> Void
        var admitted = false
    }
    private var controlPending: ControlPending?

    init(store: VisionSentryRequestStore = .unavailable) {
        self.store = store
        do {
            records = try store.load()
            guard records.count <= VisionSentryRequestStore.maximumRecords else { throw VisionSentryRequestStore.Failure.storage }
            for record in records { _ = try record.request() }
        } catch { storageHealthy = false }
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func bind(_ next: ObjectIdentifier?, trusted: Bool, identity: VisionSentryStoredRequest.Binding? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard peer != next || self.trusted != trusted || self.identity != identity else { return }
        clearLocked()
        retiredRevisions = []
        peer = next
        self.trusted = trusted
        self.identity = trusted && identity?.valid == true ? identity : nil
    }

    func observe(_ list: WindowList, from sender: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        guard peer == sender else { return }
        guard trusted, let next = Catalog(list) else { clearLocked(); return }
        if let old = catalog,
           old.state.hostBootID != next.state.hostBootID || old.state.sessionID != next.state.sessionID {
            retiredRevisions = []
        }
        guard !retiredRevisions.contains(next.state.revision) else { clearLocked(); return }
        if let old = catalog, old.state.hostBootID == next.state.hostBootID,
           old.state.sessionID == next.state.sessionID {
            if old.state.revision != next.state.revision {
                retiredRevisions.insert(old.state.revision)
            } else if old.state != next.state {
                let pendingOffProgress = old.state.control != nil &&
                    old.state.control?.authorizationGeneration == next.state.control?.authorizationGeneration &&
                    !old.state.requested && !next.state.requested &&
                    (old.state.phase == .pending || next.state.phase == .pending)
                guard pendingOffProgress else { clearLocked(); return }
            }
        }
        if catalog != next {
            let continuing = controlPending?.admitted == true && catalog?.state.hostBootID == next.state.hostBootID &&
                catalog?.state.sessionID == next.state.sessionID &&
                catalog?.state.control?.authorizationGeneration == next.state.control?.authorizationGeneration
            if !continuing { finishLocked() }
        }
        catalog = next
        value.available = true
        value.state = next.state
        value.problem = nil
        refreshControlLocked()
    }

    func invalidateCatalog(from sender: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        guard peer == sender else { return }
        clearLocked()
    }

    func begin(requestID: UUID = UUID(), now: TimeInterval, cancel: @escaping () -> Void) -> SentryActivation? {
        lock.lock(); defer { lock.unlock() }
        guard trusted, peer != nil, value.canActivate, let catalog, catalog.source != .none else { return nil }
        let state = catalog.state
        let activation = SentryActivation(requestID: requestID, hostBootID: state.hostBootID, sessionID: state.sessionID, revision: state.revision)
        pending = Pending(activation: activation, catalog: catalog, deadline: now + Self.timeout, cancel: cancel)
        value.pendingID = activation.requestID
        value.problem = nil
        return activation
    }

    @discardableResult
    func submit(_ activation: SentryActivation, to sender: ObjectIdentifier, now: TimeInterval,
                send: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard peer == sender, let pending, !pending.admitted, pending.activation == activation,
              catalog == pending.catalog else { return false }
        guard now < pending.deadline else { timeoutLocked(); return false }
        self.pending?.admitted = true
        guard send() else {
            finishLocked(); value.state = nil; value.problem = .sendCancelled
            return false
        }
        return true
    }

    func receive(_ response: SentryResponse, from sender: ObjectIdentifier, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard peer == sender, let pending, pending.admitted, response.requestID == pending.activation.requestID,
              catalog == pending.catalog else { return }
        guard now < pending.deadline else { timeoutLocked(); return }
        let state = response.state
        guard state.version == 1, state.hostBootID == pending.activation.hostBootID,
              state.sessionID == pending.activation.sessionID,
              !retiredRevisions.contains(state.revision),
              state.revision != pending.activation.revision || state == pending.catalog.state,
              state.phase != .userSessionProtected || state.requested,
              state.phase != .pending || state.requested else { return }
        finishLocked()
        if state.revision != pending.activation.revision { retiredRevisions.insert(pending.activation.revision) }
        catalog?.state = state
        value.state = state
        value.problem = response.accepted ? nil : .rejected(response.reason)
    }

    func timeout(_ id: UUID, now: TimeInterval, attemptID: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let operation = controlPending, operation.request.requestID == id,
           attemptID == nil || attemptID == operation.attemptID, now >= operation.deadline {
            timeoutLocked(); refreshControlLocked(); return
        }
        guard let pending, pending.activation.requestID == id, now >= pending.deadline else { return }
        timeoutLocked()
    }

    func cancelled(_ id: UUID, attemptID: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let operation = controlPending, operation.request.requestID == id,
           attemptID == nil || attemptID == operation.attemptID { controlUnknownLocked(); return }
        guard pending?.activation.requestID == id else { return }
        finishLocked(); value.state = nil; value.problem = .sendCancelled
    }

    private func timeoutLocked() {
        let wasControl = controlPending != nil
        finishLocked(); value.state = nil; value.problem = .timedOut
        if wasControl {
            value.operationState = .unknown; value.accepted = nil
            refreshControlLocked()
        }
    }

    private func finishLocked() {
        let cancel = pending?.cancel
        let controlCancel = controlPending?.cancel
        pending = nil
        controlPending = nil
        value.pendingID = nil
        cancel?()
        controlCancel?()
    }

    private func clearLocked() {
        finishLocked()
        catalog = nil
        value = Snapshot()
    }

    private var stored: VisionSentryStoredRequest? {
        guard let identity else { return nil }
        return records.last(where: { $0.binding == identity })
    }

    private func matchesCurrent(_ request: SentryControlRequest) -> Bool {
        guard trusted, peer != nil, identity != nil, let state = catalog?.state,
              let control = state.control else { return false }
        return request.hostBootID == state.hostBootID && request.authorizationGeneration == control.authorizationGeneration
    }

    private func refreshControlLocked() {
        value.controlAvailable = trusted && identity != nil && catalog?.state.control != nil && storageHealthy
        let request = stored.flatMap { try? $0.request() }
        let matches = request.map(matchesCurrent) ?? false
        value.storedRequestID = matches ? request?.requestID : nil
        value.readbackNeedsNewSession = matches && stored?.ledgerAccepted != true && request?.sessionID == catalog?.state.sessionID
        value.canReadback = value.controlAvailable && matches && !value.readbackNeedsNewSession && value.pendingID == nil
        if !storageHealthy && catalog?.state.control != nil { value.problem = .storage }
        if !matches {
            value.accepted = nil; value.operationState = nil; value.operationCode = nil
        }
    }

    func beginControl(desired: Bool?, requestID: UUID = UUID(), attemptID: UUID = UUID(), now: TimeInterval,
                      cancel: @escaping () -> Void) -> SentryControlRequest? {
        lock.lock(); defer { lock.unlock() }
        guard value.pendingID == nil, value.controlAvailable, let catalog, let identity,
              let control = catalog.state.control else { return nil }
        let request: SentryControlRequest
        do {
            if let desired {
                guard desired ? value.canActivate : value.canDeactivate else { return nil }
                request = try SentryControlRequest(requestID: requestID, hostBootID: catalog.state.hostBootID,
                    sessionID: catalog.state.sessionID, revision: catalog.state.revision,
                    authorizationGeneration: control.authorizationGeneration, desired: desired)
                var next = records
                if next.count == VisionSentryRequestStore.maximumRecords {
                    guard let index = next.firstIndex(where: { $0.hasTerminalReceipt }) else {
                        value.problem = .capacity
                        return nil
                    }
                    next.remove(at: index)
                }
                next.append(VisionSentryStoredRequest(binding: identity, rawRequest: request.rawRequest))
                try persistLocked(next)
            } else {
                guard value.canReadback, let stored else { return nil }
                guard try store.load() == records else { throw VisionSentryRequestStore.Failure.storage }
                request = try stored.request()
            }
        } catch {
            storageHealthy = false; value.problem = .storage; refreshControlLocked(); return nil
        }
        guard matchesCurrent(request) else { return nil }
        controlPending = ControlPending(attemptID: attemptID, request: request, catalog: catalog, deadline: now + Self.timeout, cancel: cancel)
        value.pendingID = request.requestID
        value.storedRequestID = request.requestID
        value.canReadback = false
        value.accepted = nil; value.operationState = nil; value.operationCode = nil; value.problem = nil
        refreshControlLocked()
        return request
    }

    @discardableResult
    func submitControl(_ request: SentryControlRequest, to sender: ObjectIdentifier, now: TimeInterval, attemptID: UUID? = nil,
                       send: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard peer == sender, let operation = controlPending, !operation.admitted,
              operation.request == request, operation.catalog == catalog, matchesCurrent(request),
              attemptID == nil || attemptID == operation.attemptID else { return false }
        guard now < operation.deadline else { timeoutLocked(); return false }
        guard let identity, store.contains(rawRequest: request.rawRequest, binding: identity) else {
            storageHealthy = false
            finishLocked(); refreshControlLocked(); return false
        }
        controlPending?.admitted = true
        guard send() else { controlUnknownLocked(); return false }
        return true
    }

    func receiveControl(_ response: SentryControlResponse, from sender: ObjectIdentifier, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard peer == sender, let operation = controlPending, operation.admitted,
              response.requestID == operation.request.requestID, matchesCurrent(operation.request),
              response.state.hostBootID == operation.request.hostBootID,
              response.state.sessionID == catalog?.state.sessionID,
              !retiredRevisions.contains(response.state.revision),
              response.state.control?.authorizationGeneration == operation.request.authorizationGeneration else { return }
        guard now < operation.deadline else { timeoutLocked(); return }
        guard response.state.phase != .userSessionProtected || response.state.requested,
              response.state.phase != .pending || response.state.requested || response.state.control != nil else { return }
        if response.operationState == .applied {
            guard response.accepted,
                  response.state.control?.manualIntent == (operation.request.desired ? .on : .off),
                  operation.request.desired ? response.state.requested && response.state.phase == .userSessionProtected :
                    !response.state.requested && response.state.phase == .inactive else { return }
        }
        do {
            guard let index = records.lastIndex(where: { $0.binding == identity && $0.rawRequest == operation.request.rawRequest }) else {
                throw VisionSentryRequestStore.Failure.storage
            }
            let terminal = response.accepted &&
                [.applied, .rejected, .superseded].contains(response.operationState)
            let updated = VisionSentryStoredRequest(binding: records[index].binding,
                rawRequest: records[index].rawRequest, ledgerAccepted: records[index].ledgerAccepted || response.accepted,
                hasTerminalReceipt: terminal)
            if updated != records[index] {
                var next = records
                next[index] = updated
                try persistLocked(next)
            }
        } catch {
            storageHealthy = false
            finishLocked(); refreshControlLocked(); return
        }
        finishLocked()
        if let old = catalog?.state, old.revision != response.state.revision { retiredRevisions.insert(old.revision) }
        catalog?.state = response.state
        value.state = response.state
        value.accepted = response.accepted
        value.operationState = response.operationState
        value.operationCode = response.code
        value.problem = nil
        refreshControlLocked()
    }

    private func persistLocked(_ next: [VisionSentryStoredRequest]) throws {
        try store.save(next)
        guard try store.load() == next else { throw VisionSentryRequestStore.Failure.storage }
        records = next
    }

    private func controlUnknownLocked() {
        finishLocked()
        value.accepted = nil; value.operationState = .unknown; value.operationCode = nil
        value.problem = nil
        refreshControlLocked()
    }
}
