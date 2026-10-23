import Foundation
import StreamProtocol

final class NWConnection {
    enum State { case ready, cancelled }
    var state = State.ready
    func cancel() { state = .cancelled }
}
struct ClientRoute: Equatable {
    enum Origin { case vpn, internet, local }
    var encrypted = true
    var pairedName: String? = "fixture"
    var fingerprint: Data? = Data(repeating: 0xab, count: 32)
    var cableDevice: String? = nil
    var origin = Origin.vpn
}
final class HandlerFixture {
    enum Role { case viewer, controlOnly, awaitingHello
        var isViewer: Bool { self == .viewer }
    }
    final class Client {
        let connection = NWConnection()
        var role = Role.viewer, route = ClientRoute(), forwardingObserved = true
        var providerExchange: ProviderExchange?
        var forwardingExchange: ForwardingExchange?
    }
    var clients: [ObjectIdentifier: Client] = [:]
    let queue = DispatchQueue(label: "provider-handler-fixture")
    var sent: [Data] = []
    var onProviderControl: ((ProviderExchange, NWConnection, ClientRoute) -> Void)?
    var onForwardingControl: ((ForwardingExchange, NWConnection, ClientRoute, AudioForwardingCatalog.Role) -> Void)?
    func send(_ bytes: Data, to client: Client) { sent.append(bytes) }
    func add() -> Client {
        let client = Client(); clients[ObjectIdentifier(client.connection)] = client; return client
    }
    func provider(_ payload: Data, _ client: Client) { queue.sync { receiveProvider(payload, from: client) } }
    func forwarding(_ payload: Data, _ client: Client) { queue.sync { receiveForwarding(payload, from: client) } }
    func drain() { queue.sync { } }
    // PRODUCTION_EXCHANGES
    // PRODUCTION_HANDLERS
}

typealias StreamServer = HandlerFixture
@MainActor final class PairingFixture {
    var paired = true
    let peer: AudioForwardingPairedDevice
    init(_ peer: AudioForwardingPairedDevice) { self.peer = peer }
    func isPaired(_ fingerprint: Data) -> Bool { paired && fingerprint == Data(repeating: 0xab, count: 32) }
    func forwardingPeer(fingerprint: Data) -> AudioForwardingPairedDevice? { isPaired(fingerprint) ? peer : nil }
}
@MainActor final class CoordinatorFixture {
    struct ForwardingClient {
        let connection: NWConnection
        let route: ClientRoute
        let generation: UUID
    }
    var synthetic = false, shuttingDown = false
    let server: HandlerFixture
    var remote: PairingFixture?
    var forwardingClients: [ObjectIdentifier: ForwardingClient] = [:]
    var forwardingRuntime: HostAudioForwardingRuntime?
    var providerRuntime: ProviderCallRuntime?
    init(_ server: HandlerFixture) { self.server = server }
    func invoke(_ exchange: StreamServer.ProviderExchange, _ connection: NWConnection, _ route: ClientRoute) async {
        await handleProvider(exchange, connection: connection, route: route)
    }
    // PRODUCTION_COORDINATOR
}

@MainActor func handlerChecks(_ check: (String, Bool) -> Void) async {
    let id = AudioForwardingDeviceID(hex: String(repeating: "ab", count: 32))!
    let r = try! ProviderCallRequest(requestId: UUID(), action: .start, expectedLeaseRevision: .init(7),
        pairedDeviceId: id, desiredInput: true, desiredOutput: true, callSessionId: nil)
    let payload = Wire.encode(ProviderCallControl(operation: .perform, request: r))
    for cause in ["unpaired", "plain", "unobserved", "control-only", "oversize", "duplicate-key", "unknown-key"] {
        let f = HandlerFixture(), c = f.add()
        var input = payload, called = 0
        f.onProviderControl = { _, _, _ in called += 1 }
        if cause == "unpaired" { c.route.pairedName = nil }
        if cause == "plain" { c.route.encrypted = false }
        if cause == "unobserved" { c.forwardingObserved = false }
        if cause == "control-only" { c.role = .controlOnly }
        if cause == "oversize" { input = Data(repeating: 32, count: 4097) }
        if cause == "duplicate-key" { input = Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8) }
        if cause == "unknown-key" {
            var object = try! JSONSerialization.jsonObject(with: payload) as! [String: Any]
            object["extra"] = true; input = try! JSONSerialization.data(withJSONObject: object)
        }
        f.provider(input, c)
        check("actual 221 handler rejects \(cause)", called == 0 && c.connection.state == .cancelled)
    }
    do {
        let f = HandlerFixture(), c = f.add(), other = f.add()
        f.onProviderControl = { _, _, _ in }
        f.onForwardingControl = { _, _, _, _ in }
        f.provider(payload, c)
        let provider = c.providerExchange!
        let observe = try! AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
        f.forwarding(Wire.encode(observe), c)
        let forwarding = c.forwardingExchange!
        check("217 and 221 pending slots are independent", provider.isCurrent && forwarding.isCurrent && c.connection.state == .ready)
        let generation = UUID()
        let snapshot = try! AudioForwardingSnapshot(revision: .init(7), intent: nil, binding: nil)
        let credential = try! AudioForwardingCredential(pairedDeviceId: id, pairingGeneration: generation,
            credential: String(repeating: "a", count: 43))
        let bootstrap = try! AudioForwardingBootstrap(credential: credential,
            ownCursor: .init(intentRevision: .init(0), bindingRevision: .init(0)), snapshot: snapshot)
        let catalog = try! AudioForwardingCatalog(principal: .init(kind: .tailnet, id: id,
            authorizationGeneration: generation), role: .viewer, bootstrap: bootstrap)
        let observed = try! AudioForwardingState(requestID: observe.requestID, operation: .observe,
            catalog: catalog, result: nil)
        f.sendForwardingState(observed, to: c.connection, ticket: forwarding.ticket); f.drain()
        check("217 response leaves pending provider slot intact", c.forwardingExchange == nil && c.providerExchange === provider && provider.isCurrent && f.sent.count == 1)
        let result = try! ProviderCallResult(requestId: r.requestId, status: .started, reason: "fixture_readback")
        let state = try! ProviderCallState(request: r, result: result)
        f.sendProviderState(state, to: c.connection, ticket: UUID()); f.drain()
        check("late wrong ticket cannot consume new slot", c.providerExchange === provider && f.sent.count == 1)
        f.sendProviderState(state, to: c.connection, ticket: provider.ticket); f.drain()
        check("correlated 222 consumes only provider slot", c.providerExchange == nil && !provider.isCurrent && f.sent.count == 2 && other.connection.state == .ready)
        f.sendProviderState(state, to: c.connection, ticket: provider.ticket); f.drain()
        check("late duplicate 222 emits no additional result", f.sent.count == 2)
    }
    for cause in ["digest", "request-id", "invalidated", "duplicate-perform"] {
        let f = HandlerFixture(), c = f.add()
        f.onProviderControl = { _, _, _ in }; f.provider(payload, c)
        let exchange = c.providerExchange!
        if cause == "duplicate-perform" { f.provider(payload, c) }
        else {
            let changed = try! ProviderCallRequest(requestId: cause == "request-id" ? UUID() : r.requestId,
                action: .stop, expectedLeaseRevision: r.expectedLeaseRevision, pairedDeviceId: id,
                desiredInput: true, desiredOutput: true, callSessionId: nil)
            let result = try! ProviderCallResult(requestId: changed.requestId, status: .unknown, reason: "fixture_unknown")
            let state = try! ProviderCallState(request: changed, result: result)
            if cause == "invalidated" { exchange.invalidate() }
            f.sendProviderState(state, to: c.connection, ticket: exchange.ticket); f.drain()
        }
        check("actual handler \(cause) fails closed with zero send", c.connection.state == .cancelled && f.sent.isEmpty)
    }
}
