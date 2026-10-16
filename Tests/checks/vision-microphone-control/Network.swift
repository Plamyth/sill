import Foundation
public struct NWError: Error {}
public final class NWConnection: @unchecked Sendable {
    public enum SendCompletion { case contentProcessed(@Sendable (NWError?) -> Void) }
    public var sent: [Data] = []
    public init() {}
    public func send(content: Data?, completion: SendCompletion) {
        if let content { sent.append(content) }
        DispatchQueue.global().async {
            if case .contentProcessed(let callback) = completion { callback(nil) }
        }
    }
}
