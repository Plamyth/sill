import Foundation
import StreamProtocol

final class SentryAdmission: @unchecked Sendable {
    private struct Session {
        let id = UUID()
        var admitted = false
        var requests: [UUID] = []
        var controlDeviceID: String?
        var selectionReady = false
        var selectionGeneration: UInt64?
    }
    private let lock = NSLock()
    private let bootID = UUID()
    private var revision = UUID()
    private var protectionRevision = UUID()
    private var inactiveRevision = UUID()
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
    private var localReturnRequestActive = false
    private var selectionGeneration: UInt64 = 0
    private var controlGrants: [String: UUID] = [:]
    private var manualIntent: SentryManualIntent = .automatic
    private var manualOwner: String?
    private var policyRevision = UUID()
    private var operations: [UUID: ControlRecord] = [:]
    private var operationOrder: [UUID] = []
    private var pendingControl: ControlTicket?
    private static let maximumOperations = 128

    struct VerifiedOwnerDevice {
        let deviceID: String
        init?(deviceID: String, encryptedTLS: Bool, currentPairedOwner: Bool) {
            guard encryptedTLS, currentPairedOwner, deviceID.utf8.count == 64,
                  deviceID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            self.deviceID = deviceID
        }
        init?(fingerprintData: Data, encryptedTLS: Bool, currentPairedOwner: Bool) {
            guard fingerprintData.count == 32 else { return nil }
            self.init(deviceID: fingerprintData.map { String(format: "%02x", $0) }.joined(),
                      encryptedTLS: encryptedTLS, currentPairedOwner: currentPairedOwner)
        }
    }

    struct ControlTicket: Equatable, Sendable {
        let request: SentryControlRequest
        fileprivate let nonce: UUID
        fileprivate let peer: ObjectIdentifier
        fileprivate let deviceID: String
        fileprivate let policyRevision: UUID
    }

    enum ControlPreparation {
        case prepared(ControlTicket, SentryControlResponse)
        case readback(SentryControlResponse)
        case rejected(SentryControlResponse)
        case unauthorized
    }

    enum ControlResult {
        case pending
        case onPrepared(surfacesVerified: Bool)
        case onVerified(surfacesVerified: Bool, captureEpoch: UUID)
        case offVerified(curtainsReleased: Bool, tapReleased: Bool, heldInputCleared: Bool)
        case failed
        case targetUnconfirmed
    }

    private struct ControlRecord {
        let request: SentryControlRequest
        let deviceID: String
        var operationState: SentryControlResponse.OperationState
        var code: SentryControlResponse.Code
        var completedPolicy: UUID?
    }

    struct ProtectionSnapshot: Equatable {
        fileprivate let revision: UUID
    }

    func protectionSnapshot() -> ProtectionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, requested, persistenceHealthy, surfacesVerified, !returningLocal && !localReturnRequestActive, pendingControl == nil else { return nil }
        return ProtectionSnapshot(revision: protectionRevision)
    }

    func protectionMatches(_ proof: ProtectionSnapshot) -> Bool { protectionSnapshot() == proof }

    struct InactiveSnapshot: Equatable {
        fileprivate let revision: UUID
    }

    func inactiveSnapshot() -> InactiveSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, !requested, !returningLocal && !localReturnRequestActive, pendingControl == nil, manualIntent == .off,
              let owner = manualOwner, controlGrants[owner] != nil else { return nil }
        return InactiveSnapshot(revision: inactiveRevision)
    }

    func inactiveMatches(_ proof: InactiveSnapshot) -> Bool { inactiveSnapshot() == proof }

    static let limitations = [
        "사용자 로그인 세션의 화면과 일반 키보드·마우스 입력을 보호합니다.",
        "전원 버튼·시스템 보안 화면·다른 로그인 세션은 차단을 보장하지 않습니다."
    ]

    func configure(latched: Bool, persistenceHealthy: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = true
        protectionRevision = UUID()
        inactiveRevision = UUID()
        requested = manualIntent == .off ? false : (requested || latched)
        self.persistenceHealthy = persistenceHealthy
        revision = UUID()
        refreshSelectionAdmissionLocked()
    }

    func register(_ peer: ObjectIdentifier, externalRoute _: Bool) {
        lock.lock(); defer { lock.unlock() }
        cancelPendingLocked(for: peer)
        sessions[peer] = Session()
        refreshSelectionAdmissionLocked()
    }

    func admit(_ peer: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        sessions[peer]?.admitted = true
        refreshSelectionAdmissionLocked()
    }

    func remove(_ peer: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        cancelPendingLocked(for: peer)
        sessions[peer] = nil
        peerCaptureEpochs[peer] = nil
        independentCapturePeers.remove(peer)
    }

    @discardableResult
    func requireProtection(explicit: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // 연결·포커스의 기존 호출은 선택을 만들지 않고 명시 활성화만 ON으로 바꾼다.
        guard explicit, enabled, !returningLocal && !localReturnRequestActive, pendingControl == nil else { return false }
        guard !requested || manualIntent != .on else { return true }
        manualIntent = .on
        manualOwner = nil
        policyRevision = UUID()
        if !requested {
            requested = true
            surfacesVerified = false
            protectionRevision = UUID()
            inactiveRevision = UUID()
        }
        revision = UUID()
        refreshSelectionAdmissionLocked()
        return true
    }

    var isRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    func update(verified: Bool, persistenceHealthy: Bool, reason: String?) {
        lock.lock(); defer { lock.unlock() }
        guard surfacesVerified != verified || self.persistenceHealthy != persistenceHealthy || self.reason != reason else { return }
        protectionRevision = UUID()
        inactiveRevision = UUID()
        surfacesVerified = verified
        self.persistenceHealthy = persistenceHealthy
        self.reason = reason
        revision = UUID()
        refreshSelectionAdmissionLocked()
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
        guard !localReturnRequestActive else { return false }
        guard enabled else { return true }
        guard !returningLocal, pendingControl == nil, sessions[peer]?.admitted == true else { return false }
        return !requested || (persistenceHealthy && surfacesVerified && epoch != nil && captureForPeer(peer) == epoch)
    }

    func allowsActions(_ peer: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowsActionsLocked(peer)
    }

    private func allowsActionsLocked(_ peer: ObjectIdentifier) -> Bool {
        guard !localReturnRequestActive else { return false }
        guard enabled else { return true }
        guard !returningLocal, pendingControl == nil, sessions[peer]?.admitted == true else { return false }
        return !requested || (persistenceHealthy && surfacesVerified)
    }

    func sourceSelectionAdmission(for peer: ObjectIdentifier) -> SourceSelectionAdmission? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let session = sessions[peer], let generation = session.selectionGeneration else { return nil }
        return SourceSelectionAdmission(generation: generation, ready: session.selectionReady)
    }

    private func refreshSelectionAdmissionLocked() {
        for peer in sessions.keys {
            guard var session = sessions[peer] else { continue }
            let ready = allowsActionsLocked(peer)
            guard session.selectionGeneration == nil || session.selectionReady != ready else { continue }
            session.selectionReady = ready
            if selectionGeneration < SourceSelectionAdmission.maximumGeneration {
                selectionGeneration += 1
                session.selectionGeneration = selectionGeneration
            } else {
                session.selectionGeneration = nil
            }
            sessions[peer] = session
        }
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
            return !localReturnRequestActive && (!enabled || (!requested && !returningLocal && pendingControl == nil && sessions[peer]?.admitted == true))
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
        if localReturnRequestActive { phase = .blocked }
        else if pendingControl != nil { phase = .pending }
        else if !requested { phase = .inactive }
        else if !persistenceHealthy || reason != nil || returningLocal { phase = .blocked }
        else if surfacesVerified && captureForPeer(peer) != nil { phase = .userSessionProtected }
        else { phase = .pending }
        let control = controlIdentityLocked(peer).map {
            SentryControlCapability(authorizationGeneration: $0.generation, manualIntent: manualIntent)
        }
        return SentryState(hostBootID: bootID, sessionID: session.id, revision: revision,
                           requested: requested || pendingControl != nil, phase: phase, reason: localReturnRequestActive ? "로컬 복귀 인증과 정리 중에는 원격 명령을 차단합니다." : reason, limitations: Self.limitations, control: control)
    }

    func accept(_ activation: SentryActivation, from peer: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled, !returningLocal && !localReturnRequestActive, pendingControl == nil, activation.version == 1, activation.hostBootID == bootID,
              var session = sessions[peer], session.admitted,
              activation.sessionID == session.id else { return false }
        if session.requests.contains(activation.requestID) { return manualIntent == .on }
        guard activation.revision == revision else { return false }
        session.requests.append(activation.requestID)
        if session.requests.count > 64 { session.requests.removeFirst() }
        sessions[peer] = session
        manualIntent = .on
        manualOwner = session.controlDeviceID
        policyRevision = UUID()
        revision = UUID()
        if !requested {
            requested = true
            surfacesVerified = false
            protectionRevision = UUID()
            inactiveRevision = UUID()
            revision = UUID()
            refreshSelectionAdmissionLocked()
        }
        return true
    }

    @discardableResult
    func grantControl(to peer: ObjectIdentifier, verifiedOwner: VerifiedOwnerDevice) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, !returningLocal, var session = sessions[peer], session.admitted,
              session.controlDeviceID == nil || session.controlDeviceID == verifiedOwner.deviceID else { return nil }
        let existing = controlGrants[verifiedOwner.deviceID]
        let generation = existing ?? UUID()
        let changed = existing == nil || session.controlDeviceID != verifiedOwner.deviceID
        controlGrants[verifiedOwner.deviceID] = generation
        session.controlDeviceID = verifiedOwner.deviceID
        sessions[peer] = session
        if changed { revision = UUID() }
        return generation
    }

    func revokeControl(forDeviceID deviceID: String) {
        lock.lock(); defer { lock.unlock() }
        guard controlGrants.removeValue(forKey: deviceID) != nil else { return }
        if pendingControl?.deviceID == deviceID { cancelPendingLocked() }
        for peer in sessions.keys where sessions[peer]?.controlDeviceID == deviceID {
            sessions[peer]?.controlDeviceID = nil
        }
        operations = operations.filter { $0.value.deviceID != deviceID }
        operationOrder.removeAll { operations[$0] == nil }
        if manualOwner == deviceID {
            manualOwner = nil
            policyRevision = UUID()
            surfacesVerified = false
            reason = nil
        }
        protectionRevision = UUID()
        inactiveRevision = UUID()
        revision = UUID()
        refreshSelectionAdmissionLocked()
    }

    private func controlIdentityLocked(_ peer: ObjectIdentifier) -> (deviceID: String, generation: UUID)? {
        guard enabled, let session = sessions[peer], session.admitted,
              let deviceID = session.controlDeviceID, let generation = controlGrants[deviceID] else { return nil }
        return (deviceID, generation)
    }

    func prepareControl(_ request: SentryControlRequest, from peer: ObjectIdentifier) -> ControlPreparation {
        lock.lock(); defer { lock.unlock() }
        guard let identity = controlIdentityLocked(peer), let state = statusLocked(for: peer) else { return .unauthorized }
        func rejection(_ code: SentryControlResponse.Code, unknown: Bool = false) -> ControlPreparation {
            .rejected(SentryControlResponse(requestID: request.requestID, accepted: false,
                operationState: unknown ? .unknown : .rejected, code: code, state: state))
        }
        if let record = operations[request.requestID] {
            guard record.deviceID == identity.deviceID,
                  record.request.authorizationGeneration == identity.generation else { return rejection(.notAuthorized) }
            guard record.request.rawRequest == request.rawRequest else { return rejection(.requestConflict) }
            return .readback(responseLocked(record, for: peer)!)
        }
        guard request.hostBootID == bootID else { return rejection(.unknown, unknown: true) }
        guard request.authorizationGeneration == identity.generation else { return rejection(.notAuthorized) }
        guard request.sessionID == sessions[peer]?.id else {
            return rejection(.unknown, unknown: true)
        }
        guard !returningLocal && !localReturnRequestActive, pendingControl == nil else { return rejection(.busy) }
        guard request.revision == revision else { return rejection(.unknown, unknown: true) }
        let ticket = ControlTicket(request: request, nonce: UUID(), peer: peer,
                                   deviceID: identity.deviceID, policyRevision: policyRevision)
        pendingControl = ticket
        operations[request.requestID] = ControlRecord(request: request, deviceID: identity.deviceID,
            operationState: .pending, code: .pending)
        operationOrder.append(request.requestID)
        while operationOrder.count > Self.maximumOperations {
            operations.removeValue(forKey: operationOrder.removeFirst())
        }
        if request.desired { requested = true }
        protectionRevision = UUID()
        inactiveRevision = UUID()
        revision = UUID()
        refreshSelectionAdmissionLocked()
        return .prepared(ticket, responseLocked(operations[request.requestID]!, for: peer)!)
    }

    func controlTicketIsCurrent(_ ticket: ControlTicket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingControl == ticket, !returningLocal && !localReturnRequestActive, policyRevision == ticket.policyRevision,
              let identity = controlIdentityLocked(ticket.peer), identity.deviceID == ticket.deviceID,
              identity.generation == ticket.request.authorizationGeneration,
              sessions[ticket.peer]?.id == ticket.request.sessionID else { return false }
        return true
    }

    func completeControl(_ ticket: ControlTicket, result: ControlResult) -> SentryControlResponse? {
        lock.lock(); defer { lock.unlock() }
        guard pendingControl == ticket, policyRevision == ticket.policyRevision,
              let identity = controlIdentityLocked(ticket.peer), identity.deviceID == ticket.deviceID,
              identity.generation == ticket.request.authorizationGeneration,
              sessions[ticket.peer]?.id == ticket.request.sessionID,
              var record = operations[ticket.request.requestID] else {
            guard let identity = controlIdentityLocked(ticket.peer), identity.deviceID == ticket.deviceID,
                  identity.generation == ticket.request.authorizationGeneration,
                  let record = operations[ticket.request.requestID] else { return nil }
            return responseLocked(record, for: ticket.peer)
        }
        var failure: SentryControlResponse.Code?
        switch result {
        case .pending: return responseLocked(record, for: ticket.peer)
        case .onPrepared(let verified):
            if !ticket.request.desired || !verified || !persistenceHealthy { failure = .targetUnconfirmed }
        case .onVerified(let verified, let epoch):
            if !ticket.request.desired || !verified || !persistenceHealthy || captureForPeer(ticket.peer) != epoch {
                failure = .targetUnconfirmed
            }
        case .offVerified(let curtains, let tap, let held):
            if ticket.request.desired || !curtains || !tap || !held { failure = .targetUnconfirmed }
        case .failed: failure = .controlFailed
        case .targetUnconfirmed: failure = .targetUnconfirmed
        }
        pendingControl = nil
        if let failure {
            record.operationState = .rejected
            record.code = failure
            surfacesVerified = false
            reason = "Sentry 전환의 실제 결과를 확인하지 못했습니다."
        } else {
            requested = ticket.request.desired
            surfacesVerified = requested
            reason = nil
            manualIntent = requested ? .on : .off
            manualOwner = ticket.deviceID
            policyRevision = UUID()
            record.completedPolicy = policyRevision
            if case .onPrepared = result {
                record.operationState = .pending
                record.code = .pending
            } else {
                record.operationState = .applied
                record.code = .applied
            }
        }
        operations[ticket.request.requestID] = record
        protectionRevision = UUID()
        inactiveRevision = UUID()
        revision = UUID()
        refreshSelectionAdmissionLocked()
        return responseLocked(record, for: ticket.peer)
    }

    private func responseLocked(_ record: ControlRecord, for peer: ObjectIdentifier) -> SentryControlResponse? {
        guard let state = statusLocked(for: peer) else { return nil }
        var current = record
        let superseded = record.completedPolicy != nil && record.completedPolicy != policyRevision
        if !superseded, current.operationState == .pending, current.completedPolicy != nil,
           state.requested, state.phase == .userSessionProtected {
            current.operationState = .applied
            current.code = .applied
            operations[current.request.requestID] = current
        }
        return SentryControlResponse(requestID: current.request.requestID, accepted: true,
            operationState: superseded ? .superseded : current.operationState,
            code: superseded ? .superseded : current.code, state: state)
    }

    private func cancelPendingLocked(for peer: ObjectIdentifier? = nil) {
        guard let ticket = pendingControl, peer == nil || ticket.peer == peer else { return }
        if var record = operations[ticket.request.requestID] {
            record.operationState = .unknown
            record.code = .unknown
            operations[ticket.request.requestID] = record
        }
        pendingControl = nil
        surfacesVerified = false
        reason = "Sentry 전환의 실제 결과를 확인하지 못했습니다."
        revision = UUID()
        protectionRevision = UUID()
        inactiveRevision = UUID()
        refreshSelectionAdmissionLocked()
    }

    func fenceForLocalReturn() {
        lock.lock(); defer { lock.unlock() }
        cancelPendingLocked()
        protectionRevision = UUID()
        inactiveRevision = UUID()
        returningLocal = true
        surfacesVerified = false
        revision = UUID()
        refreshSelectionAdmissionLocked()
    }

    func setLocalReturnRequestActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard localReturnRequestActive != active else { return }
        localReturnRequestActive = active
        if active { cancelPendingLocked() }
        protectionRevision = UUID()
        inactiveRevision = UUID()
        revision = UUID()
        refreshSelectionAdmissionLocked()
    }

    func completeLocalReturn() {
        lock.lock(); defer { lock.unlock() }
        pendingControl = nil
        controlGrants.removeAll()
        operations.removeAll()
        operationOrder.removeAll()
        manualIntent = .automatic
        manualOwner = nil
        policyRevision = UUID()
        sessions.removeAll()
        peerCaptureEpochs.removeAll()
        independentCapturePeers.removeAll()
        protectionRevision = UUID()
        inactiveRevision = UUID()
        requested = false
        returningLocal = false
        surfacesVerified = false
        captureEpoch = nil
        reason = nil
        revision = UUID()
    }
}
