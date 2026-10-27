import Foundation
import StreamProtocol

enum NWError: Error { case posix(POSIXErrorCode), dns(Int32), tls(Int32) }
enum NWEndpoint {
    struct Host { let text: String; init(_ text: String) { self.text = text } }
    struct Port { let rawValue: UInt16; init?(rawValue: UInt16) { self.rawValue = rawValue } }
}
struct FakePath {
    enum Interface { case other }
    func usesInterfaceType(_ type: Interface) -> Bool { true }
}
final class NWConnection {
    enum State { case ready, waiting(NWError), failed(NWError), cancelled }
    static var all: [NWConnection] = []
    var stateUpdateHandler: ((State) -> Void)?
    var currentPath: FakePath? = FakePath()
    var cancelled = false
    init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: Int) { Self.all.append(self) }
    func start(queue: DispatchQueue) {}
    func cancel() { cancelled = true }
}
struct RemoteIdentity {}
struct FakeTLS {}
enum DeviceTLS {
    static var refusals: [(() -> Void)?] = []
    static func options(identity: RemoteIdentity, alpn: String, pin: Data?, queue: DispatchQueue,
                        alsoAccept: [Data] = [], onPinRefused: (() -> Void)? = nil) -> FakeTLS {
        refusals.append(onPinRefused)
        return FakeTLS()
    }
}
enum RemoteTLS {
    static let sessionALPN = "sill/1"
    static let pairingALPN = "sill-pair/1"
    static func parameters(tls: FakeTLS, dialing: Bool) -> Int { 1 }
    static func negotiatedALPN(_ c: NWConnection) -> String? { sessionALPN }
    static func peerFingerprint(_ c: NWConnection) -> Data? { Data(repeating: 7, count: 32) }
}
extension DispatchQueue {
    func async(execute: @escaping () -> Void) { asyncAfter(deadline: .now(), execute: DispatchWorkItem(block: execute)) }
}

var checks = 0
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ text: String) {
    checks += 1
    if ok() { print("PASS \(text)") } else { failures += 1; print("FAIL \(text)") }
}
let candidate = RemoteDialPolicy.Candidate(host: "100.64.1.2", port: 7455, kind: MacAddress.vpn, via: "Tailscale")
func make(_ candidates: [RemoteDialPolicy.Candidate]) -> RemoteConnector {
    Clock.reset(); NWConnection.all = []; DeviceTLS.refusals = []
    return RemoteConnector(candidates: candidates, mode: .session(pin: Data(repeating: 7, count: 32)), identity: RemoteIdentity(), queue: .main)
}
do {
    let connector = make([candidate]); var results: [RemoteConnector.Failed] = []
    connector.onFailed = { results.append($0) }; connector.start(); Clock.advance(0)
    NWConnection.all[0].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
    check(results.count == 1 && results[0].failure == .refused && results[0].retry == .transport, "real connector preserves ECONNREFUSED provenance")
    Clock.advance(500)
    check(results.count == 1 && Clock.pending == 0, "completed connector cannot emit a duplicate failure or timer")
}
do {
    var other = candidate; other.host = "100.64.1.3"
    let connector = make([candidate, other]); var result: RemoteConnector.Failed?
    connector.onFailed = { result = $0 }; connector.start(); Clock.advance(1)
    NWConnection.all[0].stateUpdateHandler?(.failed(.tls(-9816)))
    NWConnection.all[1].stateUpdateHandler?(.failed(.posix(.ECONNREFUSED)))
    check(result?.failure == .refused && result?.retry == .stop, "real connector aggregates TLS refusal before TCP refusal conservatively")
}
do {
    var lan = candidate; lan.kind = MacAddress.lan; lan.host = "192.168.1.2"
    let connector = make([lan]); var result: RemoteConnector.Failed?
    connector.onFailed = { result = $0 }; connector.start(); Clock.advance(0)
    DeviceTLS.refusals[0]?()
    check(result?.retry == .stop, "pin refusal is terminal even when LAN classification omits wrongMac")
}
do {
    let connector = make([candidate]); var results: [RemoteConnector.Failed] = []
    connector.onFailed = { results.append($0) }; connector.start(); Clock.advance(0)
    let stale = NWConnection.all[0].stateUpdateHandler
    DeviceTLS.refusals[0]?(); Clock.advance(500)
    stale?(.failed(.posix(.ECONNREFUSED))); DeviceTLS.refusals[0]?()
    check(results.count == 1 && results[0].failure == .wrongMac && results[0].retry == .stop, "verify callback makes pin mismatch terminal and ignores stale peer callbacks")
}
do {
    let connector = make([candidate]); var result: RemoteConnector.Failed?
    connector.onFailed = { result = $0 }; connector.start(); Clock.advance(20)
    check(result?.retry == .transport && Clock.pending == 0, "whole dial timeout carries transport provenance once")
}
do {
    let connector = make([]); var result: RemoteConnector.Failed?
    connector.onFailed = { result = $0 }; connector.start(); Clock.advance(0)
    check(result?.retry == .stop, "empty candidate list cannot grant retry authority")
}
do {
    let connector = make([candidate]); var count = 0
    connector.onFailed = { _ in count += 1 }; connector.start(); Clock.advance(0)
    let stale = NWConnection.all[0].stateUpdateHandler
    connector.cancel(); Clock.advance(0)
    stale?(.failed(.posix(.ECONNREFUSED))); DeviceTLS.refusals[0]?(); Clock.advance(500)
    check(count == 0 && Clock.pending == 0, "cancelled connector ignores late failure, verify callback and timer")
}
print("CONNECTOR RESULT \(checks - failures)/\(checks) passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
