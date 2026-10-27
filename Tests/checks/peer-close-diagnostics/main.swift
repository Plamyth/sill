import Foundation
import Network

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

var lines: [String] = []
let trace = PeerCloseTrace { lines.append($0) }
trace.failed(.init(reason: .transportFailed))
trace.closed(.failed)
check(lines.isEmpty, "Unregistered connections have no shared diagnostic id")
trace.bind(7)
trace.bind(99)
trace.received(24, kind: 23)
trace.received(105)
trace.received(24, kind: 9)
trace.received(48)
trace.queued(2048, kind: 1)
trace.processed(768)
let original = PeerCloseTrace.Failure(reason: .sendError, kind: 1,
    network: .init(domain: .posix, code: 54))
trace.failed(original)
trace.failed(.init(reason: .receiveHeaderError, network: .init(domain: .posix, code: 57)))
trace.closed(.cancelled)
trace.closed(.unregistered)
check(trace.firstFailure == original, "Read/cleanup errors must not erase the first write failure")
check(trace.terminal == .cancelled, "Repeated cleanup must not change the first terminal state")
check(lines.count == 2, "At most one first-failure and one close line per registered connection")
check(lines.allSatisfy { $0.contains("id=7 ") }, "A diagnostic id cannot be rebound")
check(lines[0].contains("error_domain=posix error_code=54"), "Keep a numeric network error, not its description")
check(lines[1].contains("rx_kind=9 tx_kind=1"), "Keep the most recent message kinds")
check(lines[1].contains("read_bytes=201 queued_bytes=2048 processed_bytes=768"), "Wire stages must not be conflated")
check(lines[0].contains("after_close=false"), "A synchronous write failure precedes cleanup")

var late: [String] = []
let delayed = PeerCloseTrace { late.append($0) }
delayed.bind(8)
delayed.closed(.cancelled)
check(late[0].contains("first_failure=unclassified"), "Cancellation alone does not establish a peer/protocol cause")
delayed.failed(.init(reason: .sendError, kind: 1, network: .init(domain: .tls, code: -9806)))
delayed.failed(.init(reason: .headerEOF))
check(late.count == 2, "A late send callback is retained without another close line")
check(late[1].contains("after_close=true"), "Mark late failures instead of rewriting causal order")
check(delayed.firstFailure?.reason == .sendError, "A close notification must not hide a later-observed send failure")
check(delayed.terminal == .cancelled, "Late errors do not restart or alter a connection")
check(trace.firstFailure == original, "Two connections keep independent first failures")

final class ClientStandin { let trace: PeerCloseTrace; init(_ value: PeerCloseTrace) { trace = value } }
var lifetime: [String] = []
var client: ClientStandin? = ClientStandin(PeerCloseTrace { lifetime.append($0) })
client!.trace.bind(9)
weak var weakClient = client
let callback: () -> Void = { [savedTrace = client!.trace] in
    savedTrace.failed(.init(reason: .sendError, network: .init(domain: .dns, code: -65537)))
}
client = nil
check(weakClient == nil, "Retaining a diagnostic must not retain the former Client")
callback()
check(lifetime.count == 1 && lifetime[0].contains("id=9 "), "A send callback can report after Client release")

for (index, reason) in PeerCloseTrace.ReasonTests.all.enumerated() {
    var output: [String] = []
    let item = PeerCloseTrace { output.append($0) }
    item.bind(UInt64(index + 20))
    item.failed(.init(reason: reason, kind: 9, received: 5, expected: 24))
    item.closed(.failed)
    check(output.count == 2 && output[0].contains("received=5 expected=24"), "Numeric receive context is retained")
    check(output.allSatisfy { !$0.contains("https:") && !$0.contains("payload=") && !$0.contains("message=") },
          "The trace accepts no payload, endpoint, token or arbitrary error description")
}

extension PeerCloseTrace {
    enum ReasonTests {
        static let all: [Reason] = [.receiveHeaderError, .headerEOF, .roleRejected, .payloadLimit,
            .receivePayloadError, .payloadEOF, .payloadLength, .helloDecode, .sendError, .transportFailed, .notDraining]
    }
}
for bytes in [5, StreamMessage.headerLength] {
    let value = PeerCloseTrace { _ in }
    value.bind(100)
    EntryHarness.header(EntryClient(value), data: Data(repeating: 0, count: bytes), error: .posix(.ECONNRESET))
    check(value.firstFailure?.reason == .receiveHeaderError, "Data plus a header error must keep the numeric receive failure")
    check(value.firstFailure?.network?.code == POSIXErrorCode.ECONNRESET.rawValue, "Preserve the real NWError numeric code")
    check(value.firstFailure?.received == bytes, "Keep both complete and partial header byte counts")
}
for bytes in [5, 64] {
    let value = PeerCloseTrace { _ in }
    value.bind(101)
    let header = StreamHeader(kind: StreamMessageKind(rawValue: 9)!, timestamp: 0, isKeyframe: false, payloadLength: 64)
    EntryHarness.payload(EntryClient(value), data: Data(repeating: 0, count: bytes), header: header, error: .posix(.ECONNRESET))
    check(value.firstFailure?.reason == .receivePayloadError, "Data plus an error must not become only a length mismatch")
    check(value.firstFailure?.received == bytes && value.firstFailure?.expected == 64, "Keep exact numeric payload context")
}
let directCallbacks: [(PeerCloseTrace, NWError?) -> (Int, Int)] = [
    EntryHarness.direct0, EntryHarness.direct1, EntryHarness.direct2, EntryHarness.direct3
]
for (index, callback) in directCallbacks.enumerated() {
    var output: [String] = []
    let value = PeerCloseTrace { output.append($0) }
    value.bind(UInt64(200 + index))
    value.closed(.cancelled)
    let (cancelled, left) = callback(value, .posix(.ECONNRESET))
    check(value.firstFailure?.reason == .sendError, "Each actual direct-send callback must preserve its first send error")
    check(output.last?.contains("after_close=true") == true, "Direct-send callbacks remain observable after unregister")
    check(cancelled == (index == 2 ? 1 : 0), "Diagnostic logging must not add or lose the original goodbye cancellation")
    check(left == (index == 3 ? 1 : 0), "Diagnostic logging must retain the original shutdown group completion")
}
print("peer-close-diagnostics: \(checks) checks passed")
