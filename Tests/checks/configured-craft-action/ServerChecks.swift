import Foundation
import StreamProtocol

private final class CraftConnection: @unchecked Sendable {
    enum State { case ready, cancelled }
    var state = State.ready
    func cancel() { state = .cancelled }
}
private typealias NWConnection = CraftConnection
private final class CraftServerFixture: @unchecked Sendable {
    struct Role { var isViewer = true }
    struct Route { var encrypted = true; var pairedName: String? = "fixture"; var fingerprint: Data? = Data(repeating: 0xab, count: 32) }
    final class Client: @unchecked Sendable {
        let connection = CraftConnection()
        var role = Role(), route = Route(), admitted = true
        var configuredCraftExchange: ConfiguredCraftExchange?
    }
    let queue = DispatchQueue(label: "configured-craft.fixture")
    var clients: [ObjectIdentifier: Client] = [:]
    var onConfiguredCraftControl: ((ConfiguredCraftExchange, NWConnection, Route) -> Void)?
    var sent: [Data] = []
    func admissionIsCurrent(_ client: Client) -> Bool { client.admitted }
    func send(_ data: Data, to client: Client) { sent.append(data) }
    func add() -> Client {
        let client = Client(); clients[ObjectIdentifier(client.connection)] = client; return client
    }
    func receive(_ data: Data, _ client: Client) { queue.sync { receiveConfiguredCraft(data, from: client) } }
    func drain() { queue.sync {} }
    // PRODUCTION_TICKET
    // PRODUCTION_HANDLERS
}

@MainActor func craftServerChecks(_ check: (String, Bool) -> Void) async throws {
    let peer = AudioForwardingDeviceID(hex: String(repeating: "ab", count: 32))!
    let control = ConfiguredCraftActionControl(requestId: UUID())
    let payload = Wire.encode(control)
    for cause in ["unpaired", "plain", "control_only", "no_fingerprint", "stale", "oversize", "extra", "duplicate"] {
        let f = CraftServerFixture(), c = f.add(); var data = payload, called = 0
        f.onConfiguredCraftControl = { _, _, _ in called += 1 }
        switch cause {
        case "unpaired": c.route.pairedName = nil
        case "plain": c.route.encrypted = false
        case "control_only": c.role.isViewer = false
        case "no_fingerprint": c.route.fingerprint = nil
        case "stale": c.admitted = false
        case "oversize": data = Data(repeating: 32, count: 4097)
        case "extra": data = Data("{\"schemaVersion\":1,\"requestId\":\"\(control.requestId.uuidString.lowercased())\",\"operation\":\"catalog\",\"client\":null}".utf8)
        default: data = Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8)
        }
        f.receive(data, c)
        check("production receiver rejects \(cause)", called == 0 && c.connection.state == .cancelled)
    }
    do {
        let f = CraftServerFixture(), c = f.add(); var called = 0
        f.onConfiguredCraftControl = { _, _, _ in called += 1 }
        f.receive(payload, c); f.receive(payload, c)
        check("one command ticket per connection", called == 1 && c.connection.state == .cancelled)
    }
    do {
        let f = CraftServerFixture(), c = f.add()
        f.onConfiguredCraftControl = { _, _, _ in }
        f.receive(payload, c)
        let ticket = c.configuredCraftExchange!
        let state = try ConfiguredCraftActionState(control: control, deviceId: peer, error: "unavailable")
        f.sendConfiguredCraftState(state, to: c.connection, ticket: UUID()); f.drain()
        check("foreign ticket cannot send", f.sent.isEmpty)
        f.sendConfiguredCraftState(state, to: c.connection, ticket: ticket.ticket); f.drain()
        check("production reply clears and invalidates ticket", f.sent.count == 1 && c.configuredCraftExchange == nil && !ticket.isCurrent)
        let header = StreamMessage.parseHeader(f.sent[0])!
        let decoded = try ConfiguredCraftActionState.decode(Data(f.sent[0].dropFirst(StreamMessage.headerLength)))
        check("production response kind and correlation", header.kind == .configuredCraftActionState && decoded.matches(control) && decoded.deviceId == peer)
    }
    for cause in ["stale", "device", "invalidated"] {
        let f = CraftServerFixture(), c = f.add()
        f.onConfiguredCraftControl = { _, _, _ in }
        f.receive(payload, c)
        let ticket = c.configuredCraftExchange!
        if cause == "stale" { c.admitted = false }
        if cause == "device" { c.route.fingerprint = Data(repeating: 0xcd, count: 32) }
        if cause == "invalidated" { ticket.invalidate() }
        let state = try ConfiguredCraftActionState(control: control, deviceId: peer, error: "unavailable")
        f.sendConfiguredCraftState(state, to: c.connection, ticket: ticket.ticket); f.drain()
        check("production reply suppresses \(cause)", f.sent.isEmpty && c.connection.state == .cancelled)
    }
    let ticket = CraftServerFixture.ConfiguredCraftExchange(control: control)
    ticket.invalidate()
    let task = Task { _ = try? await Task.sleep(nanoseconds: 10_000_000_000) }
    ticket.attach(task)
    check("invalidated ticket cancels attached work", task.isCancelled)
}
