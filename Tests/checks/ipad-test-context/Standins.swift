enum CanvasSendError: Error { case outboxUnavailable }

// Security calls are counted stand-ins. These checks never open the real Keychain.
let kSecClass = "class", kSecClassGenericPassword = "generic", kSecAttrService = "service"
let kSecAttrAccount = "account", kSecValueData = "data", kSecAttrAccessible = "accessible"
let kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "device", kSecReturnData = "return"
let kSecMatchLimit = "limit", kSecMatchLimitOne = "one"
let errSecSuccess: Int32 = 0
var keychainCalls = 0
var keychainData: Data?
@discardableResult func SecItemDelete(_ query: CFDictionary) -> Int32 { keychainCalls += 1; return -1 }
func SecItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> Int32 { keychainCalls += 1; return -1 }
func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> Int32 {
    keychainCalls += 1
    guard let data = keychainData else { return -1 }
    result?.pointee = data as NSData
    return errSecSuccess
}

final class UserDefaults {
    static let standard = UserDefaults()
    var reads = 0
    var checkpoint: Data?
    func data(forKey key: String) -> Data? { reads += 1; return checkpoint }
}

@propertyWrapper struct State<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    init(initialValue: Value) { self.wrappedValue = initialValue }
}
