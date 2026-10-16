import Foundation
import Network
import StreamProtocol
var checks = 0
func check(_ ok: @autoclosure () -> Bool, _ label: String) {
    precondition(ok(), label); checks += 1; print("PASS \(label)")
}
func events(_ c: NWConnection) -> [InputEvent] {
    c.sent.filter { $0.first == 8 }.map { try! JSONDecoder().decode(InputEvent.self, from: $0.dropFirst()) }
}
func waitMain(_ done: () -> Bool) {
    let end = Date().addingTimeInterval(2)
    while !done() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002)) }
    check(done(), "bounded main completion")
}
let p = CGPoint(x: 0.3, y: 0.4), q = CGPoint(x: 0.6, y: 0.7)
var pointer = VisionPointer()
let modified = pointer.drag(from: p, to: q, mode: .pointer, modifiers: [.command, .shift])
check(modified.prefix(2) == KeyChord.modifiersDown([.command, .shift])[...], "modifier downs precede drag")
let released = pointer.cancel()
check(released.first == .pointer(.leftUp, x: q.x, y: q.y), "mouse up precedes modifier ups")
check(released.suffix(2) == KeyChord.modifiersUp([.command, .shift])[...], "modifier snapshot released in reverse order")
check(pointer.drag(from: p, to: q, mode: .pointer).isEmpty && pointer.tap(p, mode: .pointer).isEmpty, "cancelled stroke cannot restart or become trailing click")
check(pointer.cancel().isEmpty && pointer.end().isEmpty, "duplicate cancellation and end emit no input")
check(pointer.tap(p, mode: .right, modifiers: .control).count == 4, "fresh right click owns balanced modifier")
let scrolled = pointer.drag(from: p, to: q, mode: .scroll, modifiers: .option)
check(scrolled.count == 3 && pointer.cancel().count == 2, "modified scroll has balanced boundaries and modifier")
_ = pointer.end()
for shortcut in VisionShortcut.allCases {
    var host = KeyStrokes()
    let owner = NSObject()
    for event in KeyChord.press(shortcut.keys.0, with: shortcut.keys.1) {
        if case .key(let key, let down, let flags) = event { _ = host.key(usage: key, down: down, modifiers: flags, from: ObjectIdentifier(owner)) }
    }
    check(host.down.isEmpty && host.heldFlags == 0, "host releases \(shortcut.title)")
}
check(Set(VisionRemoteKey.allCases.map(\.rawValue)).count == 26, "unique supported navigation and function usages")
check(!ForwardedKeys.goesAsKey(0x04, modifiers: KeyModifiers.shift.rawValue), "Shift-only authored text remains on IME path")
let la = NWConnection(), lb = NWConnection(), lc = NWConnection()
let link = SessionLink(); link.connection = la
check(link.send(Data([8, 1]), onlyOn: la), "scoped input accepts original route")
link.handOver(from: la, to: lb, fencePing: Data([12]), nonce: Data([1]))
check(!link.send(Data([8, 2]), onlyOn: la), "late old input refused after handover")
_ = link.send(Data([8, 3]), onlyOn: lb)
link.send(Data([5, 9]))
check(link.inputsOnSession == 1, "waiting input counted for current connection")
_ = link.cancelInputs(onlyOn: lb) { [] }
check(link.inputsOnSession == 0 && lb.sent.isEmpty, "cancel drops unsent input without release overtaking old fence")
_ = link.fenceReturned(Data([1]), on: la)
check(lb.sent == [Data([5, 9])], "cancel preserves non-input waiting messages")
link.hold(lb)
_ = link.send(Data([8, 5]), onlyOn: lb)
_ = link.cancelInputs(onlyOn: la) { [] }
_ = link.adopt(lc)
check(lc.sent == [Data([8, 5])], "stale cleanup cannot erase replacement peer input")
let client = StreamClient(), input = VisionInputSession()
let a = NWConnection(), b = NWConnection(), c = NWConnection()
input.bind(client); input.allowed = true
client.connection = a
let blocked = DispatchSemaphore(value: 0)
client.queue.async { blocked.wait() }
client.sendInput(.text("stale"))
let before = events(b).count
client.connection = b
blocked.signal(); client.queue.sync {}
check(events(b).count == before, "actual queued native send never retargets new peer")
input.toggle(.command)
input.drag(from: p, to: q, mode: .pointer)
client.queue.sync {}
let bBefore = events(b).count
client.connection = c
check(events(b).dropFirst(bBefore).first == .pointer(.leftUp, x: q.x, y: q.y), "actual setter releases old peer atomically")
check(events(c).isEmpty && input.latched.isEmpty, "setter never sends old release to replacement")
input.drag(from: p, to: q, mode: .pointer); client.queue.sync {}
check(events(c).isEmpty, "held gesture remains cancelled across setter")
input.endGesture()
input.toggle(.shift)
input.tap(p, mode: .pointer); client.queue.sync {}
check(events(c).count == 4 && input.latched.isEmpty, "one-shot modifier click consumes latch")
input.toggle(.option)
input.drag(from: p, to: q, mode: .pointer); client.queue.sync {}
let d = NWConnection(); client.moving = .init(connection: d)
client.finish(d)
check(input.moving && !input.canSend, "handover immediately pauses native admission")
client.sendInput(.text("must not escape pause"))
waitMain { client.completions == 1 }
check(!input.moving && client.connection === d, "handover resumes only after old release drain")
let tail = c.sent.suffix(3)
check(tail.last?.first == 12 && events(c).suffix(2).first == .pointer(.leftUp, x: q.x, y: q.y), "actual viable move writes release before fence ping")
check(events(d).isEmpty, "handover carries neither held gesture nor paused text")
input.endGesture(); input.press(.left); input.press(.left); client.queue.sync {}
check(events(d).isEmpty, "new input waits behind previous route fence")
_ = client.link.fenceReturned(Data([1]), on: c)
check(events(d).count == 4, "two accepted palette keys survive old fence")
let overlay = InputOverlayView(); input.keyboard.view = overlay
_ = overlay.forwarded.began(0xE3, modifiers: KeyModifiers.command.rawValue)
let ups = input.takeReleases()
check(ups == [.key(hidUsage: 0xE3, down: false, modifiers: 0)], "reset drains hardware ownership")
check(input.takeReleases().isEmpty, "hardware reset is idempotent")
let owed = StreamClient(), owedInput = VisionInputSession(), owedPeer = NWConnection()
owedInput.bind(owed); owedInput.allowed = true; owed.connection = owedPeer
owedInput.drag(from: p, to: q, mode: .pointer); owed.queue.sync {}
owed.link.hold(owedPeer)
owedInput.endGesture(); owed.queue.sync {}
check(events(owedPeer).count == 2, "hold queues terminal up after transmitted down")
owedInput.releaseAll(); owed.queue.sync {}
check(events(owedPeer).last == .pointer(.leftUp, x: q.x, y: q.y), "emergency retains release debt after local gesture already ended")
_ = owed.link.unhold(owedPeer)
check(events(owedPeer).count == 3, "cancelled queued release cannot replay after unhold")
let fresh = NWConnection(); owed.moving = .init(connection: fresh); owed.finish(fresh)
waitMain { owed.completions == 1 }
let oldCount = events(owedPeer).count
owedInput.drag(from: p, to: q, mode: .pointer); owed.queue.sync {}
owedInput.releaseAll(); owed.queue.sync {}
check(events(fresh).isEmpty && events(owedPeer).count == oldCount, "unsent new drag cancellation cannot release old peer before fence")
_ = owed.link.fenceReturned(Data([1]), on: owedPeer)
check(events(fresh).isEmpty, "cancelled unsent drag never replays on new route")
input.allowed = false; input.press(.enter); client.queue.sync {}
check(events(d).count == 4, "inactive admission blocks new key")
print("Vision controls \(checks)/\(checks)")
