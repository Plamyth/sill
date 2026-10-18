import Foundation
import CoreGraphics

@MainActor final class PhaseBarrier {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func resume() { let w = waiter; waiter = nil; w?.resume() }
    func reached() async {
        for _ in 0..<100_000 {
            if entered { return }
            await Task.yield()
        }
        fatalError("phase barrier was not reached")
    }
}
@MainActor final class Catalog {
    var displayInventory = DisplayInventory()
    var clientCount = 1
    var display: UInt32? { displayInventory.current?.displayID }
    var bounds = CGRect(x: 3432, y: 0, width: 1350, height: 976)
    var refreshBarrier: PhaseBarrier?
    var refreshResult = true
    func refreshWindows() async -> Bool {
        if let refreshBarrier { await refreshBarrier.suspend() }
        return refreshResult
    }
    func selectDisplay(_ selection: DisplaySelection) -> Bool { displayInventory.select(selection) }
}
@MainActor final class Capture {
    var onFrame: Int?
    var running = true
    var pauseNext = false
    var pauseStarts = Set<Int>()
    var waiter: CheckedContinuation<Void, Never>?
    var starts = 0
    var stopBarrier: PhaseBarrier?
    func stop() async {
        if let stopBarrier { await stopBarrier.suspend() }
        running = false
    }
    func start() async {
        starts += 1
        if pauseNext || pauseStarts.contains(starts) {
            pauseNext = false
            await withCheckedContinuation { waiter = $0 }
        }
        running = true
    }
    func resume() { let w = waiter; waiter = nil; w?.resume() }
}
@MainActor final class Server { func resetForNewStream() {} }
@MainActor final class Pointer { func setGeometry(_ geometry: Int?, fps: Int) {} }
@MainActor final class Extended { func checkDisplay() {} }
@MainActor final class Injector { func releaseInput(of device: Int) {} }
@MainActor final class RecoveryCoordinator {
    let catalog = Catalog()
    let capture = Capture()
    let syntheticCapture = Capture()
    let server = Server()
    let pointer = Pointer()
    let extendedDesktop = Extended()
    let injector = Injector()
    var connections: [Int: Int] = [:]
    var inputFence = SourceInputFence<Int>()
    var active = StreamSource.desktop {
        didSet { inputFence.sourceChanged(to: active, desktopScope: desktopScope) }
    }
    var desktopScope: String? { DisplayInventory.scope(catalog.displayInventory.current) }
    var videoEpoch: UUID? = UUID()
    var inputGeneration = "old"
    var synthetic = false
    var switching = false
    var shuttingDown = false
    var restartOf: StreamSource?
    var pickArrivedWhileSwitching: StreamSource?
    var deselectWhenSettled = false
    var viewportArrivedWhileSwitching = false
    var pendingConfig: Int?
    var awayWanted = false
    var awayRunning = false
    var flipWait: Int?
    var fps = 60
    var audioLive = true
    var committed = [StreamSource]()
    var audioBarrier: PhaseBarrier?
    var pickDeliveries = 0
    func handlePick(_ source: StreamSource) async {
        pickDeliveries += 1
        await productionHandlePick(source)
    }
    func broadcastList() {}
    func sendMicrophoneCatalog(to connection: Int) {}
    func judgeLinks(_ value: Int?) {}
    func applyViewportToActiveWindow() async {}
    func applyPending() async {}
    func revokeRemoteAudio(reason: String) async {
        if let audioBarrier { await audioBarrier.suspend() }
        audioLive = false
    }
    func currentSourceRect(source: StreamSource, fresh: Bool) -> CGRect? { catalog.bounds }
    enum PipelineEpochError: Error { case missingGeometry }
    func startPipeline(source: StreamSource) async throws {
        let desktopSelection = source == .desktop ? catalog.displayInventory.current : nil
        let bounds = catalog.bounds
        await capture.start()
        // PIPELINE_VALIDATION
        active = source
        videoEpoch = UUID()
        committed.append(source)
    }
    // OWNED_RECOVERY
    // HANDLE_PICK
    // SELECT_PREFIX
    // DISPLAYS_CHANGED
}
