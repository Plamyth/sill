import Foundation

final class NWConnection {
    enum State { case ready }
    enum Completion { case contentProcessed((Error?) -> Void) }
    let state = State.ready
    let endpoint = "recording-wire"
    var packets: [Data] = []
    func cancel() {}
    func send(content: Data, completion: Completion) {
        packets.append(content)
        if case .contentProcessed(let done) = completion { done(nil) }
    }
}
struct Route {
    let encrypted = true
    let fingerprint: Data? = Data([1])
    let isRemote = false
}
final class HostLocalOwnerGrant {
    struct Scope { let videoEpoch: UUID }
    let fingerprint = Data([1])
    let scope: Scope
    var valid = true
    init(_ epoch: UUID) { scope = Scope(videoEpoch: epoch) }
    func whileValid(at: UInt64, _ body: () -> Void) -> Bool {
        guard valid else { return false }; body(); return true
    }
}
final class Client {
    let connection = NWConnection()
    let route = Route()
    var catalogSent = true
    var latestCatalog: StreamMessage?
    var catalogAdmission: SourcePublicationAdmission?
    var microphoneCatalogGrant: HostLocalOwnerGrant?
    var presentationInput = false
    var needsKeyframe = false
    var awaitingFirstKeyframe = false
    var inflight = 0
    var inflightFrames = 0
    var oldestUnackedFrameAt: TimeInterval?
    var connectedAt: TimeInterval = 0
    var lastSentAt: TimeInterval = 0
    var pendingBytes = 0
    var keyframeSeq = 0
    var keyframesInFlight: [(seq: Int, bytes: Int)] = []
    var keyframeBytesInFlight = 0
    var backlogFloor = 0
    var takenThisSecond = 0
}
final class PublicationServer {
    static let remoteDeadAfter = 30.0, deadAfter = 30.0, remoteGrace = 30.0, graceAfterConnect = 30.0
    let queue = DispatchQueue(label: "actual.publication")
    var videoAdmission = VideoEpochAdmission.stopped
    var lastParameterSets: Data?
    var clients: [ObjectIdentifier: Client] = [:]
    // PUBLICATION_METHODS
}
@main struct Checks {
    static func main() {
        var checks = 0, failed = 0
        func expect(_ ok: Bool, _ label: String) {
            checks += 1; if !ok { failed += 1; print("FAIL " + label) }
        }
        for modern in [false, true] {
            for newer in [StreamSource.none, .window(72)] {
                let server = PublicationServer(), client = Client()
                client.presentationInput = modern
                server.clients[ObjectIdentifier(client.connection)] = client
                let old = SourcePublicationAdmission(), current = SourcePublicationAdmission()
                func catalog(_ source: StreamSource, _ revision: String) -> StreamMessage {
                    StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false,
                        payload: Wire.encode(WindowList(macName: "test", windows: [], active: source, selectionRevision: revision)))
                }
                server.queue.suspend()
                server.sendCatalog(catalog(.window(71), "old"), to: client.connection, admission: old)
                old.invalidate()
                server.sendCatalog(catalog(newer, "new"), to: client.connection, admission: current)
                server.queue.resume(); server.queue.sync {}
                let lists = client.connection.packets.compactMap { Wire.decode(WindowList.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
                expect(lists.count == 1 && lists[0].active == newer && lists[0].selectionRevision == "new",
                       "actual send boundary refuses queued obsolete catalog for legacy and presentation peers")
                expect(client.latestCatalog.flatMap { Wire.decode(WindowList.self, from: $0.payload) }?.active == newer,
                       "obsolete queued catalog cannot replace cached current snapshot")
                let sent = client.connection.packets.count
                current.invalidate()
                server.queue.sync { server.replayCatalog(to: client) }
                expect(client.connection.packets.count == sent, "invalidated cached admission cannot replay at hello")
                let fresh = SourcePublicationAdmission()
                server.sendCatalog(catalog(.window(73), "fresh"), to: client.connection, admission: fresh)
                server.queue.sync { server.replayCatalog(to: client) }
                expect(client.connection.packets.count == sent + 2, "current ordinary catalog and cached replay both reach recording wire")
            }
        }
        print("PUBLICATION_CHECKS total=\(checks) failed=\(failed)")
        if failed > 0 { exit(1) }
    }
}
