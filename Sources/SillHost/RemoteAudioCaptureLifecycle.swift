import Foundation

/// Owns pending capture starts and stops. A waiter may settle only the start
/// record it acquired, because another start can replace it during an await.
@MainActor
final class RemoteAudioCaptureLifecycle {
    struct Start {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private struct Stop {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var currentStart: Start?
    private var current: Stop?
    private let onCleared: (() -> Void)?

    init(onCleared: (() -> Void)? = nil) { self.onCleared = onCleared }

    var isIdle: Bool { current == nil && currentStart == nil }

    var isStopping: Bool { current != nil }

    func acquireStart(_ operation: @escaping @MainActor () async -> Bool) -> Start {
        if let currentStart { return currentStart }
        let start = Start(id: UUID(), task: Task { await operation() })
        currentStart = start
        return start
    }

    func settleStart(_ start: Start) async -> Bool {
        let started = await start.task.value
        if currentStart?.id == start.id { currentStart = nil }
        return started
    }

    func scheduleStop(_ operation: @escaping @MainActor () async -> Void) {
        guard current == nil else { return }
        let pendingStart = currentStart
        let stop = Stop(id: UUID(), task: Task {
            if let pendingStart {
                _ = await pendingStart.task.value
                if self.currentStart?.id == pendingStart.id { self.currentStart = nil }
            }
            await operation()
        })
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
