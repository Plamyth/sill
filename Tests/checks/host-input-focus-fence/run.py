#!/usr/bin/env python3
"""Exercise production admission and held replay with inert OS/input adapters."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
HOST = "Sources/SillHost/StreamCoordinator.swift"
BASE = "5c4c4d4b791e21d7a9a1b594d9ca2b876f088c90"


def function(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def program(host, protocol, sizer):
    names = ["deliver(_", "applyAdmittedInput(_", "releaseHeldInput()", "raiseIfInteracting(_"]
    names += [n for n in ["inputTargetReady(_", "applyAdmittedChord("] if "private func " + n in host]
    methods = "\n".join(function(host, "private func " + n) for n in names)
    chord = "" if "private func applyAdmittedChord(" in host else "func applyAdmittedChord(keyCode: UInt16, flags: UInt64) { injector.chord(keyCode: keyCode, flags: flags) }"
    match = function(sizer, "private static func axWindow(matching window:")
    return protocol.split("public struct SourceInput:", 1)[0] + r'''
import CoreFoundation
import CoreGraphics
enum Clock {
    static var now: CFAbsoluteTime = 10000
    static var onSleep: (() -> Void)?
}
func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime { Clock.now }
struct Task {
    static var pending: [@MainActor () async -> Void] = []
    init(operation: @escaping @MainActor () async -> Void) { Self.pending.append(operation) }
    static func sleep(for duration: Duration) async throws {
        Clock.now += 0.02
        Clock.onSleep?()
    }
    static func drain() async {
        while !pending.isEmpty { await pending.removeFirst()() }
    }
}
typealias AXUIElement = Int
enum StreamSource: Equatable { case none, desktop, window(UInt32) }
struct VideoEpoch { let generation: String; let id: UUID }
struct SourceInput { let event: InputEvent; let generation: String; let videoEpoch: UUID }
enum KeyStrokes { typealias Device = Int }
enum Stats { static let shared = Counter() }
final class Counter { func bump(_ name: String) {} }
struct App { let processID: Int32 }
struct NSRunningApplication {
    init?(processIdentifier: Int32) {}
    func activate(options: [Int]) -> Bool { false }
}
struct Window {
    let owningApplication: App?
    var windowID: UInt32 = 7
    var title: String? = "fixture"
    var frame = CGRect(x: 0, y: 0, width: 100, height: 100)
}
typealias SCWindow = Window
final class Catalog { func window(id: UInt32) -> Window? { Window(owningApplication: App(processID: 22)) } }
let kAXWindowsAttribute = "AXWindows"
let kAXTitleAttribute = "AXTitle"
enum AXError { case success }
func AXUIElementSetMessagingTimeout(_ element: Int, _ timeout: Float) {}
func AXUIElementCopyAttributeValue(_ element: Int, _ name: CFString, _ value: inout CFTypeRef?) -> AXError {
    value = WindowSizer.candidates as NSArray
    return .success
}
final class WindowSizer {
    static var focused = false
    func element(for window: Window, input: Bool = false) -> AXUIElement? { Self.unique ? 99 : nil }
    static var unique = true
    static func hasKeyboardFocus(_ element: AXUIElement, pid: Int32) -> Bool { focused }
    static var keyRequests: [Int] = []
    static var focusOnRequest = true
    static func makeKey(_ element: Int) {
        keyRequests.append(element)
        if focusOnRequest { focused = true }
    }
    static func raise(_ element: Int) -> Bool { Host.pointID = 7; return true }
    static let frameTolerance: CGFloat = 4
    static var candidates = [99]
    static var bounds: CGRect? = CGRect(x: 0, y: 0, width: 100, height: 100)
    static var frames = [99: CGRect(x: 0, y: 0, width: 100, height: 100)]
    static func liveBounds(of id: UInt32) -> CGRect? { bounds }
    static func frame(of element: Int) -> CGRect? { frames[element] }
    static func string(of element: Int, _ key: String) -> String? { "fixture" }
    static func matchInput() -> Int? { axWindow(matching: Window(owningApplication: App(processID: 22)), in: 22, input: true) }
''' + match + r'''
}
struct Placement { let pid: Int32; let element: AXUIElement }
struct Stage {
    var isStaged = false
    var placement: Placement? = Placement(pid: 22, element: 99)
    var evictions = 0
    var uncover = true
    mutating func evictForeignWindows() {
        evictions += 1
        if uncover { Host.pointID = 7 }
    }
}
final class Injector {
    var owed = false
    var events: [InputEvent] = []
    var nulls: [Bool] = []
    var chords = 0
    var releases = 0
    var afterApply: (() -> Void)?
    func isUpOfSomethingDown(_ event: InputEvent, from device: Int) -> Bool {
        guard owed else { return false }
        switch event {
        case .key(_, false, _), .pointer(.leftUp, _, _), .pointer(.rightUp, _, _): return true
        default: return false
        }
    }
    func apply(_ event: InputEvent, in rect: CGRect, from device: Int) {
        events.append(event); nulls.append(rect.isNull)
        if isUpOfSomethingDown(event, from: device) { owed = false }
        afterApply?()
    }
    func chord(keyCode: UInt16, flags: UInt64) { chords += 1 }
    func releaseInput(of device: Int) { releases += 1; owed = false }
}
final class Host {
    enum Held { case input(InputEvent, CGRect, Int, VideoEpoch?), chord(keyCode: UInt16, flags: UInt64), disconnect(Int) }
    var heldInput: [Held] = []
    var holdUntil: CFAbsoluteTime = 0
    var switching = false
    var synthetic = false
    var active = StreamSource.window(7)
    var virtualDisplay = false
    var stage = Stage()
    var catalog = Catalog()
    var sizer = WindowSizer()
    var injector = Injector()
    var validEpoch = true
    var lastRaiseCheck: CFAbsoluteTime = 0
    var lastActivationAt: CFAbsoluteTime = 0
    static let activationTimeout: TimeInterval = 0.6
    var activations: [Int32] = []
    var activationAnswered = true
    var activateOnRequest = true
    static var frontPID: Int32? = 22
    static var pointID: UInt32? = 7
    let appKitLoop = true
    func activate(pid: Int32) -> Bool {
        activations.append(pid)
        if activationAnswered && activateOnRequest { Self.frontPID = pid }
        return activationAnswered
    }
    func presentationInputRect(_ input: SourceInput) -> CGRect? { validEpoch ? CGRect(x: 10, y: 20, width: 300, height: 200) : nil }
    func injectorProbePoint(_ event: InputEvent) -> CGPoint? {
        switch event {
        case .pointer, .scroll, .scrollGesture: return CGPoint(x: 20, y: 30)
        default: return nil
        }
    }
    static func topmostWindow(at point: CGPoint?) -> (id: UInt32, pid: Int32)? { pointID.map { ($0, 22) } }
    static func activePID(trustAppKit: Bool) -> Int32? { frontPID }
    func logClick(_ event: InputEvent, in rect: CGRect) {}
''' + methods + "\n" + chord + r'''
    func replay(_ events: [InputEvent]) {
        holdUntil = CFAbsoluteTimeGetCurrent() + 1
        for event in events { deliver(event, in: CGRect(x: 0, y: 0, width: 100, height: 100), from: 1) }
        releaseHeldInput()
    }
    func immediate(_ event: InputEvent, epoch: VideoEpoch? = nil) {
        deliver(event, in: CGRect(x: 0, y: 0, width: 100, height: 100), from: 1, epoch: epoch)
    }
    func chord() { applyAdmittedChord(keyCode: 123, flags: 0) }
    func interact(_ event: InputEvent, epoch: VideoEpoch? = nil) {
        if !synthetic { raiseIfInteracting(event) }
        immediate(event, epoch: epoch)
    }
}
var checks = 0
var failures = 0
func check(_ pass: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !pass() { print("FAIL \(label)"); failures += 1 }
}
let down = InputEvent.key(hidUsage: 42, down: true, modifiers: 0)
let up = InputEvent.key(hidUsage: 42, down: false, modifiers: 0)
let left = InputEvent.key(hidUsage: 80, down: true, modifiers: 0)
let click = InputEvent.pointer(.leftDown, x: 0.5, y: 0.5)
let scroll = InputEvent.scroll(x: 0.5, y: 0.5, dx: 0, dy: 1)
let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
func fresh(front: Int32? = 22, focused: Bool = true, point: UInt32? = 7) -> Host {
    Host.frontPID = front; WindowSizer.focused = focused; WindowSizer.unique = true; Host.pointID = point
    WindowSizer.keyRequests = []; WindowSizer.focusOnRequest = true
    Clock.onSleep = nil
    return Host()
}
let wrongFront = fresh(front: 77)
wrongFront.replay([down, left, .text("private"), click, scroll, .pointer(.move, x: 0.5, y: 0.5)])
check(wrongFront.injector.events.isEmpty, "timeout/wrong OS front posts no key/text/click")
wrongFront.chord()
check(wrongFront.injector.chords == 0, "wrong OS front posts no shortcut")
let wrongWindow = fresh(focused: false)
wrongWindow.replay([down, left, .text("private"), click])
check(wrongWindow.injector.events.isEmpty, "same PID wrong focused window rejected")
let ambiguous = fresh()
WindowSizer.unique = false
ambiguous.replay([down, click, scroll])
check(ambiguous.injector.events.isEmpty, "ambiguous AX window mapping rejected")
let absent = fresh(front: nil)
absent.immediate(down)
check(absent.injector.events.isEmpty, "unknown OS focus rejected")
let covered = fresh(point: 8)
covered.replay([scroll, click, .pointer(.move, x: 0.5, y: 0.5)])
check(covered.injector.events.isEmpty, "covered point rejects scroll/click/move")
let good = fresh()
good.replay([down, left, .text("fixture"), scroll, click])
check(good.injector.events.count == 5, "verified target accepts queued input")
good.chord()
check(good.injector.chords == 1, "verified target accepts shortcut")
let loss = fresh()
loss.injector.afterApply = { Host.frontPID = 77 }
loss.replay([down, left, .text("later")])
check(loss.injector.events.count == 1, "queue revalidates each event after focus loss")
let release = fresh(front: 77, focused: false, point: 8)
release.injector.owed = true
release.replay([up])
check(release.injector.events == [up] && release.injector.nulls == [true] && !release.injector.owed, "owed key up releases without pointer movement")
release.immediate(up)
check(release.injector.events.count == 1, "unowned key up rejected")
release.injector.owed = true
release.immediate(.pointer(.leftUp, x: 0, y: 0))
check(release.injector.nulls.last == true && !release.injector.owed, "owed button up releases without pointer movement")
let stale = fresh()
stale.validEpoch = false
let epoch = VideoEpoch(generation: "old", id: UUID())
stale.immediate(down, epoch: epoch)
check(stale.injector.events.isEmpty, "stale presentation still rejected")
stale.injector.owed = true
stale.immediate(up, epoch: epoch)
check(stale.injector.events == [up] && stale.injector.nulls == [true], "stale epoch retains owed release")
let none = fresh()
none.active = .none
none.immediate(down)
check(none.injector.events.isEmpty, "missing source rejected")
let desktop = fresh(front: 77, focused: false, point: 8)
desktop.active = .desktop
desktop.immediate(down)
check(desktop.injector.events.count == 1, "desktop retains intentional global input")
let switching = fresh()
switching.switching = true
switching.chord()
check(switching.injector.chords == 0, "shortcut during source switch rejected")
let disconnect = fresh(front: 77)
disconnect.injector.owed = true
disconnect.heldInput = [.input(down, rect, 1, nil), .chord(keyCode: 123, flags: 0), .disconnect(1)]
disconnect.replay([])
check(disconnect.injector.events.isEmpty && disconnect.injector.chords == 0 && disconnect.injector.releases >= 1 && !disconnect.injector.owed, "rejected queue still releases disconnected device")
let dragLoss = fresh(front: 77)
dragLoss.injector.owed = true
dragLoss.immediate(.pointer(.move, x: 0.5, y: 0.5))
check(dragLoss.injector.events.isEmpty && dragLoss.injector.releases == 1 && !dragLoss.injector.owed, "focus loss clears device drag debt before another move")
check(WindowSizer.matchInput() == 99, "one live AX frame and title match accepted")
WindowSizer.candidates = [99, 100]
WindowSizer.frames[100] = rect
check(WindowSizer.matchInput() == nil, "duplicate AX frames and title rejected")
WindowSizer.candidates = [99]
WindowSizer.bounds = nil
check(WindowSizer.matchInput() == nil, "missing live CG bounds rejected")
WindowSizer.bounds = CGRect(x: 500, y: 500, width: 100, height: 100)
check(WindowSizer.matchInput() == nil, "unique title with wrong live bounds rejected")
let began = InputEvent.scrollGesture(.began, x: 0.5, y: 0.5)
let tails: [InputEvent] = [.scrollGesture(.ended, x: 0.5, y: 0.5),
    .scrollGesture(.momentumBegan, x: 0.5, y: 0.5), .scrollGesture(.momentumEnded, x: 0.5, y: 0.5)]
for staged in [false, true] {
    for trigger in [scroll, began] {
        let h = fresh(front: 77, focused: false)
        h.virtualDisplay = staged; h.stage.isStaged = staged
        h.interact(trigger)
        print("TRACE staged=\(staged) trigger=\(trigger) activations=\(h.activations) makeKey=\(WindowSizer.keyRequests) held=\(h.heldInput.count) delivered=\(h.injector.events.count)")
        check(h.activations == [22] && WindowSizer.keyRequests == [99], "inactive selected window requests activation and key focus for \(trigger)")
        check(h.injector.events.isEmpty && h.heldInput.count == 1, "initial scroll held before delivery")
        h.interact(scroll)
        await Task.drain()
        check(h.injector.events == [trigger, scroll], "focused scroll replays once in order")
        check(h.activations.count == 1 && WindowSizer.keyRequests.count == 1, "scroll burst shares activation hold")
    }
    for trigger in [scroll, began, click, down, .text("fixture")] {
        let h = fresh(focused: false)
        h.virtualDisplay = staged; h.stage.isStaged = staged
        h.interact(trigger)
        check(h.activations.isEmpty && WindowSizer.keyRequests == [99], "same PID wrong key window requests makeKey for \(trigger)")
        await Task.drain()
        check(h.injector.events == [trigger], "same PID selected window receives interaction after key focus")
    }
}
let delayedFocus = fresh(focused: false)
delayedFocus.virtualDisplay = true; delayedFocus.stage.isStaged = true
WindowSizer.focusOnRequest = false
delayedFocus.interact(began)
delayedFocus.interact(scroll)
var waits = 0
Clock.onSleep = {
    waits += 1
    if waits == 3 { WindowSizer.focused = true }
}
await Task.drain()
check(waits >= 3 && delayedFocus.injector.events == [began, scroll], "hold waits for keyboard focus readback before replay")
for refusal in ["activation", "key", "cover", "ambiguous"] {
    let h = fresh(front: 77, focused: false, point: refusal == "cover" ? 8 : 7)
    h.virtualDisplay = true; h.stage.isStaged = true
    h.activationAnswered = refusal != "activation"
    WindowSizer.focusOnRequest = refusal != "key"
    WindowSizer.unique = refusal != "ambiguous"
    h.stage.uncover = refusal != "cover"
    h.interact(began); h.interact(scroll)
    let started = Clock.now
    await Task.drain()
    check(h.injector.events.isEmpty && h.heldInput.isEmpty, "\(refusal) refusal never admits scroll at timeout")
    check(Clock.now - started >= Host.activationTimeout, "\(refusal) waits within bounded activation deadline")
    if refusal == "activation" { check(WindowSizer.keyRequests.isEmpty, "unanswered activation skips makeKey") }
}
let tailHost = fresh(front: 77, focused: false)
for event in tails + [up, .pointer(.leftUp, x: 0.5, y: 0.5), .pointer(.move, x: 0.5, y: 0.5)] { tailHost.interact(event) }
check(tailHost.activations.isEmpty && WindowSizer.keyRequests.isEmpty, "end/momentum/up/move never initiate focus")
let readyTail = fresh()
for event in tails { readyTail.interact(event) }
check(readyTail.injector.events == tails && WindowSizer.keyRequests.isEmpty, "ready end/momentum phases preserve order without focus request")
let switchHost = fresh(front: 77, focused: false)
switchHost.switching = true
switchHost.interact(scroll)
check(switchHost.activations.isEmpty && WindowSizer.keyRequests.isEmpty, "source switch cannot activate old window")
let noSource = fresh(front: 77, focused: false)
noSource.active = .none; noSource.interact(scroll)
check(noSource.activations.isEmpty && noSource.injector.events.isEmpty, "no selection cannot focus or scroll")
let staleHeld = fresh(front: 77, focused: false)
staleHeld.interact(scroll, epoch: epoch)
staleHeld.validEpoch = false
staleHeld.injector.owed = true
staleHeld.immediate(up, epoch: epoch)
await Task.drain()
check(staleHeld.injector.events == [up] && staleHeld.injector.nulls == [true], "activation queue retains stale epoch rejection and owed release")
check(Task.pending.isEmpty, "all owned inert activation tasks drained")
if failures > 0 { print("FAIL \(failures) of \(checks) host focus admission checks"); exit(1) }
print("PASS \(checks) host focus admission checks; no app/UI/CGEvent invoked")
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--emit", action="store_true")
    args = parser.parse_args()
    original = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in [HOST, "Sources/SillHost/WindowSizer.swift", "Sources/StreamProtocol/Input.swift"]}
    host = subprocess.check_output(["git", "--no-lazy-fetch", "show", BASE + ":" + HOST], cwd=ROOT, text=True) if args.baseline else (ROOT / HOST).read_text()
    source = program(host, (ROOT / "Sources/StreamProtocol/Input.swift").read_text(), (ROOT / "Sources/SillHost/WindowSizer.swift").read_text())
    if args.emit:
        print(source)
        return 0
    runner = '''import hashlib, subprocess, sys
source = sys.stdin.buffer.read()
print("received_sha256=" + hashlib.sha256(source).hexdigest(), flush=True)
result = subprocess.run(["/usr/bin/swift", "-"], input=source, timeout=170)
del source
print("swift_exit=" + str(result.returncode), flush=True)
print("RAM input released; owned Swift process reaped; no source checkout", flush=True)
raise SystemExit(result.returncode)
'''
    print("sent_sha256=" + hashlib.sha256(source.encode()).hexdigest(), flush=True)
    result = subprocess.run(["/Users/ambrion/.local/bin/mini", "run", "--cwd", "/Users/sin-wonho", "--", "python3", "-B", "-c", runner], input=source, text=True, timeout=180)
    assert all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in original.items()), "source changed"
    print("source_unchanged=" + json.dumps(original, sort_keys=True))
    print("Isolated inert adapter check, not physical input or source-guard transfer acceptance")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
