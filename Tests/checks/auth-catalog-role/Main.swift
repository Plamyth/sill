import Foundation
import StreamProtocol
// JSON_VALIDATOR

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
    var pairedName: String? = "paired"
    var isRemote = false
    var fingerprint: Data? = Data(repeating: 1, count: 32)
    var cableDevice: String? = nil
    var automatic = false
    var authorizationCurrent = true
    var requiresLiveAuthorization: Bool { automatic }
    mutating func invalidateAuthorization() { authorizationCurrent = false }
    var isAuthenticated: Bool { encrypted && (pairedName != nil || automatic) && (!automatic || authorizationCurrent) }
    func whileAuthorized(_ send: () -> Void) -> Bool {
        guard !automatic || authorizationCurrent else { return false }; send(); return true
    }
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
final class MicrophoneRenderBuffer {
    var deliveries = 0
    var isOpen = true, isAdmitted = true
    func sendEnabled(_ data: Data, to connection: NWConnection, authorize: (_ send: () -> Void) -> Bool) -> Bool {
        authorize { deliveries += 1 }
    }
}
final class MicrophoneReplies {
    func offer(_ message: StreamMessage, connection: NWConnection, render: MicrophoneRenderBuffer?, queue: FixtureQueue,
               deliver: (StreamMessage, NWConnection, MicrophoneRenderBuffer?) -> Void) { deliver(message, connection, render) }
    func takeDeliveryTrace() -> Bool { false }
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
    var pendingBytes = 0
    var forwardingExchange: RoleHost.ForwardingExchange?
    var forwardingObserved = false
    // CLIENT_METHODS
    init(_ connection: NWConnection) { self.connection = connection }
}
final class RoleHost {
    // EXCHANGE
    struct VideoAdmission { var current: VideoEpoch? = nil }
    var videoAdmission = VideoAdmission()
    let sentryAdmission = SentryAdmission()
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
    let microphoneReplies = MicrophoneReplies()
    var onForwardingControl: ((ForwardingExchange, NWConnection, ClientRoute, AudioForwardingCatalog.Role) -> Void)?
    var rawSent: [Data] = []
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
        if admitsRaw(raw, to: client), let header = StreamMessage.parseHeader(raw) { sent.append(header.kind); rawSent.append(raw) }
    }
    // METHODS
}

@main
struct Check {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        for current in [true, false] {
            let host = RoleHost(), connection = NWConnection(), render = MicrophoneRenderBuffer()
            host.serve(connection, route: .init(encrypted: true, pairedName: nil, automatic: true), hello: Hello())
            host.clients[ObjectIdentifier(connection)]!.route.authorizationCurrent = current
            host.sendMicrophone(StreamMessage(kind: .microphoneState, timestamp: 0, isKeyframe: false, payload: Data()), to: connection, render: render)
            check(render.deliveries == (current ? 1 : 0))
            check(connection.state == (current ? .ready : .cancelled))
        }
        do {
            let host = RoleHost()
            let peers = (0..<12).map { _ in NWConnection() }
            for peer in peers { host.serve(peer, route: .init(encrypted: true, pairedName: nil, isRemote: true, automatic: true), hello: nil) }
            check(host.controlJoins == 12 && host.clients.count == 12 && host.viewerJoins == 0)
            for peer in peers { peer.cancel() }
            check(host.controlLeaves == 12 && host.clients.isEmpty)
        }
        do {
            let host = RoleHost(), connection = NWConnection()
            host.serve(connection, route: .init(encrypted: true, pairedName: nil, automatic: true), hello: nil)
            check(host.controlJoins == 1 && host.viewerJoins == 0 && host.counts.isEmpty)
            let client = host.clients[ObjectIdentifier(connection)]!
            client.route.authorizationCurrent = false
            host.sendAuthenticationCatalog(.init(macName: "fixture", windows: [], active: .none), to: connection)
            check(host.sent.isEmpty)
            host.took(Hello(), from: client)
            check(host.viewerJoins == 0 && host.controlLeaves == 1 && connection.state == .cancelled)
        }
        do {
            let host = RoleHost(), connection = NWConnection()
            host.serve(connection, route: .init(encrypted: true, pairedName: nil, automatic: true), hello: Hello())
            let client = host.clients[ObjectIdentifier(connection)]!
            check(host.viewerJoins == 1)
            client.route.authorizationCurrent = false
            host.send(StreamMessage(kind: .frame, timestamp: 0, isKeyframe: true, payload: Data([1])).serialized(), to: client)
            check(host.sent.isEmpty && connection.state == .cancelled && host.viewerLeaves == 1)
        }
        let host = RoleHost(), peer = NWConnection()
        host.serve(peer, route: .init(encrypted: true), hello: nil)
        check(host.controlJoins == 1 && host.viewerJoins == 0 && host.counts.isEmpty && !host.ticking)
        host.sendAuthenticationCatalog(.init(macName: "fixture", windows: [], active: .none), to: peer)
        check(host.sent == [.windowList] && host.clients[ObjectIdentifier(peer)]?.catalogSent == false)
        let retained = host.clients[ObjectIdentifier(peer)]!
        peer.cancel()
        check(host.controlLeaves == 1 && host.viewerLeaves == 0 && host.counts.isEmpty)
        check(host.pointerWatch?.departed.isEmpty == true)
        let joinedBeforeLateHello = host.viewerJoins
        host.took(Hello(), from: retained)
        check(host.viewerJoins == joinedBeforeLateHello && host.counts.isEmpty)

        let notReady = NWConnection()
        host.serve(notReady, route: .init(encrypted: true), hello: nil)
        let notReadyClient = host.clients[ObjectIdentifier(notReady)]!
        notReady.state = .failed
        host.took(Hello(), from: notReadyClient)
        check(host.viewerJoins == 0 && host.counts.isEmpty)
        notReady.cancel()
        let replaced = NWConnection()
        host.serve(replaced, route: .init(encrypted: true), hello: nil)
        let original = host.clients[ObjectIdentifier(replaced)]!
        let replacement = Client(replaced); replacement.role = .awaitingHello
        host.clients[ObjectIdentifier(replaced)] = replacement
        host.took(Hello(), from: original)
        check(host.viewerJoins == 0 && host.counts.isEmpty)
        replaced.cancel()

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
        host.sendAuthenticationCatalog(.init(macName: "fixture", windows: [], active: .none), to: pending)
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
        let unpaired = NWConnection()
        host.serve(unpaired, route: .init(encrypted: true, pairedName: nil), hello: nil)
        check(unpaired.state == .ready && host.viewerJoins == 4 && host.counts == [1, 2, 1, 2, 3])
        let auth = Client(NWConnection()); auth.role = .awaitingHello
        for value in 0...255 {
            guard let kind = StreamMessageKind(rawValue: UInt8(value)) else { continue }
            check(auth.role.accepts(kind) == (kind == .hello || kind == .ping || kind == .forwardingControl))
            check(auth.role.sends(kind) == (kind == .windowList || kind == .pong || kind == .goodbye))
            check(StreamPeerRole.viewer.accepts(kind) && StreamPeerRole.viewer.sends(kind))
            check(StreamPeerRole.controlOnly.accepts(kind) == (kind == .hello || kind == .ping || kind == .forwardingControl))
            check(StreamPeerRole.controlOnly.sends(kind) == (kind == .windowList || kind == .pong || kind == .goodbye || kind == .forwardingState))
        }
        let active = StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false,
                                   payload: Wire.encode(WindowList(macName: "fixture", windows: [], active: .desktop)))
        check(!host.admitsRaw(active.serialized(), to: auth))
        let frame = StreamMessage(kind: .frame, timestamp: 0, isKeyframe: true, payload: Data([1]))
        check(!host.admitsRaw(frame.serialized(), to: auth))
        let observe = try AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
        let identity = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!, generation = UUID()
        let credential = try AudioForwardingCredential(pairedDeviceId: identity, pairingGeneration: generation,
                                                       credential: String(repeating: "A", count: 43))
        let snapshot = try AudioForwardingSnapshot(revision: .init(0), intent: nil, binding: nil)
        let bootstrap = try AudioForwardingBootstrap(credential: credential,
            ownCursor: .init(intentRevision: .init(0), bindingRevision: .init(0)), snapshot: snapshot)
        let catalog = try AudioForwardingCatalog(principal: .init(kind: .cable, id: identity, authorizationGeneration: generation),
                                                 role: .controlOnly, bootstrap: bootstrap)
        let state = try AudioForwardingState(requestID: observe.requestID, operation: .observe, catalog: catalog, result: nil)
        do {
            let host = RoleHost(), connection = NWConnection()
            var received: RoleHost.ForwardingExchange?
            host.onForwardingControl = { exchange, peer, _, role in
                received = exchange; check(peer === connection && role == .controlOnly)
            }
            host.serve(connection, route: .init(encrypted: true, pairedName: nil, automatic: true), hello: nil)
            let client = host.clients[ObjectIdentifier(connection)]!
            host.receiveForwarding(Wire.encode(observe), from: client)
            check(received?.control.requestID == observe.requestID && client.role == .controlOnly)
            check(host.viewerJoins == 0 && host.counts.isEmpty && !host.ticking)
            host.queue.expirations.first?()
            check(connection.state == .ready)
            host.sendForwardingState(state, to: connection, ticket: UUID())
            check(host.rawSent.isEmpty && client.forwardingExchange != nil)
            host.sendForwardingState(state, to: connection, ticket: received!.ticket)
            check(host.sent == [.forwardingState] && client.forwardingObserved && client.forwardingExchange == nil)
            check(received?.isCurrent == false)
            let decoded = Wire.decode(AudioForwardingState.self, from: Data(host.rawSent[0].dropFirst(StreamMessage.headerLength)))
            check(decoded?.requestID == observe.requestID && decoded?.catalog?.principal.id == identity)
            host.queue.expirations.last?()
            check(connection.state == .ready)
            host.receiveForwarding(Wire.encode(observe), from: client)
            let old = received!
            host.took(Hello(), from: client)
            check(client.role.isViewer && client.forwardingExchange == nil && !client.forwardingObserved)
            check(!old.isCurrent)
            let sent = host.sent
            host.sendForwardingState(state, to: connection, ticket: old.ticket)
            check(host.sent == sent)
        }
        for expired in [true, false] {
            let host = RoleHost(), connection = NWConnection()
            var request: RoleHost.ForwardingExchange?
            host.onForwardingControl = { exchange, _, _, _ in request = exchange }
            host.serve(connection, route: .init(encrypted: true, pairedName: nil, automatic: true), hello: nil)
            let client = host.clients[ObjectIdentifier(connection)]!
            let observe = try AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
            host.receiveForwarding(Wire.encode(observe), from: client)
            check(request?.isCurrent == true && client.route.isAuthenticated)
            if expired { host.queue.expirations.last?() }
            else { client.cancel() }
            check(request?.isCurrent == false && !client.route.isAuthenticated)
            check(connection.state == .cancelled && host.clients.isEmpty)
        }
        for invalid in [Data("{}".utf8), Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8), Data(repeating: 65, count: 4097)] {
            let host = RoleHost(), connection = NWConnection()
            host.onForwardingControl = { _, _, _, _ in preconditionFailure("invalid request reached provider") }
            host.serve(connection, route: .init(encrypted: true), hello: nil)
            host.receiveForwarding(invalid, from: host.clients[ObjectIdentifier(connection)]!)
            check(connection.state == .cancelled && host.viewerJoins == 0)
        }
        check(StreamMessage.clientPayloadLimit(for: .activateSentry) == 512 && StreamMessage.hostPayloadLimit(for: .activateSentry) == -1)
        check(StreamMessage.clientPayloadLimit(for: .sentryState) == -1 && StreamMessage.hostPayloadLimit(for: .sentryState) == 4096)
        check(StreamMessageKind.activateSentry.rawValue == 213 && StreamMessageKind.sentryState.rawValue == 214)
        let guarded = RoleHost(), guardedPeer = NWConnection()
        guarded.sentryAdmission.configure(latched: true, persistenceHealthy: true)
        guarded.serve(guardedPeer, route: .init(encrypted: true, automatic: true), hello: Hello())
        let guardedID = ObjectIdentifier(guardedPeer), guardedClient = guarded.clients[ObjectIdentifier(guardedPeer)]!
        guarded.sentryAdmission.admit(guardedID)
        let pcm = StreamMessage(kind: .audio, timestamp: 0, isKeyframe: false, payload: Data([1])).serialized()
        check(!guarded.admitsRaw(pcm, to: guardedClient))
        guarded.sentryAdmission.update(verified: true, persistenceHealthy: true, reason: nil)
        check(guarded.admitsRaw(pcm, to: guardedClient))
        guarded.sentryAdmission.update(verified: false, persistenceHealthy: true, reason: "입력 필터 실패")
        check(!guarded.admitsRaw(pcm, to: guardedClient))
        guarded.sentryAdmission.update(verified: true, persistenceHealthy: true, reason: nil)
        guarded.sentryAdmission.fenceForLocalReturn()
        check(!guarded.admitsRaw(pcm, to: guardedClient))
        print("PASS \(checks) authenticated catalogue and viewer lifetime checks")
    }
}
