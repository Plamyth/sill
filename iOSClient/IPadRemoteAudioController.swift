import Foundation
import StreamProtocol

/// Owned by StreamClient on main. Consent belongs to one connection and one source.
final class IPadRemoteAudioController {
    enum Status: Equatable {
        case unavailable
        case off
        case requesting(UUID)
        case listening(UUID)
        case failed(String)

        var available: Bool { self != .unavailable }
        var requested: Bool {
            switch self {
            case .requesting, .listening: return true
            default: return false
            }
        }
    }

    private(set) var status: Status = .unavailable {
        didSet { if status != oldValue { changed(status) } }
    }
    private var peer: ObjectIdentifier?
    private var source: StreamSource = .none
    private let send: (ObjectIdentifier, RemoteAudioSubscription) -> Void
    private let stop: () -> Void
    private let play: (Data) -> Void
    private let changed: (Status) -> Void

    init(send: @escaping (ObjectIdentifier, RemoteAudioSubscription) -> Void,
         stop: @escaping () -> Void, play: @escaping (Data) -> Void,
         changed: @escaping (Status) -> Void) {
        self.send = send
        self.stop = stop
        self.play = play
        self.changed = changed
    }

    func setConnection(_ next: ObjectIdentifier?) {
        guard peer != next else { return }
        revoke()
        peer = next
        source = .none
        status = .unavailable
    }

    func receive(_ list: WindowList, from origin: ObjectIdentifier) {
        guard peer == origin else { return }
        if source != list.active || list.remoteAudio != 1 { revoke() }
        source = list.active
        if list.remoteAudio != 1 { status = .unavailable }
        else if status == .unavailable { status = .off }
    }

    func toggle() {
        guard let peer, status.available else { return }
        if status.requested { revoke(); return }
        let request = RemoteAudioSubscription(enabled: true)
        status = .requesting(request.requestID)
        send(peer, request)
    }

    func receive(_ answer: RemoteAudioState, from origin: ObjectIdentifier) {
        guard peer == origin else { return }
        if !answer.enabled, answer.requestID == nil {
            let requested = status.requested
            if requested { stop() }
            if requested { status = .failed(answer.reason ?? "Mac audio stopped") }
            return
        }
        let requestID: UUID
        switch status {
        case .requesting(let id), .listening(let id): requestID = id
        default: return
        }
        guard answer.requestID == requestID else { return }
        if answer.enabled { status = .listening(requestID) }
        else {
            stop()
            status = .failed(answer.reason ?? "Mac audio unavailable")
        }
    }

    func receiveAudio(_ packet: Data, from origin: ObjectIdentifier) {
        guard peer == origin, case .listening = status else { return }
        play(packet)
    }

    func expire(_ requestID: UUID, from origin: ObjectIdentifier) {
        guard peer == origin, status == .requesting(requestID) else { return }
        revoke()
        status = .failed("Mac audio did not respond.")
    }

    func sourceWillChange() { revoke() }

    /// Leaving the foreground ends this consent, including an ON still awaiting its ACK.
    func backgrounded() { revoke() }

    private func revoke() {
        let wasRequested = status.requested
        if wasRequested { stop() }
        if status.available { status = .off }
        if wasRequested, let peer { send(peer, RemoteAudioSubscription(enabled: false)) }
    }
}
