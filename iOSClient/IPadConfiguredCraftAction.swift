import Foundation

/// Consumes a server catalog and returns a request; owns no transport, executor or call state.
struct IPadConfiguredCraftAction {
    static let operation = "invoke-configured-craft-action"
    static let inputID = "speed.button.stop-play"
    static let trigger = "longPress"
    static let responseTimeout: TimeInterval = 10
    static let maximumReasonBytes = 256

    enum Failure: Error { case invalidContext, invalidCatalog, invalidWire }

    private struct CatalogRequest: Encodable {
        let schemaVersion = 1
        let operation = "get-configured-craft-action"
    }

    static func encodeCatalogRequest() throws -> Data {
        try JSONEncoder().encode(CatalogRequest())
    }

    private struct CatalogResponse: Decodable {
        let schemaVersion: Int
        let supported: Bool
        let expectedProfileId: UUID
        let inputID: String
        let trigger: String
        let expectedAssignmentSha256: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion, supported, expectedProfileId, inputID, trigger, expectedAssignmentSha256
        }

        init(from decoder: Decoder) throws {
            try exactKeys(decoder, required: Set(CodingKeys.allCases.map(\.rawValue)))
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
            supported = try fields.decode(Bool.self, forKey: .supported)
            expectedProfileId = try fields.decode(UUID.self, forKey: .expectedProfileId)
            inputID = try fields.decode(String.self, forKey: .inputID)
            trigger = try fields.decode(String.self, forKey: .trigger)
            expectedAssignmentSha256 = try fields.decode(String.self, forKey: .expectedAssignmentSha256)
            guard supported else { throw Failure.invalidCatalog }
        }
    }

    // Same ASCII validation as IPadEnrollmentProtocol.hex64, without importing its crypto/wire dependencies.
    private static func hex64(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    struct Context: Equatable {
        let connection: UUID
        let hostID: String
        let deviceID: String

        init(connection: UUID, hostID: String, deviceID: String) throws {
            guard hex64(hostID), hex64(deviceID) else { throw Failure.invalidContext }
            self.connection = connection; self.hostID = hostID; self.deviceID = deviceID
        }
    }

    /// Only the authenticated current connection's server-provided catalog may populate this value.
    struct Catalog: Equatable {
        let context: Context
        let profileID: UUID
        let assignmentSha256: String

        init(context: Context, schemaVersion: Int = 1, inputID: String = IPadConfiguredCraftAction.inputID,
             trigger: String = IPadConfiguredCraftAction.trigger, profileID: UUID, assignmentSha256: String) throws {
            guard schemaVersion == 1, inputID == IPadConfiguredCraftAction.inputID,
                  trigger == IPadConfiguredCraftAction.trigger, hex64(assignmentSha256) else {
                throw Failure.invalidCatalog
            }
            self.context = context; self.profileID = profileID; self.assignmentSha256 = assignmentSha256
        }

        init(context: Context, data: Data) throws {
            let response = try JSONDecoder().decode(CatalogResponse.self, from: data)
            try self.init(context: context, schemaVersion: response.schemaVersion, inputID: response.inputID,
                          trigger: response.trigger, profileID: response.expectedProfileId,
                          assignmentSha256: response.expectedAssignmentSha256)
        }
    }

    struct Request: Codable, Equatable {
        let schemaVersion: Int
        let operation: String
        let operationId: UUID
        let deviceId: String
        let inputID: String
        let trigger: String
        let expectedProfileId: UUID
        let expectedAssignmentSha256: String
        let issuedAt: Int64

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion, operation, operationId, deviceId, inputID, trigger
            case expectedProfileId, expectedAssignmentSha256, issuedAt
        }

        fileprivate init(operationId: UUID, catalog: Catalog, issuedAt: Int64) {
            schemaVersion = 1; operation = IPadConfiguredCraftAction.operation
            self.operationId = operationId; deviceId = catalog.context.deviceID
            inputID = IPadConfiguredCraftAction.inputID; trigger = IPadConfiguredCraftAction.trigger
            expectedProfileId = catalog.profileID; expectedAssignmentSha256 = catalog.assignmentSha256
            self.issuedAt = issuedAt
        }

        init(from decoder: Decoder) throws {
            try exactKeys(decoder, required: Set(CodingKeys.allCases.map(\.rawValue)))
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
            operation = try fields.decode(String.self, forKey: .operation)
            operationId = try fields.decode(UUID.self, forKey: .operationId)
            deviceId = try fields.decode(String.self, forKey: .deviceId)
            inputID = try fields.decode(String.self, forKey: .inputID)
            trigger = try fields.decode(String.self, forKey: .trigger)
            expectedProfileId = try fields.decode(UUID.self, forKey: .expectedProfileId)
            expectedAssignmentSha256 = try fields.decode(String.self, forKey: .expectedAssignmentSha256)
            issuedAt = try fields.decode(Int64.self, forKey: .issuedAt)
            guard schemaVersion == 1, operation == IPadConfiguredCraftAction.operation,
                  inputID == IPadConfiguredCraftAction.inputID, trigger == IPadConfiguredCraftAction.trigger,
                  hex64(deviceId), hex64(expectedAssignmentSha256), validEpoch(issuedAt) else {
                throw Failure.invalidWire
            }
        }
    }

    enum Outcome: String, Codable { case invoked, rejected, unknown }

    struct Response: Decodable, Equatable {
        let outcome: Outcome
        let operationId: UUID
        let deviceId: String
        let bindingSha256: String?
        let invoked: Bool
        let effectConfirmed: Bool
        let reason: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case outcome, operationId, deviceId, bindingSha256, invoked, effectConfirmed, reason
        }

        init(from decoder: Decoder) throws {
            try exactKeys(decoder, required: Set(CodingKeys.allCases.map(\.rawValue)).subtracting(["reason"]),
                          optional: ["reason"])
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            outcome = try fields.decode(Outcome.self, forKey: .outcome)
            operationId = try fields.decode(UUID.self, forKey: .operationId)
            deviceId = try fields.decode(String.self, forKey: .deviceId)
            bindingSha256 = try fields.decodeIfPresent(String.self, forKey: .bindingSha256)
            invoked = try fields.decode(Bool.self, forKey: .invoked)
            effectConfirmed = try fields.decode(Bool.self, forKey: .effectConfirmed)
            reason = fields.contains(.reason) ? try fields.decode(String.self, forKey: .reason) : nil
            guard hex64(deviceId), !effectConfirmed else { throw Failure.invalidWire }
            if let bindingSha256, !hex64(bindingSha256) { throw Failure.invalidWire }
            if let reason {
                guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      reason.utf8.count <= maximumReasonBytes else { throw Failure.invalidWire }
            }
            switch outcome {
            case .invoked:
                guard invoked, bindingSha256 != nil else { throw Failure.invalidWire }
            case .rejected:
                guard !invoked else { throw Failure.invalidWire }
            case .unknown:
                break // Either executor-submission fact is legal; neither confirms its effect.
            }
        }
    }

    struct Pending: Equatable {
        let request: Request
        let catalog: Catalog
        let userActionID: UUID
        let sentAt: TimeInterval
        let expiresAt: TimeInterval
    }

    enum UnknownReason: String { case timeout, invalidClock, contextChanged, capabilityWithdrawn, catalogChanged }

    struct Resolution: Equatable {
        let pending: Pending
        let response: Response?
        let localUnknownReason: UnknownReason?
        var outcome: Outcome { response?.outcome ?? .unknown }
        // A local timeout does not know whether the executor was called.
        var invoked: Bool? { response?.invoked }
        var effectConfirmed: Bool { false }
    }

    enum State: Equatable { case idle, pending(Pending), resolved(Resolution) }

    private struct Admission {
        let catalog: Catalog
        let inputReady: Bool
        let outputReady: Bool
    }

    private(set) var context: Context?
    private(set) var state: State = .idle
    private var admission: Admission?
    private var consumedUserActions: Set<UUID> = []
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    var supported: Bool { admission != nil }
    var pending: Pending? { if case .pending(let value) = state { value } else { nil } }
    var resolution: Resolution? { if case .resolved(let value) = state { value } else { nil } }
    var canBegin: Bool {
        guard let admission, admission.inputReady, admission.outputReady else { return false }
        switch state {
        case .idle: return true
        case .pending: return false
        case .resolved(let value): return value.outcome != .unknown
        }
    }

    mutating func bind(_ next: Context) {
        resolveUnknown(.contextChanged)
        context = next; admission = nil
    }

    mutating func disconnected() {
        resolveUnknown(.contextChanged)
        context = nil; admission = nil
    }

    @discardableResult
    mutating func observeCatalog(_ data: Data, from incoming: Context, authenticated: Bool,
                                 endpointSupported: Bool = false, inputReady: Bool, outputReady: Bool) -> Bool {
        guard context == incoming else { return false }
        return observe(from: incoming, authenticated: authenticated, endpointSupported: endpointSupported,
                       catalog: try? Catalog(context: incoming, data: data),
                       inputReady: inputReady, outputReady: outputReady)
    }

    @discardableResult
    mutating func observe(from incoming: Context, authenticated: Bool, endpointSupported: Bool = false,
                          catalog: Catalog?, inputReady: Bool, outputReady: Bool) -> Bool {
        guard context == incoming else { return false }
        guard authenticated, endpointSupported, let catalog, catalog.context == incoming else {
            resolveUnknown(.capabilityWithdrawn)
            admission = nil
            return false
        }
        if let pending, pending.catalog != catalog { resolveUnknown(.catalogChanged) }
        admission = Admission(catalog: catalog, inputReady: inputReady, outputReady: outputReady)
        return true
    }

    /// The adapter must mint userActionID only for a separate explicit physical long press.
    mutating func begin(from incoming: Context, catalog: Catalog, userActionID: UUID,
                        heldMilliseconds: Int, issuedAt: Int64) -> Request? {
        guard canBegin, context == incoming, admission?.catalog == catalog, catalog.context == incoming,
              heldMilliseconds >= 500, !consumedUserActions.contains(userActionID), Self.validEpoch(issuedAt) else {
            return nil
        }
        let now = clock()
        guard now.isFinite, now >= 0, (now + Self.responseTimeout).isFinite,
              now + Self.responseTimeout > now else { return nil }
        let request = Request(operationId: UUID(), catalog: catalog, issuedAt: issuedAt)
        consumedUserActions.insert(userActionID)
        state = .pending(Pending(request: request, catalog: catalog, userActionID: userActionID,
                                 sentAt: now, expiresAt: now + Self.responseTimeout))
        return request
    }

    @discardableResult
    mutating func receive(_ data: Data, from incoming: Context) throws -> Bool {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let pending, context == incoming, pending.catalog.context == incoming,
              admission?.catalog == pending.catalog,
              response.operationId == pending.request.operationId, response.deviceId == incoming.deviceID else {
            return false
        }
        if response.outcome != .rejected, let hash = response.bindingSha256,
           hash != pending.request.expectedAssignmentSha256 { return false }
        guard !timeout(operationId: pending.request.operationId) else { return false }
        state = .resolved(Resolution(pending: pending, response: response, localUnknownReason: nil))
        return true
    }

    @discardableResult
    mutating func timeout(operationId: UUID) -> Bool {
        guard let pending, pending.request.operationId == operationId else { return false }
        let now = clock()
        if !now.isFinite || now < pending.sentAt { resolveUnknown(.invalidClock); return true }
        guard now >= pending.expiresAt else { return false }
        resolveUnknown(.timeout)
        return true
    }

    private mutating func resolveUnknown(_ reason: UnknownReason) {
        guard let pending else { return }
        state = .resolved(Resolution(pending: pending, response: nil, localUnknownReason: reason))
    }

    private static func validEpoch(_ value: Int64) -> Bool { (0...9_007_199_254_740_991).contains(value) }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func exactKeys(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
        let fields = Set(try decoder.container(keyedBy: Field.self).allKeys.map(\.stringValue))
        guard required.isSubset(of: fields), fields.isSubset(of: required.union(optional)) else {
            throw Failure.invalidWire
        }
    }
}
