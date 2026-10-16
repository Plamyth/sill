import Foundation
import CoreFoundation
import Network
import StreamProtocol

enum OriginPolicy { enum Origin: Equatable { case loopback } }
// ROUTE
final class PointerFixture {
    func inputArrived(from: ObjectIdentifier, movesPointer: Bool) {}
}
final class ReaderHarness {
    final class Client {
        let connection: NWConnection
        var route = ClientRoute.home(.loopback, peer: nil)
        var lastHeardAt = 0.0
        var inputsRead = 0
        var pendingBytes = 0
        var presentationInput = false
        var device: String?
        var worstFrameAgeSincePrint = -1
        var worstRttSincePrint = -1
        var lastStatsPrint = Double.greatestFiniteMagnitude
        var helloSeen = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    var lastInputAt = 0.0
    var tickTimer: Int? = 1
    var pointerWatch: PointerFixture?
    var onClientStats: ((NWConnection, ClientStats) -> Void)?
    var onMessage: ((StreamMessage, NWConnection) -> Void)?
    var onMicrophoneMessage: ((StreamMessage, NWConnection) -> Void)?
    var clients: [ObjectIdentifier: Client] = [:]
    let queue = DispatchQueue(label: "inert.mic.egress")
    let microphoneReplies = MicrophoneReplyMailbox()
    func updateTicking() {}
    func took(_ hello: Hello, from: Client) {}
    static func medianAndWorst(_ value: Int, worst: Int?) -> String { "fixture" }
    func send(_ data: Data, to client: Client) { client.connection.sent.append(data) }
    // READER
    // EGRESS
}
struct PairedFixture {
    let fingerprint: String
    let fingerprintData: Data?
    let displayName = "inert paired key"
}
final class PairStoreFixture {
    var fail = false
    struct Failure: Error {}
    func savePaired(_ paired: [PairedFixture]) throws { if fail { throw Failure() } }
}
enum RemoteIdentity { static func shortName(_ data: Data) -> String { "inert" } }
@MainActor final class PairHarness {
    var paired: [PairedFixture] = []
    var store: PairStoreFixture? = PairStoreFixture()
    var lastSeen: [String: Int] = [:]
    var onMicrophoneTrustRevoked: ((Data) -> Void)?
    var server: CloseHarness?
    func publishTrust() {}
    func publish() {}
    // PAIRED
    // REMOVE
}
final class CloseHarness {
    var closes = 0
    func closeSessions(_ reason: String, matching: (ClientRoute) -> Bool, done: (Int) -> Void) {
        closes += 1; done(1)
    }
}
@MainActor final class CoordinatorHarness {
    let microphoneIngress = MicrophoneIngress()
    let microphoneReceiver: HostMicrophoneReceiver
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var routes: [ObjectIdentifier: ClientRoute] = [:]
    var remote: PairHarness?
    var synthetic = false
    var switching = false
    var shuttingDown = false
    var inputGeneration = UUID().uuidString
    var active = StreamSource.desktop
    // EPOCH
    init(_ receiver: HostMicrophoneReceiver) {
        microphoneReceiver = receiver
        receiver.current = { [weak self] scope, fingerprint in self?.microphoneScopeIsCurrent(scope, fingerprint: fingerprint) == true }
        receiver.onRenderGate = { [microphoneIngress] request, id, render in microphoneIngress.attach(request, grantID: id, render: render) }
    }
    // CURRENT
    // CONNECTION
    // DRAIN
    // CATALOG
    // DISCONNECT
    func listMessage() -> StreamMessage {
        StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false,
            payload: Wire.encode(WindowList(macName: "inert", windows: [], active: active, inputGeneration: inputGeneration, videoEpoch: videoEpoch)))
    }
    func installTrustHook() {
        // TRUSTHOOK
    }
}
