import Foundation
import Network
import StreamProtocol

struct VisionMacAudioScope: Equatable {
    let connection: UUID
    let window: UUID
    let admission: UUID
}

/// The shared transport owns submissions. This binding adds the native window lifetime.
final class VisionMacAudioTransport {
    private let lock = NSLock()
    private let shared: MacAudioRouteTransport
    private var binding: (scope: VisionMacAudioScope, peer: NWConnection)?

    init(link: SessionLink) { shared = MacAudioRouteTransport(link: link) }

    func bind(_ scope: VisionMacAudioScope?, peer: NWConnection?) {
        lock.lock(); defer { lock.unlock() }
        if binding?.scope == scope, binding?.peer === peer { return }
        shared.reset()
        binding = scope.flatMap { scope in peer.map { (scope, $0) } }
    }

    func scope(for peer: NWConnection) -> VisionMacAudioScope? {
        lock.lock(); defer { lock.unlock() }
        guard binding?.peer === peer else { return nil }
        return binding?.scope
    }

    func peer(for scope: VisionMacAudioScope) -> NWConnection? {
        lock.lock(); defer { lock.unlock() }
        guard binding?.scope == scope else { return nil }
        return binding?.peer
    }

    func fetch(in scope: VisionMacAudioScope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let binding, binding.scope == scope else { return false }
        return shared.fetch(on: binding.peer)
    }

    func change(_ request: AudioRouteSelection, in scope: VisionMacAudioScope,
                cancelled: @escaping (UUID) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let binding, binding.scope == scope else { return false }
        return shared.change(request, on: binding.peer, cancelled: cancelled)
    }

    func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        shared.finish(id)
    }
}
