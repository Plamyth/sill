import Foundation
import StreamProtocol

struct IPadDesiredAudio {
    enum Direction: String, Codable, CaseIterable, Hashable { case microphone, playback }

    struct Identity: Codable, Hashable {
        let macID: String
        let pin: Data

        init?(macID: String, pin: Data) {
            guard !macID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  macID.utf8.count <= 256, pin.count == 32 else { return nil }
            self.macID = macID
            self.pin = pin
        }
    }

    struct Selection: Codable, Equatable {
        var microphone = false
        var playback = false

        subscript(_ direction: Direction) -> Bool {
            get { direction == .microphone ? microphone : playback }
            set {
                if direction == .microphone { microphone = newValue }
                else { playback = newValue }
            }
        }
    }

    struct Scope: Hashable {
        let source: StreamSource
        let generation: UUID
        let videoEpoch: UUID
        let microphone: MicrophoneScope?
    }

    enum Privacy: Equatable { case legacy, protected, blocked }

    private struct Attempt: Hashable {
        let identity: Identity
        let scope: Scope
        let direction: Direction
    }

    private(set) var peer: ObjectIdentifier?
    private(set) var identity: Identity?
    private(set) var selection = Selection()
    private(set) var scope: Scope?
    private(set) var privacy = Privacy.legacy
    private var revisions: [Direction: UUID] = [.microphone: UUID(), .playback: UUID()]
    private var sawPrivacy = false
    private var retiredScope: Scope?
    private var attempts: Set<Attempt> = []

    mutating func bind(_ peer: ObjectIdentifier?) {
        guard self.peer != peer else { return }
        self.peer = peer
        identity = nil
        selection = Selection()
        scope = nil
        privacy = .legacy
        sawPrivacy = false
        retiredScope = nil
        attempts.removeAll()
        invalidate()
    }

    mutating func authenticate(_ identity: Identity?, saved: Selection) {
        guard self.identity != identity else { return }
        self.identity = identity
        selection = identity == nil ? Selection() : saved
        invalidate()
    }

    mutating func observe(_ list: WindowList, microphone: MicrophoneScope?, from peer: ObjectIdentifier) {
        guard self.peer == peer else { return }
        let previousPrivacy = privacy
        if let state = list.audioPrivacy {
            sawPrivacy = true
            privacy = state.version == 1 && state.protected ? .protected : .blocked
        } else { privacy = sawPrivacy ? .blocked : .legacy }
        let next: Scope?
        if let epoch = list.videoEpoch,
           epoch.matches(source: list.active, generation: list.inputGeneration),
           let generation = UUID(uuidString: epoch.generation) {
            next = Scope(source: list.active, generation: generation, videoEpoch: epoch.id, microphone: microphone)
        } else { next = nil }
        let admitted = next == retiredScope ? nil : next
        if admitted != nil { retiredScope = nil }
        if scope != admitted || previousPrivacy != privacy { invalidate() }
        scope = admitted
    }

    mutating func sourceWillChange() {
        if let scope { retiredScope = scope }
        scope = nil
        invalidate()
    }

    mutating func set(_ direction: Direction, desired: Bool) {
        if desired && selection[direction] { return }
        selection[direction] = desired
        invalidate(direction)
    }

    func revision(for direction: Direction) -> UUID { revisions[direction]! }

    mutating func invalidate(_ direction: Direction? = nil) {
        for item in direction.map({ [$0] }) ?? Direction.allCases { revisions[item] = UUID() }
    }

    func permits(_ direction: Direction, automatic: Bool, foreground: Bool,
                 presented: Bool, fullControl: Bool, microphoneAuthorized: Bool) -> Bool {
        guard peer != nil, selection[direction], foreground, privacy != .blocked else { return false }
        guard automatic else { return true }
        return identity != nil && scope != nil && privacy == .protected && presented && fullControl &&
            (direction != .microphone || (microphoneAuthorized && scope?.microphone != nil))
    }

    mutating func takeAutomaticStarts(foreground: Bool, presented: Bool, fullControl: Bool,
                                      microphoneAuthorized: Bool, microphoneCanStart: Bool,
                                      playbackCanStart: Bool) -> [Direction] {
        guard let identity, let scope else { return [] }
        return Direction.allCases.filter { direction in
            guard direction == .microphone ? microphoneCanStart : playbackCanStart,
                  permits(direction, automatic: true, foreground: foreground, presented: presented,
                          fullControl: fullControl, microphoneAuthorized: microphoneAuthorized) else { return false }
            return attempts.insert(Attempt(identity: identity, scope: scope, direction: direction)).inserted
        }
    }

    mutating func markManualAttempt(_ direction: Direction) {
        guard let identity, let scope else { return }
        attempts.insert(Attempt(identity: identity, scope: scope, direction: direction))
    }
}

struct IPadDesiredAudioStore {
    private struct Record: Codable {
        let identity: IPadDesiredAudio.Identity
        var selection: IPadDesiredAudio.Selection
    }
    private struct Archive: Codable {
        let version: Int
        var records: [Record]
    }
    static let key = "iPadDesiredAudio.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var records: [Record] {
        guard let data = defaults.data(forKey: Self.key),
              let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1,
              archive.records.count <= 128,
              archive.records.allSatisfy({ IPadDesiredAudio.Identity(macID: $0.identity.macID, pin: $0.identity.pin) != nil }) else { return [] }
        return archive.records
    }

    func selection(for identity: IPadDesiredAudio.Identity) -> IPadDesiredAudio.Selection {
        records.first { $0.identity == identity }?.selection ?? .init()
    }

    func save(_ selection: IPadDesiredAudio.Selection, for identity: IPadDesiredAudio.Identity) {
        var next = records.filter { $0.identity.macID != identity.macID }
        next.append(Record(identity: identity, selection: selection))
        if let data = try? JSONEncoder().encode(Archive(version: 1, records: Array(next.suffix(128)))) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// A reused layer's old ready image cannot admit a new source. Wait for its readiness cycle.
struct IPadAudioPresentation {
    private var scope: IPadDesiredAudio.Scope?
    private var sawNotReady = false
    private var sawKeyframe = false

    mutating func reset() {
        scope = nil
        sawNotReady = false
        sawKeyframe = false
    }

    mutating func observe(scope: IPadDesiredAudio.Scope?, ready: Bool, keyframe: Bool = false,
                          healthy: Bool, attached: Bool) -> Bool {
        if self.scope != scope { reset(); self.scope = scope }
        guard scope != nil, healthy else { reset(); return false }
        if !ready { sawNotReady = true }
        if keyframe && attached { sawKeyframe = true }
        return attached && ready && sawNotReady && sawKeyframe
    }
}
