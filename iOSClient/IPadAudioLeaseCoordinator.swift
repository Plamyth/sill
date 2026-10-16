import Foundation

struct IPadAudioLeaseCoordinator {
    enum Error: LocalizedError {
        case cleanupRequired

        var errorDescription: String? { "이전 오디오 세션 정리가 필요합니다." }
    }

    private(set) var leases = IPadAudioLeaseState()
    private(set) var recoveryOwner: UUID?

    func holds(_ id: UUID) -> Bool { leases.leases[id] != nil }

    mutating func acquire(_ role: IPadAudioLeaseState.Role, id: UUID,
                          apply: (IPadAudioLeaseState, IPadAudioLeaseState) throws -> Void) throws {
        guard recoveryOwner == nil else { throw Error.cleanupRequired }
        var next = leases
        try next.acquire(role, leaseId: id)
        guard next != leases else { return }
        do {
            try apply(leases, next)
            leases = next
        } catch {
            leases = next
            recoveryOwner = id
            throw error
        }
    }

    mutating func release(id: UUID,
                          apply: (IPadAudioLeaseState, IPadAudioLeaseState) throws -> Void) throws {
        guard holds(id) else { return }
        guard recoveryOwner == nil || recoveryOwner == id else { throw Error.cleanupRequired }
        var next = leases
        _ = next.release(leaseId: id)
        do {
            try apply(leases, next)
            leases = next
            recoveryOwner = nil
        } catch {
            recoveryOwner = id
            throw error
        }
    }
}
