import Foundation
import CryptoKit
import StreamProtocol

/// In-memory authority only. The adapter validates live connections, runs commands and supplies OS/readback completions.
@MainActor
package final class SentryReturnAuthority {
    package struct Owner: Hashable, Sendable {
        package let ownerID, hostFingerprint, deviceFingerprint, tlsFingerprint, pairingGeneration: String
        package init?(ownerID: String, hostFingerprint: String, deviceFingerprint: String, tlsFingerprint: String,
                      pairingGeneration: String, encryptedTLS: Bool, currentPairedOwner: Bool) {
            func fingerprint(_ value: String) -> Bool {
                value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
            guard encryptedTLS, currentPairedOwner, !ownerID.isEmpty, ownerID.utf8.count <= 128,
                  ownerID.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }),
                  fingerprint(hostFingerprint), fingerprint(deviceFingerprint), deviceFingerprint == tlsFingerprint,
                  UUID(uuidString: pairingGeneration)?.uuidString.lowercased() == pairingGeneration else { return nil }
            self.ownerID = ownerID; self.hostFingerprint = hostFingerprint; self.deviceFingerprint = deviceFingerprint
            self.tlsFingerprint = tlsFingerprint; self.pairingGeneration = pairingGeneration
        }
    }
    package struct Snapshot: Equatable, Sendable {
        package let owner: Owner
        package let lease: SentryReturnLease
        package init(owner: Owner, lease: SentryReturnLease) { self.owner = owner; self.lease = lease }
    }
    package struct MacAuthenticationTicket: Equatable, Sendable {
        fileprivate let issuer: UUID
        package let challenge: SentryReturnChallenge
    }
    package struct LocalReturnTicket: Equatable, Sendable {
        fileprivate let issuer: UUID
        package let challenge: SentryReturnChallenge
    }
    package struct CommitPermit: Equatable, Sendable {
        fileprivate let ticket: LocalReturnTicket
        fileprivate let nonce: UUID
    }
    package struct KeyRegistration: Equatable, Sendable {
        package let owner: Owner
        package let keyID: String
        package let publicKeySPKI: Data
    }
    package struct KeyChange: Equatable, Sendable {
        package let owner: Owner
        package let previous: KeyRegistration?
        package let current: KeyRegistration?
        package let authorizedBy: MacAuthenticationTicket
    }
    package enum Command: Equatable, Sendable {
        case authenticateMac(MacAuthenticationTicket)
        case cancelMac(MacAuthenticationTicket)
        case returnLocal(LocalReturnTicket)
        case cancelReturn(LocalReturnTicket)
        case keyChanged(KeyChange)
    }
    package struct Decision: Sendable {
        package let state: SentryReturnState?
        package let commands: [Command]
    }
    /// Only the trusted Mac LA adapter calls this completion. It is not Codable and never accepted from the wire.
    package enum MacAuthenticationCompletion: Sendable { case authenticated, denied, cancelled, unavailable }
    /// A completed command requires actual restoration readback. Authentication alone cannot construct a completed state.
    package enum RestorationCompletion: Sendable { case verifiedRestored, failed, unconfirmed }

    private enum Stage { case authenticating, restoring, committing, terminal }
    private final class Record {
        let request: SentryReturnRequest
        let snapshot: Snapshot
        var challenge: SentryReturnChallenge?
        var stage = Stage.authenticating
        var auth = SentryReturnState.AuthStatus.pending
        var operation = SentryReturnState.OperationState.authenticating
        var code = SentryReturnState.Code.authenticationRequired
        var deadline: TimeInterval
        var permit: CommitPermit?
        init(request: SentryReturnRequest, snapshot: Snapshot, deadline: TimeInterval) {
            self.request = request; self.snapshot = snapshot; self.deadline = deadline
        }
    }
    package static let maximumRecords = 256
    package let hostBootID: String
    private let issuer = UUID()
    private var records: [String: Record] = [:]
    private var keys: [Owner: KeyRegistration] = [:]
    private var lastNow: TimeInterval = 0

    package init(hostBootID: UUID = UUID()) { self.hostBootID = hostBootID.uuidString.lowercased() }

    package func capability(owner: Owner, macLocalAvailable: Bool) -> SentryReturnCapability {
        .init(macLocal: macLocalAvailable, deviceBoundKey: keys[owner] != nil)
    }

    package func handle(_ control: SentryReturnControl, now: TimeInterval,
                        current: () -> Snapshot?) -> Decision {
        let expired = expire(now: now).flatMap(\.commands)
        guard now.isFinite, now >= lastNow, now < Double(Int.max) / 1000,
              let snapshot = current(), current() == snapshot,
              snapshot.lease.hostBootID == hostBootID else { return .init(state: nil, commands: expired) }
        switch control {
        case .request(let request):
            let decision = begin(request, snapshot: snapshot, now: now)
            return .init(state: decision.state, commands: expired + decision.commands)
        case .current(let reference), .cancel(let reference, _), .prove(let reference, _, _):
            guard let record = records[reference.requestID] else {
                return .init(state: reply(reference, .notStarted, .unknown, .unknown), commands: expired)
            }
            guard record.snapshot.owner == snapshot.owner else { return .init(state: nil, commands: expired) }
            guard record.request.reference == reference else {
                return .init(state: reply(reference, .notStarted, .rejected, .requestConflict), commands: expired)
            }
            if record.stage == .terminal { return .init(state: state(record, now), commands: expired) }
            guard record.snapshot == snapshot else {
                let commands = terminate(record, operation: .rejected, code: .staleLease)
                return .init(state: state(record, now), commands: expired + commands)
            }
            switch control {
            case .current: return .init(state: state(record, now), commands: expired)
            case .cancel(_, let generation):
                guard record.challenge?.authGeneration == generation else {
                    return .init(state: reply(reference, .notStarted, .rejected, .invalidProof), commands: expired)
                }
                let commands = terminate(record, operation: .cancelled, code: .cancelled)
                return .init(state: state(record, now), commands: expired + commands)
            case .prove(_, let generation, let signature):
                guard record.stage == .authenticating, let challenge = record.challenge,
                      challenge.authMode == .deviceBoundKey, challenge.authGeneration == generation else {
                    return .init(state: reply(reference, .notStarted, .rejected, .invalidProof), commands: expired)
                }
                guard verifyDeviceProof(signature, challenge: challenge, owner: snapshot.owner) else {
                    let commands = terminate(record, operation: .rejected, code: .invalidProof)
                    return .init(state: state(record, now), commands: expired + commands)
                }
                // The signature verifier is separate from the Mac completion boundary. Neither accepts a client bool.
                let decision = authenticated(record, now: now, current: current)
                return .init(state: decision.state, commands: expired + decision.commands)
            case .request: fatalError("unreachable")
            }
        }
    }

    private func begin(_ request: SentryReturnRequest, snapshot: Snapshot, now: TimeInterval) -> Decision {
        if let record = records[request.requestID] {
            guard record.snapshot.owner == snapshot.owner else { return .init(state: nil, commands: []) }
            guard record.request.rawRequest == request.rawRequest else {
                return .init(state: reply(request.reference, .notStarted, .rejected, .requestConflict), commands: [])
            }
            if record.stage != .terminal && record.snapshot != snapshot {
                let commands = terminate(record, operation: .rejected, code: .staleLease)
                return .init(state: state(record, now), commands: commands)
            }
            return .init(state: state(record, now), commands: [])
        }
        guard request.lease == snapshot.lease else {
            return .init(state: reply(request.reference, .notStarted, .rejected, .staleLease), commands: [])
        }
        guard records.count < Self.maximumRecords else {
            return .init(state: reply(request.reference, .notStarted, .rejected, .capacity), commands: [])
        }
        let busy = records.values.contains { $0.stage != .terminal }
        let record = Record(request: request, snapshot: snapshot, deadline: now + 120)
        records[request.requestID] = record
        if busy {
            record.auth = .notStarted; _ = terminate(record, operation: .rejected, code: .busy)
            return .init(state: state(record, now), commands: [])
        }
        if let enrollment = request.keyEnrollment, !enrollmentMatches(enrollment, owner: snapshot.owner) {
            record.auth = .notStarted; _ = terminate(record, operation: .rejected, code: .enrollmentConflict)
            return .init(state: state(record, now), commands: [])
        }
        let key = keys[snapshot.owner]
        if request.authMode == .deviceBoundKey && key == nil {
            record.auth = .unsupported; _ = terminate(record, operation: .rejected, code: .noEnrolledKey)
            return .init(state: state(record, now), commands: [])
        }
        let owner = snapshot.owner
        var random = SystemRandomNumberGenerator()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        record.challenge = try! .init(reference: request.reference, lease: request.lease,
            authGeneration: UUID().uuidString.lowercased(), nonce: nonce.base64EncodedString(), ownerID: owner.ownerID,
            hostFingerprint: owner.hostFingerprint, deviceFingerprint: owner.deviceFingerprint,
            pairingGeneration: owner.pairingGeneration, authMode: request.authMode,
            keyID: request.authMode == .deviceBoundKey ? key?.keyID : nil)
        let commands: [Command] = request.authMode == .macLocal
            ? [.authenticateMac(.init(issuer: issuer, challenge: record.challenge!))] : []
        return .init(state: state(record, now), commands: commands)
    }

    package func completeMacAuthentication(_ ticket: MacAuthenticationTicket, result: MacAuthenticationCompletion,
                                          now: TimeInterval, current: () -> Snapshot?) -> Decision {
        let expired = expire(now: now).flatMap(\.commands)
        guard let record = matching(ticket.challenge, issuer: ticket.issuer), record.stage == .authenticating,
              record.request.authMode == .macLocal else { return .init(state: nil, commands: expired) }
        guard current() == record.snapshot, current() == record.snapshot, record.stage == .authenticating else {
            return .init(state: nil, commands: expired + terminate(record, operation: .rejected, code: .staleLease))
        }
        if result == .authenticated {
            let decision = authenticated(record, now: now, current: current)
            return .init(state: decision.state, commands: expired + decision.commands)
        }
        record.auth = result == .cancelled ? .cancelled : result == .unavailable ? .unsupported : .failed
        let commands = terminate(record, operation: result == .cancelled ? .cancelled : .rejected,
                                 code: result == .cancelled ? .cancelled : .authenticationFailed)
        return .init(state: state(record, now), commands: expired + commands)
    }

    private func verifyDeviceProof(_ signature: Data, challenge: SentryReturnChallenge, owner: Owner) -> Bool {
        guard let registration = keys[owner], registration.keyID == challenge.keyID,
              (8...72).contains(signature.count),
              let key = try? P256.Signing.PublicKey(derRepresentation: registration.publicKeySPKI),
              let proof = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              let bytes = try? challenge.signingBytes() else { return false }
        return key.isValidSignature(proof, for: bytes)
    }

    private func authenticated(_ record: Record, now: TimeInterval, current: () -> Snapshot?) -> Decision {
        guard record.stage == .authenticating, now.isFinite, now >= lastNow, now < record.deadline,
              current() == record.snapshot, current() == record.snapshot, record.stage == .authenticating,
              let challenge = record.challenge else {
            return .init(state: nil, commands: terminate(record, operation: .rejected, code: .staleLease))
        }
        record.auth = .succeeded
        if let enrollment = record.request.keyEnrollment {
            guard record.request.authMode == .macLocal, enrollmentMatches(enrollment, owner: record.snapshot.owner) else {
                return .init(state: nil, commands: terminate(record, operation: .rejected, code: .enrollmentConflict))
            }
            let owner = record.snapshot.owner, previous = keys[owner]
            let registration: KeyRegistration? = enrollment.action == .revoke ? nil : .init(owner: owner,
                keyID: enrollment.keyID, publicKeySPKI: Data(base64Encoded: enrollment.publicKey!)!)
            keys[owner] = registration
            record.stage = .terminal; record.operation = .completed
            switch enrollment.action {
            case .enroll: record.code = .keyEnrolled
            case .rotate: record.code = .keyRotated
            case .revoke: record.code = .keyRevoked
            }
            return .init(state: state(record, now), commands: [.keyChanged(.init(owner: owner, previous: previous,
                current: registration, authorizedBy: .init(issuer: issuer, challenge: challenge)))])
        }
        record.stage = .restoring; record.operation = .restoring; record.code = .returnPrepared
        record.deadline = now + 30
        return .init(state: state(record, now), commands: [.returnLocal(.init(issuer: issuer, challenge: challenge))])
    }

    private func enrollmentMatches(_ change: SentryReturnKeyEnrollment, owner: Owner) -> Bool {
        switch change.action {
        case .enroll: return keys[owner] == nil
        case .rotate: return keys[owner]?.keyID == change.previousKeyID && keys[owner]?.keyID != change.keyID
        case .revoke: return keys[owner]?.keyID == change.keyID
        }
    }

    /// Use as the existing admission closure throughout asynchronous restoration, including immediately before HAL/commit.
    package func returnIsCurrent(_ ticket: LocalReturnTicket, now: TimeInterval, current: () -> Snapshot?) -> Bool {
        guard let record = matching(ticket.challenge, issuer: ticket.issuer),
              record.stage == .restoring || record.stage == .committing,
              now.isFinite, now >= lastNow, now < record.deadline,
              current() == record.snapshot, current() == record.snapshot else { return false }
        return record.stage == .restoring || record.stage == .committing
    }

    /// Acquire immediately before the synchronous host commit. This never changes Sentry admission itself.
    package func authorizeCommit(_ ticket: LocalReturnTicket, now: TimeInterval,
                                 current: () -> Snapshot?) -> CommitPermit? {
        guard returnIsCurrent(ticket, now: now, current: current),
              let record = matching(ticket.challenge, issuer: ticket.issuer), record.stage == .restoring else { return nil }
        let permit = CommitPermit(ticket: ticket, nonce: UUID())
        lastNow = now
        record.permit = permit; record.stage = .committing
        return permit
    }

    /// The trusted adapter supplies a current owner independently of the Sentry session cleared by completeLocalReturn.
    package func completeReturn(_ permit: CommitPermit, result: RestorationCompletion, now: TimeInterval,
                                currentOwner: () -> Owner?) -> Decision {
        let expired = expire(now: now).flatMap(\.commands)
        guard let record = matching(permit.ticket.challenge, issuer: permit.ticket.issuer),
              record.stage == .committing, record.permit == permit else { return .init(state: nil, commands: expired) }
        guard currentOwner() == record.snapshot.owner, currentOwner() == record.snapshot.owner,
              record.stage == .committing else {
            return .init(state: nil, commands: expired + terminate(record, operation: .unknown, code: .staleLease))
        }
        record.stage = .terminal; record.permit = nil
        switch result {
        case .verifiedRestored: record.operation = .completed; record.code = .localReturned
        case .failed: record.operation = .failed; record.code = .restoreFailed
        case .unconfirmed: record.operation = .unknown; record.code = .restoreFailed
        }
        return .init(state: state(record, now), commands: expired)
    }

    package func restorationFailed(_ ticket: LocalReturnTicket, now: TimeInterval) -> Decision {
        let expired = expire(now: now).flatMap(\.commands)
        guard let record = matching(ticket.challenge, issuer: ticket.issuer), record.stage == .restoring else {
            return .init(state: nil, commands: expired)
        }
        return .init(state: stateAfterFailure(record, now), commands: expired + [.cancelReturn(ticket)])
    }
    private func stateAfterFailure(_ record: Record, _ now: TimeInterval) -> SentryReturnState {
        record.stage = .terminal; record.operation = .failed; record.code = .restoreFailed
        return state(record, now)
    }

    /// Call from the existing disconnect/revocation callbacks, not a new service or timer.
    package func disconnected(_ owner: Owner, now: TimeInterval) -> [Decision] {
        var decisions = expire(now: now)
        for record in records.values where record.snapshot.owner == owner && record.stage != .terminal {
            let commands = terminate(record, operation: .rejected, code: .staleLease)
            decisions.append(.init(state: nil, commands: commands))
        }
        return decisions
    }

    package func expire(now: TimeInterval) -> [Decision] {
        let invalidClock = !now.isFinite || now < lastNow || now >= Double(Int.max) / 1000
        if !invalidClock { lastNow = now }
        var decisions: [Decision] = []
        for record in records.values where record.stage != .terminal && (invalidClock || now >= record.deadline) {
            let commands = terminate(record, operation: .expired, code: .expired)
            decisions.append(.init(state: state(record, lastNow), commands: commands))
        }
        return decisions
    }

    private func matching(_ challenge: SentryReturnChallenge, issuer: UUID) -> Record? {
        guard issuer == self.issuer, let record = records[challenge.reference.requestID], record.challenge == challenge else { return nil }
        return record
    }
    private func terminate(_ record: Record, operation: SentryReturnState.OperationState,
                           code: SentryReturnState.Code) -> [Command] {
        guard record.stage != .terminal else { return [] }
        var commands: [Command] = []
        if let challenge = record.challenge {
            if record.stage == .authenticating, record.request.authMode == .macLocal {
                commands.append(.cancelMac(.init(issuer: issuer, challenge: challenge)))
            } else if record.stage == .restoring || record.stage == .committing {
                commands.append(.cancelReturn(.init(issuer: issuer, challenge: challenge)))
            }
        }
        if record.auth == .pending {
            record.auth = operation == .expired ? .expired : operation == .cancelled ? .cancelled : .failed
        }
        record.operation = record.stage == .committing ? .unknown : operation
        record.stage = .terminal; record.code = code; record.permit = nil
        return commands
    }
    private func state(_ record: Record, _ now: TimeInterval) -> SentryReturnState {
        let waiting = record.stage == .authenticating
        let remaining = waiting ? min(120000, max(0, Int(ceil((record.deadline - now) * 1000)))) : 0
        return try! .init(reference: record.request.reference, authGeneration: record.challenge?.authGeneration,
            authStatus: record.auth, operationState: record.operation, code: record.code,
            challenge: waiting ? record.challenge : nil, remainingMilliseconds: remaining)
    }
    private func reply(_ reference: SentryReturnReference, _ auth: SentryReturnState.AuthStatus,
                       _ operation: SentryReturnState.OperationState, _ code: SentryReturnState.Code) -> SentryReturnState {
        try! .init(reference: reference, authGeneration: nil, authStatus: auth,
                   operationState: operation, code: code, challenge: nil, remainingMilliseconds: 0)
    }
}
