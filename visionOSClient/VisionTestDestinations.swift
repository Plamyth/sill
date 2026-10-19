import Foundation
import StreamProtocol

struct VisionTestDestinations {
    static let maximumObservationAge: TimeInterval = 45
    private let clock: () -> Date
    private(set) var storageEpoch = UUID()

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }
    struct PeerBinding: Equatable, Sendable {
        let peerID: String
        let generation: UUID
    }

    enum CatalogStatus: Equatable {
        case disconnected, unavailable, unsupported, invalid, empty, available
    }

    enum PageStatus: Equatable {
        case notOpened, loading, responseReceived(Int), displaying(Int), response(Int)
        case failed, navigationDenied, authenticationDenied, resourceFilterFailed
    }

    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        fileprivate init(_ url: URL) {
            scheme = url.scheme?.lowercased() ?? ""
            host = url.host?.lowercased() ?? ""
            port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    struct Selection: Equatable, Identifiable {
        let id: UUID
        let binding: PeerBinding
        let entry: TestDestinationCatalog.Entry
        let url: URL
        let origin: Origin

        fileprivate init(binding: PeerBinding, entry: TestDestinationCatalog.Entry, url: URL) {
            id = UUID()
            self.binding = binding
            self.entry = entry
            self.url = url
            origin = Origin(url)
        }
    }

    private(set) var binding: PeerBinding?
    private(set) var catalog: TestDestinationCatalog?
    private(set) var selection: Selection?
    private(set) var pageStatus: PageStatus = .notOpened
    private(set) var catalogStatus: CatalogStatus = .disconnected

    var entries: [TestDestinationCatalog.Entry] {
        Array((catalog?.entries ?? []).prefix(TestDestinationCatalog.maximumEntries))
    }

    mutating func bind(_ next: PeerBinding?) {
        let next = next.flatMap { $0.peerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard binding != next else { return }
        binding = next
        invalidate()
        catalogStatus = next == nil ? .disconnected : .unavailable
        close()
    }

    @discardableResult
    mutating func observe(_ next: TestDestinationCatalog?, from source: PeerBinding) -> Bool {
        guard binding == source else { return false }
        guard let next else {
            invalidate()
            catalogStatus = .unavailable
            return true
        }
        guard next.schema == TestDestinationCatalog.supportedSchema else {
            invalidate()
            catalogStatus = .unsupported
            return true
        }
        guard (try? next.validate()) != nil else {
            invalidate()
            catalogStatus = .invalid
            return true
        }
        catalog = next
        catalogStatus = next.entries.isEmpty ? .empty : .available
        if next.entries.isEmpty { invalidate(status: .empty); catalog = next }
        if let selection, !isCurrent(selection) { close() }
        return true
    }

    func openingURL(for entry: TestDestinationCatalog.Entry, from source: PeerBinding) -> URL? {
        guard binding == source, catalogStatus == .available,
              catalog?.entries.contains(entry) == true, entry.reachability == .reachable,
              !entry.projectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.projectLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let checkedAt = entry.checkedAt, let checked = Self.timestamp(checkedAt),
              (0...Self.maximumObservationAge).contains(clock().timeIntervalSince(checked)),
              let url = try? entry.validatedURL(), url.scheme?.lowercased() == "https",
              (try? entry.validatedRedirectOrigins()) != nil else { return nil }
        return url
    }

    @discardableResult
    mutating func open(_ entry: TestDestinationCatalog.Entry, from source: PeerBinding) -> Bool {
        guard let url = openingURL(for: entry, from: source) else { return false }
        selection = Selection(binding: source, entry: entry, url: url)
        pageStatus = .loading
        return true
    }

    func isCurrent(_ selected: Selection) -> Bool {
        guard selection == selected, binding == selected.binding,
              let current = catalog?.entries.first(where: { $0.id == selected.entry.id }),
              current.projectId == selected.entry.projectId,
              current.projectLabel == selected.entry.projectLabel,
              current.url == selected.entry.url, current.owner == selected.entry.owner,
              current.redirectOrigins == selected.entry.redirectOrigins else { return false }
        return openingURL(for: current, from: selected.binding) == selected.url
    }

    func resourceRuleListJSON(for selected: Selection) -> String? {
        guard isCurrent(selected), let redirects = try? selected.entry.validatedRedirectOrigins() else { return nil }
        var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        for url in [selected.url] + redirects {
            let origin = Origin(url)
            let host = NSRegularExpression.escapedPattern(for: origin.host)
            let port = origin.port == 443 ? "(:443)?" : ":\(origin.port)"
            rules.append(["trigger": ["url-filter": "^https://\(host)\(port)([/?#].*)?$",
                                       "url-filter-is-case-sensitive": false],
                          "action": ["type": "ignore-previous-rules"]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func allowsNavigation(to url: URL, for selected: Selection) -> Bool {
        guard isCurrent(selected) else { return false }
        var candidate = selected.entry
        candidate.url = url.absoluteString
        guard let safeURL = try? candidate.validatedURL() else { return false }
        guard safeURL.scheme?.lowercased() == "https" else { return false }
        let origins = (try? selected.entry.validatedRedirectOrigins()) ?? []
        return Origin(safeURL) == selected.origin || origins.contains { Origin($0) == Origin(safeURL) }
    }

    @discardableResult
    mutating func revalidate(_ selected: Selection) -> Bool {
        guard selection == selected else { return false }
        guard isCurrent(selected) else { close(); return false }
        return true
    }

    mutating func report(_ status: PageStatus, for selected: Selection) {
        guard revalidate(selected) else { return }
        pageStatus = status
    }

    mutating func invalidate(status: CatalogStatus = .invalid) {
        catalogStatus = status
        catalog = nil
        storageEpoch = UUID()
        close()
    }

    private static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    mutating func close() {
        selection = nil
        pageStatus = .notOpened
    }
}
