import Foundation
import os
public struct NWError: Error {}
public final class NWConnection: @unchecked Sendable {
    public enum SendCompletion { case contentProcessed(@Sendable (NWError?) -> Void) }
    private let storage = OSAllocatedUnfairLock(initialState:[Data]())
    public var sent: [Data] { storage.withLock { $0 } }
    public init() {}
    public func send(content: Data?, completion: SendCompletion) {
        if let content { storage.withLock { $0.append(content) } }
        DispatchQueue.global().async {
            if case .contentProcessed(let callback) = completion { callback(nil) }
        }
    }
}
