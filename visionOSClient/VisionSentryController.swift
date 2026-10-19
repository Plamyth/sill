import Foundation
import StreamProtocol

final class VisionSentryController {
    enum Problem: Equatable {
        case timedOut, sendCancelled, rejected(String?)
    }

    struct Snapshot: Equatable {
        var available = false
        var state: SentryState?
        var pendingID: UUID?
        var problem: Problem?

        var canActivate: Bool {
            guard pendingID == nil, let state else { return false }
            return state.phase == .inactive || state.phase == .blocked
        }

        var message: String {
            if pendingID != nil { return "Sentry 활성화 요청의 Mac 확인을 기다립니다." }
            if problem == .timedOut { return "Sentry 응답 시간 초과 · 현재 보호 상태 미확인" }
            if problem == .sendCancelled { return "Sentry 요청을 보내지 못했습니다. 현재 보호 상태 미확인" }
            if case .rejected(_)? = problem { return "Mac이 Sentry 요청을 수락하지 않았습니다." }
            switch state?.phase {
            case .inactive: return "Sentry 꺼짐 · Mac의 현재 로그인 세션 보호를 켤 수 있습니다."
            case .pending: return "Mac이 Sentry 보호를 준비하고 있습니다. 보호 완료는 확인되지 않았습니다."
            case .userSessionProtected: return "Mac 보고 · 현재 로그인 세션의 화면·일반 입력 보호 중"
            case .blocked: return "Mac이 Sentry 보호 완료를 확인하지 못했습니다."
            case nil: return "현재 Mac의 Sentry 보호 상태 미확인"
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
                  state.phase != .pending || state.requested else { return nil }
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

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func bind(_ next: ObjectIdentifier?, trusted: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard peer != next || self.trusted != trusted else { return }
        clearLocked()
        retiredRevisions = []
        peer = next
        self.trusted = trusted
    }

    func observe(_ list: WindowList, from sender: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        guard peer == sender else { return }
        guard trusted, let next = Catalog(list) else { clearLocked(); return }
        if let old = catalog {
            if old.state.hostBootID != next.state.hostBootID || old.state.sessionID != next.state.sessionID {
                retiredRevisions = []
            } else if old.state.revision != next.state.revision {
                retiredRevisions.insert(old.state.revision)
                guard !retiredRevisions.contains(next.state.revision) else { clearLocked(); return }
            } else if old.state != next.state {
                clearLocked(); return
            }
        }
        if catalog != next { finishLocked() }
        catalog = next
        value.available = true
        value.state = next.state
        value.problem = nil
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
        // A response is a readback only while the command's catalog is still current.
        if state.revision != pending.activation.revision { retiredRevisions.insert(pending.activation.revision) }
        catalog?.state = state
        value.state = state
        value.problem = response.accepted ? nil : .rejected(response.reason)
    }

    func timeout(_ id: UUID, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard let pending, pending.activation.requestID == id, now >= pending.deadline else { return }
        timeoutLocked()
    }

    func cancelled(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard pending?.activation.requestID == id else { return }
        finishLocked(); value.state = nil; value.problem = .sendCancelled
    }

    private func timeoutLocked() {
        finishLocked(); value.state = nil; value.problem = .timedOut
    }

    private func finishLocked() {
        let cancel = pending?.cancel
        pending = nil
        value.pendingID = nil
        cancel?()
    }

    private func clearLocked() {
        finishLocked()
        catalog = nil
        value = Snapshot()
    }
}
