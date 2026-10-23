import Foundation
import CryptoKit
import Security
import StreamProtocol

private struct ProviderKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func providerExactKeys(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
    let keys = Set(try decoder.container(keyedBy: ProviderKey.self).allKeys.map(\.stringValue))
    guard keys.isSuperset(of: required), keys.isSubset(of: required.union(optional)) else {
        throw ProviderCallFailure.invalidFields
    }
}

func providerSameSnapshot(_ first: AudioForwardingSnapshot?, _ second: AudioForwardingSnapshot?) -> Bool {
    guard let first, let second else { return first == nil && second == nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let left = try? encoder.encode(first), let right = try? encoder.encode(second) else { return false }
    return left == right
}

enum ProviderCallFailure: Error {
    case invalidFields, invalidRequest, invalidTarget, invalidScope, invalidIdentity, expired, superseded, unavailable
}

struct ProviderCallRequest: Codable, Equatable {
    enum Action: String, Codable { case start, stop }
    let requestId: UUID
    let action: Action
    let expectedLeaseRevision: AudioForwardingRevision
    let pairedDeviceId: AudioForwardingDeviceID
    let desiredInput: Bool
    let desiredOutput: Bool
    let callSessionId: String?
    enum CodingKeys: String, CodingKey, CaseIterable {
        case requestId, action, expectedLeaseRevision, pairedDeviceId, desiredInput, desiredOutput, callSessionId
    }
    init(from decoder: Decoder) throws {
        try providerExactKeys(decoder, required: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .requestId)
        guard let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw.lowercased() else {
            throw ProviderCallFailure.invalidRequest
        }
        requestId = id
        action = try c.decode(Action.self, forKey: .action)
        expectedLeaseRevision = try c.decode(AudioForwardingRevision.self, forKey: .expectedLeaseRevision)
        pairedDeviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .pairedDeviceId)
        desiredInput = try c.decode(Bool.self, forKey: .desiredInput)
        desiredOutput = try c.decode(Bool.self, forKey: .desiredOutput)
        callSessionId = try c.decodeIfPresent(String.self, forKey: .callSessionId)
        guard action != .start || callSessionId == nil,
              callSessionId.map({ !$0.isEmpty && $0.utf16.count <= 128 }) ?? true else {
            throw ProviderCallFailure.invalidRequest
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try c.encode(action, forKey: .action)
        try c.encode(expectedLeaseRevision, forKey: .expectedLeaseRevision)
        try c.encode(pairedDeviceId, forKey: .pairedDeviceId)
        try c.encode(desiredInput, forKey: .desiredInput)
        try c.encode(desiredOutput, forKey: .desiredOutput)
        try c.encode(callSessionId, forKey: .callSessionId)
    }
    var digest: String {
        var data = Data("ccr-provider-request-v1\0".utf8)
        func append(_ text: String) {
            let bytes = Data(text.utf8)
            var size = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        append(requestId.uuidString.lowercased())
        append(action.rawValue)
        append(String(expectedLeaseRevision.value))
        append(pairedDeviceId.hex)
        data.append(desiredInput ? 1 : 0)
        data.append(desiredOutput ? 1 : 0)
        data.append(callSessionId == nil ? 0 : 1)
        if let callSessionId { append(callSessionId) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func matches(_ snapshot: AudioForwardingSnapshot) -> Bool {
        snapshot.revision == expectedLeaseRevision && snapshot.intent?.pairedDeviceId == pairedDeviceId &&
            snapshot.intent?.inputDesired == desiredInput && snapshot.intent?.outputDesired == desiredOutput &&
            snapshot.binding?.pairedDeviceId == pairedDeviceId &&
            (snapshot.binding?.phase == .active || action == .stop && snapshot.binding?.phase == .off)
    }
}

struct ProviderCallTarget: Decodable, Equatable {
    let profileId: String
    let leafId: String
    let guestId: UInt64
    let url: String
    let timeOrigin: Double
    private enum CodingKeys: String, CodingKey, CaseIterable { case profileId, leafId, guestId, url, timeOrigin }
    init(from decoder: Decoder) throws {
        try providerExactKeys(decoder, required: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(String.self, forKey: .profileId)
        leafId = try c.decode(String.self, forKey: .leafId)
        guestId = try c.decode(UInt64.self, forKey: .guestId)
        url = try c.decode(String.self, forKey: .url)
        timeOrigin = try c.decode(Double.self, forKey: .timeOrigin)
        _ = try hash()
    }
    func hash() throws -> String {
        guard profileId == "codex-control-room-chatgpt-dots",
              leafId.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
              guestId > 0, guestId <= 9_007_199_254_740_991,
              timeOrigin.isFinite, timeOrigin > 0,
              url.utf8.count <= 2048, url.hasPrefix("https://chatgpt.com/dots/"),
              let parsed = URLComponents(string: url), parsed.scheme == "https", parsed.host == "chatgpt.com",
              parsed.port == nil, parsed.user == nil, parsed.password == nil,
              parsed.query == nil, parsed.fragment == nil else { throw ProviderCallFailure.invalidTarget }
        var bits = timeOrigin.bitPattern.bigEndian
        let clock = withUnsafeBytes(of: &bits) { Data($0).map { String(format: "%02x", $0) }.joined() }
        let bytes = try JSONSerialization.data(withJSONObject:
            ["ccr-provider-target-v1", profileId, leafId, String(guestId), url, clock], options: [.withoutEscapingSlashes])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct ProviderCallScope: Decodable {
    enum State: String, Decodable { case prepared, dispatchAuthorized = "dispatch_authorized", recorded }
    enum Outcome: String, Codable { case notDispatched = "not_dispatched", dispatched, unknown }
    let schemaVersion: Int
    let state: State
    let requestId: UUID
    let scopeId: UUID?
    let nodeGeneration: UUID
    let outcome: Outcome
    let reason: String?
    let remainingMilliseconds: Int
    let snapshot: AudioForwardingSnapshot?
    enum CodingKeys: String, CodingKey {
        case schemaVersion, state, requestId, scopeId, nodeGeneration, outcome, reason, remainingMilliseconds, snapshot
    }
    init(from decoder: Decoder) throws {
        try providerExactKeys(decoder, required: ["schemaVersion", "state", "requestId", "nodeGeneration",
            "outcome", "reason", "remainingMilliseconds"], optional: ["scopeId", "snapshot"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        state = try c.decode(State.self, forKey: .state)
        requestId = try c.decode(UUID.self, forKey: .requestId)
        scopeId = try c.decodeIfPresent(UUID.self, forKey: .scopeId)
        nodeGeneration = try c.decode(UUID.self, forKey: .nodeGeneration)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        remainingMilliseconds = try c.decode(Int.self, forKey: .remainingMilliseconds)
        snapshot = try c.decodeIfPresent(AudioForwardingSnapshot.self, forKey: .snapshot)
        guard schemaVersion == 1, (0...1500).contains(remainingMilliseconds),
              reason.map({ $0.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil }) ?? true else {
            throw ProviderCallFailure.invalidScope
        }
        if state != .recorded {
            guard scopeId != nil, snapshot != nil, remainingMilliseconds > 0,
                  state == .prepared ? outcome == .notDispatched : outcome == .unknown else {
                throw ProviderCallFailure.invalidScope
            }
        }
    }
}

struct ProviderCallSignedEnvelope: Encodable {
    let payload: String
    let signature: String
    let publicSPKI: String
}

@MainActor
struct ProviderCallSigner {
    let identity: HostIdentity
    func identityProof(_ challenge: ProviderCallChallenge, request: ProviderCallRequest) throws -> ProviderCallSignedEnvelope {
        try challenge.validate(request)
        let body = ProviderIdentityBody(schemaVersion: 1, purpose: "ccr-provider-identity-v1",
            challenge: challenge.challenge, coreGeneration: challenge.coreGeneration.uuidString.lowercased(),
            requestId: request.requestId.uuidString.lowercased(), requestDigest: request.digest, macFingerprint: identity.fingerprint.hexString)
        return try sign(body, purpose: body.purpose)
    }
    func dispatchProof(_ approval: ProviderCallApproval,
                       context: AudioForwardingConnectionContext) throws -> ProviderCallSignedEnvelope {
        let request = approval.request, scope = approval.scope, challenge = approval.challenge
        let remainingMilliseconds = approval.remainingMilliseconds
        try challenge.validate(request)
        guard approval.isCurrent, challenge.targetHash == approval.targetHash, context.isCurrent(), request.pairedDeviceId == context.peer.id,
              context.principal.id == context.peer.id,
              context.principal.authorizationGeneration == context.peer.pairingGeneration,
              scope.state == .dispatchAuthorized, scope.requestId == request.requestId,
              let scopeId = scope.scopeId, let snapshot = scope.snapshot, request.matches(snapshot),
              let intent = snapshot.intent, let binding = snapshot.binding,
              remainingMilliseconds > 0, remainingMilliseconds <= scope.remainingMilliseconds else {
            throw ProviderCallFailure.invalidScope
        }
        let body = ProviderDispatchBody(schemaVersion: 1, purpose: "ccr-provider-dispatch-v1",
            request: request, requestDigest: request.digest, challenge: challenge.challenge,
            coreGeneration: challenge.coreGeneration.uuidString.lowercased(), targetHash: challenge.targetHash,
            pairedDeviceId: context.peer.id, pairingGeneration: context.peer.pairingGeneration.uuidString.lowercased(),
            authorizationGeneration: context.principal.authorizationGeneration.uuidString.lowercased(),
            scopeId: scopeId.uuidString.lowercased(), nodeGeneration: scope.nodeGeneration.uuidString.lowercased(),
            intentGeneration: intent.intentGeneration.uuidString.lowercased(), bindingEpoch: binding.bindingEpoch.uuidString.lowercased(),
            macFingerprint: identity.fingerprint.hexString, remainingMilliseconds: remainingMilliseconds)
        guard approval.claimProof() else { throw ProviderCallFailure.superseded }
        let proof = try sign(body, purpose: body.purpose)
        guard approval.isCurrent else { throw ProviderCallFailure.expired }
        return proof
    }
    private func sign<T: Encodable>(_ payload: T, purpose: String) throws -> ProviderCallSignedEnvelope {
        guard ["ccr-provider-identity-v1", "ccr-provider-dispatch-v1"].contains(purpose),
              let key = SecCertificateCopyKey(identity.remote.certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?, point.count == 65, point.first == 4 else {
            throw ProviderCallFailure.invalidIdentity
        }
        let publicDER = SPKI.der(point: point)
        guard Data(SHA256.hash(data: publicDER)) == identity.fingerprint else { throw ProviderCallFailure.invalidIdentity }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(payload)
        guard bytes.count <= 16_384 else { throw ProviderCallFailure.invalidFields }
        let message = Data((purpose + "\0").utf8) + bytes
        guard let signature = identity.signRecord(message), identity.verifyRecord(message, signature: signature) else {
            throw ProviderCallFailure.invalidIdentity
        }
        return ProviderCallSignedEnvelope(payload: Base64URL.encode(bytes), signature: Base64URL.encode(signature),
            publicSPKI: Base64URL.encode(publicDER))
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

struct ProviderCallChallenge: Decodable {
    let schemaVersion: Int
    let challenge: String
    let coreGeneration: UUID
    let requestId: UUID
    let target: ProviderCallTarget
    let targetHash: String
    let guestNowMs: Double
    let remainingMilliseconds: Int
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, challenge, coreGeneration, requestId, target, targetHash, guestNowMs, remainingMilliseconds
    }
    init(from decoder: Decoder) throws {
        try providerExactKeys(decoder, required: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        challenge = try c.decode(String.self, forKey: .challenge)
        coreGeneration = try c.decode(UUID.self, forKey: .coreGeneration)
        requestId = try c.decode(UUID.self, forKey: .requestId)
        target = try c.decode(ProviderCallTarget.self, forKey: .target)
        targetHash = try c.decode(String.self, forKey: .targetHash)
        guestNowMs = try c.decode(Double.self, forKey: .guestNowMs)
        remainingMilliseconds = try c.decode(Int.self, forKey: .remainingMilliseconds)
    }
    func validate(_ request: ProviderCallRequest) throws {
        guard schemaVersion == 1, requestId == request.requestId,
              Base64URL.decode(challenge)?.count == 32,
              targetHash == (try target.hash()), guestNowMs.isFinite, guestNowMs >= 0,
              (1...1500).contains(remainingMilliseconds) else { throw ProviderCallFailure.invalidTarget }
    }
}

private struct ProviderIdentityBody: Encodable {
    let schemaVersion: Int
    let purpose: String
    let challenge: String
    let coreGeneration: String
    let requestId: String
    let requestDigest: String
    let macFingerprint: String
}

private struct ProviderDispatchBody: Encodable {
    let schemaVersion: Int
    let purpose: String
    let request: ProviderCallRequest
    let requestDigest: String
    let challenge: String
    let coreGeneration: String
    let targetHash: String
    let pairedDeviceId: AudioForwardingDeviceID
    let pairingGeneration: String
    let authorizationGeneration: String
    let scopeId: String
    let nodeGeneration: String
    let intentGeneration: String
    let bindingEpoch: String
    let macFingerprint: String
    let remainingMilliseconds: Int
}
