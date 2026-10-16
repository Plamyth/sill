import Foundation

public struct NWError: Error {}
public final class NWConnection: @unchecked Sendable {
    public enum SendCompletion { case contentProcessed(@Sendable (NWError?) -> Void) }
    public enum State { case ready, cancelled }
    public var state = State.ready
    public let endpoint = "inert-pipeline"
    public var inbound: [Data] = []
    public var requests: [Int] = []
    private let lock = NSLock()
    private var output: [Data] = []
    private var completions = 0
    public var pendingCompletions: Int {
        lock.lock(); defer { lock.unlock() }; return completions
    }
    public var sent: [Data] {
        get { lock.lock(); defer { lock.unlock() }; return output }
        set { lock.lock(); output = newValue; lock.unlock() }
    }
    public init() {}
    public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                        completion: (Data?, String?, Bool, NWError?) -> Void) {
        requests.append(maximumLength)
        guard !inbound.isEmpty else { return }
        let next = inbound.removeFirst()
        precondition(next.count <= maximumLength && next.count >= minimumIncompleteLength)
        completion(next, nil, false, nil)
    }
    public func send(content: Data?, completion: SendCompletion) {
        lock.lock()
        if let content { output.append(content) }
        completions += 1
        lock.unlock()
        DispatchQueue.global().async { [self] in
            if case .contentProcessed(let done) = completion { done(nil) }
            lock.lock(); completions -= 1; lock.unlock()
        }
    }
    public func cancel() { state = .cancelled }
}
