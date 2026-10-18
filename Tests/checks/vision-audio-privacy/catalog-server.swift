import Foundation

final class HeldQueue {
    var work: [() -> Void] = []
    func async(execute: @escaping () -> Void) { work.append(execute) }
    func drain() { let pending = work; work.removeAll(); pending.forEach { $0() } }
}
final class NWConnection {
    enum State { case ready, cancelled }
    var state = State.ready
}
final class HostLocalOwnerGrant {
    let scope: MicrophoneScope
    let fingerprint = Data([1, 2, 3])
    var revoked = false
    var expiresAt = UInt64.max
    init(_ epoch: VideoEpoch) {
        scope = MicrophoneScope(peer: UUID(), source: epoch.source,
            inputGeneration: UUID(uuidString: epoch.generation)!, videoEpoch: epoch.id,
            destination: UUID(), capability: UUID())
    }
    func revoke() { revoked = true }
    func whileValid(at now: UInt64, _ operation: () -> Void) -> Bool {
        guard !revoked, now < expiresAt else { return false }
        operation()
        return true
    }
}
final class StreamServer {
    struct Route { var encrypted = true; var fingerprint: Data? = Data([1, 2, 3]) }
    final class Client {
        let connection: NWConnection
        var catalogSent = true
        var route = Route()
        init(_ connection: NWConnection) { self.connection = connection }
    }
    let queue = HeldQueue()
    var clients: [ObjectIdentifier: Client] = [:]
    var videoAdmission = VideoEpochAdmission.stopped
    var sent: [Data] = []
    func send(_ data: Data, to client: Client) { sent.append(data) }
}

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { fatalError("FAIL \(name)") }
}
func submit(_ server: StreamServer, _ message: StreamMessage, _ peer: NWConnection,
            _ grant: HostLocalOwnerGrant, fallback: StreamMessage?) {
#if CATALOG_QUERY_FALLBACK
    server.sendMicrophoneCatalog(message, to: peer, grant: grant, fallback: fallback)
#else
    server.sendMicrophoneCatalog(message, to: peer, grant: grant)
#endif
}
func exercise(_ name: String, expected: Int = 0, fallback: Bool = true,
              mutate: (StreamServer, StreamServer.Client, HostLocalOwnerGrant) -> Void) {
    let server = StreamServer(), peer = NWConnection()
    let client = StreamServer.Client(peer)
    let epoch = VideoEpoch(generation: UUID().uuidString, source: .window(42),
        geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
    let grant = HostLocalOwnerGrant(epoch)
    server.clients[ObjectIdentifier(peer)] = client
    server.videoAdmission = .committed(epoch)
    let request = UUID()
    let list = WindowList(macName: "canonical", windows: [], active: epoch.source,
        launchID: "launch", hostVersion: "host", protocol: 1, gestures: 1, remoteAudio: 1,
        inputGeneration: epoch.generation, presentationInput: 1, videoEpoch: epoch,
        microphone: .init(peer: grant.scope.peer, destination: grant.scope.destination,
                          generation: grant.scope.capability),
        displaySelection: 1, displays: [.init(id: 7, name: "display", width: 100, height: 100, isMain: true)],
        displayInventoryID: UUID(), activeDisplayID: 7, desktopSelectionRequired: false,
        audioPrivacy: .init(protected: true), catalogRefresh: 1, responseRequestID: request)
    let response = StreamMessage(kind: .windowList, timestamp: 1, isKeyframe: false, payload: Wire.encode(list))
    let ack = queryFallback(list, response)
    submit(server, response, peer, grant, fallback: fallback ? ack : nil)
    check(server.queue.work.count == 1 && server.sent.isEmpty, "\(name) holds the actual server queue")
    mutate(server, client, grant)
    server.queue.drain()
    check(server.sent.count == expected, "\(name) delivery count")
    if let data = server.sent.first {
        let header = StreamMessage.parseHeader(data)!
        let actual = Wire.decode(WindowList.self, from: Data(data.dropFirst(StreamMessage.headerLength)))!
        check(header.kind == .windowList && actual.responseRequestID == request, "\(name) correlated ACK")
        if grant.revoked || grant.expiresAt == 0 {
            check(actual.microphone == nil, "\(name) no stale microphone capability")
            check(actual.audioPrivacy == nil, "\(name) unknown privacy cannot revive protected true")
            var expectedList = list
            expectedList.microphone = nil; expectedList.audioPrivacy = nil
            let actualJSON = try! JSONSerialization.jsonObject(with: Wire.encode(actual)) as! NSDictionary
            let expectedJSON = try! JSONSerialization.jsonObject(with: Wire.encode(expectedList)) as! NSDictionary
            check(actualJSON == expectedJSON, "\(name) canonical catalog fields preserved")
            let text = String(decoding: data.dropFirst(StreamMessage.headerLength), as: UTF8.self)
            check(!text.contains(grant.scope.destination.uuidString) && !text.contains(grant.scope.capability.uuidString),
                  "\(name) no stale lease or capability identifiers disclosed")
        } else {
            check(actual.microphone == list.microphone && actual.audioPrivacy == list.audioPrivacy,
                  "\(name) valid grant response unchanged")
        }
    }
    server.queue.drain()
    check(server.sent.count == expected, "\(name) no retry or duplicate ACK")
}

exercise("revoked after submission", expected: 1) { _, _, grant in grant.revoke() }
exercise("valid grant", expected: 1) { _, _, _ in }
exercise("expired after submission", expected: 1) { _, _, grant in grant.expiresAt = 0 }
exercise("legacy caller drops revoked grant", fallback: false) { _, _, grant in grant.revoke() }
exercise("pin changed") { _, client, grant in grant.revoke(); client.route.fingerprint = Data([9]) }
exercise("unauthenticated") { _, client, grant in grant.revoke(); client.route.encrypted = false }
exercise("unadmitted") { _, client, grant in grant.revoke(); client.catalogSent = false }
exercise("closed") { _, client, grant in grant.revoke(); client.connection.state = .cancelled }
exercise("removed connection") { server, _, grant in grant.revoke(); server.clients.removeAll() }
exercise("replaced connection") { server, client, grant in
    grant.revoke(); server.clients[ObjectIdentifier(client.connection)] = .init(NWConnection())
}
exercise("epoch changed") { server, _, grant in grant.revoke(); server.videoAdmission = .stopped }
exercise("source changed with same epoch") { server, _, grant in
    grant.revoke()
    let old = server.videoAdmission.current!
    server.videoAdmission = .committed(.init(id: old.id, generation: old.generation, source: .window(99),
        geometry: old.geometry, width: old.width, height: old.height))
}
exercise("input generation changed with same epoch") { server, _, grant in
    grant.revoke()
    let old = server.videoAdmission.current!
    server.videoAdmission = .committed(.init(id: old.id, generation: UUID().uuidString, source: old.source,
        geometry: old.geometry, width: old.width, height: old.height))
}
print("RESULT_ASSERTIONS \(checks)")
