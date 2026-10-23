import Foundation
import CryptoKit
import StreamProtocol

enum CheckError: Error { case setup(String) }

@MainActor final class Core: ProviderCallTransport, @unchecked Sendable {
    let request: ProviderCallRequest
    let fixture: Fixture
    let challenge: [String: Any]
    var corruptStage = "", corruptField = "", corruptValue: Any = ""
    var hold = "", waiting = false, resume = false
    var calls: [String] = [], effects = 0, signatures = 0
    var onCall: ((String) -> Void)?
    var observedProof: [String: Any] = [:]
    init(_ request: ProviderCallRequest, _ fixture: Fixture, ttl: Int = 1500) throws {
        self.request = request; self.fixture = fixture
        let target: [String: Any] = ["profileId": "codex-control-room-chatgpt-dots", "leafId": "leaf-a",
            "guestId": 17, "url": "https://chatgpt.com/dots/leaf-a", "timeOrigin": 1_700_000_000_123.5]
        let typed: ProviderCallTarget = try decode(target)
        challenge = ["schemaVersion": 1, "challenge": Base64URL.encode(Data(repeating: 7, count: 32)),
            "coreGeneration": UUID().uuidString.lowercased(), "requestId": request.requestId.uuidString.lowercased(),
            "target": target, "targetHash": try typed.hash(), "guestNowMs": 42.5, "remainingMilliseconds": ttl]
    }
    nonisolated func invalidate() { }
    nonisolated func exchange<Request: Encodable, Reply: Decodable>(_ request: Request, as: Reply.Type,
                                                                  until deadline: TimeInterval) async throws -> Reply {
        let bytes = try JSONEncoder().encode(request)
        let reply = try await respond(bytes, deadline)
        return try JSONDecoder().decode(Reply.self, from: reply)
    }
    func respond(_ bytes: Data, _ deadline: TimeInterval) async throws -> Data {
        let input = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let op = input["op"] as! String
        calls.append(op); onCall?(op)
        if op == hold {
            waiting = true
            while !resume { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProviderCallFailure.expired }
        var reply = challenge.filter { !["target", "guestNowMs", "remainingMilliseconds"].contains($0.key) }
        reply["requestDigest"] = self.request.digest
        switch op {
        case "provider.challenge": reply = challenge
        case "provider.identity", "provider.dispatch":
            let envelope = input["envelope"] as! [String: String]
            let payload = Base64URL.decode(envelope["payload"]!)!
            let spki = Base64URL.decode(envelope["publicSPKI"]!)!
            let signature = try P256.Signing.ECDSASignature(derRepresentation: Base64URL.decode(envelope["signature"]!)!)
            let key = try P256.Signing.PublicKey(x963Representation: spki.suffix(65))
            let purpose = op == "provider.identity" ? "ccr-provider-identity-v1" : "ccr-provider-dispatch-v1"
            guard key.isValidSignature(signature, for: Data((purpose + "\0").utf8) + payload) else {
                throw CheckError.setup("actual signer signature")
            }
            signatures += 1
            if op == "provider.dispatch" {
                observedProof = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
                effects += 1
                reply["state"] = "activated"; reply["reason"] = "fixture_delivered"
            } else { reply["state"] = "identity_verified" }
        case "provider.result":
            guard fixture.events(1).contains("\"releaseOutcome\":\"dispatched\",\"remainingMilliseconds\":0") else {
                throw CheckError.setup("result before exact Node release")
            }
            let result = try ProviderCallResult(requestId: self.request.requestId,
                status: self.request.action == .start ? .started : .stopped, reason: "fixture_readback",
                callSessionId: "fixture-session")
            reply["result"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        default: throw CheckError.setup(op)
        }
        if op == corruptStage { reply[corruptField] = corruptValue }
        return try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
    }
}

func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}

@MainActor func viewer(_ peer: Peer, generation: UUID? = nil) -> AudioForwardingConnectionContext {
    let generation = generation ?? peer.generation
    return .init(peer: .init(id: peer.id, pairingGeneration: generation),
        principal: .init(kind: .tailnet, id: peer.id, authorizationGeneration: generation), role: .viewer,
        connectionID: peer.connection, connectionIsCurrent: { peer.live }, isCurrent: { peer.live })
}

@MainActor struct Setup {
    let fixture: Fixture
    let peer: Peer
    let session: ProviderCallSession
    let request: ProviderCallRequest
    let core: Core
    let runtime: ProviderCallRuntime
}

@main struct Checks {
    @MainActor static func main() async throws {
        var checks: [[String: Any]] = [], facts: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) {
            checks.append(["name": name, "passed": value]); print("\(value ? "PASS" : "FAIL") \(name)")
        }
        func wait(_ condition: () -> Bool) async throws {
            let until = ContinuousClock.now.advanced(by: .seconds(6))
            while !condition(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
            guard condition() else { throw CheckError.setup("wait") }
        }
        func count(_ f: Fixture, _ method: String) -> Int {
            f.events(1).components(separatedBy: "\"method\":\"\(method)\"").count - 1
        }
        func setup(_ name: String, ttl: Int = 1500, recovery: Bool = true,
                   action: ProviderCallRequest.Action = .start, peer: Peer? = nil) async throws -> Setup {
            let f = try Fixture(name), p = peer ?? Peer("ab")
            guard await f.runtime.start(), let initial = await f.observe(p) else { throw CheckError.setup(name) }
            let intent = try AudioForwardingIntentRequest(pairedDeviceId: p.id, intentId: UUID(),
                intentRevision: .init(initial.ownCursor.intentRevision.value + 1), action: .request,
                inputDesired: true, outputDesired: true, expectedRevision: initial.snapshot.revision,
                transportId: UUID(), transportKind: .native, bindingRevision: .init(initial.ownCursor.bindingRevision.value + 1))
            guard await f.runtime.exchange(try .init(requestID: UUID(), operation: .submit, intent: intent), context: p.context) != nil else {
                throw CheckError.setup("binding")
            }
            try await wait { f.runtime.allows(Data(repeating: 0xab, count: 32), direction: .input) }
            f.runtime.checkPausePolling()
            guard let session = await f.runtime.providerSession(viewer(p)) else { throw CheckError.setup("actual providerSession") }
            let r = try ProviderCallRequest(requestId: UUID(), action: action, expectedLeaseRevision: session.snapshot.revision,
                pairedDeviceId: p.id, desiredInput: true, desiredOutput: true, callSessionId: action == .stop ? "fixture-session" : nil)
            let core = try Core(r, f, ttl: ttl)
            let runtime = ProviderCallRuntime(identity: try HostIdentity(), recoveryReady: { recovery }, open: { _, _ in core })
            return .init(fixture: f, peer: p, session: session, request: r, core: core, runtime: runtime)
        }
        func perform(_ a: Setup, request: ProviderCallRequest? = nil, context: AudioForwardingConnectionContext? = nil,
                     session: ProviderCallSession? = nil) async -> ProviderCallState? {
            await a.runtime.exchange(.init(operation: .perform, request: request ?? a.request),
                context: context ?? viewer(a.peer), session: session ?? a.session)
        }
        func query(_ a: Setup, request: ProviderCallRequest? = nil, context: AudioForwardingConnectionContext? = nil) async -> ProviderCallState? {
            await a.runtime.exchange(.init(operation: .query, request: request ?? a.request),
                context: context ?? viewer(a.peer), session: a.session)
        }
        do {
            let a = try await setup("ordered-release"), c = a.core, f = a.fixture
            _ = await f.http("/arm?method=forwardingProviderRelease")
            let task = Task { await perform(a) }
            try await wait { f.events(1).contains("\"held\":\"forwardingProviderRelease\"") }
            check("Release reply pending has no Core result read", !c.calls.contains("provider.result"))
            check("actual Acquire then Dispatch before Core delivery", count(f, "forwardingProviderAcquire") == 1 && count(f, "forwardingProviderDispatch") == 1 && c.effects == 1)
            check("actual identity and dispatch signatures verified", c.signatures == 2)
            check("pending duplicate perform has no new effect", (await perform(a))?.result.status == .pending && c.effects == 1)
            _ = await f.http("/release")
            let value = await task.value
            check("exact Release then Core result produces started", value?.result.status == .started && c.calls == ["provider.challenge", "provider.identity", "provider.dispatch", "provider.result"])
            check("fresh snapshot read after Core result", f.events(1).range(of: "\"method\":\"forwardingSnapshot\"", options: .backwards)!.lowerBound > f.events(1).range(of: "\"method\":\"forwardingProviderRelease\"", options: .backwards)!.lowerBound)
            let duplicate = await perform(a), cached = await query(a)
            check("completed duplicate and query return cache", duplicate?.result.status == .started && cached?.result.status == .started && c.effects == 1 && count(f, "forwardingProviderAcquire") == 1)
            let changed = try ProviderCallRequest(requestId: a.request.requestId, action: .stop, expectedLeaseRevision: a.request.expectedLeaseRevision,
                pairedDeviceId: a.peer.id, desiredInput: true, desiredOutput: true, callSessionId: "different")
            check("same ID different digest conflicts without effect", (await query(a, request: changed))?.result.reason == "request_id_conflict" && c.effects == 1)
            check("same actor new generation cannot read cached result", (await query(a, context: viewer(a.peer, generation: UUID())))?.result.reason == "request_id_conflict")
            check("actual session rejects pairing generation replacement", await f.runtime.providerSession(viewer(a.peer, generation: UUID())) == nil)
            let restarted = ProviderCallRuntime(identity: try HostIdentity(), recoveryReady: { true }, open: { _, _ in c })
            let miss = await restarted.exchange(.init(operation: .query, request: a.request), context: viewer(a.peer), session: a.session)
            check("new Runtime query has no Acquire despite Node journal", miss?.result.status == .unknown && count(f, "forwardingProviderAcquire") == 1)
            let recorded = await restarted.exchange(.init(operation: .perform, request: a.request), context: viewer(a.peer), session: a.session)
            check("Node journal prevents effect after Runtime cache loss", recorded?.result.reason == "provider_action_already_recorded" && count(f, "forwardingProviderAcquire") == 2 && count(f, "forwardingProviderDispatch") == 1 && c.effects == 1)
            facts.append(["case": "ordered-release", "proof": c.observedProof, "calls": c.calls])
            await f.finish()
        }
        do {
            let a = try await setup("cache-miss")
            check("query cache miss is unknown and Acquire zero", (await query(a))?.result.status == .unknown && a.core.calls.isEmpty && count(a.fixture, "forwardingProviderAcquire") == 0)
            await a.fixture.finish()
        }
        do {
            let a = try await setup("coordinator-221")
            let server = HandlerFixture(), client = server.add(), coordinator = CoordinatorFixture(server)
            coordinator.remote = PairingFixture(a.session.peer)
            coordinator.forwardingRuntime = a.fixture.runtime; coordinator.providerRuntime = a.runtime
            coordinator.forwardingClients[ObjectIdentifier(client.connection)] = .init(connection: client.connection,
                route: client.route, generation: a.peer.connection)
            server.onProviderControl = { _, _, _ in }
            server.provider(Wire.encode(ProviderCallControl(operation: .perform, request: a.request)), client)
            let exchange = client.providerExchange!
            await coordinator.invoke(exchange, client.connection, client.route); server.drain()
            check("actual 221 Coordinator Runtime Node Core 222 path", server.sent.count == 1 && client.connection.state == .ready &&
                client.providerExchange == nil && a.core.effects == 1 && count(a.fixture, "forwardingProviderRelease") == 1)
            for cause in ["unpaired", "synthetic", "shutdown", "internet", "missing-session"] {
                let denied = server.add()
                coordinator.forwardingClients[ObjectIdentifier(denied.connection)] = .init(connection: denied.connection,
                    route: denied.route, generation: a.peer.connection)
                if cause == "unpaired" { coordinator.remote?.paired = false }
                if cause == "synthetic" { coordinator.synthetic = true }
                if cause == "shutdown" { coordinator.shuttingDown = true }
                if cause == "internet" {
                    denied.route.origin = .internet
                    coordinator.forwardingClients[ObjectIdentifier(denied.connection)] = .init(connection: denied.connection,
                        route: denied.route, generation: a.peer.connection)
                }
                if cause == "missing-session" { coordinator.forwardingClients.removeValue(forKey: ObjectIdentifier(denied.connection)) }
                server.provider(Wire.encode(ProviderCallControl(operation: .query, request: a.request)), denied)
                await coordinator.invoke(denied.providerExchange!, denied.connection, denied.route); server.drain()
                check("actual Coordinator rejects \(cause) without result or new effect", denied.connection.state == .cancelled && server.sent.count == 1 && a.core.effects == 1)
                coordinator.remote?.paired = true; coordinator.synthetic = false; coordinator.shuttingDown = false
            }
            await a.fixture.finish()
        }
        do {
            let a = try await setup("stop", action: .stop)
            check("stop requires complete release and fresh snapshot", (await perform(a))?.result.status == .stopped && a.core.effects == 1 && a.core.calls.last == "provider.result")
            await a.fixture.finish()
        }
        for field in ["requestId", "coreGeneration", "challenge", "requestDigest", "targetHash", "schemaVersion"] {
            let a = try await setup("identity-wrong-" + field)
            a.core.corruptStage = "provider.identity"; a.core.corruptField = field
            a.core.corruptValue = field == "schemaVersion" ? 2 : "00000000-0000-0000-0000-000000000001" as Any
            let result = await perform(a)
            check("identity correlation rejects \(field) before approval/effect/started", result?.result.status == .failed && count(a.fixture, "forwardingProviderAcquire") == 0 && a.core.effects == 0)
            await a.fixture.finish()
        }
        for stage in ["provider.dispatch", "provider.result"] {
            for field in ["requestId", "coreGeneration", "challenge", "requestDigest", "targetHash", "schemaVersion"] {
                let a = try await setup(stage + "-wrong-" + field)
                a.core.corruptStage = stage; a.core.corruptField = field
                a.core.corruptValue = field == "schemaVersion" ? 2 : "00000000-0000-0000-0000-000000000001" as Any
                let result = await perform(a)
                check("\(stage) wrong \(field) never started", result?.result.status == .unknown && a.core.effects == 1)
                check("\(stage) wrong \(field) still releases Node", count(a.fixture, "forwardingProviderRelease") == 1)
                if stage == "provider.dispatch" { check("bad delivery has no result read", !a.core.calls.contains("provider.result")) }
                await a.fixture.finish()
            }
        }
        for delivery in ["not_dispatched", "unknown"] {
            let a = try await setup("delivery-" + delivery)
            a.core.corruptStage = "provider.dispatch"; a.core.corruptField = "state"; a.core.corruptValue = delivery
            let result = await perform(a)
            check("delivery \(delivery) never reads result or starts", result?.result.status == .unknown && !a.core.calls.contains("provider.result") && count(a.fixture, "forwardingProviderRelease") == 1)
            await a.fixture.finish()
        }
        do {
            let a = try await setup("fresh-snapshot-revision")
            var reads = 0
            let session = ProviderCallSession(relay: a.session.relay, peer: a.session.peer,
                credential: a.session.credential, snapshot: a.session.snapshot, admitted: a.session.admitted,
                readSnapshot: {
                    reads += 1
                    guard let actual = await a.session.readSnapshot() else { return nil }
                    return reads == 1 ? actual : try? AudioForwardingSnapshot(revision: .init(actual.revision.value + 1),
                        intent: actual.intent, binding: actual.binding)
                })
            check("changed fresh snapshot refuses started after Core result", (await perform(a, session: session))?.result.status == .unknown && reads == 2 && a.core.calls.last == "provider.result")
            await a.fixture.finish()
        }
        for cause in ["revision", "actor", "target", "cancel", "late", "recovery"] {
            let a = try await setup("before-approval-" + cause, ttl: cause == "late" ? 60 : 1500, recovery: cause != "recovery")
            var r = a.request
            if cause == "revision" || cause == "actor" {
                r = try ProviderCallRequest(requestId: r.requestId, action: .start,
                    expectedLeaseRevision: cause == "revision" ? .init(r.expectedLeaseRevision.value + 1) : r.expectedLeaseRevision,
                    pairedDeviceId: cause == "actor" ? Peer("cd").id : r.pairedDeviceId,
                    desiredInput: true, desiredOutput: true, callSessionId: nil)
            }
            if cause == "target" { a.core.corruptStage = "provider.challenge"; a.core.corruptField = "targetHash"; a.core.corruptValue = String(repeating: "0", count: 64) }
            if cause == "cancel" { a.core.onCall = { if $0 == "provider.identity" { a.peer.live = false } } }
            if cause == "late" {
                a.core.hold = "provider.identity"
                let task = Task { await perform(a) }
                try await wait { a.core.waiting }
                try await Task.sleep(for: .milliseconds(90)); a.core.resume = true
                let result = await task.value
                check("late identity approval/effect/started zero", result?.result.status == .failed && count(a.fixture, "forwardingProviderDispatch") == 0 && a.core.effects == 0)
            } else {
                let result = await perform(a, request: r)
                check("\(cause) approval/effect/started zero", result?.result.status != .started && count(a.fixture, "forwardingProviderDispatch") == 0 && a.core.effects == 0)
            }
            await a.fixture.finish()
        }
        for field in ["state", "requestId", "scopeId", "nodeGeneration", "remainingMilliseconds", "outcome"] {
            let a = try await setup("release-wrong-" + field)
            let value = field == "remainingMilliseconds" ? "1" : field == "state" ? "\"prepared\"" : field == "outcome" ? "\"unknown\"" : "\"00000000-0000-0000-0000-000000000001\""
            _ = await a.fixture.http("/tamper-release?field=" + field + "&value=" + value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
            let result = await perform(a)
            check("wrong Node Release \(field) prevents result read/started", result?.result.status == .unknown && !a.core.calls.contains("provider.result"))
            await a.fixture.finish()
        }
        do {
            let a = try await setup("budget-and-217"), c = a.core
            let server = HandlerFixture(), timed = server.add(), other = server.add()
            server.onProviderControl = { _, _, _ in }; server.onForwardingControl = { _, _, _, _ in }
            server.provider(Wire.encode(ProviderCallControl(operation: .perform, request: a.request)), timed)
            let ticket = timed.providerExchange!
            c.hold = "provider.challenge"
            let task = Task { await perform(a) }
            try await wait { c.waiting }
            check("pending query first allowed", (await query(a))?.result.status == .pending)
            check("pending query under 500ms rejected", (await query(a))?.result.reason == "provider_query_budget_exhausted")
            for _ in 0..<3 { try await Task.sleep(for: .milliseconds(510)); check("pending spaced query allowed", (await query(a))?.result.status == .pending) }
            try await Task.sleep(for: .milliseconds(510))
            check("pending fifth query rejected", (await query(a))?.result.reason == "provider_query_budget_exhausted")
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(1000))
                check("217 one-second poll runs independently of pending 221", await a.fixture.observe(a.peer) != nil)
            }
            check("pending queries do not Acquire or click", count(a.fixture, "forwardingProviderAcquire") == 0 && c.effects == 0)
            try await Task.sleep(for: .milliseconds(5100))
            check("pending total 10 second TTL exhausted", (await query(a))?.result.reason == "provider_query_budget_exhausted")
            try await wait { server.queue.sync { timed.connection.state == .cancelled } }
            check("actual 221 handler ten-second deadline closes its connection", !ticket.isCurrent)
            let observe = try AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
            server.forwarding(Wire.encode(observe), other)
            check("221 timeout preserves other TLS 217 slot", other.connection.state == .ready && other.forwardingExchange?.isCurrent == true)
            c.resume = true; _ = await task.value
            await a.fixture.finish()
        }
        do {
            let a = try await setup("post-dispatch-cancel")
            a.core.onCall = { if $0 == "provider.dispatch" { a.peer.live = false } }
            let result = await perform(a)
            check("cancellation after delivery returns no started", result == nil && !a.core.calls.contains("provider.result") && count(a.fixture, "forwardingProviderRelease") == 1)
            await a.fixture.finish()
        }
        do {
            let a = try await setup("p2-old-relay")
            let original = await perform(a)
            check("P2 relay repro starts with actual completed operation", original?.result.status == .started)
            let old = a.fixture.info(1)
            await a.fixture.finish()
            let b = try await setup("p2-replacement-relay", peer: a.peer)
            let replacement = b.fixture.info(1)
            let cached = await a.runtime.exchange(.init(operation: .query, request: a.request),
                context: viewer(a.peer), session: b.session)
            check("P2 old success cannot cross actual relay/child generation", cached?.result.status == .unknown)
            let duplicate = await a.runtime.exchange(.init(operation: .perform, request: a.request),
                context: viewer(a.peer), session: b.session)
            check("P2 old perform after relay change stays unknown", duplicate?.result.status == .unknown)
            check("P2 replacement query never acquires or dispatches", count(b.fixture, "forwardingProviderAcquire") == 0 && count(b.fixture, "forwardingProviderDispatch") == 0 && b.core.effects == 0)
            facts.append(["case": "P2-relay-generation", "old": old, "replacement": replacement,
                "sameActor": a.peer.id.hex == b.peer.id.hex, "samePairing": a.peer.generation == b.peer.generation,
                "returnedStatus": cached?.result.status.rawValue ?? "nil", "returnedReason": cached?.result.reason ?? "nil"])
            await b.fixture.finish()
        }
        do {
            let a = try await setup("p2-stale-capacity")
            var rejected = 0
            for _ in 0..<256 {
                let stale = try ProviderCallRequest(requestId: UUID(), action: .start,
                    expectedLeaseRevision: .init(a.request.expectedLeaseRevision.value + 1), pairedDeviceId: a.peer.id,
                    desiredInput: true, desiredOutput: true, callSessionId: nil)
                let result = await perform(a, request: stale)
                if result?.result.reason == "audio_lease_changed" { rejected += 1 }
            }
            check("P2 256 stale revisions never reach Node Acquire", rejected == 256 && count(a.fixture, "forwardingProviderAcquire") == 0 && a.core.calls.isEmpty)
            let legitimate = await perform(a)
            check("P2 pre-effect stale requests cannot exhaust valid capacity", legitimate?.result.status == .started && a.core.effects == 1)
            facts.append(["case": "P2-stale-capacity", "preEffectRejected": rejected,
                "returnedStatus": legitimate?.result.status.rawValue ?? "nil", "returnedReason": legitimate?.result.reason ?? "nil",
                "acquires": count(a.fixture, "forwardingProviderAcquire"), "effects": a.core.effects])
            await a.fixture.finish()
        }
        for cause in ["recovery", "uds"] {
            let a = try await setup("p2-preflight-" + cause)
            var available = false, failed = 0
            let runtime = ProviderCallRuntime(identity: try HostIdentity(), recoveryReady: { cause != "recovery" || available },
                open: { _, _ in
                    guard cause != "uds" || available else { throw ProviderCallFailure.unavailable }
                    return a.core
                })
            var last = a.request
            for _ in 0..<256 {
                last = try ProviderCallRequest(requestId: UUID(), action: .start,
                    expectedLeaseRevision: a.request.expectedLeaseRevision, pairedDeviceId: a.peer.id,
                    desiredInput: true, desiredOutput: true, callSessionId: nil)
                let value = await runtime.exchange(.init(operation: .perform, request: last), context: viewer(a.peer), session: a.session)
                if value?.result.status == .failed && value?.result.reason != "request_capacity" { failed += 1 }
            }
            let query = await runtime.exchange(.init(operation: .query, request: last), context: viewer(a.peer), session: a.session)
            check("P2 \(cause) preflight failure removes unexecuted record", failed == 256 && query?.result.status == .unknown && a.core.calls.isEmpty && count(a.fixture, "forwardingProviderAcquire") == 0)
            available = true
            let valid = await runtime.exchange(.init(operation: .perform, request: a.request), context: viewer(a.peer), session: a.session)
            check("P2 \(cause) 256 preflight failures preserve valid capacity", valid?.result.status == .started && a.core.effects == 1)
            await a.fixture.finish()
        }
        do {
            let a = try await setup("preflight-four-per-actor")
            var entered = 0, released = false, ready = false
            let runtime = ProviderCallRuntime(identity: try HostIdentity(), recoveryReady: {
                entered += 1
                while !released { try? await Task.sleep(for: .milliseconds(5)) }
                return ready
            }, open: { _, _ in a.core })
            var tasks: [Task<ProviderCallState?, Never>] = []
            for _ in 0..<4 {
                let request = try ProviderCallRequest(requestId: UUID(), action: .start,
                    expectedLeaseRevision: a.request.expectedLeaseRevision, pairedDeviceId: a.peer.id,
                    desiredInput: true, desiredOutput: true, callSessionId: nil)
                tasks.append(Task { await runtime.exchange(.init(operation: .perform, request: request), context: viewer(a.peer), session: a.session) })
            }
            try await wait { entered == 4 }
            var fifth: ProviderCallState?, settled = false
            let fifthTask = Task {
                fifth = await runtime.exchange(.init(operation: .perform, request: a.request), context: viewer(a.peer), session: a.session)
                settled = true
            }
            try await Task.sleep(for: .milliseconds(50))
            check("actor fifth concurrent preflight rejected before open/Acquire", settled && fifth?.result.reason == "provider_preflight_busy" && entered == 4 && a.core.calls.isEmpty && count(a.fixture, "forwardingProviderAcquire") == 0)
            released = true
            for task in tasks { _ = await task.value }
            await fifthTask.value
            ready = true
            let after = await runtime.exchange(.init(operation: .perform, request: a.request), context: viewer(a.peer), session: a.session)
            check("settled actor preflight slots are reusable", after?.result.status == .started && a.core.effects == 1)
            await a.fixture.finish()
        }
        do {
            let a = try await setup("authority-tombstone", ttl: 100)
            _ = await a.fixture.http("/arm?method=forwardingProviderAcquire")
            let task = Task { await perform(a) }
            try await wait { a.fixture.events(1).contains("\"held\":\"forwardingProviderAcquire\"") }
            try await Task.sleep(for: .milliseconds(140))
            _ = await a.fixture.http("/release")
            let first = await task.value, duplicate = await perform(a), queried = await query(a)
            check("Acquire-reached failure keeps same-request tombstone", first?.result.status == .failed &&
                duplicate?.result.reason == first?.result.reason && queried?.result.reason == first?.result.reason &&
                count(a.fixture, "forwardingProviderAcquire") == 1 && count(a.fixture, "forwardingProviderDispatch") == 0 && a.core.effects == 0)
            await a.fixture.finish()
        }
        await handlerChecks(check)
        await socketChecks(check)
        let failures = checks.filter { $0["passed"] as? Bool == false }
        let report: [String: Any] = ["checks": checks, "failures": failures, "facts": facts,
            "passedCount": checks.count - failures.count, "checkCount": checks.count,
            "actualProviderClicks": 0, "actualKeychainAccess": 0, "installed149Modified": false,
            "positiveSignedPeerAcceptance": false, "positiveRecoveryAcceptance": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("report.json"))
        exit(failures.isEmpty ? 0 : 1)
    }
}
