import Foundation
import Network

struct MacInfo { let macID: String }
struct SavedMac { let macID: String; let fingerprintData: Data? }
enum HomeTrust: Equatable { case saved(pin: Data), plain }
enum SessionRoute { case network, remote; var isRemote: Bool { self == .remote } }
struct Session { let macID: String?; let home: HomeTrust?; let route: SessionRoute }
enum RemoteTLS {
    static var pins: [ObjectIdentifier: Data] = [:]
    static func peerFingerprint(_ peer: NWConnection) -> Data? { pins[ObjectIdentifier(peer)] }
}
enum Wire {
    static func encode<T: Encodable>(_ value: T) -> Data { try! JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }
}
enum NativeClock { static var now = 0.0 }

// PRODUCTION_LEASE

final class StreamClient {
    let link = SessionLink()
    var connection: NWConnection? { get { link.connection } set { link.connection = newValue } }
    var connected = true
    var appInForeground = true
    var visionStartupForeground = true
    var macInfoSaved = true
    var macInfoVerified: (info: MacInfo, fingerprint: Data)?
    var savedMacs: [SavedMac] = []
    var session: Session?
    // PRODUCTION_FIELDS

    init(peer: NWConnection, pin: Data) {
        connection = peer
        savedMacs = [SavedMac(macID: "fixture.mac", fingerprintData: pin)]
        macInfoVerified = (MacInfo(macID: "fixture.mac"), pin)
        session = Session(macID: "fixture.mac", home: .saved(pin: pin), route: .network)
        RemoteTLS.pins[ObjectIdentifier(peer)] = pin
    }

    func replacePeer(_ peer: NWConnection, pin: Data) {
        revokeVisionMacAudioRoutes()
        connection = peer
        RemoteTLS.pins[ObjectIdentifier(peer)] = pin
    }
    func revoke() { revokeVisionMacAudioRoutes() }
    func deliver(_ state: AudioRouteState, from peer: NWConnection) {
        let payload = Wire.encode(state)
        let message = StreamMessage(kind: .audioRoutes, timestamp: 0, isKeyframe: false, payload: payload)
        let header = StreamMessage.parseHeader(Data(message.serialized().prefix(StreamMessage.headerLength)))!
        _ = receiveVisionMacAudioRoutes(header, payload, from: peer)
    }
}

// PRODUCTION_ADAPTER

enum Phase { case active, inactive }
struct Transitions { var isPending = false }
final class ModalSession {
    var windowLease: VisionWindowLease?
    func owns(_ lease: VisionWindowLease) -> Bool { windowLease == lease }
    func refresh() {}
}
final class ModalInput {
    var releases = 0
    // PRODUCTION_INPUT_ADMISSION
    func releaseAll() { releases += 1 }
}
final class ModalClient {
    var connected = true
    var active: Int? = 1
}
final class Workspace {
    let session = ModalSession()
    let input = ModalInput()
    let client = ModalClient()
    let lease = VisionWindowLease(window: UUID())
    var phase = Phase.active
    var transitions = Transitions()
    var inputSuspended = false
    var draftShown = false
    var recoveryShown = false
    var audioOfferShown = false
    var audioOfferScope: UUID?
    var macAudioShown = false
    var macAudioOfferShown = false
    var keysShown = false
    init() { session.windowLease = lease; updateInputAdmission() }
    func open() { openMacAudioChooser() }
    func showOffer() { macAudioOfferShown = true; updateInputAdmission() }
    var admits: Bool { inputAllowed }
    // PRODUCTION_MODAL_METHODS
}
