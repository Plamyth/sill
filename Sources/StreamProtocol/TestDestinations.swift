import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct TestDestinationCatalog: Codable, Equatable, Sendable {
    public static let supportedSchema = "ccr-test-destinations/v1"
    public static let maximumEntries = 256
    public static let maximumRedirectOrigins = 8

    public enum Reachability: String, Codable, Sendable {
        case reachable, unreachable, unknown
    }

    public enum Embed: String, Codable, Sendable {
        case allowed, blocked, unknown
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedSchema, tooManyEntries, duplicateID, emptyField, invalidTimestamp, unsafeURL, tooManyRedirectOrigins
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var projectId: String
        public var projectLabel: String
        public var label: String
        public var url: String
        public var owner: String
        public var reachability: Reachability
        public var embed: Embed
        public var checkedAt: String?
        public var reason: String?
        public var redirectOrigins: [String]

        public init(id: String, projectId: String, projectLabel: String, label: String,
                    url: String, owner: String, reachability: Reachability, embed: Embed,
                    checkedAt: String? = nil, reason: String? = nil, redirectOrigins: [String] = []) {
            self.id = id
            self.projectId = projectId
            self.projectLabel = projectLabel
            self.label = label
            self.url = url
            self.owner = owner
            self.reachability = reachability
            self.embed = embed
            self.checkedAt = checkedAt
            self.reason = reason
            self.redirectOrigins = redirectOrigins
        }

        private enum CodingKeys: String, CodingKey {
            case id, projectId, projectLabel, label, url, owner, reachability, embed, checkedAt, reason, redirectOrigins
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try values.decode(String.self, forKey: .id),
                      projectId: try values.decode(String.self, forKey: .projectId),
                      projectLabel: try values.decode(String.self, forKey: .projectLabel),
                      label: try values.decode(String.self, forKey: .label),
                      url: try values.decode(String.self, forKey: .url),
                      owner: try values.decode(String.self, forKey: .owner),
                      reachability: try values.decode(Reachability.self, forKey: .reachability),
                      embed: try values.decode(Embed.self, forKey: .embed),
                      checkedAt: try values.decodeIfPresent(String.self, forKey: .checkedAt),
                      reason: try values.decodeIfPresent(String.self, forKey: .reason),
                      redirectOrigins: try values.decodeIfPresent([String].self, forKey: .redirectOrigins) ?? [])
        }

        public func validatedRedirectOrigins() throws -> [URL] {
            guard redirectOrigins.count <= TestDestinationCatalog.maximumRedirectOrigins else {
                throw ValidationError.tooManyRedirectOrigins
            }
            return try redirectOrigins.map { origin in
                var candidate = self
                candidate.url = origin
                let result = try candidate.validatedURL()
                guard let components = URLComponents(string: origin),
                      components.scheme?.lowercased() == "https", components.path.isEmpty,
                      components.query == nil, components.fragment == nil else { throw ValidationError.unsafeURL }
                return result
            }
        }

        public func validatedURL() throws -> URL {
            guard url == url.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
                  !url.contains("\\"),
                  URL(string: url, encodingInvalidCharacters: false) != nil,
                  let components = URLComponents(string: url),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  components.user == nil, components.password == nil,
                  let rawHost = components.host, !rawHost.isEmpty, !rawHost.contains("%"),
                  components.port.map({ (1...65535).contains($0) }) != false,
                  let result = components.url else { throw ValidationError.unsafeURL }
            let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let name = host.hasSuffix(".") ? String(host.dropLast()) : host
            guard !["localhost", "local", "localhost.localdomain"].contains(name),
                  !name.hasSuffix(".localhost") else { throw ValidationError.unsafeURL }
            if host.contains(":") {
                var address = in6_addr()
                guard inet_pton(AF_INET6, host, &address) == 1 else { throw ValidationError.unsafeURL }
                let bytes = withUnsafeBytes(of: &address) { Array($0) }
                let zeroPrefix = bytes.prefix(12).allSatisfy { $0 == 0 }
                let mappedPrefix = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
                if bytes.allSatisfy({ $0 == 0 }) ||
                    (bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1) ||
                    ((zeroPrefix || mappedPrefix) && !Self.allowsIPv4(first: bytes[12], second: bytes[13])) ||
                    (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) {
                    throw ValidationError.unsafeURL
                }
            } else {
                let labels = name.split(separator: ".", omittingEmptySubsequences: false)
                guard labels.allSatisfy({ label in
                    !label.isEmpty && label.first != "-" && label.last != "-" &&
                    label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                }) else { throw ValidationError.unsafeURL }
                let numeric = labels.allSatisfy { $0.allSatisfy(\.isNumber) || $0.hasPrefix("0x") }
                if numeric {
                    var address = in_addr()
                    guard labels.count == 4,
                          labels.allSatisfy({ UInt8($0).map(String.init) == String($0) }),
                          inet_pton(AF_INET, name, &address) == 1 else { throw ValidationError.unsafeURL }
                    let bytes = withUnsafeBytes(of: &address) { Array($0) }
                    guard Self.allowsIPv4(first: bytes[0], second: bytes[1]) else { throw ValidationError.unsafeURL }
                }
            }
            return result
        }

        private static func allowsIPv4(first: UInt8, second: UInt8) -> Bool {
            first != 127 && first != 0 && !(first == 169 && second == 254)
        }
    }

    public var schema: String
    public var observedAt: String
    public var entries: [Entry]

    public init(schema: String = Self.supportedSchema, observedAt: String, entries: [Entry]) {
        self.schema = schema
        self.observedAt = observedAt
        self.entries = entries
    }

    public func validate() throws {
        guard schema == Self.supportedSchema else { throw ValidationError.unsupportedSchema }
        guard entries.count <= Self.maximumEntries else { throw ValidationError.tooManyEntries }
        guard Self.validTimestamp(observedAt) else { throw ValidationError.invalidTimestamp }
        guard Set(entries.map(\.id)).count == entries.count else { throw ValidationError.duplicateID }
        for entry in entries {
            guard [entry.id, entry.projectId, entry.projectLabel, entry.label, entry.owner].allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            }) else { throw ValidationError.emptyField }
            if let checkedAt = entry.checkedAt, !Self.validTimestamp(checkedAt) {
                throw ValidationError.invalidTimestamp
            }
            _ = try entry.validatedURL()
            _ = try entry.validatedRedirectOrigins()
        }
    }

    private static func validTimestamp(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#,
                          options: .regularExpression) != nil else { return false }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if format.date(from: value) != nil { return true }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: value) != nil
    }

    public struct Projection: Codable, Equatable, Sendable {
        public var catalog: TestDestinationCatalog?

        private enum StateKey: String, CodingKey { case state }

        public init(_ catalog: TestDestinationCatalog?) {
            self.catalog = catalog.flatMap { (try? $0.validate()) != nil ? $0 : nil }
        }

        public init(from decoder: Decoder) throws {
            guard let values = try? decoder.container(keyedBy: StateKey.self) else {
                self.init(nil)
                return
            }
            if values.contains(.state), (try? values.decode(String.self, forKey: .state)) != "ready" {
                self.init(nil)
                return
            }
            self.init(try? TestDestinationCatalog(from: decoder))
        }

        public func encode(to encoder: Encoder) throws {
            if let catalog, (try? catalog.validate()) != nil {
                try catalog.encode(to: encoder)
            } else {
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }
    }
}
