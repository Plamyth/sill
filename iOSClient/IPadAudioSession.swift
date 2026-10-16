import AVFoundation

final class IPadAudioSession {
    static let shared = IPadAudioSession()

    private struct PreviousConfiguration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private var coordinator = IPadAudioLeaseCoordinator()
    private var previous: PreviousConfiguration?

    private init() {}

    func holds(leaseId: UUID) -> Bool { coordinator.holds(leaseId) }

    func acquire(_ role: IPadAudioLeaseState.Role, leaseId: UUID) throws {
        dispatchPrecondition(condition:.onQueue(.main))
        if let recoveryOwner = coordinator.recoveryOwner {
            try release(leaseId: recoveryOwner)
        }
        let session = AVAudioSession.sharedInstance()
        var nextCoordinator = coordinator
        defer { coordinator = nextCoordinator }
        try nextCoordinator.acquire(role, id: leaseId) { old, next in
            if old.isEmpty && previous == nil {
                previous = PreviousConfiguration(category:session.category,mode:session.mode,
                                                 options:session.categoryOptions)
            }
            if old.isEmpty || old.needsMicrophone != next.needsMicrophone {
                try configure(next)
            }
        }
    }

    func release(leaseId: UUID) throws {
        dispatchPrecondition(condition:.onQueue(.main))
        var nextCoordinator = coordinator
        defer { coordinator = nextCoordinator }
        try nextCoordinator.release(id: leaseId) { old, next in
            if next.isEmpty { try restorePrevious() }
            else if old.needsMicrophone != next.needsMicrophone { try configure(next) }
        }
    }

    private func configure(_ active: IPadAudioLeaseState) throws {
        let session = AVAudioSession.sharedInstance()
        if active.needsMicrophone {
            try session.setCategory(.playAndRecord,mode:.default,
                                    options:[.defaultToSpeaker,.mixWithOthers])
        } else {
            try session.setCategory(.playback,mode:.default,options:[.mixWithOthers])
        }
        try session.setActive(true)
    }

    private func restorePrevious() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false,options:.notifyOthersOnDeactivation)
        if let previous {
            try session.setCategory(previous.category,mode:previous.mode,
                                    options:previous.options)
        }
        previous = nil
    }
}
