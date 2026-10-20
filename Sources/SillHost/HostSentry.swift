import Foundation

enum SentryJournalState: String {
    case latched, releasing, inactive

    static func requiresProtection(_ raw: Any?) -> Bool {
        guard let raw else { return false }
        if let previous = raw as? Bool { return previous }
        return (raw as? String).flatMap(Self.init(rawValue:)) != .inactive
    }

    static func isValid(_ raw: Any?) -> Bool {
        raw == nil || raw is Bool || (raw as? String).flatMap(Self.init(rawValue:)) != nil
    }
}

struct SentrySurfaceOperations {
    var engage: () -> Bool
    var verify: () -> Bool
    var release: () -> Bool
    var reason: () -> String?
    var restoreCurtains: () -> Bool = { false }
}

@MainActor
final class HostSentry {
    private enum Operation { case idle, reconciling, returningLocal }
    private let admission: SentryAdmission
    private let persist: (SentryJournalState) -> Bool
    private let surfaces: SentrySurfaceOperations
    private let audioReady: () -> Bool
    private let localReturnUnavailableReason: () -> String?
    private var persistenceHealthy: Bool
    private var operation = Operation.idle
    private var membershipGeneration = UUID()
    var changed: (() -> Void)?

    init(admission: SentryAdmission, initiallyLatched: Bool, persistenceHealthy: Bool,
         persist: @escaping (SentryJournalState) -> Bool, surfaces: SentrySurfaceOperations,
         audioReady: @escaping () -> Bool = { true },
         localReturnUnavailableReason: @escaping () -> String? = { "인증된 로컬 복귀 가능 여부를 확인하지 못했습니다." }) {
        self.admission = admission
        self.persist = persist
        self.surfaces = surfaces
        self.audioReady = audioReady
        self.localReturnUnavailableReason = localReturnUnavailableReason
        self.persistenceHealthy = persistenceHealthy
        admission.configure(latched: initiallyLatched, persistenceHealthy: persistenceHealthy)
    }

    struct ForwardingProof: Equatable {
        fileprivate let membershipGeneration: UUID
        fileprivate let revision: UUID
        fileprivate let admission: SentryAdmission.ProtectionSnapshot
    }
    private var forwardingRevision = UUID()

    func forwardingProof() -> ForwardingProof? {
        forwardingRevision = UUID()
        guard operation == .idle, persistenceHealthy, let admissionProof = admission.protectionSnapshot() else { return nil }
        let proof = ForwardingProof(membershipGeneration: membershipGeneration, revision: forwardingRevision,
                                    admission: admissionProof)
        guard surfaces.verify(), forwardingProofCurrent(proof) else { return nil }
        return proof
    }

    func forwardingProofCurrent(_ proof: ForwardingProof) -> Bool {
        operation == .idle && persistenceHealthy && membershipGeneration == proof.membershipGeneration &&
        forwardingRevision == proof.revision && admission.protectionMatches(proof.admission)
    }

    @discardableResult
    func reconcile() -> Bool {
        guard admission.isRequested, operation == .idle else { return false }
        forwardingRevision = UUID()
        operation = .reconciling
        let generation = membershipGeneration
        defer { operation = .idle }
        persistenceHealthy = persist(.latched)
        let recoveryReason = localReturnUnavailableReason()
        guard persistenceHealthy, recoveryReason == nil else {
            let reason = !persistenceHealthy ? "센츄리 보호 상태를 저장하지 못했습니다." : recoveryReason
            admission.update(verified: false, persistenceHealthy: persistenceHealthy, reason: reason)
            if !surfaces.restoreCurtains(), let curtainReason = surfaces.reason() {
                admission.update(verified: false, persistenceHealthy: persistenceHealthy,
                    reason: [reason, curtainReason].compactMap { $0 }.joined(separator: " "))
            }
            changed?()
            return false
        }
        let engaged = surfaces.engage()
        let surfacesVerified = engaged && surfaces.verify()
        let audioVerified = audioReady()
        guard generation == membershipGeneration else { return false }
        let verified = surfacesVerified && audioVerified
        admission.update(verified: verified, persistenceHealthy: persistenceHealthy,
            reason: !audioVerified ? "Mac 입출력 오디오 보호를 확인하지 못했습니다." :
                verified ? nil : surfaces.reason() ?? "현장 화면과 입력 차단을 확인하지 못했습니다.")
        changed?()
        return persistenceHealthy && verified
    }

    func membershipWillChange() {
        membershipGeneration = UUID()
        invalidateVerification()
    }

    private func invalidateVerification() {
        forwardingRevision = UUID()
        guard admission.isRequested else { return }
        admission.update(verified: false, persistenceHealthy: persistenceHealthy,
                         reason: "현장 화면과 입력 차단을 다시 확인하고 있습니다.")
        changed?()
    }

    func surfacesChanged() {
        invalidateVerification()
        if operation == .idle { _ = reconcile() }
    }

    func start(recoverAudio: () -> Void = {}) {
        if admission.isRequested {
            recoverAudio()
            _ = reconcile()
        }
    }

    func joined(_ peer: ObjectIdentifier) {
        if admission.isRequested { _ = reconcile() }
        admission.admit(peer)
    }

    func activate() -> Bool {
        admission.requireProtection()
        return reconcile()
    }

    func completeAuthenticatedLocalReturn(commitAudio: () -> Bool = { true }) -> Bool {
        guard admission.isRequested else { return commitAudio() }
        guard operation == .idle else { return false }
        forwardingRevision = UUID()
        operation = .returningLocal
        defer { operation = .idle }
        admission.fenceForLocalReturn()
        guard persist(.releasing) else {
            persistenceHealthy = false
            admission.update(verified: false, persistenceHealthy: false,
                             reason: "로컬 복귀 상태를 저장하지 못해 보호를 유지합니다.")
            changed?()
            return false
        }
        guard surfaces.release() else { return restoreFailedReturn("현장 보호 해제를 확인하지 못했습니다.") }
        guard commitAudio() else { return restoreFailedReturn("오디오 복귀 완료 상태를 저장하지 못했습니다.") }
        guard persist(.inactive) else { return restoreFailedReturn("로컬 복귀 완료 상태를 저장하지 못했습니다.") }
        persistenceHealthy = true
        admission.completeLocalReturn()
        changed?()
        return true
    }

    private func restoreFailedReturn(_ reason: String) -> Bool {
        persistenceHealthy = persist(.latched)
        let recoveryAvailable = persistenceHealthy && localReturnUnavailableReason() == nil
        let restored = recoveryAvailable ? surfaces.engage() && surfaces.verify() && audioReady() : surfaces.restoreCurtains()
        let notice: String
        if !restored { notice = " 현장 보호 복구를 확인하지 못했습니다." }
        else if recoveryAvailable { notice = " 현장 보호를 다시 적용했습니다." }
        else { notice = " 가림 화면만 복구했습니다. 입력 차단과 원격 동작은 아직 확인되지 않았습니다." }
        admission.update(verified: recoveryAvailable && restored, persistenceHealthy: persistenceHealthy,
                         reason: reason + notice)
        changed?()
        return false
    }
}
