import Foundation
import CoreGraphics

@MainActor final class Catalog {
    var displayInventory = DisplayInventory()
    var clientCount = 1
    var display: UInt32? { displayInventory.current?.displayID }
    var bounds = CGRect(x: 3432, y: 0, width: 1350, height: 976)
    func refreshWindows() async -> Bool { true }
    func selectDisplay(_ selection: DisplaySelection) -> Bool { displayInventory.select(selection) }
}
@MainActor final class Capture {
    var onFrame: Int?
    var running = true
    var pauseNext = false
    var waiter: CheckedContinuation<Void, Never>?
    var starts = 0
    func stop() async { running = false }
    func start() async {
        starts += 1
        if pauseNext {
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
    func broadcastList() {}
    func sendMicrophoneCatalog(to connection: Int) {}
    func judgeLinks(_ value: Int?) {}
    func applyViewportToActiveWindow() async {}
    func applyPending() async {}
    func revokeRemoteAudio(reason: String) async { audioLive = false }
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
