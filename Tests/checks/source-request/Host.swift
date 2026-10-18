import Foundation
import CoreGraphics

struct Display { var displayID: UInt32; var width = 640; var height = 480 }
typealias VirtualStage = Stage
struct SCContentFilter {
    init(desktopIndependentWindow: SCWindow) {}
    init(display: Display, excludingApplications: [App], exceptingWindows: [SCWindow]) {}
    init(display: Display, excludingWindows: [SCWindow]) {}
}
struct App { var applicationName: String? = "fixture" }
struct SCWindow {
    var windowID: UInt32
    var frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    var owningApplication: App? = App()
    var title: String? = "window"
    var isOnScreen = true
    var isActive = true
}
@MainActor final class Barrier {
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    func suspend() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func resume() { let w = waiter; waiter = nil; w?.resume() }
    func reached() async { while !entered { await Task.yield() } }
}
@MainActor final class Capture {
    var onFrame: ((Int, Int) -> Void)?
    var startBarrier: Barrier?
    var stopBarrier: Barrier?
    var running = false
    var fail = false
    var failNextStart = false
    func stop() async { if let stopBarrier { await stopBarrier.suspend() }; running = false }
    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, showsCursor: Bool, sourceRect: CGRect?) async throws {
        if let startBarrier { await startBarrier.suspend() }
        if fail || failNextStart { failNextStart = false; throw AdmissionHost.PipelineEpochError.missingGeometry }
        running = true
    }
    func start(width: Int, height: Int, fps: Int) { running = true }
}
final class HEVCEncoder {
    struct PS { func encoded() -> Data { Data() } }
    var onHung: (() -> Void)?
    var onEncoded: ((Data, Bool, PS?) -> Void)?
    var isDead = false
    init(width: Int, height: Int, fps: Int, bitrate: Int, prioritizeSpeed: Bool, software: Bool) throws {}
    func encode(_ value: Int, pts: Int) {}
    func requestKeyframe() {}
}
@MainActor final class Catalog {
    var clientCount = 1
    var displayInventory = DisplayInventory()
    var display: Display? { displayInventory.current.map { Display(displayID: $0.displayID) } }
    var refreshBarrier: Barrier?
    var refreshResult = true
    var ownApplication: App? = App()
    func refreshWindows() async -> Bool { if let refreshBarrier { await refreshBarrier.suspend() }; return refreshResult }
    func selectDisplay(_ selection: DisplaySelection) -> Bool { displayInventory.select(selection) }
    func window(id: UInt32) -> SCWindow? { id == 999 ? nil : SCWindow(windowID: id) }
    func resolveWindow(id: UInt32) async -> SCWindow? { window(id: id) }
    func resolveOwnApplication() async -> App? { ownApplication }
}
@MainActor final class Stage {
    struct Placement { let windowID: UInt32 }
    struct Prepared { var filter = SCContentFilter(desktopIndependentWindow: SCWindow(windowID: 1)); var sourceRect = CGRect(x:0,y:0,width:640,height:480); var outputSize: CGSize?; var describe = "stage" }
    enum Failure: Error { case refused; var summary: String { "refused" } }
    var placement: Placement?
    var isStaged: Bool { placement != nil }
    var disabledReason: String?
    var prepareBarrier: Barrier?
    var fail = false
    func leaveFullScreenIfNeeded() async {}
    func release() { placement = nil }
    func releaseWindow() { placement = nil }
    func prepare(window: SCWindow, wanted: CGSize, envelope: CGSize, captureScale: CGFloat, refreshHz: Int) async throws -> Prepared {
        placement = Placement(windowID: window.windowID)
        if let prepareBarrier { await prepareBarrier.suspend() }
        if fail { throw Failure.refused }
        return Prepared()
    }
}
struct HostStatusSnapshot {
    struct Stream {
        enum Kind { case window, desktop, testPattern }
        init(kind: Kind, title: String, width: Int, height: Int, fps: Int, mbps: Int, onVirtualDisplay: Bool, softwareEncoder: Bool) {}
    }
    var stream: Stream?
    var lastStageFailure: String?
    var virtualDisplayProblem: String?
}
@MainActor final class Status {
    var value = HostStatusSnapshot()
    func update(_ action: (inout HostStatusSnapshot) -> Void) { action(&value) }
}
@MainActor final class Server {
    var committed: [StreamSource] = []
    var prepared = 0
    func prepareVideo(_ epoch: VideoEpoch) { prepared += 1 }
    func resetForNewStream() {}
    func broadcast(_ message: StreamMessage, epoch: UUID) {}
    func commitVideo(_ epoch: VideoEpoch, catalog: StreamMessage, admission: SourcePublicationAdmission, keyframe: () -> Void) {
        admission.publish { committed.append(epoch.source) }
    }
}
@MainActor final class Injector {
    func releaseInput(of device: ObjectIdentifier) {}
    func isUpOfSomethingDown(_ event: Int, from device: ObjectIdentifier) -> Bool { false }
    func apply(_ event: Int, in rect: CGRect, from device: ObjectIdentifier) {}
    func chord(keyCode: UInt16, flags: UInt64) {}
}
@MainActor final class Chords { var forgotten = 0; func forget() { forgotten += 1 } }
@MainActor final class Stats { static let shared = Stats(); func bump(_ name: String) {} }
@MainActor final class NSWorkspace {
    final class OpenConfiguration { var activates = true }
    static let shared = NSWorkspace()
    var opened: [URL] = []
    func urlForApplication(withBundleIdentifier id: String) -> URL? { id == "missing" ? nil : URL(fileURLWithPath: "/" + id) }
    func openApplication(at url: URL, configuration: OpenConfiguration, completion: @escaping (Int?, Error?) -> Void) { opened.append(url) }
}
@MainActor final class AdmissionHost {
    // HOST_TYPES
    let catalog = Catalog()
    let capture = Capture()
    let syntheticCapture = Capture()
    let server = Server()
    let stage = Stage()
    let injector = Injector()
    let status = Status()
    let gestureChords = Chords()
    var active = StreamSource.none
    var inputFence = SourceInputFence<ObjectIdentifier>()
    var connections: [ObjectIdentifier: NSObject] = [:]
    var launchID = "host"
    var selectionRevision: String { "\(launchID):\(pickSequence)" }
    var pickSequence: UInt64 = 0
    var sourcePublicationAdmission = SourcePublicationAdmission()
    var settledPickSequence: UInt64 = 0
    var pickArrivedWhileSwitching: SourcePick?
    var sourceAdmissionPeer: ObjectIdentifier?
    var pendingLaunch: PendingLaunch?
    var ownedDesktopRecovery = OwnedDesktopRecovery.idle
    var switching = false
    var restartOf: StreamSource?
    var shuttingDown = false
    var synthetic = false
    var virtualDisplay = false
    var config = Config()
    struct Config { var virtualDisplay = false }
    var pendingConfig: Config?
    var awayWanted = false
    var awayRunning = false
    var flipWait: Int?
    var deselectWhenSettled = false
    var viewportArrivedWhileSwitching = false
    var inputGeneration = "input"
    var desktopScope: String? { DisplayInventory.scope(catalog.displayInventory.current) }
    var videoEpoch: VideoEpoch?
    var rectCache: Int?
    var encoder: HEVCEncoder?
    var fps = 60
    var effectiveFPS = 60
    var bitrate = 1000000
    var streamBitrate = 1000000
    var prioritizeSpeed = false
    var useSoftwareEncoder = false
    var captureScale: CGFloat = 1
    var remote: Int?
    var audioBarrier: Barrier?
    var audioChanges = 0
    var raised: [UInt32] = []
    enum Held { case input(Int, CGRect, ObjectIdentifier, VideoEpoch?), chord(UInt16, UInt64), disconnect(ObjectIdentifier) }
    var heldInput: [Held] = []
    var holdUntil: Double = 0
    init() {
        catalog.displayInventory.update([DisplayInfo(id: 13, name: "main", width: 640, height: 480, isMain: true)], signatures: ["main"], frames: [CGRect(x:0,y:0,width:640,height:480)])
    }
    func join(_ peer: NSObject) {
        connections[ObjectIdentifier(peer)] = peer
        _ = inputFence.join(ObjectIdentifier(peer), source: active, switching: false, desktopScope: desktopScope)
        inputFence.negotiate(ObjectIdentifier(peer), supportsScoped: true)
    }
    func receive(_ request: SourceRequest, peer: NSObject) {
        _ = admitSourceMessage(StreamMessage(kind: .selectSource, timestamp: 0, isKeyframe: false, payload: Wire.encode(request)), from: peer)
    }
    func launch(_ id: String, peer: NSObject) {
        _ = admitSourceMessage(StreamMessage(kind: .launchApp, timestamp: 0, isKeyframe: false, payload: Wire.encode(LaunchApp(bundleID: id))), from: peer)
    }
    func completeLaunch(_ infos: [WindowInfo]) async { // LAUNCH_COMPLETION
    }
    func currentSourceRect(source: StreamSource, fresh: Bool) -> CGRect? { CGRect(x:0,y:0,width:640,height:480) }
    static func liveBounds(of id: UInt32) -> CGRect? { CGRect(x:0,y:0,width:640,height:480) }
    static func epochGeometry(_ rect: CGRect) -> VideoEpoch.Geometry { .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
    static func menuTitle(for window: SCWindow) -> String { "window" }
    func evenPixels(_ value: CGFloat) -> Int { Int(value) / 2 * 2 }
    func fitToViewport(_ window: SCWindow) -> CGSize? { nil }
    func wantedStage(for window: SCWindow) -> (size: CGSize, envelope: CGSize) { (window.frame.size, window.frame.size) }
    func activateAndRaise(window: SCWindow) { raised.append(window.windowID) }
    func adopt(_ config: Config, away: Bool) { self.config = config }
    struct Quality { init(bitrate: Int, fps: Int, captureScale: Double) {} }
    enum LinkJudge { typealias Quality = AdmissionHost.Quality }
    func judgeLinks(_ quality: Quality?) {}
    func broadcastList() {}
    func listMessage() -> StreamMessage { .init(kind: .windowList, timestamp: 0, isKeyframe: false, payload: Data()) }
    func sendMicrophoneCatalog(to peer: NSObject) {}
    func recoverOwnedDesktop() async {}
    func applyViewportToActiveWindow() async {}
    func applyPending() async {}
    func encoderHung(_ encoder: HEVCEncoder) async {}
    func revokeRemoteAudio(reason: String) async { if let audioBarrier { await audioBarrier.suspend() }; audioChanges += 1 }
    // HOST_METHODS
}
