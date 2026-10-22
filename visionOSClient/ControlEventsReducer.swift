import Foundation

struct ControlEventsReducer {
    enum Transport: Equatable { case stopped, connecting, open, failed }
    enum Recovery: Equatable { case initial, reconnect, gap, generation }
    enum Outcome: Equatable { case applied, heartbeat, ignored, resyncRequired, invalid }
    private(set) var subscription: UUID?
    private(set) var transport = Transport.stopped
    private(set) var transportOpenedAt: Date?
    private(set) var recovery: Recovery? = .initial
    private(set) var version: ControlEventsVersion?
    private(set) var document: ControlEventsDocument?
    var isCurrent: Bool { transport == .open && recovery == nil && document != nil }

    mutating func begin(_ id: UUID) {
        subscription = id
        transport = .connecting
        transportOpenedAt = nil
        recovery = version == nil ? .initial : .reconnect
    }

    mutating func opened(_ id: UUID, at date: Date) {
        guard subscription == id else { return }
        transport = .open
        transportOpenedAt = date
    }

    mutating func stop(_ id: UUID, failed: Bool = false) {
        guard subscription == id else { return }
        subscription = nil
        transport = failed ? .failed : .stopped
        transportOpenedAt = nil
        recovery = version == nil ? .initial : .reconnect
    }

    mutating func consume(_ envelope: ControlEventsEnvelope, subscription id: UUID) -> Outcome {
        guard subscription == id, transport == .open else { return .ignored }
        switch envelope {
        case .heartbeat(let incoming):
            guard Self.valid(incoming) else { return .invalid }
            guard let version, version.generation == incoming.generation, version.revision == incoming.revision else {
                recovery = version?.generation == incoming.generation ? .gap : .generation
                return .resyncRequired
            }
            return .heartbeat
        case .snapshot(let incoming, let next):
            guard Self.valid(incoming), Self.valid(next) else { return .invalid }
            if let version, incoming.generation == version.generation, incoming.revision < version.revision { return .ignored }
            document = next
            version = incoming
            recovery = nil
            return .applied
        case .patch(let incoming, let base, let patch):
            guard Self.valid(incoming), (0...Self.maximumRevision).contains(base), Self.valid(patch) else { return .invalid }
            guard let version, var next = document else {
                recovery = .initial
                return .resyncRequired
            }
            guard incoming.generation == version.generation else {
                recovery = .generation
                return .resyncRequired
            }
            guard incoming.revision > version.revision else { return .ignored }
            guard recovery == nil, base == version.revision, incoming.revision == base + 1 else {
                recovery = .gap
                return .resyncRequired
            }
            next.root.merge(patch.set) { _, new in new }
            for key in patch.unset { next.root.removeValue(forKey: key) }
            guard let threads = Self.applyRows(next.root["threads"], patch.upsertThreads, patch.removeThreads),
                  let catalog = Self.applyRows(next.root["catalog"], patch.upsertCatalog, patch.removeCatalog) else { return .invalid }
            next.root["threads"] = .array(threads)
            next.root["catalog"] = .array(catalog)
            guard Self.valid(next) else { return .invalid }
            document = next
            self.version = incoming
            return .applied
        }
    }

    static let maximumRevision: Int64 = 9_007_199_254_740_991
    static let maximumRecords = 10_000
    static let maximumDocumentBytes = 33_554_432

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.trimmingCharacters(in: .whitespacesAndNewlines) == value &&
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) &&
            !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
    }

    static func valid(_ version: ControlEventsVersion) -> Bool {
        (0...maximumRevision).contains(version.revision) && date(version.emittedAt) != nil
    }

    static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func valid(_ document: ControlEventsDocument) -> Bool {
        guard document.root["schemaVersion"] == .number(1), document.root.count <= 256 else { return false }
        for name in ["threads", "catalog"] {
            if let rows = document.root[name] {
                guard let records = records(rows), records.count <= maximumRecords else { return false }
                let ids = records.map(\.id)
                guard Set(ids).count == ids.count else { return false }
            }
        }
        var budget = maximumDocumentBytes
        var nodes = 1_000_000
        return valid(.object(document.root), depth: 0, bytes: &budget, nodes: &nodes)
    }

    static func records(_ value: ControlEventsValue) -> [ControlEventsRecord]? {
        guard case .array(let values) = value, values.count <= maximumRecords else { return nil }
        var result = [ControlEventsRecord]()
        for value in values {
            guard case .object(let fields) = value, case .string(let id) = fields["id"], validID(id) else { return nil }
            result.append(ControlEventsRecord(id: id, value: value))
        }
        return result
    }

    private static func applyRows(_ previous: ControlEventsValue?, _ upserts: [ControlEventsRecord], _ removals: [String]) -> [ControlEventsValue]? {
        guard previous == nil || records(previous!) != nil else { return nil }
        var rows = records(previous ?? .array([])) ?? []
        let removed = Set(removals)
        rows.removeAll { removed.contains($0.id) }
        for record in upserts {
            if let index = rows.firstIndex(where: { $0.id == record.id }) { rows[index] = record }
            else { rows.append(record) }
        }
        return rows.map(\.value)
    }

    static func valid(_ patch: ControlEventsPatch) -> Bool {
        func validChanges(_ upserts: [ControlEventsRecord], _ removals: [String]) -> Bool {
            upserts.count <= maximumRecords && removals.count <= maximumRecords &&
                upserts.allSatisfy { record in
                    guard validID(record.id), case .object(let fields) = record.value else { return false }
                    return fields["id"] == .string(record.id)
                } && removals.allSatisfy(validID)
        }
        guard validChanges(patch.upsertThreads, patch.removeThreads), validChanges(patch.upsertCatalog, patch.removeCatalog),
              patch.unset.count <= 256, patch.unset.allSatisfy(validID), patch.set.count <= 256 else { return false }
        var budget = maximumDocumentBytes
        var nodes = 1_000_000
        return valid(.object(patch.set), depth: 0, bytes: &budget, nodes: &nodes) &&
            (patch.upsertThreads + patch.upsertCatalog).allSatisfy { valid($0.value, depth: 0, bytes: &budget, nodes: &nodes) } &&
            patch.unset.allSatisfy { !["__proto__", "prototype", "constructor"].contains($0) }
    }

    private static func valid(_ value: ControlEventsValue, depth: Int, bytes: inout Int, nodes: inout Int) -> Bool {
        nodes -= 1
        guard depth <= 32, nodes >= 0, bytes >= 0 else { return false }
        switch value {
        case .string(let text): bytes -= text.utf8.count; return bytes >= 0
        case .number(let number): bytes -= 8; return number.isFinite && bytes >= 0
        case .null, .bool: bytes -= 1; return bytes >= 0
        case .array(let items):
            return items.allSatisfy { valid($0, depth: depth + 1, bytes: &bytes, nodes: &nodes) }
        case .object(let fields):
            return fields.allSatisfy { key, item in
                bytes -= key.utf8.count
                return key.utf8.count <= 512 && !["__proto__", "prototype", "constructor"].contains(key) && valid(item, depth: depth + 1, bytes: &bytes, nodes: &nodes)
            }
        }
    }
}
