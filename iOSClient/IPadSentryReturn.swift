import Foundation
import CryptoKit
import StreamProtocol

/// Main 소유 원장. 관찰은 명령을 만들지 않으며 저장 실패는 해당 인스턴스의 송신을 닫는다.
struct IPadSentryReturn {
    typealias Binding = IPadSentryControl.Binding
    struct Store {
        let load: () throws -> Data?
        let compareAndSwap: (Data?, Data) throws -> Void
        static func defaults(_ defaults: UserDefaults = .standard) -> Self {
            let key = "Sill.sentryReturn.ledger.v1"
            return .init(load: { defaults.data(forKey: key) }, compareAndSwap: { old, new in
                guard defaults.data(forKey: key) == old else { throw Failure.storage }
                defaults.set(new, forKey: key)
                guard defaults.synchronize(), defaults.data(forKey: key) == new else { throw Failure.storage }
            })
        }
    }
    enum Failure: Error { case binding, storage }
    struct Owner: Codable, Equatable {
        let binding: Binding
        let ownerID: String
        let pairingGeneration: String
        init(binding: Binding, challenge: SentryReturnChallenge) throws {
            guard challenge.hostFingerprint == binding.hostPin.hex,
                  challenge.deviceFingerprint == binding.deviceFingerprint.hex else { throw Failure.binding }
            self.binding = binding; ownerID = challenge.ownerID; pairingGeneration = challenge.pairingGeneration
        }
    }
    struct Context: Equatable {
        let binding: Binding
        let lease: SentryReturnLease?
        let capability: SentryReturnCapability
    }
    struct Entry: Codable {
        let binding: Binding
        let rawRequest: Data
        var rawState: Data?
        var rawChallengeState: Data?
        var unboundCompletion: Data?
        var locallyCancelled = false
        var cancelForwarded: Bool?
        var proofStarted = false
        var request: SentryReturnRequest { try! .init(rawRequest: rawRequest) }
        var state: SentryReturnState? { rawState.flatMap { try? .decodePayload($0) } }
        var terminal: Bool {
            guard unboundCompletion == nil else { return false }
            guard let state else { return false }
            return [.completed, .cancelled, .expired, .rejected, .failed].contains(state.operationState)
        }
    }
    struct Proof {
        let reference: SentryReturnReference
        let challenge: SentryReturnChallenge
        let owner: Owner
        let bytes: Data
        let admission: IPadSentryReturnAdmission.Ticket
    }
    struct Outbound {
        let bytes: Data
        let admission: IPadSentryReturnAdmission.Ticket
    }

    private let store: Store
    let admission = IPadSentryReturnAdmission()
    private var storedBytes: Data?
    private var entries: [Entry] = []
    private var peer: ObjectIdentifier?
    private(set) var context: Context?
    private(set) var problem: String?
    private var storageFailed = false
    private var confirmed = false
    private var deadline: TimeInterval?
    private var challengeDeadline: TimeInterval?
    var latest: Entry? { entries.last }
    var originalRequest: Data? { latest?.rawRequest }
    var canRequest: Bool { !storageFailed && context?.lease != nil && (latest == nil || latest?.terminal == true) }
    var canQuery: Bool { !storageFailed && context?.binding == latest?.binding && latest != nil }
    var canCancel: Bool { canQuery && latest?.terminal == false && latest?.locallyCancelled == false }
    var canProve: Bool {
        confirmed && canCancel && latest?.request.authMode == .deviceBoundKey && latest?.state?.challenge != nil && latest?.proofStarted == false
    }

    init(store: Store) {
        self.store = store
        do {
            storedBytes = try store.load()
            if let storedBytes {
                let decoded = try JSONDecoder().decode([Entry].self, from: storedBytes)
                guard decoded.count <= 64 else { throw Failure.storage }
                var ids = Set<String>()
                for entry in decoded {
                    let request = try SentryReturnRequest(rawRequest: entry.rawRequest)
                    guard ids.insert(request.requestID).inserted, entry.binding.hostPin.count == 32, entry.binding.deviceFingerprint.count == 32,
                          !entry.binding.macID.isEmpty else { throw Failure.storage }
                    for raw in [entry.rawState, entry.rawChallengeState, entry.unboundCompletion].compactMap({ $0 }) {
                        let state = try SentryReturnState.decodePayload(raw)
                        guard state.reference == request.reference, Self.outcomeMatches(state, request) else { throw Failure.storage }
                        if let challenge = state.challenge {
                            guard challenge.lease == request.lease, challenge.authMode == request.authMode,
                                  (try? Owner(binding: entry.binding, challenge: challenge)) != nil else { throw Failure.storage }
                        }
                    }
                }
                entries = decoded
            }
        } catch { storageFailed = true; problem = "인증 복귀 원장을 확인하지 못했습니다. 자동 재요청하지 않습니다." }
    }

    mutating func bind(_ next: ObjectIdentifier?) {
        guard peer != next else { return }
        invalidate(); peer = next; context = nil
    }
    mutating func invalidate() { admission.invalidate(); confirmed = false; deadline = nil; challengeDeadline = nil }
    mutating func trustLost() { invalidate(); context = nil }

    mutating func observe(catalog: Data, binding: Binding?, from peer: ObjectIdentifier) {
        guard self.peer == peer else { return }
        guard let binding, let raw = Self.capabilityBytes(catalog),
              let capability = try? SentryReturnCapability.decodePayload(raw) else {
            invalidate(); context = nil; return
        }
        let lease: SentryReturnLease?
        if let state = IPadSentryObservation.decodeCatalog(catalog), IPadSentryObservation.isConsistent(state), let control = state.control {
            lease = try? SentryReturnLease(hostBootID: state.hostBootID.uuidString.lowercased(),
                sessionID: state.sessionID.uuidString.lowercased(), revision: state.revision.uuidString.lowercased(),
                authorizationGeneration: control.authorizationGeneration.uuidString.lowercased())
        } else { lease = nil }
        let next = Context(binding: binding, lease: lease, capability: capability)
        if context != next { invalidate() }
        context = next
    }

    mutating func request(mode: SentryReturnAuthMode, enrollment: SentryReturnKeyEnrollment? = nil,
                          binding: Binding?, from peer: ObjectIdentifier, now: TimeInterval,
                          requestID: String = UUID().uuidString.lowercased()) -> Outbound? {
        guard valid(binding, peer), canRequest, let context, let lease = context.lease,
              mode == .macLocal ? context.capability.macLocal : context.capability.deviceBoundKey,
              enrollment == nil || mode == .macLocal,
              !entries.contains(where: { $0.request.requestID == requestID }),
              let request = try? SentryReturnRequest(requestID: requestID, lease: lease, authMode: mode, keyEnrollment: enrollment) else { return nil }
        guard entries.count < 64 else { problem = "인증 복귀 원장이 가득 찼습니다. 기존 요청은 보존합니다."; return nil }
        var next = entries; next.append(.init(binding: context.binding, rawRequest: request.rawRequest))
        guard persist(next) else { return nil }
        challengeDeadline = nil
        return outbound(.request(request), now: now)
    }

    mutating func query(binding: Binding?, from peer: ObjectIdentifier, now: TimeInterval) -> Outbound? {
        guard valid(binding, peer), canQuery, let entry = latest else { return nil }
        // 정상 reset 이후 과거 결과 조회에는 원래 lease와 현재 lease의 동일성을 요구하지 않는다.
        return outbound(.current(entry.request.reference), now: now)
    }
    mutating func cancel(binding: Binding?, from peer: ObjectIdentifier, now: TimeInterval) -> Outbound? {
        guard valid(binding, peer), canCancel, var entry = latest else { return nil }
        invalidate(); entry.locallyCancelled = true; entry.cancelForwarded = false
        var next = entries; next[next.count - 1] = entry
        guard persist(next) else { return nil }
        return forwardCancellation(binding: binding, from: peer, now: now)
    }
    mutating func forwardCancellation(binding: Binding?, from peer: ObjectIdentifier, now: TimeInterval) -> Outbound? {
        guard valid(binding, peer), var entry = latest, entry.locallyCancelled, !entry.terminal,
              entry.cancelForwarded == false, let generation = entry.state?.authGeneration,
              now.isFinite, now >= 0 else { return nil }
        entry.cancelForwarded = true
        var next = entries; next[next.count - 1] = entry
        guard persist(next) else { return nil }
        return outbound(.cancel(entry.request.reference, authGeneration: generation), now: now)
    }

    mutating func receive(_ raw: Data, binding: Binding?, from peer: ObjectIdentifier, now: TimeInterval) -> Bool {
        guard valid(binding, peer), var entry = latest, entry.binding == binding,
              now.isFinite, now >= 0,
              let state = try? SentryReturnState.decodePayload(raw), state.reference == entry.request.reference,
              Self.outcomeMatches(state, entry.request) else { return false }
        if entry.rawState == raw { confirmed = true; deadline = nil; return true }
        if entry.unboundCompletion != nil { return false }
        if entry.terminal { return false }
        if entry.locallyCancelled {
            let lateChallenge = entry.state?.authGeneration == nil && entry.rawChallengeState == nil && state.challenge != nil
            guard lateChallenge || [.cancelled, .expired, .failed, .rejected, .unknown].contains(state.operationState) else { return false }
            if lateChallenge, entry.cancelForwarded == nil { entry.cancelForwarded = false }
        }
        if let prior = entry.state {
            guard prior.authGeneration == nil || prior.authGeneration == state.authGeneration,
                  prior.authStatus != .succeeded || state.authStatus == .succeeded,
                  ![.cancelled, .expired, .failed].contains(prior.authStatus) || state.authStatus == prior.authStatus,
                  prior.operationState != .restoring || state.operationState != .authenticating else { return false }
        }
        if let challenge = state.challenge {
            guard challenge.reference == entry.request.reference, challenge.lease == entry.request.lease,
                  challenge.authMode == entry.request.authMode,
                  context?.lease == challenge.lease,
                  (try? Owner(binding: entry.binding, challenge: challenge)) != nil else { return false }
            if let old = entry.rawChallengeState,
               (try? SentryReturnState.decodePayload(old).challenge) != challenge { return false }
            entry.rawChallengeState = raw
        }
        if state.operationState == .completed {
            guard state.authStatus == .succeeded else { return false }
            if let enrollment = entry.request.keyEnrollment {
                let expected: SentryReturnState.Code = enrollment.action == .enroll ? .keyEnrolled : enrollment.action == .rotate ? .keyRotated : .keyRevoked
                guard state.code == expected else { return false }
                if entry.rawChallengeState == nil {
                    entry.unboundCompletion = raw
                    var next = entries; next[next.count - 1] = entry
                    _ = persist(next); invalidate()
                    return false
                }
                entry.unboundCompletion = nil
            } else { guard state.code == .localReturned else { return false } }
        } else if [.keyEnrolled, .keyRotated, .keyRevoked, .localReturned].contains(state.code) { return false }
        entry.rawState = raw
        var next = entries; next[next.count - 1] = entry
        guard persist(next) else { return false }
        if entry.terminal { admission.invalidate(); challengeDeadline = nil }
        if state.challenge != nil {
            let received = now + Double(state.remainingMilliseconds) / 1000
            challengeDeadline = min(challengeDeadline ?? received, received)
        }
        confirmed = true; deadline = nil
        return true
    }

    mutating func beginProof(approvedOwner: Owner, keyID: String, binding: Binding?, from peer: ObjectIdentifier, now: TimeInterval) -> Proof? {
        guard valid(binding, peer), canProve, var entry = latest,
              let expires = challengeDeadline, now.isFinite, now >= 0, now < expires,
              let raw = entry.rawChallengeState, let state = try? SentryReturnState.decodePayload(raw),
              let challenge = state.challenge, challenge.keyID == keyID,
              let owner = try? Owner(binding: entry.binding, challenge: challenge), owner == approvedOwner,
              context?.lease == challenge.lease,
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let challengeObject = object["challenge"] as? [String: Any],
              let encoded = challengeObject["signingPayloadBase64"] as? String,
              let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded,
              bytes == (try? challenge.signingBytes()) else { return nil }
        admission.invalidate(); entry.proofStarted = true
        var next = entries; next[next.count - 1] = entry
        guard persist(next) else { return nil }
        return Proof(reference: challenge.reference, challenge: challenge, owner: owner, bytes: bytes, admission: admission.ticket())
    }
    mutating func finishProof(_ proof: Proof, signature: Data, publicKey: Data, now: TimeInterval) -> Outbound? {
        guard proof.admission.permits(), latest?.locallyCancelled == false, latest?.terminal == false,
              let expires = challengeDeadline, now.isFinite, now < expires,
              latest?.request.reference == proof.reference, context?.lease == proof.challenge.lease,
              let key = try? P256.Signing.PublicKey(derRepresentation: publicKey), publicKey.count == 91,
              let signatureValue = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              signatureValue.derRepresentation == signature, key.isValidSignature(signatureValue, for: proof.bytes) else { return nil }
        return outbound(.prove(proof.reference, authGeneration: proof.challenge.authGeneration, signature: signature), now: now)
    }

    @discardableResult mutating func checkTimeout(now: TimeInterval) -> Bool {
        if (deadline != nil || challengeDeadline != nil) && (!now.isFinite || now < 0) ||
            deadline.map({ now >= $0 || now < $0 - 10 }) == true || challengeDeadline.map({ now >= $0 }) == true {
            invalidate(); return true
        }
        return false
    }
    private func valid(_ binding: Binding?, _ peer: ObjectIdentifier) -> Bool {
        !storageFailed && self.peer == peer && binding != nil && context?.binding == binding
    }
    private mutating func outbound(_ control: SentryReturnControl, now: TimeInterval) -> Outbound? {
        guard now.isFinite, now >= 0, let bytes = try? control.encodedPayload() else { return nil }
        admission.invalidate(); deadline = now + 10; confirmed = false
        return .init(bytes: StreamMessage(kind: .sentryReturnRequest, timestamp: 0, isKeyframe: false, payload: bytes).serialized(), admission: admission.ticket())
    }
    private mutating func persist(_ next: [Entry]) -> Bool {
        do {
            let data = try JSONEncoder().encode(next)
            try store.compareAndSwap(storedBytes, data)
            guard try store.load() == data else { throw Failure.storage }
            storedBytes = data; entries = next; return true
        } catch {
            storageFailed = true; invalidate(); problem = "인증 복귀 저장을 확인하지 못했습니다. 원문을 보존하며 송신을 중단합니다."; return false
        }
    }
    private static func outcomeMatches(_ state: SentryReturnState, _ request: SentryReturnRequest) -> Bool {
        if state.operationState == .restoring {
            return request.keyEnrollment == nil && state.authStatus == .succeeded && state.code == .returnPrepared
        }
        guard state.operationState == .completed else { return true }
        guard let enrollment = request.keyEnrollment else { return state.code == .localReturned }
        let code: SentryReturnState.Code = enrollment.action == .enroll ? .keyEnrolled : enrollment.action == .rotate ? .keyRotated : .keyRevoked
        return state.code == code
    }
    var statusText: String {
        if let problem { return problem }
        guard context != nil else { return "이 호스트의 인증 복귀 지원을 확인하지 못했습니다." }
        guard let entry = latest else { return "명시적으로 인증 복귀 또는 키 등록을 요청할 수 있습니다." }
        if entry.unboundCompletion != nil { return "키 승인 결과의 소유자·페어링 결속 미확인 · 원문 보존 및 복구 자료 대기" }
        if entry.locallyCancelled { return "취소 요청 기록을 보존했습니다. 늦은 성공은 수용하지 않습니다." }
        guard confirmed, let state = entry.state else { return "인증 복귀 결과 미확인 · 원래 요청 보존" }
        if state.operationState == .completed {
            return entry.request.keyEnrollment == nil ? "과거 복귀 작업 완료 · 현재 보호·오디오·입력은 별도 확인 필요" : "키 관리 완료 · 인증 복귀는 실행하지 않았습니다."
        }
        switch state.operationState {
        case .authenticating: return "인증 대기 중"
        case .restoring: return "인증 성공 · Mac 복귀 작업 대기 중"
        case .cancelled: return "인증 복귀 취소됨"
        case .expired: return "인증 복귀 만료됨"
        case .rejected, .failed: return "인증 복귀 실패 · 원래 요청 결과 보존"
        default: return "인증 복귀 결과 미확인 · 원래 요청 보존"
        }
    }

    /// 하위 객체의 원문을 잘라 엄격 DTO 파서에 전달한다. 다른 catalog 소비자의 실패로 전파하지 않는다.
    static func capabilityBytes(_ raw: Data) -> Data? {
        guard (try? JSONSerialization.jsonObject(with: raw)) != nil else { return nil }
        let bytes = Array(raw); var index = 0; var found: Data?; var names = Set<String>()
        func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func stringEnd() -> Int? {
            guard index < bytes.count, bytes[index] == 34 else { return nil }
            index += 1
            while index < bytes.count {
                let b = bytes[index]; index += 1
                if b == 34 { return index }
                if b == 92 { index += 1 }
            }
            return nil
        }
        space(); guard index < bytes.count, bytes[index] == 123 else { return nil }; index += 1
        while index < bytes.count {
            space(); if bytes[index] == 125 { return found }
            let nameStart = index
            guard let end = stringEnd(), let name = try? JSONDecoder().decode(String.self, from: Data(bytes[nameStart..<end])), names.insert(name).inserted else { return nil }
            space(); guard index < bytes.count, bytes[index] == 58 else { return nil }; index += 1; space()
            let start = index; var depth = 0
            while index < bytes.count {
                let b = bytes[index]
                if b == 34 { guard stringEnd() != nil else { return nil }; continue }
                if b == 123 || b == 91 { depth += 1 }
                if b == 125 || b == 93 { if depth == 0 { break }; depth -= 1 }
                if b == 44 && depth == 0 { break }
                index += 1
            }
            if name == "sentryReturn" { found = Data(bytes[start..<index]) }
            if index < bytes.count, bytes[index] == 44 { index += 1 }
        }
        return nil
    }
}

final class IPadSentryReturnAdmission {
    struct Ticket {
        fileprivate let gate: IPadSentryReturnAdmission
        fileprivate let generation: UUID
        func permits() -> Bool { gate.lock.lock(); defer { gate.lock.unlock() }; return gate.generation == generation }
    }
    fileprivate let lock = NSLock()
    private var generation = UUID()
    func invalidate() { lock.lock(); generation = UUID(); lock.unlock() }
    func ticket() -> Ticket { lock.lock(); defer { lock.unlock() }; return .init(gate: self, generation: generation) }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
