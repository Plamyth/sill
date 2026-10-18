import Foundation

enum OriginPolicy { enum Origin { case vpn, internet, lan } }
enum QualityPreset {
    static func shortTitle(bitrate: Int, captureScale: Double) -> String { "fixture" }
}
// QUALITY_AWAY_POLICY

struct QualityRoute {
    var isAway: Bool
    var encrypted = false
    var fingerprint: Data? = nil
    var pairedName: String? = nil
    var label: String? = nil
    var cableDevice: String? = nil
}
enum HostStatusSnapshot {
    struct Device {
        let id: ObjectIdentifier
        let endpoint: String
        let name: String?
        let route: String?
        let remoteRoute: String?
    }
}
final class QualityStatus {
    struct Snapshot {
        var devices: [HostStatusSnapshot.Device] = []
        var away = false
        var virtualDisplayOn = true
        var lastStageFailure: String?
    }
    var value = Snapshot()
    func update(_ body: (inout Snapshot) -> Void) { body(&value) }
}
final class QualityServer {
    var onClientConnected: ((NWConnection, QualityRoute, String?) -> Void)?
    var resets = 0
    func resetForNewStream() { resets += 1 }
    func setPeerToPeer(_ enabled: Bool) {}
}
final class QualityCapture {
    var stops = 0
    var onFrame: (() -> Void)?
    func stop() async { stops += 1 }
}
final class QualityEncoder { func requestKeyframe() {} }
final class QualityRemote {
    func isPaired(_ fingerprint: Data) -> Bool { false }
    func sessionStarted(fingerprint: Data, route: String, cableDevice: String?) {}
    func apply(_ config: HostConfig) {}
}
final class QualityIngress {
    func authorize(_ connection: NWConnection, fingerprint: Data) {}
}
final class QualityInputFence {
    func join(_ id: ObjectIdentifier, source: StreamSource, switching: Bool, desktopScope: Int) -> Bool { true }
}

@MainActor final class QualityCoordinatorFixture {
    let server = QualityServer()
    let status = QualityStatus()
    let inputFence = QualityInputFence()
    let microphoneIngress = QualityIngress()
    let remote: QualityRemote? = nil
    let synthetic = true
    let desktopScope = 0
    var encoder: QualityEncoder? = nil
    let capture = QualityCapture(), syntheticCapture = QualityCapture()
    var videoEpoch: Int?
    var rectCache: Int?
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var routes: [ObjectIdentifier: QualityRoute] = [:]
    var config = HostConfig.standard
    var pendingConfig: HostConfig?
    var target: HostConfig { pendingConfig ?? config }
    var awayWanted = true
    var awayRunning = true
    var flipWait: ObjectIdentifier?
    var flipWaitToken = 0
    var switching = false
    var shuttingDown = false
    var active = StreamSource.window(42)
    var viewport: Viewport?
    var clientFPS: [ObjectIdentifier: Int] = [:]
    var fps = 60
    var useSoftwareEncoder = false
    var effectiveFPS: Int { min(config.maxFPS, max(24, clientFPS.values.max() ?? 60)) }
    var captureScale: CGFloat { config.effective(away: awayRunning).captureScale }
    var bitrate: Int { config.effective(away: awayRunning).bitrate }
    var virtualDisplay: Bool { config.virtualDisplay }
    var viewportArrivedWhileSwitching = false
    let stage = VirtualStage()
    let catalog = WindowCatalog()
    let extendedDesktop: ExtendedDesktop
    var extendedDesktopViewports: [ObjectIdentifier: ExtendedDesktop.Dimensions] = [:]
    var received: [(Viewport, NWConnection)] = []
    var audioRevocations = 0
    var pipelines: [(away: Bool, fps: Int, scale: CGFloat, bitrate: Int)] = []
    init() {
        config.virtualDisplay = true
        extendedDesktop = ExtendedDesktop(makeDisplay: { _, _ in
            .init(id: 100, waitUntilOnline: { true }, configure: {}, isValid: { true }, recoverWindows: {}, destroy: {})
        }, publishID: { _ in }, reportFailure: { preconditionFailure($0) })
        // QUALITY_REGISTRATION
    }
    static func homeRouteWords(_ route: QualityRoute, link: String?) -> String { "home" }
    func sendCatalog(to connection: NWConnection) { connections[ObjectIdentifier(connection)] = connection }
    func enableVirtualDisplay() {}
    func revokeRemoteAudio(reason: String) async { audioRevocations += 1 }
    static func liveBounds(of id: UInt32) -> CGRect? { nil }
    func fitToViewport(_ window: SCWindow) -> CGSize? { nil }
    // QUALITY_METHODS
    // HOST_VIEWPORT
    func handleViewport(_ message: StreamMessage, from connection: NWConnection) async {
        // HOST_VIEWPORT_CASE
    }
    func drain() async {
        let queued = received
        received = []
        for (v, c) in queued {
            await handleViewport(StreamMessage(kind: .viewport, timestamp: 0, isKeyframe: false, payload: Wire.encode(v)), from: c)
        }
    }
    func select(_ source: StreamSource) async {
        guard !switching, !shuttingDown else { return }
        switching = true
        defer { switching = false }
        // QUALITY_SELECT_EFFECTS
        // QUALITY_SELECT_COMMIT
        active = source
        stage.askedSize = wantedStage(for: catalog.item).size
        pipelines.append((awayRunning, fps, captureScale, bitrate))
    }
}

extension Checks {
    @MainActor static func qualityTransitionChecks() async {
        for native in [true, false] {
            for limit in [120, 60] {
                let screen = ScreenFixture(), client = screen.client
                screen.textScale = 1.5
                client.awayCapsFrameRate = true
                client.session?.route = .remote
                if native {
                    await screen.sendAndWait()
                } else {
                    client.sendViewport(Viewport(width: 1350, height: 890, scale: 1.5, fps: 60))
                }
                let old = client.connection!, next = client.makeConnection()
                let host = QualityCoordinatorFixture()
                host.config.maxFPS = limit
                host.routes[ObjectIdentifier(old)] = QualityRoute(isAway: true)
                host.connections[ObjectIdentifier(old)] = old
                host.clientFPS[ObjectIdentifier(old)] = 60
                host.viewport = client.lastViewport
                host.server.onClientConnected?(next, QualityRoute(isAway: false), "wired")
                for _ in 0..<60 { await Task.yield() }
                check(host.connections[ObjectIdentifier(next)] === next && host.flipWait == ObjectIdentifier(next),
                      "production registration admits home and waits for its first viewport")
                next.onViewport = { host.received.append(($0, next)) }
                client.snapshotHomeViewport()
                client.sendHomePreflight(next)
                await host.drain()
                client.completeReplacement(next, kind: .fromRemote)
                client.send(.input, payload: Data([1]))
                try? await Task.sleep(for: .milliseconds(1200))
                print("QUALITY_EFFECTS before fence release native=\(native) limit=\(limit) pipelines=\(host.pipelines.map { $0.fps }) resets=\(host.server.resets) audio=\(host.audioRevocations)")
                let beforeRelease = host.pipelines.count
                _ = client.link.release(old)
                await host.drain()
                print("QUALITY_EFFECTS after fence release pipelines=\(host.pipelines.map { $0.fps })")
                check(host.pipelines.count == 1 && beforeRelease == 1 && host.pipelines[0].away == false && host.pipelines[0].fps == limit
                      && host.pipelines[0].scale == 2 && host.pipelines[0].bitrate == 15_000_000,
                      "early actual home viewport commits quality and \(limit) fps once across a slow fence")
                check(host.audioRevocations == 1 && host.capture.stops == 1 && host.syntheticCapture.stops == 1 && host.server.resets == 1,
                      "original home transition revokes audio and stops capture exactly once")
                check(host.viewport?.height == 890 && host.viewport?.scale == 1.5
                      && host.viewport?.extendedDesktop?.height == (native ? 976 : nil),
                      "ordinary home snapshot retains actual panel and optional native allocation")
                check(host.stage.askedSize == CGSize(width: 900, height: 593),
                      "early home snapshot never stages an oversized native frame")
                check(next.messages.map { $0.first! } == [23, 9, 9, 8],
                      "original hello, early ordinary viewport, fenced replay and input order")
                if let replay = client.lastViewport { client.sendViewport(replay) }
                await host.drain()
                check(host.pipelines.count == 1 && host.audioRevocations == 1, "identical home replay has no second restart")
                host.extendedDesktop.shutdown()
            }
        }
        let idle = QualityCoordinatorFixture(), connection = NWConnection()
        idle.active = .none
        idle.server.onClientConnected?(connection, QualityRoute(isAway: false), nil)
        for _ in 0..<60 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(1200))
        check(!idle.awayRunning && idle.flipWait == nil && idle.capture.stops == 0 && idle.audioRevocations == 0,
              "production timeout still adopts idle quality without viewport or capture restart")
        idle.extendedDesktop.shutdown()
    }
}
