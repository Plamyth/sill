import Foundation
import CoreGraphics
import StreamProtocol

enum LocalAudioRelayLaunch { static func validateCanonicalHostForInput() -> Bool { true } }
@MainActor final class LocalCursorWindow {
    let frame = CGRect(x: 10, y: 20, width: 1000, height: 500)
    var isLive = true, focused = true
    var checking: (() -> Void)?
    var focusCalls = 0
    func permits(_ event: InputEvent) -> Bool { checking?(); return isLive && focused }
    func focus(authorize: (_ operation: () -> Void) -> Bool) -> Bool {
        authorize { focusCalls += 1; focused = true }
    }
}
@MainActor final class InputInjector {
    typealias PostAuthorization = (_ operation: () -> Void) -> Bool
    var authorization: PostAuthorization?
    var observer: (() -> Void)?
    var posts = 0
    var held = Set<ObjectIdentifier>()
    var cleanup: [ObjectIdentifier] = []
    var downOwners: [ObjectIdentifier] = []
    func releaseInput(of owner: ObjectIdentifier) {
        if held.remove(owner) != nil { cleanup.append(owner); observer?() }
    }
    func trackingPosts(_ body: () -> Void) -> Int {
        let previous = observer; var count = 0
        observer = { count += 1 }; defer { observer = previous }
        body(); return count
    }
    func withAuthorization(_ authorize: @escaping PostAuthorization, _ body: () -> Void) {
        let previous = authorization; authorization = authorize; defer { authorization = previous }; body()
    }
    func apply(_ event: InputEvent, in rect: CGRect, from owner: ObjectIdentifier) {
        let report = observer
        let emit = {
            self.posts += 1; report?()
            switch event {
            case .pointer(.leftDown, _, _): self.held.insert(owner); self.downOwners.append(owner)
            case .pointer(.leftUp, _, _): self.held.remove(owner)
            default: break
            }
        }
        if let authorization {
            let previous = observer; observer = nil; defer { observer = previous }
            _ = authorization(emit)
        } else { emit() }
    }
}
@MainActor final class LocalCursorUnixChannel {
    @MainActor final class Session {
        let id = UUID()
        var isCurrent = true
        var replies: [Data] = []
        weak var owner: LocalCursorUnixChannel?
        func send(_ data: Data) -> Bool { guard isCurrent else { return false }; replies.append(data); return true }
        func close() { guard isCurrent else { return }; isCurrent = false; owner?.onClose(self) }
    }
    static var latest: LocalCursorUnixChannel?
    let canonical: () -> Bool
    let onOpen: (Session) -> Void
    let onRequest: (Data, Session) -> Void
    let onClose: (Session) -> Void
    var sessions: [Session] = []
    init(hostIsCanonical: @escaping () -> Bool, onOpen: @escaping (Session) -> Void,
         onRequest: @escaping (Data, Session) -> Void, onClose: @escaping (Session) -> Void) {
        canonical = hostIsCanonical; self.onOpen = onOpen; self.onRequest = onRequest; self.onClose = onClose
        Self.latest = self
    }
    func start() -> Bool { canonical() }
    func stop() { sessions.forEach { $0.close() } }
    func open() -> Session { let session = Session(); session.owner = self; sessions.append(session); onOpen(session); return session }
}
@MainActor final class Fixture {
    let injector = InputInjector(), window = LocalCursorWindow()
    var remote = false, sentry = false
    var lookups = 0
    var gate: CheckedContinuation<Void, Never>?
    var holdLookup = false
    lazy var broker = LocalCursorInputBroker(injector: injector, window: { [weak self] _ in
        guard let self else { return nil }; self.lookups += 1
        if self.holdLookup { await withCheckedContinuation { self.gate = $0 } }
        return self.window
    }, remoteOwnsInput: { [weak self] in self?.remote ?? true }, sentryProtected: { [weak self] in self?.sentry ?? true }, hostIsCanonical: { true })
    lazy var channel: LocalCursorUnixChannel = { precondition(broker.start()); return LocalCursorUnixChannel.latest! }()
    let captureGeneration = UUID().uuidString, videoEpoch = UUID()
    var capture: [String: Any] { ["pid": 42, "windowID": 99, "captureGeneration": captureGeneration,
        "videoEpoch": videoEpoch.uuidString, "frameWidth": 2000, "frameHeight": 1000] }
    var sequences: [UUID: UInt64] = [:]
    func packet(_ session: LocalCursorUnixChannel.Session, operation: String, fields: [String: Any] = [:]) -> Data {
        let sequence = sequences[session.id] ?? 0; sequences[session.id] = sequence + 1
        var value: [String: Any] = ["schema": 1, "requestID": UUID().uuidString, "sequence": sequence,
            "origin": "ccr-local", "interaction": ["kind": "window-scoped"], "operation": operation]
        if let id = object(session.replies.last)?["connectionID"] { value["connectionID"] = id }
        for (key, field) in fields { value[key] = field }
        return try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    func scope(_ session: LocalCursorUnixChannel.Session) -> [String: Any] {
        let last = session.replies.reversed().compactMap { object($0) }.first { $0["leaseID"] != nil }!
        return ["leaseID": last["leaseID"]!, "leaseGeneration": last["leaseGeneration"]!,
            "captureGeneration": captureGeneration, "videoEpoch": videoEpoch.uuidString]
    }
    func command(_ session: LocalCursorUnixChannel.Session, operation: String, fields: [String: Any] = [:]) async -> [String: Any] {
        await transmit(packet(session, operation: operation, fields: fields), to: session)
    }
    func transmit(_ data: Data, to session: LocalCursorUnixChannel.Session) async -> [String: Any] {
        let count = session.replies.count
        channel.onRequest(data, session)
        await until { session.replies.count > count || !session.isCurrent }
        return object(session.replies.last) ?? [:]
    }
    func bind(_ session: LocalCursorUnixChannel.Session) async -> [String: Any] {
        await command(session, operation: "bindWindow", fields: ["capture": capture, "controlEnabled": true, "ttlMilliseconds": 2000])
    }
    func input(_ session: LocalCursorUnixChannel.Session, event: InputEvent) async -> [String: Any] {
        var fields = scope(session); fields["event"] = try! JSONSerialization.jsonObject(with: Wire.encode(event))
        return await command(session, operation: "input", fields: fields)
    }
    func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        preconditionFailure("비활성 broker 대기 초과")
    }
}
func object(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }; return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
