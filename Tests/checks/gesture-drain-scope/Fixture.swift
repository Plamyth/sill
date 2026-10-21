// 생성된 검사에서만 쓰는 부작용 없는 의존성이다.
@MainActor enum Clock {
    static var now: CFAbsoluteTime = 10000
    static var sleeping: (() -> Void)?
}
@MainActor func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime { Clock.now }
@MainActor final class InertTask {
    static var pending: [InertTask] = []
    static var isCancelled = false
    var cancelled = false
    let operation: @MainActor () async -> Void
    init(operation: @escaping @MainActor () async -> Void) {
        self.operation = operation
        Self.pending.append(self)
    }
    func cancel() { cancelled = true }
    static func sleep(for duration: Duration) async throws {
        Clock.now += 0.02
        Clock.sleeping?()
    }
    static func drain() async {
        while !pending.isEmpty {
            let task = pending.removeFirst()
            isCancelled = task.cancelled
            await task.operation()
            isCancelled = false
        }
    }
}
final class NWConnection {
    enum State { case ready, cancelled, waiting }
    var state = State.ready
    let endpoint = "inert"
}
struct StreamMessage {
    enum Kind { case gesture, other }
    let kind: Kind
    let payload: Data
}
enum KeyStrokes { typealias Device = ObjectIdentifier }
@MainActor struct Stats {
    static let shared = Stats()
    func bump(_ name: String) {}
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
struct CatalogStub { var displayInventory = DisplayInventory(); var activeWindowID: UInt32? }
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
    var heldInput: [Held] = []
    var holdUntil: CFAbsoluteTime = 0
    let injector = Injector()
    var onHotKeys: (() -> Void)?
    func pointerGeometry() -> Int { 0 }
    func menuTargetChanged() {}
    func deviceName(_ connection: NWConnection) -> String { "inert-peer" }
    func hotKeyTable() -> [Int: HotKey] { onHotKeys?(); return GestureChords.defaults }
    func inputTargetReady(_ event: InputEvent) -> Bool { active != .none }
    func presentationInputRect(_ input: SourceInput) -> CGRect? { videoEpoch?.id == input.videoEpoch ? .zero : nil }
    func logClick(_ event: InputEvent, in rect: CGRect) {}
    // PRODUCTION_MEMBERS
    init() {
        catalog.displayInventory.update([
            DisplayInfo(id: 1, name: "inert-1", width: 100, height: 100, isMain: true),
            DisplayInfo(id: 2, name: "inert-2", width: 100, height: 100, isMain: false)
        ], signatures: ["fixture"])
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
    func changeSelection() {
        switching = true
        let current = catalog.displayInventory.current!
        precondition(catalog.displayInventory.select(.init(displayID: 2, inventoryID: current.inventoryID)))
        inputGeneration = UUID().uuidString
        readyEpoch()
        switching = false
    }
}
