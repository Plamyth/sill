import Foundation
import Network
import StreamProtocol
var checks = 0
func check(_ ok: @autoclosure () -> Bool, _ label: String) {
    precondition(ok(), label); checks += 1; print("PASS \(label)")
}
func inputs(_ c: NWConnection) -> [CapturedVisionInput] {
    c.sent.filter { $0.first == StreamMessageKind.input.rawValue }.map { bytes in
        let header = StreamMessage.parseHeader(bytes)!
        precondition(bytes.count == StreamMessage.headerLength + header.payloadLength)
        let payload = Data(bytes.dropFirst(StreamMessage.headerLength))
        if let scoped = Wire.decode(SourceInput.self, from: payload) {
            return CapturedVisionInput(event: scoped.event, generation: scoped.generation)
        }
        return CapturedVisionInput(event: try! JSONDecoder().decode(InputEvent.self, from: payload), generation: nil)
    }
}
func events(_ c: NWConnection) -> [InputEvent] { inputs(c).map(\.event) }
func seedLegacy(_ client: StreamClient, _ peer: NWConnection) {
    precondition(client.catalog(WindowList(macName: "Legacy fixture", windows: [], active: .desktop), from: peer))
    client.queue.sync {}
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
seedLegacy(client, a)
let blocked = DispatchSemaphore(value: 0)
client.queue.async { blocked.wait() }
client.sendInput(.text("stale"))
let before = events(b).count
client.connection = b
blocked.signal(); client.queue.sync {}
check(events(b).count == before, "actual queued native send never retargets new peer")
seedLegacy(client, b)
input.toggle(.command)
input.drag(from: p, to: q, mode: .pointer)
client.queue.sync {}
let bBefore = events(b).count
client.connection = c
check(events(b).dropFirst(bBefore).first == .pointer(.leftUp, x: q.x, y: q.y), "actual setter releases old peer atomically")
check(events(c).isEmpty && input.latched.isEmpty, "setter never sends old release to replacement")
seedLegacy(client, c)
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
check(!input.moving && client.connection === d, "handover adopts new peer only after old release drain")
check(!input.canSend, "awaiting fresh catalog keeps native controls disabled")
let movedNotes = client.notes.count
client.sendInput(.text("must wait for catalog")); client.queue.sync {}
check(client.notes.count == movedNotes && client.link.inputsOnSession == 0 && events(d).isEmpty, "awaiting fresh catalog blocks native transport before enqueue")
let tail = c.sent.suffix(3)
check(tail.last?.first == 12 && events(c).suffix(2).first == .pointer(.leftUp, x: q.x, y: q.y), "actual viable move writes release before fence ping")
check(events(d).isEmpty, "handover carries neither held gesture nor paused text")
seedLegacy(client, d)
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
seedLegacy(owed, owedPeer)
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
seedLegacy(owed, fresh)
let oldCount = events(owedPeer).count
owedInput.drag(from: p, to: q, mode: .pointer); owed.queue.sync {}
owedInput.releaseAll(); owed.queue.sync {}
check(events(fresh).isEmpty && events(owedPeer).count == oldCount, "unsent new drag cancellation cannot release old peer before fence")
_ = owed.link.fenceReturned(Data([1]), on: owedPeer)
check(events(fresh).isEmpty, "cancelled unsent drag never replays on new route")
input.allowed = false; input.press(.enter); client.queue.sync {}
check(events(d).count == 4, "inactive admission blocks new key")

let sourceA = StreamSource.desktop, sourceB = StreamSource.window(42)
func catalog(_ source: StreamSource, _ generation: String?, windows: [WindowInfo] = []) -> WindowList {
    WindowList(macName: "Fixture Mac", windows: windows, active: source, remoteAudio: 1, inputGeneration: generation)
}
var hostFence = SourceInputFence<String>()
check(hostFence.join("vision", source: sourceA, switching: false), "Vision joins settled source A")
check(!hostFence.allowsSelection(sourceB), "legacy connection initially pins source A")
let hello = Wire.decode(Hello.self, from: StreamClient.hello)!
check(hello.sourceInput == 1, "actual native Hello advertises scoped input")
hostFence.negotiate("vision", supportsScoped: hello.sourceInput == 1)
check(hostFence.allowsSelection(sourceB), "scoped Vision releases legacy source pin")
let iPadHello = Wire.decode(Hello.self, from: StreamClient.legacyHello)!
check(iPadHello.sourceInput == nil, "actual non-Vision Hello remains unadvertised")
var legacyFence = SourceInputFence<String>()
_ = legacyFence.join("ipad", source: sourceA, switching: false)
legacyFence.negotiate("ipad", supportsScoped: iPadHello.sourceInput == 1)
check(!legacyFence.allowsSelection(sourceB), "unintegrated iPad retains real host legacy pin")
let composed = Wire.decode(WindowList.self, from: Wire.encode(catalog(sourceA, "A1")))!
check(composed.remoteAudio == 1 && composed.inputGeneration == "A1", "catalog composes remote audio and generation")
let oldCatalog = Wire.decode(WindowList.self, from: Data(#"{"macName":"Old Mac","windows":[],"active":{"desktop":{}}}"#.utf8))!
check(oldCatalog.inputGeneration == nil && oldCatalog.remoteAudio == nil, "old catalog decodes without new optional fields")

let scoped = StreamClient(), scopedInput = VisionInputSession(), scopedPeer = NWConnection()
scopedInput.bind(scoped); scopedInput.allowed = true; scoped.connection = scopedPeer
check(scoped.catalog(catalog(sourceA, "A1"), from: scopedPeer), "current peer catalog establishes source binding")
scoped.queue.sync {}
scopedInput.toggle(.command)
scopedInput.drag(from: p, to: q, mode: .pointer); scoped.queue.sync {}
let heldCount = inputs(scopedPeer).count
_ = scoped.catalog(catalog(sourceA, "A1"), from: scopedPeer); scoped.queue.sync {}
check(inputs(scopedPeer).count == heldCount, "unchanged catalog preserves held stroke")
check(scoped.catalog(catalog(sourceB, "B1"), from: scopedPeer), "new current peer source catalog applies")
scoped.queue.sync {}
let sourceReleases = Array(inputs(scopedPeer).dropFirst(heldCount))
check(sourceReleases.count == 2 && sourceReleases.allSatisfy { $0.generation == "A1" }, "source change releases held input with original generation")
check(sourceReleases.map(\.event) == [.pointer(.leftUp, x: q.x, y: q.y), .key(hidUsage: 0xE3, down: false, modifiers: 0)], "source release balances pointer before modifier")
check(scoped.active == sourceB && scopedInput.latched.isEmpty, "catalog publishes new source after local ownership drain")
scopedInput.drag(from: p, to: q, mode: .pointer); scoped.queue.sync {}
check(inputs(scopedPeer).count == heldCount + 2, "held gesture cannot restart after source switch")
scopedInput.endGesture(); scopedInput.press(.enter); scopedInput.press(.left); scoped.queue.sync {}
check(inputs(scopedPeer).suffix(4).allSatisfy { $0.generation == "B1" }, "ordinary successive chords retain new source scope")

let early = StreamClient(), earlyInput = VisionInputSession(), earlyPeer = NWConnection()
earlyInput.bind(early); earlyInput.allowed = true
early.connection = earlyPeer
_ = early.catalog(catalog(sourceA, "A1"), from: earlyPeer); early.queue.sync {}
let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
early.queue.async { entered.signal(); resume.wait() }
entered.wait()
early.sendInput(.text("captured A"))
_ = early.catalog(catalog(sourceB, "B1"), from: earlyPeer)
early.sendInput(.text("captured B"))
resume.signal(); early.queue.sync {}
let queued = inputs(earlyPeer)
check(queued.count == 2 && queued[0].generation == "A1" && queued[1].generation == "B1", "queued input retains generation captured on main")
check(!hostFence.accepts("vision", generation: queued[0].generation, current: "B1", source: sourceB), "real host guard rejects delayed source A input on B")
check(hostFence.accepts("vision", generation: queued[1].generation, current: "B1", source: sourceB), "real host guard accepts current source B input")
_ = early.catalog(catalog(sourceA, "A2"), from: earlyPeer)
early.sendInput(.text("returned A")); early.queue.sync {}
check(!hostFence.accepts("vision", generation: queued[0].generation, current: "A2", source: sourceA), "A to B to A rejects first A generation")
check(inputs(earlyPeer).last?.generation == "A2" && hostFence.accepts("vision", generation: inputs(earlyPeer).last?.generation, current: "A2", source: sourceA), "return to A uses distinct current generation")
check(!hostFence.accepts("vision", generation: nil, current: "A2", source: sourceA), "scoped host refuses raw input after native Hello")

let stranger = NWConnection()
let window = WindowInfo(id: 42, title: "B", appName: "App", bundleID: "fixture", width: 800, height: 600)
check(!early.catalog(catalog(sourceB, "wrong", windows: [window]), from: stranger), "stale peer catalog refused")
check(!early.catalog(catalog(sourceB, "wrong"), from: nil), "missing peer catalog refused")
early.sendInput(.text("still A2")); early.queue.sync {}
check(early.active == sourceA && early.windows.isEmpty && inputs(earlyPeer).last?.generation == "A2", "stale catalog cannot mutate active list or generation")
let replacement = NWConnection(); early.connection = replacement
early.sendInput(.text("before new catalog")); early.queue.sync {}
check(inputs(replacement).isEmpty && !earlyInput.canSend && early.visionInputBinding == .awaitingCatalog, "actual connection setter awaits catalog without raw fallback")
check(!early.catalog(oldCatalog, from: stranger) && early.visionInputBinding == .awaitingCatalog, "wrong peer legacy catalog cannot enable fallback")
_ = early.catalog(oldCatalog, from: replacement)
early.sendInput(.text("old host")); early.queue.sync {}
let raw = Data(replacement.sent.last!.dropFirst(StreamMessage.headerLength))
check(earlyInput.canSend && early.visionInputBinding == .confirmedLegacy && events(replacement) == [.text("old host")] && Wire.decode(InputEvent.self, from: raw) == .text("old host") && Wire.decode(SourceInput.self, from: raw) == nil, "confirmed legacy catalog enables unchanged raw event fallback")

_ = scoped.catalog(catalog(sourceB, "B1"), from: scopedPeer)
scopedInput.drag(from: p, to: q, mode: .pointer); scoped.queue.sync {}
scoped.link.hold(scopedPeer)
scopedInput.endGesture(); scoped.queue.sync {}
let pendingUp = inputs(scopedPeer).count
_ = scoped.catalog(catalog(sourceA, "A2"), from: scopedPeer); scoped.queue.sync {}
check(inputs(scopedPeer).count == pendingUp + 1 && inputs(scopedPeer).last?.generation == "B1" && events(scopedPeer).last == .pointer(.leftUp, x: q.x, y: q.y), "catalog releases transmitted down whose terminal was queued")
_ = scoped.link.unhold(scopedPeer)
check(inputs(scopedPeer).count == pendingUp + 1, "old queued source release cannot replay")
scopedInput.endGesture()
scopedInput.drag(from: p, to: q, mode: .pointer); scoped.queue.sync {}
let beforeReset = inputs(scopedPeer).count
scoped.teardownInput(); scoped.queue.sync {}
check(inputs(scopedPeer).count == beforeReset + 1 && inputs(scopedPeer).last?.generation == "A2", "actual teardown input prefix drains original generation")
scoped.sendInput(.text("reset")); scoped.queue.sync {}
check(inputs(scopedPeer).count == beforeReset + 1 && !scopedInput.canSend && scoped.visionInputBinding == .awaitingCatalog, "actual teardown input prefix blocks input until another catalog")
_ = early.catalog(catalog(sourceA, "move-A"), from: replacement); early.queue.sync {}
let retainedPayload = Wire.encode(catalog(sourceA, "kept-A"))
let retainedBytes = StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false, payload: retainedPayload).serialized()
let afterMove = NWConnection(); early.moving = .init(connection: afterMove)
early.finish(afterMove, kept: [(header: StreamMessage.parseHeader(retainedBytes)!, payload: retainedPayload)])
waitMain { early.completions == 1 }
_ = early.link.fenceReturned(Data([1]), on: replacement)
check(!earlyInput.moving && early.connected && early.active == sourceA && early.visionInputBinding == .awaitingCatalog && !earlyInput.canSend && early.retained.count == 1, "delayed retained catalog keeps old active UI input disabled")
earlyInput.toggle(.command); earlyInput.press(.enter); earlyInput.tap(p, mode: .pointer)
earlyInput.overlayInput(.text("premature overlay"))
early.sendInput(.text("premature direct")); early.queue.sync {}
check(events(afterMove).isEmpty && early.link.inputsOnSession == 0 && earlyInput.latched.isEmpty, "UI and core admit no input while retained catalog waits")
check(!hostFence.accepts("vision", generation: nil, current: "kept-A", source: sourceA), "real scoped host would reject premature unscoped input")
check(!early.catalog(catalog(sourceA, "old-peer"), from: replacement) && !earlyInput.canSend, "prior peer catalog cannot resolve moved peer binding")
early.deliverRetainedCatalogs()
check(earlyInput.canSend && early.visionInputBinding == .scoped(generation: "kept-A"), "current peer retained catalog enables scoped input after normal application")
early.sendInput(.text("scoped after catalog")); earlyInput.press(.enter); early.queue.sync {}
check(events(afterMove) == [.text("scoped after catalog")] + KeyChord.press(VisionRemoteKey.enter.rawValue, with: []) && inputs(afterMove).allSatisfy { $0.generation == "kept-A" && hostFence.accepts("vision", generation: $0.generation, current: "kept-A", source: sourceA) }, "current catalog input transmits and passes real scoped host guard")
let supersedingPeer = NWConnection()
early.moving = .init(connection: supersedingPeer)
early.finish(supersedingPeer, kept: [(header: StreamMessage.parseHeader(retainedBytes)!, payload: retainedPayload)])
waitMain { early.completions == 2 }
let finalPeer = NWConnection(); early.connection = finalPeer
early.deliverRetainedCatalogs()
check(early.visionInputBinding == .awaitingCatalog && !earlyInput.canSend, "retained catalog is refused if its peer was replaced before delivery")

let waitingSource = StreamClient(), waitingInput = VisionInputSession(), waitingPeer = NWConnection()
waitingInput.bind(waitingSource); waitingInput.allowed = true; waitingSource.connection = waitingPeer
_ = waitingSource.catalog(catalog(sourceA, "A1"), from: waitingPeer); waitingSource.queue.sync {}
waitingSource.link.hold(waitingPeer)
waitingInput.drag(from: p, to: q, mode: .pointer); waitingSource.queue.sync {}
_ = waitingSource.catalog(catalog(sourceB, "B1"), from: waitingPeer); waitingSource.queue.sync {}
check(inputs(waitingPeer).isEmpty, "source switch drops unsent down without inventing release debt")
waitingSource.sendInput(.text("new source")); waitingSource.queue.sync {}
_ = waitingSource.link.unhold(waitingPeer)
check(events(waitingPeer) == [.text("new source")] && inputs(waitingPeer).last?.generation == "B1", "only new source input survives old source cancellation")
waitingInput.endGesture(); waitingInput.drag(from: p, to: q, mode: .pointer); waitingSource.queue.sync {}
let sameSourceCount = inputs(waitingPeer).count
_ = waitingSource.catalog(catalog(sourceB, "B2"), from: waitingPeer); waitingSource.queue.sync {}
check(inputs(waitingPeer).count == sameSourceCount + 1 && inputs(waitingPeer).last?.generation == "B1", "generation change drains held debt even when source identity matches")

let flushed = StreamClient(), flushedPeer = NWConnection()
flushed.connection = flushedPeer
_ = flushed.catalog(catalog(sourceA, "flush-A"), from: flushedPeer); flushed.queue.sync {}
flushed.link.hold(flushedPeer)
flushed.sendInput(.key(hidUsage: 0x04, down: true, modifiers: 0)); flushed.queue.sync {}
let flushEntered = DispatchSemaphore(value: 0), flushResume = DispatchSemaphore(value: 0)
flushed.queue.async { flushEntered.signal(); flushResume.wait() }
flushEntered.wait()
_ = flushed.catalog(catalog(sourceB, "flush-B"), from: flushedPeer)
_ = flushed.link.unhold(flushedPeer)
check(inputs(flushedPeer).count == 1 && inputs(flushedPeer).first?.generation == "flush-A", "held queue flush transmits captured input after catalog update")
flushResume.signal(); flushed.queue.sync {}
check(events(flushedPeer).last == .key(hidUsage: 0x04, down: false, modifiers: 0) && inputs(flushedPeer).last?.generation == "flush-A", "delayed actual-send callback records original generation debt")

let debt = VisionInputDebt(), debtPeer = NWConnection()
let command = KeyModifiers.command.rawValue, shift = KeyModifiers.shift.rawValue
debt.record(CapturedVisionInput(event: .key(hidUsage: 0xE3, down: true, modifiers: command), generation: "held-A"), on: debtPeer)
debt.record(CapturedVisionInput(event: .key(hidUsage: 0xE1, down: true, modifiers: command | shift), generation: "held-A"), on: debtPeer)
debt.record(CapturedVisionInput(event: .pointer(.rightDown, x: p.x, y: p.y), generation: "held-A"), on: debtPeer)
debt.record(CapturedVisionInput(event: .pointer(.move, x: q.x, y: q.y), generation: "later"), on: debtPeer)
debt.record(CapturedVisionInput(event: .scrollGesture(.began, x: p.x, y: p.y), generation: "scroll-A"), on: debtPeer)
check(debt.release(on: stranger).isEmpty, "wrong peer cannot consume release debt")
let debtUps = debt.release(on: debtPeer)
check(debtUps.map(\.generation) == ["held-A", "scroll-A", "held-A", "held-A"], "each debt release retains its originating generation")
check(debtUps.map(\.event) == [.pointer(.rightUp, x: q.x, y: q.y), .scrollGesture(.ended, x: p.x, y: p.y), .key(hidUsage: 0xE1, down: false, modifiers: command), .key(hidUsage: 0xE3, down: false, modifiers: 0)], "debt updates position and releases keys in reverse order with remaining flags")
check(debt.release(on: debtPeer).isEmpty, "source debt release is idempotent")
print("Vision controls \(checks)/\(checks)")
