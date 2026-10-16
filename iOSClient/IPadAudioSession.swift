import AVFoundation

final class IPadAudioSession {
    static let shared = IPadAudioSession()

    private struct PreviousConfiguration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private var leases = IPadAudioLeaseState()
    private var previous: PreviousConfiguration?

    private init() {}

    func acquire(_ role: IPadAudioLeaseState.Role, leaseId: UUID) throws {
        dispatchPrecondition(condition:.onQueue(.main))
        var next = leases
        try next.acquire(role,leaseId:leaseId)
        guard next != leases else { return }
        let session = AVAudioSession.sharedInstance()
        if leases.isEmpty {
            previous = PreviousConfiguration(category:session.category,mode:session.mode,
                                             options:session.categoryOptions)
        }
        do {
            if leases.isEmpty || leases.needsMicrophone != next.needsMicrophone {
                try configure(next)
            }
            leases = next
        } catch {
            if leases.isEmpty { restorePrevious() }
            else { try? configure(leases) }
            throw error
        }
    }

    func release(leaseId: UUID) {
        dispatchPrecondition(condition:.onQueue(.main))
        var next = leases
        guard next.release(leaseId:leaseId) else { return }
        let microphoneChanged = leases.needsMicrophone != next.needsMicrophone
        leases = next
        if next.isEmpty { restorePrevious() }
        else if microphoneChanged { try? configure(next) }
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

    private func restorePrevious() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false,options:.notifyOthersOnDeactivation)
        if let previous {
            try? session.setCategory(previous.category,mode:previous.mode,
                                     options:previous.options)
        }
        previous = nil
    }
}
