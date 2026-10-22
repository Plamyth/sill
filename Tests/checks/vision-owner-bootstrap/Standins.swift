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
struct RemoteIdentity { let fingerprint = DeviceIdentity.fingerprint }
enum DeviceIdentity {
    static var fingerprint = Data(repeating: 0x41, count: 32)
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

enum VisionReleaseTestContext { static var isTestBundle = false }
final class StreamClient {
    var ownerBootstrap = OwnerBootstrapState()
    var ownerBootstrapDial: RemoteConnector?
    var ownerBootstrapExchange: OwnerBootstrapExchange?
    var savedMacs: [SavedMac] = []
    var savedMacsSeeded = false
    let queue = DispatchQueue()
    var connected = false, appInForeground = true, visionStartupForeground = true, visionWindowRetired = false
    var connection: NWConnection?
    var reconnect: Int?, remoteDial: Int?, pairingDial: Int?, homeAsk: Int?, homeDialer: Int?
    var overlayAskDialer: Int?, overlayAskShown: Int?, pendingLink: Int?
    enum Pairing { case idle, working }
    var pairing = Pairing.idle
    struct Selection { var lease: VisionWindowLease? = VisionWindowLease(window: UUID()) }
    var visionDisplaySelection = Selection()
    struct Cable { enum Launch { case ordinary, cable }; var launch = Launch.ordinary }
    var visionCableBootstrap = Cable()
    var status = ""
    var persists = 0
    var dials: [String] = []
    enum DialReason { case afterPairing }
    func dialSaved(_ id: String, why: DialReason) { cancelOwnerBootstrap(); dials.append(id) }
    func persistSavedMacs() { persists += 1; UserDefaults.standard.set(SavedMacs.encode(savedMacs), forKey: SavedMacs.defaultsKey) }
    func rememberPreferredMac(_ id: String) { UserDefaults.standard.set(id, forKey: Self.ownerPreferredKey) }
}
