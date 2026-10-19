import Foundation
import StreamProtocol

struct VisionTestDestinations: Equatable {
    struct PeerBinding: Equatable, Sendable {
        let peerID: String
        let generation: UUID
    }

    enum CatalogStatus: Equatable {
        case disconnected, unavailable, unsupported, invalid, empty, available
    }

    enum PageStatus: Equatable {
        case notOpened, loading, responseReceived(Int), displaying(Int), response(Int)
        case failed, navigationDenied, authenticationDenied
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
        catalog = nil
        catalogStatus = next == nil ? .disconnected : .unavailable
        close()
    }

    @discardableResult
    mutating func observe(_ next: TestDestinationCatalog?, from source: PeerBinding) -> Bool {
        guard binding == source else { return false }
        catalog = next
        if let next {
            if next.schema != TestDestinationCatalog.supportedSchema { catalogStatus = .unsupported }
            else if (try? next.validate()) == nil { catalogStatus = .invalid }
            else { catalogStatus = next.entries.isEmpty ? .empty : .available }
        } else { catalogStatus = .unavailable }
        if let selection, !isCurrent(selection) { close() }
        return true
    }

    func openingURL(for entry: TestDestinationCatalog.Entry, from source: PeerBinding) -> URL? {
        guard binding == source, catalogStatus == .available,
              catalog?.entries.contains(entry) == true, entry.reachability == .reachable else { return nil }
        return try? entry.validatedURL()
    }

    @discardableResult
    mutating func open(_ entry: TestDestinationCatalog.Entry, from source: PeerBinding) -> Bool {
        guard let url = openingURL(for: entry, from: source) else { return false }
        selection = Selection(binding: source, entry: entry, url: url)
        pageStatus = .loading
        return true
    }

    func isCurrent(_ selected: Selection) -> Bool {
        selection == selected && openingURL(for: selected.entry, from: selected.binding) == selected.url
    }

    func allowsNavigation(to url: URL, for selected: Selection) -> Bool {
        guard isCurrent(selected) else { return false }
        var candidate = selected.entry
        candidate.url = url.absoluteString
        guard let safeURL = try? candidate.validatedURL() else { return false }
        return Origin(safeURL) == selected.origin
    }

    mutating func report(_ status: PageStatus, for selected: Selection) {
        guard isCurrent(selected) else { return }
        pageStatus = status
    }

    mutating func close() {
        selection = nil
        pageStatus = .notOpened
    }
}
