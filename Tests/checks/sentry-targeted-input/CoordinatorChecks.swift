import Foundation
import CoreGraphics
import StreamProtocol

@MainActor private final class PeerStreamSession {
    var source = StreamSource.desktop
    var epoch: VideoEpoch?
    var isClosed = false
    func inputRect(generation: String, epoch id: UUID?) -> CGRect? {
        guard !isClosed, let epoch, epoch.generation == generation, epoch.id == id, epoch.source == source else { return nil }
        return CGRect(x: 0, y: 0, width: 400, height: 300)
    }
}
private final class Connection { enum State { case ready, failed }; var state = State.ready }
private struct App { let processID: pid_t }
private struct Window { let id: CGWindowID; let owningApplication: App? }
@MainActor private final class Catalog {
    var windows: [CGWindowID: Window] = [10: Window(id: 10, owningApplication: App(processID: 100))]
    func window(id: CGWindowID) -> Window? { windows[id] }
}
@MainActor private final class Sizer {
    func element(for window: Window, input: Bool) -> CGWindowID? { window.id }
}
@MainActor private enum WindowSizer {
    static var focused = true
    static func hasKeyboardFocus(_ id: CGWindowID, pid: pid_t) -> Bool { focused }
}
@MainActor private final class Admission {
    var allowed = true
    func allowsActions(_ id: ObjectIdentifier) -> Bool { allowed }
}
@MainActor private final class Server { let sentryAdmission = Admission() }
@MainActor private final class CoordinatorFixture {
    static var foreground: pid_t? = 200
    static var top: (id: CGWindowID, pid: pid_t)? = (10, 100)
    static func activePID(trustAppKit: Bool) -> pid_t? { foreground }
    static func topmostWindow(at point: CGPoint?) -> (id: CGWindowID, pid: pid_t)? { top }
    var peerStreams: [ObjectIdentifier: PeerStreamSession] = [:]
    var connections: [ObjectIdentifier: Connection] = [:]
    let server = Server(), catalog = Catalog(), sizer = Sizer(), injector = InputInjector()
    var synthetic = false, appKitLoop = true, shuttingDown = false, switching = false
    var active = StreamSource.desktop
    var videoEpoch: VideoEpoch?
    var raised: [CGWindowID] = []
    var onRaise: (() -> Void)?
    func activateAndRaise(window: Window) { raised.append(window.id); Self.foreground = window.owningApplication?.processID; onRaise?() }
    __PRODUCTION_COORDINATOR__
    func run() async {
        injector.isolatesPhysicalInput = true
        let connection = Connection(), lane = PeerStreamSession()
        let peer = ObjectIdentifier(connection)
        let epoch = VideoEpoch(generation: "generation", source: .desktop,
            geometry: .init(x: 0, y: 0, width: 400, height: 300), width: 400, height: 300)
        lane.epoch = epoch; peerStreams[peer] = lane; connections[peer] = connection
        let event = InputEvent.pointer(.leftDown, x: 0.5, y: 0.5)
        let ready = await preparePeerInteraction(lane, epoch: epoch, event: event)
        Checks.check(ready && raised == [10] && Self.foreground == 100,
                     "exact preparePeerInteraction의 desktop 뒷창 클릭은 기존 activateAndRaise 후 초점 재검증")
        Self.foreground = 200; raised = []
        onRaise = { lane.epoch = nil }
        let delayed = await preparePeerInteraction(lane, epoch: epoch, event: event)
        Checks.check(!delayed, "desktop 비동기 초점 대기 중 epoch 교체는 입력 거부")
        lane.epoch = epoch; onRaise = nil; Self.foreground = 100
        WindowSizer.focused = false
        let focusFailed = await preparePeerInteraction(lane, epoch: epoch, event: event)
        Checks.check(!focusFailed, "desktop activation 요청 성공만으로 초점 검증 통과하지 않음")
        WindowSizer.focused = true
        var cancelled = false
        let scope = protectedPointerScope(device: peer, epoch: epoch, isCurrent: { !cancelled })!
        Checks.check(scope.isCurrent(), "exact scope의 현재 연결·source·epoch·admission 검증")
        cancelled = true
        Checks.check(!scope.isCurrent(), "peer queue 취소가 post 직전 scope에서 거부됨")
        cancelled = false; connection.state = .failed
        Checks.check(!scope.isCurrent(), "연결 ready 상실 거부")
        connection.state = .ready; lane.source = .window(10)
        Checks.check(!scope.isCurrent(), "다른 source로 바뀐 동일 peer 거부")
        lane.source = .desktop; lane.isClosed = true
        Checks.check(!scope.isCurrent(), "닫힌 lane의 지연 실행 거부")
        lane.isClosed = false; connections[peer] = nil
        Checks.check(!scope.isCurrent(), "연결 종료 뒤 원 scope는 새 down을 허용하지 않음")
        connections[peer] = connection; server.sentryAdmission.allowed = false
        Checks.check(!scope.isCurrent(), "Sentry admission 거부 유지")
        Checks.check(protectedPointerScope(device: peer, epoch: nil) == nil, "epoch 없는 입력에 새 protected scope 생성 없음")
        let queue = PeerInputQueue()
        var effects = 0
        queue.enqueue(peer: peer) { _ in effects += 1 }
        queue.cancel(peer: peer)
        await queue.drain()
        Checks.check(effects == 0, "exact PeerInputQueue 취소는 egress 작업을 실행하지 않음")
    }
}

@MainActor func coordinatorChecks() async { await CoordinatorFixture().run() }
