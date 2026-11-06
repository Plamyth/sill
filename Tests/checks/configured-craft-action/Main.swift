import Foundation
import StreamProtocol

@MainActor final class CraftFixtureTransport: ProviderCallTransport {
    let handler: @MainActor (Data) throws -> Data
    init(_ handler: @escaping @MainActor (Data) throws -> Data) { self.handler = handler }
    nonisolated func exchange<Request: Encodable, Reply: Decodable>(_ request: Request, as: Reply.Type,
                                                                   until deadline: TimeInterval) async throws -> Reply {
        let data = try JSONEncoder().encode(request)
        let response = try await handler(data)
        return try JSONDecoder().decode(Reply.self, from: response)
    }
    nonisolated func invalidate() {}
}

@main struct Checks {
    static var count = 0
    static func check(_ name: String, _ value: Bool) {
        count += 1
        guard value else { fatalError("FAIL: \(name)") }
    }
    static let device = String(repeating: "ab", count: 32)
    static let operation = "01234567-89ab-4cde-8fab-0123456789ab"
    static let profile = "11234567-89ab-4cde-8fab-0123456789ab"
    static let hash = String(repeating: "a", count: 64)
    static var client: String {
        """
        {"schemaVersion":1,"operation":"invoke-configured-craft-action","operationId":"\(operation)","deviceId":"\(device)","inputID":"speed.button.stop-play","trigger":"longPress","expectedProfileId":"\(profile)","expectedAssignmentSha256":"\(hash)","issuedAt":1793910000000}
        """
    }
    static func control(_ body: String? = nil) -> Data {
        Data("{\"schemaVersion\":1,\"requestId\":\"\(operation)\",\"operation\":\"invoke\",\"client\":\(body ?? client)}".utf8)
    }
    static func wireChecks() throws {
        let valid = try ConfiguredCraftActionControl.decode(control())
        check("canonical client9 accepted", valid.client?.operationId.uuidString.lowercased() == operation)
        for (name, body) in [
            ("fraction", client.replacingOccurrences(of: "1793910000000", with: "1793910000000.0")),
            ("exponent", client.replacingOccurrences(of: "1793910000000", with: "179391e7")),
            ("string time", client.replacingOccurrences(of: "1793910000000", with: "\"1793910000000\"")),
            ("negative", client.replacingOccurrences(of: "1793910000000", with: "-1")),
            ("boolean", client.replacingOccurrences(of: "1793910000000", with: "true")),
            ("unsafe integer", client.replacingOccurrences(of: "1793910000000", with: "9007199254740992")),
            ("client session", client.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"deviceSessionId\":\"x\"")),
            ("duplicate", client.replacingOccurrences(of: "\"issuedAt\":", with: "\"issuedAt\":1,\"issuedAt\":")),
            ("escaped duplicate", client.replacingOccurrences(of: "\"issuedAt\":", with: "\"issued\\u0041t\":1,\"issuedAt\":")),
            ("upper hash", client.replacingOccurrences(of: hash, with: hash.uppercased())),
            ("upper UUID", client.replacingOccurrences(of: operation, with: operation.uppercased())),
            ("arbitrary key", client.replacingOccurrences(of: "\"longPress\"", with: "\"keyCode9\""))
        ] { check("reject \(name)", (try? ConfiguredCraftActionControl.decode(control(body))) == nil) }
        check("control 4096 cap", (try? ConfiguredCraftActionControl.decode(Data(repeating: 32, count: 4097))) == nil)
        check("wire directions", StreamMessage.clientPayloadLimit(for: .configuredCraftActionControl) == 4096 &&
            StreamMessage.clientPayloadLimit(for: .configuredCraftActionState) == -1 &&
            StreamMessage.hostPayloadLimit(for: .configuredCraftActionState) == 16384 &&
            StreamMessage.hostPayloadLimit(for: .configuredCraftActionControl) == -1)
        check("reserved kinds preserved", StreamMessageKind.configuredCraftActionControl.rawValue == 225 &&
            StreamMessageKind.configuredCraftActionState.rawValue == 226 &&
            StreamMessageKind.providerCallControl.rawValue == 221 && StreamMessageKind.providerCallState.rawValue == 222)
        let result = try ConfiguredCraftActionResult(outcome: .invoked, operationId: UUID(uuidString: operation)!,
            deviceId: AudioForwardingDeviceID(hex: device)!, bindingSha256: hash, invoked: true)
        let state = try ConfiguredCraftActionState(control: valid, deviceId: result.deviceId, result: result)
        check("state round trip", try ConfiguredCraftActionState.decode(Wire.encode(state)).matches(valid))
        var object = try JSONSerialization.jsonObject(with: Wire.encode(state)) as! [String: Any]
        object["catalog"] = [:]
        check("result cannot carry catalog", (try? ConfiguredCraftActionState.decode(JSONSerialization.data(withJSONObject: object))) == nil)
        let resultJSON = try JSONSerialization.jsonObject(with: Wire.encode(result)) as! [String: Any]
        check("exact result6", Set(resultJSON.keys) == ["outcome", "operationId", "deviceId", "bindingSha256", "invoked", "effectConfirmed"] && resultJSON["effectConfirmed"] as? Bool == false)
        for extra in ["error", "catalog", "deviceSessionId"] {
            var wrong = try JSONSerialization.jsonObject(with: Wire.encode(state)) as! [String: Any]
            wrong[extra] = "unavailable"
            check("state refuses extra \(extra)", (try? ConfiguredCraftActionState.decode(JSONSerialization.data(withJSONObject: wrong))) == nil)
        }
        var unconfirmed = resultJSON; unconfirmed["effectConfirmed"] = true
        check("effect never confirmed", (try? JSONDecoder().decode(ConfiguredCraftActionResult.self,
            from: JSONSerialization.data(withJSONObject: unconfirmed))) == nil)
        var missing = resultJSON; missing.removeValue(forKey: "bindingSha256")
        check("binding null is required", (try? JSONDecoder().decode(ConfiguredCraftActionResult.self,
            from: JSONSerialization.data(withJSONObject: missing))) == nil)
        let catalog = try ConfiguredCraftActionCatalog(expectedProfileId: UUID(uuidString: profile)!, expectedAssignmentSha256: hash)
        let catalogJSON = try JSONSerialization.jsonObject(with: Wire.encode(catalog)) as! [String: Any]
        check("catalog exact6", Set(catalogJSON.keys) == ["schemaVersion", "supported", "inputID", "trigger", "expectedProfileId", "expectedAssignmentSha256"])
        var unsupported = catalogJSON; unsupported["supported"] = false
        check("unsupported requires error union", (try? JSONDecoder().decode(ConfiguredCraftActionCatalog.self,
            from: JSONSerialization.data(withJSONObject: unsupported))) == nil)
        let query = ConfiguredCraftActionControl(requestId: UUID(), operationId: UUID(uuidString: operation)!)
        check("query exact4", (try JSONSerialization.jsonObject(with: Wire.encode(query)) as! [String: Any]).count == 4)
        let requestJSON = try JSONSerialization.jsonObject(with: Wire.encode(valid.client!)) as! [String: Any]
        check("encoded client exact9 without session", requestJSON.count == 9 && requestJSON["operation"] as? String == "invoke-configured-craft-action" && requestJSON["deviceSessionId"] == nil)
        var coreReply: [String: Any] = ["op":"configuredCraftAction.reply", "schemaVersion":1,
            "requestId":operation, "outcome":"ok", "catalog":catalogJSON]
        check("local catalog success exact", (try? JSONDecoder().decode(HostConfiguredCraftReply.self,
            from: JSONSerialization.data(withJSONObject: coreReply)))?.catalog == catalog)
        for key in ["notSent", "error", "reason", "actionResult"] {
            var wrong = coreReply; wrong[key] = key == "notSent" ? true : "extra"
            check("local success forbids \(key)", (try? JSONDecoder().decode(HostConfiguredCraftReply.self,
                from: JSONSerialization.data(withJSONObject: wrong))) == nil)
        }
        coreReply.removeValue(forKey: "catalog"); coreReply["reason"] = "unavailable"
        for (outcome, notSent) in [("rejected", true), ("unknown", false)] {
            coreReply["outcome"] = outcome; coreReply["notSent"] = notSent
            check("local \(outcome) exact", (try? JSONDecoder().decode(HostConfiguredCraftReply.self,
                from: JSONSerialization.data(withJSONObject: coreReply))) != nil)
            coreReply["notSent"] = !notSent
            check("local \(outcome) notSent fixed", (try? JSONDecoder().decode(HostConfiguredCraftReply.self,
                from: JSONSerialization.data(withJSONObject: coreReply))) == nil)
        }
        var list = WindowList(macName: "fixture", windows: [], active: .desktop)
        check("old catalog omits capability", (try JSONSerialization.jsonObject(with: Wire.encode(list)) as! [String: Any])["configuredCraftActions"] == nil)
        list.configuredCraftActions = 1
        check("capability v1 round trip", Wire.decode(WindowList.self, from: Wire.encode(list))?.configuredCraftActions == 1)
        check("state 16384 cap", (try? ConfiguredCraftActionState.decode(Data(repeating: 32, count: 16385))) == nil)
    }
    static func snapshot(input: Bool, output: Bool, phase: AudioForwardingBinding.Phase,
                         deviceId: AudioForwardingDeviceID? = nil, revision: UInt64 = 1) throws -> AudioForwardingSnapshot {
        let peer = deviceId ?? AudioForwardingDeviceID(hex: device)!
        let generation = UUID(uuidString: operation)!
        let configuration = try AudioForwardingConfiguration(controllerBootId: generation, privacyGeneration: generation,
            registryRevision: .init(1), members: [
                .init(participantId: "native.sill", bootId: generation),
                .init(participantId: "s23.audio.relay", bootId: generation)])
        let intent = try AudioForwardingSnapshot.Intent(pairedDeviceId: peer, intentId: generation,
            intentRevision: .init(1), intentGeneration: generation, inputDesired: input, outputDesired: output)
        let binding = AudioForwardingBinding(pairedDeviceId: peer, intentGeneration: generation, bindingEpoch: generation,
            transportId: generation, transportKind: .native, operationId: generation, phase: phase, configuration: configuration)
        return try AudioForwardingSnapshot(revision: .init(revision), intent: intent, binding: binding)
    }
    @MainActor static func runtimeChecks() async throws {
        enum FixtureFailure: Error { case timeout }
        let peer = AudioForwardingDeviceID(hex: device)!, other = AudioForwardingDeviceID(hex: String(repeating: "cd", count: 32))!
        let catalog = try ConfiguredCraftActionCatalog(expectedProfileId: UUID(uuidString: profile)!, expectedAssignmentSha256: hash)
        let off = try snapshot(input: false, output: false, phase: .off)
        check("explicit both OFF eligible without active call", HostConfiguredCraftRuntime.eligible(off, deviceId: peer))
        check("active input only eligible", HostConfiguredCraftRuntime.eligible(try snapshot(input: true, output: false, phase: .active), deviceId: peer))
        check("other device selection preserved and refused", !HostConfiguredCraftRuntime.eligible(try snapshot(input: true, output: true, phase: .active, deviceId: other), deviceId: peer))
        check("quiescing refused", !HostConfiguredCraftRuntime.eligible(try snapshot(input: true, output: true, phase: .quiescing), deviceId: peer))
        var sends = 0, queries = 0, reads = 0, current = true, fail = false, invalidateAfter = false
        var observed = off
        let generation = UUID(), sessionID = UUID()
        var opened = false
        let socket = CraftFixtureTransport { data in
            let command = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let op = command["op"] as! String
            let base: Set<String> = ["op", "schemaVersion", "requestId", "deviceId", "deviceSessionId", "acceptedAt"]
            let expected = base.union(op.hasSuffix(".invoke") ? ["client", "sentryState"] : op.hasSuffix(".query") ? ["operationId"] : [])
            check("local command exact union", Set(command.keys) == expected)
            check("trusted identity separate from client", command["deviceId"] as? String == peer.hex &&
                command["deviceSessionId"] as? String == sessionID.uuidString.lowercased() &&
                command["acceptedAt"] as? Int64 == 1793910000010 && opened)
            var reply: [String: Any] = ["op":"configuredCraftAction.reply", "schemaVersion":1,
                "requestId":command["requestId"]!, "outcome":"ok"]
            if op.hasSuffix(".catalog") {
                reply["catalog"] = try JSONSerialization.jsonObject(with: Wire.encode(catalog))
            } else {
                let id: UUID
                let outcome: ConfiguredCraftActionResult.Outcome
                if op.hasSuffix(".invoke") {
                    let body = command["client"] as! [String: Any]
                    check("local sentry inactive explicit", command["sentryState"] as? String == "inactive" && body.count == 9 && body["deviceSessionId"] == nil)
                    id = UUID(uuidString: body["operationId"] as! String)!
                    sends += 1; outcome = .invoked
                    if fail { throw FixtureFailure.timeout }
                    if invalidateAfter { current = false }
                } else {
                    id = UUID(uuidString: command["operationId"] as! String)!
                    queries += 1; outcome = .unknown
                }
                reply["actionResult"] = try JSONSerialization.jsonObject(with: Wire.encode(ConfiguredCraftActionResult(
                    outcome: outcome, operationId: id, deviceId: peer,
                    bindingSha256: outcome == .invoked ? hash : nil, invoked: outcome == .invoked)))
            }
            return try JSONSerialization.data(withJSONObject: reply)
        }
        let runtime = HostConfiguredCraftRuntime(open: { _ in opened = true; return socket }, now: {
            check("acceptedAt stamped after peer socket open", opened)
            return 1793910000010
        })
        let session = HostConfiguredCraftSession(deviceId: peer, deviceSessionId: sessionID, pairingGeneration: generation,
            sentryProtected: { false }, isCurrent: { current }, readSnapshot: { reads += 1; return observed })
        let request = try ConfiguredCraftActionControl.decode(control())
        let protected = HostConfiguredCraftSession(deviceId: peer, deviceSessionId: sessionID, pairingGeneration: generation,
            sentryProtected: { true }, isCurrent: { true }, readSnapshot: { reads += 1; return observed })
        check("Sentry protected closes without audio or input", await runtime.exchange(request, session: protected)?.error == "sentry_protected" && sends == 0 && reads == 0)
        let answer = await runtime.exchange(request, session: session)
        check("both OFF invokes configured action", answer?.result?.outcome == .invoked && sends == 1 && reads == 3)
        _ = await runtime.exchange(request, session: session)
        check("same operation reuses result", sends == 1)
        check("selection remains OFF", observed.intent?.inputDesired == false && observed.intent?.outputDesired == false)
        fail = true
        let uncertainRequest = ConfiguredCraftActionControl(requestId: UUID(), client: try ConfiguredCraftActionRequest(
            operationId: UUID(), deviceId: peer, catalog: catalog, issuedAt: 1793910000000))
        let uncertain = await runtime.exchange(uncertainRequest, session: session)
        check("timeout maps unknown without retry", uncertain?.result?.outcome == .unknown && uncertain?.result?.effectConfirmed == false && sends == 2)
        _ = await runtime.exchange(uncertainRequest, session: session)
        check("unknown explicit repeat uses read-only query", sends == 2 && queries == 1)
        let query = ConfiguredCraftActionControl(requestId: UUID(), operationId: request.client!.operationId)
        _ = await runtime.exchange(query, session: session); _ = await runtime.exchange(query, session: session)
        check("read-only query does not invoke or cache unknown", queries == 3 && sends == 2)
        fail = false; observed = try snapshot(input: true, output: true, phase: .active, deviceId: other)
        let refused = ConfiguredCraftActionControl(requestId: UUID(), client: try ConfiguredCraftActionRequest(
            operationId: UUID(), deviceId: peer, catalog: catalog, issuedAt: 1793910000000))
        check("wrong selection does not dispatch", await runtime.exchange(refused, session: session)?.result?.outcome == .rejected && sends == 2)
        observed = off; invalidateAfter = true
        let late = ConfiguredCraftActionControl(requestId: UUID(), client: try ConfiguredCraftActionRequest(
            operationId: UUID(), deviceId: peer, catalog: catalog, issuedAt: 1793910000000))
        check("stale callback suppressed after sender", await runtime.exchange(late, session: session) == nil && sends == 3)
        check("stale session cannot query", await runtime.exchange(query, session: session) == nil && queries == 3)
        current = true; invalidateAfter = false
        var protectedNow = false, dispatches = 0
        let protectedSession = HostConfiguredCraftSession(deviceId: peer, deviceSessionId: sessionID, pairingGeneration: generation,
            sentryProtected: { protectedNow }, isCurrent: { true }, readSnapshot: { off })
        let blockedSocket = CraftFixtureTransport { _ in dispatches += 1; throw FixtureFailure.timeout }
        let switching = HostConfiguredCraftRuntime(open: { _ in protectedNow = true; return blockedSocket })
        check("Sentry changes during socket open block sender", await switching.exchange(request, session: protectedSession) == nil && dispatches == 0)
        let drift = HostConfiguredCraftRuntime(open: { _ in observed = try snapshot(input: false, output: false, phase: .off, revision: 2); return blockedSocket })
        check("fresh audio changes during open block sender", await drift.exchange(request, session: session) == nil && dispatches == 0)
        observed = off
        let wrongIDSocket = CraftFixtureTransport { _ in
            try JSONSerialization.data(withJSONObject: ["op":"configuredCraftAction.reply", "schemaVersion":1,
                "requestId":UUID().uuidString.lowercased(), "outcome":"rejected", "notSent":true, "reason":"unsupported"])
        }
        let wrongID = HostConfiguredCraftRuntime(open: { _ in wrongIDSocket })
        check("wrong Core requestId produces no external response", await wrongID.exchange(query, session: session) == nil)
        for _ in 0..<130 {
            let fresh = ConfiguredCraftActionControl(requestId: UUID(), client: try ConfiguredCraftActionRequest(
                operationId: UUID(), deviceId: peer, catalog: catalog, issuedAt: 1793910000000))
            check("bounded cache never permanently fills", await runtime.exchange(fresh, session: session)?.result?.outcome == .invoked)
        }
        var release: CheckedContinuation<any ProviderCallTransport, Never>?
        let blocked = HostConfiguredCraftRuntime(open: { _ in await withCheckedContinuation { release = $0 } },
                                                 now: { 1793910000010 })
        let first = Task { await blocked.exchange(request, session: session) }
        for _ in 0..<100 where release == nil { await Task.yield() }
        check("first command reaches socket open", release != nil)
        let parallel = ConfiguredCraftActionControl(requestId: UUID(), client: try ConfiguredCraftActionRequest(
            operationId: UUID(), deviceId: peer, catalog: catalog, issuedAt: 1793910000000))
        check("single invocation while open awaits", await blocked.exchange(parallel, session: session)?.error == "busy")
        release!.resume(returning: socket)
        _ = await first.value
    }
    @MainActor static func main() async throws {
        try wireChecks()
        try await runtimeChecks()
        try await reconnectChecks()
        try await craftServerChecks(check)
        print("configured-craft \(count) checks passed; actual effects=0")
    }

    @MainActor static func reconnectChecks() async throws {
        let peer = AudioForwardingDeviceID(hex: device)!, other = AudioForwardingDeviceID(hex: String(repeating: "cd", count: 32))!
        let catalog = try ConfiguredCraftActionCatalog(expectedProfileId: UUID(uuidString: profile)!, expectedAssignmentSha256: hash)
        let request = try ConfiguredCraftActionRequest(operationId: UUID(), deviceId: peer, catalog: catalog, issuedAt: 1793910000000)
        let original = ConfiguredCraftActionControl(requestId: UUID(), client: request)
        let query = ConfiguredCraftActionControl(requestId: UUID(), operationId: request.operationId)
        let generation = UUID(), firstSession = UUID(), nextSession = UUID()
        let off = try snapshot(input: false, output: false, phase: .off)
        var oldCurrent = true, invokes = 0, queries = 0, journalWrites = 0
        var journal: ConfiguredCraftActionResult?
        var querySessions: [String] = []
        let core = CraftFixtureTransport { data in
            let command = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var reply: [String: Any] = ["op":"configuredCraftAction.reply", "schemaVersion":1,
                "requestId":command["requestId"]!, "outcome":"ok"]
            if command["op"] as? String == "configuredCraftAction.invoke" {
                invokes += 1
                if journal == nil {
                    journalWrites += 1
                    journal = try ConfiguredCraftActionResult(outcome: .invoked, operationId: request.operationId,
                        deviceId: peer, bindingSha256: hash, invoked: true)
                }
            } else {
                queries += 1; querySessions.append(command["deviceSessionId"] as! String)
                if command["deviceId"] as? String != peer.hex {
                    reply["outcome"] = "rejected"; reply["notSent"] = true; reply["reason"] = "operation_owner_mismatch"
                    return try JSONSerialization.data(withJSONObject: reply)
                }
                check("query keeps original operationId", command["operationId"] as? String == request.operationId.uuidString.lowercased())
            }
            reply["actionResult"] = try JSONSerialization.jsonObject(with: Wire.encode(journal!))
            return try JSONSerialization.data(withJSONObject: reply)
        }
        let runtime = HostConfiguredCraftRuntime(open: { _ in core })
        let first = HostConfiguredCraftSession(deviceId: peer, deviceSessionId: firstSession, pairingGeneration: generation,
            sentryProtected: { false }, isCurrent: { oldCurrent }, readSnapshot: { off })
        check("original invoke recorded once", await runtime.exchange(original, session: first)?.result?.outcome == .invoked && invokes == 1 && journalWrites == 1)
        oldCurrent = false
        let connected = HostConfiguredCraftSession(deviceId: peer, deviceSessionId: nextSession, pairingGeneration: generation,
            sentryProtected: { false }, isCurrent: { true }, readSnapshot: { nil })
        let recovered = await runtime.exchange(query, session: connected)
        check("reconnect new server session recovers durable result", recovered?.result == journal && queries == 1 && invokes == 1)
        check("query carries current new session only", querySessions == [nextSession.uuidString.lowercased()])
        check("old connection cannot query", await runtime.exchange(query, session: first) == nil && queries == 1)
        let restarted = HostConfiguredCraftRuntime(open: { _ in core })
        check("Host cache absent still query only recovery", await restarted.exchange(query, session: connected)?.result == journal && queries == 2 && invokes == 1)
        let repaired = HostConfiguredCraftSession(deviceId: peer, deviceSessionId: UUID(), pairingGeneration: UUID(),
            sentryProtected: { false }, isCurrent: { true }, readSnapshot: { nil })
        check("cached operation rejects changed pairing identity", await runtime.exchange(query, session: repaired)?.error == "operation_owner_mismatch" && queries == 2)
        let foreign = HostConfiguredCraftSession(deviceId: other, deviceSessionId: UUID(), pairingGeneration: UUID(),
            sentryProtected: { false }, isCurrent: { true }, readSnapshot: { nil })
        check("Host cached owner rejects other device", await runtime.exchange(query, session: foreign)?.error == "operation_owner_mismatch" && queries == 2)
        check("cache absent defers durable owner check to Core", await restarted.exchange(query, session: foreign)?.error == "operation_owner_mismatch" && queries == 3)
        check("queries never rewrite journal or invoke", journalWrites == 1 && invokes == 1)
    }
}
