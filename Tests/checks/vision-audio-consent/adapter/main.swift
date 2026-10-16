import Foundation

enum VisionAudioPlaybackEvent { case rendering, waiting, failed(String) }
final class VisionAudioPlayer {
    var begins: [UUID] = []
    var packets: [UUID] = []
    var stops = 0
    var callbacks: [(UUID, VisionAudioPlaybackEvent) -> Void] = []
    func begin(grant: UUID, onEvent: @escaping (UUID, VisionAudioPlaybackEvent) -> Void) {
        begins.append(grant)
        callbacks.append(onEvent)
    }
    func receive(_ packet: Data, grant: UUID) { packets.append(grant) }
    func stop() { stops += 1 }
}
final class NWConnection {}
enum StreamSource: Equatable { case none, desktop, window(UInt32) }

var checks = 0
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
let a = VisionAudioScope(connection: UUID(), source: 1)
let b = VisionAudioScope(connection: a.connection, source: 2)
let player = VisionAudioPlayer()
var sent: [VisionAudioControl] = []
let controller = VisionAudioController(send: { sent.append($0) }, player: player)
controller.receive(Data([1]), scope: a)
controller.enable()
check(sent.isEmpty && player.begins.isEmpty && player.packets.isEmpty, "default controller admits no side effects")
controller.setForeground(true)
controller.update(.unsupported)
controller.enable()
check(sent.isEmpty, "unsupported controller sends no request")
controller.update(.available(a))
controller.enable()
let first = sent.last!.grant
check(sent.count == 1 && sent[0].enabled && player.begins.isEmpty, "explicit Enable requests without engine start")
controller.receive(Data([2]), scope: a)
check(player.packets.isEmpty, "pre-ACK controller drops packet")
controller.acknowledge(id: UUID(), enabled: true, scope: a, reason: nil)
check(player.begins.isEmpty, "unmatched ACK cannot start player")
controller.acknowledge(id: first.id, enabled: true, scope: a, reason: nil)
check(player.begins == [first.id], "matching ACK begins one granted player")
controller.receive(Data([3]), scope: b)
check(player.packets.isEmpty, "other source cannot reach player")
controller.receive(Data([4]), scope: a)
check(player.packets == [first.id], "granted packet reaches player")
player.callbacks[0](first.id, .rendering)
drain()
check(controller.presentation.phase == .rendering(first), "render callback alone reports rendering")
controller.stop()
check(player.stops == 1 && sent.count == 2 && !sent.last!.enabled, "Stop synchronously revokes player and sends scoped off")
controller.receive(Data([5]), scope: a)
player.callbacks[0](first.id, .rendering)
drain()
check(player.packets.count == 1 && controller.presentation.phase == .off, "late packet and render cannot resurrect Stop")
controller.enable()
let second = sent.last!.grant
controller.acknowledge(id: first.id, enabled: true, scope: a, reason: nil)
check(player.begins.count == 1, "old ACK does not satisfy next controller request")
controller.acknowledge(id: second.id, enabled: true, scope: a, reason: nil)
controller.update(.available(b))
var forbiddenSends = 0
let permitted = controller.sendIfPermitted(VisionAudioControl(grant: second, enabled: true)) { forbiddenSends += 1 }
check(player.stops == 2 && !permitted && forbiddenSends == 0, "source update revokes captured send permission")
controller.update(.available(a))
controller.receive(Data([6]), scope: a)
check(player.packets.count == 1, "source A return never restores previous consent")
controller.enable()
let third = sent.last!.grant
controller.acknowledge(id: third.id, enabled: true, scope: a, reason: nil)
controller.setForeground(false)
controller.setForeground(true)
controller.receive(Data([7]), scope: a)
check(player.stops == 3 && player.packets.count == 1, "foreground does not automatically restart playback")
controller.enable()
let fourth = sent.last!.grant
controller.acknowledge(id: fourth.id, enabled: true, scope: a, reason: nil)
player.callbacks.last!(fourth.id, .failed("decoder refused"))
drain()
check(player.stops == 4 && controller.presentation.phase == .failed("decoder refused"), "failure stops player with visible reason")

controller.enable()
let racing = sent.last!
let entered = DispatchSemaphore(value: 0)
let finishSend = DispatchSemaphore(value: 0)
let sendDone = DispatchSemaphore(value: 0)
let stopStarted = DispatchSemaphore(value: 0)
let stopDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    controller.sendIfPermitted(racing) {
        entered.signal()
        _ = finishSend.wait(timeout: .now() + 2)
    }
    sendDone.signal()
}
check(entered.wait(timeout: .now() + 2) == .success, "send fence admits current request")
DispatchQueue.global().async {
    stopStarted.signal()
    controller.stop()
    stopDone.signal()
}
check(stopStarted.wait(timeout: .now() + 2) == .success, "concurrent Stop reaches consent fence")
check(stopDone.wait(timeout: .now() + 0.02) == .timedOut, "Stop cannot overtake an admitted send body")
finishSend.signal()
check(sendDone.wait(timeout: .now() + 2) == .success && stopDone.wait(timeout: .now() + 2) == .success,
      "send and Stop complete without deadlock")
var afterStopSends = 0
_ = controller.sendIfPermitted(racing) { afterStopSends += 1 }
check(afterStopSends == 0, "revoked queued Enable never executes after Stop")

let route = VisionAudioRoute()
let peerA = NWConnection(), peerB = NWConnection()
check(route.scope(for: peerA) == nil, "unlisted peer has no audio scope")
check(route.observe(peerA, source: .desktop, supported: false) == .unsupported, "missing capability is unsupported")
_ = route.observe(peerA, source: .desktop, supported: true)
let scopeA = route.scope(for: peerA)!
let control = VisionAudioControl(grant: VisionAudioGrant(id: UUID(), scope: scopeA), enabled: true)
check(route.peer(for: control) === peerA, "scoped request captures its peer")
_ = route.observe(peerA, source: .window(10), supported: true)
check(route.peer(for: control) == nil, "old source cannot capture Enable")
let oldOff = VisionAudioControl(grant: control.grant, enabled: false)
check(route.peer(for: oldOff) === peerA, "old source cleanup can disable the exact same peer")
_ = route.observe(peerA, source: .desktop, supported: true)
check(route.scope(for: peerA) != scopeA, "route A to B to A increments source generation")
_ = route.observe(peerB, source: .desktop, supported: true)
check(route.peer(for: oldOff) == nil && route.scope(for: peerA) == nil, "replacement peer never inherits old commands")
route.clear()
check(route.scope(for: peerB) == nil, "connection reset clears capability and scope")
print("Vision audio adapter: \(checks - failures)/\(checks) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
