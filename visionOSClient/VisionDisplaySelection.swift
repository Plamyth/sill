import Foundation
import StreamProtocol

struct VisionDisplaySelection {
    struct Token: Codable, Equatable {
        let peerEpoch: UUID
        let window: UUID
        let admission: UUID
        let inventory: UUID
        let revision: UInt64
    }
    struct Command: Codable, Equatable {
        let requestID: UUID
        let displayID: UInt32
        let token: Token
    }
    enum Code: String, Codable {
        case ready, releasing, queued, observing, observed
        case disconnected, foregroundRequired, windowRequired, catalogRequired
        case legacyOnly, unsupportedCapability, invalidInventory, unknownDisplay
        case staleScope, conflictingID, busy, releaseFailed, cancelled, timedOut
        case peerChanged, admissionChanged, inventoryChanged, sourceChanged, sendCancelled
    }
    struct Result: Codable, Equatable {
        let requestID: UUID
        let code: Code
    }
    struct Catalog: Equatable {
        let capability: Int?
        let inventory: UUID?
        let displays: [DisplayInfo]?
        let activeDisplay: UInt32?
        let required: Bool
        let source: StreamSource
        let generation: String?
        let epoch: VideoEpoch?

        init(_ list: WindowList) {
            capability = list.displaySelection; inventory = list.displayInventoryID
            displays = list.displays; activeDisplay = list.activeDisplayID
            required = list.desktopSelectionRequired == true; source = list.active
            generation = list.inputGeneration; epoch = list.videoEpoch
        }
        var validInventory: Bool {
            guard inventory != nil, let displays, !displays.isEmpty, displays.count <= 64 else { return false }
            if let activeDisplay, !displays.contains(where: { $0.id == activeDisplay }) { return false }
            if source == .desktop && activeDisplay == nil { return false }
            if required && (source == .desktop || activeDisplay != nil) { return false }
            return Set(displays.map(\.id)).count == displays.count && displays.allSatisfy {
                $0.id != 0 && !$0.name.isEmpty && (1...32768).contains($0.width) && (1...32768).contains($0.height)
            }
        }
    }
    struct Pending {
        let command: Command
        let original: Catalog
        var code: Code = .releasing
        var postSendCatalog: Catalog?
    }
    private(set) var peerEpoch: UUID?
    private(set) var lease: VisionWindowLease?
    private(set) var foreground = false
    private(set) var modal = false
    private(set) var catalog: Catalog?
    private(set) var revision: UInt64 = 0
    private(set) var pending: Pending?
    private(set) var lastResult: Result?
    private var unresolved = false
    private var modernSeen = false
    private var history: [(Command, Result)] = []

    var inputBlocked: Bool { modal || unresolved || pending != nil }
    var legacyDesktopAllowed: Bool { !modernSeen && catalog?.capability == nil && catalog?.required == false }
    var blocksDesktopRequest: Bool { !legacyDesktopAllowed || inputBlocked }
    var token: Token? {
        guard let peerEpoch, let lease, let inventory = catalog?.inventory else { return nil }
        return Token(peerEpoch: peerEpoch, window: lease.window, admission: lease.admission,
                     inventory: inventory, revision: revision)
    }
    var choices: [DisplayInfo] { catalog?.capability == 1 && catalog?.validInventory == true ? catalog?.displays ?? [] : [] }
    var observedDisplay: UInt32? { catalog?.source == .desktop ? catalog?.activeDisplay : nil }

    func adjacentCommand(by step: Int, expected: Token) -> Command? {
        guard step == -1 || step == 1, token == expected, !inputBlocked,
              choices.count > 1, let current = observedDisplay,
              let index = choices.firstIndex(where: { $0.id == current }) else { return nil }
        let next = (index + step + choices.count) % choices.count
        let command = Command(requestID: UUID(), displayID: choices[next].id, token: expected)
        return preview(command).code == .ready ? command : nil
    }

    mutating func bind(peerEpoch: UUID?) {
        guard self.peerEpoch != peerEpoch else { return }
        cancel(.peerChanged)
        self.peerEpoch = peerEpoch; catalog = nil; revision &+= 1
        unresolved = false; modernSeen = false
    }
    mutating func admit(lease: VisionWindowLease?, foreground: Bool) {
        if self.lease != lease {
            cancel(.admissionChanged); revision &+= 1
            modal = false
        } else if self.foreground && !foreground {
            cancel(.foregroundRequired); revision &+= 1
        }
        self.lease = lease; self.foreground = foreground
    }
    mutating func setModal(_ shown: Bool) { modal = shown }

    mutating func observe(_ next: Catalog) {
        let old = catalog
        catalog = next
        if next.capability != nil || next.required { modernSeen = true }
        if old != next { revision &+= 1 }
        guard var waiting = pending else { return }
        guard next.capability == 1, next.validInventory,
              next.inventory == waiting.original.inventory,
              next.displays == waiting.original.displays else { cancel(.inventoryChanged); return }
        switch waiting.code {
        case .releasing, .queued:
            if next != waiting.original { cancel(.sourceChanged) }
        case .observing:
            if next.epoch == nil,
               next.source == .none ||
               (next.source == waiting.original.source &&
                (next.source != .desktop || next.activeDisplay == waiting.original.activeDisplay)) ||
               (next.source == .desktop && next.activeDisplay == waiting.command.displayID) {
                waiting.postSendCatalog = nil
                pending = waiting
                return
            }
            if let observed = waiting.postSendCatalog, next != observed { cancel(.sourceChanged); return }
            // A catalog is observed convergence, never a request-correlated host ACK.
            if next.source == .desktop, next.activeDisplay == waiting.command.displayID,
               let epoch = next.epoch, epoch.matches(source: .desktop, generation: next.generation) {
                if waiting.original.source == .desktop, waiting.original.activeDisplay != next.activeDisplay,
                   waiting.original.epoch == epoch { cancel(.sourceChanged); return }
                waiting.postSendCatalog = next
                pending = waiting
            } else if next != waiting.original {
                cancel(.sourceChanged)
            }
        default: break
        }
    }
    mutating func presented(_ epoch: VideoEpoch?) {
        guard let waiting = pending, waiting.code == .observing,
              let next = waiting.postSendCatalog, let epoch, next.epoch == epoch,
              catalog == next else { return }
        finish(.observed)
        unresolved = false
    }
    func preview(_ command: Command) -> Result {
        if let waiting = pending, waiting.command.requestID == command.requestID {
            return Result(requestID: command.requestID, code: waiting.command == command ? waiting.code : .conflictingID)
        }
        if let previous = history.first(where: { $0.0.requestID == command.requestID }) {
            return previous.0 == command ? previous.1 : Result(requestID: command.requestID, code: .conflictingID)
        }
        let code: Code
        if peerEpoch == nil { code = .disconnected }
        else if !foreground { code = .foregroundRequired }
        else if lease == nil { code = .windowRequired }
        else if let catalog {
            if catalog.capability == nil { code = modernSeen ? .unsupportedCapability : .legacyOnly }
            else if catalog.capability != 1 { code = .unsupportedCapability }
            else if !catalog.validInventory { code = .invalidInventory }
            else if token != command.token { code = .staleScope }
            else if !choices.contains(where: { $0.id == command.displayID }) { code = .unknownDisplay }
            else if pending != nil { code = .busy }
            else { code = .ready }
        } else { code = .catalogRequired }
        return Result(requestID: command.requestID, code: code)
    }
    func known(_ id: UUID) -> Bool { pending?.command.requestID == id || history.contains { $0.0.requestID == id } }
    mutating func begin(_ command: Command) -> Result {
        let result = preview(command)
        guard !known(command.requestID) else { return result }
        guard result.code == .ready, let catalog else { remember(command, result); return result }
        unresolved = true
        pending = Pending(command: command, original: catalog)
        let started = Result(requestID: command.requestID, code: .releasing)
        remember(command, started)
        return started
    }
    mutating func released(_ id: UUID, confirmed: Bool) -> Bool {
        guard let waiting = pending, waiting.command.requestID == id, waiting.code == .releasing else { return false }
        guard confirmed else { finish(.releaseFailed); return false }
        guard foreground, lease?.window == waiting.command.token.window,
              lease?.admission == waiting.command.token.admission,
              token == waiting.command.token, catalog == waiting.original else { finish(.staleScope); return false }
        pending?.code = .queued
        update(.queued)
        return true
    }
    mutating func submitted(_ id: UUID) {
        guard pending?.command.requestID == id, pending?.code == .queued else { return }
        pending?.code = .observing
        update(.observing)
    }
    mutating func cancel(_ code: Code = .cancelled) { if pending != nil { finish(code) } }
    mutating func timeout(_ id: UUID) { if pending?.command.requestID == id { finish(.timedOut) } }
    private mutating func update(_ code: Code) {
        guard let command = pending?.command else { return }
        remember(command, Result(requestID: command.requestID, code: code))
    }
    private mutating func finish(_ code: Code) { update(code); pending = nil }
    private mutating func remember(_ command: Command, _ result: Result) {
        history.removeAll { $0.0.requestID == command.requestID }
        history.append((command, result))
        if history.count > 32 { history.removeFirst(history.count - 32) }
        lastResult = result
    }
}
