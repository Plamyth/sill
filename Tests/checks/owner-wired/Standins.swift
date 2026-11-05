import Foundation

let pin = Data(repeating: 7, count: 32)
enum MacID { static func make(fingerprint: Data) -> String { fingerprint == pin ? "owner" : "other" } }
struct SavedMac { var macID = "owner", remotePort = 7469; var fingerprintData: Data? = pin; var method = "owner"; var revoked: Bool?; var newKey: Bool? }
enum RemoteDialPolicy { static func ownerTailnetScope(_ saved: SavedMac?) -> Bool { saved?.method == "owner" } }
enum DeviceIdentity { static var available = true; static func existing() -> Int? { available ? 1 : nil } }
struct UIDevice { enum Idiom { case pad, phone }; static var current = UIDevice(); var userInterfaceIdiom = Idiom.pad }
struct Interface: Equatable { enum Kind { case wiredEthernet, wifi }; let name: String; let index: Int; var type = Kind.wiredEthernet }
func if_nametoindex(_ name: String) -> UInt32 { UInt32(interfaces[name] ?? 0) }
var interfaces = ["en2": 9]
enum NWEndpoint: Equatable { case service(name: String, type: String, domain: String, interface: Interface?); case address }
struct FoundMac { enum Route { case network, remote }; var id = "usb"; var route = Route.network; var wired: Interface? = Interface(name: "en2", index: 9); var endpoint: NWEndpoint? = .service(name: "Mac", type: "_sill._tcp", domain: "local.", interface: nil) }
final class NWConnection { enum State: Equatable { case ready, cancelled, waiting(String), failed(String) }; enum Completion { case contentProcessed((String?) -> Void) }; var stateUpdateHandler: ((State) -> Void)?; func send(content: Data, completion: Completion) {}; var state = State.ready; var currentPath: Int? = 1; var cancels = 0; var fingerprint = pin; var alpn = "sill/1"; func cancel() { cancels += 1; state = .cancelled } }
struct StreamHeader {}
struct SignedMacInfo { let valid: Bool }
struct Goodbye { let reason: String }
enum RemoteTLS { static let sessionALPN = "sill/1"; static func peerFingerprint(_ c: NWConnection) -> Data? { c.fingerprint }; static func negotiatedALPN(_ c: NWConnection) -> String? { c.alpn } }
struct OwnerWiredTarget { var binding: OwnerWiredPolicy.Binding; var key: String; var interface: Interface; var endpoint = NWEndpoint.address; var valid = true; func current() -> Bool { valid && if_nametoindex(interface.name) == UInt32(interface.index) }; func matches(_ path: Int?) -> Bool { current() && path == 1 } }
final class OwnerWiredResolver {
 static var pending: [(resolver: OwnerWiredResolver, completion: (OwnerWiredTarget?) -> Void)] = []
 let binding: OwnerWiredPolicy.Binding, key: String, interface: Interface
 var cancelled = false
 init(binding: OwnerWiredPolicy.Binding, key: String, interface: Interface) { self.binding = binding; self.key = key; self.interface = interface }
 func start(service: NWEndpoint, completion: @escaping (OwnerWiredTarget?) -> Void) { Self.pending.append((self, completion)) }
 func cancel() { cancelled = true }
 static func answer(_ index: Int, success: Bool) { let p = pending[index]; p.completion(success ? OwnerWiredTarget(binding: p.resolver.binding, key: p.resolver.key, interface: p.resolver.interface) : nil) }
}
final class StreamClient {
 enum DialReason { case automatic, tap }
 enum MoveKind { case fromRemote, fromDirect, toCable, toWifi }
 struct Move { var connection: NWConnection; var kind = MoveKind.fromRemote; var ownerWired: OwnerWiredTarget? }
 struct Session { struct Route { var isRemote = true }; var route = Route(); var macID: String? = "owner" }
 struct Retry {}
 struct HomeInfo { var latest: Double? = 1; mutating func moveStarted() {} }
 enum StartupAutoConnection { case waitingRemote(String) }; var startupAutoConnection = StartupAutoConnection.waitingRemote("owner")
 struct HomeRow { let id: String }; struct HomeRows { var refused = Set<String>() }
 var homeMoveRows = HomeRows(), homeMoveRow: HomeRow?, homeMoveName: String?, goodbye: Goodbye?
 var records = [SavedMac()]
 var appInForeground = true, connected = false, sessionListed = true, sessionDead = false
 var connection: NWConnection?, remoteDial: Int?, pairingDial: Int?, homeAsk: Int?, pendingLink: Int?, reconnect: Retry?
 enum Pairing { case idle, busy }; var pairing = Pairing.idle
 var session: Session? = Session(), moving: Move?, ownerWiredSession: OwnerWiredTarget?
 var ownerWiredResolver: OwnerWiredResolver?, ownerWiredToken: UUID?, ownerWiredRecheck: DispatchWorkItem?
 var ownerWiredBudget = OwnerWiredPolicy.Budget(), homeInfo = HomeInfo(), macs = [FoundMac()]
 var sessionHost: String? = "launch", hostName = "Mac", sightings = DiscoveryPolicy.NetworkSightings()
 var refusedListing: Double?, refusedCable: Double?, upListing: Double?
 var tailnet = 0, usb = 0, committed = 0, rejected = 0, audioRebind = 0, probes = 0
 var lastPort: Int?
 static var own: [(interface: String, address: [UInt8])] = [("en2", [0xfe,0x80] + Array(repeating:0,count:13) + [2])]
 static func ownAddresses() -> [(interface: String, address: [UInt8])] { own }
 func savedMac(_ id: String) -> SavedMac? { records.first { $0.macID == id } }
 func dialSavedAtStartup(_ id: String, ownerWired: OwnerWiredTarget? = nil) { dialSaved(id, why: .automatic, ownerWired: ownerWired) }
 func dialSaved(_ id: String, why: DialReason, ownerWired: OwnerWiredTarget? = nil) { if let ownerWired { usb += 1; lastPort = ownerWired.binding.port } else { tailnet += 1 } }
 func startMove(to endpoint: NWEndpoint, kind: MoveKind, fallback: NWEndpoint?, ownerWired: OwnerWiredTarget? = nil) { moving = Move(connection: NWConnection(), kind: kind, ownerWired: ownerWired) }
 func moveEnded(_ c: NWConnection) { if moving?.connection === c { moving = nil } }
 func endSession() { connected = false }
 func homeInfoChecks(_ info: SignedMacInfo?) -> Bool { info?.valid == true }
 func refuseHomeMove(_ c: NWConnection, why: String) { rejected += 1; c.cancel() }
 func finishMove(_ c: NWConnection, kind: MoveKind, kept: [(header: StreamHeader,payload: Data)]) { committed += 1; audioRebind += 1; connection = c; moving = nil }
 func probeMove(_ c: NWConnection, kept: [(header: StreamHeader,payload: Data)] = [], untilMacInfo: Bool, listed: String?? = nil) { probes += 1 }
 func sessionReadyAgain(_ c: NWConnection) {}
 func sessionWaiting(_ c: NWConnection) {}
 func connectionLost(_ c: NWConnection, error: String? = nil) { if connection === c { connection = nil; connected = false } }
 func moveUnconstrained(after c: NWConnection, _ fallback: NWEndpoint, why: String) {}
 func giveUpMove(_ c: NWConnection, why: String) { moveEnded(c); c.cancel() }

 /* ACTUAL_METHODS */
}
