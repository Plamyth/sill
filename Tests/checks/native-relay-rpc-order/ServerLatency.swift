import Foundation
import StreamProtocol

private final class NWConnection {
    enum State { case ready, cancelled }
    var state = State.ready
    func cancel() { state = .cancelled }
}
private struct ClientRoute { var encrypted = true; var pairedName: String? = "검사 기기" }
private final class LatencyServer {
    final class Client {
        let connection = NWConnection()
        var route = ClientRoute()
        var role = StreamPeerRole.controlOnly
        var forwardingExchange: ForwardingExchange?
        var forwardingObserved = false
    }
    // final class ForwardingExchange:
    var clients: [ObjectIdentifier: Client] = [:]
    let queue = DispatchQueue(label: "relay-latency-server-check")
    var forwardingTracesRemaining = 64
    var onForwardingControl: ((ForwardingExchange, NWConnection, ClientRoute, AudioForwardingCatalog.Role) -> Void)?
    var sends = 0
    func send(_ data: Data, to client: Client) { sends += 1 }
    // private func receiveForwarding(
    // func sendForwardingState(
}

extension Checks {
    @MainActor static func serverLatencyDiagnostics() async {
        HostLog.shared.configure(keepLines: 1024, fileURL: nil)
        let server = LatencyServer(), client = LatencyServer.Client()
        server.clients[ObjectIdentifier(client.connection)] = client
        let peer = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!, generation = UUID()
        func response(_ control: AudioForwardingControl) -> AudioForwardingState {
            let credential = try! AudioForwardingCredential(pairedDeviceId: peer, pairingGeneration: generation,
                                                          credential: String(repeating: "A", count: 43))
            let snapshot = try! AudioForwardingSnapshot(revision: .init(0), intent: nil, binding: nil)
            let bootstrap = try! AudioForwardingBootstrap(credential: credential,
                ownCursor: .init(intentRevision: .init(0), bindingRevision: .init(0)), snapshot: snapshot)
            let catalog = try! AudioForwardingCatalog(principal: .init(kind: .tailnet, id: peer, authorizationGeneration: generation),
                                                     role: .controlOnly, bootstrap: bootstrap)
            return try! .init(requestID: control.requestID, operation: .observe, catalog: catalog, result: nil)
        }
        server.onForwardingControl = { _, _, _, _ in }
        for _ in 0..<80 {
            let control = try! AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
            server.queue.sync { server.receiveForwarding(Wire.encode(control), from: client) }
            let exchange = client.forwardingExchange!
            expect(exchange.isCurrent, "서버 수신 뒤 현재 handler authority 유지")
            server.sendForwardingState(response(control), to: client.connection, ticket: exchange.ticket)
            server.queue.sync {}
        }
        expect(server.sends == 80 && server.forwardingTracesRemaining == 64, "빠른 정상 OFF observe 80회도 서버 진단 예산 소진0")
        let control = try! AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
        server.queue.sync { server.receiveForwarding(Wire.encode(control), from: client) }
        let exchange = client.forwardingExchange!
        try? await Task.sleep(for: .milliseconds(80))
        expect(exchange.isCurrent, "MainActor handler 진입 때 기존 authority 검사 수용")
        try? await Task.sleep(for: .milliseconds(60))
        server.queue.async { Thread.sleep(forTimeInterval: 0.3) }
        server.sendForwardingState(response(control), to: client.connection, ticket: exchange.ticket)
        server.queue.sync {}
        let line = HostLog.shared.lines(after: 0).last!.text
        let fields = Dictionary(uniqueKeysWithValues: line.split(separator: " ").dropFirst(2).compactMap { field -> (String, String)? in
            let p = field.split(separator: "=", maxSplits: 1);return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        })
        expect((Double(fields["firstMainCheckMs"] ?? "") ?? -1) >= 60 &&
               (Double(fields["handlerToReplyMs"] ?? "") ?? -1) >= 40 &&
               (Double(fields["replyQueueMs"] ?? "") ?? -1) >= 250,
               "서버 수신→첫 MainActor 검사·handler 전체·응답 큐 시간을 분리")
        expect(fields["request"] == control.requestID.uuidString && !line.contains(String(repeating: "A", count: 43)),
               "서버 관측은 requestID만 포함하고 응답 credential을 기록하지 않음")
        for _ in 0..<80 {
            client.connection.state = .ready
            let c = try! AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
            server.queue.sync { server.receiveForwarding(Wire.encode(c), from: client) }
            server.sendForwardingState(nil, to: client.connection, ticket: client.forwardingExchange!.ticket)
            server.queue.sync {}
            client.forwardingExchange = nil
        }
        expect(HostLog.shared.lines(after: 0).filter { $0.text.hasPrefix("audio.trace forwardingReply ") }.count == 64,
               "서버의 느리거나 실패한 응답 진단 상한 64개")
    }
}
