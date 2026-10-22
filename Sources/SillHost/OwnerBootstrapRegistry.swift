import Foundation
import CryptoKit
import Security
import StreamProtocol

struct OwnerBootstrapRegistry: Codable, Equatable {
    struct Binding: Codable, Equatable {
        enum State: String, Codable { case pending, active, revoked }
        let principal: String?
        let fingerprint: String
        var state: State = .pending
    }

    private struct Record: Codable {
        let payload: Data
        let signature: Data
    }

    private struct LegacyBinding: Decodable {
        let principal: String
        let fingerprint: String
        let revoked: Bool
    }

    private enum CodingKeys: String, CodingKey { case schema, macID, bindings }
    let schema: Int
    let macID: String
    var bindings: [Binding]

    init(macID: String) {
        schema = 3
        self.macID = macID
        bindings = []
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schema)
        guard version == 1 || version == 2 || version == 3 else {
            throw IdentityStoreError("지원하지 않는 자동 등록 기록입니다.")
        }
        schema = 3
        macID = try values.decode(String.self, forKey: .macID)
        if version == 1 {
            bindings = try values.decode([LegacyBinding].self, forKey: .bindings).map {
                Binding(principal: $0.principal, fingerprint: $0.fingerprint, state: $0.revoked ? .revoked : .active)
            }
        } else {
            bindings = try values.decode([Binding].self, forKey: .bindings)
        }
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
              registry.macID == identity.macID,
              Set(registry.bindings.compactMap(\.principal)).count == registry.bindings.compactMap(\.principal).count,
              Set(registry.bindings.map(\.fingerprint)).count == registry.bindings.count,
              registry.bindings.allSatisfy({ binding in
                  validFingerprint(binding.fingerprint)
                      && (binding.principal.map(validPrincipal) ?? (binding.state == .revoked))
              }) else {
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
        guard !paired.contains(where: { $0.ownerPrincipal == principal && $0.fingerprint != fingerprint }) else { return false }
        let device = paired.first { $0.fingerprint == fingerprint }
        if let device {
            guard device.ownerPrincipal == principal || Self.isExplicitPairing(device) else { return false }
        }
        if let binding = bindings.first(where: { $0.principal == principal || $0.fingerprint == fingerprint }) {
            guard binding.principal == principal, binding.fingerprint == fingerprint else { return false }
            switch binding.state {
            case .pending: return true
            case .active: return device != nil
            case .revoked: return false
            }
        }
        return device == nil || device.map(Self.isExplicitPairing) == true
    }

    func candidatePrincipal(_ device: PairedDevice) -> String? {
        guard device.method == OwnerMacBootstrap.method, device.ownerActivationPending != true,
              let principal = device.ownerPrincipal,
              bindings.contains(where: { $0.principal == principal && $0.fingerprint == device.fingerprint && $0.state == .active }) else { return nil }
        return principal
    }

    private static func isExplicitPairing(_ device: PairedDevice) -> Bool {
        device.ownerPrincipal == nil && [PairRequest.qr, PairRequest.code, PairResult.cable, "icloud"].contains(device.method)
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
