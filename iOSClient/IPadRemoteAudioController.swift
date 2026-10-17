import Foundation
import StreamProtocol

/// Owned by StreamClient on main. Consent belongs to one connection and one source.
final class IPadRemoteAudioController {
    enum Status: Equatable {
        case unavailable
        case off
        case requesting(UUID)
        case starting(UUID)
        case listening(UUID)
        case failed(String)

        var available: Bool { self != .unavailable }
        var requested: Bool {
            switch self {
            case .requesting, .starting, .listening: return true
            default: return false
            }
        }
    }

    enum PlaybackEvent {
        case preparing, ready, failed(String)
    }

    private(set) var status: Status = .unavailable {
        didSet { if status != oldValue { changed(status) } }
    }
    private var peer: ObjectIdentifier?
    private var source: StreamSource = .none
    private var inputGeneration: String?
    private let send: (ObjectIdentifier, RemoteAudioSubscription) -> Void
    private let stop: () -> Void
    private let play: (Data, UUID) -> Void
    private let changed: (Status) -> Void

    init(send: @escaping (ObjectIdentifier, RemoteAudioSubscription) -> Void,
         stop: @escaping () -> Void, play: @escaping (Data, UUID) -> Void,
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
        inputGeneration = nil
        status = .unavailable
    }

    func receive(_ list: WindowList, from origin: ObjectIdentifier) {
        guard peer == origin else { return }
        if source != list.active || inputGeneration != list.inputGeneration || list.remoteAudio != 1 { revoke() }
        source = list.active
        inputGeneration = list.inputGeneration
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
            if requested { status = .failed(answer.reason ?? "Mac 오디오가 중지되었습니다.") }
            return
        }
        let requestID: UUID
        switch status {
        case .requesting(let id), .starting(let id), .listening(let id): requestID = id
        default: return
        }
        guard answer.requestID == requestID else { return }
        if answer.enabled {
            if case .requesting = status { status = .starting(requestID) }
        }
        else {
            stop()
            status = .failed(answer.reason ?? "Mac 오디오를 사용할 수 없습니다.")
        }
    }

    func receiveAudio(_ packet: Data, from origin: ObjectIdentifier) {
        guard peer == origin else { return }
        switch status {
        case .starting(let id), .listening(let id): play(packet, id)
        default: return
        }
    }

    func playerChanged(_ event: PlaybackEvent, requestID: UUID, from origin: ObjectIdentifier) {
        guard peer == origin, status == .starting(requestID) || status == .listening(requestID) else { return }
        switch event {
        case .preparing: status = .starting(requestID)
        case .ready: status = .listening(requestID)
        case .failed(let reason):
            revoke()
            status = .failed(reason)
        }
    }

    func expire(_ requestID: UUID, from origin: ObjectIdentifier) {
        guard peer == origin, status == .requesting(requestID) else { return }
        revoke()
        status = .failed("Mac 오디오의 응답이 없습니다.")
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
