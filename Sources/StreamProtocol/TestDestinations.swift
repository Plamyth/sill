import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct TestDestinationCatalog: Codable, Equatable, Sendable {
    public static let supportedSchema = "ccr-test-destinations/v1"
    public static let maximumEntries = 256

    public enum Reachability: String, Codable, Sendable {
        case reachable, unreachable, unknown
    }

    public enum Embed: String, Codable, Sendable {
        case allowed, blocked, unknown
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedSchema, tooManyEntries, duplicateID, emptyField, invalidTimestamp, unsafeURL
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

        public init(id: String, projectId: String, projectLabel: String, label: String,
                    url: String, owner: String, reachability: Reachability, embed: Embed,
                    checkedAt: String? = nil, reason: String? = nil) {
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
                    ((zeroPrefix || mappedPrefix) && (bytes[12] == 127 || bytes[12] == 0)) ||
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
                    guard labels.count == 4, inet_pton(AF_INET, name, &address) == 1,
                          labels[0] != "127", labels[0] != "0",
                          !(labels[0] == "169" && labels[1] == "254") else { throw ValidationError.unsafeURL }
                }
            }
            return result
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

        public init(_ catalog: TestDestinationCatalog?) {
            self.catalog = catalog.flatMap { (try? $0.validate()) != nil ? $0 : nil }
        }

        public init(from decoder: Decoder) throws {
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
