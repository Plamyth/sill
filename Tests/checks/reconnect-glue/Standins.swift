import Foundation

enum Clock {
    static var now = 100.0
    static var events: [(Double, DispatchWorkItem)] = []
    static func reset() { now = 100; events = [] }
    static func advance(_ seconds: Double) {
        let end = now + seconds
        var steps = 0
        while let next = events.enumerated().filter({ $0.element.0 <= end }).min(by: { $0.element.0 < $1.element.0 }) {
            events.remove(at: next.offset)
            now = next.element.0
            next.element.1.perform()
            steps += 1
            precondition(steps < 2000, "unbounded same-time scheduling")
        }
        now = end
    }
    static var pending: Int { events.filter { !$0.1.cancelled }.count }
}
struct ProcessInfo {
    static let processInfo = ProcessInfo()
    var systemUptime: Double { Clock.now }
}
struct DispatchTime {
    var value: Double
    static func now() -> Self { Self(value: Clock.now) }
    static func + (lhs: Self, rhs: Double) -> Self { Self(value: lhs.value + rhs) }
}
final class DispatchWorkItem {
    var cancelled = false
    let body: () -> Void
    init(block: @escaping () -> Void) { body = block }
    func cancel() { cancelled = true }
    func perform() { if !cancelled { body() } }
}
struct DispatchQueue {
    static let main = DispatchQueue()
    func asyncAfter(deadline: DispatchTime, execute: DispatchWorkItem) { Clock.events.append((deadline.value, execute)) }
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { asyncAfter(deadline: deadline, execute: DispatchWorkItem(block: execute)) }
    func async(execute: @escaping () -> Void) { asyncAfter(deadline: .now(), execute: execute) }
}
enum NWError: Error { case dns(Int32) }
final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
typealias DNSServiceErrorType = Int32
let kDNSServiceErr_PolicyDenied: Int32 = -65570
final class NWParameters { var includePeerToPeer = false }
final class NWBrowser {
    enum Descriptor { case bonjourWithTXTRecord(type: String, domain: String?) }
    enum State { case ready, failed(NWError), waiting(NWError), cancelled }
    struct Result: Hashable { var name: String }
    var browseResultsChangedHandler: ((Set<Result>, Set<Result>) -> Void)?
    var stateUpdateHandler: ((State) -> Void)?
    var cancelled = false
    init(for descriptor: Descriptor, using: NWParameters) {}
    func start(queue: DispatchQueue) {}
    func cancel() { cancelled = true }
}
final class NWConnection {
    enum State { case preparing, ready }
    var state: State = .preparing
    func cancel() {}
}
final class RemoteConnector { func cancel() {} }
struct FoundMac {
    enum Route { case network, direct }
    var route: Route = .network
    var name = "Mac"
    var macID: String? = "saved"
    var carriesTag = true
    var id: String { name }
    var direct: Bool { route == .direct }
    var endpoint: String? = "fake"
}
struct Session {
    enum Route { case network, remote; var isRemote: Bool { self == .remote } }
    var why: DialReason?
    var route = Route.network
}
enum DialReason { case automatic }
struct SavedMac { var fingerprintData: Data? = Data([1]); var newKey = false }
struct Sightings { var since: [String: Double] = ["Mac": 100]; var leftAt: [String: Double] = [:] }
final class StreamClient {
    static let serviceType = "_sill._tcp"
    static let deviceWord = "Vision"
    static let reconnectDialWait = 5.0
    let queue = DispatchQueue()
    var reconnect: Reconnect?
    var reconnectCheck: DispatchWorkItem?
    var connected = false
    var moveUnderWay = false
    var connection: NWConnection?
    var session: Session?
    var remoteDial: RemoteConnector?
    var pinRefusedRows: Set<String> = []
    var macs = [FoundMac()]
    var sightings = Sightings()
    var savedSightings = Sightings()
    var directSince: [String: Double] = [:]
    var pathSignature = "wifi"
    var localNetworkDenied = false
    var searchingSince = 100.0
    var status = "Reconnecting"
    var hostName = "Mac"
    var rowDials: [Double] = []
    var remoteDials: [Double] = []
    var decision = DiscoveryPolicy.HomeDial.pinned
    static func serviceName(of result: NWBrowser.Result) -> String { result.name }
    func savedMac(_ id: String) -> SavedMac? { SavedMac() }
    func homeDecision(_ mac: FoundMac, macID: String?, tap: Bool) -> DiscoveryPolicy.HomeDial { decision }
    func cancelRemoteDial() { remoteDial?.cancel(); remoteDial = nil }
    func dial(_ mac: FoundMac, macID: String?, tap: Bool) -> Bool {
        rowDials.append(Clock.now)
        let c = NWConnection()
        connection = c
        armTimeout(c, name: mac.name)
        return true
    }
    func dialSaved(_ id: String, why: DialReason) {
        remoteDials.append(Clock.now)
        remoteDial = RemoteConnector()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.remoteDial != nil else { return }
            self.remoteDial = nil
            if var r = self.reconnect {
                r.remoteFailures += 1
                r.nextRemoteAt = Clock.now + DiscoveryPolicy.remoteRetryDelay(afterFailures: r.remoteFailures)
                self.reconnect = r
            }
            self.reconnectIfListed()
        }
    }
    func tearDown(status: String, restartSearch: Bool = true) { connection = nil; session = nil; self.status = status }
    func updateDiscovery() {}
    func startPathMonitor() {}
    func discoveryChanged() { reconnectIfListed() }
    func seed(saved: Bool = true) {
        reconnect = Reconnect(macID: saved ? "saved" : nil, bonjourName: "Mac", name: "Mac", lostAt: Clock.now,
                              pathAtLoss: pathSignature, remoteAllowed: saved, rememberedDirect: false)
    }
    func browserIdentity() -> ObjectIdentifier? { networkBrowser.map(ObjectIdentifier.init) }
    func browserHandle() -> NWBrowser? { networkBrowser }
    func failBrowser() { networkBrowser?.stateUpdateHandler?(.failed(.dns(-65569))) }
    func report(_ names: [String]) { networkBrowser?.browseResultsChangedHandler?(Set(names.map { NWBrowser.Result(name: $0) }), []) }
    func rows() -> [String] { networkResults.map(\.name).sorted() }
}
