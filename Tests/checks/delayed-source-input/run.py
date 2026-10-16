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
         "iOSClient/StreamClient.swift", "Sources/SillHost/PointerControl.swift",
         "Sources/SillHost/SourceInputFence.swift", "Sources/StreamProtocol/Compatibility.swift",
         "Sources/SillHost/StreamServer.swift"]


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
    fenced = bool(sources.get(FILES[6]))
    if fenced:
        token += "\nvar inputFence = SourceInputFence<ObjectIdentifier>()"
    changed = "inputFence.sourceChanged(to: active)" if "inputFence.sourceChanged(to: active)" in host else ""
    selection_guard = host.split("func select(_ source: StreamSource, bringForward: Bool = false) async {", 1)[1].split("        switching = true", 1)[0]
    admission = host.split("server.onClientConnected =", 1)[1].split("let id = ObjectIdentifier(connection)", 1)[1].split("self.routes[id] = route", 1)[0] if fenced else ""
    leave = "self.inputFence.leave(id)" if "self.inputFence.leave(id)" in host else ""
    negotiate = next((line.strip() for line in host.splitlines() if "self.inputFence.negotiate(id," in line), "")
    pending = re.search(r"private var pendingMove: ([^\n]+)", client).group(1)
    send = function(client, "func sendInput(_ event: InputEvent)")
    flush = function(client, "private func flushPendingMove()")
    scoped = "public struct SourceInput" in sources[FILES[0]]
    listing = function(host, "private func listMessage()").replace("private func", "func", 1) if scoped else ""
    protocol = sources[FILES[0]] + sources[FILES[1]].split("/// Binary image payloads:", 1)[0]
    protocol += "\n" + function(sources[FILES[7]], "public struct Hello:")
    protocol += "\n" + sources.get(FILES[6], "").replace("import StreamProtocol", "")
    broadcast = function(sources[FILES[8]], "func broadcast(_ message: StreamMessage)")
    recipients = next(line.strip() for line in broadcast.splitlines() if "for client in clients.values where" in line)
    direct_send = function(sources[FILES[8]], "func send(_ message: StreamMessage, to connection:")
    catalog_sent = next((line.strip() for line in direct_send.splitlines() if "client.catalogSent = true" in line), "")
    server = f'''
final class ServerClient {{
    var connection = NWConnection()
    var catalogSent = false
    var seen: [String] = []
}}
final class BeforeCatalogServer {{
    var clients: [Int: ServerClient] = [:]
    func broadcast(_ label: String) {{ {recipients}\n client.seen.append(label) }} }}
    func sendCatalog(_ label: String, to client: ServerClient) {{
        let message = StreamMessage(kind: .windowList, payload: Data())
        {catalog_sent}
        client.seen.append(label)
    }}
}}
'''
    pointer_control = "enum PointerControl {\n" + function(sources[FILES[5]], "static func movesPointer(_ event:") + "\n" + function(sources[FILES[5]], "static func movesPointer(payload:") + "\n}\n"
    return protocol + '\n' + r'''
import CoreFoundation
import CoreGraphics
import Dispatch
typealias CGWindowID = UInt32
func CACurrentMediaTime() -> Double { 0.004 }
final class NWConnection {
    enum State { case ready }
    var state = State.ready
    var cancelled = false
    func cancel() { cancelled = true }
}
enum Kind { case input, windowList }
struct StreamMessage {
    let kind: Kind
    let timestamp: Double
    let isKeyframe: Bool
    let payload: Data
    init(kind: Kind = .input, timestamp: Double = 0, isKeyframe: Bool = false, payload: Data) {
        self.kind = kind; self.timestamp = timestamp; self.isKeyframe = isKeyframe; self.payload = payload
    }
}
enum SillProtocol { static let current = 1 }
enum TrackpadGesture { static let generation = 1 }
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
''' + f"var pendingMove: {pending}\n{send}\n{flush}\n}}\n" + pointer_control + server + r'''
let aRect = CGRect(x: 100, y: 200, width: 400, height: 200)
let bRect = CGRect(x: 1000, y: 800, width: 800, height: 600)
let bounds: [UInt32: CGRect] = [1: aRect, 2: bRect]
struct Window { let frame: CGRect }
final class Catalog {
    var infos: [WindowInfo] = []
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
    let macName = "isolated"
    let launchID = "isolated-launch"
    let hostVersion: String? = nil
''' + token + f"\nvar active: StreamSource = .window(1) {{ didSet {{ {rotation.group(0) if rotation else ''}\n{changed} }} }}\n" + f'''
    var admitted: Set<ObjectIdentifier> = []
    func admit(_ connection: NWConnection) {{
        let id = ObjectIdentifier(connection)
        {admission}
        admitted.insert(id)
    }}
    func join(_ connection: NWConnection) -> Bool {{ admit(connection); return admitted.contains(ObjectIdentifier(connection)) }}
    func leave(_ connection: NWConnection) {{
        let id = ObjectIdentifier(connection)
        {leave}
        admitted.remove(id)
    }}
    func hello(_ connection: NWConnection, _ hello: Hello) {{ let id = ObjectIdentifier(connection); {negotiate} }}
    func select(_ source: StreamSource) {{ {selection_guard}\n active = source }}
''' + r'''
    var switching = false
    var shuttingDown = false
    func broadcastList() {}
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
''' + route + "\n}\n" + rect + "\n" + listing + r'''
}
var failures = 0
var checks = 0
func check(_ ok: Bool, _ message: String) {
    checks += 1
    if !ok { failures += 1; print("FAIL: \(message)") }
}
let delayedClient = NWConnection()
func packet(_ event: InputEvent, generation: String? = "epoch-A") -> Data {
    let client = Client()
    client.inputGeneration = generation
    client.sendInput(event)
    client.queue.drain(); client.queue.flush()
    return client.sent.last!
}
let click = InputEvent.pointer(.leftDown, x: 0.25, y: 0.75)
let delayed = packet(click)
let h = Host()
check(h.join(delayedClient), "initial peer admitted")
h.receive(delayed, from: delayedClient)
check(h.injector.points == [CGPoint(x: 200, y: 350)], "unchanged source: expected A (200,350), got \(h.injector.points)")
h.injector = Injector(); h.raised = 0; h.desktopActivations = 0
h.active = .window(2)
h.receive(delayed, from: delayedClient)
print("TRACE A→B delayed click: points=\(h.injector.points), raises=\(h.raised)")
check(h.injector.events.isEmpty && h.raised == 0 && h.desktopActivations == 0,
      "delayed A click must not hit B (1200,1250) or activate B; got \(h.injector.points), raises=\(h.raised)")
''' + (r'''
let freshB = packet(click, generation: h.inputGeneration)
h.receive(freshB, from: delayedClient)
check(h.injector.points == [CGPoint(x: 1200, y: 1250)], "fresh B click must land on B")
h.active = .window(1)
h.injector = Injector(); h.raised = 0; h.desktopActivations = 0
h.receive(delayed, from: delayedClient)
check(h.injector.events.isEmpty && h.raised == 0, "A→B→A rejects old A generation")
let kinds: [InputEvent] = [click, .pointer(.move, x: 0.25, y: 0.75),
    .scroll(x: 0.25, y: 0.75, dx: 0.1, dy: 0.2), .scrollGesture(.began, x: 0.25, y: 0.75),
    .text("x"), .key(hidUsage: 4, down: true, modifiers: 0)]
for event in kinds {
    h.injector = Injector(); h.raised = 0
    h.receive(packet(event), from: delayedClient)
    check(h.injector.events.isEmpty && h.raised == 0, "stale event rejected: \(event)")
    h.receive(packet(event, generation: h.inputGeneration), from: delayedClient)
    check(h.injector.events == [event], "fresh event delivered: \(event)")
    check(PointerControl.movesPointer(payload: packet(event)) == PointerControl.movesPointer(event),
          "scoped input preserves pointer ownership classification: \(event)")
    check(PointerControl.movesPointer(payload: Wire.encode(event)) == PointerControl.movesPointer(event),
          "legacy input preserves pointer ownership classification: \(event)")
}
h.injector = Injector(); h.raised = 0
h.receive(Wire.encode(click), from: delayedClient)
check(h.injector.events.isEmpty && h.raised == 0, "scoped connection cannot downgrade to raw input")
h.receive(Data("{invalid".utf8), from: delayedClient)
check(h.injector.events.isEmpty, "malformed input dropped")
let ups: [InputEvent] = [.pointer(.leftUp, x: 0.25, y: 0.75),
    .pointer(.rightUp, x: 0.25, y: 0.75), .key(hidUsage: 4, down: false, modifiers: 0)]
for event in ups {
    h.injector = Injector(); h.raised = 0
    h.receive(packet(event), from: delayedClient)
    check(h.injector.events.isEmpty, "unowned stale up rejected: \(event)")
    h.injector.owedUp = true
    h.receive(packet(event), from: delayedClient)
    check(h.injector.events == [event] && h.injector.nulls == [true] && h.raised == 0,
          "owed stale up delivered at null rect without activation: \(event)")
}
h.switching = true
h.injector = Injector(); h.raised = 0
h.receive(packet(click, generation: h.inputGeneration), from: delayedClient)
check(h.injector.events.isEmpty && h.raised == 0, "no input during async source switch")
h.injector.owedUp = true
h.receive(packet(ups[0], generation: h.inputGeneration), from: delayedClient)
check(h.injector.nulls == [true], "owed up during switch uses null rect")
h.switching = false
let sameGeneration = h.inputGeneration
h.active = .window(1)
check(h.inputGeneration == sameGeneration, "same source keeps generation for live geometry")
h.injector = Injector()
h.rectCache = (1, CGRect(x: 300, y: 400, width: 800, height: 400), CFAbsoluteTimeGetCurrent())
h.receive(packet(click, generation: h.inputGeneration), from: delayedClient)
check(h.injector.points == [CGPoint(x: 500, y: 700)], "same source still follows current geometry")
h.active = .none
h.injector = Injector()
h.receive(packet(click, generation: h.inputGeneration), from: delayedClient)
check(h.injector.events.isEmpty, "no source drops even matching generation")
h.injector.owedUp = true
h.receive(Wire.encode(ups[0]), from: delayedClient)
check(h.injector.nulls == [true], "legacy owed up with no source still releases")
h.active = .desktop; h.injector = Injector()
h.receive(packet(click, generation: h.inputGeneration), from: delayedClient)
check(h.injector.points == [CGPoint(x: 500, y: 1050)], "fresh desktop input maps to display")
h.active = .window(2)
let listed = Wire.decode(WindowList.self, from: h.listMessage().payload)!
check(listed.inputGeneration == h.inputGeneration && listed.active == h.active, "actual catalog publishes source generation")
let oldCatalog = WindowList(macName: "old", windows: [], active: .window(1))
check(Wire.decode(WindowList.self, from: Wire.encode(oldCatalog))?.inputGeneration == nil,
      "old catalogs decode without generation")
check(Wire.decode(InputEvent.self, from: packet(click, generation: nil)) == click,
      "new client uses original payload with old host")
let queued = Client()
queued.sendInput(click)
queued.inputGeneration = h.inputGeneration
queued.queue.drain()
check(Wire.decode(SourceInput.self, from: queued.sent[0])?.generation == "epoch-A",
      "event generation captured before network queue")
let coalesced = Client()
coalesced.sendInput(.pointer(.move, x: 0.25, y: 0.75))
coalesced.queue.drain()
check(coalesced.sent.isEmpty, "move actually waits in coalescer")
coalesced.inputGeneration = h.inputGeneration
coalesced.queue.flush()
check(Wire.decode(SourceInput.self, from: coalesced.sent[0])?.generation == "epoch-A",
      "coalesced move retains creation generation")
h.injector = Injector(); h.raised = 0
h.receive(coalesced.sent[0], from: delayedClient)
check(h.injector.events.isEmpty && h.raised == 0, "delayed coalesced move cannot target B")
let immediate = Client()
immediate.lastMoveAt = -1
immediate.sendInput(.pointer(.move, x: 0.25, y: 0.75))
immediate.inputGeneration = h.inputGeneration
immediate.queue.drain()
check(Wire.decode(SourceInput.self, from: immediate.sent[0])?.generation == "epoch-A",
      "immediate move retains creation generation")
let ordered = Client()
ordered.sendInput(.pointer(.move, x: 0.25, y: 0.75)); ordered.queue.drain()
ordered.inputGeneration = h.inputGeneration
ordered.sendInput(.text("new source")); ordered.queue.drain(); ordered.queue.flush()
check(ordered.sent.count == 2, "non-move flushes pending move exactly once")
check(Wire.decode(SourceInput.self, from: ordered.sent[0])?.generation == "epoch-A" &&
      Wire.decode(SourceInput.self, from: ordered.sent[1])?.generation == h.inputGeneration,
      "flush preserves each event's generation and order")
h.injector = Injector()
ordered.sent.forEach { h.receive($0, from: delayedClient) }
check(h.injector.events == [.text("new source")], "host drops old move and delivers fresh text")
let old = Host()
let oldConnection = NWConnection()
check(old.join(oldConnection), "legacy peer joins without hello")
let rawClick = Wire.encode(click)
old.receive(rawClick, from: oldConnection)
check(old.injector.points == [CGPoint(x: 200, y: 350)], "legacy ordinary click remains functional on A")
let rawKinds: [InputEvent] = [.text("legacy"), .key(hidUsage: 4, down: true, modifiers: 0),
    .scroll(x: 0.25, y: 0.75, dx: 0.1, dy: 0.2), .scrollGesture(.began, x: 0.25, y: 0.75)]
old.injector = Injector()
rawKinds.forEach { old.receive(Wire.encode($0), from: oldConnection) }
check(old.injector.events == rawKinds, "legacy text, key, scroll and gesture-phase remain functional")
old.injector = Injector(); old.raised = 0
old.select(.window(2))
old.receive(rawClick, from: oldConnection)
print("TRACE legacy delayed A→B attempt: active=\(old.active), points=\(old.injector.points)")
check(old.active == .window(1) && old.injector.points == [CGPoint(x: 200, y: 350)],
      "legacy delayed A click remains on A while another client requests B")
old.select(.none); old.select(.window(2))
check(old.active == .none, "source loss does not release legacy source pin")
old.injector = Injector()
old.receive(rawClick, from: oldConnection)
check(old.injector.events.isEmpty, "legacy input with no source is dropped")
old.select(.window(1)); old.injector = Injector()
old.receive(rawClick, from: oldConnection)
check(old.injector.points == [CGPoint(x: 200, y: 350)], "legacy resumes on same source")
old.leave(oldConnection); old.select(.window(2)); old.injector = Injector(); old.injector.owedUp = true
old.receive(rawClick, from: oldConnection)
old.receive(Wire.encode(ups[0]), from: oldConnection)
check(old.active == .window(2) && old.injector.events.isEmpty,
      "disconnected legacy peer cannot inject delayed click or up after B selection")
''' + (r'''
let mixed = Host()
let legacy1 = NWConnection(), legacy2 = NWConnection(), modern = NWConnection()
check(mixed.join(legacy1) && mixed.join(legacy2) && mixed.join(modern), "mixed peers admitted")
mixed.hello(modern, Hello(sourceInput: 1))
mixed.select(.window(2))
check(mixed.active == .window(1), "modern peer cannot override legacy pin")
mixed.leave(legacy1); mixed.select(.window(2))
check(mixed.active == .window(1), "one remaining legacy peer retains pin")
mixed.hello(legacy2, Hello(sourceInput: 2)); mixed.select(.window(2))
check(mixed.active == .window(1), "unknown capability does not release pin")
mixed.hello(legacy2, Hello(sourceInput: 1)); mixed.select(.window(2))
check(mixed.active == .window(2), "all capable peers release source pin")
mixed.hello(legacy2, Hello()); mixed.injector = Injector()
mixed.receive(rawClick, from: legacy2)
check(mixed.injector.events.isEmpty, "capability cannot downgrade by missing hello flag")
mixed.receive(packet(click, generation: mixed.inputGeneration), from: legacy2)
check(mixed.injector.points == [CGPoint(x: 1200, y: 1250)], "negotiated peer uses generation fence on B")
let entering = NWConnection()
mixed.switching = true
check(!mixed.join(entering), "joining during switch refused before old catalog can be sent")
check(entering.cancelled, "actual admission path cancels joining connection during switch")
mixed.switching = false; mixed.injector = Injector(); mixed.injector.owedUp = true
mixed.receive(rawClick, from: entering)
mixed.receive(Wire.encode(ups[0]), from: entering)
check(mixed.injector.events.isEmpty, "unadmitted peer cannot inject input or releases")
check(mixed.join(entering), "peer reconnects after switch settles")
mixed.receive(rawClick, from: entering)
check(mixed.injector.points == [CGPoint(x: 1200, y: 1250)], "reconnected legacy peer functions on settled B")
mixed.select(.window(1))
check(mixed.active == .window(2), "reconnected legacy peer pins B")
let initial = Host(), first = NWConnection()
initial.active = .none
check(initial.join(first), "legacy peer joins idle host")
initial.select(.desktop); initial.select(.window(2))
check(initial.active == .desktop, "first source selection binds idle legacy connection")
initial.injector = Injector()
initial.receive(rawClick, from: first)
check(initial.injector.points == [CGPoint(x: 500, y: 1050)], "idle legacy client can start and control desktop")
let proof = Host(), candidateClient = NWConnection()
check(proof.join(candidateClient), "first scoped candidate without capability admitted")
proof.receive(packet(click), from: candidateClient)
proof.select(.window(2))
check(proof.active == .window(2), "valid scoped packet also negotiates prior candidate")
check(Wire.decode(Hello.self, from: Data("{}".utf8))?.sourceInput == nil,
      "legacy hello remains decodable")
check(Wire.decode(Hello.self, from: Wire.encode(Hello(sourceInput: 1)))?.sourceInput == 1,
      "capability round trips without protocol floor change")
let admissionServer = BeforeCatalogServer(), pendingClient = ServerClient()
admissionServer.clients[0] = pendingClient
admissionServer.broadcast("old-A-catalog")
admissionServer.broadcast("old-A-frame")
check(pendingClient.seen.isEmpty, "pre-admission connection cannot receive old A catalog or frame")
let settled = Host()
settled.select(.window(2))
check(settled.join(pendingClient.connection), "delayed coordinator admission enrolls settled B")
admissionServer.sendCatalog("B-catalog", to: pendingClient)
admissionServer.broadcast("B-frame")
check(pendingClient.seen == ["B-catalog", "B-frame"], "first admitted catalog precedes broadcast frames")
settled.receive(rawClick, from: pendingClient.connection)
check(settled.injector.points == [CGPoint(x: 1200, y: 1250)], "new legacy peer has only seen B and controls B")
''' if fenced else '') + r'''
''' if scoped else '') + r'''
print("\(checks - failures)/\(checks) checks passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emit-swift", action="store_true")
    parser.add_argument("--ref", help="read exact committed sources without switching the worktree")
    parser.add_argument("--mutant", choices=["unguarded-generation", "no-generation-rotation", "late-client-stamp", "ignore-switching", "no-legacy-pin", "no-membership", "pre-catalog-broadcast"])
    args = parser.parse_args()
    disk_before = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in FILES}
    if args.ref:
        commit = subprocess.check_output(["git", "rev-parse", "--verify", args.ref + "^{commit}"], cwd=ROOT, text=True).strip()
        present = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", commit, "--", *FILES], cwd=ROOT, text=True).splitlines()
        sources = {p: subprocess.check_output(["git", "show", commit + ":" + p], cwd=ROOT, text=True) for p in present}
    else:
        sources = {p: (ROOT / p).read_text() for p in FILES}
    original = dict(sources)
    if args.mutant:
        mutations = {
            "unguarded-generation": (FILES[6], "guard generation == current else { return false }", ""),
            "no-generation-rotation": (FILES[2], "if active != oldValue { inputGeneration = UUID().uuidString }", ""),
            "late-client-stamp": (FILES[4], "        let payload = SourceInput.payload(event, generation: inputGeneration)\n", ""),
            "ignore-switching": (FILES[2], "guard !switching, inputFence.accepts", "guard inputFence.accepts"),
            "no-legacy-pin": (FILES[6], "return source == .none || source == pinnedSource", "return true"),
            "no-membership": (FILES[2], "guard inputFence.contains(device) else { return }", ""),
            "pre-catalog-broadcast": (FILES[8], "for client in clients.values where client.catalogSent && client.connection.state == .ready", "for client in clients.values where client.connection.state == .ready"),
        }
        path, old, new = mutations[args.mutant]
        if sources[path].count(old) != 1:
            raise SystemExit("mutation selector not unique")
        sources[path] = sources[path].replace(old, new)
        if args.mutant == "late-client-stamp":
            old = "            self.pointerNoteSent(event)"
            sources[FILES[4]] = sources[FILES[4]].replace(old, old + "\n            let payload = SourceInput.payload(event, generation: self.inputGeneration)")
    script = program(sources)
    if args.emit_swift:
        print(script)
        return 0
    before = {p: hashlib.sha256(s.encode()).hexdigest() for p, s in original.items()}
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
    if disk_before != after:
        raise SystemExit("FAIL: source changed during isolated check")
    print("source_sha256=" + json.dumps(before, sort_keys=True))
    print("MacBook source unchanged; isolated streamed Swift check, not source-guard transfer acceptance")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
