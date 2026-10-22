import Foundation
import StreamProtocol

typealias NWEndpoint = Int
enum MoveKind { case fromRemote }
enum VisionReleaseTestContext { static let isTestBundle = false }
struct FoundMac {
    let id: String
    let name: String
    let door: DiscoveryPolicy.HomeDoor
    var endpoint: Int? = 7
    var direct = false
    enum Route { case network }
    var route = Route.network
}
struct HomeRow { let id: String; let tagNamed: Bool; let tried: [String]; let tapped: Bool }
final class Work { var cancelled = false; func cancel() { cancelled = true } }
struct MoveRows { func keeping(listed: Set<String>) -> Self { self } }
struct Session { struct Route { var isRemote = true }; var route = Route(); var why = StreamClient.DialReason.automatic; var macID: String? }
final class StreamClient {
    enum DialReason { case tap, automatic, connectRemotely, afterPairing, launchArgument }
    enum Pairing { case idle }
    struct Reconnect {
        var macID: String?
        var remoteAllowed = true
        var remoteFailures = 0
        var nextRemoteAt: Double = 0
    }
    static let deviceWord = "Vision Pro"
    static let debugBuild = false
    var records: [SavedMac] = []
    var session: Session?
    var connected = true
    var sessionListed = true
    var moving: Int?
    var sessionDead = false
    var connection: Int? = 1
    struct HomeInfo { var latest: Double? = 1 }
    var homeInfo = HomeInfo()
    var homeMoveCheck: Work?
    var homeMoveRows = MoveRows()
    var macs: [FoundMac] = []
    var homeEligible = 0, moveCreated = 0, rowConnections = 0
    var remoteRequests: [(String,DialReason)] = []
    var remoteDial: Int?
    var reconnect: Reconnect?
    var reconnectCheck: Work?
    var appInForeground = true
    var moveUnderWay = false
    var afterPairingWatch: Work?
    var pairing = Pairing.idle
    var retries = 0, discoveryChanges = 0
    var status = ""
    func displayName(_ id: String) -> String { savedMac(id)?.name ?? "Mac" }
    func discoveryChanged() { discoveryChanges += 1 }
    func savedMac(_ id: String) -> SavedMac? { records.first { $0.macID == id } }
    static func localIPv4Networks() -> [(address:[UInt8],prefix:Int)] { [([192,168,1,2],24)] }
    static func candidates(_ mac: SavedMac) -> [RemoteDialPolicy.Candidate] {
        /* ACTUAL_CANDIDATES */
    }
    func dialSaved(_ id: String, why: DialReason) { remoteRequests.append((id,why)); remoteDial = 1 }
    func wiredDial(for mac: FoundMac) -> (endpoint:Int,via:String)? { nil }
    func connect(to endpoint: Int, name: String, peerToPeer: Bool = false, macID: String?, fallback: Int? = nil, trust: DiscoveryPolicy.HomeTrust, row: HomeRow) -> Bool { rowConnections += 1; return true }
    /* ACTUAL_METHODS */
}
