#!/usr/bin/env python3
"""Exercise the production Dock reader and host admission using inert adapters."""
import os
from pathlib import Path
import subprocess
import sys

root, out = (Path(p).resolve() for p in sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
libdir = out / "reader"
result = subprocess.run([sys.executable, "-B", str(root / "Tests/checks/native-dock-reader/run.py"),
                         str(root), str(libdir)], env=env, timeout=300)
if result.returncode:
    sys.exit(result.returncode)

host = (root / "Sources/SillHost/StreamCoordinator.swift").read_text()
start = host.index("    private func handleDockRequest(")
end = host.index("{", start) + 1
depth = 1
while depth:
    depth += (host[end] == "{") - (host[end] == "}")
    end += 1
def extract(signature):
    start = host.index("    private func " + signature)
    end = host.index("{", start) + 1
    depth = 1
    while depth:
        depth += (host[end] == "{") - (host[end] == "}")
        end += 1
    return host[start:end].replace("private func", "func")
method = "\n".join(extract(name) for name in ["handleDockRequest(", "dockActionIsCurrent(", "focusedDockSource("])
clock = (root / "Sources/SillHost/DockSelectionIngress.swift").read_text()
handle_start = host.index("    private func handle(_ message:")
handle_end = host.index("        switch message.kind {", handle_start)
handle = host[handle_start:handle_end].replace("private func", "func") + """        switch message.kind {
        case .dockRequest: await handleDockRequest(message, from: connection, selectionTicket: selectionTicket)
        case .selectSource:
            if let source = Wire.decode(StreamSource.self, from: message.payload) { await select(source, bringForward: false) }
        default: break
        }
    }
"""
admission = r'''
import Foundation
import CoreFoundation
import CoreGraphics
import StreamProtocol
final class NWConnection {
    enum State { case ready, cancelled }
    var state = State.ready
}
struct Fence {
    var members: Set<ObjectIdentifier> = []
    func contains(_ id: ObjectIdentifier) -> Bool { members.contains(id) }
}
struct Route { var encrypted = true; var fingerprint: String? = "paired" }
final class Remote { var paired = true; func isPaired(_ key: String) -> Bool { paired && key == "paired" } }
let fixtureVersion = UUID()
final class Reader {
    func catalog(force: Bool = false) -> RemoteDockCatalog { RemoteDockCatalog(version: fixtureVersion, items: [RemoteDockItem(id: 0, title: "fixture", subrole: "app", running: true)]) }
    var calls = 0
    var onPerform: (() -> Void)?
    var note: String?
    var bundle: String? = "fixture.app"
    func applicationBundleID(for request: RemoteDockRequest) -> String? { bundle }
    func perform(_ request: RemoteDockRequest, owner: ObjectIdentifier) -> RemoteDockReply {
        calls += 1; onPerform?()
        return RemoteDockReply(requestID: request.requestID, catalog: RemoteDockCatalog(version: request.version, items: []), note: note)
    }
}
final class Server {
    var sent: [StreamMessage] = []
    func send(_ message: StreamMessage, to: NWConnection) { sent.append(message) }
}
struct FocusApp { let bundleIdentifier: String? = "fixture.app"; let processIdentifier: Int32 = 42 }
struct NSWorkspace { static let shared = NSWorkspace(); var frontmostApplication: FocusApp? { FocusApp() } }
struct WindowCatalog { static func isPrivateApplication(_ id: String) -> Bool { false } }
struct Window { let id: UInt32; var owningApplication: Owner? { Owner() }; struct Owner { let processID: Int32 = 42 } }
struct Sizer { func element(for window: Window, input: Bool) -> UInt32? { window.id } }
typealias AXUIElement = NSNumber
let kAXFocusedWindowAttribute = "focusedWindow", kAXTitleAttribute = "title"
enum AXError { case success }
func AXUIElementCreateApplication(_ pid: Int32) -> AXUIElement { NSNumber(value: pid) }
func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ timeout: Float) {}
func AXUIElementGetTypeID() -> CFTypeID { CFNumberGetTypeID() }
func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ name: CFString, _ result: inout CFTypeRef?) -> AXError {
    result = (name as String) == kAXFocusedWindowAttribute ? NSNumber(value: 123) : "focused" as NSString
    return .success
}
struct WindowSizer {
    static func hasKeyboardFocus(_ element: AXUIElement, pid: Int32) -> Bool { element.intValue == 123 }
    static func frame(of element: AXUIElement) -> CGRect? { CGRect(x: 0, y: 0, width: 100, height: 100) }
}
final class Mic { enum Phase { case off, cleanupFailed }; var phase = Phase.off }
final class Catalog {
    func window(id: UInt32) -> Window? { Window(id: id) }
    var infos = [WindowInfo(id: 7, title: "first", appName: "fixture", bundleID: "fixture.app", width: 100, height: 100), WindowInfo(id: 17, title: "focused", appName: "fixture", bundleID: "fixture.app", width: 100, height: 100)]
    var refreshes = 0
    var onRefresh: (() -> Void)?
    func refreshWindows() async -> Bool { refreshes += 1; onRefresh?(); return true }
}
@MainActor final class Host {
    var pendingLaunch: String?
    let dockSelectionIngress = DockSelectionIngress()
    var dockTransition = false
    var dockGeneration: String?
    var pendingDockSelection: (StreamMessage, NWConnection, UInt64)?
    var dockArrivals: [ObjectIdentifier: [TimeInterval]] = [:]
    let microphoneReceiver = Mic(), sizer = Sizer()
    static func liveBounds(of id: UInt32) -> CGRect? { CGRect(x: 0, y: 0, width: 100, height: 100) }
    var inputFence = Fence()
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var routes: [ObjectIdentifier: Route] = [:]
    var remote: Remote? = Remote()
    var synthetic = false, shuttingDown = false, switching = false
    var inputGeneration = "generation"
    var active = StreamSource.window(7)
    let nativeDock = Reader(), server = Server(), catalog = Catalog()
    var selections: [StreamSource] = []
    var broadcasts = 0
    var onStop: (() -> Void)?
    func select(_ source: StreamSource, bringForward: Bool) async {
        selections.append(source); active = source; inputGeneration = UUID().uuidString
        if source == .none { onStop?() }
    }

    func broadcastList() { broadcasts += 1 }
''' + method + '\n' + handle + r'''
}
@MainActor func fixture() -> (Host, NWConnection) {
    let h = Host(), c = NWConnection(), id = ObjectIdentifier(c)
    h.inputFence.members.insert(id); h.connections[id] = c; h.routes[id] = Route()
    return (h, c)
}
@main struct AdmissionChecks {
    @MainActor static func main() async {
        precondition(StreamMessageKind.dockRequest.rawValue == 215 && StreamMessageKind.dockReply.rawValue == 216)
        precondition(StreamMessageKind(rawValue: 213) == nil && StreamMessageKind(rawValue: 214) == nil)
        precondition(StreamMessage.clientPayloadLimit(for: .dockRequest) == 4096)
        precondition(StreamMessage.clientPayloadLimit(for: .dockReply) == -1)
        precondition(StreamMessage.hostPayloadLimit(for: .dockRequest) == -1)
        let request = RemoteDockRequest(version: fixtureVersion, itemID: 0, action: .press)
        let message = StreamMessage(kind: .dockRequest, timestamp: 1, isKeyframe: false, payload: Wire.encode(request))
        let refusals: [(Host, NWConnection) -> Void] = [
            { h, _ in h.inputFence.members.removeAll() },
            { h, _ in h.connections.removeAll() },
            { _, c in c.state = .cancelled },
            { h, c in h.routes[ObjectIdentifier(c)]?.encrypted = false },
            { h, c in h.routes[ObjectIdentifier(c)]?.fingerprint = nil },
            { h, _ in h.remote?.paired = false },
            { h, _ in h.synthetic = true },
            { h, _ in h.shuttingDown = true },
            { h, _ in h.switching = true }
        ]
        for change in refusals {
            let (h, c) = fixture(); change(h, c)
            await h.handleDockRequest(message, from: c, selectionTicket: h.dockSelectionIngress.reserve(for: message))
            precondition(h.nativeDock.calls == 0 && h.server.sent.isEmpty && h.selections.isEmpty)
        }
        for payload in [Data(repeating: 1, count: 4097), Data("invalid".utf8)] {
            let (h, c) = fixture()
            await h.handleDockRequest(StreamMessage(kind: .dockRequest, timestamp: 1, isKeyframe: false, payload: payload), from: c, selectionTicket: nil)
            precondition(h.nativeDock.calls == 0)
        }
        do {
            let (h, c) = fixture()
            await h.handleDockRequest(message, from: c, selectionTicket: h.dockSelectionIngress.reserve(for: message))
            precondition(h.nativeDock.calls == 1 && h.selections == [.none, .window(17)] && h.broadcasts == 1)
            let reply = Wire.decode(RemoteDockReply.self, from: h.server.sent[0].payload)!
            precondition(reply.requestID == request.requestID)
        }
        for change in [
            { (h: Host) in h.inputFence.members.removeAll() },
            { (h: Host) in h.inputGeneration = "new-generation" },
            { (h: Host) in h.active = .window(19) },
            { (h: Host) in h.switching = true },
            { (h: Host) in h.shuttingDown = true }
        ] {
            let (h, c) = fixture()
            h.catalog.onRefresh = { change(h) }
            await h.handleDockRequest(message, from: c, selectionTicket: h.dockSelectionIngress.reserve(for: message))
            precondition(h.nativeDock.calls == 1 && h.selections == [.none])
        }
        do {
            let (h, c) = fixture(); h.nativeDock.note = "거부"
            await h.handleDockRequest(message, from: c, selectionTicket: h.dockSelectionIngress.reserve(for: message))
            precondition(h.catalog.refreshes == 0 && h.selections == [.none, .window(7)])
        }
        do {
            let (h, c) = fixture()
            h.pendingLaunch = "older.app"
            h.nativeDock.onPerform = {
                precondition(h.active == .none && h.microphoneReceiver.phase == .off && h.pendingLaunch == nil)
            }
            await h.handle(message, from: c, selectionTicket: h.dockSelectionIngress.reserve(for: message))
            precondition(h.nativeDock.calls == 1)
        }
        do {
            let (h, c) = fixture()
            h.microphoneReceiver.phase = .cleanupFailed
            await h.handle(message, from: c, selectionTicket: h.dockSelectionIngress.reserve(for: message))
            precondition(h.nativeDock.calls == 0 && h.selections == [.none] && h.server.sent.count == 1)
        }
        do {
            let (h, c) = fixture()
            let oldTicket = h.dockSelectionIngress.reserve(for: message)
            let newer = StreamMessage(kind: .selectSource, timestamp: 2, isKeyframe: false, payload: Wire.encode(StreamSource.window(19)))
            let newerTicket = h.dockSelectionIngress.reserve(for: newer)
            await h.handle(newer, from: c, selectionTicket: newerTicket)
            await h.handle(message, from: c, selectionTicket: oldTicket)
            precondition(h.nativeDock.calls == 0 && h.selections == [.window(19)])
        }
        do {
            let (h, c) = fixture()
            h.onStop = {
                let newer = StreamMessage(kind: .selectSource, timestamp: 2, isKeyframe: false, payload: Wire.encode(StreamSource.window(19)))
                h.pendingDockSelection = (newer, c, h.dockSelectionIngress.reserve(for: newer)!)
            }
            await h.handle(message, from: c, selectionTicket: h.dockSelectionIngress.reserve(for: message))
            for _ in 0..<20 where h.selections.count < 2 { await Task.yield() }
            precondition(h.nativeDock.calls == 0 && h.selections == [.none, .window(19)])
        }
        print("Dock 호스트의 TLS·페어링·입력 사용권·지연 응답·세대 변경·ingress 순서·기존 마이크 정리 경계 검증 통과")
    }
}
'''
admission_source = out / "admission.swift"
admission_source.write_text(clock + '\n' + admission)
for index, command in enumerate([
    ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-I", str(libdir), "-L", str(libdir), "-lStreamProtocol",
     "-Xlinker", "-rpath", "-Xlinker", str(libdir), str(admission_source), "-o", str(out / "admission")],
    [str(out / "admission")],
]):
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=120)
    (out / f"admission-{index}.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        print(result.stdout + result.stderr)
        sys.exit(result.returncode)
print(result.stdout, end="")
