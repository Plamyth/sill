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
    let sentryAdmission = SentryAdmission()
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
    // PRODUCTION_WRITE_ADMISSION
}

@MainActor func craftFirstWriteAdmissionChecks(_ check: (String, Bool) -> Void) throws {
    let peer = AudioForwardingDeviceID(hex: Checks.device)!
    for mode in ["valid", "changed_sentry", "wrong_ticket", "concurrent_sentry", "inactive_without_screen_admission"] {
        let server = CraftServerFixture(), client = server.add(), other = server.add()
        let id = ObjectIdentifier(client.connection)
        server.sentryAdmission.configure(latched: false, persistenceHealthy: true)
        server.sentryAdmission.register(id, externalRoute: false)
        if mode != "inactive_without_screen_admission" { server.sentryAdmission.admit(id) }
        let inactive = server.sentryAdmission.status(for: id)!
        let control = ConfiguredCraftActionControl(requestId: UUID())
        server.onConfiguredCraftControl = { _, _, _ in }
        server.receive(Wire.encode(control), client)
        let ticket = client.configuredCraftExchange!.ticket
        if mode == "changed_sentry" { _ = server.sentryAdmission.requireProtection(explicit: true) }
        let attempting = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var wrote = false, protectionWaited = false
        let allowed = server.withConfiguredCraftWrite(to: client.connection,
            ticket: mode == "wrong_ticket" ? UUID() : ticket, deviceId: peer, inactive: inactive, requiresInactive: true) {
                if mode == "concurrent_sentry" {
                    DispatchQueue.global().async {
                        attempting.signal()
                        _ = server.sentryAdmission.requireProtection(explicit: true)
                        finished.signal()
                    }
                    precondition(attempting.wait(timeout: .now() + 1) == .success)
                    protectionWaited = finished.wait(timeout: .now() + 0.01) == .timedOut
                }
                wrote = true
            }
        if mode == "changed_sentry" || mode == "wrong_ticket" {
            check("first-write scope rejects \(mode)", !allowed && !wrote)
        } else { check("first-write scope accepts current inactive owner", allowed && wrote) }
        if mode == "concurrent_sentry" {
            check("Sentry lock held through first write", protectionWaited && finished.wait(timeout: .now() + 1) == .success && server.sentryAdmission.isRequested)
        }
        check("write admission leaves other TLS untouched", other.connection.state == .ready)
    }
}

@MainActor private final class CraftCoordinatorReplyFixture {
    struct Peer { let id: AudioForwardingDeviceID }
    let server: CraftServerFixture
    var configuredCraftRuntime: HostConfiguredCraftRuntime?
    init(server: CraftServerFixture, runtime: HostConfiguredCraftRuntime?) {
        self.server = server; configuredCraftRuntime = runtime
    }
    func forward(_ exchange: CraftServerFixture.ConfiguredCraftExchange, connection: NWConnection,
                 peer: Peer, craftSession: HostConfiguredCraftSession, current: () -> Bool) async {
        // PRODUCTION_COORDINATOR_REPLY
    }
}

@MainActor func craftCoordinatorReplyChecks(_ check: (String, Bool) -> Void) async throws {
    let peer = AudioForwardingDeviceID(hex: Checks.device)!
    let catalog = try ConfiguredCraftActionCatalog(expectedProfileId: UUID(uuidString: Checks.profile)!, expectedAssignmentSha256: Checks.hash)
    let off = try Checks.snapshot(input: false, output: false, phase: .off)
    for mode in ["wrong_request", "malformed", "timeout", "explicit_rejected", "explicit_unknown", "missing_runtime", "stale"] {
        let server = CraftServerFixture(), client = server.add(), other = server.add()
        other.route.fingerprint = Data(repeating: 0xcd, count: 32)
        let request = try ConfiguredCraftActionRequest(operationId: UUID(), deviceId: peer, catalog: catalog, issuedAt: 1793910000000)
        let control = ConfiguredCraftActionControl(requestId: UUID(), client: request)
        server.onConfiguredCraftControl = { _, _, _ in }
        server.receive(Wire.encode(control), client)
        let ticket = client.configuredCraftExchange!
        var current = true, dispatches = 0
        let transport = CraftFixtureTransport { data in
            dispatches += 1
            if mode == "timeout" { throw ProviderCallFailure.unavailable }
            if mode == "malformed" { return Data("{".utf8) }
            let command = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var reply: [String: Any] = ["op":"configuredCraftAction.reply", "schemaVersion":1,
                "requestId": mode == "wrong_request" ? UUID().uuidString.lowercased() : command["requestId"]!,
                "outcome":"rejected", "notSent":true, "reason":"unsupported"]
            if mode == "explicit_unknown" {
                reply["outcome"] = "ok"; reply.removeValue(forKey: "notSent"); reply.removeValue(forKey: "reason")
                let result = try ConfiguredCraftActionResult(outcome: .unknown, operationId: request.operationId,
                    deviceId: peer, bindingSha256: nil, invoked: false, reason: "executor-submitted-result-unknown")
                reply["actionResult"] = try JSONSerialization.jsonObject(with: Wire.encode(result))
            }
            if mode == "stale" { current = false }
            return try JSONSerialization.data(withJSONObject: reply)
        }
        let runtime = mode == "missing_runtime" ? nil : HostConfiguredCraftRuntime(open: { _ in transport })
        let coordinator = CraftCoordinatorReplyFixture(server: server, runtime: runtime)
        let session = HostConfiguredCraftSession(deviceId: peer, deviceSessionId: UUID(), pairingGeneration: UUID(),
            sentryProtected: { false }, isCurrent: { current }, currentSelection: { off }, readSnapshot: { off }, withSendAdmission: { _, write in try write() })
        await coordinator.forward(ticket, connection: client.connection, peer: .init(id: peer), craftSession: session, current: { current })
        server.drain()
        if ["wrong_request", "malformed", "stale", "missing_runtime"].contains(mode) {
            check("ambiguous \(mode) closes request TLS without fallback error", server.sent.isEmpty && client.connection.state == .cancelled)
        } else {
            check("explicit response \(mode) preserved", server.sent.count == 1 && client.connection.state == .ready)
            let state = try ConfiguredCraftActionState.decode(Data(server.sent[0].dropFirst(StreamMessage.headerLength)))
            if mode == "explicit_rejected" { check("Core notSent rejected remains distinct", state.error == nil && state.result?.outcome == .rejected && state.result?.reason == "unsupported" && state.result?.invoked == false) }
            if mode == "timeout" || mode == "explicit_unknown" { check("post-send uncertainty stays typed unknown", state.result?.outcome == .unknown && state.error == nil) }
        }
        check("other TLS connection remains ready", other.connection.state == .ready)
        check("no automatic reinvoke", dispatches == (mode == "missing_runtime" ? 0 : 1))
    }
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
