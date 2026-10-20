import Foundation
import StreamProtocol

final class NWConnection {
    enum State { case ready, cancelled }
    var state = State.ready
    func cancel() { state = .cancelled }
}
// struct AudioForwardingPairedDevice:
// @MainActor struct AudioForwardingConnectionContext
struct ClientRoute: Equatable {
    let automaticPrincipal: AutomaticDevicePrincipal?
    let authorization: AutomaticSessionAuthorization
}
final class Remote {
    let peer: AudioForwardingPairedDevice
    init(_ peer: AudioForwardingPairedDevice) { self.peer = peer }
    func isAuthorized(_ route: ClientRoute) -> Bool { route.authorization.isCurrent }
    func forwardingPeer(route: ClientRoute) -> AudioForwardingPairedDevice? {
        guard isAuthorized(route), route.automaticPrincipal?.stableIdentifier == peer.id.hex else { return nil }
        return peer
    }
}
final class StreamServer {
    // struct ForwardingExchange:
    var sent: [(UUID, AudioForwardingState?)] = []
    func sendForwardingState(_ state: AudioForwardingState?, to connection: NWConnection, ticket: UUID) {
        sent.append((ticket, state))
    }
}
@MainActor final class Host {
    var synthetic = false
    var remote: Remote?
    let server = StreamServer()
    // private struct ForwardingClient {
    var forwardingClients: [ObjectIdentifier: ForwardingClient] = [:]
    var forwardingControl: (@MainActor (AudioForwardingControl, AudioForwardingConnectionContext) async -> AudioForwardingState?)?
    // private func handleForwarding(
}

@main struct Check {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        let principal = AutomaticDevicePrincipal.cable(deviceId: "inert-USB")
        let id = AudioForwardingDeviceID(hex: principal.stableIdentifier)!, generation = UUID()
        let peer = AudioForwardingPairedDevice(id: id, pairingGeneration: generation)
        let request = try AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
        for scenario in ["accepted", "expired", "replaced", "closed", "wrong-principal", "wrong-role"] {
            let host = Host(), connection = NWConnection()
            let authorization = AutomaticSessionAuthorization(principal: principal, fingerprint: Data32(Data(repeating: 1, count: 32))!)
            let route = ClientRoute(automaticPrincipal: principal, authorization: authorization)
            host.remote = Remote(peer)
            var entered = false
            host.forwardingControl = { control, context in
                entered = true
                check(control.requestID == request.requestID && context.principal.id == id && context.peer.id == id)
                check(context.principal.authorizationGeneration == generation && context.principal.kind == .cable && context.role == .controlOnly)
                check(context.isCurrent())
                await Task.yield()
                if scenario == "expired" { authorization.invalidate() }
                if scenario == "replaced" { host.forwardingClients[ObjectIdentifier(connection)] = .init(connection: connection, route: route) }
                if scenario == "closed" { connection.cancel() }
                let replyID = scenario == "wrong-principal" ? AudioForwardingDeviceID(hex: String(repeating: "b", count: 64))! : id
                let credential = try! AudioForwardingCredential(pairedDeviceId: replyID, pairingGeneration: generation,
                    credential: String(repeating: "A", count: 43))
                let snapshot = try! AudioForwardingSnapshot(revision: .init(0), intent: nil, binding: nil)
                let bootstrap = try! AudioForwardingBootstrap(credential: credential,
                    ownCursor: .init(intentRevision: .init(0), bindingRevision: .init(0)), snapshot: snapshot)
                let catalog = try! AudioForwardingCatalog(principal: .init(kind: .cable, id: replyID, authorizationGeneration: generation),
                    role: scenario == "wrong-role" ? .viewer : context.role, bootstrap: bootstrap)
                return try! AudioForwardingState(requestID: control.requestID, operation: .observe, catalog: catalog, result: nil)
            }
            let exchange = StreamServer.ForwardingExchange(control: request)
            await host.handleForwarding(exchange, connection: connection, route: route, role: .controlOnly)
            check(entered && host.server.sent.count == 1 && host.server.sent[0].0 == exchange.ticket)
            check((host.server.sent[0].1?.catalog != nil) == (scenario == "accepted"))
        }
        print("PASS \(checks) extracted forwarding context checks; service, socket and hardware are inert")
    }
}
