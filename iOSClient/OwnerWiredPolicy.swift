import Foundation

/// Discovery is only a hint. This policy grants no identity or bootstrap authority.
enum OwnerWiredPolicy {
    struct Binding: Equatable {
        let macID: String
        let pin: Data
        let port: Int
    }

    static func registered(_ binding: Binding?, current: Binding?, hasIdentity: Bool) -> Bool {
        guard let binding, binding == current, hasIdentity else { return false }
        return !binding.macID.isEmpty && binding.pin.count == 32 && (1...65535).contains(binding.port)
    }

    static func addressAllowed(_ address: [UInt8], replyIndex: UInt32, scopeIndex: UInt32,
                               interfaceIndex: UInt32, interface: DiscoveryPolicy.Interface,
                               own: [(interface: String, address: [UInt8])]) -> Bool {
        guard interfaceIndex != 0, replyIndex == interfaceIndex,
              scopeIndex == 0 || scopeIndex == interfaceIndex else { return false }
        return DiscoveryPolicy.onCable(mac: address, scope: interface, own: own).cable
    }

    /// A stale DNS/TLS callback may neither replace the live peer nor start a fallback dial.
    static func callbackCurrent(token: UUID, currentToken: UUID?, binding: Binding, current: Binding?,
                                hasIdentity: Bool, samePeer: Bool, interfaceCurrent: Bool) -> Bool {
        token == currentToken && samePeer && interfaceCurrent
            && registered(binding, current: current, hasIdentity: hasIdentity)
    }

    struct Budget {
        private var attempts: [String: (count: Int, next: Double)] = [:]
        mutating func keep(_ keys: Set<String>) { attempts = attempts.filter { keys.contains($0.key) } }
        mutating func begin(_ key: String, now: Double) -> Bool {
            let previous = attempts[key] ?? (0, -Double.infinity)
            guard previous.count < 2, now >= previous.next else { return false }
            attempts[key] = (previous.count + 1, now + DiscoveryPolicy.upWait(failures: previous.count + 1))
            return true
        }
        func next(_ key: String, now: Double) -> Double? {
            guard let value = attempts[key], value.count < 2, value.next > now else { return nil }
            return value.next
        }
    }
}
