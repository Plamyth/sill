import Foundation
import StreamProtocol

enum NWError: Error { case failed }
final class NWConnection {
    enum Completion { case contentProcessed((NWError?) -> Void) }
    var sent: [Data] = []
    var failSend = false
    var wire = Data()
    var pin = Data(repeating: 1, count: 32)
    var alpn: String? = "sill/1"
    func send(content: Data?, completion: Completion) {
        if let content { sent.append(content) }
        if case .contentProcessed(let callback) = completion { callback(failSend ? .failed : nil) }
    }
    func receive(minimumIncompleteLength: Int, maximumLength: Int,
                 completion: (Data?, Int?, Bool, NWError?) -> Void) {
        let count = min(maximumLength, wire.count)
        let piece = Data(wire.prefix(count))
        wire.removeFirst(count)
        completion(count == 0 ? nil : piece, nil, count == 0, nil)
    }
}
enum RemoteTLS {
    static let sessionALPN = "sill/1"
    static func negotiatedALPN(_ peer: NWConnection) -> String? { peer.alpn }
    static func peerFingerprint(_ peer: NWConnection) -> Data? { peer.pin }
}
enum DeviceIdentity {
    struct Identity { let fingerprint: Data }
    static var fingerprint: Data? = Data(repeating: 2, count: 32)
    static func existing() -> Identity? { fingerprint.map(Identity.init) }
}
enum MacID {
    static func make(fingerprint: Data) -> String { fingerprint == Data(repeating: 1, count: 32) ? "fixtureMac" : "otherMac" }
}
struct SavedMac {
    var macID = "fixtureMac"
    var fingerprintData: Data? = Data(repeating: 1, count: 32)
    var revoked: Bool? = false
    var newKey: Bool? = false
}
final class StreamClient {
    enum Route { case remote, network; var isRemote: Bool { self == .remote } }
    enum Home: Equatable { case saved(pin: Data) }
    struct Session {
        var macID: String? = "fixtureMac"
        var route: Route = .network
        var home: Home? = .saved(pin: Data(repeating: 1, count: 32))
    }
    var connection: NWConnection?
    var connected = true
    var session: Session? = Session()
    var savedMacs = [SavedMac()]
    var sentryObservation = IPadSentryObservation()
    var sentryControl: IPadSentryControl
    init(store: IPadSentryControl.Store) { sentryControl = IPadSentryControl(store: store) }
    // ACCEPT_REPLY
}
