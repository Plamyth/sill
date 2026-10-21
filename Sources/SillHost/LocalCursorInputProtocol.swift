import Foundation
import StreamProtocol

struct LocalCursorInteraction: Codable, Equatable {
    enum Kind: String, Codable { case windowScoped = "window-scoped", conversationScoped = "conversation-scoped" }
    let kind: Kind
    let conversationID: String?
}

struct LocalCursorCapture: Codable, Equatable {
    let pid: Int32
    let windowID: UInt32
    let instanceID: String?
    let workspace: String?
    let captureGeneration: String
    let videoEpoch: UUID
    let frameWidth: Int
    let frameHeight: Int

    var isValid: Bool {
        pid > 0 && windowID > 0 && (1...16384).contains(frameWidth) && (1...16384).contains(frameHeight) &&
        (1...128).contains(captureGeneration.utf8.count) && (instanceID?.utf8.count ?? 0) <= 128 &&
        (workspace?.utf8.count ?? 0) <= 512
    }
}

struct LocalCursorInputRequest: Decodable {
    enum Operation: String, Decodable { case hello, bindWindow, renew, input, release }
    enum Origin: String, Decodable { case ccrLocal = "ccr-local", sillDelegated = "sill-delegated" }
    let schema: Int
    let requestID: UUID
    let sequence: UInt64
    let origin: Origin
    let interaction: LocalCursorInteraction
    let operation: Operation
    let connectionID: UUID?
    let capture: LocalCursorCapture?
    let leaseID: UUID?
    let leaseGeneration: UUID?
    let captureGeneration: String?
    let videoEpoch: UUID?
    let event: InputEvent?
    let ttlMilliseconds: Int?
    let controlEnabled: Bool?
    let activate: Bool?
}

struct LocalCursorInputReply: Encodable {
    let schema = 1
    let observedAt = Date().timeIntervalSince1970
    let requestID: UUID?
    let sequence: UInt64?
    let status: String
    let code: String?
    let reason: String?
    let connectionID: UUID?
    let leaseID: UUID?
    let leaseGeneration: UUID?
    let capture: LocalCursorCapture?
    let expiresInMilliseconds: Int?
    let postedEvents: Int?
    let windowInputSupported: Bool
    let conversationInputSupported = false
    let delegatedInputSupported = false
}
