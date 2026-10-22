import Foundation

/// 설치 앱의 서명된 리소스로 공급하는 공개 신뢰 기준이다. 접속 기기의 권한을 부여하지 않는다.
public struct OwnerMacBootstrap: Codable, Equatable, Sendable {
    public static let schemaName = "ccr.owner-mac-bootstrap/v1"
    public static let resourceName = "CCR-OwnerMacBootstrap"
    public static let alpn = "sill-owner/1"
    public static let method = "owner-tailnet-v1"
    public static let requestVersion = 2
    public static let maximumBytes = 4096

    public let schema: String
    public let macID: String
    public let fingerprint: String
    public let addresses: [String]
    public let remotePort: Int

    public var fingerprintData: Data { Base64URL.decode(fingerprint)! }

    public init?(macID: String, fingerprint: String, addresses: [String], remotePort: Int) {
        guard let key = Base64URL.decode(fingerprint), key.count == 32,
              Base64URL.encode(key) == fingerprint, MacID.make(fingerprint: key) == macID,
              (1...65535).contains(remotePort), (1...8).contains(addresses.count),
              Set(addresses).count == addresses.count, addresses.allSatisfy(Self.isTailnetAddress) else { return nil }
        self.schema = Self.schemaName
        self.macID = macID
        self.fingerprint = fingerprint
        self.addresses = addresses
        self.remotePort = remotePort
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, macID, fingerprint, addresses, remotePort
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(String.self, forKey: .schema)
        let macID = try values.decode(String.self, forKey: .macID)
        let fingerprint = try values.decode(String.self, forKey: .fingerprint)
        let addresses = try values.decode([String].self, forKey: .addresses)
        let remotePort = try values.decode(Int.self, forKey: .remotePort)
        guard schema == Self.schemaName,
              let value = Self(macID: macID, fingerprint: fingerprint, addresses: addresses, remotePort: remotePort) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "소유 Mac 연결 설정이 유효하지 않습니다."))
        }
        self = value
    }

    public static func decodeResource(_ data: Data) -> Self? {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public static func isTailnetAddress(_ address: String) -> Bool {
        guard case .success(let parsed) = AddressParser.parse(address),
              parsed.port == nil, parsed.host == address else { return false }
        switch parsed.kind {
        case .ipv4:
            let parts = address.split(separator: ".").compactMap { Int($0) }
            return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
        case .ipv6:
            return address.hasPrefix("fd7a:115c:a1e0:")
        case .name:
            return false
        }
    }
}
