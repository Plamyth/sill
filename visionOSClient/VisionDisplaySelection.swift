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
        let automaticRevision: String?

        init(requestID: UUID, displayID: UInt32, token: Token, automaticRevision: String? = nil) {
            self.requestID = requestID; self.displayID = displayID; self.token = token
            self.automaticRevision = automaticRevision
        }
    }
    struct Remembered: Codable, Equatable {
        let macID: String
        let launchID: String
        let inventoryID: UUID
        let displayID: UInt32
    }
    private struct AutomaticOpportunity {
        let peer: UUID
        let macID: String
        let launchID: String
        let revision: String
        let window: UUID
    }
    private struct AutomaticInventory {
        let displayID: UInt32
        let displays: [DisplayInfo]
        let admissionGeneration: UInt64
    }
    private enum AutomaticPhase { case open, hostOwned, closed }
    enum Code: String, Codable {
        case ready, releasing, queued, observing, observed, unchanged
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
        let automaticCapability: Int?
        let selectionRevision: String?
        let launchID: String?
        let inventory: UUID?
        let displays: [DisplayInfo]?
        let activeDisplay: UInt32?
        let required: Bool
        let source: StreamSource
        let generation: String?
        let epoch: VideoEpoch?
        let selectionAdmission: SourceSelectionAdmission?

        init(_ list: WindowList) {
            capability = list.displaySelection; inventory = list.displayInventoryID
            automaticCapability = list.automaticDisplaySelection
            selectionRevision = list.selectionRevision; launchID = list.launchID
            displays = list.displays; activeDisplay = list.activeDisplayID
            required = list.desktopSelectionRequired == true; source = list.active
            generation = list.inputGeneration; epoch = list.videoEpoch
            selectionAdmission = list.sourceSelectionAdmission
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
    private var automaticOpportunity: AutomaticOpportunity?
    private var automaticInventories: [UUID: AutomaticInventory] = [:]
    private var automaticPhase = AutomaticPhase.open
    private var newestSelectionAdmission: SourceSelectionAdmission?
    private var selectionAdmissionConflicted = false

    private var selectionAdmissionIsCurrent: Bool {
        guard let admission = catalog?.selectionAdmission, admission.ready,
              !selectionAdmissionConflicted else { return false }
        return admission == newestSelectionAdmission
    }

    var hasAutomaticOpportunity: Bool { automaticOpportunity != nil }

    mutating func stopAutomatic() {
        automaticPhase = .closed
        if pending?.command.automaticRevision != nil { cancel(.cancelled) }
    }

    mutating func prepareManualSource() {
        let wasAutomatic = pending?.command.automaticRevision != nil ||
            (pending == nil && automaticOpportunity != nil && automaticPhase != .closed)
        stopAutomatic()
        if wasAutomatic { unresolved = false }
    }

    mutating func automaticCommand(macID: String, remembered: Remembered?) -> Command? {
        guard automaticPhase == .open, let peerEpoch, let lease, let catalog else { return nil }
        guard catalog.automaticCapability == 1, let host = catalog.launchID,
              !host.isEmpty, host.utf8.count <= 128, let revision = catalog.selectionRevision,
              !revision.isEmpty, revision.utf8.count <= 128 else {
            if automaticOpportunity != nil { stopAutomatic() }
            return nil
        }
        if let opportunity = automaticOpportunity {
            guard opportunity.peer == peerEpoch, opportunity.macID == macID,
                  opportunity.launchID == host, opportunity.window == lease.window else {
                stopAutomatic(); return nil
            }
            guard opportunity.revision == revision else {
                automaticPhase = .hostOwned
                if pending?.code != .observing, pending?.command.automaticRevision != nil { cancel(.sourceChanged) }
                return nil
            }
        } else {
            automaticOpportunity = AutomaticOpportunity(peer: peerEpoch, macID: macID, launchID: host, revision: revision, window: lease.window)
        }
        guard foreground, lease != nil, !modal, pending == nil, catalog.source == .none,
              selectionAdmissionIsCurrent, let admission = catalog.selectionAdmission,
              catalog.capability == 1, catalog.validInventory, let inventory = catalog.inventory,
              let token else { return nil }
        let target: DisplayInfo?
        if let previous = automaticInventories[inventory] {
            guard admission.generation > previous.admissionGeneration, catalog.displays == previous.displays else { return nil }
            target = choices.first { $0.id == previous.displayID }
        } else if automaticInventories.count >= 64 { return nil }
        else if let remembered, remembered.macID == macID, remembered.launchID == host,
           remembered.inventoryID == inventory, choices.filter({ $0.id == remembered.displayID }).count == 1 {
            target = choices.first { $0.id == remembered.displayID }
        } else {
            let main = choices.filter(\.isMain)
            target = main.count == 1 ? main.first : nil
        }
        guard let target else { return nil }
        let command = Command(requestID: UUID(), displayID: target.id, token: token, automaticRevision: revision)
        guard preview(command).code == .ready else { return nil }
        automaticInventories[inventory] = AutomaticInventory(displayID: target.id, displays: choices,
                                                              admissionGeneration: admission.generation)
        return command
    }

    func automaticIsCurrent(_ command: Command, macID: String) -> Bool {
        guard let opportunity = automaticOpportunity, automaticPhase == .open, let catalog else { return false }
        return opportunity.macID == macID && opportunity.peer == peerEpoch &&
            opportunity.launchID == catalog.launchID && opportunity.revision == catalog.selectionRevision &&
            command.automaticRevision == opportunity.revision && token == command.token &&
            foreground && lease != nil && !modal && catalog.automaticCapability == 1 && catalog.source == .none &&
            selectionAdmissionIsCurrent
    }

    mutating func recoverAutomaticPresentation(_ epoch: VideoEpoch, macID: String) {
        guard automaticPhase != .closed, unresolved, pending == nil,
              let opportunity = automaticOpportunity, opportunity.peer == peerEpoch,
              opportunity.macID == macID, opportunity.window == lease?.window,
              foreground, let catalog, catalog.launchID == opportunity.launchID,
              catalog.source != .none, catalog.epoch == epoch,
              epoch.matches(source: catalog.source, generation: catalog.generation) else { return }
        if catalog.source == .desktop, catalog.capability != 1 || !catalog.validInventory { return }
        unresolved = false
        automaticPhase = .hostOwned
    }

    func rememberedDisplay(macID: String, epoch: VideoEpoch) -> Remembered? {
        guard foreground, lease != nil, let catalog, catalog.capability == 1, catalog.validInventory,
              catalog.source == .desktop, catalog.epoch == epoch,
              epoch.matches(source: .desktop, generation: catalog.generation),
              let launchID = catalog.launchID, !launchID.isEmpty, let inventoryID = catalog.inventory,
              let displayID = catalog.activeDisplay else { return nil }
        return Remembered(macID: macID, launchID: launchID, inventoryID: inventoryID, displayID: displayID)
    }

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
        automaticOpportunity = nil; automaticInventories = [:]; automaticPhase = .open
        newestSelectionAdmission = nil; selectionAdmissionConflicted = false
    }
    mutating func admit(lease: VisionWindowLease?, foreground: Bool) {
        if self.lease != lease {
            cancel(.admissionChanged); revision &+= 1
            automaticInventories = [:]
            modal = false
        } else if self.foreground && !foreground {
            cancel(.foregroundRequired); revision &+= 1
        }
        if foreground && !self.foreground { automaticInventories = [:] }
        self.lease = lease; self.foreground = foreground
    }
    mutating func setModal(_ shown: Bool) {
        modal = shown
        if shown, pending?.command.automaticRevision != nil {
            cancel(.cancelled); automaticInventories = [:]
        }
    }

    mutating func observe(_ next: Catalog) {
        let old = catalog
        catalog = next
        if let admission = next.selectionAdmission {
            if newestSelectionAdmission == nil || admission.generation > newestSelectionAdmission!.generation {
                newestSelectionAdmission = admission
                selectionAdmissionConflicted = false
            } else if admission.generation == newestSelectionAdmission?.generation && admission != newestSelectionAdmission {
                selectionAdmissionConflicted = true
            }
        }
        if next.capability != nil || next.required { modernSeen = true }
        if old != next { revision &+= 1 }
        guard var waiting = pending else { return }
        if waiting.command.automaticRevision != nil,
           !selectionAdmissionIsCurrent || next.selectionAdmission != waiting.original.selectionAdmission {
            cancel(.admissionChanged)
            return
        }
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
    mutating func invalidateCatalog() {
        cancel(.catalogRequired)
        catalog = nil
        revision &+= 1
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
            if command.automaticRevision != nil &&
                (automaticPhase != .open || automaticOpportunity?.revision != command.automaticRevision ||
                 automaticOpportunity?.peer != peerEpoch || automaticOpportunity?.launchID != catalog.launchID ||
                 automaticOpportunity?.window != lease?.window || catalog.automaticCapability != 1 ||
                 catalog.selectionRevision != command.automaticRevision || catalog.source != .none || modal ||
                 !selectionAdmissionIsCurrent) {
                code = .staleScope
            }
            else if catalog.capability == nil { code = modernSeen ? .unsupportedCapability : .legacyOnly }
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
    mutating func begin(_ command: Command, presented: VideoEpoch? = nil) -> Result {
        if command.automaticRevision == nil { stopAutomatic() }
        let result = preview(command)
        guard !known(command.requestID) else { return result }
        guard result.code == .ready, let catalog else { remember(command, result); return result }
        if let presented, catalog.epoch == presented, catalog.source == .desktop,
           catalog.activeDisplay == command.displayID,
           presented.matches(source: .desktop, generation: catalog.generation) {
            unresolved = false
            let unchanged = Result(requestID: command.requestID, code: .unchanged)
            remember(command, unchanged)
            return unchanged
        }
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
