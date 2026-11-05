import Foundation
import CryptoKit

public enum ProviderCallWireFailure: Error { case invalidFields, invalidRequest, invalidResult, invalidTarget }

private struct ProviderCallFieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func providerCallKeys(_ decoder: Decoder, required: Set<String>) throws {
    guard Set(try decoder.container(keyedBy: ProviderCallFieldKey.self).allKeys.map(\.stringValue)) == required else {
        throw ProviderCallWireFailure.invalidFields
    }
}

/// Prepared target from the Core/Host contract at Host 8a59b524. A matching hash only
/// validates the target's bytes; it does not attest a started call, authority, or media.
public struct CodexRealtimePreparedTarget: Decodable, Equatable, Sendable {
    public let schema: String
    public let providerKind: String
    public let providerInstanceId: String
    public let threadId: String
    public let voiceSessionId: String
    public let targetHash: String
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, providerKind, providerInstanceId, threadId, voiceSessionId, targetHash
    }
    public init(from decoder: Decoder) throws {
        try providerCallKeys(decoder, required: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        providerKind = try c.decode(String.self, forKey: .providerKind)
        providerInstanceId = try c.decode(String.self, forKey: .providerInstanceId)
        threadId = try c.decode(String.self, forKey: .threadId)
        voiceSessionId = try c.decode(String.self, forKey: .voiceSessionId)
        targetHash = try c.decode(String.self, forKey: .targetHash)
        _ = try hash()
    }
    public func hash() throws -> String {
        guard schema == "ccr-codex-realtime-target-v1", providerKind == "codex-app-server",
              [providerInstanceId, threadId, voiceSessionId].allSatisfy({ raw in
                  guard let id = UUID(uuidString: raw) else { return false }
                  return id.uuidString.lowercased() == raw.lowercased()
              }) else { throw ProviderCallWireFailure.invalidTarget }
        // Preserve UUID source case. This is JSON.stringify of the five strings, not
        // the Dots target hash or the length-prefixed ProviderCallRequest digest.
        let bytes = try JSONSerialization.data(withJSONObject:
            [schema, providerKind, providerInstanceId, threadId, voiceSessionId], options: [.withoutEscapingSlashes])
        let computed = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard targetHash == computed else { throw ProviderCallWireFailure.invalidTarget }
        return computed
    }
}

public struct ProviderCallRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case start, stop }
    public let requestId: UUID
    public let action: Action
    public let expectedLeaseRevision: AudioForwardingRevision
    public let pairedDeviceId: AudioForwardingDeviceID
    public let desiredInput: Bool
    public let desiredOutput: Bool
    public let callSessionId: String?
    enum CodingKeys: String, CodingKey, CaseIterable {
        case requestId, action, expectedLeaseRevision, pairedDeviceId, desiredInput, desiredOutput, callSessionId
    }
    public init(requestId: UUID, action: Action, expectedLeaseRevision: AudioForwardingRevision,
                pairedDeviceId: AudioForwardingDeviceID, desiredInput: Bool, desiredOutput: Bool,
                callSessionId: String?) throws {
        guard action != .start || callSessionId == nil,
              callSessionId.map({ !$0.isEmpty && $0.utf16.count <= 128 }) ?? true else {
            throw ProviderCallWireFailure.invalidRequest
        }
        self.requestId = requestId; self.action = action; self.expectedLeaseRevision = expectedLeaseRevision
        self.pairedDeviceId = pairedDeviceId; self.desiredInput = desiredInput; self.desiredOutput = desiredOutput
        self.callSessionId = callSessionId
    }
    public init(from decoder: Decoder) throws {
        try providerCallKeys(decoder, required: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .requestId)
        guard let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw.lowercased() else {
            throw ProviderCallWireFailure.invalidRequest
        }
        requestId = id
        action = try c.decode(Action.self, forKey: .action)
        expectedLeaseRevision = try c.decode(AudioForwardingRevision.self, forKey: .expectedLeaseRevision)
        pairedDeviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .pairedDeviceId)
        desiredInput = try c.decode(Bool.self, forKey: .desiredInput)
        desiredOutput = try c.decode(Bool.self, forKey: .desiredOutput)
        callSessionId = try c.decodeIfPresent(String.self, forKey: .callSessionId)
        guard action != .start || callSessionId == nil,
              callSessionId.map({ !$0.isEmpty && $0.utf16.count <= 128 }) ?? true else {
            throw ProviderCallWireFailure.invalidRequest
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try c.encode(action, forKey: .action)
        try c.encode(expectedLeaseRevision, forKey: .expectedLeaseRevision)
        try c.encode(pairedDeviceId, forKey: .pairedDeviceId)
        try c.encode(desiredInput, forKey: .desiredInput)
        try c.encode(desiredOutput, forKey: .desiredOutput)
        try c.encode(callSessionId, forKey: .callSessionId)
    }
    public var digest: String {
        var data = Data("ccr-provider-request-v1\0".utf8)
        func append(_ text: String) {
            let bytes = Data(text.utf8)
            var size = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        append(requestId.uuidString.lowercased())
        append(action.rawValue)
        append(String(expectedLeaseRevision.value))
        append(pairedDeviceId.hex)
        data.append(desiredInput ? 1 : 0)
        data.append(desiredOutput ? 1 : 0)
        data.append(callSessionId == nil ? 0 : 1)
        if let callSessionId { append(callSessionId) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func matches(_ snapshot: AudioForwardingSnapshot) -> Bool {
        snapshot.revision == expectedLeaseRevision && snapshot.intent?.pairedDeviceId == pairedDeviceId &&
            snapshot.intent?.inputDesired == desiredInput && snapshot.intent?.outputDesired == desiredOutput &&
            snapshot.binding?.pairedDeviceId == pairedDeviceId &&
            (snapshot.binding?.phase == .active || action == .stop && snapshot.binding?.phase == .off)
    }
}

public struct ProviderCallControl: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case perform, query }
    public let schemaVersion: Int
    public let operation: Operation
    public let request: ProviderCallRequest
    private enum CodingKeys: String, CodingKey { case schemaVersion, operation, request }
    public init(operation: Operation, request: ProviderCallRequest) {
        schemaVersion = 1; self.operation = operation; self.request = request
    }
    public init(from decoder: Decoder) throws {
        try providerCallKeys(decoder, required: ["schemaVersion", "operation", "request"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        operation = try c.decode(Operation.self, forKey: .operation)
        request = try c.decode(ProviderCallRequest.self, forKey: .request)
        guard schemaVersion == 1 else { throw ProviderCallWireFailure.invalidRequest }
    }
}

public struct ProviderCallResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case started, stopped, unsupported, failed, unknown, pending }
    public let requestId: UUID
    public let status: Status
    public let reason: String
    public let callSessionId: String?
    public let provider: String
    public let mediaProtection: String
    private enum CodingKeys: String, CodingKey {
        case requestId, status, reason, callSessionId, provider, mediaProtection
    }
    public init(requestId: UUID, status: Status, reason: String, callSessionId: String? = nil,
                provider: String = "chatgpt-dots-webguest") throws {
        self.requestId = requestId; self.status = status; self.reason = reason; self.callSessionId = callSessionId
        self.provider = provider; mediaProtection = "not_attested"
        try validate()
    }
    public init(from decoder: Decoder) throws {
        try providerCallKeys(decoder, required: ["requestId", "status", "reason", "callSessionId", "provider", "mediaProtection"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(UUID.self, forKey: .requestId)
        status = try c.decode(Status.self, forKey: .status)
        reason = try c.decode(String.self, forKey: .reason)
        callSessionId = try c.decodeIfPresent(String.self, forKey: .callSessionId)
        provider = try c.decode(String.self, forKey: .provider)
        mediaProtection = try c.decode(String.self, forKey: .mediaProtection)
        try validate()
    }
    private func validate() throws {
        guard ["chatgpt-dots-webguest", "codex-app-server"].contains(provider), mediaProtection == "not_attested",
              reason.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil,
              callSessionId.map({ !$0.isEmpty && $0.utf16.count <= 128 }) ?? true else {
            throw ProviderCallWireFailure.invalidResult
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try c.encode(status, forKey: .status)
        try c.encode(reason, forKey: .reason)
        try c.encode(callSessionId, forKey: .callSessionId)
        try c.encode(provider, forKey: .provider)
        try c.encode(mediaProtection, forKey: .mediaProtection)
    }
}

public struct ProviderCallState: Codable, Sendable {
    public let schemaVersion: Int
    public let requestDigest: String
    public let result: ProviderCallResult
    private enum CodingKeys: String, CodingKey { case schemaVersion, requestDigest, result }
    public init(request: ProviderCallRequest, result: ProviderCallResult) throws {
        guard request.requestId == result.requestId else { throw ProviderCallWireFailure.invalidResult }
        schemaVersion = 1; requestDigest = request.digest; self.result = result
    }
    public init(from decoder: Decoder) throws {
        try providerCallKeys(decoder, required: ["schemaVersion", "requestDigest", "result"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        requestDigest = try c.decode(String.self, forKey: .requestDigest)
        result = try c.decode(ProviderCallResult.self, forKey: .result)
        guard schemaVersion == 1, requestDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ProviderCallWireFailure.invalidResult
        }
    }
}
