import Foundation
import Network
import StreamProtocol
@testable import SillHostCore

@MainActor final class ContractCapture: PeerCaptureDriver {
    var onStopped: (() -> Void)?
    var description: PeerCaptureDescription?
    var epoch: VideoEpoch?
    var output: ((StreamMessage, UUID) -> Void)?
    func resolve(source: StreamSource, display: DisplaySelection?, identity: String?, config: HostConfig,
                 viewport: Viewport?) async throws -> PeerCaptureDescription {
        let bounds = Self.bounds(display?.displayID)
        return PeerCaptureDescription(source: source, bounds: bounds,
                               width: Int(bounds.width), height: Int(bounds.height), displayID: display?.displayID,
                               windowPID: nil, title: "격리 화면")
    }
    static func bounds(_ displayID: UInt32?) -> CGRect {
        switch displayID {
        case 1: return CGRect(x: 0, y: 0, width: 1512, height: 982)
        case 2: return CGRect(x: -2560, y: -300, width: 2560, height: 1440)
        case 42: return CGRect(x: 1512, y: 0, width: 1350, height: 890)
        default: return CGRect(x: 1, y: 2, width: 640, height: 480)
        }
    }
    func start(_ description: PeerCaptureDescription, epoch: VideoEpoch,
               output: @escaping (StreamMessage, UUID) -> Void) async throws {
        self.description = description; self.epoch = epoch; self.output = output
    }
    func requestKeyframe() {
        guard let epoch else { return }
        output?(StreamMessage(kind: .parameterSets, timestamp: 0, isKeyframe: true, payload: Data([1,2,3])), epoch.id)
        output?(StreamMessage(kind: .frame, timestamp: 0, isKeyframe: true,
                              payload: Data([0,0,0,3,0x26,1,UInt8(description?.displayID ?? 0)])), epoch.id)
    }
    func stop() async { epoch = nil; output = nil; description = nil }
    func currentBounds() -> CGRect? { description?.bounds }
}

final class Client: @unchecked Sendable {
    let connection: NWConnection
    let queue = DispatchQueue(label: "peer.contract.client")
    private let lock = NSLock()
    private var messages: [StreamMessage] = []
    init(port: UInt16) { connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    var catalogs: [WindowList] { lock.lock(); defer { lock.unlock() }; return messages.filter { $0.kind == .windowList }.compactMap { Wire.decode(WindowList.self, from: $0.payload) } }
    var frames: [UUID] { lock.lock(); defer { lock.unlock() }; return messages.filter { $0.kind == .epochFrame }.compactMap { PresentationMedia.decode($0.payload, kind: $0.kind)?.epoch } }
    var frameDisplays: [UInt8] { lock.lock(); defer { lock.unlock() }; return messages.filter { $0.kind == .epochFrame }.compactMap { PresentationMedia.decode($0.payload, kind: $0.kind)?.media.last } }
    func start() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                if case .ready = state { self.connection.stateUpdateHandler = nil; self.header(); done.resume() }
                else if case .failed(let error) = state { self.connection.stateUpdateHandler = nil; done.resume(throwing: error) }
            }
            connection.start(queue: queue)
        }
        send(.hello, Hello(appVersion: "0.5.1", build: "contract", protocol: 1, device: "isolated peer", sourceInput: 1, presentationInput: 1))
    }
    func send<T: Encodable>(_ kind: StreamMessageKind, _ value: T) {
        let packet = StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: Wire.encode(value))
        connection.send(content: packet.serialized(), completion: .contentProcessed { _ in })
    }
    private func header() {
        connection.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { data, _, ended, error in
            guard let data, let h = StreamMessage.parseHeader(data) else { return }
            self.payload(h)
        }
    }
    private func payload(_ h: StreamHeader) {
        func accept(_ data: Data) {
            self.lock.lock()
            self.messages.append(StreamMessage(kind: h.kind, timestamp: h.timestamp, isKeyframe: h.isKeyframe, payload: data))
            self.lock.unlock()
            self.header()
        }
        if h.payloadLength == 0 { accept(Data()); return }
        connection.receive(minimumIncompleteLength: h.payloadLength, maximumLength: h.payloadLength) { data, _, _, _ in
            guard let data, data.count == h.payloadLength else { return }
            accept(data)
        }
    }
}

@main struct PeerCoordinatorChecks {
    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["SILL_TEST_LOOPBACK"] == "1")
        let host = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        var inventory = DisplayInventory()
        inventory.update([
            DisplayInfo(id: 1, name: "MacBook", width: 1512, height: 982, isMain: true),
            DisplayInfo(id: 2, name: "LG", width: 2560, height: 1440, isMain: false),
            DisplayInfo(id: 42, name: "가상 화면", width: 1350, height: 890, isMain: false)
        ], signatures: ["macbook/rect", "lg/rect", "virtual/rect"])
        var destroyed = 0
        let desktop = ExtendedDesktop(makeDisplay: { _, _ in
            ExtendedDesktop.Resource(id: 42, waitUntilOnline: { true }, configure: {}, isValid: { true },
                recoverWindows: {}, destroy: { destroyed += 1 })
        }, publishID: { _ in }, reportFailure: { _ in preconditionFailure("inert display failed") })
        host.startPeerContract({ ContractCapture() }, inventory: inventory, desktop: desktop)
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            FileHandle.standardError.write(Data("FAIL timeout: \(label)\n".utf8))
            exit(1)
        }
        try await wait("listener") { host.server.port != nil }
        let a = Client(port: host.server.port!), b = Client(port: host.server.port!)
        defer { a.connection.cancel(); b.connection.cancel() }
        try await a.start(); try await b.start()
        try await wait("both peer catalogs") { a.catalogs.last?.independentStreams == 1 && b.catalogs.last?.independentStreams == 1 }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL \(label) after \(checks) passing checks\n".utf8))
                exit(1)
            }
            checks += 1
        }
        check(a.catalogs.last?.sourceSelectionEffects == 0 && b.catalogs.last?.sourceSelectionEffects == 0, "observational capability")
        a.send(.selectSource, SourceRequest(source: .window(10), origin: .human))
        b.send(.selectSource, SourceRequest(source: .window(20), origin: .human))
        try await wait("two independent frames") { a.catalogs.last?.active == .window(10) && b.catalogs.last?.active == .window(20) && !a.frames.isEmpty && !b.frames.isEmpty }
        let ea = a.catalogs.last!.videoEpoch!, eb = b.catalogs.last!.videoEpoch!
        check(ea.id != eb.id && ea.generation != eb.generation, "separate epoch generations")
        check(a.frames.allSatisfy { $0 == ea.id } && b.frames.allSatisfy { $0 == eb.id }, "frames confined to own peer")
        let sameRevision = a.catalogs.last!.selectionRevision, sameFrameCount = a.frames.count
        a.send(.selectSource, SourceRequest(source: .window(10), origin: .human))
        try await wait("same-source processed intent") { a.catalogs.last?.selectionRevision != sameRevision && a.frames.count > sameFrameCount }
        check(a.catalogs.last?.videoEpoch == ea && b.catalogs.last?.videoEpoch == eb, "same-source fresh intent reply preserves both peers video epochs")
        check(a.frames.last == ea.id, "same-source request produces a fresh keyframe on the existing epoch")
        a.send(.input, SourceInput(event: .text("A"), generation: ea.generation, videoEpoch: ea.id))
        b.send(.input, SourceInput(event: .text("B"), generation: eb.generation, videoEpoch: eb.id))
        try await wait("own input admitted") { host.contractPeerInputs.count == 2 }
        check(Set(host.contractPeerInputs) == Set([StreamSource.window(10), .window(20)]), "input uses requesting peer source")
        b.send(.input, SourceInput(event: .text("foreign"), generation: ea.generation, videoEpoch: ea.id))
        a.send(.selectSource, SourceRequest(source: .window(11), origin: .human))
        try await wait("A source changes") { a.catalogs.last?.active == .window(11) && a.catalogs.last?.videoEpoch != nil }
        check(b.catalogs.last?.videoEpoch == eb && b.catalogs.last?.active == .window(20), "A selection does not change B catalog or capture")
        let next = a.catalogs.last!.videoEpoch!
        a.send(.input, SourceInput(event: .text("stale"), generation: ea.generation, videoEpoch: ea.id))
        a.send(.input, SourceInput(event: .text("new"), generation: next.generation, videoEpoch: next.id))
        try await wait("new input admitted") { host.contractPeerInputEvents.last == .text("new") }
        check(Set(host.contractPeerInputs.prefix(2)) == Set([StreamSource.window(10), .window(20)]) && host.contractPeerInputs.count == 3 && host.contractPeerInputs.last == .window(11), "foreign and stale input dropped")
        func select(_ client: Client, _ display: UInt32) {
            client.send(.selectDisplay, DisplaySelection(displayID: display, inventoryID: inventory.revision!, origin: .human))
        }
        select(a, 1); select(b, 2)
        try await wait("two physical displays") {
            a.catalogs.last?.activeDisplayID == 1 && b.catalogs.last?.activeDisplayID == 2 &&
            a.frames.last == a.catalogs.last?.videoEpoch?.id && b.frames.last == b.catalogs.last?.videoEpoch?.id
        }
        let mac = a.catalogs.last!.videoEpoch!, lg = b.catalogs.last!.videoEpoch!
        check(mac.id != lg.id && mac.generation != lg.generation, "physical displays have independent frame epochs")
        check(a.frameDisplays.last == 1 && b.frameDisplays.last == 2, "different capture content reaches only its selected monitor")
        a.send(.input, SourceInput(event: .pointer(.leftDown, x: 0.5, y: 0.5), generation: mac.generation, videoEpoch: mac.id))
        b.send(.input, SourceInput(event: .pointer(.leftDown, x: 0.5, y: 0.5), generation: lg.generation, videoEpoch: lg.id))
        let physicalInputs = host.contractPeerInputs.count + 2
        try await wait("per-display input rectangles") { host.contractPeerInputs.count == physicalInputs }
        check(host.contractPeerInputRects.suffix(2).contains(ContractCapture.bounds(1)) &&
              host.contractPeerInputRects.suffix(2).contains(ContractCapture.bounds(2)),
              "each connection maps normalized input into its own offset physical monitor bounds")
        a.send(.viewport, Viewport(width: 400, height: 900, scale: 2, fps: 30))
        try await wait("A viewport restarts only A") { a.catalogs.last?.videoEpoch?.id != mac.id && a.catalogs.last?.videoEpoch != nil }
        check(b.catalogs.last?.videoEpoch == lg && b.frameDisplays.last == 2, "A viewport cannot replace B capture or geometry")
        host.contractRequestExtendedDesktop(epoch: a.catalogs.last!.videoEpoch!.id,
                                            viewport: Viewport(width: 1350, height: 890, scale: 2))
        try await wait("inert virtual display ready") { desktop.displayID == 42 }
        select(b, 42)
        try await wait("B captures A owned virtual display") {
            b.catalogs.last?.activeDisplayID == 42 && b.frames.last == b.catalogs.last?.videoEpoch?.id
        }
        let virtual = b.catalogs.last!.videoEpoch!
        check(b.frameDisplays.last == 42, "virtual display supplies its own capture content")
        a.connection.cancel()
        try await wait("A disconnect processed") { desktop.requesters.isEmpty }
        check(desktop.displayID == 42 && destroyed == 0, "A disconnect preserves a virtual display still captured by B")
        b.send(.input, SourceInput(event: .text("virtual retained"), generation: virtual.generation, videoEpoch: virtual.id))
        let retainedInputs = host.contractPeerInputs.count + 1
        try await wait("B retained virtual input") { host.contractPeerInputs.count == retainedInputs }
        check(host.contractPeerInputRects.last == ContractCapture.bounds(42) && b.catalogs.last?.videoEpoch == virtual,
              "B virtual epoch and input coordinates survive A disconnect")
        let reconnected = Client(port: host.server.port!)
        defer { reconnected.connection.cancel() }
        try await reconnected.start()
        try await wait("reconnect starts with its own idle scope") { reconnected.catalogs.last?.independentStreams == 1 }
        check(reconnected.catalogs.last?.active == StreamSource.none && reconnected.catalogs.last?.videoEpoch == nil &&
              b.catalogs.last?.videoEpoch == virtual, "new connection never inherits or clears another peer display")
        select(reconnected, 1)
        try await wait("reconnected peer captures MacBook") {
            reconnected.catalogs.last?.activeDisplayID == 1 && reconnected.frames.last == reconnected.catalogs.last?.videoEpoch?.id
        }
        let fresh = reconnected.catalogs.last!.videoEpoch!
        check(fresh.id != mac.id && fresh.generation != mac.generation && b.catalogs.last?.videoEpoch == virtual,
              "reconnect has a new capture incarnation without restarting B")
        let beforeForeign = host.contractPeerInputs.count
        b.send(.input, SourceInput(event: .text("foreign reconnect"), generation: fresh.generation, videoEpoch: fresh.id))
        b.send(.input, SourceInput(event: .text("own virtual"), generation: virtual.generation, videoEpoch: virtual.id))
        try await wait("reconnect input fence") { host.contractPeerInputEvents.last == .text("own virtual") }
        check(host.contractPeerInputs.count == beforeForeign + 1 && host.contractPeerInputRects.last == ContractCapture.bounds(42),
              "a new connection epoch cannot steer the retained virtual monitor")
        reconnected.connection.cancel()
        try await wait("reconnected peer disconnect processed") { host.contractPeerCount == 1 }
        b.send(.selectDisplay, DisplaySelection(displayID: 42, inventoryID: inventory.revision!, origin: .human))
        let virtualRevision = b.catalogs.last!.selectionRevision
        try await wait("B acknowledges retained virtual source") { b.catalogs.last?.selectionRevision != virtualRevision }
        check(desktop.displayID == 42 && destroyed == 0 && b.catalogs.last?.videoEpoch == virtual,
              "closing the reconnected peer preserves B resource and epoch")
        select(b, 2)
        try await wait("B returns to LG") { b.catalogs.last?.activeDisplayID == 2 && b.catalogs.last?.videoEpoch != nil }
        check(destroyed == 1 && desktop.displayID == nil, "last virtual capture release retires exactly its owned resource")
        let retained = b.catalogs.last!.videoEpoch!
        let beforeRetained = host.contractPeerInputs.count
        b.send(.input, SourceInput(event: .text("B retained"), generation: retained.generation, videoEpoch: retained.id))
        try await wait("B retained input") { host.contractPeerInputs.count == beforeRetained + 1 }
        check(host.contractPeerInputs.last == .desktop && b.catalogs.last?.videoEpoch == retained, "A disconnect leaves B scope live")
        host.contractSentryProtection(verified: false)
        let beforeBlocked = host.contractPeerInputs.count
        b.send(.input, SourceInput(event: .text("blocked"), generation: retained.generation, videoEpoch: retained.id))
        b.send(.selectSource, SourceRequest(source: .window(99), origin: .human))
        try await Task.sleep(for: .milliseconds(150))
        check(host.contractPeerInputs.count == beforeBlocked && b.catalogs.last?.activeDisplayID == 2,
            "failed Sentry protection rejects real wire input and source mutations")
        host.contractSentryProtection(verified: true)
        b.send(.input, SourceInput(event: .text("verified"), generation: retained.generation, videoEpoch: retained.id))
        try await wait("protected peer input resumes") { host.contractPeerInputs.count == beforeBlocked + 1 }
        check(host.contractPeerInputs.last == .desktop, "verified Sentry restores original remote control without a new source")
        print("PASS \(checks) production coordinator + real loopback transport checks; inert capture, dry OS input, no device/audio effects")
    }
}
