import StreamProtocol

enum StreamPeerRole: Equatable {
    case awaitingHello, controlOnly, viewer

    var isViewer: Bool { if case .viewer = self { return true }; return false }

    func accepts(_ kind: StreamMessageKind) -> Bool {
        isViewer || kind == .hello || kind == .ping || kind == .forwardingControl
    }

    func sends(_ kind: StreamMessageKind) -> Bool {
        isViewer || kind == .pong || kind == .goodbye ||
            (self == .controlOnly && kind == .forwardingState)
    }
}
