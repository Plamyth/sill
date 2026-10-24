#if os(iOS)
import Foundation
import Security

final class IPadEnrollmentStore {
    private static let lock = NSLock()
    private let account: String
    private let service = "com.ambrion.sillcanvas.ipad.owner-enrollment.v1"
    init(deviceID: String) { account = deviceID }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    func load() throws -> Data? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read()
    }
    /// 이 namespace의 유일 작성자는 main queue의 등록 소비자다. 잠금 안에서 원문 비교와 쓰기 후 읽기를 수행한다.
    func compareAndSwap(_ expected: Data?, _ next: Data) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try read() == expected else { throw IPadEnrollmentFailure.storage }
        let result: OSStatus
        if expected == nil {
            var add = query
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecValueData as String] = next
            add[kSecAttrGeneric as String] = IPadEnrollmentProtocol.hash(next)
            result = SecItemAdd(add as CFDictionary, nil)
        } else {
            var match = query
            match[kSecAttrGeneric as String] = IPadEnrollmentProtocol.hash(expected!)
            result = SecItemUpdate(match as CFDictionary,
                [kSecValueData as String: next, kSecAttrGeneric as String: IPadEnrollmentProtocol.hash(next)] as CFDictionary)
        }
        guard result == errSecSuccess, try read() == next else { throw IPadEnrollmentFailure.storage }
    }
    private func read() throws -> Data? {
        var read = query
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        read[kSecReturnData as String] = true
        read[kSecReturnAttributes as String] = true
        var found: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let fields = found as? [String: Any],
              let bytes = fields[kSecValueData as String] as? Data, !bytes.isEmpty,
              (fields[kSecAttrGeneric as String] as? Data) == IPadEnrollmentProtocol.hash(bytes),
              (fields[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
              (fields[kSecAttrSynchronizable as String] as? Bool) != true else { throw IPadEnrollmentFailure.storage }
        return bytes
    }
}
#endif
