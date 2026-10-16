import Foundation
import Network
import StreamProtocol

enum OriginPolicy { enum Origin { case loopback } }
enum ClientRoute {
    case home(OriginPolicy.Origin, peer: Int?)
    case remote
    var isRemote: Bool { if case .remote = self { return true }; return false }
}
enum ClientLink { enum Route {} }
struct LinkJudge {
    struct Verdict {}
    mutating func reset() -> Verdict? { nil }
}
enum Stats { static let shared = StatsSink() }
final class StatsSink { func bump(_ name: String) {} }
enum DeviceGate { static func helloLine(_ hello: Hello, endpoint: String) -> String { "fixture hello" } }

final class MediaHost {
    // CLIENT
    let queue = DispatchQueue(label: "epoch.fake.host")
    var clients: [ObjectIdentifier: Client] = [:]
    var videoAdmission = VideoEpochAdmission.stopped
    var latestCatalog: StreamMessage?
    var lastParameterSets: Data?
    var lastKeyframeAt = 0.0
    var lastRemoteKeyframeRequest = 0.0
    var onKeyframeNeeded: (() -> Void)?
    var onClientHello: ((NWConnection, Hello) -> Void)?
    static let remoteDeadAfter = 15.0
    static let remoteGrace = 15.0
    static let deadAfter = 4.0
    static let graceAfterConnect = 8.0
    static let remoteBacklogBudget = 256 * 1024
    static let remoteBacklogSlack = 128 * 1024
    static let remoteHoldCap = 512 * 1024
    static let remoteIdleBytes = 16 * 1024
    static let remoteKeyframeSpacing = 2.0
    static let remoteKeyframeSpacingBesideHome = 4.0
    func add(_ connection: NWConnection, remote: Bool, modern: Bool) {
        let client = Client(connection)
        client.route = remote ? .remote : .home(.loopback, peer: nil)
        client.catalogSent = true
        clients[ObjectIdentifier(connection)] = client
        queue.sync { took(Hello(presentationInput: modern ? 1 : nil), from: client) }
    }
    func drain() { queue.sync {} }
    // METHODS
}
