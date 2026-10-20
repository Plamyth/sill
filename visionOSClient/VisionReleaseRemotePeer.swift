#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import Network
import StreamProtocol

final class VisionReleaseRemotePeer: ObservableObject {
    struct Snapshot: Equatable {
        var tls = false
        var authenticated = false
        var presented = false
        var frames = 0
        var inputCount = 0
        var text = ""
        var providerAbsent = true
        var reset = false
        var stopped = false
        var problem: String?
    }

    @Published private(set) var snapshot = Snapshot()
    private let queue = DispatchQueue(label: "ccr.vision.simulated-peer")
    private let context: VisionReleaseTestContext.Context
    private let lease: VisionWindowLease
    private let boot: String
    private let identity: RemoteIdentity
    private let device: RemoteIdentity
    private let directory: URL
    private let epoch: VideoEpoch
    private let inventory = UUID()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var readers: [MessageReader] = []
    private var frames: DispatchSourceTimer?
    private var expiry: DispatchWorkItem?
    private var state = Snapshot()
    private var inputs: [SourceInput] = []
    private var presentationObserved = false
    private var stopped = false
    private var started = false
    private var observed: (authenticated: Bool, presented: Bool)?

    init(context: VisionReleaseTestContext.Context, lease: VisionWindowLease) throws {
        guard VisionReleaseTestContext.isRemote, context.profile == .remote,
              context.commit == VisionReleaseTestContext.current?.commit,
              context.tree == VisionReleaseTestContext.current?.tree,
              context.runID == VisionReleaseTestContext.current?.runID else { throw Failure.invalidContext }
        VisionReleaseRuntimeWriter.write()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let runtime = try JSONSerialization.jsonObject(with: Data(contentsOf:
            documents.appendingPathComponent("CCRReleaseRuntime.json"))) as? [String: Any]
        guard let boot = runtime?["bootUUID"] as? String, UUID(uuidString: boot) != nil,
              runtime?["commit"] as? String == context.commit,
              runtime?["tree"] as? String == context.tree,
              runtime?["bundleId"] as? String == VisionReleaseTestContext.bundleID,
              runtime?["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier,
              let device = DeviceIdentity.existing(), let key = RemoteKey.generate(),
              let identity = RemoteIdentity(privateKey: key) else { throw Failure.identity }
        self.context = context
        self.lease = lease
        self.boot = boot
        self.device = device
        self.identity = identity
        directory = documents.appendingPathComponent("CCRRemoteFixture", isDirectory: true)
            .appendingPathComponent(context.runID, isDirectory: true)
            .appendingPathComponent(lease.admission.uuidString, isDirectory: true)
        epoch = VideoEpoch(generation: UUID().uuidString, source: .desktop,
            geometry: .init(x: 0, y: 0, width: 64, height: 64), width: 64, height: 64)
    }

    func start(client: StreamClient) {
        guard !started else { return }
        started = true
        queue.async { [self, weak client] in
            guard !stopped else { return }
            do {
                let pin = device.fingerprint
                let tls = RemoteTLS.options(identity: identity.tls, role: .server, queue: queue) { fp, alpn in
                    fp == pin && alpn == RemoteTLS.sessionALPN
                }
                let parameters = RemoteTLS.parameters(tls: tls, dialing: false)
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                parameters.requiredInterfaceType = .loopback
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.stateUpdateHandler = { [weak self, weak client, weak listener] status in
                    guard let self, let listener, !self.stopped else { return }
                    switch status {
                    case .ready:
                        guard let port = listener.port else { self.fail(Failure.listener); return }
                        let mac = self.savedMac(port: Int(port.rawValue))
                        DispatchQueue.main.async { [weak self, weak client] in
                            guard let self, let client, client.visionDisplaySelection.lease == self.lease,
                                  !client.visionWindowRetired else { return }
                            guard client.trustVisionReleasePeer(mac) else {
                                self.queue.async { self.fail(Failure.identity) }
                                return
                            }
                            client.dialSaved(mac.macID, why: .connectRemotely)
                        }
                    case .failed(let error): self.fail(error)
                    default: break
                    }
                }
                listener.start(queue: queue)
                let expiry = DispatchWorkItem { [weak self] in self?.fail(Failure.expired) }
                self.expiry = expiry
                queue.asyncAfter(deadline: .now() + 120, execute: expiry)
                try record()
            } catch { fail(error) }
        }
    }

    func observe(client: StreamClient, lease: VisionWindowLease?, foreground: Bool) {
        let authenticated = client.connected && client.macInfoSaved &&
            client.macInfoVerified?.fingerprint == identity.fingerprint &&
            client.session?.macID == MacID.make(fingerprint: identity.fingerprint)
        let presented = authenticated && foreground && lease == self.lease &&
            client.visionInputBinding == .presented(epoch)
        guard observed?.authenticated != authenticated || observed?.presented != presented else { return }
        observed = (authenticated, presented)
        queue.async { [self] in
            guard !stopped else { return }
            state.authenticated = authenticated
            state.presented = presented
            presentationObserved = presentationObserved || presented
            do { try record() } catch { fail(error) }
        }
    }

    func resetProvider() {
        queue.async { [self] in
            do { try reset(); try record() } catch { fail(error) }
        }
    }

    func stop() {
        queue.async { [self] in close() }
    }

    private func savedMac(port: Int) -> SavedMac {
        SavedMac(macID: MacID.make(fingerprint: identity.fingerprint),
            fingerprint: Base64URL.encode(identity.fingerprint), name: "시뮬레이션 Mac 피어",
            recognitionKey: Base64URL.encode(Data(repeating: 0, count: 32)), remotePort: port,
            addresses: [.init(host: "127.0.0.1", port: port, kind: MacAddress.lan, via: "simulated-peer")],
            infoIssuedAt: 0, pairedAt: Date(), method: "simulated-peer", homeTLS: true)
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.isEmpty else { connection.cancel(); return }
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] status in
            guard let self, let connection, !self.stopped else { return }
            switch status {
            case .ready:
                guard RemoteTLS.peerFingerprint(connection) == self.device.fingerprint,
                      RemoteTLS.negotiatedALPN(connection) == RemoteTLS.sessionALPN else {
                    self.fail(Failure.identity); return
                }
                self.state.tls = true
                let reader = MessageReader(connection: connection,
                    stillReads: { [weak self] in self?.stopped == false }, onBytes: { _ in },
                    onMessage: { [weak self] header, data in self?.receive(header, data, on: connection) },
                    onEnd: { [weak self] _ in self?.close() })
                self.readers.append(reader)
                reader.start()
            case .failed(let error): self.fail(error)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ header: StreamHeader, _ data: Data, on connection: NWConnection) {
        guard !stopped else { return }
        do {
            switch header.kind {
            case .hello:
                guard frames == nil, let hello = Wire.decode(Hello.self, from: data),
                      hello.presentationInput == 1, let port = listener?.port else { throw Failure.hello }
                let info = MacInfo(macID: MacID.make(fingerprint: identity.fingerprint), name: "시뮬레이션 Mac 피어",
                    issuedAt: Date().timeIntervalSince1970, remoteAccess: true, remotePort: Int(port.rawValue),
                    internet: false, addresses: savedMac(port: Int(port.rawValue)).addresses)
                guard let signed = SignedMacInfo.signing(info, with: identity.privateKey) else { throw Failure.identity }
                send(.macInfo, Wire.encode(signed), on: connection)
                send(.windowList, Wire.encode(catalog()), on: connection)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                frames = timer
                timer.setEventHandler { [weak self] in self?.sendFrame(on: connection) }
                timer.schedule(deadline: .now() + 0.1, repeating: 0.5)
                timer.resume()
            case .ping: send(.pong, data, on: connection)
            case .input:
                guard inputs.count < 128, let input = Wire.decode(SourceInput.self, from: data),
                      input.generation == epoch.generation, input.videoEpoch == epoch.id else { throw Failure.input }
                inputs.append(input)
                state.inputCount = inputs.count
                if case .text(let text) = input.event {
                    guard VisionDraftText.accepts(text) else { throw Failure.input }
                    let file = directory.appendingPathComponent("provider.json")
                    try prepareDirectory()
                    try JSONEncoder().encode(input).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    let readback = try JSONDecoder().decode(SourceInput.self, from: Data(contentsOf: file))
                    guard readback.event == input.event, readback.generation == epoch.generation,
                          readback.videoEpoch == epoch.id else { throw Failure.input }
                    state.text = text
                    state.providerAbsent = false
                    state.reset = false
                }
            case .selectDisplay:
                guard let selection = Wire.decode(DisplaySelection.self, from: data),
                      selection.displayID == 1, selection.inventoryID == inventory else { throw Failure.input }
                send(.windowList, Wire.encode(catalog()), on: connection)
            case .viewport, .clientStats, .fetchMenu: break
            default: throw Failure.unsupported
            }
            try record()
        } catch { fail(error) }
    }

    private func catalog() -> WindowList {
        WindowList(macName: "시뮬레이션 Mac 피어", windows: [], active: epoch.source,
            launchID: boot, hostVersion: "simulated-peer", protocol: SillProtocol.current,
            inputGeneration: epoch.generation, presentationInput: 1, videoEpoch: epoch,
            displaySelection: 1, displays: [.init(id: 1, name: "격리 화면", width: 64, height: 64, isMain: true)],
            displayInventoryID: inventory, activeDisplayID: 1, desktopSelectionRequired: false)
    }

    private func sendFrame(on connection: NWConnection) {
        guard !stopped else { return }
        let sets = ["QAEMAf//BAgAAAMAn6gAAAMAAB66AkA=", "QgEBBAgAAAMAn6gAAAMAAB6gIIEFlukpMLmgIAAAAwAgAAADAEE=", "RAHAcYES"]
            .compactMap { Data(base64Encoded: $0) }
        let samples = ["KAGt4NEX/8m1zI4u", "KAGsE+Do6D2n1Mkfyi9tj4A="]
        guard let nal = Data(base64Encoded: samples[state.frames % samples.count]) else { fail(Failure.media); return }
        var length = UInt32(nal.count).bigEndian
        let frame = withUnsafeBytes(of: &length) { Data($0) } + nal
        send(.epochParameterSets, PresentationMedia.encode(epoch: epoch.id,
            media: ParameterSets(nalUnitHeaderLength: 4, sets: sets).encoded()), on: connection)
        send(.epochFrame, PresentationMedia.encode(epoch: epoch.id, media: frame), keyframe: true, on: connection)
        state.frames += 1
        do { try record() } catch { fail(error) }
    }

    private func send(_ kind: StreamMessageKind, _ data: Data, keyframe: Bool = false, on connection: NWConnection) {
        connection.send(content: StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970,
            isKeyframe: keyframe, payload: data).serialized(), completion: .contentProcessed { [weak self] error in
                if let error, self?.stopped == false { self?.fail(error) }
            })
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func reset() throws {
        let file = directory.appendingPathComponent("provider.json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw Failure.reset }
        state.providerAbsent = true
        state.reset = true
        state.text = ""
    }

    private func record() throws {
        try prepareDirectory()
        let inputJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inputs))
        let epochJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(epoch))
        let receipt: [String: Any] = [
            "schema": "ccr.vision.simulated-remote-peer/v1", "profile": "remote",
            "commit": context.commit, "tree": context.tree, "runID": context.runID, "bootUUID": boot,
            "owner": "01a13005-ff61-7780-b0e8-6dc171de1c9d",
            "window": lease.window.uuidString, "admission": lease.admission.uuidString,
            "bundleId": VisionReleaseTestContext.bundleID, "providerMode": "simulated-loopback-tls-peer",
            "storageIdentity": directory.path, "externalEffects": "zero", "wholeProductTestAccepted": false,
            "tlsMutualPinVerified": state.tls, "clientSignedIdentityVerified": state.authenticated,
            "nativePresentationObserved": presentationObserved, "framesSent": state.frames,
            "epoch": epoch.id.uuidString, "videoEpoch": epochJSON, "generation": epoch.generation, "inputs": inputJSON,
            "providerAbsent": state.providerAbsent, "providerResetVerified": state.reset,
            "stopped": state.stopped, "problem": state.problem ?? "",
            "uncovered": ["physical-gaze", "physical-audio", "HAL", "Sentry", "whole-acceptance"]]
        let file = directory.appendingPathComponent("receipt.json")
        try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let snapshot = state
        DispatchQueue.main.async { [weak self] in self?.snapshot = snapshot }
    }

    private func fail(_ error: Error) {
        state.problem = String(describing: error)
        close()
    }

    private func close() {
        guard !stopped else { return }
        stopped = true
        frames?.cancel(); frames = nil
        expiry?.cancel(); expiry = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        readers.removeAll()
        state.stopped = true
        state.presented = false
        do { try reset(); try record() } catch {
            state.problem = String(describing: error)
            let snapshot = state
            DispatchQueue.main.async { [weak self] in self?.snapshot = snapshot }
        }
    }

    private enum Failure: Error { case invalidContext, identity, listener, hello, input, unsupported, media, reset, expired }
}

final class VisionReleaseSilentPlayer: VisionAudioPlaying {
    var cleanupProblem: String? { nil }
    var onCleanupChange: ((String?) -> Void)?
    func retryCleanup() {}
    func begin(grant: UUID, onEvent: @escaping (UUID, VisionAudioPlaybackEvent) -> Void) {
        onEvent(grant, .failed("시뮬레이션 피어는 실제 오디오를 사용하지 않습니다."))
    }
    func receive(_ packet: Data, grant: UUID) {}
    func stop() {}
}

struct VisionReleaseRemoteStatus: View {
    @ObservedObject var peer: VisionReleaseRemotePeer
    var body: some View {
        VStack {
            Text("시뮬레이션 피어 · 실제 Mac·시선·오디오·HAL·Sentry 검증 아님").font(.caption)
            if peer.snapshot.tls && peer.snapshot.authenticated {
                Text("TLS 연결·Mac 서명 확인 완료").accessibilityIdentifier("release.remote-authenticated")
            }
            if peer.snapshot.presented && peer.snapshot.frames >= 2 {
                Text("네이티브 영상 표시 확인").accessibilityIdentifier("release.remote-presented")
            }
            Text(peer.snapshot.text).accessibilityIdentifier("release.remote-input")
            Button("격리 공급자 초기화") { peer.resetProvider() }
            if peer.snapshot.providerAbsent && peer.snapshot.reset {
                Text("격리 공급자 삭제 확인").accessibilityIdentifier("release.remote-reset")
            }
            if let problem = peer.snapshot.problem { Text("격리 피어 오류: \(problem)") }
        }
    }
}
#endif
