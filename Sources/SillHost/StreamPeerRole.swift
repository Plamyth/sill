import StreamProtocol

enum StreamPeerRole {
    case awaitingHello, viewer

    var isViewer: Bool { if case .viewer = self { return true }; return false }

    func accepts(_ kind: StreamMessageKind) -> Bool {
        isViewer || kind == .hello || kind == .ping
    }

    func sends(_ kind: StreamMessageKind) -> Bool {
        isViewer || kind == .windowList || kind == .pong || kind == .goodbye
    }
}
