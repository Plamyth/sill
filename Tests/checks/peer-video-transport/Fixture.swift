import Foundation
import CoreGraphics

final class NWConnection {
    enum State { case ready, cancelled }
    enum SendCompletion { case contentProcessed((Error?) -> Void) }
    var state = State.ready
    let endpoint = "inert-peer"
    var sent: [Data] = []
    var completions: [() -> Void] = []
    func send(content: Data?, completion: SendCompletion) {
        sent.append(content ?? Data())
        if case .contentProcessed(let done) = completion { completions.append { done(nil) } }
    }
    func drain() { let pending = completions; completions = []; pending.forEach { $0() } }
    func cancel() { state = .cancelled }
}
enum AudioRoutingPolicy { static let maxSelectionPayload = 4096; static let maxStatePayload = 4096 }
struct MacPointer: Equatable, Codable {
    var x: Double?; var y: Double?; var inside: Bool; var seen: Int
    init(x: Double? = nil, y: Double? = nil, inside: Bool, seen: Int) { self.x = x; self.y = y; self.inside = inside; self.seen = seen }
}
final class PointerWatch {
    struct Reading {
        let x: Double; let inside: Bool; var moving = false
        func report(for client: ObjectIdentifier, seen: Int) -> MacPointer? { MacPointer(x: x, y: 0, inside: inside, seen: seen) }
    }
    var globalCalls = 0
    var rects: [CGRect] = []
    let frameInterval = 1.0 / 60
    func sample(devices: [ObjectIdentifier]) -> Reading? { globalCalls += 1; return Reading(x: 0.99, inside: true) }
    func sample(devices: [ObjectIdentifier], in rect: CGRect) -> Reading? { rects.append(rect); return Reading(x: rect.minX / 1000, inside: true) }
    static func samplerInterval(moving: Bool, inside: Bool, watched: Bool, frameInterval: Double, tickInterval: Double) -> Double? { nil }
}
struct Hello { var presentationInput: Int? = 1; var device: String? = "fixture" }
enum DeviceGate { static func helloLine(_ hello: Hello, endpoint: String) -> String { "inert hello" } }
enum SafeText { static func label(_ text: String) -> String { text } }
final class Stats { static let shared = Stats(); func bump(_ value: String) {} }
struct ClientLink { enum Route {} }
struct ClientRoute {
    var isRemote = false
    var encrypted = false
    var fingerprint: Data? = nil
    static func home(_ origin: Origin, peer: Int?) -> Self { Self() }
    enum Origin { case loopback }
}
struct LinkJudge {
    struct Second { let sent: Int; let withheld: Int; let taken: Int; let waiting: Int; let heard: Bool }
    struct Verdict {}
    mutating func close(_ second: Second) -> Verdict? { nil }
    mutating func reset() -> Verdict? { nil }
}
final class HostLocalOwnerGrant {
    struct Scope { let videoEpoch: UUID }
    let scope: Scope
    let fingerprint: Data
    var valid = true
    init(epoch: UUID, fingerprint: Data) { scope = Scope(videoEpoch: epoch); self.fingerprint = fingerprint }
    func whileValid(at time: UInt64, _ body: () -> Void) -> Bool { guard valid else { return false }; body(); return true }
}
final class StreamServer {
    // PRODUCTION_TYPES
    let queue = DispatchQueue(label: "inert.transport")
    var clients: [ObjectIdentifier: Client] = [:]
    var videoAdmission = VideoEpochAdmission.stopped
    var lastParameterSets: Data?
    var lastRemoteKeyframeRequest: TimeInterval = 0
    var lastKeyframeAt: TimeInterval = 0
    var lastSweepAt: TimeInterval = 0
    var streaming = false
    var onKeyframeNeeded: (() -> Void)?
    var onPeerKeyframeNeeded: ((NWConnection) -> Void)?
    var onClientHello: ((NWConnection, Hello) -> Void)?
    var onClientLinkChanged: ((NWConnection, LinkJudge.Verdict) -> Void)?
    static let remoteSilence: TimeInterval = 8
    static let remoteGrace: TimeInterval = 15
    static let remoteDeadAfter: TimeInterval = 15
    static let deadAfter: TimeInterval = 4
    static let graceAfterConnect: TimeInterval = 8
    static let remoteBacklogBudget = 256 * 1024
    static let remoteBacklogSlack = 128 * 1024
    static let remoteHoldCap = 512 * 1024
    static let remoteIdleBytes = 16 * 1024
    static let remoteKeyframeSpacing: TimeInterval = 2
    static let remoteKeyframeSpacingBesideHome: TimeInterval = 4
    static let tickInterval: TimeInterval = 0.03
    var pointerWatch: PointerWatch?
    func setPointerSampler(interval: Double?) {}
    func updateTicking() {}
    func add(_ connection: NWConnection, remote: Bool = false, modern: Bool = true) {
        queue.sync { let c = Client(connection); c.route.isRemote = remote; c.presentationInput = modern; clients[ObjectIdentifier(connection)] = c }
    }
    func flush() { queue.sync {} }
    // PRODUCTION_METHODS
}
