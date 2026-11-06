import Foundation
import CoreFoundation
import CryptoKit
import Network
import StreamProtocol

enum OriginPolicy { enum Origin: Equatable { case loopback } }
// PUBLICATION
// TRUST_SNAPSHOT
// TRUST_BOX
// REGISTRY_ERROR
// IDENTITY_ERROR
// REGISTRY
// ROUTE
final class SentryObservationFixture {
    func capture(_ epoch: VideoEpoch?) {}
    func revokeControl(forDeviceID: String) {}
    func membershipWillChange() {}
    func surfacesChanged() {}
}
struct PeerSessionFixture {
    var epoch: VideoEpoch?
    var source: StreamSource
    var admission: SourcePublicationAdmission
}
final class PointerFixture {
    func inputArrived(from: ObjectIdentifier, movesPointer: Bool) {}
}
final class ReaderHarness {
    // VIDEO_LANE
    // PEER_VIDEO
    final class Client {
        let connection: NWConnection
        var route = ClientRoute.home(.loopback, peer: nil)
        var lastHeardAt = 0.0
        var inputsRead = 0
        var pendingBytes = 0
        var catalogSent = false
        var latestCatalog: StreamMessage?
        var microphoneCatalogGrant: HostLocalOwnerGrant?
        var catalogAdmission: SourcePublicationAdmission?
        var admissionCurrent: (() -> Bool)?
        var role = StreamPeerRole.viewer
        var videoLane = VideoLane.unassigned
        var peerVideo = PeerVideo()
        var screenDemandPending = false
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
    let connectionQueueKey = DispatchSpecificKey<Bool>()
    let sentryAdmission = SentryObservationFixture()
    let microphoneReplies = MicrophoneReplyMailbox()
    var videoAdmission = VideoEpochAdmission.stopped
    func updateTicking() {}
    func publishScreenDemand(renewing: Client? = nil) {}
    func screenDemandTrustChanged() {}
    func receiveConfiguredCraft(_ payload: Data, from client: Client) { client.connection.cancel() }
    func receiveProvider(_ payload: Data, from client: Client) { client.connection.cancel() }
    func receiveForwarding(_ payload: Data, from client: Client) { client.connection.cancel() }
    func took(_ hello: Hello, from: Client) {}
    static func medianAndWorst(_ value: Int, worst: Int?) -> String { "fixture" }
    func send(_ data: Data, to client: Client) { client.connection.sent.append(data) }
    // READER
    // EGRESS
    // CATALOG_EGRESS
    // REPLAYCATALOG
    // ADMISSION_CURRENT
    // CONNECTION_CURRENT
    // VIDEO_ADMISSION
    // CATALOG_MATCHES
    // PLAIN_CATALOG
    // PEER_CATALOG
    func send(_ message: StreamMessage, to connection: NWConnection) { connection.sent.append(message.serialized()) }
}
struct PairedFixture: Equatable {
    let fingerprint: String
    let fingerprintData: Data?
    let displayName = "inert paired key"
    var ownerPrincipal: String? { nil }
    var ownerActivationPending: Bool? { nil }
    var method: String { "code" }
}
typealias PairedDevice = PairedFixture
typealias IdentityStore = PairStoreFixture
struct HostIdentity {
    let macID = "inert-without-keys"
    func verifyRecord(_ message: Data, signature: Data) -> Bool { false }
    func signRecord(_ message: Data) -> Data? { nil }
}
final class PairStoreFixture {
    var fail = false
    struct Failure: Error {}
    private var paired: [PairedFixture] = []
    func savePaired(_ paired: [PairedFixture]) throws { if fail { throw Failure() }; self.paired = paired }
    func loadPaired() throws -> [PairedFixture] { paired }
    func loadOwnerRegistry() throws -> Data? { throw OwnerRegistryStoreError.unsupported }
    func saveOwnerRegistry(_ record: Data) throws { throw OwnerRegistryStoreError.unsupported }
}
enum RemoteIdentity { static func shortName(_ data: Data) -> String { "inert" } }
@MainActor final class PairHarness {
    var paired: [PairedFixture] = [] { didSet { publishTrust() } }
    var identity: HostIdentity? = HostIdentity()
    var ownerRegistry: OwnerBootstrapRegistry?
    let trust = TrustBox()
    var store: PairStoreFixture? = PairStoreFixture()
    var lastSeen: [String: Int] = [:]
    var onMicrophoneTrustRevoked: ((Data) -> Void)?
    var server: CloseHarness?
    func publishTrust() {
        trust.update { $0.paired = Dictionary(uniqueKeysWithValues: paired.compactMap { device in
            device.fingerprintData.map { ($0, device.displayName) }
        }) }
    }
    func publish() {}
    // PAIRED
    // REMOVE
    // OWNER_TRUSTED
}
final class CloseHarness {
    var closes = 0
    func closeSessions(_ reason: String, matching: (ClientRoute) -> Bool, done: ((Int) -> Void)? = nil) {
        closes += 1; done?(1)
    }
}
@MainActor final class CoordinatorHarness {
    let server = ReaderHarness()
    // RECOVERY
    // BROADCAST
    // PUBLISHCATALOG
    let microphoneIngress = MicrophoneIngress()
    var microphoneIngressDraining = false
    var microphoneIngressDrainTask: Task<Void, Never>?
    let microphoneReceiver: HostMicrophoneReceiver
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var routes: [ObjectIdentifier: ClientRoute] = [:]
    var remote: PairHarness?
    var synthetic = false
    var switching = false
    var shuttingDown = false
    var inputGeneration = UUID().uuidString
    var active = StreamSource.desktop
    var gestureScopeToken = UUID()
    var peerStreams: [ObjectIdentifier: PeerSessionFixture] = [:]
    var sourcePublicationAdmission = SourcePublicationAdmission()
    var audioPrivacy: HostAudioPrivacy?
    var physicalAudioRoutesRetired = false
    var forwardingRuntime: AnyObject?
    var nativeAudioBindingAuthorized: ((Data, PrivacyAudioScope) -> Bool)?
    var sentry: SentryObservationFixture?
    // EPOCH
    init(_ receiver: HostMicrophoneReceiver) {
        microphoneReceiver = receiver
        receiver.current = { [weak self] scope, fingerprint in self?.microphoneScopeIsCurrent(scope, fingerprint: fingerprint) == true }
        receiver.onRenderGate = { [microphoneIngress] request, id, render in microphoneIngress.attach(request, grantID: id, render: render) }
    }
    // CURRENT
    // ROUTE_AUTH
    // NATIVE_BINDING
    // PRIVACY_READY
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
    func peerCatalog(to connection: NWConnection, lane: PeerSessionFixture) -> StreamMessage {
        StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false,
            payload: Wire.encode(WindowList(macName: "inert", windows: [], active: lane.source,
                inputGeneration: lane.epoch?.generation, videoEpoch: lane.epoch)))
    }
}
