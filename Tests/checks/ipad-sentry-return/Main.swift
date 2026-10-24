import Foundation
import CryptoKit
import Network
import StreamProtocol

final class Memory {
    var data: Data?
    var fail = false
    var drop = false
    var writes = 0
    var store: IPadSentryReturn.Store {
        .init(load: { self.data }, compareAndSwap: { old, new in
            guard !self.fail, self.data == old else { throw IPadSentryReturn.Failure.storage }
            self.writes += 1
            if !self.drop { self.data = new }
        })
    }
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { print("FAIL \(label)"); exit(1) }
    checks += 1; print("PASS \(label)")
}
func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
func object(_ data: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: data) as! [String: Any] }
let peer = NWConnection(), other = NWConnection()
let binding = IPadSentryReturn.Binding(macID: "fixtureMac", hostPin: Data(repeating: 0xab, count: 32), deviceFingerprint: Data(repeating: 0xcd, count: 32))
var fixtures: [String: Any] = [:]
var request: SentryReturnRequest!
func raw(_ key: String) -> Data { Data((fixtures[key] as! String).utf8) }
func catalog(_ lease: SentryReturnLease? = nil, capability: Any? = nil, include: Bool = true) -> Data {
    let lease = lease ?? request.lease
    let sentry = SentryState(hostBootID: UUID(uuidString: lease.hostBootID)!, sessionID: UUID(uuidString: lease.sessionID)!,
        revision: UUID(uuidString: lease.revision)!, requested: true, phase: .userSessionProtected, limitations: [],
        control: .init(authorizationGeneration: UUID(uuidString: lease.authorizationGeneration)!, manualIntent: .on))
    var value: [String: Any] = ["windows": [], "sentry": object(try! JSONEncoder().encode(sentry))]
    if include { value["sentryReturn"] = capability ?? fixtures["capability"]! }
    return json(value)
}
func consumer(_ memory: Memory = Memory()) -> IPadSentryReturn {
    var value = IPadSentryReturn(store: memory.store)
    value.bind(ObjectIdentifier(peer)); value.observe(catalog: catalog(), binding: binding, from: ObjectIdentifier(peer))
    return value
}
@discardableResult func start(_ value: inout IPadSentryReturn, request source: SentryReturnRequest? = nil) -> IPadSentryReturn.Outbound? {
    let r = source ?? request!
    return value.request(mode: r.authMode, enrollment: r.keyEnrollment, binding: binding,
        from: ObjectIdentifier(peer), now: 1, requestID: r.requestID)
}
@discardableResult func receive(_ value: inout IPadSentryReturn, _ data: Data, now: Double = 2) -> Bool {
    value.receive(data, binding: binding, from: ObjectIdentifier(peer), now: now)
}
func changed(_ data: Data, _ change: (inout [String: Any]) -> Void) -> Data {
    var value = object(data); change(&value); return json(value)
}
func challengeState(for r: SentryReturnRequest, owner: String = "owner-fixture-1", keyID: String? = nil) -> Data {
    let fixture = try! SentryReturnState.decodePayload(raw("pendingStateRaw")).challenge!
    let challenge = try! SentryReturnChallenge(reference: r.reference, lease: r.lease,
        authGeneration: fixture.authGeneration, nonce: fixture.nonce, ownerID: owner,
        hostFingerprint: fixture.hostFingerprint, deviceFingerprint: fixture.deviceFingerprint,
        pairingGeneration: fixture.pairingGeneration, authMode: r.authMode, keyID: keyID)
    return try! SentryReturnState(reference: r.reference, authGeneration: challenge.authGeneration, authStatus: .pending,
        operationState: .authenticating, code: .authenticationRequired, challenge: challenge, remainingMilliseconds: 120000).encodedPayload()
}
func completed(for r: SentryReturnRequest, code: SentryReturnState.Code) -> Data {
    let generation = try! SentryReturnState.decodePayload(raw("pendingStateRaw")).authGeneration
    return try! SentryReturnState(reference: r.reference, authGeneration: generation, authStatus: .succeeded,
        operationState: .completed, code: code, challenge: nil, remainingMilliseconds: 0).encodedPayload()
}

@main struct Main {
    static func main() throws {
        fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        request = try .init(rawRequest: raw("requestDeviceRaw"))
        if CommandLine.arguments.count > 2 {
            switch CommandLine.arguments[2] {
            case "lifecycle": try lifecycleChecks()
            case "late-cancel": lateCancelChecks()
            case "cancel-terminal": cancelTerminalChecks()
            default: fatalError("unknown regression")
            }
            print("PASS regression \(CommandLine.arguments[2]) total \(checks)")
            return
        }
        let pending = raw("pendingStateRaw"), done = raw("completedStateRaw")
        for name in ["requestDeviceRaw", "enrollRaw", "currentRaw", "cancelRaw", "proofRaw"] {
            let data = raw(name)
            check((try? SentryReturnControl.decodePayload(data).encodedPayload()) == data, "golden control exact \(name)")
        }
        for name in ["pendingStateRaw", "completedStateRaw"] {
            check((try? SentryReturnState.decodePayload(raw(name)).encodedPayload()) == raw(name), "golden state exact \(name)")
        }
        let fixturePublic = try P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: fixtures["publicKeySPKIBase64"] as! String)!)
        let fixtureChallenge = try SentryReturnState.decodePayload(pending).challenge!
        let sig = Data(base64Encoded: object(raw("proofRaw"))["signature"] as! String)!
        let parsedSignature = try P256.Signing.ECDSASignature(derRepresentation: sig)
        let signingBytes = try fixtureChallenge.signingBytes()
        check(fixturePublic.isValidSignature(parsedSignature, for: signingBytes), "golden SPKI91 DER signature valid over exact bytes")
        let base64urlProof = changed(raw("proofRaw")) { value in
            value["signature"] = (value["signature"] as! String).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        check((try? SentryReturnControl.decodePayload(base64urlProof)) == nil, "base64url proof rejected")
        let memory = Memory(); var value = consumer(memory)
        let out = start(&value)!
        check(Data(out.bytes.dropFirst(StreamMessage.headerLength)) == raw("requestDeviceRaw"), "request raw exact and digest preserved")
        check(out.bytes.first == 223, "control kind223")
        check(receive(&value, pending), "pending consumed from bound peer")
        let owner = try IPadSentryReturn.Owner(binding: binding, challenge: fixtureChallenge)
        let proof = value.beginProof(approvedOwner: owner, keyID: fixtureChallenge.keyID!, binding: binding, from: ObjectIdentifier(peer), now: 3)!
        let rawSigning = Data(base64Encoded: (object(pending)["challenge"] as! [String: Any])["signingPayloadBase64"] as! String)!
        check(proof.bytes == rawSigning, "proof uses received raw signing bytes")
        let proofOut = value.finishProof(proof, signature: sig, publicKey: fixturePublic.derRepresentation, now: 4)!
        check(Data(proofOut.bytes.dropFirst(StreamMessage.headerLength)) == raw("proofRaw"), "golden proof roundtrip from consumer")
        check(receive(&value, done), "completed accepted as historical result")
        check(value.statusText.contains("현재 보호·오디오·입력은 별도"), "completion does not claim current protection")
        check(!receive(&value, pending) && value.latest?.state?.operationState == .completed, "terminal ignores late pending")
        check(value.latest?.state?.currentProtection == "notObserved" && value.latest?.state?.nextPolicy == "parentAdmissionRequired", "parent admission remains required")
        check(value.query(binding: binding, from: ObjectIdentifier(peer), now: 5).map { Data($0.bytes.dropFirst(StreamMessage.headerLength)) } == raw("currentRaw"), "query sends current not request")
        var restored = consumer(memory)
        check(restored.originalRequest == raw("requestDeviceRaw") && !restored.canProve, "restart preserves raw and no implicit signing")
        let newLease = try SentryReturnLease(hostBootID: request.lease.hostBootID,
            sessionID: "00000099-1111-4111-8111-111111111111", revision: request.lease.revision, authorizationGeneration: request.lease.authorizationGeneration)
        restored.observe(catalog: catalog(newLease), binding: binding, from: ObjectIdentifier(peer))
        check(restored.query(binding: binding, from: ObjectIdentifier(peer), now: 6) != nil, "same owner current allowed after Sentry session reset")
        let resetCatalog = changed(catalog()) { $0.removeValue(forKey: "sentry") }
        restored.observe(catalog: resetCatalog, binding: binding, from: ObjectIdentifier(peer))
        check(restored.context?.lease == nil && !restored.canRequest,
            "reset Snapshot=nil preserves advertised binding without fabricating current lease")
        check(restored.query(binding: binding, from: ObjectIdentifier(peer), now: 7).map { Data($0.bytes.dropFirst(StreamMessage.headerLength)) } == raw("currentRaw"),
            "reset Snapshot=nil allows explicit current with original reference only")
        check(restored.request(mode: .macLocal, binding: binding, from: ObjectIdentifier(peer), now: 8) == nil,
            "fresh request denied without current Sentry lease")

        var cancel = consumer(); _ = start(&cancel); receive(&cancel, pending)
        let cancelOut = cancel.cancel(binding: binding, from: ObjectIdentifier(peer), now: 3)!
        check(Data(cancelOut.bytes.dropFirst(StreamMessage.headerLength)) == raw("cancelRaw"), "cancel distinct reference and auth generation")
        check(!receive(&cancel, done) && cancel.latest?.locallyCancelled == true, "late success after local cancel rejected")
        check(!cancel.canRequest, "cancel result unknown never starts new ID")
        var invalid = consumer(); _ = start(&invalid)
        for field in ["ownerID", "pairingGeneration", "hostFingerprint", "deviceFingerprint", "keyID", "nonce", "authGeneration"] {
            let wrong = changed(pending) { state in
                var c = state["challenge"] as! [String: Any]; c[field] = "wrong"; state["challenge"] = c
            }
            check(!receive(&invalid, wrong), "bad challenge tuple rejected \(field)")
        }
        check(!receive(&invalid, Data(repeating: 32, count: 16385)), "state224 over cap rejected")
        let duplicate = Data(String(decoding: pending, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1").utf8)
        check(!receive(&invalid, duplicate), "duplicate state key rejected")
        check(!invalid.receive(pending, binding: binding, from: ObjectIdentifier(other), now: 2), "wrong peer rejected")
        check(!invalid.receive(pending, binding: nil, from: ObjectIdentifier(peer), now: 2), "lost TLS binding rejected")
        check(receive(&invalid, pending), "valid state after malformed states remains usable")
        var badOwner = object(pending)["challenge"] as! [String: Any]
        badOwner["ownerID"] = "different-owner"
        let otherChallenge = try SentryReturnChallenge(reference: fixtureChallenge.reference, lease: fixtureChallenge.lease,
            authGeneration: fixtureChallenge.authGeneration, nonce: fixtureChallenge.nonce, ownerID: "different-owner",
            hostFingerprint: fixtureChallenge.hostFingerprint, deviceFingerprint: fixtureChallenge.deviceFingerprint,
            pairingGeneration: fixtureChallenge.pairingGeneration, authMode: .deviceBoundKey, keyID: fixtureChallenge.keyID)
        let otherOwner = try IPadSentryReturn.Owner(binding: binding, challenge: otherChallenge)
        check(invalid.beginProof(approvedOwner: otherOwner, keyID: fixtureChallenge.keyID!, binding: binding, from: ObjectIdentifier(peer), now: 3) == nil, "approved owner mismatch prevents signing")
        check(invalid.beginProof(approvedOwner: owner, keyID: UUID().uuidString.lowercased(), binding: binding, from: ObjectIdentifier(peer), now: 3) == nil, "unregistered keyID prevents signing")
        check(invalid.beginProof(approvedOwner: owner, keyID: fixtureChallenge.keyID!, binding: binding, from: ObjectIdentifier(peer), now: 123) == nil, "expired challenge prevents signing")
        let prepared = try SentryReturnState(reference: request.reference, authGeneration: fixtureChallenge.authGeneration, authStatus: .succeeded,
            operationState: .restoring, code: .returnPrepared, challenge: nil, remainingMilliseconds: 1000).encodedPayload()
        check(receive(&invalid, prepared) && !receive(&invalid, pending), "auth succeeded distinct from operation completion and no regression")
        var premature = consumer(); _ = start(&premature)
        check(!receive(&premature, changed(prepared) { $0["authStatus"] = "pending" }), "restoring cannot claim authentication success from pending auth")
        check(!receive(&premature, changed(prepared) { $0["code"] = "invalidProof" }), "restoring requires returnPrepared code")
        for code: SentryReturnState.Code in [.invalidProof, .keyEnrolled, .keyRotated, .keyRevoked] {
            var bad = consumer(); _ = start(&bad)
            check(!receive(&bad, completed(for: request, code: code)) && bad.latest?.terminal == false, "completed code mismatch rejected \(code.rawValue)")
        }
        var cancelledPast = consumer(); _ = start(&cancelledPast); receive(&cancelledPast, done)
        check(cancelledPast.cancel(binding: binding, from: ObjectIdentifier(peer), now: 5) == nil && cancelledPast.latest?.locallyCancelled == false,
            "past completed result never interpreted as cancellation ACK")
        let unboundStore = Memory(); var unbound = consumer(unboundStore)
        let enrollmentRequest = try SentryReturnRequest(rawRequest: raw("enrollRaw"))
        _ = start(&unbound, request: enrollmentRequest)
        let completionWithoutChallenge = completed(for: enrollmentRequest, code: .keyEnrolled)
        check(!receive(&unbound, completionWithoutChallenge) && unbound.latest?.unboundCompletion == completionWithoutChallenge && !unbound.canRequest,
            "missing first challenge preserves unbound completion and prohibits reenrollment")
        check(!receive(&unbound, challengeState(for: enrollmentRequest)) && unbound.latest?.rawChallengeState == nil,
            "late pending cannot replace unbound historical completion")
        let unboundRestart = consumer(unboundStore)
        check(unboundRestart.latest?.unboundCompletion == completionWithoutChallenge && !unboundRestart.canRequest,
            "unbound enrollment recovery waits across restart")
        var unknownCancelled = consumer(); _ = start(&unknownCancelled)
        let unknownCancelledRaw = try SentryReturnState(reference: request.reference, authGeneration: fixtureChallenge.authGeneration,
            authStatus: .cancelled, operationState: .unknown, code: .cancelled, challenge: nil, remainingMilliseconds: 0).encodedPayload()
        check(receive(&unknownCancelled, unknownCancelledRaw) && unknownCancelled.latest?.terminal == false && !receive(&unknownCancelled, done),
            "post-commit unknown cancelled is not effect-zero or late success")

        for mode in 0..<3 {
            let failed = Memory(); failed.fail = mode == 0; failed.drop = mode == 1
            if mode == 2 { failed.data = Data("corrupt".utf8) }
            var c = consumer(failed)
            check(start(&c) == nil && c.problem != nil, "store failure blocks transmission mode\(mode)")
        }
        let unknownStore = Memory(); var unknown = consumer(unknownStore); let first = start(&unknown)!
        unknown.checkTimeout(now: 12)
        check(!first.admission.permits() && !unknown.canRequest && unknown.originalRequest == raw("requestDeviceRaw"), "timeout retains unknown and revokes admission")
        var restart = consumer(unknownStore)
        check(!restart.canRequest && restart.query(binding: binding, from: ObjectIdentifier(peer), now: 13) != nil, "unknown restart only explicit current")
        let priorWrites = unknownStore.writes
        for _ in 0..<5 { restart.observe(catalog: catalog(), binding: binding, from: ObjectIdentifier(peer)); restart.checkTimeout(now: 50) }
        check(unknownStore.writes == priorWrites, "observation and timers never create request or enrollment")
        for cap in [NSNull(), ["schemaVersion": 1], ["schemaVersion": 1, "requestMaxBytes": 16384]] as [Any] {
            var c = consumer(); c.observe(catalog: catalog(capability: cap), binding: binding, from: ObjectIdentifier(peer))
            check(!c.canRequest && start(&c) == nil, "invalid capability unsupported without send")
            check(IPadSentryObservation.decodeCatalog(catalog(capability: cap)) != nil, "invalid return capability preserves Sentry catalog")
        }
        var noCap = consumer(); noCap.observe(catalog: catalog(include: false), binding: binding, from: ObjectIdentifier(peer))
        check(!noCap.canRequest, "Host217/218 absent advertisement unsupported")
        let dupCap = Data("{\"sentryReturn\":{\"schemaVersion\":1,\"schemaVersion\":1}}".utf8)
        check(IPadSentryReturn.capabilityBytes(dupCap).flatMap { try? SentryReturnCapability.decodePayload($0) } == nil, "raw subtree retains duplicate for strict decoder")
        try keyChecks(owner: owner, fixturePublic: fixturePublic)
        transportChecks(out: out)
        print("PASS total \(checks); real key creation=0; biometric UI=0; Host effects=0")
    }
}

func keyChecks(owner: IPadSentryReturn.Owner, fixturePublic: P256.Signing.PublicKey) throws {
    let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
    var creates = 0, signs = 0
    let adapter = IPadSentryReturnKeys.Adapter(create: { op in
        try op.check(); creates += 1
        return .init(opaqueKey: Data("fixture-only-protected-blob".utf8), publicKey: fixturePublic.derRepresentation)
    }, sign: { _, bytes, op in try op.check(); signs += 1; return try privateKey.signature(for: bytes).derRepresentation })
    let store = Memory(); let keys = IPadSentryReturnKeys(store: store.store, adapter: adapter)
    check(creates == 0 && signs == 0 && keys.approved(binding: binding) == nil, "key adapter init neither creates nor signs")
    let keyID = "00000008-1111-4111-8111-111111111111"
    let candidate = try keys.prepare(binding: binding, rotating: false, operation: .init(), keyID: keyID)
    check(candidate.phase == .candidate && creates == 1 && keys.approved(binding: binding) == nil, "explicit candidate not approved enrollment")
    check((try? keys.prepare(binding: binding, rotating: false, operation: .init())) == nil && creates == 1, "unknown candidate never overwritten or automatically regenerated")
    let enrollment = try SentryReturnRequest(rawRequest: raw("enrollRaw"))
    var c = consumer(); _ = start(&c, request: enrollment)
    receive(&c, challengeState(for: enrollment))
    check((try? keys.acceptEnrollment(c.latest!)) == nil, "pending Mac auth cannot approve key")
    check(receive(&c, completed(for: enrollment, code: .keyEnrolled)), "Mac keyEnrolled completion accepted")
    try keys.acceptEnrollment(c.latest!)
    check(keys.approved(binding: binding)?.owner == owner && c.statusText.contains("복귀는 실행하지"), "approved key binds challenge owner/pairing and is not return")
    let restored = IPadSentryReturnKeys(store: store.store, adapter: adapter)
    check(restored.approved(binding: binding)?.keyID == keyID && creates == 1, "key metadata readback restart preserves key without create")
    try inFlightSignatureChecks(store: store, owner: owner, keyID: keyID, privateKey: privateKey, fixturePublic: fixturePublic)
    var proofConsumer = consumer(); _ = start(&proofConsumer); receive(&proofConsumer, raw("pendingStateRaw"))
    let proof = proofConsumer.beginProof(approvedOwner: owner, keyID: keyID, binding: binding, from: ObjectIdentifier(peer), now: 3)!
    let (signature, der) = try keys.sign(proof, operation: .init())
    check(proofConsumer.finishProof(proof, signature: signature, publicKey: der, now: 4) != nil && signs == 1, "injected key signs exact received bytes")
    let cancelledOp = IPadSentryReturnKeys.Operation(); cancelledOp.cancel()
    check((try? keys.sign(proof, operation: cancelledOp)) == nil && signs == 1, "cancelled authentication cannot sign")
    check(proofConsumer.finishProof(proof, signature: Data(repeating: 0, count: 64), publicKey: der, now: 4) == nil, "raw64 signature rejected")
    check(proofConsumer.finishProof(proof, signature: signature, publicKey: privateKey.publicKey.x963Representation, now: 4) == nil, "point65 public key rejected")
    let doubleHash = try privateKey.signature(for: Data(SHA256.hash(data: proof.bytes))).derRepresentation
    check(proofConsumer.finishProof(proof, signature: doubleHash, publicKey: der, now: 4) == nil, "double SHA256 signature rejected")
    _ = proofConsumer.cancel(binding: binding, from: ObjectIdentifier(peer), now: 5)
    check(proofConsumer.finishProof(proof, signature: signature, publicKey: der, now: 6) == nil, "late signature after cancel cannot produce proof packet")
    wiringChecks(keys: keys, keyID: keyID)
    let rotationID = "00000009-1111-4111-8111-111111111111"
    _ = try keys.prepare(binding: binding, rotating: true, operation: .init(), keyID: rotationID)
    let rotate = try SentryReturnKeyEnrollment(action: .rotate, keyID: rotationID, publicKey: der.base64EncodedString(), previousKeyID: keyID)
    let rotation = try SentryReturnRequest(lease: request.lease, authMode: .macLocal, keyEnrollment: rotate)
    var rc = consumer(); _ = start(&rc, request: rotation); receive(&rc, challengeState(for: rotation)); receive(&rc, completed(for: rotation, code: .keyRotated))
    try keys.acceptEnrollment(rc.latest!)
    check(keys.approved(binding: binding)?.keyID == rotationID && (try? keys.sign(proof, operation: .init())) == nil, "rotation retires prior key and rejects late previous proof")
    let revoke = try SentryReturnRequest(lease: request.lease, authMode: .macLocal,
        keyEnrollment: .init(action: .revoke, keyID: rotationID))
    var vc = consumer(); _ = start(&vc, request: revoke); receive(&vc, challengeState(for: revoke)); receive(&vc, completed(for: revoke, code: .keyRevoked))
    try keys.acceptEnrollment(vc.latest!)
    check(keys.approved(binding: binding) == nil && store.data != nil, "revoke disables record and preserves key storage")
    try keys.acceptEnrollment(c.latest!)
    check(keys.approved(binding: binding) == nil, "historical keyEnrolled query never reactivates rotated or revoked key")
    let failingStore = Memory(); failingStore.drop = true
    let badKeys = IPadSentryReturnKeys(store: failingStore.store, adapter: adapter)
    check((try? badKeys.prepare(binding: binding, rotating: false, operation: .init())) == nil && creates == 2, "failed key intent readback stops creation")
}

func inFlightSignatureChecks(store: Memory, owner: IPadSentryReturn.Owner, keyID: String,
                             privateKey: P256.Signing.PrivateKey, fixturePublic: P256.Signing.PublicKey) throws {
    var c = consumer(); _ = start(&c); receive(&c, raw("pendingStateRaw"))
    let proof = c.beginProof(approvedOwner: owner, keyID: keyID, binding: binding, from: ObjectIdentifier(peer), now: 3)!
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let adapter = IPadSentryReturnKeys.Adapter(create: { _ in fatalError("unexpected create") }, sign: { _, bytes, _ in
        entered.signal(); _ = release.wait(timeout: .now() + 3)
        return try privateKey.signature(for: bytes).derRepresentation
    })
    let keys = IPadSentryReturnKeys(store: store.store, adapter: adapter)
    let result = SignatureResult()
    DispatchQueue.global().async {
        result.succeeded = (try? keys.sign(proof, operation: .init())) != nil
        finished.signal()
    }
    check(entered.wait(timeout: .now() + 3) == .success, "fixture signature is in flight before invalidation")
    keys.invalidateSignatures(); release.signal()
    check(finished.wait(timeout: .now() + 3) == .success && !result.succeeded,
        "key generation invalidation rejects late in-flight signature")
    check(fixturePublic.derRepresentation.count == 91, "fixture key remains SPKI91")
}
final class SignatureResult {
    private let lock = NSLock()
    private var value = false
    var succeeded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

func transportChecks(out: IPadSentryReturn.Outbound) {
    let link = SessionLink(); link.connection = peer
    let otherBefore = other.sent.count
    _ = link.hold(peer)
    let submission = SessionLink.Submission { _ in }
    let ticket = out.admission
    let before = peer.sent.count
    _ = link.send(out.bytes, onlyOn: peer, submission: submission, admit: { ticket.permits() })
    link.cancel(submission); _ = link.unhold(peer)
    check(peer.sent.count == before, "actual SessionLink cancelled hold cannot submit")
    _ = link.hold(peer)
    _ = link.send(out.bytes, onlyOn: peer, submission: .init { _ in }, admit: { ticket.permits() })
    _ = link.adopt(other); _ = link.unhold(other)
    check(other.sent.count == otherBefore, "actual SessionLink held request never follows replacement peer")
    link.connection = peer; _ = link.hold(peer)
    let gate = IPadSentryReturnAdmission(); let inactive = gate.ticket()
    _ = link.send(out.bytes, onlyOn: peer, submission: .init { _ in }, admit: { inactive.permits() })
    gate.invalidate(); _ = link.unhold(peer)
    check(peer.sent.count == before, "background immutable admission rejects held proof/enrollment")
    let nonce = Data([8, 9]); link.handOver(from: peer, to: other, fencePing: Data([0]), nonce: nonce)
    let live = gate.ticket(); _ = link.send(out.bytes, onlyOn: other, submission: .init { _ in }, admit: { live.permits() })
    gate.invalidate(); _ = link.fenceReturned(nonce, on: peer)
    check(other.sent.count == otherBefore, "handover fence rechecks immutable admission without main queue")
}

func wiringChecks(keys: IPadSentryReturnKeys, keyID: String) {
    func spin(_ until: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !until() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    let client = StreamClient(); client.connection = peer; client.sentryReturn = consumer(); client.sentryReturnKeys = keys
    let before = peer.sent.count
    client.requestIPadSentryReturn(mode: .deviceBoundKey)
    let active = client.sentryReturn.latest!.request
    client.receiveIPadSentryReturn(challengeState(for: active, keyID: keyID), from: peer)
    spin { peer.sent.count >= before + 2 }
    check(peer.sent.count == before + 2 && peer.sent.last?.first == 223 && client.sentryReturnDeviceIntent == nil,
        "explicit device intent follows same challenge to one native fixture signature")
    let afterProof = peer.sent.count
    client.receiveIPadSentryReturn(challengeState(for: active, keyID: keyID), from: peer)
    spin { client.sentryReturnKeyOperation == nil }
    check(peer.sent.count == afterProof, "duplicate pending cannot reuse consumed device intent")
    client.queryIPadSentryReturn()
    check(client.sentryReturnDeviceIntent == nil, "explicit current has no native authentication intent")
    client.invalidateIPadSentryReturn()
    check(client.sentryReturnKeyOperation == nil && client.sentryReturnDeviceIntent == nil, "inactive lifecycle clears operation and one-shot intent")

    let held = StreamClient(); held.connection = peer; held.sentryReturn = consumer(); held.sentryReturnKeys = keys
    _ = held.link.hold(peer)
    let heldStart = peer.sent.count
    held.requestIPadSentryReturn(mode: .macLocal)
    held.cancelIPadSentryReturn(); _ = held.link.unhold(peer)
    check(peer.sent.count == heldStart, "actual wiring cancels held request before challenge without forwarding")
    check(held.sentryReturn.latest?.locallyCancelled == true, "held cancellation preserves request rather than false effect-zero completion")
    let reset = StreamClient(); reset.connection = peer; reset.sentryReturn = consumer(); reset.sentryReturnKeys = keys
    reset.requestIPadSentryReturn(mode: .macLocal)
    let original = reset.sentryReturn.latest!.request
    reset.observeIPadSentryReturn(catalog: changed(catalog()) { $0.removeValue(forKey: "sentry") }, from: peer)
    let beforeCurrent = peer.sent.count
    reset.queryIPadSentryReturn()
    let query = peer.sent.last.map { Data($0.dropFirst(StreamMessage.headerLength)) }
    check(peer.sent.count == beforeCurrent + 1 && query == (try? SentryReturnControl.current(original.reference).encodedPayload()),
        "actual send wiring current succeeds with no current lease")
    reset.requestIPadSentryReturn(mode: .macLocal)
    check(peer.sent.count == beforeCurrent + 1 && reset.sentryReturn.latest?.request.reference == original.reference,
        "actual wiring no new request after lease disappears")

    let bg = StreamClient(); bg.connection = peer; bg.sentryReturn = consumer(); bg.sentryReturnKeys = keys
    _ = bg.link.hold(peer)
    let backgroundStart = peer.sent.count
    bg.requestIPadSentryReturn(mode: .deviceBoundKey)
    bg.appInForeground = false; bg.invalidateIPadSentryReturn(); _ = bg.link.unhold(peer)
    check(peer.sent.count == backgroundStart && bg.sentryReturnDeviceIntent == nil, "actual wiring background blocks held request and invalidates intent")
    let trustChanges: [(String, (StreamClient) -> Void)] = [
        ("revoked", { $0.savedMacs[0].revoked = true }),
        ("newKey", { $0.savedMacs[0].newKey = true }),
        ("pin", { $0.savedMacs[0].fingerprintData = Data(repeating: 9, count: 32) }),
        ("removed", { $0.savedMacs = [] }),
        ("session-owner", { $0.session?.macID = "differentMac" }),
        ("session-pin", { $0.session?.home = .saved(pin: Data(repeating: 7, count: 32)) }),
        ("disconnected", { $0.connected = false })
    ]
    for (name, change) in trustChanges {
        for operation in ["request", "proof", "enrollment"] {
            let c = StreamClient(); c.connection = peer; c.sentryReturn = consumer(); c.sentryReturnKeys = keys
            if operation == "proof" { c.requestIPadSentryReturn(mode: .deviceBoundKey) }
            _ = c.link.hold(peer)
            let count = peer.sent.count
            if operation == "proof" {
                c.receiveIPadSentryReturn(challengeState(for: c.sentryReturn.latest!.request, keyID: keyID), from: peer)
                spin { c.sentryReturn.latest?.proofStarted == true && c.sentryReturnKeyOperation == nil }
                check(c.sentryReturn.latest?.proofStarted == true, "proof prepared before held trust change \(name)")
            } else if operation == "enrollment" { c.manageIPadSentryReturnKey(.revoke) }
            else { c.requestIPadSentryReturn(mode: .macLocal) }
            let ticket = c.sentryReturn.admission.ticket()
            change(c)
            _ = c.link.unhold(peer)
            check(!ticket.permits() && peer.sent.count == count && c.sentryReturn.context == nil && c.sentryReturnDeviceIntent == nil,
                "actual saved/session observer invalidates held \(operation) on \(name)")
        }
    }
    let moving = StreamClient(); moving.connection = peer; moving.sentryReturn = consumer(); moving.sentryReturnKeys = keys
    _ = moving.link.hold(peer); moving.requestIPadSentryReturn(mode: .macLocal)
    let movedReference = moving.sentryReturn.latest?.request.reference
    let oldCount = other.sent.count
    moving.invalidateIPadSentryReturn(); moving.sentryReturn.bind(ObjectIdentifier(other))
    _ = moving.link.adopt(other)
    check(other.sent.count == oldCount && moving.sentryReturn.latest?.request.reference == movedReference,
        "handover cancels old intent and preserves original request without forwarding")
    moving.observeIPadSentryReturn(catalog: catalog(), from: other)
    moving.queryIPadSentryReturn()
    check(other.sent.count == oldCount + 1,
        "new pinned connection permits only explicit current after new catalog")
}


func spinMain(_ until: () -> Bool) {
    let end = Date().addingTimeInterval(3)
    while !until() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

func lifecycleChecks() throws {
    let fixtureKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
    let keyID = "00000008-1111-4111-8111-111111111111"
    for stop in ["resume", "background", "cancel", "trust", "handover", "lease", "expiry", "timeout", "no-context"] {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let store = Memory()
        let keys = IPadSentryReturnKeys(store: store.store, adapter: .init(create: { _ in
            .init(opaqueKey: Data([1]), publicKey: fixtureKey.publicKey.derRepresentation)
        }, sign: { _, bytes, op in
            if stop != "no-context" { try op.installCancellation {} }
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw IPadSentryReturnKeys.Failure.cancelled }
            return try fixtureKey.signature(for: bytes).derRepresentation
        }))
        _ = try keys.prepare(binding: binding, rotating: false, operation: .init(), keyID: keyID)
        var enrollment = consumer(); let enrollmentRequest = try SentryReturnRequest(rawRequest: raw("enrollRaw"))
        _ = start(&enrollment, request: enrollmentRequest)
        receive(&enrollment, challengeState(for: enrollmentRequest)); receive(&enrollment, completed(for: enrollmentRequest, code: .keyEnrolled))
        try keys.acceptEnrollment(enrollment.latest!)
        let c = StreamClient(); c.connection = peer; c.sentryReturn = consumer(); c.sentryReturnKeys = keys
        c.requestIPadSentryReturn(mode: .deviceBoundKey)
        let original = c.sentryReturn.latest!.request
        c.receiveIPadSentryReturn(challengeState(for: original, keyID: keyID), from: peer)
        spinMain { c.sentryReturnKeyOperation != nil }
        check(entered.wait(timeout: .now() + 3) == .success, "native fixture entered before inactive \(stop)")
        let operation = c.sentryReturnKeyOperation!
        let ticket = c.sentryReturn.admission.ticket()
        let count = peer.sent.count
        c.resignActive()
        if stop == "no-context" {
            check(c.sentryReturnKeyOperation == nil && !ticket.permits(), "inactive without native context cancels operation and ticket")
        } else {
            check(c.sentryReturnKeyOperation === operation && ticket.permits(), "own native context survives temporary inactive \(stop)")
        }
        release.signal()
        spinMain { c.sentryReturnKeyCompletion != nil || c.sentryReturnKeyOperation == nil }
        check(peer.sent.count == count, "native result sends zero while inactive \(stop)")
        if stop != "no-context" {
            check(c.sentryReturnKeyCompletion != nil && c.sentryReturnKeyOperation === operation, "inactive result retained on same operation \(stop)")
        }
        switch stop {
        case "background": c.enterBackground()
        case "cancel": c.cancelIPadSentryReturn()
        case "trust": c.savedMacs[0].revoked = true
        case "handover": c.connection = other; c.sentryReturn.bind(ObjectIdentifier(other))
        case "lease":
            let changedLease = try SentryReturnLease(hostBootID: original.lease.hostBootID, sessionID: UUID().uuidString.lowercased(),
                revision: original.lease.revision, authorizationGeneration: original.lease.authorizationGeneration)
            c.observeIPadSentryReturn(catalog: catalog(changedLease), from: peer)
        case "expiry": c.checkReturnTimeout(now: ProcessInfo.processInfo.systemUptime + 121)
        case "timeout": _ = c.sentryReturn.query(binding: binding, from: ObjectIdentifier(peer), now: 1); c.checkReturnTimeout(now: 12)
        default: break
        }
        c.becomeActive(); c.becomeActive()
        spinMain { c.sentryReturnKeyOperation == nil }
        check(peer.sent.count == count + (stop == "resume" ? 1 : 0), "active completes original once or drops invalid result \(stop)")
        check(c.sentryReturnKeyCompletion == nil && c.sentryReturnKeyOperation == nil, "completion and operation cleared \(stop)")
        check(c.sentryReturn.latest?.request.reference == original.reference && c.sentryReturn.latest?.proofStarted == true,
            "lifecycle never creates new request or restarts proof \(stop)")
        if stop == "resume" {
            let sent = try SentryReturnControl.decodePayload(Data(peer.sent.last!.dropFirst(StreamMessage.headerLength)))
            if case .prove(let reference, let generation, _) = sent {
                check(reference == original.reference && generation == (try! SentryReturnState.decodePayload(challengeState(for: original, keyID: keyID))).authGeneration,
                    "active sends proof for original reference and generation")
            } else { check(false, "active must send original proof") }
        }
    }
    let op = IPadSentryReturnKeys.Operation(); op.cancel()
    check((try? op.installCancellation {}) == nil, "context installed after cancellation is rejected")
}

func lateCancelChecks() {
    let c = StreamClient(); c.connection = peer; c.sentryReturn = consumer()
    c.requestIPadSentryReturn(mode: .macLocal)
    let original = c.sentryReturn.latest!.request
    let count = peer.sent.count
    c.cancelIPadSentryReturn()
    check(peer.sent.count == count && c.sentryReturn.latest?.locallyCancelled == true, "cancel before first challenge preserves intent with zero packet")
    let challenge = challengeState(for: original)
    c.receiveIPadSentryReturn(challenge, from: peer)
    spinMain { peer.sent.count > count }
    check(peer.sent.count == count + 1, "late verified challenge forwards original cancellation exactly once through SessionLink")
    let generation = try! SentryReturnState.decodePayload(challenge).authGeneration!
    check(Data(peer.sent.last!.dropFirst(StreamMessage.headerLength)) == (try? SentryReturnControl.cancel(original.reference, authGeneration: generation).encodedPayload()),
        "late cancellation preserves raw reference and received generation")
    c.receiveIPadSentryReturn(challenge, from: peer)
    c.receiveIPadSentryReturn(challenge, from: peer)
    DispatchQueue.main.async { c.becomeActive() }
    spinMain { c.sentryReturnSubmissions.isEmpty }
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    check(peer.sent.count == count + 1 && !c.sentryReturn.canProve && c.sentryReturnKeyOperation == nil,
        "duplicate late challenges never resend or start native authentication")
    check(c.sentryReturn.latest?.rawChallengeState == challenge && c.sentryReturn.originalRequest == original.rawRequest,
        "late cancellation keeps original intent and raw challenge")
}

func cancelTerminalChecks() {
    let pending = raw("pendingStateRaw")
    let generation = try! SentryReturnState.decodePayload(pending).authGeneration!
    let cases: [(SentryReturnState.OperationState, SentryReturnState.AuthStatus, SentryReturnState.Code)] = [
        (.expired, .expired, .expired), (.failed, .failed, .authenticationFailed), (.rejected, .pending, .invalidProof)]
    for (terminal, auth, code) in cases {
        let store = Memory(); var c = consumer(store); _ = start(&c); receive(&c, pending)
        _ = c.cancel(binding: binding, from: ObjectIdentifier(peer), now: 3)
        let rawTerminal = try! SentryReturnState(reference: request.reference, authGeneration: generation, authStatus: auth,
            operationState: terminal, code: code, challenge: nil, remainingMilliseconds: 0).encodedPayload()
        let wrongGeneration = changed(rawTerminal) { $0["authGeneration"] = UUID().uuidString.lowercased() }
        check(!receive(&c, wrongGeneration), "cancel terminal rejects changed generation \(terminal)")
        check(receive(&c, rawTerminal) && c.latest?.terminal == true && c.canRequest, "cancel race accepts non-success terminal and reopens explicit request \(terminal)")
        check(c.latest?.locallyCancelled == true && c.latest?.rawState == rawTerminal, "cancel intent and terminal raw preserved \(terminal)")
        var reopened = consumer(store)
        let current = reopened.query(binding: binding, from: ObjectIdentifier(peer), now: 4)
        check(current.map { Data($0.bytes.dropFirst(StreamMessage.headerLength)) } == raw("currentRaw") && receive(&reopened, rawTerminal) && reopened.canRequest,
            "reopen and explicit current keep non-success terminal \(terminal)")
        let next = reopened.request(mode: .macLocal, binding: binding, from: ObjectIdentifier(peer), now: 5)
        check(next != nil && reopened.latest?.request.reference != request.reference, "new request requires explicit action after terminal \(terminal)")
    }
    var cancelled = consumer(); _ = start(&cancelled); receive(&cancelled, pending)
    _ = cancelled.cancel(binding: binding, from: ObjectIdentifier(peer), now: 3)
    check(!receive(&cancelled, raw("completedStateRaw")) && !cancelled.canRequest && cancelled.latest?.locallyCancelled == true,
        "late success after cancel remains effect-unknown without execution authority")
}
