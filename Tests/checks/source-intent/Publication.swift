import Foundation

final class NWConnection {
    enum State { case ready, cancelled }
    enum Completion { case contentProcessed((Error?) -> Void) }
    var state = State.ready
    let endpoint = "recording-wire"
    var packets: [Data] = []
    func cancel() {}
    func send(content: Data, completion: Completion) {
        packets.append(content)
        if case .contentProcessed(let done) = completion { done(nil) }
    }
}
struct Route {
    var encrypted = true
    var fingerprint: Data? = Data([1])
    let isRemote = false
}
final class HostLocalOwnerGrant {
    struct Scope {
        let videoEpoch: UUID
        let source: StreamSource
        let inputGeneration: UUID
        let peer: UUID
        let destination = UUID()
        let capability = UUID()
    }
    let fingerprint = Data([1])
    let scope: Scope
    var valid = true
    init(_ epoch: VideoEpoch, peer: UUID = UUID()) {
        scope = Scope(videoEpoch: epoch.id, source: epoch.source,
                      inputGeneration: UUID(uuidString: epoch.generation)!, peer: peer)
    }
    func valid(at: UInt64) -> Bool { valid }
    func whileValid(at: UInt64, _ body: () -> Void) -> Bool {
        guard valid else { return false }; body(); return true
    }
}
final class Client {
    let connection = NWConnection()
    var route = Route()
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
    let remoteAudioDrain = DispatchGroup()
    var videoAdmission = VideoEpochAdmission.stopped
    var lastParameterSets: Data?
    var clients: [ObjectIdentifier: Client] = [:]
    // PUBLICATION_METHODS
}
@main struct PublicationChecks {
    static func main() {
        var checks = 0
        func expect(_ ok: Bool, _ label: String) { checks += 1; if !ok { fatalError(label) } }
        for modern in [false, true] {
            let server = PublicationServer(), client = Client()
            client.presentationInput = modern
            server.clients[ObjectIdentifier(client.connection)] = client
            func catalog(_ source: StreamSource, _ revision: String) -> StreamMessage {
                .init(kind: .windowList, timestamp: 0, isKeyframe: false,
                      payload: Wire.encode(WindowList(macName: "test", windows: [], active: source, selectionRevision: revision)))
            }
            let peerAdmission = SourcePublicationAdmission { client.connection.state == .ready }
            server.queue.suspend()
            server.sendCatalog(catalog(.desktop, "departed"), to: client.connection, admission: peerAdmission)
            client.connection.state = .cancelled
            server.queue.resume(); server.queue.sync {}
            expect(client.connection.packets.isEmpty, "departed peer cannot publish through delayed queue")
            client.connection.state = .ready
            let old = SourcePublicationAdmission(), current = SourcePublicationAdmission()
            server.queue.suspend()
            server.sendCatalog(catalog(.window(71), "old"), to: client.connection, admission: old)
            old.invalidate()
            server.sendCatalog(catalog(.none, "new"), to: client.connection, admission: current)
            server.queue.resume(); server.queue.sync {}
            let lists = client.connection.packets.compactMap { Wire.decode(WindowList.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
            expect(lists.count == 1 && lists[0].active == .none && lists[0].selectionRevision == "new", "queued obsolete catalog blocked for both peer formats")
            let sent = client.connection.packets.count
            current.invalidate()
            server.queue.sync { server.replayCatalog(to: client) }
            expect(client.connection.packets.count == sent, "invalid cached catalog never replays")
            let epoch = VideoEpoch(generation: UUID().uuidString, source: .desktop,
                geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
            server.videoAdmission = .preparing(epoch)
            let stale = SourcePublicationAdmission()
            var keyframes = 0
            server.queue.suspend()
            server.commitVideo(epoch, catalog: catalog(.desktop, "stale"), admission: stale) { keyframes += 1 }
            stale.invalidate()
            server.queue.resume(); server.queue.sync {}
            expect(server.videoAdmission.current == nil && keyframes == 0, "queue delay invalidates commit before publication")
            expect(client.connection.packets.count == sent, "invalid epoch sends no catalog")
            let valid = SourcePublicationAdmission()
            server.commitVideo(epoch, catalog: catalog(.desktop, "valid"), admission: valid) { keyframes += 1 }
            server.queue.sync {}
            expect(server.videoAdmission.current == epoch && keyframes == 1, "current commit still works")
            let committedCount = client.connection.packets.count
            valid.invalidate()
            server.queue.sync { server.replayCatalog(to: client) }
            expect(client.connection.packets.count == committedCount, "commit cache keeps original admission")
            let grant = HostLocalOwnerGrant(epoch)
            let microphone = SourcePublicationAdmission()
            server.queue.suspend()
            server.sendMicrophoneCatalog(catalog(.desktop, "mic"), to: client.connection, grant: grant, admission: microphone)
            microphone.invalidate()
            server.queue.resume(); server.queue.sync {}
            expect(client.connection.packets.count == committedCount, "source change fences pending microphone catalog")
        }
        print("production publication checks passed=\(checks)")
    }
}
