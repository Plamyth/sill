import Foundation
import StreamProtocol

final class SentryAdmission: @unchecked Sendable {
    private struct Session {
        let id = UUID()
        var admitted = false
        var requests: Set<UUID> = []
    }
    private let lock = NSLock()
    private let bootID = UUID()
    private var revision = UUID()
    private var protectionRevision = UUID()
    private var enabled = false
    private var requested = false
    private var surfacesVerified = false
    private var persistenceHealthy = true
    private var captureEpoch: UUID?
    private var peerCaptureEpochs: [ObjectIdentifier: UUID] = [:]
    private var independentCapturePeers = Set<ObjectIdentifier>()
    private var reason: String?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var returningLocal = false

    struct ProtectionSnapshot: Equatable {
        fileprivate let revision: UUID
    }

    func protectionSnapshot() -> ProtectionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, requested, persistenceHealthy, surfacesVerified, !returningLocal else { return nil }
        return ProtectionSnapshot(revision: protectionRevision)
    }

    func protectionMatches(_ proof: ProtectionSnapshot) -> Bool { protectionSnapshot() == proof }

    static let limitations = [
        "사용자 로그인 세션의 화면과 일반 키보드·마우스 입력을 보호합니다.",
        "전원 버튼·시스템 보안 화면·다른 로그인 세션은 차단을 보장하지 않습니다."
    ]

    func configure(latched: Bool, persistenceHealthy: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = true
        protectionRevision = UUID()
        requested = requested || latched
        self.persistenceHealthy = persistenceHealthy
        revision = UUID()
    }

    func register(_ peer: ObjectIdentifier, externalRoute: Bool) {
        lock.lock(); defer { lock.unlock() }
        sessions[peer] = Session()
        if enabled && externalRoute && !requested {
            requested = true
            surfacesVerified = false
            protectionRevision = UUID()
            revision = UUID()
        }
    }

    func admit(_ peer: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        sessions[peer]?.admitted = true
    }

    func remove(_ peer: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        sessions[peer] = nil
        peerCaptureEpochs[peer] = nil
        independentCapturePeers.remove(peer)
    }

    func requireProtection() {
        lock.lock(); defer { lock.unlock() }
        guard !requested else { return }
        requested = true
        surfacesVerified = false
        protectionRevision = UUID()
        revision = UUID()
    }

    var isRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    func update(verified: Bool, persistenceHealthy: Bool, reason: String?) {
        lock.lock(); defer { lock.unlock() }
        guard surfacesVerified != verified || self.persistenceHealthy != persistenceHealthy || self.reason != reason else { return }
        protectionRevision = UUID()
        surfacesVerified = verified
        self.persistenceHealthy = persistenceHealthy
        self.reason = reason
        revision = UUID()
    }

    func capture(_ epoch: UUID?) {
        lock.lock(); defer { lock.unlock() }
        guard captureEpoch != epoch else { return }
        captureEpoch = epoch
        revision = UUID()
    }

    func capture(_ epoch: UUID?, for peer: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        guard sessions[peer] != nil else { return }
        let changed = independentCapturePeers.insert(peer).inserted || peerCaptureEpochs[peer] != epoch
        peerCaptureEpochs[peer] = epoch
        if changed { revision = UUID() }
    }

    private func captureForPeer(_ peer: ObjectIdentifier) -> UUID? {
        independentCapturePeers.contains(peer) ? peerCaptureEpochs[peer] : captureEpoch
    }

    func allows(_ peer: ObjectIdentifier, epoch: UUID?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return true }
        guard !returningLocal, sessions[peer]?.admitted == true else { return false }
        return !requested || (persistenceHealthy && surfacesVerified && epoch != nil && captureForPeer(peer) == epoch)
    }

    func allowsActions(_ peer: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return true }
        guard !returningLocal, sessions[peer]?.admitted == true else { return false }
        return !requested || (persistenceHealthy && surfacesVerified)
    }

    func allowsWire(_ data: Data, for peer: ObjectIdentifier, currentEpoch: UUID?) -> Bool {
        guard let header = StreamMessage.parseHeader(data), data.count == StreamMessage.headerLength + header.payloadLength else { return false }
        switch header.kind {
        case .epochFrame, .epochParameterSets:
            guard let payload = PresentationMedia.decode(Data(data.dropFirst(StreamMessage.headerLength)), kind: header.kind) else { return false }
            return allows(peer, epoch: payload.epoch)
        case .frame, .parameterSets:
            return allows(peer, epoch: nil)
        case .thumbnail:
            lock.lock(); defer { lock.unlock() }
            return !enabled || (!requested && !returningLocal && sessions[peer]?.admitted == true)
        default:
            return true
        }
    }

    func status(for peer: ObjectIdentifier) -> SentryState? {
        lock.lock(); defer { lock.unlock() }
        return statusLocked(for: peer)
    }

    private func statusLocked(for peer: ObjectIdentifier) -> SentryState? {
        guard enabled, let session = sessions[peer] else { return nil }
        let phase: SentryState.Phase
        if !requested { phase = .inactive }
        else if !persistenceHealthy || reason != nil || returningLocal { phase = .blocked }
        else if surfacesVerified && captureForPeer(peer) != nil { phase = .userSessionProtected }
        else { phase = .pending }
        return SentryState(hostBootID: bootID, sessionID: session.id, revision: revision,
                           requested: requested, phase: phase, reason: reason, limitations: Self.limitations)
    }

    func accept(_ activation: SentryActivation, from peer: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled, !returningLocal, activation.version == 1, activation.hostBootID == bootID,
              var session = sessions[peer], session.admitted,
              activation.sessionID == session.id else { return false }
        if session.requests.contains(activation.requestID) { return true }
        guard activation.revision == revision, session.requests.count < 64 else { return false }
        session.requests.insert(activation.requestID)
        sessions[peer] = session
        if !requested {
            requested = true
            surfacesVerified = false
            protectionRevision = UUID()
            revision = UUID()
        }
        return true
    }

    func fenceForLocalReturn() {
        lock.lock(); defer { lock.unlock() }
        protectionRevision = UUID()
        returningLocal = true
        surfacesVerified = false
        revision = UUID()
    }

    func completeLocalReturn() {
        lock.lock(); defer { lock.unlock() }
        sessions.removeAll()
        peerCaptureEpochs.removeAll()
        independentCapturePeers.removeAll()
        protectionRevision = UUID()
        requested = false
        returningLocal = false
        surfacesVerified = false
        captureEpoch = nil
        reason = nil
        revision = UUID()
    }
}
