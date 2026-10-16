import Foundation
public struct NWError: Error {}
public final class NWConnection: @unchecked Sendable {
    public enum SendCompletion { case contentProcessed((Error?) -> Void) }
    public enum State { case ready, cancelled }
    public var state = State.ready
    public let endpoint = "inert-peer"
    public var inbound: [Data] = []
    public var requests: [Int] = []
    public var sent: [Data] = []
    public init() {}
    public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                        completion: (Data?, String?, Bool, NWError?) -> Void) {
        requests.append(maximumLength)
        guard !inbound.isEmpty else { return }
        let next = inbound.removeFirst()
        completion(next, nil, false, nil)
    }
    public func send(content: Data?, completion: SendCompletion) {
        if let content { sent.append(content) }
        if case .contentProcessed(let done) = completion { done(nil) }
    }
    public func cancel() { state = .cancelled }
}
