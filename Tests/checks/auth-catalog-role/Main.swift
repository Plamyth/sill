import Foundation
import StreamProtocol

final class NWConnection {
    enum State { case ready, failed, cancelled }
    var state = State.ready
    var endpoint = "inert paired peer"
    var currentPath = 0
    var stateUpdateHandler: ((State) -> Void)?
    var pathUpdateHandler: ((Int) -> Void)?
    func cancel() { state = .cancelled; stateUpdateHandler?(.cancelled) }
}
enum ClientLink { struct Route: Equatable {} }
struct ClientRoute {
    var encrypted: Bool
    var isRemote = false
    var fingerprint: Data? = Data(repeating: 1, count: 32)
    var cableDevice: String? = nil
}
struct Hello { var presentationInput: Int? = nil; var device: String? = nil }
enum SafeText { static func label(_ text: String) -> String { text } }
enum DeviceGate { static func helloLine(_ hello: Hello, endpoint: String) -> String { "inert hello" } }
final class FixtureQueue {
    var expirations: [() -> Void] = []
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { expirations.append(execute) }
    func async(execute: () -> Void) { execute() }
}
final class PointerProbe {
    var departed: [ObjectIdentifier] = []
    func clientLeft(_ id: ObjectIdentifier) { departed.append(id) }
}
final class Client {
    let connection: NWConnection
    var route = ClientRoute(encrypted: false)
    var role = StreamPeerRole.viewer
    var encrypted = false
    var onCable = false
    var link: ClientLink.Route?
    var connectedAt = 0.0
    var lastHeardAt = 0.0
    var helloSeen = false
    var presentationInput = false
    var needsKeyframe = false
    var awaitingFirstKeyframe = false
    var catalogSent = false
    var device: String?
    init(_ connection: NWConnection) { self.connection = connection }
}
final class RoleHost {
    struct VideoAdmission { var current: VideoEpoch? = nil }
    var videoAdmission = VideoAdmission()
    var clients: [ObjectIdentifier: Client] = [:]
    // VIEWER_COUNT
    let queue = FixtureQueue()
    var pointerWatch: PointerProbe? = PointerProbe()
    var onClientConnected: ((NWConnection, ClientRoute, ClientLink.Route?) -> Void)?
    var onControlClientConnected: ((NWConnection, ClientRoute) -> Void)?
    var onControlClientDisconnected: ((NWConnection) -> Void)?
    var onClientDisconnected: ((NWConnection) -> Void)?
    var onClientCountChanged: ((Int) -> Void)?
    var onClientRouteChanged: ((NWConnection, ClientLink.Route?) -> Void)?
    var onClientHello: ((NWConnection, Hello) -> Void)?
    var onKeyframeNeeded: (() -> Void)?
    var viewerJoins = 0, viewerLeaves = 0, controlJoins = 0, controlLeaves = 0
    var counts: [Int] = [], sent: [StreamMessageKind] = []
    var ticking = false
    init() {
        onClientConnected = { [unowned self] _, _, _ in viewerJoins += 1 }
        onClientDisconnected = { [unowned self] _ in viewerLeaves += 1 }
        onControlClientConnected = { [unowned self] _, _ in controlJoins += 1 }
        onControlClientDisconnected = { [unowned self] _ in controlLeaves += 1 }
        onClientCountChanged = { [unowned self] in counts.append($0) }
    }
    func updateTicking() { ticking = viewerCount > 0 }
    func updateSweep() {}
    func receiveLoop(_ client: Client) {}
    func replayCatalog(to client: Client) {}
    func link(_ connection: NWConnection, path: Int) -> ClientLink.Route? { nil }
    func send(_ raw: Data, to client: Client) {
        if admitsRaw(raw, to: client), let header = StreamMessage.parseHeader(raw) { sent.append(header.kind) }
    }
    // METHODS
}

@main
struct Check {
    static func main() {
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        let host = RoleHost(), peer = NWConnection()
        host.serve(peer, route: .init(encrypted: true), hello: nil)
        check(host.controlJoins == 1 && host.viewerJoins == 0 && host.counts.isEmpty && !host.ticking)
        host.sendAuthenticationCatalog(.init(windows: [], active: .none), to: peer)
        check(host.sent == [.windowList] && host.clients[ObjectIdentifier(peer)]?.catalogSent == false)
        peer.cancel()
        check(host.controlLeaves == 1 && host.viewerLeaves == 0 && host.counts.isEmpty)
        check(host.pointerWatch?.departed.isEmpty == true)

        let screen = NWConnection(), audioAuth = NWConnection()
        host.serve(screen, route: .init(encrypted: true), hello: Hello())
        check(host.viewerJoins == 1 && host.counts == [1] && host.ticking)
        host.serve(audioAuth, route: .init(encrypted: true), hello: nil)
        audioAuth.cancel()
        check(host.viewerLeaves == 0 && host.counts == [1] && host.ticking)
        let pending = NWConnection()
        host.serve(pending, route: .init(encrypted: true), hello: nil)
        let client = host.clients[ObjectIdentifier(pending)]!
        host.took(Hello(presentationInput: 1), from: client)
        check(host.viewerJoins == 2 && host.counts == [1, 2] && client.presentationInput)
        let before = host.sent
        host.sendAuthenticationCatalog(.init(windows: [], active: .none), to: pending)
        check(host.sent == before)
        host.took(Hello(), from: client)
        check(host.viewerJoins == 2 && host.counts == [1, 2])
        host.queue.expirations.forEach { $0() }
        check(pending.state == .ready && screen.state == .ready)
        pending.cancel()
        check(host.viewerLeaves == 1 && host.counts == [1, 2, 1])

        let abandoned = NWConnection()
        host.serve(abandoned, route: .init(encrypted: true), hello: nil)
        host.queue.expirations.last?()
        check(abandoned.state == .cancelled && host.viewerLeaves == 1 && host.counts == [1, 2, 1])
        let plain = NWConnection()
        host.serve(plain, route: .init(encrypted: false), hello: nil)
        check(host.viewerJoins == 3 && host.counts == [1, 2, 1, 2])
        let auth = Client(NWConnection()); auth.role = .awaitingHello
        for value in 0...255 {
            guard let kind = StreamMessageKind(rawValue: UInt8(value)) else { continue }
            check(auth.role.accepts(kind) == (kind == .hello || kind == .ping))
            check(auth.role.sends(kind) == (kind == .windowList || kind == .pong || kind == .goodbye))
            check(StreamPeerRole.viewer.accepts(kind) && StreamPeerRole.viewer.sends(kind))
        }
        let active = StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false,
                                   payload: Wire.encode(WindowList(windows: [], active: .desktop)))
        check(!host.admitsRaw(active.serialized(), to: auth))
        let frame = StreamMessage(kind: .frame, timestamp: 0, isKeyframe: true, payload: Data([1]))
        check(!host.admitsRaw(frame.serialized(), to: auth))
        print("PASS \(checks) authenticated catalogue and viewer lifetime checks")
    }
}
