import Foundation
import StreamProtocol

@MainActor func craftOutcomeChecks(_ check: (String, Bool) -> Void) async throws {
    let peer = AudioForwardingDeviceID(hex: Checks.device)!
    let catalog = try ConfiguredCraftActionCatalog(expectedProfileId: UUID(uuidString: Checks.profile)!, expectedAssignmentSha256: Checks.hash)
    let off = try Checks.snapshot(input: false, output: false, phase: .off)
    let pairing = UUID()
    func session(_ id: UUID = UUID(), deny: Bool = false) -> HostConfiguredCraftSession {
        .init(deviceId: peer, deviceSessionId: id, pairingGeneration: pairing,
            sentryProtected: { false }, isCurrent: { true }, currentSelection: { off }, readSnapshot: { off },
            withSendAdmission: { _, write in
                if deny { throw ProviderCallFailure.superseded }
                try write()
            })
    }
    func invoke() throws -> ConfiguredCraftActionControl {
        .init(requestId: UUID(), client: try .init(operationId: UUID(), deviceId: peer, catalog: catalog, issuedAt: 1793910000000))
    }
    func reply(_ data: Data, outcome: String, result: ConfiguredCraftActionResult? = nil) throws -> Data {
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var object: [String: Any] = ["op":"configuredCraftAction.reply", "schemaVersion":1,
            "requestId":body["requestId"]!, "outcome":outcome]
        if let result { object["actionResult"] = try JSONSerialization.jsonObject(with: Wire.encode(result)) }
        else { object["notSent"] = outcome == "rejected"; object["reason"] = "operation_not_found" }
        return try JSONSerialization.data(withJSONObject: object)
    }
    var failures = [String]()
    func expect(_ name: String, _ value: Bool) {
        print("\(value ? "PASS" : "FAIL") OUTCOME \(name)")
        if !value { failures.append(name) }
    }
    for mode in ["open_failure", "admission_failure", "initial_core_rejected"] {
        var writes = 0, opens = 0
        let transport = CraftFixtureTransport { data in
            writes += 1
            return try reply(data, outcome: "rejected")
        }
        let runtime = HostConfiguredCraftRuntime(open: { _ in
            opens += 1
            if mode == "open_failure" { throw ProviderCallFailure.unavailable }
            return transport
        })
        let request = try invoke()
        let response = await runtime.exchange(request, session: session(deny: mode == "admission_failure"))
        expect("\(mode) is definite typed rejected", response?.error == nil && response?.result?.outcome == .rejected && response?.result?.invoked == false && response?.result?.bindingSha256 == nil)
        _ = await runtime.exchange(request, session: session())
        expect("\(mode) terminal replay does not open/reinvoke/query", opens == 1 && writes == (mode == "initial_core_rejected" ? 1 : 0))
    }
    for mode in ["rejected", "timeout", "unknown"] {
        var invokes = 0, queries = 0
        let request = try invoke()
        let known = try ConfiguredCraftActionResult(outcome: .unknown, operationId: request.client!.operationId,
            deviceId: peer, bindingSha256: Checks.hash, invoked: true, reason: "executor-submitted-result-unknown")
        let transport = CraftFixtureTransport { data in
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if body["op"] as? String == "configuredCraftAction.invoke" {
                invokes += 1; return try reply(data, outcome: "ok", result: known)
            }
            queries += 1
            if mode == "timeout" { throw ProviderCallFailure.expired }
            return try reply(data, outcome: mode)
        }
        let runtime = HostConfiguredCraftRuntime(open: { _ in transport })
        _ = await runtime.exchange(request, session: session())
        let internalQuery = await runtime.exchange(request, session: session())
        let explicitQuery = await runtime.exchange(ConfiguredCraftActionControl(requestId: UUID(), operationId: request.client!.operationId), session: session())
        expect("\(mode) internal query preserves original UNKNOWN/known invoked", internalQuery?.result == known)
        expect("\(mode) reconnect explicit query preserves original UNKNOWN/known invoked", explicitQuery?.result == known && queries == 2 && invokes == 1)
    }
    // A cache miss or reconnect cannot turn a query rejection into proof about the original invoke.
    let absent = HostConfiguredCraftRuntime(open: { _ in CraftFixtureTransport { try reply($0, outcome: "rejected") } })
    let query = ConfiguredCraftActionControl(requestId: UUID(), operationId: UUID())
    let missed = await absent.exchange(query, session: session())
    expect("cache-miss query notSent never rejects original operation", missed?.result?.outcome != .rejected)
    var live = true, supersededOpens = 0
    let supersededRequest = try invoke()
    let supersededRuntime = HostConfiguredCraftRuntime(open: { _ in
        supersededOpens += 1; live = false
        return CraftFixtureTransport { try reply($0, outcome: "rejected") }
    })
    let disconnected = HostConfiguredCraftSession(deviceId: peer, deviceSessionId: UUID(), pairingGeneration: pairing,
        sentryProtected: { false }, isCurrent: { live }, currentSelection: { off }, readSnapshot: { off },
        withSendAdmission: { _, write in try write() })
    let oldConnection = await supersededRuntime.exchange(supersededRequest, session: disconnected)
    let recoveredRejection = await supersededRuntime.exchange(supersededRequest, session: session())
    expect("zero-byte superseded connection closes but reconnect retains definite rejection", oldConnection == nil && recoveredRejection?.result?.outcome == .rejected && supersededOpens == 1)
    let concurrentRequest = try invoke()
    let earlier = try ConfiguredCraftActionResult(outcome: .unknown, operationId: concurrentRequest.client!.operationId,
        deviceId: peer, bindingSha256: nil, invoked: false, reason: "invocation_uncertain")
    let later = try ConfiguredCraftActionResult(outcome: .unknown, operationId: concurrentRequest.client!.operationId,
        deviceId: peer, bindingSha256: Checks.hash, invoked: true, reason: "executor-submitted-result-unknown")
    var openCount = 0
    var delayed: CheckedContinuation<any ProviderCallTransport, Never>?
    let concurrent = HostConfiguredCraftRuntime(open: { _ in
        openCount += 1
        if openCount == 2 { return await withCheckedContinuation { delayed = $0 } }
        return CraftFixtureTransport { data in
            try reply(data, outcome: "ok", result: openCount == 1 ? earlier : later)
        }
    })
    _ = await concurrent.exchange(concurrentRequest, session: session())
    let concurrentQuery = ConfiguredCraftActionControl(requestId: UUID(), operationId: concurrentRequest.client!.operationId)
    let waiting = Task { await concurrent.exchange(concurrentQuery, session: session()) }
    for _ in 0..<100 where delayed == nil { await Task.yield() }
    expect("concurrent query reaches bounded open seam", delayed != nil)
    _ = await concurrent.exchange(concurrentQuery, session: session())
    delayed?.resume(returning: CraftFixtureTransport { try reply($0, outcome: "rejected") })
    expect("late query failure cannot overwrite newer known invoked", await waiting.value?.result == later)
    var originalInvokes = 0, effects = 0, queryRejected = true
    let original = try invoke()
    let durable = try ConfiguredCraftActionResult(outcome: .unknown, operationId: original.client!.operationId,
        deviceId: peer, bindingSha256: Checks.hash, invoked: true, reason: "prior-operation-result-unknown")
    let durableCore = CraftFixtureTransport { data in
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if body["op"] as? String == "configuredCraftAction.query" {
            return try reply(data, outcome: queryRejected ? "rejected" : "ok", result: queryRejected ? nil : durable)
        }
        let client = body["client"] as! [String: Any]
        if client["operationId"] as? String == original.client!.operationId.uuidString.lowercased() {
            originalInvokes += 1
            if effects == 0 { effects += 1 }
            return try reply(data, outcome: "ok", result: durable)
        }
        return try reply(data, outcome: "rejected")
    }
    let evicted = HostConfiguredCraftRuntime(open: { _ in durableCore })
    _ = await evicted.exchange(original, session: session())
    for _ in 0..<130 { _ = await evicted.exchange(try invoke(), session: session()) }
    let originalQuery = ConfiguredCraftActionControl(requestId: UUID(), operationId: original.client!.operationId)
    let unavailable = await evicted.exchange(originalQuery, session: session())
    expect("evicted UNKNOWN query rejection supplies no false rejected/false invoked result", unavailable?.result == nil && unavailable?.error == "operation_not_found" && originalInvokes == 1)
    queryRejected = false
    let restored = await evicted.exchange(originalQuery, session: session())
    expect("evicted same ID reconnect reads durable UNKNOWN without reinvoke", restored?.result == durable && originalInvokes == 1)
    let repeated = await evicted.exchange(original, session: session())
    expect("explicit same-ID replay after eviction uses Core durable once result", repeated?.result == durable && originalInvokes == 2 && effects == 1)
    if !failures.isEmpty { exit(1) }
    check("typed outcomes regression group", true)
}
