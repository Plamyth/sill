@MainActor enum Clock {
    static var now: CFAbsoluteTime = 10000
    static var sleeping: (() async -> Void)?
}
@MainActor func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime { Clock.now }
@MainActor final class InertTask {
    static var pending: [InertTask] = []
    static var current: InertTask?
    static var isCancelled: Bool { Task.isCancelled || current?.cancelled == true }
    var cancelled = false
    let operation: @MainActor () async -> Void
    init(operation: @escaping @MainActor () async -> Void) {
        self.operation = operation
        Self.pending.append(self)
    }
    func cancel() { cancelled = true }
    static func sleep(for duration: Duration) async throws {
        Clock.now += 0.02
        await Clock.sleeping?()
    }
    static func drain() async {
        while !pending.isEmpty {
            let task = pending.removeFirst()
            current = task
            await task.operation()
            current = nil
        }
    }
}
final class NWConnection {
    enum State { case ready, cancelled, waiting }
    var state = State.ready
    let endpoint = "inert"
}
struct StreamMessage {
    enum Kind { case gesture, selectSource, selectDisplay, other }
    let kind: Kind
    let payload: Data
}
enum KeyStrokes { typealias Device = ObjectIdentifier }
@MainActor struct Stats {
    static let shared = Stats()
    static var counters: [String: Int] = [:]
    func bump(_ name: String) { Self.counters[name, default: 0] += 1 }
}
final class RefusalSummary {
    init(queue: DispatchQueue, categories: [String], line: @escaping ([String: Int]) -> String) {}
    func count(_ category: String) {}
}
final class MicrophoneStub {
    func revoke() {}
    func revoke(reason: String) {}
    func forgetCapabilities() {}
}
struct StatusSnapshot { var stream: Int? }
final class StatusStub { func update(_ body: (inout StatusSnapshot) -> Void) { var s = StatusSnapshot(); body(&s) } }
final class ServerStub { func setStreaming(_ value: Bool) {} }
final class CursorStub { var running = false }
final class PointerStub { func setGeometry(_ geometry: Int, fps: Int) {} }
@MainActor final class CatalogStub {
    var displayInventory = DisplayInventory()
    var activeWindowID: UInt32?
    var clientCount = 1
    var refresh: (() async -> Bool)?
    func refreshWindows() async -> Bool { await refresh?() ?? true }
    func selectDisplay(_ selection: DisplaySelection) -> Bool { displayInventory.select(selection) }
}
@MainActor final class SelectionGate {
    private var suspended: CheckedContinuation<Bool, Never>?
    private(set) var entered = false
    func wait() async -> Bool {
        await withCheckedContinuation { suspended = $0; entered = true }
    }
    func release(_ success: Bool = true) {
        let continuation = suspended
        suspended = nil
        continuation?.resume(returning: success)
    }
}
@MainActor final class Injector {
    var trace: [String] = []
    var targets: [StreamSource] = []
    var target: () -> StreamSource = { .none }
    var afterApply: (() -> Void)?
    var owed = Set<ObjectIdentifier>()
    func chord(keyCode: UInt16, flags: UInt64) {
        trace.append("chord:\(keyCode)")
        targets.append(target())
    }
    func isUpOfSomethingDown(_ event: InputEvent, from device: ObjectIdentifier) -> Bool {
        if case .key(_, false, _) = event { return owed.contains(device) }
        return false
    }
    func apply(_ event: InputEvent, in rect: CGRect, from device: ObjectIdentifier) {
        if case .key(_, false, _) = event {
            trace.append(rect.isNull ? "up:null" : "up")
            owed.remove(device)
        } else { trace.append("input") }
        afterApply?()
    }
    func releaseInput(of device: ObjectIdentifier) { trace.append("disconnect"); owed.remove(device) }
}
@MainActor final class Harness {
    let microphoneIngress = MicrophoneStub()
    let microphoneReceiver = MicrophoneStub()
    var inputFence = SourceInputFence<ObjectIdentifier>()
    var desktopScope: String? { DisplayInventory.scope(catalog.displayInventory.current) }
    var catalog = CatalogStub()
    let status = StatusStub()
    let server = ServerStub()
    let cursorShapes = CursorStub()
    let pointer = PointerStub()
    let fps = 60
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var shuttingDown = false
    var gesturesDry = false
    let synthetic: Bool
    var beforePipelineCommit: (() async -> Void)?
    var afterPipelineCommit: (() async -> Void)?
    var failPipeline = false
    var viewportArrivedWhileSwitching = false
    var heldInput: [Held] = []
    var holdUntil: CFAbsoluteTime = 0
    let injector = Injector()
    var onHotKeys: (() -> Void)?
    func pointerGeometry() -> Int { 0 }
    func menuTargetChanged() {}
    func broadcastList() {}
    func deviceName(_ connection: NWConnection) -> String { "inert-peer" }
    func hotKeyTable() -> [Int: HotKey] { onHotKeys?(); return GestureChords.defaults }
    func inputTargetReady(_ event: InputEvent) -> Bool { active != .none }
    func presentationInputRect(_ input: SourceInput) -> CGRect? { videoEpoch?.id == input.videoEpoch ? .zero : nil }
    func logClick(_ event: InputEvent, in rect: CGRect) {}
    // PRODUCTION_MEMBERS
    init(synthetic: Bool = false, emptyInventory: Bool = false) {
        self.synthetic = synthetic
        gesturesDry = synthetic
        if !emptyInventory {
            catalog.displayInventory.update([
                DisplayInfo(id: 1, name: "inert-1", width: 100, height: 100, isMain: true),
                DisplayInfo(id: 2, name: "inert-2", width: 100, height: 100, isMain: false)
            ], signatures: ["fixture"])
        }
        active = .desktop
        readyEpoch()
        injector.target = { [weak self] in self?.active ?? .none }
    }
    func readyEpoch() {
        videoEpoch = VideoEpoch(generation: inputGeneration, source: active,
            geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
    }
    func join(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        precondition(inputFence.join(id, source: active, switching: switching, desktopScope: desktopScope))
        inputFence.negotiate(id, supportsScoped: true)
        connections[id] = connection
    }
    func leave(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        inputFence.leave(id)
        connections[id] = nil
    }
    func send(_ name: String = "swipeUp", fingers: Int? = 3, from connection: NWConnection) async {
        await receive(StreamMessage(kind: .gesture, payload: Wire.encode(TrackpadGesture(gesture: name, fingers: fingers))), from: connection)
    }
    func pick(_ source: StreamSource, from connection: NWConnection) async {
        await receive(StreamMessage(kind: .selectSource, payload: Wire.encode(source)), from: connection)
    }
    func pickDisplay(_ id: UInt32, from connection: NWConnection) async {
        let selection = DisplaySelection(displayID: id, inventoryID: catalog.displayInventory.current!.inventoryID)
        await receive(StreamMessage(kind: .selectDisplay, payload: Wire.encode(selection)), from: connection)
    }
    func beginWindowSelection(from connection: NWConnection) async -> (SelectionGate, Task<Void, Never>) {
        active = .window(7)
        readyEpoch()
        let gate = SelectionGate()
        catalog.refresh = { await gate.wait() }
        let task = Task { await self.pick(.desktop, from: connection) }
        while !gate.entered { await Task.yield() }
        return (gate, task)
    }
    func changeSelection() {
        switching = true
        let current = catalog.displayInventory.current!
        precondition(catalog.displayInventory.select(.init(displayID: 2, inventoryID: current.inventoryID)))
        inputGeneration = UUID().uuidString
        readyEpoch()
        switching = false
    }
}
