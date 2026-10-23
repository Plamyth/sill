import Foundation
import CryptoKit
import StreamProtocol

@MainActor final class Gate { var allowed = true }

@MainActor struct Acquired {
    let fixture: Fixture
    let peer: Peer
    let gate: Gate
    let request: ProviderCallRequest
    let challenge: ProviderCallChallenge
    let snapshot: AudioForwardingSnapshot
    let credential: AudioForwardingCredential
    func acquire(started: TimeInterval? = nil) async -> ProviderCallAcquisition {
        await fixture.relay.providerAcquire(request, challenge: challenge,
            challengeStartedAt: started ?? ProcessInfo.processInfo.systemUptime,
            snapshot: snapshot, peer: peer.context.peer, credential: credential,
            admission: { gate.allowed && peer.live })
    }
}

enum CheckError: Error { case setup(String) }

@main struct Checks {
    @MainActor static func main() async throws {
        var checks: [[String: Any]] = [], facts: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) {
            checks.append(["name": name, "passed": value])
            print("\(value ? "PASS" : "FAIL") \(name)")
        }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let until = ContinuousClock.now.advanced(by: .seconds(6))
            while !condition(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
            guard condition() else { throw CheckError.setup(label) }
        }
        func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
            try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }
        func request(_ peer: Peer, _ snapshot: AudioForwardingSnapshot, id: UUID = UUID(), action: String = "start", session: String? = nil) throws -> ProviderCallRequest {
            try decode(["requestId": id.uuidString.lowercased(), "action": action,
                "expectedLeaseRevision": String(snapshot.revision.value), "pairedDeviceId": peer.id.hex,
                "desiredInput": true, "desiredOutput": true, "callSessionId": session as Any? ?? NSNull()])
        }
        func challenge(_ request: ProviderCallRequest, leaf: String = "leaf-a", ttl: Int = 1500) throws -> ProviderCallChallenge {
            let target: [String: Any] = ["profileId": "codex-control-room-chatgpt-dots", "leafId": leaf,
                "guestId": leaf == "leaf-a" ? 17 : 23, "url": "https://chatgpt.com/dots/\(leaf)", "timeOrigin": 1_700_000_000_123.5]
            let typed: ProviderCallTarget = try decode(target)
            return try decode(["schemaVersion": 1, "challenge": Base64URL.encode(Data(repeating: leaf == "leaf-a" ? 7 : 8, count: 32)),
                "coreGeneration": UUID().uuidString.lowercased(), "requestId": request.requestId.uuidString.lowercased(),
                "target": target, "targetHash": try typed.hash(), "guestNowMs": 42.5, "remainingMilliseconds": ttl])
        }
        func setup(_ name: String, ttl: Int = 1500) async throws -> Acquired {
            let f = try Fixture(name), peer = Peer("ab"), gate = Gate()
            guard await f.runtime.start(), let initial = await f.observe(peer) else { throw CheckError.setup(name + " bootstrap") }
            let intent = try AudioForwardingIntentRequest(pairedDeviceId: peer.id, intentId: UUID(),
                intentRevision: .init(initial.ownCursor.intentRevision.value + 1), action: .request,
                inputDesired: true, outputDesired: true, expectedRevision: initial.snapshot.revision,
                transportId: UUID(), transportKind: .native, bindingRevision: .init(initial.ownCursor.bindingRevision.value + 1))
            guard await f.runtime.exchange(try .init(requestID: UUID(), operation: .submit, intent: intent), context: peer.context) != nil else {
                throw CheckError.setup(name + " native binding")
            }
            try await wait("active binding") { f.runtime.allows(Data(repeating: 0xab, count: 32), direction: .input) }
            guard let current = await f.observe(peer), current.snapshot.binding?.phase == .active else { throw CheckError.setup(name + " active snapshot") }
            f.runtime.checkPausePolling()
            let r = try request(peer, current.snapshot)
            return .init(fixture: f, peer: peer, gate: gate, request: r, challenge: try challenge(r, ttl: ttl),
                         snapshot: current.snapshot, credential: current.credential)
        }
        func prepared(_ a: Acquired, started: TimeInterval? = nil) async throws -> ProviderCallPrepared {
            guard case .prepared(let p) = await a.acquire(started: started) else { throw CheckError.setup("actual Acquire prepared") }
            return p
        }
        func approval(_ a: Acquired, _ p: ProviderCallPrepared) async throws -> ProviderCallApproval {
            guard case .approved(let value) = await a.fixture.relay.providerDispatch(p) else { throw CheckError.setup("actual Dispatch approved") }
            return value
        }
        func methodCount(_ f: Fixture, _ method: String) -> Int {
            f.events(1).components(separatedBy: "\"method\":\"\(method)\"").count - 1
        }
        func state(_ value: ProviderCallDispatch) -> String {
            switch value { case .approved: return "approved"; case .unknown: return "unknown"; case .notDispatched: return "not_dispatched" }
        }
        let signer = ProviderCallSigner(identity: try HostIdentity())
        func proof(_ a: Acquired, _ approval: ProviderCallApproval) throws -> (ProviderCallSignedEnvelope, [String: Any]) {
            let signed = try signer.dispatchProof(approval, context: a.peer.context)
            let bytes = Base64URL.decode(signed.payload)!
            let publicDER = Base64URL.decode(signed.publicSPKI)!
            let publicKey = try P256.Signing.PublicKey(x963Representation: publicDER.suffix(65))
            let signature = try P256.Signing.ECDSASignature(derRepresentation: Base64URL.decode(signed.signature)!)
            check("signature verifies exact purpose and payload", publicKey.isValidSignature(signature,
                for: Data("ccr-provider-dispatch-v1\0".utf8) + bytes))
            check("signature rejects a different purpose", !publicKey.isValidSignature(signature,
                for: Data("ccr-provider-identity-v1\0".utf8) + bytes))
            return (signed, try JSONSerialization.jsonObject(with: bytes) as! [String: Any])
        }
        // A's immutable values survive replacement of the caller's request/challenge variables.
        do {
            let a = try await setup("immutable-and-once"), f = a.fixture
            var callerRequest = a.request, callerChallenge = a.challenge
            let p = try await prepared(a)
            _ = await f.http("/arm?method=forwardingProviderDispatch")
            let pending = Task { await f.relay.providerDispatch(p) }
            try await wait("actual Dispatch reply held") { f.events(1).contains("\"held\":\"forwardingProviderDispatch\"") }
            callerRequest = try request(a.peer, a.snapshot, id: a.request.requestId, action: "stop", session: "other-session")
            callerChallenge = try challenge(callerRequest, leaf: "leaf-b")
            check("concurrent duplicate Prepared dispatch is unknown", state(await f.relay.providerDispatch(p)) == "unknown")
            _ = await f.http("/release")
            guard case .approved(let approved) = await pending.value else { throw CheckError.setup("held immutable approval") }
            let (signed, body) = try proof(a, approved)
            let payloadRequest = body["request"] as! [String: Any]
            check("proof keeps original target, challenge and Core generation", body["targetHash"] as? String == a.challenge.targetHash &&
                body["challenge"] as? String == a.challenge.challenge && body["coreGeneration"] as? String == a.challenge.coreGeneration.uuidString.lowercased())
            check("caller target B and challenge B cannot replace A", body["targetHash"] as? String != callerChallenge.targetHash && body["challenge"] as? String != callerChallenge.challenge)
            check("proof keeps original action/session/request digest", payloadRequest["action"] as? String == "start" && payloadRequest["callSessionId"] is NSNull &&
                body["requestDigest"] as? String == a.request.digest && body["requestDigest"] as? String != callerRequest.digest)
            check("proof has no relay credential", !String(data: Base64URL.decode(signed.payload)!, encoding: .utf8)!.contains(a.credential.credential))
            check("proof scope belongs to actual Acquire", body["scopeId"] as? String == p.scope.scopeId?.uuidString.lowercased() && body["nodeGeneration"] as? String == p.scope.nodeGeneration.uuidString.lowercased())
            check("same Approval cannot sign twice", (try? signer.dispatchProof(approved, context: a.peer.context)) == nil)
            check("completed duplicate Prepared dispatch is unknown", state(await f.relay.providerDispatch(p)) == "unknown")
            check("one actual Node Dispatch only", methodCount(f, "forwardingProviderDispatch") == 1)
            await f.relay.providerRelease(approved, outcome: .unknown)
            check("actual Node Release traversed private stdio", methodCount(f, "forwardingProviderRelease") == 1)
            await f.finish()
        }
        // Withdrawal after Node authorized but before Swift receives the reply.
        for cause in ["admission", "cancel", "task-cancel", "membership", "relay-boot", "connection"] {
            let a = try await setup("await-" + cause), f = a.fixture, p = try await prepared(a)
            _ = await f.http("/arm?method=forwardingProviderDispatch")
            let pending = Task { await f.relay.providerDispatch(p) }
            try await wait("held dispatch " + cause) { f.events(1).contains("\"held\":\"forwardingProviderDispatch\"") }
            var cancellation: Task<Void, Never>?
            if cause == "admission" { a.gate.allowed = false }
            if cause == "connection" { a.peer.live = false }
            if cause == "cancel" { cancellation = Task { await f.relay.providerCancel(p) }; try await wait("cancel revocation") { !p.isCurrent } }
            if cause == "task-cancel" { pending.cancel() }
            if cause == "membership" || cause == "relay-boot" {
                f.registry.register(cause == "membership" ? .native : .relay, bootId: UUID(),
                    control: .init(fenceAndQuiesce: { Fixture.receipt($0) }, inspect: { _ in nil }))
            }
            _ = await f.http("/release")
            let outcome = state(await pending.value)
            await cancellation?.value
            check(cause + " after await: Approval zero and unknown", outcome == "unknown")
            check(cause + ": no retry of actual Node dispatch", methodCount(f, "forwardingProviderDispatch") == 1)
            a.gate.allowed = true; a.peer.live = true
            check(cause + ": same Prepared never dispatches again", state(await f.relay.providerDispatch(p)) != "approved" && methodCount(f, "forwardingProviderDispatch") == 1)
            if cause == "membership" || cause == "relay-boot" {
                check(cause + ": no cleanup sent to a replacement membership", methodCount(f, "forwardingProviderCancel") == 0)
            }
            facts.append(["case": cause, "dispatch": outcome])
            await f.finish()
        }
        do {
            let a = try await setup("release-before-proof"), f = a.fixture, p = try await prepared(a)
            let approved = try await approval(a, p)
            await f.relay.providerRelease(approved, outcome: .notDispatched)
            check("Release reaches Node recorded state", f.events(1).contains("\"reply\":\"forwardingProviderRelease\",\"status\":\"recorded\""))
            let signedAfterRelease = try? signer.dispatchProof(approved, context: a.peer.context)
            check("Release permanently invalidates Approval before first sign", signedAfterRelease == nil)
            check("released Prepared cannot dispatch again", state(await f.relay.providerDispatch(p)) == "unknown")
            facts.append(["case": "release-before-proof", "signatureIssuedAfterRelease": signedAfterRelease != nil,
                          "approvalStillCurrent": approved.isCurrent])
            await f.finish()
        }
        do {
            let a = try await setup("cancel-and-other-scope"), f = a.fixture, p = try await prepared(a)
            await f.relay.providerCancel(p)
            check("Cancel reaches real Node", methodCount(f, "forwardingProviderCancel") == 1)
            let revokedDispatch = state(await f.relay.providerDispatch(p))
            check("cancelled Prepared stays revoked", !p.isCurrent && revokedDispatch == "not_dispatched")
            let r = try request(a.peer, a.snapshot), c = try challenge(r)
            let b = Acquired(fixture: f, peer: a.peer, gate: a.gate, request: r, challenge: c, snapshot: a.snapshot, credential: a.credential)
            let next = try await prepared(b)
            await f.relay.providerCancel(p)
            let approved = try await approval(b, next)
            check("old Cancel preserves newer Node scope", approved.isCurrent)
            _ = try proof(b, approved)
            await f.relay.providerRelease(approved, outcome: .unknown)
            await f.finish()
        }
        do {
            let a = try await setup("cancel-approved"), p = try await prepared(a), approved = try await approval(a, p)
            await a.fixture.relay.providerCancel(p)
            check("Cancel after Dispatch prevents first proof", (try? signer.dispatchProof(approved, context: a.peer.context)) == nil)
            await a.fixture.finish()
        }
        do {
            let a = try await setup("foreign-cancel-owner"), owner = a.fixture, p = try await prepared(a)
            let foreign = try Fixture("foreign-cancel-caller")
            await foreign.relay.providerCancel(p)
            check("foreign relay Cancel cannot revoke the original Prepared", p.isCurrent)
            check("foreign relay Cancel sends no cleanup to owner Node", methodCount(owner, "forwardingProviderCancel") == 0)
            let outcome = state(await owner.relay.providerDispatch(p))
            check("original actor retains dispatch after foreign Cancel", outcome == "approved")
            facts.append(["case": "foreign-cancel", "ownerDispatch": outcome])
            await owner.relay.providerCancel(p)
            await foreign.finish(); await owner.finish()
        }
        do {
            let a = try await setup("dispatch-expired-in-flight", ttl: 120), f = a.fixture, p = try await prepared(a)
            _ = await f.http("/arm?method=forwardingProviderDispatch")
            let pending = Task { await f.relay.providerDispatch(p) }
            try await wait("held short dispatch") { f.events(1).contains("\"held\":\"forwardingProviderDispatch\"") }
            try await Task.sleep(for: .milliseconds(160))
            _ = await f.http("/release")
            check("late Dispatch cannot create Approval after expiry", state(await pending.value) == "unknown")
            check("late Dispatch never retries Node", methodCount(f, "forwardingProviderDispatch") == 1)
            await f.finish()
        }
        do {
            let a = try await setup("min-clock", ttl: 900), f = a.fixture
            let start = ProcessInfo.processInfo.systemUptime - 0.15
            _ = await f.http("/arm?method=forwardingProviderAcquire")
            let acquiring = Task { await a.acquire(started: start) }
            try await wait("held acquire clock") { f.events(1).contains("\"held\":\"forwardingProviderAcquire\"") }
            try await Task.sleep(for: .milliseconds(180))
            _ = await f.http("/release")
            guard case .prepared(let p) = await acquiring.value else { throw CheckError.setup("clock prepared") }
            let approved = try await approval(a, p)
            let remaining = approved.remainingMilliseconds
            let budget = Int(((start + 0.9 - ProcessInfo.processInfo.systemUptime) * 1000).rounded(.down))
            check("deadline is min challenge send clock and Node remaining", remaining > 0 && remaining <= budget + 2 && remaining < p.scope.remainingMilliseconds)
            try await Task.sleep(for: .milliseconds(max(1, budget + 25)))
            check("expiry cannot regain remaining time", !approved.isCurrent && approved.remainingMilliseconds == 0)
            check("expired Approval refuses first proof", (try? signer.dispatchProof(approved, context: a.peer.context)) == nil)
            await f.finish()
        }
        do {
            let a = try await setup("acquire-expired-in-flight", ttl: 120), f = a.fixture
            _ = await f.http("/arm?method=forwardingProviderAcquire")
            let pending = Task { await a.acquire() }
            try await wait("held short acquire") { f.events(1).contains("\"held\":\"forwardingProviderAcquire\"") }
            try await Task.sleep(for: .milliseconds(160))
            _ = await f.http("/release")
            if case .unavailable = await pending.value { check("late Acquire cannot extend challenge expiry", true) }
            else { check("late Acquire cannot extend challenge expiry", false) }
            check("late Acquire cancellation uses original scope", methodCount(f, "forwardingProviderCancel") == 1 && methodCount(f, "forwardingProviderDispatch") == 0)
            for clock in [Double.nan, Double.infinity, -1, ProcessInfo.processInfo.systemUptime + 60] {
                if case .unavailable = await a.acquire(started: clock) { check("invalid monotonic start rejected locally", true) }
                else { check("invalid monotonic start rejected locally", false) }
            }
            check("invalid clocks write no further Node Acquire", methodCount(f, "forwardingProviderAcquire") == 1)
            await f.finish()
        }
        let failures = checks.filter { $0["passed"] as? Bool == false }
        let report: [String: Any] = ["checks": checks, "failures": failures, "facts": facts,
            "passedCount": checks.count - failures.count, "checkCount": checks.count,
            "actualProviderClicks": 0, "actualKeychainAccess": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("report.json"))
        print("실제 Swift/Node admission 검사 \(checks.count)개, 실패 \(failures.count)개")
        exit(failures.isEmpty ? 0 : 1)
    }
}
