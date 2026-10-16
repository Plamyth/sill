import Foundation
public final class NWConnection {
    public enum SendCompletion { case contentProcessed((Error?) -> Void) }
    private let lock = NSLock()
    private var writes: [Data] = []
    public init() {}
    public func send(content: Data?, completion: SendCompletion) {
        lock.lock()
        if let content { writes.append(content) }
        lock.unlock()
    }
    public var sent: [Data] { lock.lock(); defer { lock.unlock() }; return writes }
    public func cancel() {}
}
