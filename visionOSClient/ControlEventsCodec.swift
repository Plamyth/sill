import Foundation

struct ControlEventsCursor: Equatable, Sendable {
    let generation: UUID
    let revision: Int64
    var sseID: String { "\(generation.uuidString.lowercased()):\(revision)" }

    init(generation: UUID, revision: Int64) {
        self.generation = generation
        self.revision = revision
    }

    init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let generation = UUID(uuidString: String(parts[0])),
              !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let revision = Int64(parts[1]), (0...ControlEventsReducer.maximumRevision).contains(revision) else { return nil }
        self.init(generation: generation, revision: revision)
    }
}

enum ControlEventsCodec {
    enum Failure: Error { case invalidEnvelope, invalidCursor, unsupportedSchema, invalidProjection }
    static let schema = "ccr.control-events/v1"

    static func decode(_ frame: ControlEventsSSEFrame) throws -> ControlEventsEnvelope {
        guard frame.data.utf8.count <= ControlEventsReducer.maximumDocumentBytes else { throw Failure.invalidEnvelope }
        let value = try JSONDecoder().decode(ControlEventsValue.self, from: Data(frame.data.utf8))
        guard case .object(let fields) = value, fields["schema"] == .string(schema) else { throw Failure.unsupportedSchema }
        guard let type = fields.text("type"), ["snapshot", "patch", "heartbeat"].contains(type),
              frame.event == type, let generationText = fields.text("generation"),
              let generation = UUID(uuidString: generationText), let revision = fields.revision("revision"),
              let emittedAt = fields.text("emittedAt") else { throw Failure.invalidEnvelope }
        let version = ControlEventsVersion(generation: generation, revision: revision, emittedAt: emittedAt)
        guard ControlEventsReducer.valid(version) else { throw Failure.invalidEnvelope }
        guard let cursor = ControlEventsCursor(frame.id), cursor.generation == generation, cursor.revision == revision else { throw Failure.invalidCursor }
        let baseKeys: Set<String> = ["schema", "type", "generation", "revision", "emittedAt"]
        switch type {
        case "snapshot":
            guard Set(fields.keys).isSubset(of: baseKeys.union(["snapshot"])), case .object(let root) = fields["snapshot"] else { throw Failure.invalidEnvelope }
            let document = ControlEventsDocument(root: root)
            guard ControlEventsReducer.valid(document) else { throw Failure.invalidEnvelope }
            return .snapshot(version, document)
        case "patch":
            guard Set(fields.keys).isSubset(of: baseKeys.union(["baseRevision", "set", "unset", "threads", "catalog"])),
                  let base = fields.revision("baseRevision"), base < ControlEventsReducer.maximumRevision, revision == base + 1,
                  case .object(let set) = fields["set"], let unset = fields.strings("unset"),
                  let threads = changes(fields["threads"]), let catalog = changes(fields["catalog"]) else { throw Failure.invalidEnvelope }
            let patch = ControlEventsPatch(set: set, unset: unset, upsertThreads: threads.0, removeThreads: threads.1,
                                           upsertCatalog: catalog.0, removeCatalog: catalog.1)
            guard ControlEventsReducer.valid(patch) else { throw Failure.invalidEnvelope }
            return .patch(version, baseRevision: base, patch)
        default:
            guard Set(fields.keys) == baseKeys else { throw Failure.invalidEnvelope }
            return .heartbeat(version)
        }
    }

    private static func changes(_ value: ControlEventsValue?) -> ([ControlEventsRecord], [String])? {
        guard case .object(let fields) = value, Set(fields.keys) == ["upsert", "remove"],
              let upsert = fields["upsert"].flatMap(ControlEventsReducer.records), let remove = fields.strings("remove") else { return nil }
        return (upsert, remove)
    }
}

extension Dictionary where Key == String, Value == ControlEventsValue {
    func text(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }
    func flag(_ key: String) -> Bool? {
        guard case .bool(let value) = self[key] else { return nil }
        return value
    }
    func revision(_ key: String) -> Int64? {
        guard case .number(let value) = self[key], value.isFinite, value.rounded() == value,
              value >= 0, value <= Double(ControlEventsReducer.maximumRevision) else { return nil }
        return Int64(value)
    }
    func strings(_ key: String) -> [String]? {
        guard case .array(let values) = self[key] else { return nil }
        var result = [String]()
        for value in values {
            guard case .string(let string) = value else { return nil }
            result.append(string)
        }
        return result
    }
    func rows(_ key: String) -> [[String: ControlEventsValue]]? {
        guard case .array(let values) = self[key] else { return nil }
        var result = [[String: ControlEventsValue]]()
        for value in values {
            guard case .object(let fields) = value else { return nil }
            result.append(fields)
        }
        return result
    }
}
