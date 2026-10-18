struct QueryRoute {
    var encrypted = true
    var fingerprint: Data? = Data([1])
}
final class QueryRemote {
    var paired = true
    func isPaired(_ fingerprint: Data) -> Bool { paired && fingerprint == Data([1]) }
}
final class QueryPrivacy {
    var state = AudioPrivacyState(version: 2, protected: true)
    var repairs = 0
    func verify() -> Bool { repairs += 1; return false }
}
final class QueryIngress {
    struct Peer { let id: UUID }
    var current: Peer?
    func peer(_ connection: NWConnection) -> Peer? { current }
}
final class QueryReceiver {
    var grant: HostLocalOwnerGrant?
    var reads = 0
    func advertisedGrant(peer: UUID) -> HostLocalOwnerGrant? { reads += 1; return grant }
}
final class QueryServer {
    var messages: [StreamMessage] = []
    var grants: [HostLocalOwnerGrant?] = []
    func sendCatalog(_ message: StreamMessage, to connection: NWConnection,
                     admission: SourcePublicationAdmission, grant: HostLocalOwnerGrant?) {
        messages.append(message); grants.append(grant)
    }
}
final class QueryHost {
    let server = QueryServer()
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var routes: [ObjectIdentifier: QueryRoute] = [:]
    var remote: QueryRemote? = QueryRemote()
    var audioPrivacy: QueryPrivacy? = QueryPrivacy()
    let microphoneIngress = QueryIngress()
    let microphoneReceiver = QueryReceiver()
    var synthetic = false, shuttingDown = false, switching = false
    let sourcePublicationAdmission = SourcePublicationAdmission()
    var active = StreamSource.desktop
    var inputGeneration: String
    var videoEpoch: VideoEpoch?
    let connection = NWConnection()
    let inventory = UUID()
    init() {
        let generation = UUID()
        inputGeneration = generation.uuidString
        let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
            geometry: .init(x: -100, y: 0, width: 100, height: 100), width: 100, height: 100)
        videoEpoch = epoch
        let grant = HostLocalOwnerGrant(epoch)
        microphoneReceiver.grant = grant
        microphoneIngress.current = .init(id: grant.scope.peer)
        connections[ObjectIdentifier(connection)] = connection
        routes[ObjectIdentifier(connection)] = QueryRoute()
    }
    func listMessage() -> StreamMessage {
        .init(kind: .windowList, timestamp: 0, isKeyframe: false,
            payload: Wire.encode(WindowList(macName: "fixture", windows: [], active: active,
                selectionRevision: "query:9", inputGeneration: inputGeneration, videoEpoch: videoEpoch,
                displays: [.init(id: 91, name: "fixture", width: 100, height: 100, isMain: true)],
                displayInventoryID: inventory, activeDisplayID: 91,
                dockApps: [.init(name: "fixture", bundleID: "fixture.app")],
                audioPrivacy: audioPrivacy?.state, catalogRefresh: 1)))
    }
    // QUERY_METHOD
}

func queryChecks(_ expect: (Bool, String) -> Void) {
    let badRequests: [(String, (QueryHost) -> Void, Data?)] = [
        ("plain", { $0.routes[ObjectIdentifier($0.connection)]!.encrypted = false }, nil),
        ("unpaired", { $0.remote!.paired = false }, nil),
        ("missing-pin", { $0.routes[ObjectIdentifier($0.connection)]!.fingerprint = nil }, nil),
        ("wrong-pin", { $0.routes[ObjectIdentifier($0.connection)]!.fingerprint = Data([2]) }, nil),
        ("unregistered", { $0.connections.removeAll() }, nil),
        ("synthetic", { $0.synthetic = true }, nil),
        ("shutdown", { $0.shuttingDown = true }, nil),
        ("oversize", { _ in }, Data(repeating: 32, count: 257)),
        ("malformed", { _ in }, Data(#"{"requestID":"invalid"}"#.utf8))
    ]
    for (label, prepare, bytes) in badRequests {
        let host = QueryHost(), request = UUID()
        prepare(host)
        host.refreshCatalog(.init(kind: .fetchCatalog, timestamp: 0, isKeyframe: false,
            payload: bytes ?? Wire.encode(FetchCatalog(requestID: request))), from: host.connection)
        expect(host.server.messages.isEmpty, "read-only query refuses \(label)")
        expect(host.audioPrivacy?.repairs == 0 && host.microphoneReceiver.reads == 0,
               "refused query cannot repair HAL or inspect a grant: \(label)")
    }
    let unavailable: [(String, (QueryHost) -> Void)] = [
        ("missing-grant", { $0.microphoneReceiver.grant = nil }),
        ("revoked", { $0.microphoneReceiver.grant!.valid = false }),
        ("wrong-peer", { $0.microphoneIngress.current = .init(id: UUID()) }),
        ("source-changed", { $0.active = .window(74) }),
        ("epoch-changed", { $0.videoEpoch = nil }),
        ("generation-changed", { $0.inputGeneration = UUID().uuidString }),
        ("switching", { $0.switching = true }),
        ("legacy-privacy", { $0.audioPrivacy!.state.version = 1 }),
        ("future-privacy", { $0.audioPrivacy!.state.version = 3 }),
        ("unprotected", { $0.audioPrivacy!.state.protected = false }),
        ("absent-privacy", { $0.audioPrivacy = nil })
    ]
    for (label, prepare) in unavailable {
        let host = QueryHost(), request = UUID()
        prepare(host)
        host.refreshCatalog(.init(kind: .fetchCatalog, timestamp: 0, isKeyframe: false,
            payload: Wire.encode(FetchCatalog(requestID: request))), from: host.connection)
        let list = host.server.messages.first.flatMap { Wire.decode(WindowList.self, from: $0.payload) }
        expect(host.server.messages.count == 1 && list?.responseRequestID == request,
               "unavailable microphone still answers correlated query: \(label)")
        expect(list?.microphone == nil && host.server.grants.first.flatMap({ $0 }) == nil,
               "query cannot create a replacement grant: \(label)")
        expect((host.audioPrivacy?.repairs ?? 0) == 0, "query cannot schedule HAL repair: \(label)")
    }
    let host = QueryHost(), request = UUID()
    let grant = host.microphoneReceiver.grant!
    host.refreshCatalog(.init(kind: .fetchCatalog, timestamp: 0, isKeyframe: false,
        payload: Wire.encode(FetchCatalog(requestID: request))), from: host.connection)
    let list = host.server.messages.first.flatMap { Wire.decode(WindowList.self, from: $0.payload) }
    expect(list?.responseRequestID == request && list?.catalogRefresh == 1 &&
           list?.microphone?.generation == grant.scope.capability && host.server.grants.first.flatMap({ $0 }) === grant,
           "paired query advertises only the exact already-live grant")
    expect(list?.selectionRevision == "query:9" && list?.displayInventoryID == host.inventory &&
           list?.dockApps?.first?.bundleID == "fixture.app" && list?.audioPrivacy?.version == 2,
           "query preserves canonical source/display/Dock/privacy fields")
    expect(host.audioPrivacy?.repairs == 0, "positive query remains read-only")
    expect(StreamMessage.clientPayloadLimit(for: .fetchCatalog) == 256 &&
           StreamMessage.hostPayloadLimit(for: .fetchCatalog) == -1,
           "query uses reserved212 client-only bounded wire contract")
    host.refreshCatalog(.init(kind: .fetchCatalog, timestamp: 0, isKeyframe: false,
        payload: Wire.encode(FetchCatalog(requestID: request))), from: host.connection)
    expect(host.server.messages.count == 2 && host.server.grants.last.flatMap({ $0 }) === grant &&
           host.audioPrivacy?.repairs == 0, "repeating a query cannot renew its grant or repair hardware")
    let legacy = Wire.decode(WindowList.self, from: Data(#"{"macName":"old","windows":[],"active":{"none":{}}}"#.utf8))
    expect(legacy != nil && legacy?.catalogRefresh == nil && legacy?.responseRequestID == nil,
           "older catalogs remain decodable without query fields")
}
