import Foundation
import CryptoKit
import Security
import LocalAuthentication
import StreamProtocol

final class IPadSentryReturnKeys {
    typealias Binding = IPadSentryReturn.Binding
    typealias Owner = IPadSentryReturn.Owner
    enum Failure: Error { case unsupported, storage, conflict, cancelled, unapproved, invalidKey }
    enum Phase: String, Codable { case preparing, candidate, approved, retired, revoked }
    struct Record: Codable {
        let keyID: String
        let binding: Binding
        var phase: Phase
        var opaqueKey: Data?
        var publicKey: Data?
        var owner: Owner?
        var approvedReference: SentryReturnReference?
    }
    struct Material { let opaqueKey: Data; let publicKey: Data }
    final class Operation {
        private let lock = NSLock()
        private var cancelled = false
        private var cancelAuthentication: (() -> Void)?
        func cancel() {
            lock.lock(); cancelled = true; let cancel = cancelAuthentication; lock.unlock(); cancel?()
        }
        func check() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw Failure.cancelled }
        }
        func installCancellation(_ cancel: @escaping () -> Void) throws {
            lock.lock()
            if cancelled { lock.unlock(); cancel(); throw Failure.cancelled }
            cancelAuthentication = cancel; lock.unlock()
        }
    }
    struct Adapter {
        let create: (Operation) throws -> Material
        let sign: (Data, Data, Operation) throws -> Data
        static let secureEnclave = Self(create: { operation in
            try operation.check()
            #if targetEnvironment(simulator)
            throw Failure.unsupported
            #else
            guard SecureEnclave.isAvailable else { throw Failure.unsupported }
            var error: Unmanaged<CFError>?
            guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                [.privateKeyUsage, .userPresence], &error) else { throw Failure.unsupported }
            let context = LAContext(); context.localizedReason = "이 iPad의 인증 복귀 전용 키를 등록합니다."
            try operation.installCancellation { context.invalidate() }
            let key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false,
                accessControl: acl, authenticationContext: context)
            try operation.check()
            return Material(opaqueKey: key.dataRepresentation, publicKey: key.publicKey.derRepresentation)
            #endif
        }, sign: { blob, rawBytes, operation in
            try operation.check()
            #if targetEnvironment(simulator)
            throw Failure.unsupported
            #else
            guard SecureEnclave.isAvailable else { throw Failure.unsupported }
            let context = LAContext(); context.localizedReason = "등록된 iPad 인증으로 Mac 복귀 요청에 서명합니다."
            try operation.installCancellation { context.invalidate() }
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            let signature = try key.signature(for: rawBytes).derRepresentation
            try operation.check()
            return signature
            #endif
        })
    }

    private let lock = NSLock()
    private let store: IPadSentryReturn.Store
    private let adapter: Adapter
    private var bytes: Data?
    private var records: [Record] = []
    private var failed = false
    private var revision = UUID()
    init(store: IPadSentryReturn.Store, adapter: Adapter) {
        self.store = store; self.adapter = adapter
        do {
            bytes = try store.load()
            if let bytes {
                records = try JSONDecoder().decode([Record].self, from: bytes)
                guard records.count <= 64, Set(records.map(\.keyID)).count == records.count else { throw Failure.storage }
                for record in records {
                    guard UUID(uuidString: record.keyID)?.uuidString.lowercased() == record.keyID,
                          record.binding.hostPin.count == 32, record.binding.deviceFingerprint.count == 32 else { throw Failure.storage }
                    if record.phase != .preparing {
                        guard let der = record.publicKey, der.count == 91, let blob = record.opaqueKey, !blob.isEmpty,
                              (try? P256.Signing.PublicKey(derRepresentation: der).derRepresentation) == der else { throw Failure.storage }
                    }
                    if record.phase == .approved {
                        guard record.owner?.binding == record.binding, record.approvedReference != nil else { throw Failure.storage }
                    }
                }
            }
        } catch { failed = true }
    }
    func invalidateSignatures() { lock.lock(); revision = UUID(); lock.unlock() }
    func approved(binding: Binding) -> Record? {
        lock.lock(); defer { lock.unlock() }
        guard !failed, (try? store.load()) == bytes else { return nil }
        return records.first { $0.binding == binding && $0.phase == .approved }
    }
    func candidate(binding: Binding) -> Record? {
        lock.lock(); defer { lock.unlock() }
        guard !failed, (try? store.load()) == bytes else { return nil }
        return records.first { $0.binding == binding && $0.phase == .candidate }
    }

    /// 준비 의도를 먼저 저장한다. 중단되면 preparing을 남겨 새 키 자동 생성과 덮어쓰기를 막는다.
    func prepare(binding: Binding, rotating: Bool, operation: Operation,
                 keyID: String = UUID().uuidString.lowercased()) throws -> Record {
        try operation.check()
        lock.lock()
        do {
            guard !failed, UUID(uuidString: keyID)?.uuidString.lowercased() == keyID, records.count < 64,
                  !records.contains(where: { $0.keyID == keyID || ($0.binding == binding && [.preparing, .candidate].contains($0.phase)) }),
                  records.contains(where: { $0.binding == binding && $0.phase == .approved }) == rotating else { throw Failure.conflict }
            revision = UUID()
            var next = records; next.append(.init(keyID: keyID, binding: binding, phase: .preparing))
            try persist(next); lock.unlock()
        } catch { lock.unlock(); throw error }
        let material = try adapter.create(operation)
        try operation.check()
        guard material.publicKey.count == 91, !material.opaqueKey.isEmpty,
              (try? P256.Signing.PublicKey(derRepresentation: material.publicKey).derRepresentation) == material.publicKey else { throw Failure.invalidKey }
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.keyID == keyID && $0.phase == .preparing }) else { throw Failure.conflict }
        var next = records; next[index].phase = .candidate
        next[index].opaqueKey = material.opaqueKey; next[index].publicKey = material.publicKey
        try persist(next)
        return next[index]
    }

    func acceptEnrollment(_ entry: IPadSentryReturn.Entry) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed, !entry.locallyCancelled, let enrollment = entry.request.keyEnrollment,
              let raw = entry.rawChallengeState, let challenge = try SentryReturnState.decodePayload(raw).challenge,
              let state = entry.state, state.operationState == .completed, state.authStatus == .succeeded,
              state.reference == entry.request.reference,
              challenge.reference == entry.request.reference, challenge.lease == entry.request.lease,
              challenge.authMode == .macLocal, challenge.authGeneration == state.authGeneration,
              let owner = try? Owner(binding: entry.binding, challenge: challenge) else { throw Failure.unapproved }
        let expected: SentryReturnState.Code = enrollment.action == .enroll ? .keyEnrolled : enrollment.action == .rotate ? .keyRotated : .keyRevoked
        guard state.code == expected else { throw Failure.unapproved }
        if records.contains(where: { $0.approvedReference == state.reference }) { return }
        var next = records
        if enrollment.action == .revoke {
            guard let index = next.firstIndex(where: { $0.keyID == enrollment.keyID && $0.owner == owner && $0.phase == .approved }) else { throw Failure.conflict }
            next[index].phase = .revoked; next[index].approvedReference = state.reference
        } else {
            guard let index = next.firstIndex(where: { $0.keyID == enrollment.keyID && $0.binding == owner.binding && $0.phase == .candidate }),
                  next[index].publicKey?.base64EncodedString() == enrollment.publicKey else { throw Failure.conflict }
            let prior = next.firstIndex(where: { $0.binding == owner.binding && $0.phase == .approved })
            if enrollment.action == .rotate {
                guard let prior, next[prior].keyID == enrollment.previousKeyID, next[prior].owner == owner else { throw Failure.conflict }
                next[prior].phase = .retired
            } else { guard prior == nil else { throw Failure.conflict } }
            next[index].phase = .approved; next[index].owner = owner; next[index].approvedReference = state.reference
        }
        revision = UUID(); try persist(next)
    }
    func sign(_ proof: IPadSentryReturn.Proof, operation: Operation) throws -> (Data, Data) {
        try operation.check()
        lock.lock()
        guard !failed, proof.admission.permits(), let record = records.first(where: {
            $0.phase == .approved && $0.owner == proof.owner && $0.keyID == proof.challenge.keyID
        }), let blob = record.opaqueKey, let der = record.publicKey, (try? store.load()) == bytes else {
            lock.unlock(); throw Failure.unapproved
        }
        let stamp = revision; lock.unlock()
        let signature = try adapter.sign(blob, proof.bytes, operation)
        try operation.check()
        lock.lock(); defer { lock.unlock() }
        guard stamp == revision, proof.admission.permits(), (try? store.load()) == bytes,
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature), parsed.derRepresentation == signature,
              let publicKey = try? P256.Signing.PublicKey(derRepresentation: der), publicKey.isValidSignature(parsed, for: proof.bytes) else { throw Failure.cancelled }
        return (signature, der)
    }
    private func persist(_ next: [Record]) throws {
        do {
            let data = try JSONEncoder().encode(next)
            try store.compareAndSwap(bytes, data)
            guard try store.load() == data else { throw Failure.storage }
            bytes = data; records = next
        } catch { failed = true; revision = UUID(); throw error }
    }

    static func keychainStore() -> IPadSentryReturn.Store {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ambrion.sill.sentry-return.keys.v1",
            kSecAttrAccount as String: SentryReturnChallenge.purpose, kSecAttrSynchronizable as String: false]
        func load() throws -> Data? {
            var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext(); context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
            var value: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = value as? Data else { throw Failure.storage }
            return data
        }
        return .init(load: {
            keychainLock.lock(); defer { keychainLock.unlock() }; return try load()
        }, compareAndSwap: { old, new in
            keychainLock.lock(); defer { keychainLock.unlock() }
            guard try load() == old else { throw Failure.conflict }
            let status: OSStatus
            if old == nil {
                var q = query; q[kSecValueData as String] = new
                q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
                status = SecItemAdd(q as CFDictionary, nil)
            } else {
                status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: new] as CFDictionary)
            }
            guard status == errSecSuccess, try load() == new else { throw Failure.storage }
        })
    }
    private static let keychainLock = NSLock()
}
