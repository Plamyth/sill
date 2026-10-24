import Foundation
import Security
import StreamProtocol

struct VisionSentryStoredRequest: Codable, Equatable {
    struct Binding: Codable, Equatable {
        let macID: String
        let hostFingerprint: Data
        let deviceFingerprint: Data

        var valid: Bool {
            !macID.isEmpty && hostFingerprint.count == 32 && deviceFingerprint.count == 32
        }
    }

    let binding: Binding
    let rawRequest: Data
    let ledgerAccepted: Bool
    let hasTerminalReceipt: Bool

    init(binding: Binding, rawRequest: Data, ledgerAccepted: Bool = false, hasTerminalReceipt: Bool = false) {
        self.binding = binding
        self.rawRequest = rawRequest
        self.ledgerAccepted = ledgerAccepted
        self.hasTerminalReceipt = hasTerminalReceipt
    }

    private enum CodingKeys: String, CodingKey { case binding, rawRequest, ledgerAccepted, hasTerminalReceipt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        binding = try values.decode(Binding.self, forKey: .binding)
        rawRequest = try values.decode(Data.self, forKey: .rawRequest)
        ledgerAccepted = try values.decodeIfPresent(Bool.self, forKey: .ledgerAccepted) ?? false
        hasTerminalReceipt = try values.decodeIfPresent(Bool.self, forKey: .hasTerminalReceipt) ?? false
        guard !hasTerminalReceipt || ledgerAccepted else { throw VisionSentryRequestStore.Failure.storage }
    }

    func request() throws -> SentryControlRequest {
        guard binding.valid, !hasTerminalReceipt || ledgerAccepted else { throw VisionSentryRequestStore.Failure.storage }
        return try SentryControlRequest(rawRequest: rawRequest)
    }
}

struct VisionSentryRequestStore {
    enum Failure: Error { case storage }
    let load: () throws -> [VisionSentryStoredRequest]
    let save: ([VisionSentryStoredRequest]) throws -> Void
    static let maximumRecords = 64
    static let unavailable = Self(load: { [] }, save: { _ in throw Failure.storage })

    static let keychain = Self(load: {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 131072 else { throw Failure.storage }
        let records = try JSONDecoder().decode([VisionSentryStoredRequest].self, from: data)
        guard records.count <= maximumRecords else { throw Failure.storage }
        for record in records { _ = try record.request() }
        return records
    }, save: { records in
        guard records.count <= maximumRecords else { throw Failure.storage }
        for record in records { _ = try record.request() }
        let data = try JSONEncoder().encode(records)
        guard data.count <= 131072 else { throw Failure.storage }
        let changes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(keychainQuery as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = keychainQuery
            item.merge(changes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.storage }
        } else if status != errSecSuccess { throw Failure.storage }
    })

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.ambrion.SillVision.sentry-control.v2",
         kSecAttrAccount as String: "public-request-journal",
         kSecAttrSynchronizable as String: false]
    }
}
