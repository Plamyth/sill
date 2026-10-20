import Foundation

final class AutomaticSessionAuthorization: @unchecked Sendable, Equatable {
    let principal: AutomaticDevicePrincipal
    let fingerprint: Data32
    private let lock = NSLock()
    private let clock: @Sendable () -> (UInt64, Date)
    private var valid = true
    private var deadline: UInt64 = 0
    private var expiry = Date.distantPast

    init(principal: AutomaticDevicePrincipal, fingerprint: Data32, nodeExpiry: Date = .distantFuture,
         clock: @escaping @Sendable () -> (UInt64, Date) = { (DispatchTime.now().uptimeNanoseconds, Date()) }) {
        self.principal = principal; self.fingerprint = fingerprint; self.clock = clock
        setExpiry(nodeExpiry, now: clock())
    }

    static func == (lhs: AutomaticSessionAuthorization, rhs: AutomaticSessionAuthorization) -> Bool { lhs === rhs }

    var isCurrent: Bool {
        lock.lock(); defer { lock.unlock() }
        return current(clock())
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        valid = false
    }

    func whileCurrent(_ operation: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current(clock()) else { return false }
        operation()
        return true
    }

    func renew(principal: AutomaticDevicePrincipal, fingerprint: Data32, nodeExpiry: Date = .distantFuture) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        guard current(now), principal == self.principal, fingerprint == self.fingerprint else {
            valid = false
            return false
        }
        setExpiry(nodeExpiry, now: now)
        return valid
    }

    private func current(_ now: (UInt64, Date)) -> Bool {
        if now.0 >= deadline || now.1 >= expiry { valid = false }
        return valid
    }

    private func setExpiry(_ nodeExpiry: Date, now: (UInt64, Date)) {
        let seconds = min(10, nodeExpiry.timeIntervalSince(now.1))
        guard seconds > 0 else { valid = false; return }
        let duration = UInt64(seconds * 1_000_000_000)
        guard duration > 0, now.0 <= UInt64.max - duration else { valid = false; return }
        deadline = now.0 + duration
        expiry = now.1.addingTimeInterval(seconds)
    }
}
