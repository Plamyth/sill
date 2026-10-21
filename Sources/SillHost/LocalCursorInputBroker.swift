import Foundation
import CryptoKit
import Dispatch
import StreamProtocol

@MainActor
final class LocalCursorInputBroker {
    private final class Binding {
        var grant: LocalCursorInputLease.Grant
        let window: LocalCursorWindow
        let capture: LocalCursorCapture
        var expiry: Task<Void, Never>?
        init(grant: LocalCursorInputLease.Grant, window: LocalCursorWindow, capture: LocalCursorCapture) {
            self.grant = grant; self.window = window; self.capture = capture
        }
    }
    private final class Client {
        let channel: LocalCursorUnixChannel.Session
        let connection: LocalCursorInputLease.Connection
        var binding: Binding?
        var sequence: UInt64?
        var requestID: UUID?
        var digest: Data?
        var reply: Data?
        var busy = false
        init(channel: LocalCursorUnixChannel.Session, connection: LocalCursorInputLease.Connection) {
            self.channel = channel; self.connection = connection
        }
    }
    private let injector: InputInjector
    private let window: (LocalCursorCapture) async -> LocalCursorWindow?
    private let remoteOwnsInput: () -> Bool
    private let sentryProtected: () -> Bool
    private let hostIsCanonical: () -> Bool
    private var clients: [UUID: Client] = [:]
    private var running = false
    private lazy var lease = LocalCursorInputLease { [weak self] connection, target, _ in
        guard let self, let client = self.clients.values.first(where: { $0.connection === connection }),
              let binding = client.binding, binding.grant.target == target else { return }
        client.binding = nil
        binding.expiry?.cancel()
        self.injector.releaseInput(of: ObjectIdentifier(binding))
    }
    private lazy var channel = LocalCursorUnixChannel(hostIsCanonical: hostIsCanonical,
        onOpen: { [weak self] session in self?.opened(session) },
        onRequest: { [weak self] data, session in Task { @MainActor [weak self] in await self?.receive(data, from: session) } },
        onClose: { [weak self] session in self?.closed(session) })

    init(injector: InputInjector, window: @escaping (LocalCursorCapture) async -> LocalCursorWindow?,
         remoteOwnsInput: @escaping () -> Bool, sentryProtected: @escaping () -> Bool,
         hostIsCanonical: @escaping () -> Bool = { LocalAudioRelayLaunch.validateCanonicalHostForInput() }) {
        self.injector = injector; self.window = window; self.remoteOwnsInput = remoteOwnsInput
        self.sentryProtected = sentryProtected; self.hostIsCanonical = hostIsCanonical
    }

    @discardableResult func start() -> Bool { running = channel.start(); return running }
    func stop() {
        running = false
        channel.stop()
    }

    func ownershipChanged() {
        lease.remoteStateChanged(remoteViewerOwnsInput: remoteOwnsInput(), sentryProtected: sentryProtected())
    }

    private func opened(_ session: LocalCursorUnixChannel.Session) {
        guard running, session.isCurrent else { session.close(); return }
        clients[session.id] = Client(channel: session, connection: lease.openConnection())
    }

    private func closed(_ session: LocalCursorUnixChannel.Session) {
        guard let client = clients[session.id], client.channel === session else { return }
        lease.closeConnection(client.connection)
        clients[session.id] = nil
    }

    private func receive(_ data: Data, from session: LocalCursorUnixChannel.Session) async {
        guard running, let client = clients[session.id], client.channel === session, session.isCurrent else { session.close(); return }
        let allowed: Set<String> = ["schema", "requestID", "sequence", "origin", "interaction", "operation", "connectionID", "capture", "leaseID", "leaseGeneration", "captureGeneration", "videoEpoch", "event", "ttlMilliseconds", "controlEnabled", "activate"]
        guard (try? LocalAudioRelayJSON.validate(data)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowed),
              let request = try? JSONDecoder().decode(LocalCursorInputRequest.self, from: data),
              request.schema == 1, request.sequence <= 9_007_199_254_740_991 else { session.close(); return }
        let digest = Data(SHA256.hash(data: data))
        if client.busy {
            if request.sequence != client.sequence || request.requestID != client.requestID || digest != client.digest { session.close() }
            return
        }
        if request.sequence == client.sequence {
            guard request.requestID == client.requestID, digest == client.digest, let reply = client.reply else { session.close(); return }
            _ = session.send(reply)
            return
        }
        let expected = client.sequence.map { $0 + 1 } ?? 0
        guard request.sequence == expected else {
            _ = session.send(encode(request, client: client, status: "refused", code: "stale_sequence",
                reason: "이 연결에서 처리할 수 없는 요청 순서입니다. 이전 효과를 새 요청으로 재전송하지 마세요."))
            return
        }
        client.busy = true
        defer { client.busy = false }
        client.sequence = request.sequence; client.requestID = request.requestID; client.digest = digest
        ownershipChanged()
        let reply = await perform(request, client: client)
        client.reply = reply
        _ = session.send(reply)
    }

    private func perform(_ request: LocalCursorInputRequest, client: Client) async -> Data {
        func refused(_ code: String, _ reason: String) -> Data {
            encode(request, client: client, status: "refused", code: code, reason: reason)
        }
        guard request.origin == .ccrLocal else { return refused("delegated_input_unsupported", "원격 위임 입력은 아직 지원하지 않습니다.") }
        guard request.interaction.kind == .windowScoped else {
            return refused("conversation_authority_unavailable", "특정 대화의 입력·전송·승인 권한은 아직 검증할 수 없습니다.")
        }
        guard request.operation == .hello ? request.sequence == 0 && request.connectionID == nil : request.connectionID == client.connection.id else {
            return refused("connection_mismatch", "Host가 이 연결에 발급한 식별자가 필요합니다.")
        }
        if request.operation == .hello {
            return encode(request, client: client, status: "observed")
        }
        if request.operation == .release {
            guard let binding = currentBinding(request, client: client) else { return refused("stale_lease", "입력 소유 또는 영상 세대가 바뀌었습니다.") }
            _ = lease.release(binding.grant)
            binding.expiry?.cancel()
            return encode(request, client: client, status: "released")
        }
        guard !remoteOwnsInput(), !sentryProtected() else {
            return refused("remote_owns_input", "기존 원격 화면이나 현장 보호가 입력을 소유하고 있습니다.")
        }
        if request.operation == .bindWindow {
            guard request.controlEnabled == true, let capture = request.capture, capture.isValid,
                  client.channel.isCurrent, let window = await window(capture),
                  running, clients[client.channel.id] === client, client.channel.isCurrent else {
                return refused("target_unavailable", "명시적으로 켠 실제 Cursor 영상과 현재 창을 확인해야 합니다.")
            }
            let scaleX = Double(window.frame.width) / Double(capture.frameWidth), scaleY = Double(window.frame.height) / Double(capture.frameHeight)
            guard abs(scaleX - scaleY) * Double(max(capture.frameWidth, capture.frameHeight)) <= 1 else {
                return refused("capture_geometry_mismatch", "영상과 실제 창의 좌표 비율을 확인할 수 없습니다.")
            }
            let target = LocalCursorInputLease.Target(pid: capture.pid, windowID: capture.windowID,
                instanceID: capture.instanceID ?? "", workspace: capture.workspace ?? "", interaction: .windowScoped,
                captureGeneration: capture.captureGeneration, videoEpoch: capture.videoEpoch)
            do {
                let grant = try lease.claim(client.connection, target: target, ttlMilliseconds: request.ttlMilliseconds ?? 500)
                let binding = Binding(grant: grant, window: window, capture: capture)
                client.binding = binding
                scheduleExpiry(binding)
                if request.activate == true {
                    guard window.focus(authorize: { [weak self, weak client, weak binding] operation in
                        guard let self, let client, let binding else { return false }
                        return self.authorize(binding, client: client, event: nil, operation: operation)
                    }) else {
                        _ = lease.release(binding.grant)
                        return refused("target_not_focused", "대상 창의 활성화와 입력 위치를 확인하지 못했습니다.")
                    }
                }
                guard window.permits(.text("")), authorize(binding, client: client, event: nil, operation: {}) else {
                    _ = lease.release(binding.grant)
                    return refused("target_not_focused", "대상 Cursor 창이 실제 입력 창인지 확인하지 못했습니다.")
                }
                return encode(request, client: client, status: "bound")
            } catch {
                return refused("lease_unavailable", "다른 입력 소유, 만료 또는 허용되지 않은 유지 시간입니다.")
            }
        }
        guard let binding = currentBinding(request, client: client) else {
            return refused("stale_lease", "입력 소유 또는 영상 세대가 바뀌었습니다.")
        }
        if request.operation == .renew {
            guard authorize(binding, client: client, event: .text(""), operation: {}) else {
                return refused("target_not_current", "창·초점·연결 권한이 바뀌어 입력을 중지했습니다.")
            }
            do {
                binding.grant = try lease.renew(binding.grant, ttlMilliseconds: request.ttlMilliseconds ?? 500)
                scheduleExpiry(binding)
                return encode(request, client: client, status: "renewed")
            } catch { return refused("stale_lease", "이전 입력 소유를 갱신할 수 없습니다.") }
        }
        guard request.operation == .input, let event = request.event, Self.valid(event) else {
            return refused("invalid_input", "허용된 범위의 포인터·스크롤·키보드 입력이 필요합니다.")
        }
        var count = 0
        let admitted = authorize(binding, client: client, event: event) {
            count = injector.trackingPosts {
                injector.withAuthorization({ [weak self, weak client, weak binding] operation in
                    guard let self, let client, let binding else { return false }
                    return self.authorize(binding, client: client, event: event, operation: operation)
                }) { injector.apply(event, in: binding.window.frame, from: ObjectIdentifier(binding)) }
            }
        }
        if count > 0 { return encode(request, client: client, status: "inputPosted", postedEvents: count) }
        return refused(admitted ? "input_not_posted" : "target_not_current", "이 요청의 OS 입력 게시를 확인하지 못했습니다.")
    }

    private func currentBinding(_ request: LocalCursorInputRequest, client: Client) -> Binding? {
        guard let binding = client.binding, request.leaseID == binding.grant.id,
              request.leaseGeneration == binding.grant.generation,
              request.captureGeneration == binding.capture.captureGeneration,
              request.videoEpoch == binding.capture.videoEpoch else { return nil }
        return binding
    }

    private func authorize(_ binding: Binding, client: Client, event: InputEvent?, operation: () -> Void) -> Bool {
        ownershipChanged()
        return lease.withAuthorization(binding.grant, windowCurrent: { [weak self, weak client, weak binding] _ in
            guard let self, let client, let binding, self.running, client.binding === binding,
                  self.clients[client.channel.id] === client, client.channel.isCurrent else { return false }
            let valid = event.map { binding.window.permits($0) } ?? binding.window.isLive
            self.ownershipChanged()
            return valid && client.channel.isCurrent && !self.remoteOwnsInput() && !self.sentryProtected()
        }, operation: operation)
    }

    private func scheduleExpiry(_ binding: Binding) {
        binding.expiry?.cancel()
        let grant = binding.grant
        let now = DispatchTime.now().uptimeNanoseconds
        let delay = grant.deadlineNanoseconds > now ? grant.deadlineNanoseconds - now : 0
        binding.expiry = Task { @MainActor [weak self, weak binding] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, let binding, binding.grant === grant else { return }
            _ = self.lease.expireIfNeeded()
        }
    }

    private func encode(_ request: LocalCursorInputRequest, client: Client, status: String,
                        code: String? = nil, reason: String? = nil, postedEvents: Int? = nil) -> Data {
        let binding = client.binding
        let expires = binding.map { value -> Int in
            let now = DispatchTime.now().uptimeNanoseconds
            return value.grant.deadlineNanoseconds > now ? Int((value.grant.deadlineNanoseconds - now) / 1_000_000) : 0
        }
        return Wire.encode(LocalCursorInputReply(requestID: request.requestID, sequence: request.sequence,
            status: status, code: code, reason: reason, connectionID: client.connection.id,
            leaseID: binding?.grant.id, leaseGeneration: binding?.grant.generation, capture: binding?.capture,
            expiresInMilliseconds: expires, postedEvents: postedEvents, windowInputSupported: true))
    }

    private static func valid(_ event: InputEvent) -> Bool {
        func point(_ x: Double, _ y: Double) -> Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
        switch event {
        case .pointer(_, let x, let y), .scrollGesture(_, let x, let y): return point(x, y)
        case .scroll(let x, let y, let dx, let dy): return point(x, y) && dx.isFinite && dy.isFinite && abs(dx) <= 4 && abs(dy) <= 4
        case .text(let text): return !text.isEmpty && text.utf8.count <= 256
        case .key(let usage, _, let modifiers): return (4...231).contains(usage) && modifiers & ~UInt64(0xFF0000) == 0
        }
    }
}
