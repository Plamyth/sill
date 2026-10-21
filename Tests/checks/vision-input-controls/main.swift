import Foundation
import Network
import StreamProtocol
import SwiftUI
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
            return CapturedVisionInput(event: scoped.event, generation: scoped.generation, videoEpoch: scoped.videoEpoch)
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
do {
    let feedback = StreamClient(), original = NWConnection()
    feedback.connection = original
    seedLegacy(feedback, original)
    feedback.link.hold(original)
    feedback.sendInput(.pointer(.move, x: p.x, y: p.y)); feedback.queue.sync {}
    var drained = false
    DispatchQueue.main.async { drained = true }
    waitMain { drained }
    check(feedback.pointerPoints.isEmpty, "queued spatial input cannot draw a cursor before transport submission")
    _ = feedback.link.unhold(original)
    waitMain { feedback.pointerPoints.count == 1 }
    check(feedback.pointerPoints.last! == p, "submitted spatial input shows the exact target")
    check(feedback.cursorVisible == p, "submitted target is visible")
    feedback.sendInput(.pointer(.move, x: q.x, y: q.y)); feedback.queue.sync {}
    feedback.connection = NWConnection()
    check(feedback.cursorVisible == nil, "connection change immediately hides the old spatial cursor")
    drained = false
    DispatchQueue.main.async { drained = true }
    waitMain { drained }
    check(feedback.pointerPoints.count == 1, "late spatial feedback cannot cross a connection change")
    let replacement = feedback.connection!
    seedLegacy(feedback, replacement)
    feedback.sendInput(.pointer(.move, x: q.x, y: q.y)); feedback.queue.sync {}
    _ = feedback.catalog(WindowList(macName: "검사 Mac", windows: [], active: .desktop,
                                   inputGeneration: "changed"), from: replacement)
    check(feedback.cursorVisible == nil, "source generation change immediately hides the old spatial cursor")
    drained = false
    DispatchQueue.main.async { drained = true }
    waitMain { drained }
    check(feedback.pointerPoints.count == 1, "late spatial feedback cannot cross a source generation change")
    let oldCount = feedback.pointerPoints.count
    feedback.sendInput(.pointer(.move, x: q.x, y: q.y)); feedback.queue.sync {}
    feedback.cancelVisionInputs()
    drained = false
    DispatchQueue.main.async { drained = true }
    waitMain { drained }
    check(feedback.pointerPoints.count == oldCount && feedback.cursorVisible == nil,
          "cancelled spatial callback cannot resurrect a cursor on the same peer permit and binding")
}
let testGeometry = VisionPointer.Geometry(bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), video: CGSize(width: 1000, height: 1000))
struct TestPinch { let id: UUID; let revision: UUID }
var testPinches: [ObjectIdentifier: TestPinch] = [:]
extension VisionInputSession {
    func testHoldDrag(from start: CGPoint, to point: CGPoint) {
        let key = ObjectIdentifier(self)
        let first = testPinches[key] == nil
        let pinch = testPinches[key] ?? TestPinch(id: UUID(), revision: gestureRevision)
        testPinches[key] = pinch
        if first {
            spatial([.init(id: pinch.id, timestamp: 0, location: CGPoint(x: start.x * 1000, y: start.y * 1000), phase: .active)],
                    geometry: testGeometry, revision: pinch.revision)
        }
        spatial([.init(id: pinch.id, timestamp: 1, location: CGPoint(x: point.x * 1000, y: point.y * 1000), phase: .active)],
                geometry: testGeometry, revision: pinch.revision)
    }
    func testEndGesture() {
        if let pinch = testPinches.removeValue(forKey: ObjectIdentifier(self)) { finishGesture(revision: pinch.revision) }
    }
    func testClick(_ point: CGPoint) {
        let id = UUID(), revision = gestureRevision
        let location = CGPoint(x: point.x * 1000, y: point.y * 1000)
        spatial([.init(id: id, timestamp: 0, location: location, phase: .active)], geometry: testGeometry, revision: revision)
        spatial([.init(id: id, timestamp: 0.1, location: location, phase: .ended)], geometry: testGeometry, revision: revision)
        finishGesture(revision: revision)
    }
}
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
_ = link.unhold(lb)
check(lb.sent.last == Data([8, 5]), "stale cleanup cannot erase replacement peer input")
link.hold(lb)
_ = link.send(Data([8, 6]), onlyOn: lb)
link.send(Data([5, 10]))
_ = link.adopt(lc)
check(lc.sent == [Data([5, 10])] && link.inputsOnSession == 0, "scoped waiting input stays with origin while generic control migrates")
let client = StreamClient(), input = VisionInputSession()
let a = NWConnection(), b = NWConnection(), c = NWConnection()
input.bind(client); input.setGeometry(testGeometry); input.allowed = true
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
input.testHoldDrag(from: p, to: q)
client.queue.sync {}
let bBefore = events(b).count
client.connection = c
check(events(b).dropFirst(bBefore).first == .pointer(.leftUp, x: q.x, y: q.y), "actual setter releases old peer atomically")
check(events(c).isEmpty && input.latched.isEmpty, "setter never sends old release to replacement")
seedLegacy(client, c)
input.testHoldDrag(from: p, to: q); client.queue.sync {}
check(events(c).isEmpty, "held gesture remains cancelled across setter")
input.testEndGesture()
input.toggle(.shift)
input.testClick(p); client.queue.sync {}
check(events(c).count == 5 && input.latched.isEmpty, "one-shot modifier click consumes latch")
input.toggle(.option)
input.testHoldDrag(from: p, to: q); client.queue.sync {}
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
input.testEndGesture(); input.press(.left); input.press(.left); client.queue.sync {}
check(events(d).isEmpty, "new input waits behind previous route fence")
_ = client.link.fenceReturned(Data([1]), on: c)
check(events(d).count == 4, "two accepted palette keys survive old fence")
let overlay = InputOverlayView(); input.keyboard.view = overlay
_ = overlay.forwarded.began(0xE3, modifiers: KeyModifiers.command.rawValue)
let ups = input.takeReleases()
check(ups == [.key(hidUsage: 0xE3, down: false, modifiers: 0)], "reset drains hardware ownership")
check(input.takeReleases().isEmpty, "hardware reset is idempotent")
let owed = StreamClient(), owedInput = VisionInputSession(), owedPeer = NWConnection()
owedInput.bind(owed); owedInput.setGeometry(testGeometry); owedInput.allowed = true; owed.connection = owedPeer
seedLegacy(owed, owedPeer)
owedInput.testHoldDrag(from: p, to: q); owed.queue.sync {}
owed.link.hold(owedPeer)
owedInput.testEndGesture(); owed.queue.sync {}
check(events(owedPeer).count == 3, "hold queues terminal up after transmitted down")
owedInput.releaseAll(); owed.queue.sync {}
check(events(owedPeer).last == .scrollGesture(.ended, x: p.x, y: p.y), "emergency retains release debt after local gesture already ended")
_ = owed.link.unhold(owedPeer)
check(events(owedPeer).count == 4, "cancelled queued release cannot replay after unhold")
let fresh = NWConnection(); owed.moving = .init(connection: fresh); owed.finish(fresh)
waitMain { owed.completions == 1 }
seedLegacy(owed, fresh)
let oldCount = events(owedPeer).count
owedInput.testHoldDrag(from: p, to: q); owed.queue.sync {}
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
let iPadHello = Wire.decode(Hello.self, from: StreamClient.iPadHello)!
check(iPadHello.sourceInput == 1, "actual iPad Hello advertises scoped input")
var iPadFence = SourceInputFence<String>()
_ = iPadFence.join("ipad", source: sourceA, switching: false)
iPadFence.negotiate("ipad", supportsScoped: iPadHello.sourceInput == 1)
check(iPadFence.allowsSelection(sourceB), "actual iPad Hello releases real host legacy pin")
let oldHello = Wire.decode(Hello.self, from: Data("{}".utf8))!
check(oldHello.sourceInput == nil, "genuinely old Hello has no source capability")
var legacyFence = SourceInputFence<String>()
_ = legacyFence.join("old", source: sourceA, switching: false)
legacyFence.negotiate("old", supportsScoped: oldHello.sourceInput == 1)
check(!legacyFence.allowsSelection(sourceB), "old Hello retains real host legacy pin")
let composed = Wire.decode(WindowList.self, from: Wire.encode(catalog(sourceA, "A1")))!
check(composed.remoteAudio == 1 && composed.inputGeneration == "A1", "catalog composes remote audio and generation")
let oldCatalog = Wire.decode(WindowList.self, from: Data(#"{"macName":"Old Mac","windows":[],"active":{"desktop":{}}}"#.utf8))!
check(oldCatalog.inputGeneration == nil && oldCatalog.remoteAudio == nil, "old catalog decodes without new optional fields")

let scoped = StreamClient(), scopedInput = VisionInputSession(), scopedPeer = NWConnection()
scopedInput.bind(scoped); scopedInput.setGeometry(testGeometry); scopedInput.allowed = true; scoped.connection = scopedPeer
check(scoped.catalog(catalog(sourceA, "A1"), from: scopedPeer), "current peer catalog establishes source binding")
scoped.queue.sync {}
scopedInput.toggle(.command)
scopedInput.testHoldDrag(from: p, to: q); scoped.queue.sync {}
let heldCount = inputs(scopedPeer).count
_ = scoped.catalog(catalog(sourceA, "A1"), from: scopedPeer); scoped.queue.sync {}
check(inputs(scopedPeer).count == heldCount, "unchanged catalog preserves held stroke")
check(scoped.catalog(catalog(sourceB, "B1"), from: scopedPeer), "new current peer source catalog applies")
scoped.queue.sync {}
let sourceReleases = Array(inputs(scopedPeer).dropFirst(heldCount))
check(sourceReleases.count == 2 && sourceReleases.allSatisfy { $0.generation == "A1" }, "source change releases held input with original generation")
check(sourceReleases.map(\.event) == [.pointer(.leftUp, x: q.x, y: q.y), .key(hidUsage: 0xE3, down: false, modifiers: 0)], "source release balances pointer before modifier")
check(scoped.active == sourceB && scopedInput.latched.isEmpty, "catalog publishes new source after local ownership drain")
scopedInput.testHoldDrag(from: p, to: q); scoped.queue.sync {}
check(inputs(scopedPeer).count == heldCount + 2, "held gesture cannot restart after source switch")
scopedInput.testEndGesture(); scopedInput.press(.enter); scopedInput.press(.left); scoped.queue.sync {}
check(inputs(scopedPeer).suffix(4).allSatisfy { $0.generation == "B1" }, "ordinary successive chords retain new source scope")

let early = StreamClient(), earlyInput = VisionInputSession(), earlyPeer = NWConnection()
earlyInput.bind(early); earlyInput.setGeometry(testGeometry); earlyInput.allowed = true
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
check(queued.count == 1 && queued[0].generation == "B1", "queued input revoked before submission cannot cross source update")
check(!hostFence.accepts("vision", generation: "A1", current: "B1", source: sourceB), "real host guard rejects delayed source A input on B")
check(hostFence.accepts("vision", generation: queued[0].generation, current: "B1", source: sourceB), "real host guard accepts current source B input")
_ = early.catalog(catalog(sourceA, "A2"), from: earlyPeer)
early.sendInput(.text("returned A")); early.queue.sync {}
check(!hostFence.accepts("vision", generation: "A1", current: "A2", source: sourceA), "A to B to A rejects first A generation")
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
scopedInput.testHoldDrag(from: p, to: q); scoped.queue.sync {}
scoped.link.hold(scopedPeer)
scopedInput.testEndGesture(); scoped.queue.sync {}
let pendingUp = inputs(scopedPeer).count
_ = scoped.catalog(catalog(sourceA, "A2"), from: scopedPeer); scoped.queue.sync {}
check(inputs(scopedPeer).count == pendingUp + 1 && inputs(scopedPeer).last?.generation == "B1" && events(scopedPeer).last == .scrollGesture(.ended, x: p.x, y: p.y), "catalog releases transmitted scroll whose terminal was queued")
_ = scoped.link.unhold(scopedPeer)
check(inputs(scopedPeer).count == pendingUp + 1, "old queued source release cannot replay")
scopedInput.testEndGesture()
scopedInput.testHoldDrag(from: p, to: q); scoped.queue.sync {}
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
earlyInput.toggle(.command); earlyInput.press(.enter); earlyInput.testClick(p)
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
waitingInput.bind(waitingSource); waitingInput.setGeometry(testGeometry); waitingInput.allowed = true; waitingSource.connection = waitingPeer
_ = waitingSource.catalog(catalog(sourceA, "A1"), from: waitingPeer); waitingSource.queue.sync {}
waitingSource.link.hold(waitingPeer)
waitingInput.testHoldDrag(from: p, to: q); waitingSource.queue.sync {}
_ = waitingSource.catalog(catalog(sourceB, "B1"), from: waitingPeer); waitingSource.queue.sync {}
check(inputs(waitingPeer).isEmpty, "source switch drops unsent down without inventing release debt")
waitingSource.sendInput(.text("new source")); waitingSource.queue.sync {}
_ = waitingSource.link.unhold(waitingPeer)
check(events(waitingPeer) == [.text("new source")] && inputs(waitingPeer).last?.generation == "B1", "only new source input survives old source cancellation")
waitingInput.testEndGesture(); waitingInput.testHoldDrag(from: p, to: q); waitingSource.queue.sync {}
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
check(inputs(flushedPeer).isEmpty, "held queue flush rejects revoked input after catalog update")
flushResume.signal(); flushed.queue.sync {}
check(inputs(flushedPeer).isEmpty, "revoked unsent input creates no actual-send release debt")

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
let coastEpoch = UUID()
debt.record(CapturedVisionInput(event: .scrollGesture(.momentumBegan, x: p.x, y: p.y), generation: "coast-A", videoEpoch: coastEpoch), on: debtPeer)
let coastUps = debt.release(on: debtPeer)
check(coastUps.map(\.event) == [.scrollGesture(.momentumEnded, x: p.x, y: p.y)], "source debt closes momentum with its matching host phase")
check(coastUps.first?.generation == "coast-A" && coastUps.first?.videoEpoch == coastEpoch && debt.release(on: debtPeer).isEmpty, "momentum release retains its original presentation and is idempotent")
let resumeClient = StreamClient()
let idleCatalog = catalog(.none, "idle")
for prior in [StreamSource.window(999), .desktop] {
    StreamClient.noAutoDesktop = true
    resumeClient.resumeSource = prior
    resumeClient.resumeCatalog(idleCatalog)
    check(resumeClient.requested.isEmpty && resumeClient.resumeSource == nil,
          "native automatic resume clears pending choice without source effects")
    resumeClient.resumeCatalog(idleCatalog)
    check(resumeClient.requested.isEmpty, "cleared native resume cannot carry into a later catalog")
}
StreamClient.noAutoDesktop = false
resumeClient.resumeSource = .window(999)
resumeClient.resumeCatalog(idleCatalog)
check(resumeClient.requested == [.desktop] && resumeClient.resumeSource == nil,
      "iPad automatic restore keeps peer missing-window desktop fallback")
resumeClient.requested = []
resumeClient.resumeSource = .window(42)
let restoredWindow = WindowInfo(id: 42, title: "Still present", appName: "Fixture", bundleID: "fixture", width: 100, height: 100)
resumeClient.resumeCatalog(catalog(.none, "idle", windows: [restoredWindow]))
check(resumeClient.requested == [.window(42)] && resumeClient.resumeSource == nil,
      "iPad automatic restore keeps peer surviving-window choice")
resumeClient.requested = []
resumeClient.resumeSource = .window(42)
resumeClient.resumeCatalog(catalog(.desktop, "already-streaming"))
check(resumeClient.requested.isEmpty && resumeClient.resumeSource == nil,
      "active host consumes resume without replacing its source")
StreamClient.noAutoDesktop = true
let displayGate = StreamClient(), displayGateInput = VisionInputSession(), displayGatePeer = NWConnection()
displayGateInput.bind(displayGate); displayGateInput.setGeometry(testGeometry); displayGateInput.allowed = true
displayGate.connection = displayGatePeer; seedLegacy(displayGate, displayGatePeer)
check(displayGateInput.canSend, "display transition gate starts from usable input")
displayGate.visionDisplaySelection.setModal(true)
displayGateInput.press(.enter)
displayGate.sendInput(.text("blocked display input")); displayGate.queue.sync {}
check(!displayGateInput.canSend && inputs(displayGatePeer).isEmpty, "display transition blocks controls and direct native input")
displayGate.visionDisplaySelection.setModal(false)
displayGateInput.press(.enter); displayGate.queue.sync {}
check(events(displayGatePeer).count == 2, "confirmed display gate can restore ordinary native controls")
let gestureClient = StreamClient(), gestureInput = VisionInputSession(), gesturePeer = NWConnection()
gestureInput.bind(gestureClient); gestureInput.setGeometry(testGeometry); gestureInput.allowed = true
gestureClient.connection = gesturePeer
seedLegacy(gestureClient, gesturePeer)
func nativeSample(_ id: Int, _ time: TimeInterval, _ x: CGFloat = 500, _ y: CGFloat = 500,
                  _ phase: VisionPointer.Sample.Phase = .active) -> VisionPointer.Sample {
    .init(id: id, timestamp: time, location: CGPoint(x: x, y: y), phase: phase)
}
let gestureTicket = gestureInput.gestureRevision
gestureInput.toggle(.option)
gestureInput.spatial([nativeSample(1, 0)], geometry: testGeometry, revision: gestureTicket)
gestureClient.queue.sync {}
check(events(gesturePeer) == [.pointer(.move, x: 0.5, y: 0.5)] && gestureInput.latched.isEmpty, "actual pinch begins at native target and snapshots one-shot modifier")
gestureInput.spatial([nativeSample(1, 0.1, 500, 600)], geometry: testGeometry, revision: gestureTicket)
gestureClient.queue.sync {}
check(events(gesturePeer).suffix(2).first == .scrollGesture(.began, x: 0.5, y: 0.5), "actual session starts scroll at the original pinch target")
gestureInput.magnify(2, at: CGPoint(x: 750, y: 250), time: 1, geometry: testGeometry, revision: gestureTicket)
gestureClient.queue.sync {}
check(events(gesturePeer).suffix(2).first == .scrollGesture(.ended, x: 0.5, y: 0.5) && events(gesturePeer).last == KeyChord.modifiersUp(.option).last, "native magnification releases scroll before changing local viewport")
check(gestureInput.viewport.scale == 2 && gestureInput.viewport.offset == CGSize(width: -250, height: 250), "actual magnification applies native start location to bounded viewport")
gestureInput.magnify(3, at: .zero, time: 1.1, geometry: testGeometry, revision: gestureTicket)
check(gestureInput.viewport.scale == 3 && gestureInput.viewport.offset == CGSize(width: -500, height: 500), "native magnification uses gesture base and initial anchor rather than accumulating callback factors")
gestureInput.magnify(4, at: .zero, time: 1, geometry: testGeometry, revision: gestureTicket)
check(gestureInput.viewport.scale == 3, "out of order native magnification cannot rewind viewport")
gestureInput.magnify(2, at: .zero, time: 1.2, geometry: testGeometry, revision: gestureTicket)
let beforeZoomTail = events(gesturePeer).count
gestureInput.spatial([nativeSample(1, 1.1, 600, 600, .ended), nativeSample(2, 1.1, 700, 700)], geometry: testGeometry, revision: gestureTicket)
gestureInput.spatial([nativeSample(2, 1.2, 700, 700, .ended)], geometry: testGeometry, revision: gestureTicket)
gestureInput.finishGesture(revision: gestureTicket)
gestureClient.queue.sync {}
check(events(gesturePeer).count == beforeZoomTail, "two-hand zoom sends no host semantic zoom and no contact tails")
let zoomedTicket = gestureInput.gestureRevision
gestureInput.spatial([nativeSample(3, 2, 750, 250)], geometry: testGeometry, revision: zoomedTicket)
gestureInput.spatial([nativeSample(3, 2.1, 750, 250, .ended)], geometry: testGeometry, revision: zoomedTicket)
gestureInput.finishGesture(revision: zoomedTicket)
gestureClient.queue.sync {}
check(Array(events(gesturePeer).suffix(3)) == [.pointer(.move, x: 0.75, y: 0.25), .pointer(.leftDown, x: 0.75, y: 0.25), .pointer(.leftUp, x: 0.75, y: 0.25)], "actual session click uses inverse of displayed zoom and offset")
let inwardTicket = gestureInput.gestureRevision
gestureInput.magnify(0.5, at: CGPoint(x: 750, y: 250), time: 2, geometry: testGeometry, revision: inwardTicket)
gestureInput.finishGesture(revision: inwardTicket)
check(gestureInput.viewport == VisionViewport(), "new native inward gesture returns to one without mode selection")
let cancelledTicket = gestureInput.gestureRevision
gestureInput.spatial([nativeSample(4, 3)], geometry: testGeometry, revision: cancelledTicket)
gestureInput.spatial([nativeSample(4, 3.7, 600, 700)], geometry: testGeometry, revision: cancelledTicket)
gestureClient.queue.sync {}
let beforeLoss = events(gesturePeer).count
gestureInput.allowed = false
gestureClient.queue.sync {}
check(events(gesturePeer).count == beforeLoss + 1 && events(gesturePeer).last == .scrollGesture(.ended, x: 0.5, y: 0.5), "admission loss ends live native scroll through actual send debt")
gestureInput.allowed = true
gestureInput.spatial([nativeSample(4, 4, 700, 800)], geometry: testGeometry, revision: cancelledTicket)
gestureInput.spatial([nativeSample(4, 4.1, 700, 800, .ended)], geometry: testGeometry, revision: cancelledTicket)
gestureInput.magnify(3, at: CGPoint(x: 500, y: 500), time: 4, geometry: testGeometry, revision: cancelledTicket)
gestureClient.queue.sync {}
check(events(gesturePeer).count == beforeLoss + 1 && gestureInput.viewport.scale == 1, "revoked admission revision cannot rearm or zoom after admission restores")
let geometryTicket = gestureInput.gestureRevision
gestureInput.spatial([nativeSample(5, 5)], geometry: testGeometry, revision: geometryTicket)
let resized = VisionPointer.Geometry(bounds: CGRect(x: 0, y: 0, width: 900, height: 900), video: testGeometry.video)
gestureInput.setGeometry(resized)
gestureClient.queue.sync {}
let afterResize = events(gesturePeer).count
gestureInput.spatial([nativeSample(5, 5.1, 500, 500, .ended)], geometry: resized, revision: geometryTicket)
gestureInput.finishGesture(revision: geometryTicket)
gestureClient.queue.sync {}
check(events(gesturePeer).count == afterResize, "geometry change revokes pending pinch and stale terminal cannot click")
let mismatchTicket = gestureInput.gestureRevision
gestureInput.spatial([nativeSample(6, 6)], geometry: testGeometry, revision: mismatchTicket)
gestureClient.queue.sync {}
check(events(gesturePeer).count == afterResize, "callback for unrendered geometry cannot target a different viewport")
gestureInput.setGeometry(testGeometry)
let badAnchorTicket = gestureInput.gestureRevision
gestureInput.magnify(2, at: CGPoint(x: -1, y: 500), time: 6.5, geometry: testGeometry, revision: badAnchorTicket)
gestureInput.spatial([nativeSample(7, 6.6)], geometry: testGeometry, revision: badAnchorTicket)
gestureInput.spatial([nativeSample(7, 6.7, 500, 500, .ended)], geometry: testGeometry, revision: badAnchorTicket)
gestureInput.finishGesture(revision: badAnchorTicket)
gestureClient.queue.sync {}
check(events(gesturePeer).count == afterResize && gestureInput.viewport.scale == 1, "invalid zoom anchor remains locally unchanged and suppresses all hand tails")
let overlayKeys = InputOverlayView(); gestureInput.keyboard.view = overlayKeys
let heldCommand = KeyModifiers.command.rawValue
_ = overlayKeys.forwarded.began(0xE3, modifiers: heldCommand)
gestureInput.overlayInput(.key(hidUsage: 0xE3, down: true, modifiers: heldCommand))
gestureInput.overlayInput(.key(hidUsage: 0x04, down: true, modifiers: heldCommand))
check(gestureInput.takeReleases() == [.key(hidUsage: 0xE3, down: false, modifiers: 0)], "overlay pointer cancellation preserves keyboard's independently held ownership")
gestureInput.releaseAll(); gestureClient.queue.sync {}
let rawEvent = SpatialEventCollection.Event(id: 17, timestamp: 9.25, kind: .indirectPinch, location: CGPoint(x: 220, y: 330), phase: .active)
let adapted = VisionPointer.Sample(rawEvent)!
check(adapted.id == AnyHashable(17) && adapted.timestamp == 9.25 && adapted.location == rawEvent.location && adapted.phase == .active, "actual adapter preserves native id timestamp and local interaction location")
let phasePairs: [(SpatialEventCollection.Event.Phase, VisionPointer.Sample.Phase)] = [(.ended, .ended), (.cancelled, .cancelled)]
for pair in phasePairs {
    let event = SpatialEventCollection.Event(id: 18, timestamp: 10, kind: .directPinch, location: .zero, phase: pair.0)
    check(VisionPointer.Sample(event)?.phase == pair.1, "actual adapter distinguishes native ended and cancelled")
}
check(VisionPointer.Sample(.init(id: 19, timestamp: 10, kind: .pointer, location: .zero, phase: .active)) == nil, "native hover pointer is never treated as a pinch")
let continuityClient = StreamClient(), continuityInput = VisionInputSession(), continuityPeer = NWConnection()
continuityInput.bind(continuityClient); continuityInput.setGeometry(testGeometry); continuityInput.allowed = true
continuityClient.connection = continuityPeer; seedLegacy(continuityClient, continuityPeer)
continuityInput.magnify(2, at: CGPoint(x: 750, y: 250), time: 0, geometry: testGeometry, revision: continuityInput.gestureRevision)
continuityInput.finishGesture(revision: continuityInput.gestureRevision)
let continuityTicket = continuityInput.gestureRevision
continuityInput.toggle(.option)
continuityInput.spatial([nativeSample(50, 1, 750, 250)], geometry: testGeometry, revision: continuityTicket)
continuityInput.spatial([nativeSample(50, 1.1, 850, 450)], geometry: testGeometry, revision: continuityTicket)
continuityInput.spatial([nativeSample(50, 1.2, 2000, 2000)], geometry: testGeometry, revision: continuityTicket)
continuityInput.spatial([nativeSample(50, 1.3, 2200, 2100), nativeSample(50, 1.25, 2100, 2050)], geometry: testGeometry, revision: continuityTicket)
continuityInput.spatial([nativeSample(50, 1.4, 2200, 2100, .ended), nativeSample(50, 1.5, 750, 250)], geometry: testGeometry, revision: continuityTicket)
continuityInput.spatial([nativeSample(50, 1.6, 750, 250, .ended)], geometry: testGeometry, revision: continuityTicket)
continuityClient.queue.sync {}
check(events(continuityPeer) == [.pointer(.move, x: 0.75, y: 0.25)] + KeyChord.modifiersDown(.option) + [
    .scrollGesture(.began, x: 0.75, y: 0.25), .scroll(x: 0.75, y: 0.25, dx: 0.1, dy: 0.2),
    .scroll(x: 0.75, y: 0.25, dx: 1.15, dy: 1.55), .scroll(x: 0.75, y: 0.25, dx: 0.2, dy: 0.1),
    .scrollGesture(.ended, x: 0.75, y: 0.25)] + KeyChord.modifiersUp(.option),
    "actual session preserves raw zoomed outside scroll and ignores stale and retired batch tails")
continuityInput.finishGesture(revision: continuityTicket)
let dragTicket = continuityInput.gestureRevision
let beforeOrderedDrag = events(continuityPeer).count
continuityInput.spatial([nativeSample(51, 2, 750, 250)], geometry: testGeometry, revision: dragTicket)
continuityInput.spatial([nativeSample(51, 2.8, 950, 650), nativeSample(51, 2.7, 3000, 3000)], geometry: testGeometry, revision: dragTicket)
continuityInput.spatial([nativeSample(51, 2.9, 3000, 3000, .cancelled)], geometry: testGeometry, revision: dragTicket)
continuityClient.queue.sync {}
check(Array(events(continuityPeer).dropFirst(beforeOrderedDrag)) == [
    .pointer(.move, x: 0.75, y: 0.25), .scrollGesture(.began, x: 0.75, y: 0.25),
    .scroll(x: 0.75, y: 0.25, dx: 0.2, dy: 0.4), .scrollGesture(.ended, x: 0.75, y: 0.25)],
    "actual session held scroll and cancellation retain original inverse anchor within a batch")
runLifecycleTests()
print("RESULT_ASSERTIONS \(checks)")

print("Vision controls \(checks)/\(checks)")
