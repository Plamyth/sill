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
enum CGEventType { case keyDown, keyUp, flagsChanged, leftMouseDown, leftMouseUp, rightMouseUp, otherMouseUp, mouseMoved }
final class CGEvent {
    struct Flags { let rawValue: UInt64 }
    enum Tap { case cghidEventTap }
    let type: CGEventType
    var flags = Flags(rawValue: 0)
    enum Field { case eventSourceUserData }
    var userData: Int64 = 0
    func setIntegerValueField(_ field: Field, value: Int64) { userData = value }
    var posted = 0
    init(_ type: CGEventType) { self.type = type }
    func post(tap: Tap) { posted += 1 }
}
typealias CGEventFlags = CGEvent.Flags
enum KeyStrokes { static let capsLock: UInt64 = 1 << 16 }
struct Stats { static let shared = Stats(); func bump(_ name: String) {} }
final class PostFixture {
    typealias PostAuthorization = (_ operation: () -> Void) -> Bool
    var postAuthorization: PostAuthorization?
    static let modifierBits: UInt64 = 0xff
    var lastKeyFlags: UInt64 = 0
    var isolatesPhysicalInput = false
    var remoteEventTag: Int64?
    var dryRun = false, testLog = false
    func logTest(_ event: CGEvent) {}
    // func withAuthorization(
    // private func post(_ event:
    // private static func isKeyboard(
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
        let injectionLease = AutomaticSessionAuthorization(principal: principal, fingerprint: key)
        let injector = PostFixture(), firstKey = CGEvent(.keyDown), lateKey = CGEvent(.keyDown), keyUp = CGEvent(.keyUp)
        injector.withAuthorization(injectionLease.whileCurrent) {
            check(injector.post(firstKey))
            injectionLease.invalidate()
            check(!injector.post(lateKey))
            check(injector.post(keyUp))
            for kind in [CGEventType.leftMouseDown, .mouseMoved] {
                let event = CGEvent(kind)
                check(!injector.post(event) && event.posted == 0)
            }
            for kind in [CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp] {
                check(injector.post(CGEvent(kind)))
            }
        }
        check(firstKey.posted == 1 && lateKey.posted == 0 && keyUp.posted == 1)
        check(injector.postAuthorization == nil && injector.post(CGEvent(.mouseMoved)))
        injector.isolatesPhysicalInput = true
        injector.remoteEventTag = 90210
        injector.lastKeyFlags = 7
        let pointer = CGEvent(.mouseMoved)
        check(injector.post(pointer) && pointer.flags.rawValue == 7 && pointer.userData == 90210)
        let denied = CGEvent(.leftMouseDown)
        injector.withAuthorization(injectionLease.whileCurrent) { check(!injector.post(denied)) }
        check(denied.posted == 0 && denied.userData == 0)
        print("PASS \(assertions) actual grant-lock, sendEnabled and injector post checks; no microphone, HAL or TLS device")
    }
}
