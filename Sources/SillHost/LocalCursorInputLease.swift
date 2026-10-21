import Dispatch
import Foundation

@MainActor
final class LocalCursorInputLease {
    enum Origin: String {
        case ccrLocal = "ccr-local"
    }

    enum Interaction: Equatable {
        case windowScoped
        case conversationScoped(conversationID: String)
    }

    // Equality binds a request to observations. It does not prove conversation authority.
    struct Target: Equatable {
        let pid: Int32
        let windowID: UInt32 // CGWindowID's raw representation, without a platform dependency.
        let instanceID: String
        let workspace: String
        let interaction: Interaction
        let captureGeneration: String
        let videoEpoch: UUID
    }

    @MainActor
    final class Connection {
        let id: UUID

        fileprivate init() { id = UUID() }
    }

    @MainActor
    final class Grant {
        let id: UUID
        let connection: Connection
        let generation: UUID
        let target: Target
        let deadlineNanoseconds: UInt64
        let origin = Origin.ccrLocal

        fileprivate init(connection: Connection, target: Target, deadline: UInt64, renewing: Grant? = nil) {
            id = renewing?.id ?? UUID()
            self.connection = connection
            generation = renewing?.generation ?? UUID()
            self.target = target
            deadlineNanoseconds = deadline
        }
    }

    enum Refusal: Error, Equatable {
        case connectionNotOpen
        case invalidTTL
        case remoteViewerOwnsInput
        case sentryProtected
        case localOwnerBusy
        case staleGrant
        case releaseInProgress
        case deadlineOverflow
    }

    enum ReleaseReason: Equatable {
        case explicitRelease
        case expired
        case targetChanged
        case connectionClosed
        case remoteViewerOwnsInput
        case sentryProtected
    }

    static let ttlRangeMilliseconds = 100...2000

    private let now: () -> UInt64
    private let releaseDown: (Connection, Target, ReleaseReason) -> Void
    private var connections: [UUID: Connection] = [:]
    private var current: Grant?
    private var releasing = false
    private var remoteViewerOwnsInput = false
    private var sentryProtected = false

    // The injected clock must be a side-effect-free monotonic nanosecond clock.
    init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         releaseDown: @escaping (Connection, Target, ReleaseReason) -> Void) {
        self.now = now
        self.releaseDown = releaseDown
    }

    // Only the host calls this, after validating the IPC peer. No caller ID is accepted.
    func openConnection() -> Connection {
        let connection = Connection()
        connections[connection.id] = connection
        return connection
    }

    func closeConnection(_ connection: Connection) {
        guard connections[connection.id] === connection else { return }
        connections[connection.id] = nil
        if let current, current.connection === connection {
            revoke(current, reason: .connectionClosed)
        }
    }

    @discardableResult
    func release(_ grant: Grant) -> Bool {
        // Cleanup uses exact object identity, without expiring an unrelated current owner.
        guard current === grant else { return false }
        revoke(grant, reason: .explicitRelease)
        return true
    }

    func claim(_ connection: Connection, target: Target,
               ttlMilliseconds: Int = 500) throws -> Grant {
        try validateRequest(connection, ttlMilliseconds: ttlMilliseconds)
        expireIfNeeded()
        try requireAvailable()
        let previous = current
        if let previous {
            guard previous.connection === connection, previous.target != target else {
                throw Refusal.localOwnerBusy
            }
        }
        let grant = try makeGrant(connection, target: target, ttlMilliseconds: ttlMilliseconds)
        if let previous { revoke(previous, reason: .targetChanged) }
        // A release callback may close the connection or enable remote protection.
        try validateRequest(connection, ttlMilliseconds: ttlMilliseconds)
        try requireAvailable()
        guard now() < grant.deadlineNanoseconds else { throw Refusal.staleGrant }
        current = grant
        return grant
    }

    func renew(_ grant: Grant, ttlMilliseconds: Int = 500) throws -> Grant {
        try validateRequest(grant.connection, ttlMilliseconds: ttlMilliseconds)
        expireIfNeeded()
        try requireAvailable()
        guard isCurrent(grant) else { throw Refusal.staleGrant }
        let renewed = try makeGrant(grant.connection, target: grant.target, ttlMilliseconds: ttlMilliseconds, renewing: grant)
        current = renewed
        return renewed
    }

    // Conversation commands require an authoritative compare-and-execute guard, which
    // Companion 0.2 cannot supply. Ordinary window input does not use conversation IDs.
    @discardableResult
    func withAuthorization(_ grant: Grant, windowCurrent: (Target) -> Bool,
                           conversationAuthority: ((Target, () -> Void) -> Void)? = nil,
                           operation: () -> Void) -> Bool {
        guard isCurrent(grant) else { return false }
        switch grant.target.interaction {
        case .windowScoped:
            return postIfCurrent(grant, windowCurrent: windowCurrent, operation: operation)
        case .conversationScoped:
            guard let conversationAuthority else { return false }
            var performed = false
            conversationAuthority(grant.target) {
                guard !performed else { return }
                _ = self.postIfCurrent(grant, windowCurrent: windowCurrent) {
                    performed = true
                    operation()
                }
            }
            return performed
        }
    }

    @discardableResult
    func expireIfNeeded() -> Bool {
        guard let current, now() >= current.deadlineNanoseconds else { return false }
        revoke(current, reason: .expired)
        return true
    }

    func remoteStateChanged(remoteViewerOwnsInput: Bool, sentryProtected: Bool) {
        self.remoteViewerOwnsInput = remoteViewerOwnsInput
        self.sentryProtected = sentryProtected
        guard let current else { return }
        if remoteViewerOwnsInput { revoke(current, reason: .remoteViewerOwnsInput) }
        else if sentryProtected { revoke(current, reason: .sentryProtected) }
    }

    private func validateRequest(_ connection: Connection, ttlMilliseconds: Int) throws {
        guard connections[connection.id] === connection else { throw Refusal.connectionNotOpen }
        guard Self.ttlRangeMilliseconds.contains(ttlMilliseconds) else { throw Refusal.invalidTTL }
    }

    private func requireAvailable() throws {
        guard !releasing else { throw Refusal.releaseInProgress }
        guard !remoteViewerOwnsInput else { throw Refusal.remoteViewerOwnsInput }
        guard !sentryProtected else { throw Refusal.sentryProtected }
    }

    private func makeGrant(_ connection: Connection, target: Target, ttlMilliseconds: Int,
                           renewing: Grant? = nil) throws -> Grant {
        let (deadline, overflow) = now().addingReportingOverflow(UInt64(ttlMilliseconds) * 1_000_000)
        guard !overflow else { throw Refusal.deadlineOverflow }
        return Grant(connection: connection, target: target, deadline: deadline, renewing: renewing)
    }

    private func postIfCurrent(_ grant: Grant, windowCurrent: (Target) -> Bool, operation: () -> Void) -> Bool {
        guard isCurrent(grant) else { return false }
        let windowMatches = windowCurrent(grant.target)
        // The callback may renew, close, expire, or replace this exact grant.
        guard isCurrent(grant) else { return false }
        guard windowMatches else {
            revoke(grant, reason: .targetChanged)
            return false
        }
        operation()
        return true
    }

    private func isCurrent(_ grant: Grant) -> Bool {
        let instant = now()
        if let current, instant >= current.deadlineNanoseconds { revoke(current, reason: .expired) }
        guard !releasing, !remoteViewerOwnsInput, !sentryProtected,
              let current, current === grant,
              connections[grant.connection.id] === grant.connection,
              current.connection === grant.connection,
              current.generation == grant.generation,
              current.target == grant.target,
              current.deadlineNanoseconds == grant.deadlineNanoseconds,
              instant < grant.deadlineNanoseconds else { return false }
        return true
    }

    private func revoke(_ grant: Grant, reason: ReleaseReason) {
        guard current === grant else { return }
        // Invalidate before calling out, and finish releasing this owner's Down before any claim.
        current = nil
        releasing = true
        defer { releasing = false }
        releaseDown(grant.connection, grant.target, reason)
    }
}
