import Foundation
import StreamProtocol

enum Clock {
    static var now = 100.0
    static var events: [(Double, DispatchWorkItem)] = []
    static func reset() { now = 100; events = [] }
    static var pending: Int { events.filter { !$0.1.cancelled }.count }
    static func advance(_ seconds: Double) {
        let until = now + seconds
        var steps = 0
        while let event = events.enumerated().filter({ $0.element.0 <= until }).min(by: { $0.element.0 < $1.element.0 }) {
            events.remove(at: event.offset); now = event.element.0
            event.element.1.perform(); steps += 1
            precondition(steps < 2000, "same-time timer loop")
        }
        now = until
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
}
enum NWError: Error { case posix(POSIXErrorCode), tls(Int32), dns(Int32) }
final class NWConnection { func cancel() {} }
final class RemoteConnector {
    var cancelled = false
    func cancel() { cancelled = true }
    static func end(of error: NWError) -> RemoteDialPolicy.End {
        switch error {
        case .posix(let code): return .posix(code.rawValue)
        case .tls(let code): return .tls(code)
        case .dns(let code): return .dns(code)
        }
    }
}
enum DeviceIdentity { static var available = true; static func existing() -> Int? { available ? 1 : nil } }
struct FoundMac {
    enum Route { case network, direct }
    var route = Route.network
    var name = "Mac"
    var macID: String?
    var carriesTag = true
    var id: String { name }
    var endpoint: Int? = 1
    var direct: Bool { route == .direct }
}
enum DialReason { case automatic, afterPairing, tap, connectRemotely, launchArgument }
struct Session {
    enum Route { case network, remote; var isRemote: Bool { self == .remote } }
    var route = Route.remote
    var macID: String?
    var why: DialReason? = .automatic
    var candidate: RemoteDialPolicy.Candidate?
    var bonjourName: String? = "Mac"
    var home: DiscoveryPolicy.HomeTrust?
}
struct BrowserLife { var rebuildWork: DispatchWorkItem?; var settleWork: DispatchWorkItem? }
enum Pairing { case idle }
struct Notice { let text: String; let storeLink: Bool }
final class StreamClient {
    static let deviceWord = "iPad"
    let targetID: String
    var saved: SavedMac
    var savedMacs: [SavedMac] { get { [saved] } set { if let first = newValue.first { saved = first } } }
    let candidate = RemoteDialPolicy.Candidate(host: "100.64.1.2", port: 7455, kind: MacAddress.vpn, via: "Tailscale")
    var connection: NWConnection?
    var session: Session?
    var remoteDial: RemoteConnector?
    var reconnect: Reconnect?
    var reconnectCheck: DispatchWorkItem?
    var firstListDeadline: DispatchWorkItem?
    var afterPairingWatch: DispatchWorkItem?
    var connected = false
    var moveUnderWay = false
    var appInForeground = true
    var macs: [FoundMac] = []
    var pinRefusedRows: Set<String> = []
    var sightings = DiscoveryPolicy.NetworkSightings()
    var savedSightings = DiscoveryPolicy.NetworkSightings()
    var directSince: [String: Double] = [:]
    var directWirelessMacs: [String] = []
    var pathSignature = "wifi"
    var hostName = "Mac"
    var status = "대기"
    var goodbye: Goodbye?
    var notice: Notice?
    var pairing = Pairing.idle
    var browsing = false
    var nearbyBrowser: Int?
    var networkLife = BrowserLife()
    var nearbyLife = BrowserLife()
    var remoteDials: [Double] = []
    var onDial: ((StreamClient) -> Void)?
    init(owner: Bool = true) {
        let pin = Data(repeating: 7, count: 32)
        targetID = MacID.make(fingerprint: pin)
        saved = SavedMac(macID: targetID, fingerprint: Base64URL.encode(pin), name: "Mac",
                         recognitionKey: Base64URL.encode(Data(repeating: 8, count: 32)), remotePort: 7455,
                         addresses: [MacAddress(host: "100.64.1.2", kind: MacAddress.vpn, via: "Tailscale")],
                         infoIssuedAt: 0, bonjourName: "Mac", pairedAt: Date(),
                         method: owner ? OwnerMacBootstrap.method : "qr", homeTLS: true)
    }
    func savedMac(_ id: String) -> SavedMac? { saved.macID == id ? saved : nil }
    func displayName(_ id: String) -> String { "Mac" }
    func homeDecision(_ mac: FoundMac, macID: String?, tap: Bool) -> DiscoveryPolicy.HomeDial { .pinned }
    func dial(_ mac: FoundMac, macID: String?, tap: Bool) -> Bool { dialSaved(targetID, why: .automatic); return true }
    func dialSaved(_ id: String, why: DialReason) {
        remoteDials.append(Clock.now); remoteDial = RemoteConnector()
        if let onDial { onDial(self) } else { fail([.posix(ECONNREFUSED)]) }
    }
    func tearDown(status: String, restartSearch: Bool = true) { connection = nil; session = nil; connected = false; self.status = status }
    func updateDiscovery() {}
    func discoveryChanged() { reconnectIfListed() }
    func scheduleReconnectRetry() { reconnectIfListed() }
    func homeSessionEnded(_ s: Session?, error: NWError?, goodbye: String?) -> Bool { false }
    func persistSavedMacs() {}
    enum BrowserKind { case network, nearby }
    func rebuildIfDue(_ kind: BrowserKind, cameForward: Bool) {}

