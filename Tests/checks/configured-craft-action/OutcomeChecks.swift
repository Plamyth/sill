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
    for wasInvoked in [false, true] {
        let initial = try invoke()
        let uncertain = try ConfiguredCraftActionResult(outcome: .unknown, operationId: initial.client!.operationId,
            deviceId: peer, bindingSha256: wasInvoked ? Checks.hash : nil, invoked: wasInvoked, reason: "prior_unknown")
        let terminal = try ConfiguredCraftActionResult(outcome: .rejected, operationId: initial.client!.operationId,
            deviceId: peer, bindingSha256: nil, invoked: false, reason: "not_dispatched")
        let core = CraftFixtureTransport { data in
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try reply(data, outcome: "ok", result: body["op"] as? String == "configuredCraftAction.invoke" ? uncertain : terminal)
        }
        let runtime = HostConfiguredCraftRuntime(open: { _ in core })
        _ = await runtime.exchange(initial, session: session())
        let response = await runtime.exchange(ConfiguredCraftActionControl(requestId: UUID(), operationId: initial.client!.operationId), session: session())
        expect("Core ok query typed rejected terminates UNKNOWN unless known invoked=\(wasInvoked)", response?.result == (wasInvoked ? uncertain : terminal))
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


@MainActor func craftCacheCASChecks() async throws {
    let a = AudioForwardingDeviceID(hex: Checks.device)!
    let other = AudioForwardingDeviceID(hex: String(repeating: "cd", count: 32))!
    let catalog = try ConfiguredCraftActionCatalog(expectedProfileId: UUID(uuidString: Checks.profile)!, expectedAssignmentSha256: Checks.hash)
    let off = try Checks.snapshot(input: false, output: false, phase: .off)
    var failures = 0, cases = 0
    for internalQuery in [false, true] {
        for replacement in ["other_device_unknown", "other_device_ok", "other_request", "other_pairing", "same_identity_reinserted"] {
            cases += 1
            let pairingA = UUID(), operationId = UUID()
            let original = ConfiguredCraftActionControl(requestId: UUID(), client: try .init(operationId: operationId,
                deviceId: a, catalog: catalog, issuedAt: 1793910000000))
            let b = replacement.hasPrefix("other_device") ? other : a
            let pairingB = replacement == "other_pairing" || b != a ? UUID() : pairingA
            let requestB = replacement == "other_request" || b != a
                ? try ConfiguredCraftActionRequest(operationId: operationId, deviceId: b, catalog: catalog, issuedAt: 1793910000001)
                : original.client!
            let replacementControl = ConfiguredCraftActionControl(requestId: UUID(), client: requestB)
            func session(_ device: AudioForwardingDeviceID, _ pairing: UUID, protected: Bool = false) -> HostConfiguredCraftSession {
                .init(deviceId: device, deviceSessionId: UUID(), pairingGeneration: pairing,
                    sentryProtected: { protected }, isCurrent: { true }, currentSelection: { off }, readSnapshot: { off },
                    withSendAdmission: { _, write in try write() })
            }
            var release: CheckedContinuation<Void, Never>?
            var queryCalls = 0, invokeCalls = 0
            let originalUnknown = try ConfiguredCraftActionResult(outcome: .unknown, operationId: operationId,
                deviceId: a, bindingSha256: Checks.hash, invoked: false, reason: "original_unknown")
            let transport = CraftFixtureTransport { data in
                let command = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                var reply: [String: Any] = ["op":"configuredCraftAction.reply", "schemaVersion":1,
                    "requestId":command["requestId"]!, "outcome":"ok"]
                if command["op"] as? String == "configuredCraftAction.invoke" {
                    invokeCalls += 1
                    reply["actionResult"] = try JSONSerialization.jsonObject(with: Wire.encode(originalUnknown))
                } else {
                    queryCalls += 1
                    if queryCalls == 1 { await withCheckedContinuation { release = $0 } }
                    if replacement.hasSuffix("unknown") {
                        reply["outcome"] = "unknown"; reply["notSent"] = false; reply["reason"] = "unavailable"
                    } else { reply["actionResult"] = try JSONSerialization.jsonObject(with: Wire.encode(originalUnknown)) }
                }
                return try JSONSerialization.data(withJSONObject: reply)
            }
            var initialOpen = true
            let runtime = HostConfiguredCraftRuntime(open: { _ in
                if initialOpen { initialOpen = false; if !internalQuery { throw ProviderCallFailure.unavailable } }
                return transport
            })
            let originalResult = await runtime.exchange(original, session: session(a, pairingA))
            let query = internalQuery ? original : ConfiguredCraftActionControl(requestId: UUID(), operationId: operationId)
            let waiting = Task { await runtime.exchange(query, session: session(a, pairingA)) }
            for _ in 0..<1000 where release == nil { await Task.yield() }
            guard release != nil else { fatalError("CAS fixture failed to reach query response wait") }
            // Exactly 128 unrelated terminal outcomes evict A while its read-only query awaits.
            for _ in 0..<128 {
                let filler = ConfiguredCraftActionControl(requestId: UUID(), client: try .init(operationId: UUID(),
                    deviceId: a, catalog: catalog, issuedAt: 1793910000000))
                _ = await runtime.exchange(filler, session: session(a, pairingA, protected: true))
            }
            _ = await runtime.exchange(replacementControl, session: session(b, pairingB, protected: true))
            let before = await runtime.exchange(replacementControl, session: session(b, pairingB))
            release!.resume()
            let late = await waiting.value
            let after = await runtime.exchange(replacementControl, session: session(b, pairingB))
            let passed = originalResult?.result != nil && before?.result?.outcome == .rejected && after?.result == before?.result &&
                late?.deviceId == a && (!replacement.hasSuffix("unknown") || late?.result == originalResult?.result) && queryCalls == 1 && invokeCalls == (internalQuery ? 1 : 0)
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL") CACHE_CAS \(internalQuery ? "internal" : "explicit")/\(replacement) original=\(originalResult?.result?.outcome.rawValue ?? "nil") Bbefore=\(before?.result?.outcome.rawValue ?? "nil") late=\(late?.result?.outcome.rawValue ?? "nil") Bafter=\(after?.result?.outcome.rawValue ?? "nil") queries=\(queryCalls) invokes=\(invokeCalls)")
        }
    }
    print("CACHE_CAS cases=\(cases) failures=\(failures); unchanged regression counts not added; actual Core/Craft effects=0")
    if failures != 0 { exit(1) }
}
