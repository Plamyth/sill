import Foundation
import StreamProtocol

final class NWConnection {
    enum State { case ready, cancelled }
    var state = State.ready
}
struct FixtureRoute { var encrypted: Bool; var fingerprint: Data? }
final class FixtureTrust {
    var trusted = Set([Data([1])])
    func isPaired(_ fingerprint: Data) -> Bool { trusted.contains(fingerprint) }
}
final class FixtureServer {
    var sent: [(StreamMessage, NWConnection)] = []
    func send(_ message: StreamMessage, to connection: NWConnection) { sent.append((message, connection)) }
}
final class CoordinatorFixture {
    var routes: [ObjectIdentifier: FixtureRoute] = [:]
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var audioRoutePublished: [ObjectIdentifier: UUID] = [:]
    var audioRouteArrivals: [ObjectIdentifier: [TimeInterval]] = [:]
    let audioHardwareRoutes: AudioHardwareRoutes
    var remote: FixtureTrust? = FixtureTrust()
    var synthetic = false
    var shuttingDown = false
    let server = FixtureServer()
    init(_ hardware: FakeHardware) { audioHardwareRoutes = AudioHardwareRoutes(hardware: hardware) }

    // PRODUCTION_COORDINATOR_METHODS

    func join(_ connection: NWConnection, encrypted: Bool = true, fingerprint: Data? = Data([1])) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        routes[id] = FixtureRoute(encrypted: encrypted, fingerprint: fingerprint)
    }
    func deliver(_ kind: StreamMessageKind, _ payload: Data, from connection: NWConnection) {
        handleAudioRoute(StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: payload), from: connection)
    }
    func publish() { publishAudioRoutes() }
    func state(_ index: Int) -> AudioRouteState { Wire.decode(AudioRouteState.self, from: server.sent[index].0.payload)! }
}

func runCoordinatorChecks() {
    for mode in 0..<8 {
        let h = FakeHardware(); let c = CoordinatorFixture(h); let peer = NWConnection()
        c.join(peer)
        switch mode {
        case 0: c.routes[ObjectIdentifier(peer)]?.encrypted = false
        case 1: c.routes[ObjectIdentifier(peer)]?.fingerprint = nil
        case 2: c.remote?.trusted = []
        case 3: peer.state = .cancelled
        case 4: c.connections = [:]
        case 5: c.synthetic = true
        case 6: c.shuttingDown = true
        default: c.remote = nil
        }
        c.deliver(.fetchAudioRoutes, Data(), from: peer)
        c.deliver(.changeAudioRoute, Data("{}".utf8), from: peer)
        c.publish()
        check("unauthorized rejected before hardware/decode \(mode)", h.reads == 0 && h.writes.isEmpty && c.server.sent.isEmpty)
    }
    do {
        let h = FakeHardware(); let c = CoordinatorFixture(h); let a = NWConnection(); let b = NWConnection()
        c.join(a); c.join(b)
        c.publish()
        check("catalog sent to every paired peer", c.server.sent.count == 2)
        c.publish()
        check("unchanged observations deduplicate", c.server.sent.count == 2 && h.writes.isEmpty)
        let first = c.state(0)
        let selection = request(first, input: "in-b")
        c.deliver(.changeAudioRoute, Wire.encode(selection), from: a)
        check("requester receives correlated applied reply", c.server.sent.count == 4 && c.state(2).answering == selection.requestID && c.state(2).result == .applied)
        check("other client gets effective route without request correlation", c.server.sent[3].1 === b && c.state(3).answering == nil && c.state(3).result == nil && c.state(3).defaults.inputUID == "in-b")
        c.deliver(.changeAudioRoute, Wire.encode(request(first, output: "out-b")), from: b)
        check("second client stale selection refused", c.state(4).result == .stale && h.writes.count == 1)
        let fresh = c.state(4)
        c.deliver(.changeAudioRoute, Wire.encode(request(fresh, output: "out-b")), from: b)
        check("either client may select independent direction", c.state(5).result == .applied && h.inventory.defaults.inputUID == "in-b" && h.inventory.defaults.outputUID == "out-b")
        c.remote?.trusted = []
        let count = c.server.sent.count; let reads = h.reads
        c.deliver(.fetchAudioRoutes, Data(), from: a); c.publish()
        check("revocation suppresses catalog and commands immediately", c.server.sent.count == count && h.reads == reads)
    }
    do {
        let h = FakeHardware(); let c = CoordinatorFixture(h); let peer = NWConnection(); c.join(peer)
        c.deliver(.changeAudioRoute, Data(repeating: 1, count: 2049), from: peer)
        c.deliver(.fetchAudioRoutes, Data([0]), from: peer)
        check("oversize and nonempty fetch rejected before hardware", h.reads == 0 && c.server.sent.isEmpty)
        c.deliver(.changeAudioRoute, Data("{}".utf8), from: peer)
        check("malformed request replies invalid without write", c.state(0).result == .invalid && h.writes.isEmpty)
        c.deliver(.fetchAudioRoutes, Data(), from: peer)
        let sent = c.server.sent.count; let reads = h.reads
        c.deliver(.fetchAudioRoutes, Data(), from: peer)
        check("bounded command rate", c.server.sent.count == sent && h.reads == reads)
    }
}
