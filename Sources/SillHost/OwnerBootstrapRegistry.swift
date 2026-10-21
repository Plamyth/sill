import Foundation
import CryptoKit
import Security
import StreamProtocol

struct OwnerBootstrapRegistry: Codable, Equatable {
    struct Binding: Codable, Equatable {
        let principal: String
        let fingerprint: String
        var revoked = false
    }

    private struct Record: Codable {
        let payload: Data
        let signature: Data
    }

    let schema: Int
    let macID: String
    var bindings: [Binding]

    init(macID: String) {
        schema = 1
        self.macID = macID
        bindings = []
    }

    static func principal(user: UInt64, node: String) -> String {
        let input = Data("sill-owner-tailnet-v1\n\(user)\n\(node)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    static func load(store: IdentityStore, identity: HostIdentity) throws -> Self {
        guard let data = try store.loadOwnerRegistry() else {
            guard try store.loadPaired().allSatisfy({ $0.ownerPrincipal == nil }) else {
                throw IdentityStoreError("자동 등록 철회 기록이 없습니다.")
            }
            return Self(macID: identity.macID)
        }
        guard data.count <= 1024 * 1024,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              identity.verifyRecord(message(record.payload), signature: record.signature),
              let registry = try? JSONDecoder().decode(Self.self, from: record.payload),
              registry.schema == 1, registry.macID == identity.macID,
              Set(registry.bindings.map(\.principal)).count == registry.bindings.count,
              Set(registry.bindings.map(\.fingerprint)).count == registry.bindings.count,
              registry.bindings.allSatisfy({ validPrincipal($0.principal) && validFingerprint($0.fingerprint) }) else {
            throw IdentityStoreError("자동 등록 철회 기록을 검증하지 못했습니다.")
        }
        return registry
    }

    func save(store: IdentityStore, identity: HostIdentity) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(self)
        guard let signature = identity.signRecord(Self.message(payload)) else {
            throw IdentityStoreError("자동 등록 철회 기록에 서명하지 못했습니다.")
        }
        let record = try encoder.encode(Record(payload: payload, signature: signature))
        guard record.count <= 1024 * 1024 else { throw IdentityStoreError("자동 등록 기록의 크기 한도를 초과했습니다.") }
        try store.saveOwnerRegistry(record)
        guard try Self.load(store: store, identity: identity) == self else {
            throw IdentityStoreError("자동 등록 철회 기록의 저장을 확인하지 못했습니다.")
        }
    }

    func permits(principal: String, fingerprint: String, paired: [PairedDevice]) -> Bool {
        if let binding = bindings.first(where: { $0.principal == principal || $0.fingerprint == fingerprint }) {
            return binding.principal == principal && binding.fingerprint == fingerprint && !binding.revoked
                && paired.contains { $0.ownerPrincipal == principal && $0.fingerprint == fingerprint }
        }
        return !paired.contains { $0.ownerPrincipal == principal || $0.fingerprint == fingerprint }
    }

    func trusts(_ device: PairedDevice) -> Bool {
        guard let principal = device.ownerPrincipal else { return true }
        return bindings.contains { $0.principal == principal && $0.fingerprint == device.fingerprint && !$0.revoked }
    }

    private static func message(_ payload: Data) -> Data { Data("sill-owner-registry-v1\n".utf8) + payload }
    private static func validPrincipal(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validFingerprint(_ value: String) -> Bool {
        guard let data = Base64URL.decode(value), data.count == 32 else { return false }
        return Base64URL.encode(data) == value
    }
}

enum SignedHostExecutable {
    static func validate(path: String, identifier: String, team: String) throws {
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == path else { throw TailnetDeviceAccess.Failure.sensorFailure }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw TailnetDeviceAccess.Failure.sensorFailure
        }
    }
}
