import Foundation
import os
import StreamProtocol

final class IPadAudioAdmission: @unchecked Sendable {
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
            if state.catalog != catalog { state.generation = UUID() }
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

    @discardableResult
    func withAdmission(_ ticket: Ticket?, _ body: () -> Void) -> Bool {
        lock.withLock { state in
            guard let ticket, state.peer == ticket.peer, state.generation == ticket.generation,
                  state.catalog?.protected == true else { return false }
            body()
            return true
        }
    }
}
