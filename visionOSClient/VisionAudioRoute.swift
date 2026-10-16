import Foundation
import Network
import StreamProtocol
import os

final class VisionAudioRoute {
    private struct Route {
        var peer: NWConnection?
        var identity = UUID()
        var source = StreamSource.none
        var generation: UInt64 = 0
        var supported = false

        var scope: VisionAudioScope { VisionAudioScope(connection: identity, source: generation) }
    }

    private let storage = OSAllocatedUnfairLock(initialState: Route())

    func clear() {
        storage.withLock { route in route = Route() }
    }

    func observe(_ peer: NWConnection, source: StreamSource, supported: Bool) -> VisionAudioState.Availability {
        storage.withLock { route in
            if route.peer !== peer {
                route = Route()
                route.peer = peer
            }
            if route.source != source {
                route.generation &+= 1
                route.source = source
            }
            route.supported = supported
            guard supported else { return .unsupported }
            guard source != .none else { return .noSource }
            return .available(route.scope)
        }
    }

    func scope(for peer: NWConnection) -> VisionAudioScope? {
        storage.withLock { route in
            guard route.peer === peer, route.supported, route.source != .none else { return nil }
            return route.scope
        }
    }

    func peer(for control: VisionAudioControl) -> NWConnection? {
        storage.withLock { route in
            guard route.identity == control.grant.scope.connection else { return nil }
            if control.enabled {
                guard route.supported, route.source != .none, route.scope == control.grant.scope else { return nil }
            }
            return route.peer
        }
    }
}
