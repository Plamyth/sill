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
    var released: () -> Bool = { false }
}

@MainActor
final class HostSentry {
    private enum Operation { case idle, reconciling, returningLocal }
    private let admission: SentryAdmission
    private let persist: (SentryJournalState) -> Bool
    private let surfaces: SentrySurfaceOperations
    private let prepareRelease: () -> Bool
    private let prepareRemoteRelease: () -> Bool
    private let audioReady: () -> Bool
    private let localReturnUnavailableReason: () -> String?
    private var persistenceHealthy: Bool
    private var operation = Operation.idle
    private var membershipGeneration = UUID()
    var changed: (() -> Void)?
    var protectionInvalidated: (() -> Void)?

    init(admission: SentryAdmission, initiallyLatched: Bool, persistenceHealthy: Bool,
         persist: @escaping (SentryJournalState) -> Bool, surfaces: SentrySurfaceOperations,
         prepareRelease: @escaping () -> Bool,
         prepareRemoteRelease: (() -> Bool)? = nil,
         audioReady: @escaping () -> Bool = { true },
         localReturnUnavailableReason: @escaping () -> String? = { "인증된 로컬 복귀 가능 여부를 확인하지 못했습니다." }) {
        self.admission = admission
        self.persist = persist
        self.surfaces = surfaces
        self.prepareRelease = prepareRelease
        self.prepareRemoteRelease = prepareRemoteRelease ?? prepareRelease
        self.audioReady = audioReady
        self.localReturnUnavailableReason = localReturnUnavailableReason
        self.persistenceHealthy = persistenceHealthy
        admission.configure(latched: initiallyLatched, persistenceHealthy: persistenceHealthy)
    }

    struct ForwardingProof: Equatable {
        fileprivate enum Surface: Equatable {
            case protected(SentryAdmission.ProtectionSnapshot)
            case released(SentryAdmission.InactiveSnapshot)
        }
        fileprivate let revision: UUID
        fileprivate let surface: Surface
    }
    private var forwardingRevision = UUID()

    func forwardingProof() -> ForwardingProof? {
        guard operation == .idle, persistenceHealthy, audioReady() else {
            forwardingRevision = UUID()
            return nil
        }
        let proof: ForwardingProof
        if let protected = admission.protectionSnapshot(), surfaces.verify() {
            proof = ForwardingProof(revision: forwardingRevision, surface: .protected(protected))
        } else if let inactive = admission.inactiveSnapshot(), surfaces.released() {
            proof = ForwardingProof(revision: forwardingRevision, surface: .released(inactive))
        } else {
            forwardingRevision = UUID()
            return nil
        }
        guard forwardingProofCurrent(proof) else {
            forwardingRevision = UUID()
            return nil
        }
        return proof
    }

    func forwardingProofCurrent(_ proof: ForwardingProof) -> Bool {
        guard operation == .idle, persistenceHealthy, audioReady(), forwardingRevision == proof.revision else { return false }
        switch proof.surface {
        case .protected(let snapshot): return admission.protectionMatches(snapshot)
        case .released(let snapshot): return admission.inactiveMatches(snapshot) && surfaces.released()
        }
    }

    @discardableResult
    func reconcile() -> Bool {
        guard admission.isRequested, operation == .idle else { return false }
        operation = .reconciling
        let generation = membershipGeneration
        defer { operation = .idle }
        if let proof = admission.protectionSnapshot(), persistenceHealthy,
           localReturnUnavailableReason() == nil, surfaces.verify(),
           generation == membershipGeneration, admission.protectionMatches(proof) { return true }
        invalidateVerification()
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
        guard generation == membershipGeneration else { return false }
        let verified = surfacesVerified
        admission.update(verified: verified, persistenceHealthy: persistenceHealthy,
            reason: verified ? nil : surfaces.reason() ?? "현장 화면과 입력 차단을 확인하지 못했습니다.")
        changed?()
        return persistenceHealthy && verified
    }

    func membershipWillChange() {
        membershipGeneration = UUID()
    }

    private func invalidateVerification() {
        forwardingRevision = UUID()
        protectionInvalidated?()
        guard admission.isRequested else { return }
        admission.update(verified: false, persistenceHealthy: persistenceHealthy,
                         reason: "현장 화면과 입력 차단을 다시 확인하고 있습니다.")
        changed?()
    }

    func surfacesChanged() {
        if operation == .idle { _ = reconcile() }
        else { invalidateVerification() }
    }

    func localReturnActivityChanged(_ active: Bool) {
        forwardingRevision = UUID()
        admission.setLocalReturnRequestActive(active)
        changed?()
        if !active { surfacesChanged() }
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

    func setRemoteProtection(_ desired: Bool, current: () -> Bool) -> Bool {
        guard current(), operation == .idle else { return false }
        if desired { return reconcile() && current() }
        operation = .returningLocal
        defer { operation = .idle }
        forwardingRevision = UUID()
        protectionInvalidated?()
        guard prepareRemoteRelease(), current() else { return false }
        guard persist(.releasing) else {
            persistenceHealthy = false
            return false
        }
        guard current(), surfaces.release(), surfaces.released(), current() else {
            return restoreFailedReturn("원격 기기에서 요청한 현장 보호 해제를 확인하지 못했습니다.")
        }
        guard persist(.inactive), current() else {
            return restoreFailedReturn("원격 보호 해제 상태를 저장하거나 인가를 확인하지 못했습니다.")
        }
        persistenceHealthy = true
        return true
    }

    func controlDidComplete() { changed?() }

    func completeAuthenticatedLocalReturn(commitAudio: () -> Bool = { true }) -> Bool {
        guard operation == .idle else { return false }
        forwardingRevision = UUID()
        operation = .returningLocal
        defer { operation = .idle }
        admission.fenceForLocalReturn()
        if !admission.isRequested {
            guard commitAudio() else { changed?(); return false }
            admission.completeLocalReturn()
            changed?()
            return true
        }
        guard prepareRelease() else {
            persistenceHealthy = persist(.latched)
            admission.update(verified: false, persistenceHealthy: persistenceHealthy,
                             reason: "원래 입력 대상의 종료를 확인하지 못해 보호를 유지합니다.")
            changed?()
            return false
        }
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
        let restored = recoveryAvailable ? surfaces.engage() && surfaces.verify() : surfaces.restoreCurtains()
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
