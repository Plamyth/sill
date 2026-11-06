import Foundation

public enum ConfiguredCraftActionFailure: Error { case invalidFields, invalidValue, invalidCorrelation }

private struct CraftKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func craftKeys(_ decoder: Decoder, _ required: Set<String>, optional: Set<String> = []) throws {
    let keys = Set(try decoder.container(keyedBy: CraftKey.self).allKeys.map(\.stringValue))
    guard keys.isSuperset(of: required), keys.isSubset(of: required.union(optional)) else {
        throw ConfiguredCraftActionFailure.invalidFields
    }
}

private func craftUUID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else {
        throw ConfiguredCraftActionFailure.invalidValue
    }
    return id
}
private func craftHash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
private func craftReason(_ value: String) -> Bool {
    value.range(of: "^[a-z][a-z0-9_]{0,79}$", options: .regularExpression) != nil
}
private func craftResultReason(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
}

public struct ConfiguredCraftActionCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let supported: Bool
    public let expectedProfileId: String
    public let inputID: String
    public let trigger: String
    public let expectedAssignmentSha256: String
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, supported, expectedProfileId, inputID, trigger, expectedAssignmentSha256
    }
    public init(expectedProfileId: UUID, expectedAssignmentSha256: String) throws {
        guard craftHash(expectedAssignmentSha256) else { throw ConfiguredCraftActionFailure.invalidValue }
        schemaVersion = 1; supported = true; inputID = "speed.button.stop-play"; trigger = "longPress"
        self.expectedProfileId = expectedProfileId.uuidString.lowercased()
        self.expectedAssignmentSha256 = expectedAssignmentSha256
    }
    public init(from decoder: Decoder) throws {
        try craftKeys(decoder, ["schemaVersion", "supported", "expectedProfileId", "inputID", "trigger", "expectedAssignmentSha256"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        supported = try c.decode(Bool.self, forKey: .supported)
        expectedProfileId = try c.decode(String.self, forKey: .expectedProfileId)
        inputID = try c.decode(String.self, forKey: .inputID); trigger = try c.decode(String.self, forKey: .trigger)
        expectedAssignmentSha256 = try c.decode(String.self, forKey: .expectedAssignmentSha256)
        _ = try craftUUID(expectedProfileId)
        guard schemaVersion == 1, supported, inputID == "speed.button.stop-play", trigger == "longPress",
              craftHash(expectedAssignmentSha256) else { throw ConfiguredCraftActionFailure.invalidValue }
    }
}

public struct ConfiguredCraftActionRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operation: String
    public let operationId: UUID
    public let deviceId: AudioForwardingDeviceID
    public let inputID: String
    public let trigger: String
    public let expectedProfileId: String
    public let expectedAssignmentSha256: String
    public let issuedAt: Int64
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, operation, operationId, deviceId, inputID, trigger,
             expectedProfileId, expectedAssignmentSha256, issuedAt
    }
    public init(operationId: UUID, deviceId: AudioForwardingDeviceID,
                catalog: ConfiguredCraftActionCatalog, issuedAt: Int64) throws {
        guard issuedAt > 0, issuedAt <= 9_007_199_254_740_991 else { throw ConfiguredCraftActionFailure.invalidValue }
        schemaVersion = 1; operation = "invoke-configured-craft-action"
        self.operationId = operationId; self.deviceId = deviceId
        inputID = catalog.inputID; trigger = catalog.trigger; expectedProfileId = catalog.expectedProfileId
        expectedAssignmentSha256 = catalog.expectedAssignmentSha256; self.issuedAt = issuedAt
    }
    public init(from decoder: Decoder) throws {
        try craftKeys(decoder, ["schemaVersion", "operation", "operationId", "deviceId", "inputID", "trigger",
                                "expectedProfileId", "expectedAssignmentSha256", "issuedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        operation = try c.decode(String.self, forKey: .operation)
        operationId = try craftUUID(c.decode(String.self, forKey: .operationId))
        deviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .deviceId)
        inputID = try c.decode(String.self, forKey: .inputID); trigger = try c.decode(String.self, forKey: .trigger)
        expectedProfileId = try c.decode(String.self, forKey: .expectedProfileId)
        expectedAssignmentSha256 = try c.decode(String.self, forKey: .expectedAssignmentSha256)
        issuedAt = try c.decode(Int64.self, forKey: .issuedAt)
        _ = try craftUUID(expectedProfileId)
        guard schemaVersion == 1, operation == "invoke-configured-craft-action", inputID == "speed.button.stop-play",
              trigger == "longPress", craftHash(expectedAssignmentSha256), issuedAt > 0,
              issuedAt <= 9_007_199_254_740_991 else { throw ConfiguredCraftActionFailure.invalidValue }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(operation, forKey: .operation)
        try c.encode(operationId.uuidString.lowercased(), forKey: .operationId); try c.encode(deviceId, forKey: .deviceId)
        try c.encode(inputID, forKey: .inputID); try c.encode(trigger, forKey: .trigger)
        try c.encode(expectedProfileId, forKey: .expectedProfileId)
        try c.encode(expectedAssignmentSha256, forKey: .expectedAssignmentSha256); try c.encode(issuedAt, forKey: .issuedAt)
    }
}

public struct ConfiguredCraftActionResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case invoked, rejected, unknown }
    public let outcome: Outcome
    public let operationId: UUID
    public let deviceId: AudioForwardingDeviceID
    public let bindingSha256: String?
    public let invoked: Bool
    public let effectConfirmed: Bool
    public let reason: String?
    private enum CodingKeys: String, CodingKey { case outcome, operationId, deviceId, bindingSha256, invoked, effectConfirmed, reason }
    public init(outcome: Outcome, operationId: UUID, deviceId: AudioForwardingDeviceID,
                bindingSha256: String?, invoked: Bool, reason: String? = nil) throws {
        guard bindingSha256.map(craftHash) ?? true, reason.map(craftResultReason) ?? true else {
            throw ConfiguredCraftActionFailure.invalidValue
        }
        self.outcome = outcome; self.operationId = operationId; self.deviceId = deviceId
        self.bindingSha256 = bindingSha256; self.invoked = invoked; effectConfirmed = false; self.reason = reason
    }
    public init(from decoder: Decoder) throws {
        try craftKeys(decoder, ["outcome", "operationId", "deviceId", "bindingSha256", "invoked", "effectConfirmed"], optional: ["reason"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        operationId = try craftUUID(c.decode(String.self, forKey: .operationId))
        deviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .deviceId)
        bindingSha256 = try c.decodeIfPresent(String.self, forKey: .bindingSha256)
        invoked = try c.decode(Bool.self, forKey: .invoked); effectConfirmed = try c.decode(Bool.self, forKey: .effectConfirmed)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        guard !effectConfirmed, bindingSha256.map(craftHash) ?? true, reason.map(craftResultReason) ?? true,
              !c.contains(.reason) || reason != nil else { throw ConfiguredCraftActionFailure.invalidValue }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outcome, forKey: .outcome); try c.encode(operationId.uuidString.lowercased(), forKey: .operationId)
        try c.encode(deviceId, forKey: .deviceId); try c.encode(bindingSha256, forKey: .bindingSha256)
        try c.encode(invoked, forKey: .invoked); try c.encode(false, forKey: .effectConfirmed)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
}

public struct ConfiguredCraftActionControl: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case catalog, invoke, query }
    public let schemaVersion: Int
    public let requestId: UUID
    public let operation: Operation
    public let client: ConfiguredCraftActionRequest?
    public let operationId: UUID?
    private enum CodingKeys: String, CodingKey { case schemaVersion, requestId, operation, client, operationId }
    public init(requestId: UUID, client: ConfiguredCraftActionRequest) {
        schemaVersion = 1; self.requestId = requestId; operation = .invoke; self.client = client; operationId = nil
    }
    public init(requestId: UUID, operationId: UUID? = nil) {
        schemaVersion = 1; self.requestId = requestId; operation = operationId == nil ? .catalog : .query
        client = nil; self.operationId = operationId
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = try c.decode(Operation.self, forKey: .operation)
        var keys: Set<String> = ["schemaVersion", "requestId", "operation"]
        if operation == .invoke { keys.insert("client") }
        if operation == .query { keys.insert("operationId") }
        try craftKeys(decoder, keys)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        requestId = try craftUUID(c.decode(String.self, forKey: .requestId))
        client = operation == .invoke ? try c.decode(ConfiguredCraftActionRequest.self, forKey: .client) : nil
        operationId = operation == .query ? try craftUUID(c.decode(String.self, forKey: .operationId)) : nil
        guard schemaVersion == 1 else { throw ConfiguredCraftActionFailure.invalidValue }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try c.encode(operation, forKey: .operation); try c.encodeIfPresent(client, forKey: .client)
        try c.encodeIfPresent(operationId?.uuidString.lowercased(), forKey: .operationId)
    }
    public static func decode(_ data: Data) throws -> Self { try CraftJSON.decode(Self.self, data, limit: 4096) }
    public var targetOperationId: UUID? { client?.operationId ?? operationId }
}

public struct ConfiguredCraftActionState: Codable, Sendable {
    public let schemaVersion: Int
    public let requestId: UUID
    public let operation: ConfiguredCraftActionControl.Operation
    public let deviceId: AudioForwardingDeviceID
    public let catalog: ConfiguredCraftActionCatalog?
    public let result: ConfiguredCraftActionResult?
    public let error: String?
    private enum CodingKeys: String, CodingKey { case schemaVersion, requestId, operation, deviceId, catalog, result, error }
    public init(control: ConfiguredCraftActionControl, deviceId: AudioForwardingDeviceID,
                catalog: ConfiguredCraftActionCatalog? = nil, result: ConfiguredCraftActionResult? = nil,
                error: String? = nil) throws {
        schemaVersion = 1; requestId = control.requestId; operation = control.operation; self.deviceId = deviceId
        self.catalog = catalog; self.result = result; self.error = error
        try validate()
        guard matches(control) else { throw ConfiguredCraftActionFailure.invalidCorrelation }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let payload = [CodingKeys.catalog, .result, .error].filter { c.contains($0) }
        guard payload.count == 1 else { throw ConfiguredCraftActionFailure.invalidFields }
        try craftKeys(decoder, ["schemaVersion", "requestId", "operation", "deviceId", payload[0].rawValue])
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        requestId = try craftUUID(c.decode(String.self, forKey: .requestId))
        operation = try c.decode(ConfiguredCraftActionControl.Operation.self, forKey: .operation)
        deviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .deviceId)
        catalog = try c.decodeIfPresent(ConfiguredCraftActionCatalog.self, forKey: .catalog)
        result = try c.decodeIfPresent(ConfiguredCraftActionResult.self, forKey: .result)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        try validate()
    }
    private func validate() throws {
        guard schemaVersion == 1, [catalog != nil, result != nil, error != nil].filter({ $0 }).count == 1,
              catalog == nil || operation == .catalog, result == nil || operation != .catalog,
              result == nil || result?.deviceId == deviceId, error.map(craftReason) ?? true else {
            throw ConfiguredCraftActionFailure.invalidValue
        }
    }
    public func matches(_ control: ConfiguredCraftActionControl) -> Bool {
        requestId == control.requestId && operation == control.operation &&
            (error != nil || control.client == nil || control.client?.deviceId == deviceId) &&
            (result == nil || result?.operationId == control.targetOperationId)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try c.encode(operation, forKey: .operation); try c.encode(deviceId, forKey: .deviceId)
        try c.encodeIfPresent(catalog, forKey: .catalog); try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(error, forKey: .error)
    }
    public static func decode(_ data: Data) throws -> Self { try CraftJSON.decode(Self.self, data, limit: 16384) }
}

// JSONDecoder accepts integral fractions and exponents. Validate the original tokens before decoding.
private struct CraftJSON {
    let bytes: [UInt8]
    var offset = 0
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, limit: Int) throws -> T {
        guard !data.isEmpty, data.count <= limit, String(data: data, encoding: .utf8) != nil else {
            throw ConfiguredCraftActionFailure.invalidFields
        }
        var scan = Self(bytes: Array(data))
        try scan.value(depth: 0); scan.space()
        guard scan.offset == scan.bytes.count else { throw ConfiguredCraftActionFailure.invalidFields }
        return try JSONDecoder().decode(type, from: data)
    }
    mutating func space() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    mutating func string() throws -> String {
        let start = offset; offset += 1
        while offset < bytes.count {
            if bytes[offset] == 34 {
                offset += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
            offset += bytes[offset] == 92 ? 2 : 1
        }
        throw ConfiguredCraftActionFailure.invalidFields
    }
    mutating func value(depth: Int) throws {
        space()
        guard depth < 8, offset < bytes.count else { throw ConfiguredCraftActionFailure.invalidFields }
        if bytes[offset] == 34 { _ = try string(); return }
        if bytes[offset] == 123 {
            offset += 1; space(); var keys = Set<String>()
            if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
            while offset < bytes.count {
                space()
                guard offset < bytes.count, bytes[offset] == 34, keys.insert(try string()).inserted else {
                    throw ConfiguredCraftActionFailure.invalidFields
                }
                space()
                guard offset < bytes.count, bytes[offset] == 58 else { throw ConfiguredCraftActionFailure.invalidFields }
                offset += 1; try value(depth: depth + 1); space()
                guard offset < bytes.count else { throw ConfiguredCraftActionFailure.invalidFields }
                if bytes[offset] == 125 { offset += 1; return }
                guard bytes[offset] == 44 else { throw ConfiguredCraftActionFailure.invalidFields }
                offset += 1
            }
            throw ConfiguredCraftActionFailure.invalidFields
        }
        let start = offset
        while offset < bytes.count, ![9, 10, 13, 32, 44, 125].contains(bytes[offset]) { offset += 1 }
        let token = String(decoding: bytes[start..<offset], as: UTF8.self)
        guard ["null", "true", "false"].contains(token) ||
            token.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil && Int64(token) != nil else {
            throw ConfiguredCraftActionFailure.invalidFields
        }
    }
}
