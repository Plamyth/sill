import AVFoundation

final class IPadAudioSession {
    enum Owner: Hashable {
        case remotePlayback
        case canvasDictation
    }

    static let shared = IPadAudioSession()

    private struct PreviousConfiguration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private var owners = Set<Owner>()
    private var previous: PreviousConfiguration?

    private init() {}

    func acquire(_ owner: Owner) throws {
        dispatchPrecondition(condition:.onQueue(.main))
        guard !owners.contains(owner) else { return }
        let session = AVAudioSession.sharedInstance()
        if owners.isEmpty {
            previous = PreviousConfiguration(category:session.category,mode:session.mode,
                                             options:session.categoryOptions)
        }
        let next = owners.union([owner])
        do {
            try configure(next)
            owners = next
        } catch {
            if owners.isEmpty { restorePrevious() }
            else { try? configure(owners) }
            throw error
        }
    }

    func release(_ owner: Owner) {
        dispatchPrecondition(condition:.onQueue(.main))
        guard owners.remove(owner) != nil else { return }
        if owners.isEmpty { restorePrevious() }
        else { try? configure(owners) }
    }

    private func configure(_ active: Set<Owner>) throws {
        let session = AVAudioSession.sharedInstance()
        if active.contains(.canvasDictation) {
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
