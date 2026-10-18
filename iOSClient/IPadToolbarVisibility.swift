/// Local presentation only. A touch must finish before the picture's geometry changes.
struct IPadToolbarVisibility {
    enum State: Equatable {
        case shown(since: Double)
        case pinned
        case hidden
        case showAfterTouch
        case hideAfterTouch
    }

    static let idleSeconds: Double = 4
    private(set) var state: State = .shown(since: 0)

    init(now: Double = 0) { state = .shown(since: now) }

    var visible: Bool {
        switch state {
        case .shown, .pinned, .hideAfterTouch: true
        case .hidden, .showAfterTouch: false
        }
    }

    var needsPolling: Bool {
        switch state {
        case .hidden, .pinned: false
        default: true
        }
    }

    mutating func toggle(now: Double, touchesDown: Bool, pinned: Bool) {
        guard !pinned else { return }
        if touchesDown { state = visible ? .hideAfterTouch : .showAfterTouch }
        else { state = visible ? .hidden : .shown(since: now) }
    }

    mutating func update(now: Double, lastActivity: Double?, touchesDown: Bool,
                         enabled: Bool, foreground: Bool, pinned: Bool) {
        guard foreground else { return }
        if !enabled || pinned {
            state = touchesDown && !visible ? .showAfterTouch : .pinned
            return
        }
        switch state {
        case .hidden: break
        case .pinned: state = .shown(since: now)
        case .showAfterTouch:
            if !touchesDown { state = .shown(since: now) }
        case .hideAfterTouch:
            if !touchesDown { state = .hidden }
        case .shown(let since):
            let idleStart = max(since, lastActivity ?? since)
            if !touchesDown && now - idleStart >= Self.idleSeconds { state = .hidden }
        }
    }
}
