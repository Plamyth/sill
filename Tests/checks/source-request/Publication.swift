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
// QUERY_FIXTURE
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
                        payload: Wire.encode(WindowList(macName: "test", windows: [], active: source, selectionRevision: revision,
                            audioPrivacy: AudioPrivacyState(version: 2, protected: false, reason: "revoked"))))
                }
                server.queue.suspend()
                server.sendCatalog(catalog(.window(71), "old"), to: client.connection, admission: old)
                old.invalidate()
                server.sendCatalog(catalog(newer, "new"), to: client.connection, admission: current)
                server.queue.resume(); server.queue.sync {}
                let lists = client.connection.packets.compactMap { Wire.decode(WindowList.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
                expect(lists.count == 1 && lists[0].active == newer && lists[0].selectionRevision == "new",
                       "actual send boundary refuses queued obsolete catalog for legacy and presentation peers")
                expect(lists.first?.audioPrivacy == AudioPrivacyState(version: 2, protected: false, reason: "revoked"),
                       "current source catalog preserves privacy revocation through actual send encoding")
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
        for replay in [false, true] {
            let server = PublicationServer(), client = Client()
            client.presentationInput = true
            server.clients[ObjectIdentifier(client.connection)] = client
            let generation = UUID()
            let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
                geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
            server.videoAdmission = .committed(epoch)
            let grant = HostLocalOwnerGrant(epoch), id = UUID(), inventory = UUID()
            let message = StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false,
                payload: Wire.encode(WindowList(macName: "test", windows: [], active: .desktop,
                    selectionRevision: "source:77", inputGeneration: generation.uuidString,
                    videoEpoch: epoch, microphone: .init(peer: UUID(), destination: UUID(), generation: UUID()),
                    displays: [.init(id: 91, name: "fixture", width: 100, height: 100, isMain: true)],
                    displayInventoryID: inventory, activeDisplayID: 91,
                    audioPrivacy: .init(version: 2, protected: true), catalogRefresh: 1, responseRequestID: id)))
            let admission = SourcePublicationAdmission()
            if replay {
                server.sendCatalog(message, to: client.connection, admission: admission, grant: grant)
                server.queue.sync {}
                client.connection.packets.removeAll()
                grant.valid = false
                server.queue.sync { server.replayCatalog(to: client) }
            } else {
                server.queue.suspend()
                server.sendCatalog(message, to: client.connection, admission: admission, grant: grant)
                grant.valid = false
                server.queue.resume(); server.queue.sync {}
            }
            let lists = client.connection.packets.compactMap {
                Wire.decode(WindowList.self, from: Data($0.dropFirst(StreamMessage.headerLength)))
            }
            expect(lists.count == 1, "query expiry must still answer, actual count=\(lists.count), replay=\(replay)")
            expect(lists.first?.responseRequestID == id && lists.first?.microphone == nil &&
                   lists.first?.audioPrivacy == nil,
                   "query expiry response keeps correlation and strips stale microphone/protection, replay=\(replay)")
            expect(lists.first?.selectionRevision == "source:77" && lists.first?.displayInventoryID == inventory &&
                   lists.first?.activeDisplayID == 91,
                   "query fallback preserves source CAS and display inventory, replay=\(replay)")
        }
        for stale in ["source", "generation", "epoch", "plain", "pin", "admission"] {
            let server = PublicationServer(), client = Client()
            server.clients[ObjectIdentifier(client.connection)] = client
            let epoch = VideoEpoch(generation: UUID().uuidString, source: .desktop,
                geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
            server.videoAdmission = .committed(epoch)
            let admission = SourcePublicationAdmission(), grant = HostLocalOwnerGrant(epoch)
            let message = StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false,
                payload: Wire.encode(WindowList(macName: "fixture", windows: [], active: .desktop,
                    inputGeneration: epoch.generation, videoEpoch: epoch, responseRequestID: UUID())))
            server.queue.suspend()
            server.sendCatalog(message, to: client.connection, admission: admission, grant: grant)
            switch stale {
            case "source":
                server.videoAdmission = .committed(.init(id: epoch.id, generation: epoch.generation, source: .window(73),
                    geometry: epoch.geometry, width: 100, height: 100))
            case "generation":
                server.videoAdmission = .committed(.init(id: epoch.id, generation: UUID().uuidString, source: .desktop,
                    geometry: epoch.geometry, width: 100, height: 100))
            case "epoch": server.videoAdmission = .stopped
            case "plain": client.route.encrypted = false
            case "pin": client.route.fingerprint = Data([2])
            default: admission.invalidate()
            }
            server.queue.resume(); server.queue.sync {}
            expect(client.connection.packets.isEmpty, "queued query cannot cross stale \(stale) boundary")
        }
        queryChecks(expect)
        print("PUBLICATION_CHECKS total=\(checks) failed=\(failed)")
        if failed > 0 { exit(1) }
    }
}
