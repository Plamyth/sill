import Foundation
import CoreGraphics
import StreamProtocol

// ADMISSION_TYPE

struct SCWindow {
    let windowID: UInt32
    var frame = CGRect(x: 10, y: 20, width: 640, height: 480)
    var title: String? = "검사 창"
    var isOnScreen = true, isActive = true
    var owningApplication: Application? = Application()
}
struct Application { var applicationName = "검사 앱" }
struct Display { var displayID: UInt32 = 1; var width = 1280, height = 720 }
struct SCContentFilter {
    init() {}
    init(desktopIndependentWindow: SCWindow) {}
    init(display: Display, excludingApplications: [Application], exceptingWindows: [SCWindow]) {}
    init(display: Display, excludingWindows: [SCWindow]) {}
}
struct DisplayInventory {
    var current: DisplaySelection? = DisplaySelection(displayID: 1, inventoryID: UUID())
    func contains(_ selection: DisplaySelection) -> Bool { current == selection }
    static func scope(_ selection: DisplaySelection) -> String { "검사 화면" }
}
final class Catalog {
    var displayInventory = DisplayInventory()
    var display: Display? = Display()
    var clientCount = 1
    var ownApplication: Application? = Application()
    @discardableResult func refreshWindows() async -> Bool { true }
    func selectDisplay(_ selection: DisplaySelection) -> Bool { displayInventory.contains(selection) }
    func window(id: UInt32) -> SCWindow? { SCWindow(windowID: id) }
    func resolveWindow(id: UInt32) async -> SCWindow? { window(id: id) }
    func resolveOwnApplication() async -> Application? { ownApplication }
}
final class Stage {
    struct Placement { let windowID: UInt32 }
    struct Prepared {
        let filter = SCContentFilter()
        let sourceRect = CGRect(x: 10, y: 20, width: 640, height: 480)
        let outputSize: CGSize? = nil
        let describe = "검사 가상 화면"
    }
    struct Failure: Error { let summary: String }
    var isStaged = false
    var placement: Placement?
    var disabledReason: String?
    func leaveFullScreenIfNeeded() async {}
    func release() { isStaged = false; placement = nil }
    func releaseWindow() { placement = nil }
    func prepare(window: SCWindow, wanted: CGSize, envelope: CGSize, captureScale: CGFloat, refreshHz: Int) async throws -> Prepared {
        Prepared()
    }
}
typealias VirtualStage = Stage
@MainActor final class Capture {
    var onFrame: ((Int, Double) -> Void)?
    var starts = 0, stops = 0
    var running = false
    private var pending: CheckedContinuation<Void, Error>?
    private var entered: CheckedContinuation<Void, Never>?
    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, showsCursor: Bool,
               sourceRect: CGRect?, desktopDisplay: Display?) async throws {
        starts += 1
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            entered?.resume(); entered = nil
        }
        running = true
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func finish(_ error: Error? = nil) {
        let continuation = pending!
        pending = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
    func stop() async { stops += 1; running = false }
}
@MainActor final class SyntheticCapture {
    var onFrame: ((Int, Double) -> Void)?
    var onStart: (() -> Void)?
    var starts = 0, stops = 0
    var running = false
    func start(width: Int, height: Int, fps: Int) { starts += 1; running = true; onStart?() }
    func stop() async { stops += 1; running = false }
}
final class HEVCEncoder {
    static var created: [HEVCEncoder] = []
    var onHung: (() -> Void)?
    var onEncoded: ((Data, Bool, ParameterSets?) -> Void)?
    var isDead = false
    var keyframes = 0
    init(width: Int, height: Int, fps: Int, bitrate: Int, prioritizeSpeed: Bool, software: Bool) throws {
        Self.created.append(self)
    }
    func encode(_ buffer: Int, pts: Double) { onEncoded?(Data([1]), true, nil) }
    func requestKeyframe() { keyframes += 1 }
}
final class Server {
    struct Commit { let epoch: VideoEpoch; let catalog: StreamMessage }
    var prepared: [VideoEpoch] = []
    var commits: [Commit] = []
    var resets = 0, broadcasts = 0
    var admission = VideoEpochAdmission.stopped
    var sent: [StreamMessage] = []
    func send(_ message: StreamMessage, to connection: NWConnection) { sent.append(message) }
    func prepareVideo(_ epoch: VideoEpoch) { prepared.append(epoch); admission = .preparing(epoch) }
    func commitVideo(_ epoch: VideoEpoch, catalog: StreamMessage, onReady: () -> Void) {
        commits.append(Commit(epoch: epoch, catalog: catalog)); admission = .committed(epoch); onReady()
    }
    func resetForNewStream() { resets += 1; admission = .stopped }
    func broadcast(_ message: StreamMessage, epoch: UUID) { broadcasts += 1 }
}
struct HostStatusSnapshot {
    struct Stream {
        enum Kind { case window, desktop, testPattern }
        let kind: Kind, title: String, width: Int, height: Int, fps: Int, mbps: Int
        let onVirtualDisplay: Bool, softwareEncoder: Bool
    }
    var stream: Stream?
    var lastStageFailure: String?
    var virtualDisplayProblem: String?
}
final class Status {
    var value = HostStatusSnapshot()
    var updates = 0
    func update(_ action: (inout HostStatusSnapshot) -> Void) { updates += 1; action(&value) }
}
enum AXError { case success, cannotComplete }
final class Dock {
    var value = RemoteDockCatalog(version: UUID(), items: [RemoteDockItem(id: 0, title: "검사 앱", subrole: "app", running: true)])
    var onRead: (() -> Void)?
    var reads = 0
    var actionAttempts = 0
    static let failure = "격리된 Dock 액션 실패"
    func disconnected(_ owner: ObjectIdentifier) {}
    func perform(_ request: RemoteDockRequest, owner: ObjectIdentifier,
                 actionAdmission: ((() -> AXError) -> AXError)) -> RemoteDockReply {
        _ = actionAdmission { self.actionAttempts += 1; return .cannotComplete }
        return RemoteDockReply(requestID: request.requestID, catalog: value, note: Self.failure)
    }
    func catalog(force: Bool = false) -> RemoteDockCatalog { reads += 1; onRead?(); return value }
}
struct Config { var virtualDisplay = false }
enum KeyStrokes { typealias Device = ObjectIdentifier }
final class NWConnection {
    enum State { case ready, cancelled }
    var state = State.ready
}
struct Route {
    var encrypted = true
    var fingerprint: String? = "검사 키"
    var requiresLiveAuthorization = false
    var isAuthenticated = true
}
final class Remote {
    var paired = true
    func isPaired(_ fingerprint: String) -> Bool { paired && fingerprint == "검사 키" }
    func isAuthorized(_ route: Route) -> Bool { paired && route.encrypted && route.isAuthenticated }
}
final class Microphone {
    enum Phase { case off, cleanupFailed }
    var phase = Phase.off
}
struct Injector {
    func releaseInput(of device: ObjectIdentifier) {}
    func isUpOfSomethingDown(_ event: Int, from device: ObjectIdentifier) -> Bool { false }
    func apply(_ event: Int, in rect: CGRect, from device: ObjectIdentifier) {}
}
struct Fence {
    var members: Set<ObjectIdentifier> = []
    func contains(_ id: ObjectIdentifier) -> Bool { members.contains(id) }
    func allowsSelection(_ source: StreamSource, desktopScope: String?) -> Bool { true }
}
enum LinkJudge { struct Quality { let bitrate: Int, fps: Int, captureScale: Double } }
final class Stats { static let shared = Stats(); func bump(_ key: String) {} }

@MainActor final class Host {
    let capture = Capture(), syntheticCapture = SyntheticCapture()
    let server = Server(), status = Status(), nativeDock = Dock(), catalog = Catalog(), stage = Stage()
    let dockSelectionIngress = DockSelectionIngress()
    let microphoneReceiver = Microphone()
    var dockTransition = false
    var dockGeneration: String?
    var pendingDockSelection: (StreamMessage, NWConnection, UInt64)?
    var pendingLaunch: String?
    var dockArrivals: [ObjectIdentifier: [TimeInterval]] = [:]
    var selectionRevision: String { "검사 선택 세대" }
    var active = StreamSource.none
    var inputGeneration = "기존 입력 세대"
    var videoEpoch: VideoEpoch?
    var encoder: HEVCEncoder?
    var synthetic = false, virtualDisplay = false, switching = false, shuttingDown = false
    var fps = 60, streamBitrate = 8_000_000
    var prioritizeSpeed = false, useSoftwareEncoder = false
    var config = Config(), pendingConfig: Config?
    var restartOf: StreamSource?, pickArrivedWhileSwitching: StreamSource?
    var deselectWhenSettled = false, viewportArrivedWhileSwitching = false
    var awayWanted = false, awayRunning = false
    var flipWait: Int?
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var routes: [ObjectIdentifier: Route] = [:]
    let injector = Injector()
    var inputFence = Fence()
    var desktopScope: String? = "검사 화면"
    var rectCache: CGRect?
    enum Held { case input(Int, CGRect, ObjectIdentifier, VideoEpoch?), chord, disconnect(ObjectIdentifier) }
    var heldInput: [Held] = []
    var holdUntil = 0
    var captureScale: CGFloat = 1
    var bitrate: Int { streamBitrate }
    var effectiveFPS: Int { 60 }
    var remote: Remote? = Remote()
    var listCalls = 0
    var sourceBounds: CGRect? = CGRect(x: 10, y: 20, width: 640, height: 480)
    func currentSourceRect(source: StreamSource? = nil, fresh: Bool = false) -> CGRect? { sourceBounds }
    static func liveBounds(of id: UInt32) -> CGRect? { CGRect(x: 10, y: 20, width: 640, height: 480) }
    static func menuTitle(for window: SCWindow) -> String { "검사 창" }
    func wantedStage(for window: SCWindow) -> (size: CGSize, envelope: CGSize) { (window.frame.size, window.frame.size) }
    func fitToViewport(_ window: SCWindow) -> CGSize? { nil }
    func activateAndRaise(window: SCWindow) {}
    func evenPixels(_ value: CGFloat) -> Int { Int(value) / 2 * 2 }
    func sendMicrophoneCatalog(to connection: NWConnection) {}
    func applyViewportToActiveWindow() async {}
    func handlePick(_ source: StreamSource) async {}
    func applyPending() async {}
    func judgeLinks(_ quality: LinkJudge.Quality?) {}
    func revokeRemoteAudio(reason: String) async {}
    func adopt(_ value: Config, away: Bool) { config = value }
    func encoderHung(_ encoder: HEVCEncoder) async {}
    func broadcastList() {}
    func focusedDockSource() -> StreamSource? { fatalError("실패 복구 검사에서 OS 포커스 조회를 실행하면 안 됩니다") }
    func handle(_ message: StreamMessage, from connection: NWConnection, selectionTicket: UInt64?) async {
        fatalError("실패 복구 검사는 후속 메시지를 실행하지 않습니다")
    }
    func runDock(_ message: StreamMessage, from connection: NWConnection, selectionTicket: UInt64?) async {
        await handleDockRequest(message, from: connection, selectionTicket: selectionTicket)
    }
    func listMessage(preloadedDock: RemoteDockCatalog? = nil) -> StreamMessage {
        listCalls += 1
        dockSelectionIngress.publish(dock: preloadedDock, windowIDs: [7, 17], displayInventoryID: nil,
                                      displayIDs: [], appBundleIDs: [])
        return StreamMessage(kind: .windowList, timestamp: 1, isKeyframe: false,
            payload: Wire.encode(WindowList(macName: "비활성 호스트", windows: [], active: active,
                inputGeneration: inputGeneration, videoEpoch: videoEpoch, dock: preloadedDock)))
    }
    func runPipeline(admission: SourceSelectionAdmission? = nil, source: StreamSource = .window(17), pattern: Bool = false) async throws {
        try await startPipeline(source: source, filter: pattern ? nil : SCContentFilter(), sourceRect: nil,
                                width: 640, height: 480, describe: "비활성 검사", title: "검사 창",
                                kind: pattern ? .testPattern : .window, admission: admission)
    }
    func runLegacyPipeline(source: StreamSource) async throws {
        try await startPipeline(source: source, filter: SCContentFilter(), sourceRect: nil,
                                width: 640, height: 480, describe: "기존 호출 검사", title: "검사 창", kind: .window)
    }
    func dockAdmission(_ connection: NWConnection, selectionTicket: UInt64?) -> SourceSelectionAdmission {
        // ADMISSION_FACTORY
        return admission
    }
    static func revoked(_ error: Error?) -> Bool { (error as? PipelineEpochError) == .admissionRevoked }
    // PRODUCTION_MEMBERS
}

enum Revocation: String, CaseIterable { case peerLoss = "peer-loss", newTicket = "new-ticket", transportClosed = "transport-closed" }
enum Moment: String, CaseIterable { case captureStart = "capture-start", catalogRead = "catalog-read", commitCallback = "commit-callback" }
enum RecoveryRevocation: String, CaseIterable {
    case peerRemoved = "peer-removed", newTicket = "new-ticket"
    case transportCancelled = "transport-cancel", pairingRevoked = "pair-revoke"

    @MainActor func apply(to request: Request) {
        let host = request.host
        switch self {
        case .peerRemoved:
            host.dockSelectionIngress.removePeer(ObjectIdentifier(request.peer))
        case .newTicket:
            let peer = ObjectIdentifier(request.newerPeer)
            host.dockSelectionIngress.setPeer(peer, dockAllowed: true)
            let message = StreamMessage(kind: .selectSource, timestamp: 2, isKeyframe: false,
                                       payload: Wire.encode(StreamSource.window(17)))
            precondition(host.dockSelectionIngress.reserve(for: message, from: peer)! > request.ticket)
        case .transportCancelled:
            request.peer.state = .cancelled
        case .pairingRevoked:
            host.remote?.paired = false
        }
    }
}
final class StartFailure: Error {}
struct CheckFailure: Error, CustomStringConvertible { let description: String }
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    if !condition() { throw CheckFailure(description: description) }
}

@MainActor final class Request {
    let host: Host
    let peer = NWConnection(), newerPeer = NWConnection()
    let ticket: UInt64
    var commitAttempts = 0
    var beforeCommit: (() -> Void)?
    init(_ host: Host) {
        self.host = host
        let id = ObjectIdentifier(peer)
        host.inputFence.members.insert(id); host.connections[id] = peer; host.routes[id] = Route()
        host.dockSelectionIngress.setPeer(id, dockAllowed: true)
        host.dockSelectionIngress.publish(dock: host.nativeDock.value, windowIDs: [7, 17], displayInventoryID: nil,
                                          displayIDs: [], appBundleIDs: [])
        let request = RemoteDockRequest(version: host.nativeDock.value.version, itemID: 0, action: .press)
        let message = StreamMessage(kind: .dockRequest, timestamp: 1, isKeyframe: false, payload: Wire.encode(request))
        ticket = host.dockSelectionIngress.reserve(for: message, from: id)!
    }
    var admission: SourceSelectionAdmission {
        let production = host.dockAdmission(peer, selectionTicket: ticket)
        return SourceSelectionAdmission(isCurrent: production.isCurrent, commit: { action in
            self.commitAttempts += 1
            self.beforeCommit?()
            return production.commit(action)
        })
    }
    func revoke(_ reason: Revocation) {
        switch reason {
        case .peerLoss:
            peer.state = .cancelled
            host.dockSelectionIngress.removePeer(ObjectIdentifier(peer))
        case .transportClosed: peer.state = .cancelled
        case .newTicket:
            let id = ObjectIdentifier(newerPeer)
            host.dockSelectionIngress.setPeer(id, dockAllowed: true)
            let message = StreamMessage(kind: .selectSource, timestamp: 2, isKeyframe: false, payload: Wire.encode(StreamSource.window(7)))
            precondition(host.dockSelectionIngress.reserve(for: message, from: id)! > ticket)
        }
    }
}

@MainActor struct Snapshot {
    let source: StreamSource, generation: String, epoch: VideoEpoch?, encoder: HEVCEncoder?
    init(_ host: Host) { source = host.active; generation = host.inputGeneration; epoch = host.videoEpoch; encoder = host.encoder }
    func check(_ host: Host) throws {
        try expect(host.active == source, "active가 확정되지 않아야 합니다")
        try expect(host.inputGeneration == generation, "inputGeneration이 확정되지 않아야 합니다")
        try expect(host.videoEpoch == epoch, "videoEpoch가 확정되지 않아야 합니다")
        try expect(host.encoder === encoder, "encoder가 확정되지 않아야 합니다")
        try expect(host.server.commits.isEmpty && host.listCalls == 0, "server.commitVideo와 catalog 생성이 없어야 합니다")
        try expect(host.status.updates == 0, "취소된 후보를 상태에 공개하면 안 됩니다")
    }
}

@MainActor func cleaned(_ host: Host, candidate: HEVCEncoder) throws {
    let observed = "capture.stop=\(host.capture.stops), synthetic.stop=\(host.syntheticCapture.stops), capture.onFrame=\(host.capture.onFrame != nil), synthetic.onFrame=\(host.syntheticCapture.onFrame != nil), onEncoded=\(candidate.onEncoded != nil), server=\(host.server.admission)"
    try expect(host.capture.onFrame == nil && host.syntheticCapture.onFrame == nil, "후보 프레임 콜백을 해제해야 합니다. 관측값 \(observed)")
    try expect(host.capture.stops > 0 && host.syntheticCapture.stops > 0, "실제 및 synthetic 후보 모두 stop해야 합니다. 관측값 \(observed)")
    try expect(!host.capture.running && !host.syntheticCapture.running, "취소 뒤 캡처가 실행 중이면 안 됩니다")
    try expect(candidate.onEncoded == nil, "후보 encoder 출력 콜백을 해제해야 합니다")
    try expect(host.server.admission == .stopped, "서버의 준비 중 epoch를 폐기해야 합니다")
}

@MainActor func pending(_ host: Host, request: Request?, select: Bool = false, source: StreamSource = .window(17)) -> Task<Error?, Never> {
    Task { @MainActor in
        do {
            if select {
                if let request { await host.select(source, admission: request.admission) }
                else { await host.select(source) }
            } else if let request { try await host.runPipeline(admission: request.admission, source: source) }
            else { try await host.runLegacyPipeline(source: source) }
            return nil
        } catch { return error }
    }
}

@main struct Checks {
    @MainActor static func main() async {
        var failed = 0
        func check(_ name: String, _ body: () async throws -> Void) async {
            HEVCEncoder.created = []
            do {
                try await body()
                let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": true])
                print("CASE " + String(decoding: data, as: UTF8.self))
            } catch {
                failed += 1
                let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": false, "failure": String(describing: error)])
                print("CASE " + String(decoding: data, as: UTF8.self))
            }
        }
        for moment in Moment.allCases {
            for reason in Revocation.allCases {
                await check("\(moment.rawValue)-\(reason.rawValue)") {
                    let host = Host(), request: Request
                    host.active = .window(7)
                    request = Request(host)
                    let before = Snapshot(host)
                    if moment == .catalogRead { host.nativeDock.onRead = { request.revoke(reason) } }
                    if moment == .commitCallback { request.beforeCommit = { request.revoke(reason) } }
                    let task = pending(host, request: request)
                    await host.capture.waitUntilStarted()
                    try before.check(host)
                    try expect(host.server.prepared.count == 1 && host.server.admission.current == nil, "대기 중 epoch는 준비 상태여야 합니다")
                    if moment == .captureStart { request.revoke(reason) }
                    host.capture.finish()
                    let error = await task.value
                    try expect(Host.revoked(error), "취소된 요청은 admissionRevoked여야 합니다")
                    try before.check(host)
                    try cleaned(host, candidate: HEVCEncoder.created.last!)
                    try expect(request.commitAttempts == 1, "최종 확정 검사를 한 번 거쳐야 합니다")
                }
            }
        }
        for reason in Revocation.allCases {
            for atCommit in [false, true] {
                await check("synthetic-\(atCommit ? "commit" : "start")-\(reason.rawValue)") {
                    let host = Host(); host.synthetic = true
                    let request = Request(host), before = Snapshot(host)
                    if atCommit { request.beforeCommit = { request.revoke(reason) } }
                    else { host.syntheticCapture.onStart = { request.revoke(reason) } }
                    var caught: Error?
                    do { try await host.runPipeline(admission: request.admission, source: .desktop, pattern: true) }
                    catch { caught = error }
                    try expect(Host.revoked(caught), "synthetic 요청도 최종 취소를 따라야 합니다")
                    try before.check(host)
                    try cleaned(host, candidate: HEVCEncoder.created.last!)
                }
            }
            await check("stale-select-\(reason.rawValue)") {
                let host = Host(), request = Request(host), before = Snapshot(host)
                request.revoke(reason)
                await host.select(.window(17), admission: request.admission)
                try before.check(host)
                try expect(host.capture.starts == 0 && host.capture.stops == 0 && host.server.resets == 0,
                           "조회 뒤 무효화된 select는 기존 파이프라인을 건드리면 안 됩니다")
                try expect(HEVCEncoder.created.isEmpty && request.commitAttempts == 0, "오래된 select가 후보를 만들면 안 됩니다")
            }
            await check("select-await-\(reason.rawValue)") {
                let host = Host(), request = Request(host)
                let task = pending(host, request: request, select: true)
                await host.capture.waitUntilStarted()
                request.revoke(reason)
                host.capture.finish()
                _ = await task.value
                try Snapshot(Host()).check(host)
                try cleaned(host, candidate: HEVCEncoder.created.last!)
                try expect(!host.switching, "select 종료 뒤 전환 잠금을 해제해야 합니다")
            }
        }
        for select in [false, true] {
            for legacy in [false, true] {
                await check("valid-\(select ? "select" : "pipeline")-\(legacy ? "nil" : "admitted")") {
                    let host = Host(), request = legacy ? nil : Request(host)
                    let task = pending(host, request: request, select: select)
                    await host.capture.waitUntilStarted()
                    try expect(host.server.commits.isEmpty && host.active == .none && host.encoder == nil && host.videoEpoch == nil,
                               "캡처 시작 완료 전에 확정하면 안 됩니다")
                    host.capture.finish()
                    let error = await task.value
                    try expect(error == nil, "유효한 요청은 성공해야 합니다")
                    try committed(host, source: .window(17), dock: host.nativeDock.value)
                    try expect((request?.commitAttempts ?? 1) == 1, "admission 확정은 한 번이어야 합니다")
                }
            }
        }
        for legacy in [false, true] {
            await check("valid-synthetic-\(legacy ? "nil" : "admitted")") {
                let host = Host(); host.synthetic = true
                let request = legacy ? nil : Request(host)
                try await host.runPipeline(admission: request?.admission, source: .desktop, pattern: true)
                try committed(host, source: .desktop, dock: nil)
                try expect(host.capture.starts == 0 && host.syntheticCapture.starts == 1, "synthetic 어댑터만 시작해야 합니다")
            }
        }
        await check("same-source-generation") {
            let host = Host(); host.active = .window(17)
            let request = Request(host), oldGeneration = host.inputGeneration
            let task = pending(host, request: request)
            await host.capture.waitUntilStarted(); host.capture.finish()
            let error = await task.value
            try expect(error == nil, "동일 소스 재시작이 성공해야 합니다")
            try committed(host, source: .window(17), dock: host.nativeDock.value)
            try expect(host.inputGeneration == oldGeneration, "동일 소스는 입력 세대를 유지해야 합니다")
        }
        for reason in [nil, Revocation.peerLoss, Revocation.newTicket, Revocation.transportClosed] {
            await check("capture-start-error-\(reason?.rawValue ?? "current")") {
                let host = Host(), request = Request(host), before = Snapshot(host)
                let failure = StartFailure()
                let task = pending(host, request: request)
                await host.capture.waitUntilStarted()
                if let reason { request.revoke(reason) }
                host.capture.finish(failure)
                let error = await task.value
                try expect((error as? StartFailure) === failure, "capture.start의 원래 오류 객체를 호출자에게 전달해야 합니다")
                try before.check(host)
                try expect(request.commitAttempts == 0, "시작 오류 뒤 commit을 호출하면 안 됩니다")
                try cleaned(host, candidate: HEVCEncoder.created.last!)
                try expect(host.capture.stops == 1 && host.syntheticCapture.stops == 1 && host.server.resets == 1,
                           "시작 오류 후보를 정확히 한 번 정리해야 합니다")
            }
        }
        for reason in Revocation.allCases {
            await check("capture-start-error-cleanup-\(reason.rawValue)") {
                let host = Host(), request = Request(host)
                let task = pending(host, request: request)
                await host.capture.waitUntilStarted()
                request.revoke(reason); host.capture.finish(StartFailure())
                _ = await task.value
                try cleaned(host, candidate: HEVCEncoder.created.last!)
            }
        }
        await check("select-start-error-cleanup") {
            let host = Host(), request = Request(host)
            let task = pending(host, request: request, select: true)
            await host.capture.waitUntilStarted()
            request.revoke(.peerLoss); host.capture.finish(StartFailure())
            _ = await task.value
            try Snapshot(Host()).check(host)
            try expect(!host.switching, "시작 오류 뒤 select 전환 잠금을 해제해야 합니다")
            try cleaned(host, candidate: HEVCEncoder.created.last!)
            try expect(host.capture.stops == 2 && host.syntheticCapture.stops == 2 && host.server.resets == 2,
                       "select의 전환 전 정리와 오류 후보 정리를 각각 한 번 수행해야 합니다")
        }
        for reason in [nil] + RecoveryRevocation.allCases.map(Optional.some) {
            await check("dock-failure-restore-\(reason?.rawValue ?? "current")") {
                let host = Host(); host.active = .window(7)
                let request = Request(host)
                let message = StreamMessage(kind: .dockRequest, timestamp: 1, isKeyframe: false,
                    payload: Wire.encode(RemoteDockRequest(version: host.nativeDock.value.version, itemID: 0, action: .press)))
                let task = Task { @MainActor in
                    await host.runDock(message, from: request.peer, selectionTicket: request.ticket)
                }
                await host.capture.waitUntilStarted()
                let candidate = HEVCEncoder.created.last!
                try expect(host.nativeDock.actionAttempts == 1 && host.active == .none && host.dockTransition,
                           "Dock 액션이 실패한 뒤 소스가 종료된 상태에서 실제 복구 캡처를 기다려야 합니다")
                try expect(host.server.commits.isEmpty && host.capture.starts == 1,
                           "복구 캡처 시작 완료 전에 commit하면 안 됩니다")
                reason?.apply(to: request)
                host.capture.finish()
                await task.value
                try expect(!host.switching && !host.dockTransition && host.dockGeneration == nil,
                           "실패 복구 종료 뒤 두 전환 잠금과 Dock 세대를 정리해야 합니다")
                if reason != nil {
                    let observed = "commit=\(host.server.commits.count), active=\(host.active), capture.running=\(host.capture.running)"
                    try expect(host.server.commits.isEmpty && host.active == .none && host.encoder == nil && host.videoEpoch == nil,
                               "취소된 실패 복구를 확정하면 안 됩니다. 관측값 \(observed)")
                    try cleaned(host, candidate: candidate)
                    try expect(host.capture.stops == 3 && host.syntheticCapture.stops == 3 && host.server.resets == 3,
                               "기존 소스 종료와 복구 전 정리와 취소 후보 정리를 각각 한 번 수행해야 합니다")
                } else {
                    try committed(host, source: .window(7), dock: host.nativeDock.value)
                    try expect(host.capture.running && host.capture.stops == 2 && host.syntheticCapture.stops == 2,
                               "정상 실패 복구는 이전 소스를 한 번 확정하고 캡처를 유지해야 합니다")
                }
                for sent in host.server.sent {
                    let reply = Wire.decode(RemoteDockReply.self, from: sent.payload)
                    try expect(reply?.note == Dock.failure && reply?.selectedSource == nil && reply?.videoEpochID == nil,
                               "복구 결과를 Dock 액션 성공으로 답하면 안 됩니다")
                }
            }
        }
        exit(failed == 0 ? 0 : 1)
    }

    @MainActor static func committed(_ host: Host, source: StreamSource, dock: RemoteDockCatalog?) throws {
        try expect(host.server.prepared.count == 1 && host.server.commits.count == 1 && host.listCalls == 1,
                   "source와 epoch와 catalog를 정확히 한 번 확정해야 합니다")
        let sent = host.server.commits[0]
        let catalog = Wire.decode(WindowList.self, from: sent.catalog.payload)
        try expect(host.active == source && sent.epoch.source == source, "동일 소스를 확정해야 합니다")
        try expect(host.videoEpoch == sent.epoch && sent.epoch == host.server.prepared[0], "준비한 동일 epoch를 확정해야 합니다")
        try expect(host.inputGeneration == sent.epoch.generation, "입력 세대가 확정 epoch와 같아야 합니다")
        try expect(catalog?.active == source && catalog?.videoEpoch == sent.epoch && catalog?.inputGeneration == host.inputGeneration,
                   "전송 catalog와 호스트의 source와 epoch와 세대가 같아야 합니다")
        try expect(catalog?.dock == dock, "확정 시 읽은 동일 Dock catalog를 전달해야 합니다")
        try expect(host.encoder === HEVCEncoder.created.last && host.encoder?.keyframes == 1, "동일 encoder를 한 번 확정해야 합니다")
        try expect(host.status.value.stream != nil && host.server.admission == .committed(sent.epoch), "성공한 상태를 공개해야 합니다")
    }
}
