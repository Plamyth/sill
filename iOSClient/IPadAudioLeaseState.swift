import Foundation

struct IPadAudioLeaseState: Equatable {
    enum Role: Equatable {
        case remotePlayback
        case canvasDictation
        case microphoneUplink

        var needsMicrophone: Bool {
            switch self {
            case .remotePlayback: false
            case .canvasDictation, .microphoneUplink: true
            }
        }
    }

    enum LeaseError: LocalizedError {
        case roleMismatch
        case microphoneInUse

        var errorDescription: String? {
            switch self {
            case .roleMismatch: "오디오 사용자가 다른 기능으로 등록돼 있습니다."
            case .microphoneInUse: "다른 기능에서 이미 마이크를 사용 중입니다."
            }
        }
    }

    private(set) var leases: [UUID: Role] = [:]

    var isEmpty: Bool { leases.isEmpty }
    var needsMicrophone: Bool { leases.values.contains(where: \.needsMicrophone) }

    mutating func acquire(_ role: Role, leaseId: UUID) throws {
        if let existing = leases[leaseId] {
            guard existing == role else { throw LeaseError.roleMismatch }
            return
        }
        if role.needsMicrophone && needsMicrophone { throw LeaseError.microphoneInUse }
        leases[leaseId] = role
    }

    @discardableResult
    mutating func release(leaseId: UUID) -> Bool {
        leases.removeValue(forKey:leaseId) != nil
    }
}
