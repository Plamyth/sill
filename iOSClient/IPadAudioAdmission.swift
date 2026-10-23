import Foundation
import os
import StreamProtocol

final class IPadAudioAdmission: @unchecked Sendable {
    enum Direction { case microphone, playback }
    struct Ticket: Equatable {
        let peer: ObjectIdentifier
        let generation: UUID
    }

    private struct Catalog: Equatable {
        let source: StreamSource
        let inputGeneration: String?
        let videoEpoch: UUID?
        let microphone: MicrophoneCapability?
        let remoteAudio: Int?
        let protected: Bool

        init(_ list: WindowList) {
            source = list.active
            inputGeneration = list.inputGeneration
            videoEpoch = list.videoEpoch?.id
            microphone = list.microphone
            remoteAudio = list.remoteAudio
            protected = list.audioPrivacy?.version == 2 && list.audioPrivacy?.protected == true
        }
    }

    private struct State {
        var peer: ObjectIdentifier?
        var generation = UUID()
        var catalog: Catalog?
        var microphone = false
        var playback = false
        var deadline: TimeInterval?
        var lastTime: TimeInterval?
        var faulted = false

    }

    private let now: @Sendable () -> TimeInterval
    init(now: @escaping @Sendable () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }) {
        self.now = now
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func bind(_ peer: ObjectIdentifier?) {
        lock.withLock { state in
            guard state.peer != peer else { return }
            state = State(peer: peer)
        }
    }

    func observe(_ list: WindowList, from peer: ObjectIdentifier) -> Ticket? {
        lock.withLock { state in
            guard state.peer == peer else { return nil }
            let catalog = Catalog(list)
            if state.catalog != catalog {
                state.generation = UUID()
                state.microphone = false; state.playback = false; state.deadline = nil
            }
            state.catalog = catalog
            return Ticket(peer: peer, generation: state.generation)
        }
    }

    func ticket(for peer: ObjectIdentifier) -> Ticket? {
        lock.withLock { state in
            guard state.peer == peer, state.catalog?.protected == true else { return nil }
            return Ticket(peer: peer, generation: state.generation)
        }
    }

    func isCurrent(_ ticket: Ticket?) -> Bool {
        lock.withLock { state in
            guard let ticket else { return false }
            return state.peer == ticket.peer && state.generation == ticket.generation
        }
    }

    var forwardingFaulted: Bool { lock.withLock { $0.faulted } }

    func resetForwardingFault() {
        lock.withLock { state in
            state.faulted = false; state.lastTime = nil
            state.microphone = false; state.playback = false; state.deadline = nil
            state.generation = UUID()
        }
    }

    func forwarding(peer: ObjectIdentifier?, microphone: Bool, playback: Bool, deadline: TimeInterval?) {
        lock.withLock { state in
            guard state.peer == peer else { return }
            if state.microphone != microphone || state.playback != playback {
                state.generation = UUID()
            }
            state.microphone = microphone; state.playback = playback; state.deadline = deadline
        }
    }

    @discardableResult
    func withAdmission(_ ticket: Ticket?, direction: Direction = .playback, _ body: () -> Void) -> Bool {
        lock.withLock { state in
            guard let ticket, state.peer == ticket.peer, state.generation == ticket.generation,
                  state.catalog?.protected == true else { return false }
            guard !state.faulted, let deadline = state.deadline else { return false }
            let time = now()
            guard time.isFinite, time >= 0, state.lastTime.map({ time >= $0 }) ?? true,
                  time < deadline else {
                state.faulted = true
                state.microphone = false; state.playback = false; state.deadline = nil
                state.generation = UUID()
                return false
            }
            state.lastTime = time
            guard direction == .microphone ? state.microphone : state.playback else { return false }
            body()
            return true
        }
    }
}
