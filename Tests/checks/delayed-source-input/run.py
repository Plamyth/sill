#!/usr/bin/env python3
"""Run extracted Swift input paths with inert dependencies, without building or opening Sill."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
FILES = ["Sources/StreamProtocol/Input.swift", "Sources/StreamProtocol/Switcher.swift",
         "Sources/SillHost/StreamCoordinator.swift", "Sources/SillHost/InputInjector.swift",
         "iOSClient/StreamClient.swift"]


def function(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


def program(sources):
    host = sources[FILES[2]]
    client = sources[FILES[4]]
    route = host.split("        case .input:\n", 1)[1].split("        case .gesture:\n", 1)[0]
    point = function(sources[FILES[3]], "private func point(")
    rect = function(host, "private func currentSourceRect()")
    rotation = re.search(r"if active != oldValue \{ inputGeneration = UUID\(\).uuidString \}", host)
    token = "var inputGeneration = \"epoch-A\"" if "private var inputGeneration" in host else ""
    pending = re.search(r"private var pendingMove: ([^\n]+)", client).group(1)
    send = function(client, "func sendInput(_ event: InputEvent)")
    flush = function(client, "private func flushPendingMove()")
    protocol = sources[FILES[0]] + sources[FILES[1]].split("/// Binary image payloads:", 1)[0]
    return protocol + '\n' + r'''
import CoreFoundation
import CoreGraphics
import Dispatch
typealias CGWindowID = UInt32
func CACurrentMediaTime() -> Double { 0.004 }
final class NWConnection {}
struct StreamMessage { let payload: Data }
enum Kind { case input }
final class Queue {
    var ready: [() -> Void] = []
    var later: [() -> Void] = []
    func async(execute: @escaping () -> Void) { ready.append(execute) }
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { later.append(execute) }
    func drain() { let jobs = ready; ready = []; jobs.forEach { $0() } }
    func flush() { let jobs = later; later = []; jobs.forEach { $0() } }
}
final class Client {
    var inputGeneration: String? = "epoch-A"
    var lastInputAt = 0.0
    var queue = Queue()
    var lastMoveAt = 0.0
    var moveFlushScheduled = false
    static let moveInterval = 0.008
    var sent: [Data] = []
    func pointerNoteSent(_ event: InputEvent) {}
    func send(_ kind: Kind, _ data: Data) { sent.append(data) }
''' + f"var pendingMove: {pending}\n{send}\n{flush}\n}}\n" + r'''
let aRect = CGRect(x: 100, y: 200, width: 400, height: 200)
let bRect = CGRect(x: 1000, y: 800, width: 800, height: 600)
let bounds: [UInt32: CGRect] = [1: aRect, 2: bRect]
struct Window { let frame: CGRect }
final class Catalog {
    var display: Window? = Window(frame: CGRect(x: 0, y: 0, width: 2000, height: 1400))
    func window(id: UInt32) -> Window? { bounds[id].map(Window.init) }
}
struct Stage { var isStaged = false; var captureRectOnScreen: CGRect? }
struct Pointer { var hasTestPointer = false }
struct Chords { mutating func input(_ event: InputEvent) {} }
final class Injector {
    var events: [InputEvent] = []
    var points: [CGPoint] = []
    var nulls: [Bool] = []
    var owedUp = false
    func isUpOfSomethingDown(_ event: InputEvent) -> Bool {
        guard owedUp else { return false }
        switch event {
        case .pointer(.leftUp, _, _), .pointer(.rightUp, _, _), .key(_, false, _): return true
        default: return false
        }
    }
    func pointerNow() -> CGPoint { CGPoint(x: 77, y: 88) }
    func apply(_ event: InputEvent, in rect: CGRect) {
        events.append(event); nulls.append(rect.isNull)
        switch event {
        case .pointer(_, let x, let y), .scroll(let x, let y, _, _), .scrollGesture(_, let x, let y):
            points.append(point(x, y, in: rect))
        default: break
        }
    }
''' + point + r'''
}
final class Host {
''' + token + f"\nvar active: StreamSource = .window(1) {{ didSet {{ {rotation.group(0) if rotation else ''} }} }}\n" + r'''
    var switching = false
    var catalog = Catalog()
    var stage = Stage()
    var pointer = Pointer()
    var virtualDisplay = false
    var synthetic = false
    static let testPatternRect = aRect
    var rectCache: (id: UInt32, rect: CGRect, at: Double)?
    var injector = Injector()
    var gestureChords = Chords()
    var raised = 0
    var desktopActivations = 0
    static func liveBounds(of id: UInt32) -> CGRect? { bounds[id] }
    static func gestureInput(_ event: InputEvent) -> InputEvent { event }
    func raiseIfInteracting(_ event: InputEvent) { raised += 1 }
    func desktopInputMayActivate(_ event: InputEvent) { desktopActivations += 1 }
    func deliver(_ event: InputEvent, in rect: CGRect, from device: ObjectIdentifier) {
        injector.apply(event, in: rect)
    }
    func receive(_ data: Data, from connection: NWConnection) {
        let message = StreamMessage(payload: data)
''' + route + "\n}\n" + rect + r'''
}
var failures = 0
var checks = 0
func check(_ ok: Bool, _ message: String) {
    checks += 1
    if !ok { failures += 1; print("FAIL: \(message)") }
}
let delayedClient = NWConnection()
func packet(_ event: InputEvent) -> Data {
    let client = Client()
    client.sendInput(event)
    client.queue.drain(); client.queue.flush()
    return client.sent.last!
}
let click = InputEvent.pointer(.leftDown, x: 0.25, y: 0.75)
let delayed = packet(click)
let h = Host()
h.receive(delayed, from: delayedClient)
check(h.injector.points == [CGPoint(x: 200, y: 350)], "unchanged source: expected A (200,350), got \(h.injector.points)")
h.injector = Injector(); h.raised = 0; h.desktopActivations = 0
h.active = .window(2)
h.receive(delayed, from: delayedClient)
print("TRACE A→B delayed click: points=\(h.injector.points), raises=\(h.raised)")
check(h.injector.events.isEmpty && h.raised == 0 && h.desktopActivations == 0,
      "delayed A click must not hit B (1200,1250) or activate B; got \(h.injector.points), raises=\(h.raised)")
print("\(checks - failures)/\(checks) checks passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emit-swift", action="store_true")
    args = parser.parse_args()
    sources = {p: (ROOT / p).read_text() for p in FILES}
    script = program(sources)
    if args.emit_swift:
        print(script)
        return 0
    before = {p: hashlib.sha256(s.encode()).hexdigest() for p, s in sources.items()}
    census = subprocess.check_output(["ps", "-axo", "comm="], text=True)
    if re.search(r"/(swift-frontend|swiftc|xcodebuild|clang)(?:\s|$)", census):
        raise SystemExit("Compiler job active on MacBook; defer isolated check")
    runner = r'''import hashlib, re, subprocess, sys
source = sys.stdin.buffer.read()
print("received_swift_sha256=" + hashlib.sha256(source).hexdigest(), flush=True)
census = subprocess.check_output(["ps", "-axo", "comm="], text=True)
if re.search(r"/(swift-frontend|swiftc|xcodebuild|clang)(?:\s|$)", census):
    raise SystemExit("Compiler job active on Mac mini; defer isolated check")
result = subprocess.run(["/usr/bin/swift", "-"], input=source, timeout=60)
del source
print("stdin source released; no source checkout or app launched", flush=True)
raise SystemExit(result.returncode)
'''
    print("sent_swift_sha256=" + hashlib.sha256(script.encode()).hexdigest(), flush=True)
    result = subprocess.run([str(Path.home() / ".local/bin/mini"), "run", "--cwd", "/Users/sin-wonho",
                             "--", "python3", "-c", runner], input=script, text=True, timeout=90)
    after = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in FILES}
    if before != after:
        raise SystemExit("FAIL: source changed during isolated check")
    print("source_sha256=" + json.dumps(after, sort_keys=True))
    print("MacBook source unchanged; isolated streamed Swift check, not source-guard transfer acceptance")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
