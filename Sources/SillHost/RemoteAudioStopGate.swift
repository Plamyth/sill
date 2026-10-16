import Foundation

/// Serializes capture starts after every stop that was scheduled while a start waited.
/// MainActor owns the ticket; the capture operation may suspend on another queue.
@MainActor
final class RemoteAudioStopGate {
    private struct Stop {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var current: Stop?
    private let onCleared: (() -> Void)?

    init(onCleared: (() -> Void)? = nil) { self.onCleared = onCleared }

    var isStopping: Bool { current != nil }

    func schedule(_ operation: @escaping @MainActor () async -> Void) {
        guard current == nil else { return }
        let stop = Stop(id: UUID(), task: Task { await operation() })
        current = stop
        Task { @MainActor in
            await stop.task.value
            clear(stop)
        }
    }

    private func clear(_ stop: Stop) {
        guard current?.id == stop.id else { return }
        current = nil
        onCleared?()
    }

    /// A start may proceed only after the latest stop settles and its request
    /// is still current. A stream of replacement stops cannot spin forever.
    func waitToStart(if allowed: @MainActor () -> Bool) async -> Bool {
        var completedStops = 0
        while let stop = current {
            guard allowed(), completedStops < 32 else { return false }
            await stop.task.value
            clear(stop)
            completedStops += 1
        }
        return allowed()
    }

    func waitUntilIdle() async {
        _ = await waitToStart(if: { true })
    }
}
