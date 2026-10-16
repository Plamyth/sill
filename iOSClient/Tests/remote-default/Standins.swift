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
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { Clock.events.append((deadline.value, execute)) }
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
}
enum SavedMacs {
    static func automaticTarget(_ list: [SavedMac], preferredID: String?) -> SavedMac? {
        list.first { $0.eligible && $0.fingerprintData != nil && (preferredID == nil || $0.macID == preferredID) }
    }
}
enum NWEndpoint: Equatable { case cable, bonjour }
final class NWConnection {
    enum State { case preparing, ready, cancelled }
    var state: State = .preparing
    func cancel() { state = .cancelled }
}
struct HomeRow {}
struct Session { var macID: String? }
struct FoundMac {
    enum Route { case network, direct, remote }
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
    var reconnect: Int?
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
    var dialSucceeds = true
    var securityHandled = false
    struct Goodbye { var reason: String }
    var goodbye: Goodbye?
    enum DialReason { case tap }
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
    func dialSaved(_ id: String, why: DialReason) { remoteDials.append(id); remoteDial = 1 }
    func tearDown(status: String, restartSearch: Bool) { self.status = status; session = nil }
    func evaluate() { trySavedMacAutoConnect() }
    func stop() { startupAutoConnection = .stopped }
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
