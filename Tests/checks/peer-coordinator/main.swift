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
        PeerCaptureDescription(source: source, bounds: CGRect(x: 1, y: 2, width: 640, height: 480),
                               width: 640, height: 480, displayID: nil, windowPID: nil, title: "격리 화면")
    }
    func start(_ description: PeerCaptureDescription, epoch: VideoEpoch,
               output: @escaping (StreamMessage, UUID) -> Void) async throws {
        self.description = description; self.epoch = epoch; self.output = output
    }
    func requestKeyframe() {
        guard let epoch else { return }
        output?(StreamMessage(kind: .parameterSets, timestamp: 0, isKeyframe: true, payload: Data([1,2,3])), epoch.id)
        output?(StreamMessage(kind: .frame, timestamp: 0, isKeyframe: true, payload: Data([0,0,0,2,0x26,1])), epoch.id)
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
        host.startPeerContract { ContractCapture() }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            fatalError("timeout: \(label)")
        }
        try await wait("listener") { host.server.port != nil }
        let a = Client(port: host.server.port!), b = Client(port: host.server.port!)
        defer { a.connection.cancel(); b.connection.cancel() }
        try await a.start(); try await b.start()
        try await wait("both peer catalogs") { a.catalogs.last?.independentStreams == 1 && b.catalogs.last?.independentStreams == 1 }
        var checks = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
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
        try await wait("new input admitted") { host.contractPeerInputs.count >= 3 }
        check(Set(host.contractPeerInputs.prefix(2)) == Set([StreamSource.window(10), .window(20)]) && host.contractPeerInputs.count == 3 && host.contractPeerInputs.last == .window(11), "foreign and stale input dropped")
        a.connection.cancel()
        b.send(.input, SourceInput(event: .text("B retained"), generation: eb.generation, videoEpoch: eb.id))
        try await wait("B retained input") { host.contractPeerInputs.count >= 4 }
        check(host.contractPeerInputs.last == .window(20) && b.catalogs.last?.videoEpoch == eb, "A disconnect leaves B scope live")
        host.contractSentryProtection(verified: false)
        let beforeBlocked = host.contractPeerInputs.count
        b.send(.input, SourceInput(event: .text("blocked"), generation: eb.generation, videoEpoch: eb.id))
        b.send(.selectSource, SourceRequest(source: .window(99), origin: .human))
        try await Task.sleep(for: .milliseconds(150))
        check(host.contractPeerInputs.count == beforeBlocked && b.catalogs.last?.active == .window(20),
            "failed Sentry protection rejects real wire input and source mutations")
        host.contractSentryProtection(verified: true)
        b.send(.input, SourceInput(event: .text("verified"), generation: eb.generation, videoEpoch: eb.id))
        try await wait("protected peer input resumes") { host.contractPeerInputs.count == beforeBlocked + 1 }
        check(host.contractPeerInputs.last == .window(20), "verified Sentry restores original remote control without a new source")
        print("PASS \(checks) production coordinator + real loopback transport checks; inert capture, dry OS input, no device/audio effects")
    }
}
