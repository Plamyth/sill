import Foundation
import os

package struct MicrophoneScope {}
final class NWConnection: @unchecked Sendable {
    enum Completion { case contentProcessed((Error?) -> Void) }
    private let lock = NSLock()
    private var count = 0
    var sent: Int { lock.lock(); defer { lock.unlock() }; return count }
    func send(content: Data, completion: Completion) { lock.lock(); count += 1; lock.unlock() }
}
// package struct HostMicrophoneDestination:
// package final class HostLocalOwnerGrant:

final class RenderFixture: @unchecked Sendable {
    // private struct Storage
    private let state = OSAllocatedUnfairLock(initialState: Storage())
    let grant: HostLocalOwnerGrant
    let monotonicNow: () -> UInt64
    init(_ grant: HostLocalOwnerGrant, now: @escaping () -> UInt64 = { 0 }) { self.grant = grant; monotonicNow = now }
    var admitted: Bool { state.withLock { $0.admitted } }
    // func sendEnabled(
}
final class ResultBox: @unchecked Sendable {
    let lock = NSLock()
    var value = true
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@main struct Check {
    static func main() {
        var assertions = 0
        func check(_ value: Bool) { precondition(value); assertions += 1 }
        let key = Data32(Data(repeating: 1, count: 32))!
        let principal = AutomaticDevicePrincipal.cable(deviceId: "inert")
        let destination = HostMicrophoneDestination(outputUID: "out", inputUID: "in", pluginBundleID: "inert",
            outputChannels: 1, inputChannels: 1, outputChannel: 0, inputChannel: 0)!
        func owner() -> HostLocalOwnerGrant {
            .init(owner: UUID(), callGeneration: UUID(), scope: .init(), fingerprint: key.data,
                  destination: destination, expiresAt: .max)
        }
        let lease = AutomaticSessionAuthorization(principal: principal, fingerprint: key)
        let render = RenderFixture(owner()), connection = NWConnection()
        check(render.sendEnabled(Data(), to: connection, authorize: lease.whileCurrent))
        check(render.admitted && connection.sent == 1)
        lease.invalidate()
        check(!render.sendEnabled(Data(), to: connection, authorize: lease.whileCurrent))
        check(connection.sent == 1)

        let blockedLease = AutomaticSessionAuthorization(principal: principal, fingerprint: key)
        let grant = owner(), blocked = NWConnection(), result = ResultBox()
        let ownerHeld = DispatchSemaphore(value: 0), releaseOwner = DispatchSemaphore(value: 0)
        let reachedOwnerLock = DispatchSemaphore(value: 0), ownerDone = DispatchSemaphore(value: 0), sendDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = grant.whileValid(at: 0) { ownerHeld.signal(); releaseOwner.wait() }
            ownerDone.signal()
        }
        check(ownerHeld.wait(timeout: .now() + 3) == .success)
        let waitingRender = RenderFixture(grant, now: { reachedOwnerLock.signal(); return 0 })
        DispatchQueue.global().async {
            result.set(waitingRender.sendEnabled(Data(), to: blocked, authorize: blockedLease.whileCurrent))
            sendDone.signal()
        }
        check(reachedOwnerLock.wait(timeout: .now() + 3) == .success)
        blockedLease.invalidate()
        releaseOwner.signal()
        check(ownerDone.wait(timeout: .now() + 3) == .success && sendDone.wait(timeout: .now() + 3) == .success)
        check(!result.read() && blocked.sent == 0 && !waitingRender.admitted)
        print("PASS \(assertions) actual grant-lock and sendEnabled checks; no microphone, HAL or TLS device")
    }
}
