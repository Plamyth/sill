import Foundation
import StreamProtocol

final class DispatchWorkItem {
    var cancelled = false
    let action: () -> Void
    init(block: @escaping () -> Void) { action = block }
    func cancel() { cancelled = true }
    func run() { if !cancelled { action() } }
}
struct DispatchTime {
    var value: Double
    static func now() -> Self { .init(value: Clock.now) }
    static func + (lhs: Self, rhs: Double) -> Self { .init(value: lhs.value + rhs) }
}
struct DispatchQueue {
    var isMain = false
    static let main = DispatchQueue(isMain: true)
    func async(execute: @escaping () -> Void) {
        if isMain { Clock.main.append(execute) }
        else if Clock.networkPaused { Clock.network.append(execute) }
        else { execute() }
    }
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { Clock.events.append((deadline.value, execute)) }
    func asyncAfter(deadline: DispatchTime, execute: DispatchWorkItem) { asyncAfter(deadline: deadline) { execute.run() } }
}
struct ProcessInfo {
    static let processInfo = ProcessInfo()
    var systemUptime: Double { Clock.now }
}
enum Clock {
    static var now = 100.0
    static var main: [() -> Void] = []
    static var networkPaused = false
    static var network: [() -> Void] = []
    static var events: [(Double, () -> Void)] = []
    static func resumeNetwork() {
        networkPaused = false
        while !network.isEmpty { network.removeFirst()() }
    }
    static func flush() { while !main.isEmpty { main.removeFirst()() } }
    static func advance(_ seconds: Double) {
        now += seconds
        let due = events.filter { $0.0 <= now }; events.removeAll { $0.0 <= now }
        due.forEach { $0.1() }; flush()
    }
}
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any, forKey key: String) { values[key] = value }
}
enum Bundle {
    static let main = Self.bundle
    case bundle
    static var resource: URL?
    static var reads = 0
    func url(forResource name: String, withExtension ext: String) -> URL? {
        precondition(name == OwnerMacBootstrap.resourceName && ext == "json")
        Self.reads += 1
        return Self.resource
    }
}
struct RemoteIdentity {}
enum DeviceIdentity {
    static var present = true, missing = false, throwsOnCreate = false
    static var creates = 0, forgets = 0
    static func existing() -> RemoteIdentity? { present ? RemoteIdentity() : nil }
    static func knownMissing() -> Bool { missing }
    static func loadOrCreate() throws -> RemoteIdentity {
        creates += 1
        if throwsOnCreate { throw NSError(domain: "identity", code: 1) }
        present = true; missing = false
        return RemoteIdentity()
    }
    static func forget() { forgets += 1 }
}
enum UIDevice { static let current = Device(); struct Device { let name = "검사 iPad" } }
enum ClientStatsReporter { static let hardwareIdentifier = "iPadFixture" }
enum RemoteDialPolicy {
    // FAILURE_TYPE
    static func ownerTailnetScope(_ mac: SavedMac?) -> Bool { mac?.method == OwnerMacBootstrap.method }
    static let pairingReplyDeadline = 8.0
    struct Candidate { let host: String; let port: Int; let kind: String; let via: String; var key: String { "\(host)|\(port)" } }
}
final class NWConnection {
    enum State { case ready, waiting(Int), failed(Int), cancelled }
    enum Completion { case contentProcessed((Int?) -> Void) }
    typealias Read = (Data?, Int?, Bool, Int?) -> Void
    var stateUpdateHandler: ((State) -> Void)?
    var cancelled = false
    var pin = fixturePin
    var alpn: String? = OwnerMacBootstrap.alpn
    var reads: [Read] = []
    var sent: [Data] = []
    var sendError: Int?
    func cancel() { cancelled = true }
    func send(content: Data?, completion: Completion) { sent.append(content!); if case .contentProcessed(let done) = completion { done(sendError) } }
    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping Read) { reads.append(completion) }
    func deliver(_ data: Data?, ended: Bool = false, error: Int? = nil) { if !reads.isEmpty { reads.removeFirst()(data, nil, ended, error) } }
}
enum RemoteTLS {
    static func negotiatedALPN(_ c: NWConnection) -> String? { c.alpn }
    static func peerFingerprint(_ c: NWConnection) -> Data? { c.pin }
}
final class RemoteConnector {
    enum Mode { case ownerBootstrap(pin: Data) }
    struct Winner { let connection: NWConnection; let candidate: RemoteDialPolicy.Candidate; let fingerprint: Data }
    var onWinner: ((Winner) -> Void)?
    var onFailed: ((Int) -> Void)?
    let candidates: [RemoteDialPolicy.Candidate]
    var cancelled = false
    static var all: [RemoteConnector] = []
    init(candidates: [RemoteDialPolicy.Candidate], mode: Mode, identity: RemoteIdentity, queue: DispatchQueue) {
        self.candidates = candidates
        if case .ownerBootstrap(let pin) = mode { precondition(pin == fixturePin) }
        Self.all.append(self)
    }
    func start() {}
    func cancel() { cancelled = true }
    func win(_ c: NWConnection = NWConnection()) -> NWConnection {
        onWinner?(.init(connection: c, candidate: candidates[0], fingerprint: c.pin)); return c
    }
}
enum RemoteCopy {
    static func vpnLabel(_ candidate: RemoteDialPolicy.Candidate) -> String? { nil }
    static func dialFailure(_ failure: RemoteDialPolicy.Failure, mac: String, candidate: RemoteDialPolicy.Candidate?, vpnName: String?, device: String) -> String { "가짜 실패" }
}
enum DiscoveryPolicy {
    static let networkFirst = 3.0
    // RETRY_POLICY
    enum HomeDial { case pinned }
    enum HomeTrust { case saved(pin: Data) }
    enum Method { case network, nearby }
}
struct FoundMac { let route = DiscoveryPolicy.Method.network; let macID = ""; let carriesTag = false; let endpoint: Int? = nil }
final class StreamClient {
    static var manualPairingEnabled = true
    private var startupAutoConnection: StartupAutoConnection = .unarmed
    static let preferredTrustedMacKey = "Sill.preferredTrustedMacID"
    var ownerBootstrap = OwnerBootstrapState()
    var ownerBootstrapDial: RemoteConnector?
    var ownerBootstrapExchange: OwnerBootstrapExchange?
    var savedMacs: [SavedMac] = []
    var savedMacsSeeded = false
    let queue = DispatchQueue()
    var connected = false, appInForeground = true
    var ownerEnrollmentResumes = 0, ownerEnrollmentCancels = 0
    func resumeOwnerEnrollment() { ownerEnrollmentResumes += 1 }
    func cancelOwnerEnrollment() { ownerEnrollmentCancels += 1 }
    func invalidateIPadSentryReturn() {}
    var connection: NWConnection?
    struct Reconnect {
        var macID: String?
        var remoteAllowed = true
        var remoteFailures = 0
        var nextRemoteAt = 0.0
        var rowBudgets: [String: Int] = [:]
        var rowListing: String?
    }
    var reconnect: Reconnect?
    var remoteDial: Int?
    enum Pairing: Equatable { case idle, working, failed(Problem) }
    enum Problem: Equatable { case notALink, zone, address, codeLength, codeTypo }
    var pairing = Pairing.idle
    var pairingAttempt = 0
    var pairingDial: RemoteConnector?
    var homeAsk: Int?, overlayAskDialer: Int?, overlayAskShown: Int?, pendingLink: Int?
    var status = ""
    var macs: [FoundMac] = []
    var localNetworkDenied = false
    var searchingSince = 0.0
    var persists = 0
    var dials: [String] = []
    var dialReasons: [DialReason] = []
    var retryChecks = 0
    var afterPairingWatch: DispatchWorkItem?
    static let deviceWord = "iPad"
    func savedMac(_ id: String) -> SavedMac? { savedMacs.first { $0.macID == id } }
    func reconnectIfListed() { retryChecks += 1 }
    var browsing = false
    struct Life { var rebuildWork: DispatchWorkItem?; var settleWork: DispatchWorkItem? }
    var networkLife = Life(), nearbyLife = Life()
    var nearbyBrowser: Int?, reconnectCheck: DispatchWorkItem?, audioRouteAuthorization: Int?
    enum DialReason { case tap, automatic, afterPairing, connectRemotely, launchArgument }
    func lostReconnect(session: Int?, saved: SavedMac?, name: String, remoteAllowed: Bool) -> Reconnect { Reconnect(macID: saved?.macID, remoteAllowed: remoteAllowed) }
    func displayName(_ id: String) -> String { "fixture-Mac" }
    func dialSaved(_ id: String, why: DialReason) { cancelOwnerBootstrap(); dials.append(id); dialReasons.append(why) }
    func persistSavedMacs() { persists += 1; UserDefaults.standard.set(SavedMacs.encode(savedMacs), forKey: SavedMacs.defaultsKey) }
    func pair(link: PairLink, overlay: Bool) {}
    func pair(code: String, address: ParsedAddress, overlay: Bool) {}
    func cancelHomeAsk() {}
    func wiredDial(for row: FoundMac) -> Int? { nil }
    func homeDecision(_ row: FoundMac, macID: String, tap: Bool) -> DiscoveryPolicy.HomeDial { .pinned }
    func dialRow(_ row: FoundMac, macID: String, trust: DiscoveryPolicy.HomeTrust, tagNamed: Bool, tap: Bool) -> Bool { false }
    func rebuildIfDue(_ method: DiscoveryPolicy.Method, cameForward: Bool) {}
    func runBoundary(_ index: Int) {
        switch index {
        case 0: cancellationBoundary0()
        case 1: cancellationBoundary1()
        case 2: cancellationBoundary2()
        case 3: cancellationBoundary3()
        case 4: cancellationBoundary4()
        case 5: cancellationBoundary5()
        default: cancellationBoundary6()
        }
    }
    func discoveryChanged() { trySavedMacAutoConnect() }
    func tearDown(status: String, restartSearch: Bool) {}
    func cancelRemoteDial() {}
    // STARTUP_METHODS
}
