import Foundation
import StreamProtocol

final class NWConnection {
    enum State { case ready, cancelled }
    var state = State.ready
    func cancel() { state = .cancelled }
}
struct ClientRoute {
    var encrypted = true
    var pairedName: String? = "검사 기기"
}
// JSON
final class Server {
    final class Client {
        let connection = NWConnection()
        var route = ClientRoute()
        var role = StreamPeerRole.awaitingHello
        var forwardingExchange: ForwardingExchange?
        var forwardingObserved = false
    }
    // final class ForwardingExchange:
    var clients: [ObjectIdentifier: Client] = [:]
    let queue = DispatchQueue(label: "forwarding-control-check")
    var onForwardingControl: ((ForwardingExchange, NWConnection, ClientRoute, AudioForwardingCatalog.Role) -> Void)?
    var sent: [StreamMessage] = []
    func send(_ raw: Data, to client: Client) {
        let header = StreamMessage.parseHeader(raw)!
        guard client.role.sends(header.kind) else { return }
        sent.append(StreamMessage(kind: header.kind, timestamp: 0, isKeyframe: false,
                                  payload: Data(raw.suffix(header.payloadLength))))
    }
    func client() -> Client {
        let c = Client()
        clients[ObjectIdentifier(c.connection)] = c
        return c
    }
    // private func receiveForwarding(
    // func sendForwardingState(
}

@main struct Checks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        for role in [StreamPeerRole.awaitingHello, .controlOnly] {
            for kind in [StreamMessageKind.frame, .audio, .input, .selectSource, .microphoneControl, .microphoneFrame] {
                check(!role.accepts(kind), "관찰 연결은 입력과 소스를 바꿀 수 없음")
                check(!role.sends(kind), "관찰 연결은 영상과 오디오를 받지 않음")
            }
            check(!role.sends(.windowList), "인증 관찰 연결에 화면 목록 전송 금지")
        }
        let peer = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
        let generation = UUID()
        let observe = try AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
        let intent = try AudioForwardingIntentRequest(pairedDeviceId: peer, intentId: UUID(), intentRevision: .init(1),
            action: .request, inputDesired: true, outputDesired: true, expectedRevision: .init(0),
            transportId: UUID(), transportKind: .native, bindingRevision: .init(1))
        let submit = try AudioForwardingControl(requestID: UUID(), operation: .submit, intent: intent)
        func reply(_ requestID: UUID, role: AudioForwardingCatalog.Role = .controlOnly) throws -> AudioForwardingState {
            let credential = try AudioForwardingCredential(pairedDeviceId: peer, pairingGeneration: generation,
                credential: String(repeating: "A", count: 43))
            let snapshot = try AudioForwardingSnapshot(revision: .init(0), intent: nil, binding: nil)
            let bootstrap = try AudioForwardingBootstrap(credential: credential,
                ownCursor: .init(intentRevision: .init(0), bindingRevision: .init(0)), snapshot: snapshot)
            let catalog = try AudioForwardingCatalog(principal: .init(kind: .tailnet, id: peer,
                authorizationGeneration: generation), role: role, bootstrap: bootstrap)
            return try AudioForwardingState(requestID: requestID, operation: .observe, catalog: catalog, result: nil)
        }
        for scenario in ["valid", "unpaired", "plaintext", "submit-first", "duplicate", "bad-json",
                         "wrong-id", "wrong-role", "expired", "replaced", "promoted"] {
            let server = Server(), c = server.client()
            var calls = 0
            server.onForwardingControl = { _, _, _, role in
                calls += 1
                check(role == .controlOnly, "관찰 역할만 전달")
            }
            if scenario == "unpaired" { c.route.pairedName = nil }
            if scenario == "plaintext" { c.route.encrypted = false }
            var data = Wire.encode(scenario == "submit-first" ? submit : observe)
            if scenario == "bad-json" { data = Data("{\"operation\":\"observe\",\"operation\":\"submit\"}".utf8) }
            server.queue.sync { server.receiveForwarding(data, from: c) }
            if ["unpaired", "plaintext", "submit-first", "bad-json"].contains(scenario) {
                check(c.connection.state == .cancelled && calls == 0, "인증·순서·JSON 거부")
                continue
            }
            check(c.role == .controlOnly && calls == 1, "hello 없이 관찰 연결 확정")
            let exchange = c.forwardingExchange!
            if scenario == "duplicate" {
                server.queue.sync { server.receiveForwarding(data, from: c) }
                check(c.connection.state == .cancelled && calls == 1, "중복 동시 요청 차단")
                continue
            }
            if scenario == "expired" { exchange.invalidate() }
            if scenario == "replaced" { server.clients[ObjectIdentifier(c.connection)] = Server.Client() }
            if scenario == "promoted" {
                exchange.invalidate(); c.forwardingExchange = nil; c.role = .viewer
            }
            let state = try reply(scenario == "wrong-id" ? UUID() : observe.requestID,
                                  role: scenario == "wrong-role" ? .viewer : .controlOnly)
            server.sendForwardingState(state, to: c.connection, ticket: exchange.ticket)
            server.queue.sync {}
            let accepted = scenario == "valid"
            check((server.sent.count == 1) == accepted, "교체·만료·다른 요청의 응답은 전송 금지")
            check(!exchange.isCurrent || c.connection.state == .cancelled || scenario == "replaced", "응답 후 교환 ticket 소모")
            if accepted {
                check(c.forwardingObserved, "수신 완료 뒤에만 submit 허용")
                server.queue.sync { server.receiveForwarding(Wire.encode(submit), from: c) }
                check(calls == 2, "확인된 연결의 submit 전달")
            }
        }
        print("관찰 연결·인증·전환 검사 \(checks)개 통과. 실제 화면·입력·오디오 조작 0.")
    }
}
