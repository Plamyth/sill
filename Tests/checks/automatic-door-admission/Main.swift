import Foundation

final class NWConnection {
    var cancelled = false
    func cancel() { cancelled = true }
}
enum RemoteTLS { static let pairingALPN = "sill-pair/1" }
enum Origin { case internet, vpn, home }
struct Hello {}
enum ClientRoute {
    struct Peer {
        let fingerprint: Data
        let name: String?
        let cableDevice: String?
        let automaticPrincipal: AutomaticDevicePrincipal?
        let authorization: AutomaticSessionAuthorization?
    }
    case automatic(origin: Origin, peer: Peer)
}
final class Server {
    var admitted: [(NWConnection, ClientRoute)] = []
    func serve(_ connection: NWConnection, route: ClientRoute, hello: Hello?, admitted: () -> Void) {
        precondition(hello == nil)
        self.admitted.append((connection, route)); admitted()
    }
}
final class Deadline { var cancelled = false; func cancel() { cancelled = true } }
struct AutomaticEvidence { let principal: AutomaticDevicePrincipal; let fingerprint: Data32 }
final class DoorFixture {
    struct Pending {
        let connection: NWConnection
        let source: String
        var origin: Origin? = .vpn
        var automaticEvidence: AutomaticEvidence?
        var deadline: Deadline? = Deadline()
    }
    var pending: [ObjectIdentifier: Pending] = [:]
    var server: Server? = Server()
    var current = true
    var paired = 0, forgiven = 0, leases = 0
    func evidenceCurrent(_ evidence: AutomaticEvidence, on connection: NWConnection) -> Bool { current && !connection.cancelled }
    func readPairRequest(_ id: ObjectIdentifier, _ connection: NWConnection, _ fingerprint: Data) { paired += 1 }
    func forgive(_ source: String) { forgiven += 1 }
    func startAutomaticSession(_ connection: NWConnection, evidence: AutomaticEvidence) -> AutomaticSessionAuthorization {
        leases += 1
        return .init(principal: evidence.principal, fingerprint: evidence.fingerprint)
    }
    // METHOD
}

@main struct Check {
    static func main() {
        var assertions = 0
        func check(_ condition: Bool) { precondition(condition); assertions += 1 }
        let key = Data32(Data(repeating: 1, count: 32))!
        let evidence = AutomaticEvidence(principal: .cable(deviceId: "USB-device"), fingerprint: key)
        let host = DoorFixture()
        let peers = (0..<12).map { _ in NWConnection() }
        for connection in peers {
            let id = ObjectIdentifier(connection)
            let pending = DoorFixture.Pending(connection: connection, source: "inert")
            host.pending[id] = pending
            host.automaticResolved(id, connection, evidence: evidence, alpn: "sill/1")
            check(pending.deadline?.cancelled == true && host.pending[id] == nil && !connection.cancelled)
        }
        check(host.server?.admitted.count == 12 && host.leases == 12 && host.forgiven == 12)
        for (_, route) in host.server!.admitted {
            guard case .automatic(let origin, let peer) = route else { fatalError() }
            check(origin == .vpn && peer.fingerprint == key.data && peer.name == nil && peer.cableDevice == "USB-device")
            check(peer.authorization?.isCurrent == true && peer.authorization?.principal == evidence.principal)
        }
        let late = peers[0]
        host.automaticResolved(ObjectIdentifier(late), late, evidence: evidence, alpn: "sill/1")
        check(late.cancelled && host.leases == 12)
        for scenario in 0..<4 {
            let door = DoorFixture(), connection = NWConnection(), id = ObjectIdentifier(connection)
            door.pending[id] = .init(connection: scenario == 0 ? NWConnection() : connection, source: "inert")
            if scenario == 1 { door.current = false }
            if scenario == 2 { door.server = nil }
            door.automaticResolved(id, connection, evidence: evidence, alpn: scenario == 3 ? RemoteTLS.pairingALPN : "sill/1")
            check(door.leases == 0 && door.forgiven == 0 && door.server?.admitted.isEmpty != false)
            check(scenario == 3 ? door.paired == 1 && !connection.cancelled : connection.cancelled && door.paired == 0)
        }
        print("PASS \(assertions) automatic Door finalizer checks; socket, path sensors and device acceptance are not exercised")
    }
}
