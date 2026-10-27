final class PeerCloseTrace {
    enum Reason: String {
        case receiveHeaderError = "receive_header_error"
        case headerEOF = "header_eof"
        case roleRejected = "role_rejected"
        case payloadLimit = "payload_limit"
        case receivePayloadError = "receive_payload_error"
        case payloadEOF = "payload_eof"
        case payloadLength = "payload_length"
        case helloDecode = "hello_decode"
        case sendError = "send_error"
        case transportFailed = "transport_failed"
        case notDraining = "not_draining"
    }

    enum ErrorDomain: String { case posix, dns, tls, unknown }
    struct NetworkFailure: Equatable {
        let domain: ErrorDomain
        let code: Int32
    }
    struct Failure: Equatable {
        let reason: Reason
        var kind: UInt8? = nil
        var received: Int? = nil
        var expected: Int? = nil
        var network: NetworkFailure? = nil
    }
    enum Terminal: String { case failed, cancelled, unregistered }

    private(set) var connectionID: UInt64?
    private let emit: (String) -> Void
    private(set) var firstFailure: Failure?
    private(set) var terminal: Terminal?
    private var incomingKind: UInt8?
    private var outgoingKind: UInt8?
    private var receivedBytes: UInt64 = 0
    private var queuedBytes: UInt64 = 0
    private var processedBytes: UInt64 = 0

    init(emit: @escaping (String) -> Void = { print($0) }) { self.emit = emit }

    func bind(_ id: UInt64) {
        guard connectionID == nil else { return }
        connectionID = id
    }

    func received(_ bytes: Int, kind: UInt8? = nil) {
        receivedBytes += UInt64(bytes)
        if let kind { incomingKind = kind }
    }

    func queued(_ bytes: Int, kind: UInt8) {
        queuedBytes += UInt64(bytes)
        outgoingKind = kind
    }

    func processed(_ bytes: Int) { processedBytes += UInt64(bytes) }

    func failed(_ failure: Failure) {
        guard let connectionID, firstFailure == nil else { return }
        firstFailure = failure
        emit("[연결 진단] id=\(connectionID) event=first_failure reason=\(failure.reason.rawValue)" +
             " kind=\(number(failure.kind)) received=\(number(failure.received)) expected=\(number(failure.expected))" +
             " error_domain=\(failure.network?.domain.rawValue ?? "none") error_code=\(number(failure.network?.code))" +
             " after_close=\(terminal != nil) " + counters)
    }

    func closed(_ state: Terminal) {
        guard let connectionID, terminal == nil else { return }
        terminal = state
        emit("[연결 진단] id=\(connectionID) event=close state=\(state.rawValue)" +
             " first_failure=\(firstFailure?.reason.rawValue ?? "unclassified") " + counters)
    }

    private func number<T: FixedWidthInteger>(_ value: T?) -> String {
        value.map { String($0) } ?? "none"
    }

    // Queued/processed are NWConnection stages, not peer receipts or billed network bytes.
    private var counters: String {
        "rx_kind=\(number(incomingKind)) tx_kind=\(number(outgoingKind))" +
        " read_bytes=\(receivedBytes) queued_bytes=\(queuedBytes) processed_bytes=\(processedBytes)"
    }
}
