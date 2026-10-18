import Foundation
import CoreGraphics

@MainActor final class PhaseBarrier {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        entered = true
        let ready = observers
        observers.removeAll()
        for observer in ready { observer.resume() }
        await withCheckedContinuation { waiter = $0 }
    }
    func resume() { let w = waiter; waiter = nil; w?.resume() }
    func reached() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
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
    var startBarrier: PhaseBarrier?
    var stopBarrier: PhaseBarrier?
    func stop() async {
        if let stopBarrier { await stopBarrier.suspend() }
        running = false
    }
    var failStarts = Set<Int>()
    enum Failure: Error { case refused }
    func start() async throws {
        starts += 1
        if let startBarrier { await startBarrier.suspend() }
        if pauseNext || pauseStarts.contains(starts) {
            pauseNext = false
            await withCheckedContinuation { waiter = $0 }
        }
        if failStarts.contains(starts) { throw Failure.refused }
        running = true
    }
    func resume() { let w = waiter; waiter = nil; w?.resume() }
}
@MainActor final class Server {
    var committedEpoch: UUID?
    func resetForNewStream() { committedEpoch = nil }
    func isVideoCommitted(_ epoch: UUID) async -> Bool { committedEpoch == epoch }
}
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
    var sourcePublicationAdmission = SourcePublicationAdmission()
    var sourceAdmissionPeer: ObjectIdentifier?
    var pendingLaunch: String?
    func admissionIsCurrent(_ sequence: UInt64, peer: ObjectIdentifier?) -> Bool { !shuttingDown && sequence == pickSequence }
    var switching = false
    var shuttingDown = false
    var restartOf: StreamSource?
    // SOURCE_PICK
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
    var replayBarrier: PhaseBarrier?
    var deliveryBarriers: [Int: PhaseBarrier] = [:]
    var pickDeliveries = 0
    private var pickObserver: (Int, CheckedContinuation<Void, Never>)?
    func picksDelivered(_ count: Int) async {
        if pickDeliveries >= count { return }
        await withCheckedContinuation { pickObserver = (count, $0) }
    }
    func handlePick(_ source: StreamSource, intentSequence: UInt64? = nil, origin: PickOrigin? = nil, admissionPeer: ObjectIdentifier? = nil) async {
        pickDeliveries += 1
        if let barrier = deliveryBarriers[pickDeliveries] { await barrier.suspend() }
        if pickDeliveries == 2, let replayBarrier { await replayBarrier.suspend() }
        await productionHandlePick(source, intentSequence: intentSequence, origin: origin ?? (source == .desktop ? .automatic : .human), admissionPeer: admissionPeer)
        if let (count, observer) = pickObserver, pickDeliveries >= count {
            pickObserver = nil
            observer.resume()
        }
    }
    func broadcastList(admission: SourcePublicationAdmission? = nil) {}
    func sendMicrophoneCatalog(to connection: Int, admission: SourcePublicationAdmission? = nil) {}
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
        try await capture.start()
        // PIPELINE_VALIDATION
        active = source
        videoEpoch = UUID()
        server.committedEpoch = videoEpoch
        committed.append(source)
    }
    // OWNED_RECOVERY
    // HANDLE_PICK
    // SELECT_PREFIX
    // DISPLAYS_CHANGED
}
