import Foundation

final class NWConnection {
    let endpoint = "fixture"
    enum State { case ready }
    var state: State = .ready
    enum SendCompletion { case contentProcessed((Error?) -> Void) }
    var messages: [Data] = []
    var onViewport: (Viewport) -> Void = { _ in }
    func send(content: Data?, completion: SendCompletion) {
        guard let content else { return }
        messages.append(content)
        if content.first == StreamMessageKind.viewport.rawValue {
            onViewport(Wire.decode(Viewport.self, from: content.dropFirst())!)
        }
    }
    func cancel() {}
    func forceCancel() {}
    var viewports: [Viewport] { messages.compactMap {
        $0.first == StreamMessageKind.viewport.rawValue ? Wire.decode(Viewport.self, from: $0.dropFirst()) : nil
    } }
}

enum StreamMessageKind: UInt8 { case input = 8, viewport = 9, ping = 10, hello = 23 }
struct StreamMessage {
    let kind: StreamMessageKind
    let timestamp: Double
    let isKeyframe: Bool
    let payload: Data
    func serialized() -> Data { Data([kind.rawValue]) + payload }
}
// WIRE

@MainActor
final class CoordinatorFixture {
    var shuttingDown = false
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var extendedDesktopViewports: [ObjectIdentifier: ExtendedDesktop.Dimensions] = [:]
    let extendedDesktop: ExtendedDesktop
    init(_ desktop: ExtendedDesktop) { extendedDesktop = desktop }
    // HOST_VIEWPORT
    var viewport: Viewport?
    var clientFPS: [ObjectIdentifier: Int] = [:]
    var fps = 120
    var effectiveFPS: Int { clientFPS.values.max() ?? 120 }
    var flipWait: ObjectIdentifier?
    var switching = false
    var viewportArrivedWhileSwitching = false
    var virtualDisplay = true
    var active = StreamSource.window(42)
    let stage = VirtualStage()
    let catalog = WindowCatalog()
    var selections: [StreamSource] = []
    var audioRevocations = 0
    var pendingApplies = 0
    var received: [(Viewport, NWConnection)] = []
    static func liveBounds(of id: UInt32) -> CGRect? { nil }
    func fitToViewport(_ window: SCWindow) -> CGSize? { nil }
    func applyPending() async { pendingApplies += 1 }
    func select(_ source: StreamSource) async {
        selections.append(source)
        audioRevocations += 1
        active = source
        fps = effectiveFPS
        stage.askedSize = wantedStage(for: catalog.item).size
    }
    func drain() async {
        let queued = received
        received = []
        for (v, c) in queued {
            await handleViewport(StreamMessage(kind: .viewport, timestamp: 0, isKeyframe: false,
                                                payload: Wire.encode(v)), from: c)
        }
    }
    func handleViewport(_ message: StreamMessage, from connection: NWConnection) async {
        // HOST_VIEWPORT_CASE
    }
    // HOST_APPLY_VIEWPORT
    // HOST_WANTED_STAGE
}

@MainActor
final class StreamClient {
    var connected = true
    var awayCapsFrameRate = false
    var lastViewport: Viewport?
    var sent: [Viewport] = []
    var deliver: (Viewport) -> Void = { _ in }
    static func wantedFPS(remote: Bool) -> Int { remote ? 60 : 120 }
    final class CursorState { var wanted: Bool?; var pending: DispatchWorkItem? }
    let localCursorState = CursorState()
    let link = SessionLink()
    struct AudioControl { func setConnection(_ id: ObjectIdentifier) {} }
    let remoteAudioControl = AudioControl()
    var connection: NWConnection? { get { link.connection } set { link.connection = newValue } }
    var connectedDirectly = false
    var sessionListed = true
    var goodbye: Int?
    var sessionDead = false
    var homeMoveViewport: Viewport?
    enum MoveKind { case fromDirect, toCable, toWifi, fromRemote }
    struct Move { let connection: NWConnection; let kind: MoveKind }
    struct Session {
        enum Route { case network, remote; var isRemote: Bool { self == .remote } }
        var route = Route.network
    }
    var session: Session? = Session()
    var moving: Move?
    var resumeSource: StreamSource?
    var active = StreamSource.none
    var route = DiscoveryPolicy.Method.wired
    var wired: String? = "en7"
    func pathInput(now: Double) -> DiscoveryPolicy.PathInput {
        .init(now: now, route: route, lastPong: now, wired: wired, wiredSince: now - 10,
              wifi: "en0", lastUp: nil, lastDown: nil)
    }
    func reconnectNow(_ method: DiscoveryPolicy.Method, _ interface: String, now: Double) -> Bool {
        guard let connection else { return false }
        holdSends(connection)
        moving = Move(connection: makeConnection(), kind: method == .wired ? .toCable : .toWifi)
        return true
    }
    func makeConnection() -> NWConnection {
        let c = NWConnection()
        c.send(content: Data([StreamMessageKind.hello.rawValue]), completion: .contentProcessed { _ in })
        c.onViewport = { [unowned self] v in self.sent.append(v); self.deliver(v) }
        return c
    }
    init() { connection = makeConnection() }
    func send(_ kind: StreamMessageKind, payload: Data) {
        link.send(StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: payload).serialized())
    }
    func closeSoon(_ connections: [NWConnection]) {}
    // CURSOR_DEBOUNCE
    // VIEWPORT_CLIENT
    // RESCUE
    // HOLD
    func completeReplacement(_ c: NWConnection, kind: MoveKind) {
        guard let old = connection else { return }
        // HANDOVER
        // RESEND_PANEL
        sessionDead = false
    }
    func sendHomePreflight(_ c: NWConnection) {
        // HOME_PREFLIGHT
    }
    func snapshotHomeViewport() {
        // HOME_SNAPSHOT
    }
}

@MainActor
final class ScreenFixture {
    let client = StreamClient()
    var panelSize = CGSize(width: 1350, height: 890)
    var availableSize = CGSize(width: 1366, height: 992)
    var toolbarEnabled = true
    var textScale: Double? = nil
    var pendingViewport: Task<Void, Never>?
    // CLIENT_VIEWPORT
    func sendAndWait(after delay: Double = 0) async {
        sendViewport(after: delay)
        await pendingViewport?.value
    }
}

// SIZING
// VIDEO_RECT
// INPUT_MAPPING

@main
struct Checks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL \(message)"); exit(1) }
        count += 1
        print("PASS \(message)")
    }
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

    @MainActor static func main() async {
        // QUALITY_ONLY
        // STAGED_ONLY
        await qualityTransitionChecks()
        wireChecks()
        await stagedWindowChecks()
        let nativeSize = Viewport.ExtendedDesktopSize(width: 1350, height: 976)!
        let screen = ScreenFixture()
        var creates = 0, destroys = 0
        let desktop = ExtendedDesktop(makeDisplay: { dimensions, _ in
            creates += 1
            check(dimensions.widthPt == 1350 && dimensions.heightPt == 976, "first allocation is 1350x976")
            return .init(id: 100, waitUntilOnline: { true }, configure: {}, isValid: { true },
                         recoverWindows: {}, destroy: { destroys += 1 })
        }, publishID: { _ in }, reportFailure: { preconditionFailure($0) })
        let host = CoordinatorFixture(desktop), connection = NWConnection()
        let id = ObjectIdentifier(connection)
        host.connections[id] = connection
        desktop.request(id)
        screen.client.deliver = { host.updateExtendedDesktopViewport($0, from: connection) }

        screen.availableSize = .zero
        await screen.sendAndWait()
        check(screen.client.sent.isEmpty && creates == 0, "initial send waits for unoccluded geometry")
        screen.availableSize = CGSize(width: 1366, height: 992)
        screen.textScale = 1.5
        await screen.sendAndWait()
        for _ in 0..<60 { await Task.yield() }
        check(desktop.phase == .ready && creates == 1, "one virtual display becomes ready")
        check(screen.client.sent.count == 1 && screen.client.sent[0].scale == 1.5,
              "one actual panel viewport carries allocation without changing Aa")
        check(screen.client.lastViewport == Viewport(width: 1350, height: 890, scale: 1.5, fps: 120, extendedDesktop: nativeSize),
              "actual panel remains the viewport used for Aa and cursor resends")

        let physical = DisplayInfo(id: 1, name: "physical", width: 1512, height: 982, isMain: true)
        let virtual = DisplayInfo(id: 100, name: "CCR", width: 2700, height: 1952, isMain: false)
        for selectedID: UInt32 in [1, 100] {
            var inventory = DisplayInventory()
            inventory.update([physical, virtual], signatures: ["physical", "CCR/1350x976"])
            let selection = DisplaySelection(displayID: selectedID, inventoryID: inventory.revision!)
            check(inventory.select(selection), "select display \(selectedID)")
            screen.panelSize.height = 976
            await screen.sendAndWait()
            inventory.update([physical, virtual], signatures: ["physical", "CCR/1350x976"])
            check(inventory.current == selection && inventory.contains(selection),
                  "unchanged topology preserves selection \(selectedID)")
        }
        screen.panelSize.height = 540
        await screen.sendAndWait()
        check(screen.client.lastViewport?.height == 540 && host.extendedDesktopViewports[id]?.heightPt == 976,
              "keyboard affects panel viewport while allocation stays fixed")
        screen.panelSize = CGSize(width: 976, height: 600)
        screen.availableSize = CGSize(width: 992, height: 1366)
        await screen.sendAndWait()
        check(creates == 1 && destroys == 0 && desktop.dimensions?.heightPt == 976,
              "hide, keyboard and rotation never recreate the virtual display")

        let cursorReplay = screen.client.lastViewport!
        screen.client.setLocalCursor(true)
        try? await Task.sleep(for: .milliseconds(300))
        check(screen.client.lastViewport?.localCursor == true
              && screen.client.lastViewport?.extendedDesktop == cursorReplay.extendedDesktop
              && screen.client.lastViewport?.height == cursorReplay.height
              && screen.client.lastViewport?.scale == cursorReplay.scale,
              "debounced cursor replay retains actual geometry, native intent and Aa")

        let visible = CGRect(x: 0, y: 0, width: 1350, height: 890)
        let hidden = CGRect(x: 0, y: 0, width: 1350, height: 976)
        let videoSize = CGSize(width: 2700, height: 1952)
        let before = HEVCDisplayView.videoRect(in: visible, videoSize: videoSize)
        let after = HEVCDisplayView.videoRect(in: hidden, videoSize: videoSize)
        check(near(before.height, 890) && near(after.height, 976) && after.width > before.width,
              "aspect-fit video grows in both dimensions when toolbar hides")
        check(after == hidden && visible.contains(before), "whole frame remains visible without cropping")
        let oldVideo = HEVCDisplayView.videoRect(in: hidden, videoSize: CGSize(width: 2700, height: 1780))
        check(near(oldVideo.height, 890), "baseline 1350x890 allocation cannot grow into reclaimed height")

        for bounds in [visible, hidden, CGRect(x: 0, y: 0, width: 1350, height: 540)] {
            let input = InputFixture(bounds: bounds, videoSize: videoSize)
            let rect = HEVCDisplayView.videoRect(in: bounds, videoSize: videoSize)
            let center = input.normalized(CGPoint(x: rect.midX, y: rect.midY), clamped: false)
            check(center?.x == 0.5 && center?.y == 0.5, "rendered frame center maps to remote center at height \(bounds.height)")
            check(input.normalized(CGPoint(x: rect.minX, y: rect.minY), clamped: false)?.x == 0,
                  "rendered top-left maps to remote origin")
            if rect.minX > 0 {
                check(input.normalized(CGPoint(x: 0, y: rect.midY), clamped: false) == nil,
                      "letterbox tap is rejected")
                check(input.normalized(CGPoint(x: 0, y: rect.midY), clamped: true)?.x == 0,
                      "drag beyond video clamps to frame edge")
            }
        }

        let fresh = ScreenFixture()
        fresh.panelSize.height = 540
        await fresh.sendAndWait()
        check(fresh.client.sent.first?.height == 540 && fresh.client.lastViewport?.extendedDesktop == nativeSize,
              "connection beginning with keyboard up still provisions expanded surface")
        fresh.client.forgetViewport()
        fresh.client.sent = []
        await fresh.sendAndWait()
        check(fresh.client.sent.count == 1 && fresh.client.sent.first?.extendedDesktop == nativeSize,
              "fresh session provisions again after forgetViewport")
        let phone = ScreenFixture()
        phone.toolbarEnabled = false
        phone.panelSize = CGSize(width: 390, height: 244)
        phone.textScale = 1.5
        phone.availableSize = .zero
        await phone.sendAndWait()
        check(phone.client.sent.count == 1 && phone.client.lastViewport == Viewport(width: 390, height: 244, scale: 1.5, fps: 120),
              "phone retains original panel reporting")
        let portrait = ScreenFixture()
        portrait.panelSize = CGSize(width: 976, height: 600)
        portrait.textScale = 0.8
        portrait.availableSize = CGSize(width: 992, height: 1366)
        await portrait.sendAndWait()
        check(portrait.client.sent.count == 1 && portrait.client.lastViewport == Viewport(width: 976, height: 600, scale: 0.8, fps: 120, extendedDesktop: .init(width: 976, height: 600)),
              "initial portrait keeps its existing split layout and window scale")
        let disconnected = ScreenFixture()
        disconnected.client.connected = false
        await disconnected.sendAndWait()
        check(disconnected.client.sent.isEmpty, "disconnected screen sends nothing")
        let unmeasured = ScreenFixture()
        unmeasured.panelSize = .zero
        await unmeasured.sendAndWait()
        check(unmeasured.client.sent.isEmpty, "unmeasured panel sends nothing")
        let debounced = ScreenFixture()
        debounced.sendViewport(after: 0.03)
        debounced.panelSize.height = 976
        debounced.sendViewport(after: 0.01)
        await debounced.pendingViewport?.value
        check(debounced.client.sent.count == 1 && debounced.client.lastViewport?.height == 976,
              "debounce cancellation keeps only settled panel")
        desktop.shutdown()
        await replacementChecks()
        print("\(count) provisioning, host-policy, aspect-fit and input checks passed. No UI or device acceptance.")
    }
}
