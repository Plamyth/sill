import Foundation

final class VisionInputFence {
    private struct Pending {
        let peer: ObjectIdentifier
        let finished: (Bool) -> Void
    }
    private let queue: DispatchQueue
    private var pending: [Data: Pending] = [:]

    init(queue: DispatchQueue) { self.queue = queue }

    @discardableResult
    func begin(peer: ObjectIdentifier, timeout: TimeInterval = 8, send: (Data) -> Void,
               finished: @escaping (Bool) -> Void) -> Data {
        dispatchPrecondition(condition: .onQueue(queue))
        let nonce = Data(UUID().uuidString.utf8)
        pending[nonce] = Pending(peer: peer, finished: finished)
        send(nonce)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.pending.removeValue(forKey: nonce)?.finished(false)
        }
        return nonce
    }

    @discardableResult
    func receive(_ nonce: Data, peer: ObjectIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let entry = pending[nonce], entry.peer == peer else { return false }
        pending.removeValue(forKey: nonce)
        entry.finished(true)
        return true
    }
}
