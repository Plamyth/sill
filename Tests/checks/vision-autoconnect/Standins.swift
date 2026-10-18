import Foundation
import CryptoKit
import Security
import Darwin

struct NWInterface: Hashable { let name: String }
enum NWEndpoint: Hashable {
    case service(name: String, type: String, domain: String, interface: NWInterface?)
}
final class NWConnection {
    var cancelled = false
    var stateUpdateHandler: ((Int) -> Void)?
    func cancel() { cancelled = true }
}
struct RemoteIdentity {}
final class RemoteConnector { func cancel() {} }
enum DeviceIdentity {
    static var available = true
    static func existing() -> RemoteIdentity? { available ? RemoteIdentity() : nil }
}
enum UIDevice {
    static let current = UIDeviceValue()
    struct UIDeviceValue { let name = "Fixture Vision" }
}
final class UserDefaults {
    static let standard = UserDefaults()
    var strings: [String: String] = [:]
    func string(forKey key: String) -> String? { strings[key] }
    func set(_ value: String, forKey key: String) { strings[key] = value }
}
final class DispatchWorkItem {
    private let body: () -> Void
    private(set) var cancelled = false
    init(block: @escaping () -> Void) { body = block }
    func cancel() { cancelled = true }
    func performEvenIfCancelled() { body() }
}
final class DispatchQueue {
    static let main = DispatchQueue()
    var scheduled = 0
    var held: [() -> Void] = []
    var hold = false
    var timers: [(DispatchTime, DispatchWorkItem)] = []
    func async(execute: @escaping () -> Void) {
        if self === Self.main || hold { held.append(execute) } else { execute() }
    }
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { scheduled += 1 }
    func asyncAfter(deadline: DispatchTime, execute: DispatchWorkItem) {
        scheduled += 1
        timers.append((deadline, execute))
    }
    func drain() {
        for _ in 0..<1000 {
            guard !held.isEmpty else { return }
            let work = held; held = []; work.forEach { $0() }
        }
        preconditionFailure("Fixture scheduling did not settle")
    }
}
final class HomeDialer {
    /* REAL_DIAL_TYPES */
    static var instances: [HomeDialer] = []
    let targets: [Target]
    let pin: Data?
    var onWinner: ((Winner) -> Void)?
    var onFailed: ((Failed) -> Void)?
    var cancelled = false
    var starts = 0
    private var index = 0
    private var current: NWConnection?
    private var onFallback = false
    private var finished = false
    private var statuses: [Int32] = []
    var dials: [(NWEndpoint, Bool)] = []
    func dial(_ endpoint: NWEndpoint, ipv6Only: Bool, wait: Double) { dials.append((endpoint, ipv6Only)) }
    func finish() { finished = true; onFailed?(Failed(statuses: statuses)) }
    func failCurrent(_ status: Int32? = nil) { ended(NWConnection(), status: status); DispatchQueue.main.drain() }
    /* REAL_DIAL_METHODS */
    init(targets: [Target], pin: Data?, identity: RemoteIdentity, queue: DispatchQueue) {
        self.targets = targets; self.pin = pin
        Self.instances.append(self)
    }
    func start() { starts += 1; dialTarget() }
    func cancel() { cancelled = true }
    func win(_ fingerprint: Data) {
        let target = targets[0]
        onWinner?(Winner(connection: NWConnection(), target: target, endpoint: target.endpoint, fingerprint: fingerprint))
        DispatchQueue.main.drain()
    }
}
/* REAL_ROW */
/* REAL_ASK */

final class StreamClient {
    enum PairingPhase: Equatable { case idle, working }
    enum HomeExchange { case answer(PairResult, SymmetricKey?), noAnswer }
    enum Route { case network, remote; var isRemote: Bool { self == .remote } }
    struct Session { var macID: String?; var route: Route; var home: DiscoveryPolicy.HomeTrust? }
    static let preferredTrustedMacKey = "Sill.preferredTrustedMacID"
    static let deviceWord = "Apple Vision Pro"
    static let debugBuild = false
    static let keepsLoopback = false
    static let lookingOnNetwork = "looking"
    private var startupAutoConnection: StartupAutoConnection = .unarmed
    private var startupRemoteCheck: DispatchWorkItem?
    var visionCableBootstrap: VisionCableBootstrap<FoundMac>
    var savedMacs: [SavedMac] = []
    var macs: [FoundMac] = []
    var connected = false
    var connection: NWConnection?
    var reconnect: Int?
    var remoteDial: RemoteConnector?
    var pairingDial: RemoteConnector?
    var homeDialer: HomeDialer?
    var homeAsk: HomeAsk?
    var pairing = PairingPhase.idle
    var pairingAttempt = 0
    var appInForeground = true
    var visionStartupStarted = true
    var visionStartupForeground = true
    var localNetworkDenied = false
    var queue = DispatchQueue()
    var session: Session?
    var afterPairingWatch: DispatchWorkItem?
    var pinRefusedRows = Set<String>()
    var status = ""
    var hostName = ""
    var cable = true
    var allowedTestOverride: Bool?
    var reply: PairResult?
    var pendingReply: ((HomeExchange) -> Void)?
    var sentMethods: [String] = []
    var sentCable: [Bool?] = []
    var sessionPins: [Data] = []
    var sessionRows: [FoundMac] = []
    enum DialReason { case launchArgument }
    var remoteAttempts: [(String, DialReason)] = []
    var writes = 0
    var identityCalls = 0
    var withdrawals = 0
    init(_ launch: VisionCableBootstrap<FoundMac>.Launch) {
        visionCableBootstrap = VisionCableBootstrap(launch: launch)
    }
    func deviceIdentity() -> RemoteIdentity? { identityCalls += 1; return DeviceIdentity.existing() }
    func savedMac(_ id: String) -> SavedMac? { savedMacs.first { $0.macID == id } }
    func persistSavedMacs() { writes += 1 }
    func displayName(_ id: String) -> String { savedMac(id)?.name ?? "Mac" }
    func cancelRemoteDial() { remoteDial = nil }
    func cableCheck(_ connection: NWConnection, allowTestOverride: Bool = true) -> DiscoveryPolicy.CableCheck {
        allowedTestOverride = allowTestOverride
        return DiscoveryPolicy.CableCheck(cable: cable, console: "fixture")
    }
    func homeExchange(_ winner: HomeDialer.Winner, identity: RemoteIdentity, deviceName: String, method: String,
                      cable: Bool?, key: ((Data) -> SymmetricKey?)?, done: @escaping (HomeExchange) -> Void) {
        sentMethods.append(method); sentCable.append(cable)
        if let reply { done(.answer(reply, nil)) } else { pendingReply = done }
    }
    func withdrawAsk(at target: HomeDialer.Target, key: Data) { withdrawals += 1 }
    func markNewKey(_ id: String) { savedMacs = SavedMacs.markingNewKey(id, in: savedMacs) ?? savedMacs }
    func updateDiscovery() {}
    func discoveryChanged() { trySavedMacAutoConnect(); considerVisionCableBootstrap() }
    func tearDown(status: String, restartSearch: Bool) { self.status = status; connected = false }
    func dialRow(_ row: FoundMac, macID: String?, trust: DiscoveryPolicy.HomeTrust, tagNamed: Bool, tap: Bool = false) -> Bool {
        guard DeviceIdentity.existing() != nil, case .saved(let pin) = trust else { return false }
        sessionPins.append(pin)
        sessionRows.append(row)
        session = Session(macID: macID, route: .network, home: trust)
        connection = NWConnection()
        return true
    }
    func dialSaved(_ macID: String, why: DialReason) {
        remoteAttempts.append((macID, why))
        remoteDial = RemoteConnector()
    }
    func connect(to endpoint: NWEndpoint, name: String, peerToPeer: Bool, macID: String?, trust: DiscoveryPolicy.HomeTrust) {
        if case .saved(let pin) = trust { sessionPins.append(pin) }
        session = Session(macID: macID, route: .network, home: trust)
        connection = NWConnection()
    }
    /* REAL_CLIENT_METHODS */
}

enum PairRequest { static let ask = "ask" }
enum HostConfigDefaults { static let remotePort = 5318 }

enum RemoteTLS { static let dialTimeout = 5 }
final class FixtureLaunchClient {
    var retired = false
    func retireVisionWindow() { retired = true }
    func admitVisionDisplays(lease: VisionWindowLease?, foreground: Bool) {}
    let visionAudio = FixtureAudio()
    let bootstrap = VisionCableBootstrap<Int>(launch: .cable(.init(pin: Data(repeating: 1, count: 32), service: "fixture")))
    var visionStartupForeground = false
    var visionStartupStarted = false
    var visionExpectedMacPin: Data? = nil
    var calls: [String] = []
    func startRemote() { calls.append("startRemote") }
    func armSavedMacAutoConnect() { calls.append("armSavedMacAutoConnect") }
    func startBrowsing() { calls.append("startBrowsing") }
    func setVisionPresentationForeground(_ active: Bool) {}
    var microphoneScenes: [(VisionWindowLease?, VisionMicrophoneAdmission.Scene)] = []
    func microphoneSceneChanged(lease: VisionWindowLease?, scene: VisionMicrophoneAdmission.Scene) {
        microphoneScenes.append((lease, scene))
    }
    func stopVisionCableBootstrap(_ reason: VisionCableBootstrapReason) { bootstrap.stop(reason) }
}
final class FixtureAudio { func setForeground(_ active: Bool) {} }
enum VisionMicrophoneAdmission { enum Scene { case active, inactive, background } }
enum ScenePhase { case active, inactive, background }
final class FixtureInput {
    var allowed = true
    func bind(_ client: FixtureLaunchClient) {}
}
final class FixtureStats { func attach(to client: FixtureLaunchClient) {} }
final class FixtureAppOwner {
    var windowLease: VisionWindowLease?
    var windowOwner: UUID? { windowLease?.window }
    var foreground = false
    private var started = false
    private var expectedPin: Data?
    let client = FixtureLaunchClient()
    let input = FixtureInput()
    let stats = FixtureStats()
    func refresh() {}
    /* REAL_OWNER_METHODS */
}
