import StreamProtocol

/// Legacy input cannot identify its source. Keep that source fixed until every remaining
/// connection can echo a generation; stopping a stream never releases a legacy connection's pin.
struct SourceInputFence<Peer: Hashable> {
    private var scoped: [Peer: Bool] = [:]
    private struct Target: Equatable {
        let source: StreamSource
        let desktopScope: String?
        init(_ source: StreamSource, _ desktopScope: String?) {
            self.source = source
            self.desktopScope = source == .desktop ? desktopScope : nil
        }
    }
    private var pinnedSource: Target?

    mutating func join(_ peer: Peer, source: StreamSource, switching: Bool, desktopScope: String? = nil) -> Bool {
        // A joining legacy client must not see the old catalog halfway through a source switch.
        guard !switching, scoped[peer] == nil else { return false }
        scoped[peer] = false
        sourceChanged(to: source, desktopScope: desktopScope)
        return true
    }

    func contains(_ peer: Peer) -> Bool { scoped[peer] != nil }

    mutating func leave(_ peer: Peer) {
        scoped[peer] = nil
        releasePinIfScoped()
    }

    mutating func negotiate(_ peer: Peer, supportsScoped: Bool) {
        guard supportsScoped, scoped[peer] != nil else { return }
        scoped[peer] = true
        releasePinIfScoped()
    }

    mutating func sourceChanged(to source: StreamSource, desktopScope: String? = nil) {
        if scoped.values.contains(false), pinnedSource == nil, source != .none { pinnedSource = Target(source, desktopScope) }
    }

    func allowsSelection(_ source: StreamSource, desktopScope: String? = nil) -> Bool {
        guard let pinnedSource else { return true }
        return source == .none || Target(source, desktopScope) == pinnedSource
    }

    mutating func accepts(_ peer: Peer, generation: String?, current: String, source: StreamSource, desktopScope: String? = nil) -> Bool {
        guard let supportsScoped = scoped[peer] else { return false }
        if let generation {
            guard generation == current else { return false }
            // Also recognizes the first scoped client candidate, whose hello had no capability.
            negotiate(peer, supportsScoped: true)
            return true
        }
        return !supportsScoped && source != .none && Target(source, desktopScope) == pinnedSource
    }

    private mutating func releasePinIfScoped() {
        if !scoped.values.contains(false) { pinnedSource = nil }
    }
}
