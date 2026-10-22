import Foundation

enum Clock {
    static var now = 100.0
    static var events: [(Double, () -> Void)] = []
    static func reset() { now = 100; events = []; DeviceIdentity.available = true; UserDefaults.standard.values = [:] }
    static func advance(_ seconds: Double) {
        let end = now + seconds
        while let event = events.enumerated().filter({ $0.element.0 <= end }).min(by: { $0.element.0 < $1.element.0 }) {
            events.remove(at: event.offset)
            now = event.element.0
            event.element.1()
        }
        now = end
    }
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
struct DispatchQueue {
    static let main = DispatchQueue()
    func asyncAfter(deadline: DispatchTime, execute: DispatchWorkItem) { asyncAfter(deadline: deadline) { execute.perform() } }
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { Clock.events.append((deadline.value, execute)) }
}
final class DispatchWorkItem {
    var cancelled = false
    let block: () -> Void
    init(block: @escaping () -> Void) { self.block = block }
    func cancel() { cancelled = true }
    func perform() { if !cancelled { block() } }
}
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
}
enum DeviceIdentity {
    static var available = true
    static func existing() -> Int? { available ? 1 : nil }
}
struct SavedMac {
    var macID = "trusted"
    var fingerprintData: Data? = Data([1, 2, 3])
    var eligible = true
    var newKey: Bool?
    var revoked: Bool?
    var method = "qr"
    var bonjourName: String?
    var allAddresses: [RemoteDialPolicy.Candidate] = []
}
enum SavedMacs {
    static func automaticTarget(_ list: [SavedMac], preferredID: String?) -> SavedMac? {
        list.first { $0.eligible && $0.fingerprintData != nil && (preferredID == nil || $0.macID == preferredID) }
    }
}
enum RemoteDialPolicy {
    // FAILURE_TYPE
    struct Candidate { var host: String; var port: Int; var kind: String; var via: String; var key: String { host } }
    static func ownerTailnetScope(_ mac: SavedMac?) -> Bool { mac?.method == "owner-tailnet-v1" } }
enum RemoteCopy {
    static func vpnLabel(_ candidate: RemoteDialPolicy.Candidate) -> String? { nil }
    static func dialFailure(_ failure: RemoteDialPolicy.Failure, mac: String, candidate: RemoteDialPolicy.Candidate?, vpnName: String?, device: String) -> String { "fixture failure" }
}
enum NWEndpoint: Equatable { case cable, bonjour }
final class NWConnection {
    enum State { case preparing, ready, cancelled }
    var state: State = .preparing
    func cancel() { state = .cancelled }
}
struct HomeRow {}
struct Session { var macID: String?; var bonjourName: String?; var why: StreamClient.DialReason? }
struct FoundMac {
    enum Route { case network, direct, remote }
    var id = "fixture-row"
    var direct: Bool { route == .direct }
    var savedID: String? { macID }
    var route = Route.network
    var macID: String? = "trusted"
    var carriesTag = true
    var endpoint: NWEndpoint? = .bonjour
    var name = "Mac"
    var cable = false
    var decision = DiscoveryPolicy.HomeDial.pinned
}
final class StreamClient {
    private var startupAutoConnection: StartupAutoConnection = .unarmed
    private static let preferredTrustedMacKey = "Sill.preferredTrustedMacID"
    var savedMacs = [SavedMac()]
    var appInForeground = true
    var connected = false
    var connection: NWConnection?
    // EXTRACTED_STARTUP_DIAL
    // RECONNECT_TYPE
    var reconnect: Reconnect?
    var reconnectCheck: DispatchWorkItem?
    var afterPairingWatch: DispatchWorkItem?
    var pathSignature = "fixture-path"
    var directWirelessMacs: Set<String> = []
    var moveUnderWay = false
    var pinRefusedRows: Set<String> = []
    struct Sightings { var since: [String: Double] = [:]; var leftAt: [String: Double] = [:] }
    var sightings = Sightings(), savedSightings = Sightings()
    var directSince: [String: Double] = [:]
    static let deviceWord = "iPad"
    static let lookingOnNetwork = "fixture-search"
    func savedMac(_ id: String) -> SavedMac? { savedMacs.first { $0.macID == id } }
    func displayName(_ id: String) -> String { "fixture-Mac" }
    func discoveryChanged() {}
    func updateDiscovery() {}
    func cancelOwnerBootstrap() {}
    func cancelHomeAsk() {}
    var hostName = "fixture-Mac"
    func cancelRemoteDial() { remoteDial = nil }
    func dial(_ row: FoundMac, macID: String?, tap: Bool) -> Bool {
        dialRow(row, macID: macID, trust: .saved(pin: Data([1, 2, 3])), tagNamed: true, tap: tap)
    }
    enum Pairing { case idle, working }
    var pairing = Pairing.idle
    var pairingDial: Int?
    var pendingLink: Int?
    var homeAsk: Int?
    var remoteDial: Int?
    var session: Session?
    var status = ""
    var searchingSince = 100.0
    var localNetworkDenied = false
    var macs: [FoundMac] = []
    var homeDials: [(NWEndpoint, DiscoveryPolicy.HomeTrust)] = []
    var remoteDials: [String] = []
    var reasons: [DialReason] = []
    var dialSucceeds = true
    var securityHandled = false
    struct Goodbye { var reason: String }
    var goodbye: Goodbye?
    enum DialReason { case tap, automatic, afterPairing, connectRemotely, launchArgument }
    func startOwnerBootstrap() {}
    func homeDecision(_ row: FoundMac, macID: String?, tap: Bool) -> DiscoveryPolicy.HomeDial { row.decision }
    func wiredDial(for row: FoundMac) -> (endpoint: NWEndpoint, via: String)? { row.cable ? (.cable, "cable") : nil }
    func dialRow(_ row: FoundMac, macID: String?, trust: DiscoveryPolicy.HomeTrust, tagNamed: Bool, tap: Bool) -> Bool {
        connect(to: row.cable ? .cable : .bonjour, name: row.name, macID: macID, trust: trust, row: nil)
    }
    @discardableResult
    func connect(to endpoint: NWEndpoint, name: String, macID: String?, trust: DiscoveryPolicy.HomeTrust, row: HomeRow?) -> Bool {
        guard dialSucceeds else { return false }
        homeDials.append((endpoint, trust))
        connection = NWConnection()
        session = Session(macID: macID)
        return true
    }
    // DIAL_SAVED_ENTRY
    func failRemote(_ failure: RemoteDialPolicy.Failure) {
        guard let why = reasons.last, let id = remoteDials.last else { return }
        remoteDial = nil
        remoteDialFailed(macID: id, why: why, failure: failure, candidate: nil)
    }
    func tearDown(status: String, restartSearch: Bool = true) { self.status = status; session = nil }
    var startupAttempted: Bool { if case .attempted = startupAutoConnection { return true }; return false }
    func evaluate() { trySavedMacAutoConnect() }
    func stop() { disconnect() }
    func homeSessionEnded(_ session: Session?, error: Int?, goodbye: String?) -> Bool { securityHandled }
    func closedBeforeAdmission() {
        connection = nil
        let s = session
        let error: Int? = nil
        let goodbye = self.goodbye
        // EXTRACTED_SESSION_END
    }
    func cableUnavailable(_ c: NWConnection) {
        dialUnconstrained(after: c, .bonjour, name: "Mac", macID: "trusted", trust: .saved(pin: Data([1, 2, 3])), row: nil, why: "unavailable")
    }
    // EXTRACTED_METHODS
}
