import Foundation
import Network
import StreamProtocol

final class MicrophoneIngress: @unchecked Sendable {
    struct Peer {
        let id: UUID
        let fingerprint: Data
        let connection: NWConnection
    }
    struct Control {
        let peer: Peer
        let request: MicrophoneControl
    }
    struct Frame {
        let peer: Peer
        let frame: MicrophoneFrame
        let arrived: UInt64
    }
    private struct Gate {
        let requestID: UUID
        let scope: MicrophoneScope
        let grantID: UUID
        let render: MicrophoneRenderBuffer
    }
    private let lock = NSLock()
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var gate: Gate?
    private var controls: [Control] = []
    private var closedPeers: [UUID] = []
    private var frames: [Frame] = []
    private var overflowedFrames: UInt64 = 0
    private static let frameCapacity = 6
    private var scheduled = false
    var schedule: (@Sendable () -> Void)?

    @discardableResult
    func authorize(_ connection: NWConnection, fingerprint: Data) -> Peer? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(connection)
        if let existing = peers[key] { return existing }
        guard peers.count + closedPeers.count < 32, !fingerprint.isEmpty else { return nil }
        let peer = Peer(id: UUID(), fingerprint: fingerprint, connection: connection)
        peers[key] = peer
        return peer
    }
    func peer(_ connection: NWConnection) -> Peer? {
        lock.lock(); defer { lock.unlock() }
        return peers[ObjectIdentifier(connection)]
    }
    func attach(_ request: MicrophoneControl, grantID: UUID, render: MicrophoneRenderBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard peers.values.contains(where: { $0.id == request.scope.peer }) else { render.close(); return }
        frames.removeAll(keepingCapacity: true)
        gate = Gate(requestID: request.requestID, scope: request.scope, grantID: grantID, render: render)
    }
    func close(_ connection: NWConnection) {
        lock.lock(); defer { lock.unlock() }
        guard let peer = peers.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        if gate?.scope.peer == peer.id { gate?.render.close(); gate = nil; frames.removeAll(keepingCapacity: true) }
        controls.removeAll { $0.peer.id == peer.id }
    }
    func revoke(fingerprint: Data? = nil) {
        lock.lock(); defer { lock.unlock() }
        let ids = Set(peers.values.filter { fingerprint == nil || $0.fingerprint == fingerprint }.map(\.id))
        if let gate, ids.contains(gate.scope.peer) { gate.render.close(); self.gate = nil; frames.removeAll(keepingCapacity: true) }
        controls.removeAll { ids.contains($0.peer.id) }
        if let fingerprint { peers = peers.filter { $0.value.fingerprint != fingerprint } }
    }
    func offer(_ message: StreamMessage, from connection: NWConnection, now: UInt64) {
        lock.lock()
        var cancelConnection = false
        guard let peer = peers[ObjectIdentifier(connection)] else { lock.unlock(); return }
        switch message.kind {
        case .microphoneControl:
            guard let request = MicrophoneControl.decode(message.payload), request.scope.peer == peer.id else { lock.unlock(); return }
            if request.operation == .stop, let gate, request.scope == gate.scope,
               request.grantID == gate.grantID || (request.grantID == nil && request.requestID == gate.requestID) {
                gate.render.close(); frames.removeAll(keepingCapacity: true)
            }
            if controls.count < 8 {
                controls.append(Control(peer: peer, request: request))
            } else if request.operation == .stop {
                if let index = controls.firstIndex(where: {
                    $0.peer.id == peer.id && $0.request.requestID == request.requestID && $0.request.scope == request.scope
                }) {
                    controls[index] = Control(peer: peer, request: request)
                } else {
                    if gate?.scope.peer == peer.id { gate?.render.close(); gate = nil; frames.removeAll(keepingCapacity: true) }
                    peers[ObjectIdentifier(connection)] = nil
                    controls.removeAll { $0.peer.id == peer.id }
                    closedPeers.append(peer.id)
                    cancelConnection = true
                }
            } else { lock.unlock(); return }
        case .microphoneFrame:
            guard let gate, gate.render.isOpen, let frame = MicrophoneFrame(encoded: message.payload),
                  frame.scope == gate.scope, frame.scope.peer == peer.id, frame.grantID == gate.grantID else { lock.unlock(); return }
            if let latest = frames.last, latest.frame.sequence >= frame.sequence { lock.unlock(); return }
            if frames.count == Self.frameCapacity {
                frames.removeFirst()
                if overflowedFrames < UInt64.max { overflowedFrames += 1 }
            }
            frames.append(Frame(peer: peer, frame: frame, arrived: now))
        default: lock.unlock(); return
        }
        let wake = !scheduled
        scheduled = true
        lock.unlock()
        if cancelConnection { connection.cancel() }
        if wake { schedule?() }
    }
    func take() -> ([Control], [Frame], [UUID]) {
        lock.lock(); defer { lock.unlock() }
        let result = (controls, frames, closedPeers)
        controls.removeAll(keepingCapacity: true); closedPeers.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true); scheduled = false
        return result
    }
    var overflowCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return overflowedFrames
    }
}

final class MicrophoneReplyMailbox: @unchecked Sendable {
    private struct Reply {
        let message: StreamMessage
        let connection: NWConnection
        let render: MicrophoneRenderBuffer?
    }
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Reply] = [:]
    private var scheduled = false
    func offer(_ message: StreamMessage, connection: NWConnection, render: MicrophoneRenderBuffer?,
               queue: DispatchQueue, deliver: @escaping (StreamMessage, NWConnection, MicrophoneRenderBuffer?) -> Void) {
        lock.lock()
        let key = ObjectIdentifier(connection)
        guard pending[key] != nil || pending.count < 32 else { lock.unlock(); return }
        pending[key] = Reply(message: message, connection: connection, render: render)
        let wake = !scheduled
        scheduled = true
        lock.unlock()
        guard wake else { return }
        queue.async { [self] in
            lock.lock()
            let replies = Array(pending.values)
            pending.removeAll(keepingCapacity: true); scheduled = false
            lock.unlock()
            for reply in replies {
                if let render = reply.render {
                    guard render.isOpen, render.grant.valid(at: DispatchTime.now().uptimeNanoseconds) else { continue }
                }
                deliver(reply.message, reply.connection, reply.render)
            }
        }
    }
}
