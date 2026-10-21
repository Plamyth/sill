import Foundation
import StreamProtocol

final class DispatchWorkItem {
    let block: () -> Void
    init(block: @escaping () -> Void) { self.block = block }
    func cancel() {}
}
struct DispatchTime {
    static func now() -> Self { .init() }
    static func + (lhs: Self, rhs: Double) -> Self { lhs }
}
struct DispatchQueue {
    func async(execute: () -> Void) { execute() }
    func asyncAfter(deadline: DispatchTime, execute: DispatchWorkItem) {}
}
struct RemoteIdentity {}
enum RemoteDialPolicy {
    static let wholeDial = 20.0, stagger = 0.2
    struct Candidate {
        let host: String; let port: Int
        var key: String { "\(host)|\(port)" }
    }
    enum Failure: Equatable { case noAnswer, notSill }
    enum End { case timeout, posix(Int32), dns(Int), tls(Int32), notSill }
    static func classify(_ end: End, candidate: Candidate, usedTunnel: Bool?) -> Failure? {
        if case .notSill = end { return .notSill }; return .noAnswer
    }
    static func worst(_ failures: [Failure]) -> Failure? { failures.first }
}
enum NWError: Error { case posix(POSIXErrorCode), dns(Int), tls(Int32), other }
enum NWEndpoint {
    struct Host { let value: String; init(_ value: String) { self.value = value } }
    struct Port { let rawValue: UInt16; init?(rawValue: UInt16) { guard rawValue > 0 else { return nil }; self.rawValue = rawValue } }
}
struct Parameters { let alpn: String; let pin: Data?; let others: [Data] }
struct FakePath {
    enum Interface { case other }
    func usesInterfaceType(_ type: Interface) -> Bool { true }
}
final class NWConnection {
    enum State { case ready, waiting(NWError), failed(NWError), cancelled, preparing }
    static var all: [NWConnection] = []
    let parameters: Parameters
    var stateUpdateHandler: ((State) -> Void)?
    var currentPath: FakePath? = FakePath()
    var pin: Data?
    var alpn: String?
    var cancelled = false
    init(host: NWEndpoint.Host, port: NWEndpoint.Port, using params: Parameters) {
        parameters = params; pin = params.pin; alpn = params.alpn
        Self.all.append(self)
    }
    func start(queue: DispatchQueue) {}
    func cancel() { cancelled = true }
    func ready() { stateUpdateHandler?(.ready) }
}
enum DeviceTLS {
    static func options(identity: RemoteIdentity, alpn: String, pin: Data?, queue: DispatchQueue, alsoAccept: [Data]) -> Parameters {
        Parameters(alpn: alpn, pin: pin, others: alsoAccept)
    }
}
enum RemoteTLS {
    static let sessionALPN = "sill/1", pairingALPN = "sill-pair/1"
    static func parameters(tls: Parameters, dialing: Bool) -> Parameters { tls }
    static func peerFingerprint(_ c: NWConnection) -> Data? { c.pin }
    static func negotiatedALPN(_ c: NWConnection) -> String? { c.alpn }
}
// ACTUAL_CONNECTOR

var count = 0
func check(_ name: String, _ value: Bool) { precondition(value, name); count += 1 }
let pin = Data(repeating: 0x37, count: 32)
let candidates = [RemoteDialPolicy.Candidate(host: "100.64.1.2", port: 7455),
                  RemoteDialPolicy.Candidate(host: "100.64.1.3", port: 7455)]
func connector(_ mode: RemoteConnector.Mode = .ownerBootstrap(pin: pin)) -> RemoteConnector {
    NWConnection.all = []
    let c = RemoteConnector(candidates: candidates, mode: mode, identity: RemoteIdentity(), queue: DispatchQueue(),
                            successors: [candidates[0].key: [Data(repeating: 8, count: 32)]])
    c.start(); return c
}
do {
    let c = connector()
    check("owner 순차 첫 주소 하나만 dial", NWConnection.all.count == 1)
    let first = NWConnection.all[0]
    check("owner ALPN·정확 pin·successor 없음", first.parameters.alpn == OwnerMacBootstrap.alpn && first.parameters.pin == pin && first.parameters.others.isEmpty)
    first.alpn = RemoteTLS.sessionALPN; first.ready()
    check("잘못된 실제 협상 ALPN은 닫고 다음 주소", first.cancelled && NWConnection.all.count == 2)
    var winners = 0; c.onWinner = { _ in winners += 1 }
    NWConnection.all[1].ready()
    check("정확한 두번째 peer만 winner", winners == 1)
    first.ready()
    check("늦은 이전 ready callback 무시", winners == 1)
}
do {
    let c = connector(); let first = NWConnection.all[0]
    first.pin = Data(repeating: 2, count: 32); first.ready()
    check("실제 peer pin 불일치는 폐기", first.cancelled && NWConnection.all.count == 2)
    c.cancel(); NWConnection.all[1].ready()
    check("dial 취소는 진행 소켓을 닫음", NWConnection.all[1].cancelled)
}
do {
    let c = connector(); var failures = 0; c.onFailed = { _ in failures += 1 }
    NWConnection.all[0].stateUpdateHandler?(.failed(.posix(.ETIMEDOUT)))
    NWConnection.all[1].stateUpdateHandler?(.waiting(.tls(-9808)))
    check("기존 timeout·waiting 실패 순차종료 재사용", failures == 1 && NWConnection.all.allSatisfy(\.cancelled))
}
do {
    let c = connector(.pairing(pin: nil))
    check("기존 code 경로는 pairing ALPN과 nil pin 유지", NWConnection.all[0].parameters.alpn == RemoteTLS.pairingALPN && NWConnection.all[0].parameters.pin == nil)
    c.cancel()
}
do {
    let c = connector(.pairing(pin: pin))
    check("기존 QR 경로의 pairing ALPN과 pin 유지", NWConnection.all[0].parameters.alpn == RemoteTLS.pairingALPN && NWConnection.all[0].parameters.pin == pin)
    c.cancel()
}
print("PASS \(count) actual RemoteConnector owner mode checks; deterministic sockets, no transport effects")
