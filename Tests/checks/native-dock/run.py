#!/usr/bin/env python3
"""Run the production Dock reader against inert Accessibility elements."""
import os
from pathlib import Path
import subprocess
import sys

root, out = map(Path, sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
reader = (root / "Sources/SillHost/RemoteDockReader.swift").read_text()
for name in ["AXIsProcessTrusted", "AXUIElementCreateApplication", "AXUIElementPerformAction",
             "AXUIElementSetMessagingTimeout", "AXUIElementCopyAttributeValue"]:
    reader = reader.replace(name, "Fixture" + name)
reader = reader.replace("AXUIElement", "FixtureElement").replace("NSRunningApplication", "FixtureRunningApplication")
program = r'''
import AppKit
import ApplicationServices
import StreamProtocol
typealias FixtureElement = Int
enum FixtureRunningApplication {
    struct App { let processIdentifier: Int32 = 42 }
    static func runningApplications(withBundleIdentifier: String) -> [App] { [App()] }
}
enum Fixture {
    static var trusted = true
    static var title = "Dock fixture"
    static var actions: [(Int, String)] = []
    static var menuOpen = false
    static var enabled = true
}
func FixtureAXIsProcessTrusted() -> Bool { Fixture.trusted }
func FixtureFixtureElementCreateApplication(_ pid: Int32) -> Int { 0 }
func FixtureFixtureElementSetMessagingTimeout(_ element: Int, _ timeout: Float) {}
func FixtureFixtureElementPerformAction(_ element: Int, _ action: CFString) -> AXError {
    let name = action as String
    Fixture.actions.append((element, name))
    if name == kAXShowMenuAction as String { Fixture.menuOpen = true }
    if name == kAXCancelAction as String { Fixture.menuOpen = false }
    return .success
}
func FixtureFixtureElementCopyAttributeValue(_ element: Int, _ name: CFString, _ result: inout CFTypeRef?) -> AXError {
    let key = name as String
    var value: Any?
    if key == kAXRoleAttribute as String {
        value = [0: "AXApplication", 1: "AXList", 2: "AXDockItem", 3: "AXMenu", 4: "AXMenuItem"][element]
    } else if key == kAXChildrenAttribute as String {
        value = [0: [1], 1: [2], 2: Fixture.menuOpen ? [3] : [], 3: [4], 4: []][element]
    } else if key == kAXTitleAttribute as String {
        value = element == 2 ? Fixture.title : element == 4 ? "열기" : nil
    } else if key == kAXSubroleAttribute as String, element == 2 {
        value = "AXApplicationDockItem"
    } else if key == "AXIsApplicationRunning", element == 2 {
        value = true
    } else if key == kAXEnabledAttribute as String {
        value = Fixture.enabled
    }
    guard let value else { return .noValue }
    result = value as CFTypeRef
    return .success
}
''' + reader + r'''
@main struct Checks {
    @MainActor static func main() throws {
        let reader = RemoteDockReader()
        let ownerObject = NSObject(), otherObject = NSObject()
        let owner = ObjectIdentifier(ownerObject), other = ObjectIdentifier(otherObject)
        let initial = reader.catalog(force: true)
        precondition(initial.items.count == 1 && initial.items[0].running)
        precondition(reader.catalog().version == initial.version)
        let bad = RemoteDockRequest(version: UUID(), itemID: 0, action: .press)
        precondition(reader.perform(bad, owner: owner).note != nil && Fixture.actions.isEmpty)
        let missing = RemoteDockRequest(version: initial.version, itemID: -1, action: .press)
        precondition(reader.perform(missing, owner: owner).note != nil && Fixture.actions.isEmpty)
        let press = RemoteDockRequest(version: initial.version, itemID: 0, action: .press)
        precondition(reader.perform(press, owner: owner).note == nil)
        precondition(Fixture.actions.count == 1 && Fixture.actions[0].0 == 2)
        let menu = reader.perform(RemoteDockRequest(version: initial.version, itemID: 0, action: .menu), owner: owner)
        precondition(menu.menu?.count == 1 && menu.menuID != nil)
        let before = Fixture.actions.count
        let choose = RemoteDockRequest(version: initial.version, itemID: 0, action: .choose,
                                       menuID: menu.menuID, menuItemID: "0", title: "열기")
        precondition(reader.perform(choose, owner: other).note != nil && Fixture.actions.count == before)
        var wrong = choose
        wrong.title = "다른 메뉴"
        precondition(reader.perform(wrong, owner: owner).note != nil && Fixture.actions.count == before)
        Fixture.enabled = false
        precondition(reader.perform(choose, owner: owner).note != nil && Fixture.actions.count == before)
        Fixture.enabled = true
        precondition(reader.perform(choose, owner: owner).note == nil)
        precondition(Fixture.actions.last!.0 == 4)
        _ = reader.perform(RemoteDockRequest(version: initial.version, itemID: 0, action: .menu), owner: owner)
        let menuCount = Fixture.actions.count
        reader.disconnected(other)
        precondition(Fixture.actions.count == menuCount)
        reader.disconnected(owner)
        precondition(Fixture.actions.count == menuCount + 1 && !Fixture.menuOpen)
        Fixture.title = "다른 Dock 항목"
        precondition(reader.perform(press, owner: owner).note != nil)
        Fixture.trusted = false
        precondition(reader.catalog(force: true).note != nil && reader.catalog().items.isEmpty)
        let legacy = try JSONDecoder().decode(WindowList.self, from: Data(#"{"macName":"fixture","windows":[],"active":{"none":{}}}"#.utf8))
        precondition(legacy.dock == nil)
        let old = WindowList(macName: "fixture", windows: [], active: .none, dockApps: [AppInfo(name: "Finder", bundleID: "com.apple.finder")])
        let oldRoundtrip = try JSONDecoder().decode(WindowList.self, from: JSONEncoder().encode(old))
        precondition(oldRoundtrip.dock == nil && oldRoundtrip.dockApps == old.dockApps)
        let withDock = WindowList(macName: "fixture", windows: [], active: .none, dock: initial)
        let decodedDock = try JSONDecoder().decode(WindowList.self, from: JSONEncoder().encode(withDock))
        precondition(decodedDock.dock == initial)
        print("Dock 실제 reader의 격리 AX 경계·메뉴 소유권·대상·버전·권한 거부·구버전 계약 검증 통과")
        print("실제 Dock 조회·액션·앱 실행·오디오·기기 효과 없음")
    }
}
'''
source = out / "main.swift"
source.write_text(program)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
protocol = sorted((root / "Sources/StreamProtocol").glob("*.swift"))
commands = [
    ["/usr/bin/xcrun", "swiftc", "-emit-library", "-emit-module", "-module-name", "StreamProtocol",
     *map(str, protocol), "-emit-module-path", str(out / "StreamProtocol.swiftmodule"), "-o", str(out / "libStreamProtocol.dylib")],
    ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-I", str(out), "-L", str(out), "-lStreamProtocol",
     "-Xlinker", "-rpath", "-Xlinker", str(out), str(source), "-o", str(out / "checks")],
    [str(out / "checks")],
]
for index, command in enumerate(commands):
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=120)
    (out / f"stage-{index}.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        print(result.stdout + result.stderr)
        sys.exit(result.returncode)
print(result.stdout, end="")

host = (root / "Sources/SillHost/StreamCoordinator.swift").read_text()
start = host.index("    private func handleDockRequest(")
end = host.index("{", start) + 1
depth = 1
while depth:
    depth += (host[end] == "{") - (host[end] == "}")
    end += 1
method = host[start:end].replace("private func", "func")
admission = r'''
import Foundation
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
final class Reader {
    var calls = 0
    var note: String?
    var bundle: String? = "fixture.app"
    func applicationBundleID(for request: RemoteDockRequest) -> String? { bundle }
    func perform(_ request: RemoteDockRequest, owner: ObjectIdentifier) -> RemoteDockReply {
        calls += 1
        return RemoteDockReply(requestID: request.requestID, catalog: RemoteDockCatalog(version: request.version, items: []), note: note)
    }
}
final class Server {
    var sent: [StreamMessage] = []
    func send(_ message: StreamMessage, to: NWConnection) { sent.append(message) }
}
final class Catalog {
    var infos = [WindowInfo(id: 7, title: "fixture", appName: "fixture", bundleID: "fixture.app", width: 100, height: 100)]
    var refreshes = 0
    var onRefresh: (() -> Void)?
    func refreshWindows() async -> Bool { refreshes += 1; onRefresh?(); return true }
}
final class Host {
    var inputFence = Fence()
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var routes: [ObjectIdentifier: Route] = [:]
    var remote: Remote? = Remote()
    var synthetic = false, shuttingDown = false, switching = false
    var inputGeneration = "generation"
    var active = StreamSource.desktop
    let nativeDock = Reader(), server = Server(), catalog = Catalog()
    var selections: [StreamSource] = []
    var broadcasts = 0
    func select(_ source: StreamSource, bringForward: Bool) async { selections.append(source) }
    func broadcastList() { broadcasts += 1 }
''' + method + r'''
}
func fixture() -> (Host, NWConnection) {
    let h = Host(), c = NWConnection(), id = ObjectIdentifier(c)
    h.inputFence.members.insert(id); h.connections[id] = c; h.routes[id] = Route()
    return (h, c)
}
@main struct AdmissionChecks {
    static func main() async {
        precondition(StreamMessageKind.dockRequest.rawValue == 215 && StreamMessageKind.dockReply.rawValue == 216)
        precondition(StreamMessageKind(rawValue: 213) == nil && StreamMessageKind(rawValue: 214) == nil)
        precondition(StreamMessage.clientPayloadLimit(for: .dockRequest) == 4096)
        precondition(StreamMessage.clientPayloadLimit(for: .dockReply) == -1)
        precondition(StreamMessage.hostPayloadLimit(for: .dockRequest) == -1)
        let request = RemoteDockRequest(version: UUID(), itemID: 0, action: .press)
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
            await h.handleDockRequest(message, from: c)
            precondition(h.nativeDock.calls == 0 && h.server.sent.isEmpty && h.selections.isEmpty)
        }
        for payload in [Data(repeating: 1, count: 4097), Data("invalid".utf8)] {
            let (h, c) = fixture()
            await h.handleDockRequest(StreamMessage(kind: .dockRequest, timestamp: 1, isKeyframe: false, payload: payload), from: c)
            precondition(h.nativeDock.calls == 0)
        }
        do {
            let (h, c) = fixture()
            await h.handleDockRequest(message, from: c)
            precondition(h.nativeDock.calls == 1 && h.selections == [.window(7)] && h.broadcasts == 1)
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
            await h.handleDockRequest(message, from: c)
            precondition(h.nativeDock.calls == 1 && h.selections.isEmpty)
        }
        do {
            let (h, c) = fixture(); h.nativeDock.note = "거부"
            await h.handleDockRequest(message, from: c)
            precondition(h.catalog.refreshes == 0 && h.selections.isEmpty)
        }
        print("Dock 호스트의 TLS·페어링·입력 사용권·지연 응답·세대 변경 경계 검증 통과")
    }
}
'''
admission_source = out / "admission.swift"
admission_source.write_text(admission)
for index, command in enumerate([
    ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-I", str(out), "-L", str(out), "-lStreamProtocol",
     "-Xlinker", "-rpath", "-Xlinker", str(out), str(admission_source), "-o", str(out / "admission")],
    [str(out / "admission")],
]):
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=120)
    (out / f"admission-{index}.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        print(result.stdout + result.stderr)
        sys.exit(result.returncode)
print(result.stdout, end="")
