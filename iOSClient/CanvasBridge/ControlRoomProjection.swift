import Foundation

struct ControlRoomProjection: Decodable {
    let schemaVersion: Int
    let generatedAt: String
    let workspace: String?
    let activeVoiceId: String?
    let activeVoiceSession: VoiceSession?
    let voiceCard: ControlRoomCard?
    let currentGrid: [ControlRoomSlot]
    let workspaces: [ControlRoomLayout]
    let projects: [ControlRoomProject]?
    let chatgptProjects: [ControlRoomProject]?
    let chatgptProjectState: String?
    let sections: [ControlRoomSection]?
    let brainTrinity: BrainTrinityFeed?
    let unifiedControl: ControlRoomUnifiedControl?
    let sourceConnections: [ControlRoomSourceConnection]?

    struct Connection: Decodable {
        enum State: String, Decodable { case connected, stale, unavailable }
        let connected: Bool
        let state: State
    }
    let sourceObservedAt: String?
    let connection: Connection?
    var transportConnected: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, workspace, activeVoiceId, activeVoiceSession, voiceCard
        case currentGrid, workspaces, projects, chatgptProjects, chatgptProjectState, sections, brainTrinity
        case sourceObservedAt, connection, unifiedControl, sourceConnections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion = try c.decode(Int.self,forKey:.schemaVersion)
        generatedAt = try c.decodeIfPresent(String.self,forKey:.generatedAt) ?? ""
        workspace = try c.decodeIfPresent(String.self,forKey:.workspace)
        activeVoiceId = try c.decodeIfPresent(String.self,forKey:.activeVoiceId)
        activeVoiceSession = try c.decodeIfPresent(VoiceSession.self,forKey:.activeVoiceSession)
        voiceCard = try c.decodeIfPresent(ControlRoomCard.self,forKey:.voiceCard)
        currentGrid = try c.decodeIfPresent([ControlRoomSlot].self,forKey:.currentGrid) ?? []
        workspaces = try c.decodeIfPresent([ControlRoomLayout].self,forKey:.workspaces) ?? []
        projects = try c.decodeIfPresent([ControlRoomProject].self,forKey:.projects)
        chatgptProjects = try c.decodeIfPresent([ControlRoomProject].self,forKey:.chatgptProjects)
        chatgptProjectState = try c.decodeIfPresent(String.self,forKey:.chatgptProjectState)
        sections = try c.decodeIfPresent([ControlRoomSection].self,forKey:.sections)
        brainTrinity = try c.decodeIfPresent(BrainTrinityFeed.self,forKey:.brainTrinity)
        sourceObservedAt = try c.decodeIfPresent(String.self,forKey:.sourceObservedAt)
        connection = try c.decodeIfPresent(Connection.self,forKey:.connection)
        unifiedControl = try c.decodeIfPresent(ControlRoomUnifiedControl.self,forKey:.unifiedControl)
        sourceConnections = try c.decodeIfPresent([ControlRoomSourceConnection].self,forKey:.sourceConnections)
    }

    var hasDisplayContent: Bool { !generatedAt.isEmpty && connection?.state != .unavailable }

    func isFresh(now: Date = Date()) -> Bool {
        guard schemaVersion == 1, transportConnected != false, Self.recent(generatedAt,now:now) else { return false }
        guard let connection else { return transportConnected != true }
        return connection.connected && connection.state == .connected &&
            sourceObservedAt.map { Self.recent($0,now:now) } == true
    }

    func disconnected() -> Self {
        var copy = self
        copy.transportConnected = false
        return copy
    }

    var availableVoiceCard: ControlRoomCard? {
        guard let card = voiceCard, card.id == activeVoiceId, card.isAvailable else { return nil }
        return card
    }

    func observedSession(now: Date = Date()) -> VoiceSession? {
        guard isFresh(now:now), let card = availableVoiceCard,
              let session = activeVoiceSession,
              session.threadId.uuidString.lowercased() == card.id.lowercased(),
              !session.sessionId.isEmpty, Self.recent(session.observedAt,now:now) else { return nil }
        return session
    }

    func slots(layoutID: String?) -> [ControlRoomSlot] {
        guard let layoutID else { return currentGrid }
        return workspaces.first(where: { $0.id == layoutID })?.slots ?? []
    }

    func projectLabel(for slot: ControlRoomSlot) -> String? {
        guard let id = slot.chatgptProjectId ?? slot.carouselProjectId ?? slot.projectId else { return nil }
        let project = project(for:slot)
        return project?.displayLabel ?? project?.label ?? id
    }

    func project(for slot: ControlRoomSlot) -> ControlRoomProject? {
        if let id = slot.chatgptProjectId {
            guard chatgptProjectState == "cached" else { return nil }
            return chatgptProjects?.first(where: { $0.id == id })
        }
        guard let id = slot.carouselProjectId ?? slot.projectId else { return nil }
        return projects?.first(where: { $0.id == id })
    }

    func freshBrainTrinity(now: Date = Date()) -> BrainTrinityFeed? {
        guard isFresh(now:now), let feed = brainTrinity, feed.isAvailable(now:now) else { return nil }
        return feed
    }

    func brainTrinityBadges(layoutID: String?, index: Int, now: Date = Date()) -> BrainTrinityBadges {
        guard let feed = freshBrainTrinity(now:now), (0..<9).contains(index),
              let workspaceID = layoutID ?? workspace else { return .empty }
        let layouts = workspaces.filter { $0.id == workspaceID }
        guard layouts.count == 1 else { return .empty }
        let slots = (layoutID == nil ? currentGrid : layouts[0].slots).filter { $0.index == index }
        guard slots.count == 1 else { return .empty }
        let slot = slots[0]
        func linked(_ ref: BrainTrinityRowReference) -> Bool {
            ref.isCurrent(revision:feed.revision,now:now) &&
                ref.cardLinks.contains { $0.workspaceId == workspaceID && $0.slotIndex == index } &&
                slot.matchesBrainTrinityOwner(ref,projects:projects ?? [])
        }
        return BrainTrinityBadges(activities:feed.activities.filter { activity in
            BrainTrinityFeed.validID(activity.key) && linked(activity.reference) &&
                feed.activities.filter { $0.key == activity.key }.count == 1
        }, reviews:feed.reviewRequests.filter { review in
            BrainTrinityFeed.validID(review.id) && review.order >= 0 &&
                review.state == .pending && !review.decisionAllowed && linked(review.reference) &&
                feed.reviewRequests.filter { $0.id == review.id }.count == 1
        })
    }

    private static func recent(_ value: String, now: Date) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let fractional = formatter.date(from:value)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from:value) else { return false }
        return now.timeIntervalSince(date) <= 30 && date.timeIntervalSince(now) <= 5
    }
}

// Only the relay's public projection is decoded; source summaries never grant row permissions.
enum ControlRoomSource: String, CaseIterable, Identifiable {
    case codex, cursorDesktop = "cursor-desktop", cursorCloud = "cursor-cloud"
    var id: Self { self }
    var label: String {
        switch self {
        case .codex: return "Codex"
        case .cursorDesktop: return "Cursor 로컬"
        case .cursorCloud: return "Cursor Cloud"
        }
    }
}

struct ControlRoomSourceConnection: Decodable {
    let provider: String
    let connected: Bool?
    let state: String?
    let connectedAt: String?
    let observedAt: String?
    let owner: String?
    let sessionId: String?
    let runId: String?
    let sourceRevision: ProjectionValue?
    let readOnly: Bool?
    let capabilities: ControlRoomSourceCapabilities?
    let reason: String?

    var label: String {
        switch state {
        case "unsupported": return "미지원"
        case "connected": return connected == true ? "연결됨" : "연결 미확인"
        case "stale": return "오래된 연결 관측"
        case "unavailable": return "연결 정보 없음"
        default: return state ?? "연결 미확인"
        }
    }
}

struct ControlRoomSourceCapabilities: Decodable {
    let read: Bool?
    let send: Bool?
}

struct ControlRoomSessionID: Hashable {
    let source: String
    let key: String
    let externalId: String?
    let sessionId: String?
    let runId: String?
    let hostId: String?
    let instanceId: String?
    let startedAt: String?
    let workspaceIdentity: String?
    let ownerThreadId: String?
}

struct ControlRoomSourceSession: Decodable, Identifiable {
    let source: String
    let provider: String
    let key: String
    let externalId: String?
    let sessionId: String?
    let runId: String?
    let hostId: String?
    let instanceId: String?
    let startedAt: String?
    let workspaceIdentity: String?
    let ownerThreadId: String?
    let ownerVerified: Bool?
    let projectId: String?
    let title: String?
    let status: String?
    let displayStatus: String?
    let executionStatus: String?
    let statusSource: String?
    let agentStatus: String?
    let observedAt: String?
    let connectedAt: String?
    let sourceRevision: ProjectionValue?
    let connectionState: String?
    let fresh: Bool?
    let stale: Bool?
    let readOnly: Bool?
    let capabilities: ControlRoomSourceCapabilities?
    let threadId: String?
    let activeTurnId: String?
    let sourceConnection: ControlRoomSourceConnection?

    var id: ControlRoomSessionID {
        ControlRoomSessionID(source:source,key:key,externalId:externalId,sessionId:sessionId,
            runId:runId,hostId:hostId,instanceId:instanceId,startedAt:startedAt,
            workspaceIdentity:workspaceIdentity,ownerThreadId:ownerThreadId)
    }
    var isSupported: Bool {
        ControlRoomSource(rawValue:source) != nil && provider == source && !key.isEmpty && externalId?.isEmpty == false
    }
    var titleLabel: String { title?.isEmpty == false ? title! : externalId ?? "제목 미제공" }
    var ownerLabel: String { ownerVerified == true ? ownerThreadId ?? "미확인" : "미확인" }

    func isFresh(now: Date) -> Bool {
        fresh == true && stale != true && Self.recent(observedAt,now:now)
    }
    static func recent(_ value: String?, now: Date) -> Bool {
        guard let value, let date = BrainTrinityFeed.date(value) else { return false }
        return now.timeIntervalSince(date) <= 30 && date.timeIntervalSince(now) <= 5
    }

    enum SessionConnection: Equatable {
        case unavailable, mismatched, stale, current
        var label: String {
            switch self {
            case .unavailable: return "개별 연결 미제공"
            case .mismatched: return "개별 연결 식별자 불일치"
            case .stale: return "개별 연결 최신성 미확인"
            case .current: return "개별 원본 연결 확인"
            }
        }
    }
    func sessionConnection(now: Date) -> SessionConnection {
        guard let connection = sourceConnection else { return .unavailable }
        guard connection.provider == source, connection.sessionId?.isEmpty == false,
              connection.sessionId == sessionId, connection.sessionId == externalId,
              connection.runId == runId else { return .mismatched }
        if source == "codex" {
            guard connection.sessionId == threadId, connection.runId == activeTurnId else { return .mismatched }
        }
        guard connection.connected == true, connection.state == "connected",
              connection.owner?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false,
              case .number(let revision) = connection.sourceRevision,
              revision >= 0, revision <= 9_007_199_254_740_991, revision.rounded() == revision,
              isFresh(now:now), Self.recent(connection.observedAt,now:now) else { return .stale }
        return .current
    }

    // Describes the row contract only. This panel never sends commands.
    func reportedSendAllowed(now: Date) -> Bool {
        guard isSupported, ownerVerified == true, ownerThreadId?.isEmpty == false,
              readOnly == false, capabilities?.send == true, isFresh(now:now) else { return false }
        return source != "codex" || sessionConnection(now:now) == .current
    }
}

struct ControlRoomUnifiedControl: Decodable {
    let schema: Int
    let rows: [ControlRoomSourceSession]
    let truncated: Bool
    let error: String?
}

extension ControlRoomProjection {
    var sourceSessions: [ControlRoomSourceSession] {
        guard hasDisplayContent, unifiedControl?.schema == 1 else { return [] }
        return unifiedControl?.rows ?? []
    }
    var sourceSessionIDs: [ControlRoomSessionID] {
        ControlRoomSource.allCases.flatMap { sessions(for:$0).map(\.id) }
    }
    func sessions(for source: ControlRoomSource) -> [ControlRoomSourceSession] {
        let supported = sourceSessions.filter { $0.isSupported && $0.source == source.rawValue }
        let counts = Dictionary(supported.map { ($0.id,1) },uniquingKeysWith:+)
        return supported.filter { counts[$0.id] == 1 }
    }
    func sourceSummary(for source: ControlRoomSource) -> ControlRoomSourceConnection? {
        guard hasDisplayContent else { return nil }
        let matches = sourceConnections?.filter { $0.provider == source.rawValue } ?? []
        return matches.count == 1 ? matches[0] : nil
    }
}

struct ControlRoomSourceSelection {
    private(set) var source: ControlRoomSource = .codex
    private var selected: [ControlRoomSource:ControlRoomSessionID] = [:]
    var sessionID: ControlRoomSessionID? { selected[source] }

    mutating func select(source: ControlRoomSource) { self.source = source }
    mutating func select(session: ControlRoomSourceSession) {
        guard session.isSupported, session.source == source.rawValue else { return }
        selected[source] = session.id
    }
    mutating func clear() { selected[source] = nil }
    mutating func reconcile(_ projection: ControlRoomProjection?) {
        selected = selected.filter { source,id in
            projection?.sessions(for:source).contains(where:{ $0.id == id }) == true
        }
    }
    func session(in projection: ControlRoomProjection) -> ControlRoomSourceSession? {
        projection.sessions(for:source).first { $0.id == sessionID }
    }
}

enum BrainTrinityMode: String, Decodable {
    case stopped, starting, running, stopping, blocked
    var localizedTitle: String {
        switch self {
        case .stopped: return "중지됨"
        case .starting: return "시작 중"
        case .running: return "실행 중"
        case .stopping: return "중지 중"
        case .blocked: return "차단됨"
        }
    }
}

enum BrainTrinityPhase: String, Decodable {
    case queued, observationPending = "observation_pending", resultReview = "result_review", attention, completed
    var localizedTitle: String {
        switch self {
        case .queued: return "대기 중"
        case .observationPending: return "관측 대기"
        case .resultReview: return "결과 검토"
        case .attention: return "확인 필요"
        case .completed: return "완료"
        }
    }
}

enum BrainTrinityReviewState: String, Decodable { case pending }

struct BrainTrinityCardLink: Decodable, Equatable {
    let workspaceId: String
    let slotIndex: Int
}

struct BrainTrinityRowReference: Decodable {
    let projectId: String?
    let threadId: String?
    let summary: String
    let updatedAt: String
    let ledgerRevision: Int
    let cardLinks: [BrainTrinityCardLink]

    func isCurrent(revision: Int?, now: Date) -> Bool {
        guard ledgerRevision == revision, ledgerRevision >= 0, summary.utf16.count <= 2000,
              cardLinks.count <= 256, let updated = BrainTrinityFeed.date(updatedAt),
              updated.timeIntervalSince(now) <= 30 else { return false }
        return [projectId,threadId].compactMap { $0 }.allSatisfy(BrainTrinityFeed.validID)
    }
}

struct BrainTrinityActivity: Decodable, Identifiable {
    let key: String
    let phase: BrainTrinityPhase
    let reference: BrainTrinityRowReference
    var id: String { key }

    private enum CodingKeys: String, CodingKey { case key, phase }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy:CodingKeys.self)
        key = try fields.decode(String.self,forKey:.key)
        phase = try fields.decode(BrainTrinityPhase.self,forKey:.phase)
        reference = try BrainTrinityRowReference(from:decoder)
    }
}

struct BrainTrinityReviewOrigin: Decodable {
    let goalId: String?
    let stepKey: String?
    let taskId: String?
    let dispatchId: String?
    let resultId: String?
    let runId: String?
}

struct BrainTrinityReview: Decodable, Identifiable {
    let id: String
    let state: BrainTrinityReviewState
    let order: Int
    let decisionAllowed: Bool
    let origin: BrainTrinityReviewOrigin
    let reference: BrainTrinityRowReference

    private enum CodingKeys: String, CodingKey { case id, state, order, decisionAllowed }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy:CodingKeys.self)
        id = try fields.decode(String.self,forKey:.id)
        state = try fields.decode(BrainTrinityReviewState.self,forKey:.state)
        order = try fields.decode(Int.self,forKey:.order)
        decisionAllowed = try fields.decode(Bool.self,forKey:.decisionAllowed)
        origin = try BrainTrinityReviewOrigin(from:decoder)
        reference = try BrainTrinityRowReference(from:decoder)
    }
}

struct BrainTrinityFeed: Decodable {
    let schema: String
    let available: Bool
    let writable: Bool
    let source: String?
    let ownerInstanceId: String?
    let revision: Int?
    let epoch: Int?
    let observedAt: String?
    let mode: BrainTrinityMode?
    let reason: String?
    let activities: [BrainTrinityActivity]
    let reviewRequests: [BrainTrinityReview]

    func isAvailable(now: Date) -> Bool {
        let ownerPrefix = "bt-ledger:goal_becdf9909850486b:"
        guard schema == "control-room-bt-mobile-feed/v1", available, !writable, source == "braintrinity",
              let ownerInstanceId, Self.validID(ownerInstanceId), ownerInstanceId.hasPrefix(ownerPrefix),
              ownerInstanceId.count > ownerPrefix.count,
              let revision, (0...9_007_199_254_740_991).contains(revision),
              let epoch, (0...9_007_199_254_740_991).contains(epoch),
              mode != nil, let observedAt, let observed = Self.date(observedAt),
              abs(now.timeIntervalSince(observed)) <= 30,
              activities.count <= 50, reviewRequests.count <= 50 else { return false }
        return true
    }

    static func date(_ value: String) -> Date? {
        guard value.utf16.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let fractional = formatter.date(from:value)
        formatter.formatOptions = [.withInternetDateTime]
        return fractional ?? formatter.date(from:value)
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count < 200 &&
            value.trimmingCharacters(in:.whitespacesAndNewlines) == value &&
            value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) &&
                !(0x202a...0x202e).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
    }
}

struct BrainTrinityBadges {
    let activities: [BrainTrinityActivity]
    let reviews: [BrainTrinityReview]
    static let empty = BrainTrinityBadges(activities:[],reviews:[])
}

struct ControlRoomProject: Decodable, Identifiable {
    let id: String
    let label: String
    let displayLabel: String?
    let projectKind: String?
}

struct ControlRoomSection: Decodable, Identifiable {
    let id: String
    let kind: String?
    let label: String
    let prefix: String?
    let absorbedPrefixSectionId: String?
    let projectIds: [String]?
    let chatgptProjectIds: [String]?
}

enum ControlRoomSectionID: Hashable {
    case pcCurrent
    case workspace(String)
}

enum ControlRoomProjectID: Hashable {
    case codex(String)
    case chatgpt(String)
}

struct ControlRoomNavigationSelection: Equatable {
    var sectionID: ControlRoomSectionID = .pcCurrent
    var projectID: ControlRoomProjectID?
    var filter: ControlRoomStatusFilter = .all
}

struct ControlRoomProjectOption: Identifiable {
    let id: ControlRoomProjectID
    let label: String
    let workspaceID: String?
}

struct ControlRoomSectionOption: Identifiable {
    let id: ControlRoomSectionID
    let label: String
    let projects: [ControlRoomProjectOption]
}

enum ControlRoomGridTarget: Equatable {
    case pcCurrent
    case workspace(String)
    case unavailable

    var layoutID: String? {
        if case .workspace(let id) = self { return id }
        return nil
    }
}

struct ControlRoomNavigation {
    let sections: [ControlRoomSectionOption]
    private let workspaceAliases: [String:String]

    init(projection: ControlRoomProjection) {
        let local = projection.projects ?? []
        let remote = projection.chatgptProjectState == "cached" ? projection.chatgptProjects ?? [] : []
        let layouts = projection.workspaces
        let projectLayouts = Set(local.map { "project:\($0.id)" })
        let sourceSections = projection.sections ?? []
        var aliases = [String:String]()
        for section in sourceSections {
            guard let alias = section.absorbedPrefixSectionId,
                  let native = layouts.first(where: { $0.nativeSectionId == section.id || $0.id == "section:\(section.id)" })
            else { continue }
            aliases[alias] = native.id
            aliases["section:\(alias)"] = native.id
        }
        workspaceAliases = aliases

        func projects(localIDs: [String], remoteIDs: [String]) -> [ControlRoomProjectOption] {
            localIDs.compactMap { id in
                guard let project = local.first(where: { $0.id == id }) else { return nil }
                return ControlRoomProjectOption(id:.codex(id),
                    label:"\(project.displayLabel ?? project.label) · Codex",
                    workspaceID:layouts.first(where: { $0.id == "project:\(id)" })?.id)
            } + remoteIDs.compactMap { id in
                guard let project = remote.first(where: { $0.id == id }) else { return nil }
                return ControlRoomProjectOption(id:.chatgpt(id),
                    label:"\(project.displayLabel ?? project.label) · ChatGPT",workspaceID:nil)
            }
        }

        var options = [ControlRoomSectionOption(id:.pcCurrent,label:"PC 현재 3×3",
            projects:projects(localIDs:local.map(\.id),remoteIDs:remote.map(\.id)))]
        for layout in layouts where !projectLayouts.contains(layout.id) && aliases[layout.id] == nil {
            let section = sourceSections.first {
                layout.nativeSectionId == $0.id || layout.id == "section:\($0.id)" || layout.id == $0.id
            }
            let localIDs = section?.projectIds ?? layout.projectIds ??
                (layout.id == "all" ? local.map(\.id) : [])
            let remoteIDs = section?.chatgptProjectIds ?? layout.chatgptProjectIds ?? []
            let slotLocalIDs = layout.slots.filter { $0.chatgptProjectId == nil }
                .compactMap { $0.carouselProjectId ?? $0.projectId }
            let slotRemoteIDs = layout.slots.compactMap(\.chatgptProjectId)
            func unique(_ ids: [String]) -> [String] {
                var seen = Set<String>()
                return ids.filter { seen.insert($0).inserted }
            }
            options.append(ControlRoomSectionOption(id:.workspace(layout.id),label:layout.label,
                projects:projects(localIDs:unique(localIDs+slotLocalIDs),remoteIDs:unique(remoteIDs+slotRemoteIDs))))
        }
        sections = options
    }

    func target(for selection: ControlRoomNavigationSelection) -> ControlRoomGridTarget {
        guard let section = sections.first(where: { $0.id == selection.sectionID }) else { return .unavailable }
        if let id = selection.projectID {
            guard let workspace = section.projects.first(where: { $0.id == id })?.workspaceID else { return .unavailable }
            return .workspace(workspace)
        }
        switch section.id {
        case .pcCurrent: return .pcCurrent
        case .workspace(let id): return .workspace(id)
        }
    }

    func selection(layoutID: String?) -> ControlRoomNavigationSelection {
        guard let layoutID else { return ControlRoomNavigationSelection() }
        let canonicalID = workspaceAliases[layoutID] ?? layoutID
        if let section = sections.first(where: { $0.id == .workspace(canonicalID) }) {
            return ControlRoomNavigationSelection(sectionID:section.id)
        }
        for section in sections {
            if let project = section.projects.first(where: { $0.workspaceID == canonicalID }) {
                return ControlRoomNavigationSelection(sectionID:section.id,projectID:project.id)
            }
        }
        return ControlRoomNavigationSelection(sectionID:.workspace(layoutID))
    }
}

enum ControlRoomStatusFilter: String, CaseIterable, Identifiable {
    case all = "All", running = "Running", needsInput = "Needs input", unavailable = "Unavailable"
    var id: Self { self }
    var localizedTitle: String {
        switch self {
        case .all: return "전체"
        case .running: return "진행 중"
        case .needsInput: return "입력 필요"
        case .unavailable: return "사용할 수 없음"
        }
    }

    func matches(_ slot: ControlRoomSlot) -> Bool {
        switch self {
        case .all: return true
        case .unavailable: return slot.availableCard == nil
        case .needsInput: return slot.availableCard?.needsInput == true
        case .running: return slot.availableCard?.isRunning == true
        }
    }
}

struct ControlRoomGridGeometry {
    static let columns = 3
    static let aspectRatio: CGFloat = 16 / 9
    static let spacing: CGFloat = 8

    static func width(available: CGFloat) -> CGFloat {
        max(available, 3 * 320 + 2 * spacing)
    }
}

enum ControlRoomCardReference: Identifiable {
    case voice(threadId: String)
    case slot(layoutID: String?, index: Int, threadId: String)

    var id: String {
        switch self {
        case .voice(let threadId): return "voice/\(threadId)"
        case .slot(let layoutID, let index, let threadId): return "\(layoutID ?? "pc")/\(index)/\(threadId)"
        }
    }

    func card(in projection: ControlRoomProjection) -> ControlRoomCard? {
        switch self {
        case .voice(let threadId):
            guard projection.availableVoiceCard?.id == threadId else { return nil }
            return projection.availableVoiceCard
        case .slot(let layoutID, let index, let threadId):
            return projection.slots(layoutID:layoutID).first(where: {
                $0.index == index && $0.threadId == threadId
            })?.availableCard
        }
    }
}

struct ControlRoomLayout: Decodable, Identifiable {
    let id: String
    let label: String
    let kind: String?
    let prefix: String?
    let nativeSectionId: String?
    let projectIds: [String]?
    let chatgptProjectIds: [String]?
    let slots: [ControlRoomSlot]
}

struct ControlRoomSlot: Decodable, Identifiable {
    let index: Int
    let kind: String
    let threadId: String?
    let projectId: String?
    let carouselProjectId: String?
    let chatgptProjectId: String?
    let card: ControlRoomCard?
    let unavailableReason: String?
    var id: Int { index }

    var availableCard: ControlRoomCard? {
        guard unavailableReason == nil, let card, card.id == threadId, card.isAvailable else { return nil }
        return card
    }

    func matchesBrainTrinityOwner(_ ref: BrainTrinityRowReference, projects: [ControlRoomProject]) -> Bool {
        guard ["normal","voice","project"].contains(kind), chatgptProjectId == nil,
              unavailableReason == nil || unavailableReason == "empty-slot" else { return false }
        if threadId != nil {
            guard let card = availableCard, card.source == "codex",
                  ref.threadId == nil || ref.threadId == threadId,
                  ref.projectId == nil || card.projectVerified == true && card.projectId == ref.projectId,
                  [projectId,carouselProjectId].compactMap({ $0 }).allSatisfy({ $0 == card.projectId })
            else { return false }
            return ref.threadId != nil || ref.projectId != nil
        }
        guard ref.threadId == nil, let ownerProject = ref.projectId, kind == "project", card == nil else { return false }
        let ids = [projectId,carouselProjectId].compactMap { $0 }
        return !ids.isEmpty && ids.allSatisfy { $0 == ownerProject } &&
            projects.filter { $0.id == ownerProject && $0.projectKind != "chatgpt" }.count == 1
    }

    var sourceKindLabel: String {
        if chatgptProjectId != nil { return "ChatGPT 프로젝트 · 읽기 전용" }
        if let card, card.id == threadId, let source = card.source {
            return source == "codex" ? "Codex 대화" : "대화 출처 · \(source)"
        }
        if threadId == nil, carouselProjectId != nil || projectId != nil { return "Codex 프로젝트 · 읽기 전용" }
        return "출처 미제공"
    }

    var displayTitle: String? {
        guard let threadId else { return nil }
        guard let card, card.id == threadId else { return threadId }
        return card.displayTitle
    }

    var availabilityLabel: String? {
        guard availableCard == nil else { return nil }
        if let reason = unavailableReason, reason != "empty-slot" { return "사용 불가 · \(reason)" }
        if let reason = card?.unavailableReason { return "사용 불가 · \(reason)" }
        if card?.stale == true { return "사용 불가 · stale" }
        if card?.sourceMissing == true { return "사용 불가 · source-missing" }
        if card?.hidden == true { return "사용 불가 · hidden" }
        if card?.archived == true { return "사용 불가 · archived" }
        if threadId != nil { return "대화 사용 가능 상태 미확인" }
        if chatgptProjectId != nil { return "네이티브 대화 연결 대기" }
        return carouselProjectId != nil || projectId != nil ? "선택된 대화 없음" : "빈 슬롯"
    }
}

struct ControlRoomCard: Decodable, Identifiable {
    let id: String
    let title: String?
    let titleVerified: Bool?
    let status: String?
    let turnStatus: String?
    let available: Bool?
    let unavailableReason: String?
    let sourceMissing: Bool?
    let stale: Bool?
    let hidden: Bool?
    let archived: Bool?
    let source: String?
    let provenance: String?
    let observedAt: String?
    let owner: String?
    let project: String?
    let projectId: String?
    let projectVerified: Bool?
    let latestProgress: ControlRoomEvent?
    let latestUser: ControlRoomEvent?
    let activeTools: [String]?
    let pendingTools: Int?
    let permission: String?
    let result: String?
    let voiceState: ProjectionValue?
    let goal: ProjectionValue?
    let inputRequest: ProjectionValue?
    let executions: ProjectionValue?
    let events: [ControlRoomEvent]?

    var isAvailable: Bool {
        available == true && unavailableReason == nil && sourceMissing != true && stale != true &&
            hidden != true && archived != true
    }
    var displayTitle: String { titleVerified == true ? title ?? id : id }
    var needsInput: Bool { inputRequestSummary != nil || status == "사용자 입력 필요" }
    var inputRequestSummary: String? { inputRequest?.requestSummary }
    var isRunning: Bool {
        guard !needsInput else { return false }
        if let turnStatus { return turnStatus == "inProgress" }
        return status == "진행 중" || status == "running"
    }
}

struct ControlRoomEvent: Decodable, Identifiable {
    let id: String
    let ts: String?
    let kind: String?
    let role: String?
    let text: String?
    let source: String?
    let voiceSessionId: String?
}

indirect enum ProjectionValue: Codable {
    case string(String), number(Double), bool(Bool), object([String:ProjectionValue]), array([ProjectionValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let object = try? value.decode([String:ProjectionValue].self) { self = .object(object) }
        else { self = .array(try value.decode([ProjectionValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .null: try value.encodeNil()
        }
    }

    var formatted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding:data,as:UTF8.self)
    }

    var requestSummary: String? {
        switch self {
        case .null, .bool(false): return nil
        case .string(let text): return text.isEmpty ? nil : text
        case .object(let fields):
            guard !fields.isEmpty else { return nil }
            if case .array(let questions) = fields["questions"] {
                let text = questions.compactMap { value -> String? in
                    guard case .object(let question) = value, case .string(let text) = question["question"],
                          !text.isEmpty else { return nil }
                    return text
                }.joined(separator:" · ")
                if !text.isEmpty { return text }
            }
            for key in ["question","message","kind","requestId","callId"] {
                if case .string(let text) = fields[key], !text.isEmpty { return text }
            }
            return "입력 요청 있음 · 세부 내용 미제공"
        case .bool(true): return "입력 요청 있음 · 세부 내용 미제공"
        case .number, .array: return nil
        }
    }
}

struct VoicePIPPlacement {
    var anchor = CGPoint(x:1,y:1)

    static func cardSize(in container: CGSize) -> CGSize {
        CGSize(width:min(310,max(0,container.width-24)),height:min(174,max(0,container.height-24)))
    }

    func origin(in container: CGSize) -> CGPoint {
        let card = Self.cardSize(in:container)
        return CGPoint(x:12+max(0,container.width-card.width-24)*anchor.x,
                       y:12+max(0,container.height-card.height-24)*anchor.y)
    }

    mutating func move(from origin: CGPoint, by translation: CGSize, in container: CGSize) {
        let card = Self.cardSize(in:container)
        let travelX = max(0,container.width-card.width-24)
        let travelY = max(0,container.height-card.height-24)
        anchor = CGPoint(x:travelX > 0 ? min(1,max(0,(origin.x+translation.width-12)/travelX)) : 1,
                         y:travelY > 0 ? min(1,max(0,(origin.y+translation.height-12)/travelY)) : 1)
    }
}

// The relay cursor is independent of the source observation clock.
struct ControlRoomEventsReducer {
    enum Outcome { case applied, ignored, heartbeat, resync }
    enum Contract { case common, relayProjection }
    private(set) var generation: String?
    private(set) var revision: Int?
    private(set) var snapshot: [String:ProjectionValue]?
    private(set) var projection: ControlRoomProjection?
    var cursor: String? {
        guard let generation, let revision else { return nil }
        return "\(generation):\(revision)"
    }

    struct Event: Decodable {
        let schema: String
        let type: String
        let generation: String
        let revision: Int
        let emittedAt: String
        let snapshot: [String:ProjectionValue]?
        let baseRevision: Int?
        let set: [String:ProjectionValue]?
        let unset: [String]?
        let threads: Rows?
        let catalog: Rows?
    }
    struct Rows: Decodable {
        let upsert: [[String:ProjectionValue]]
        let remove: [String]
    }

    mutating func consume(_ frame: ControlRoomSSE.Frame, contract: Contract) throws -> Outcome {
        let event = try JSONDecoder().decode(Event.self,from:frame.data)
        guard event.schema == "ccr.control-events/v1", UUID(uuidString:event.generation) != nil,
              event.generation.utf8.count == 36, (0...9_007_199_254_740_991).contains(event.revision),
              BrainTrinityFeed.date(event.emittedAt) != nil,
              ["snapshot","patch","heartbeat"].contains(event.type), frame.event == event.type,
              frame.id == "\(event.generation):\(event.revision)" else { throw ControlRoomEventsError.invalid }
        let raw = try JSONDecoder().decode(ProjectionValue.self,from:frame.data)
        guard Self.safe(raw) else { throw ControlRoomEventsError.invalid }
        if contract == .relayProjection, case .object(let fields) = raw, fields["changes"] != nil {
            throw ControlRoomEventsError.invalid
        }
        if event.type == "heartbeat" {
            return generation == event.generation && revision == event.revision ? .heartbeat : .resync
        }
        var next: [String:ProjectionValue]
        if event.type == "snapshot" {
            guard let fields = event.snapshot else { throw ControlRoomEventsError.invalid }
            if generation == event.generation, let revision, event.revision < revision { return .ignored }
            next = fields
        } else {
            guard let base = event.baseRevision, (0..<9_007_199_254_740_991).contains(base),
                  event.revision == base + 1, let set = event.set, let unset = event.unset,
                  unset.allSatisfy({ !Self.forbidden.contains($0) }),
                  let threads = event.threads, let catalog = event.catalog,
                  Self.valid(threads), Self.valid(catalog) else { throw ControlRoomEventsError.invalid }
            guard generation == event.generation, let revision, let snapshot else { return .resync }
            if event.revision <= revision { return .ignored }
            guard base == revision else { return .resync }
            next = snapshot.merging(set) { _,new in new }
            for key in unset { next.removeValue(forKey:key) }
            next["threads"] = try Self.apply(next["threads"],rows:threads)
            next["catalog"] = try Self.apply(next["catalog"],rows:catalog)
        }
        guard case .number(1) = next["schemaVersion"] else { throw ControlRoomEventsError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(ProjectionValue.object(next))
        guard data.count <= ControlRoomSSE.maxBodyBytes else { throw ControlRoomEventsError.tooLarge }
        var value = try JSONDecoder().decode(ControlRoomProjection.self,from:data)
        if contract == .relayProjection {
            guard let connection = value.connection, let observed = next["sourceObservedAt"],
                  case .array(let threads) = next["threads"], threads.isEmpty,
                  case .array(let catalog) = next["catalog"], catalog.isEmpty,
                  connection.connected == (connection.state == .connected) else { throw ControlRoomEventsError.invalid }
            switch observed {
            case .null:
                guard connection.state == .unavailable else { throw ControlRoomEventsError.invalid }
            case .string(let date):
                guard BrainTrinityFeed.date(date) != nil else { throw ControlRoomEventsError.invalid }
            default: throw ControlRoomEventsError.invalid
            }
            if connection.state != .unavailable {
                guard BrainTrinityFeed.date(value.generatedAt) != nil,
                      value.sourceObservedAt == value.generatedAt,
                      case .array = next["currentGrid"], case .array = next["workspaces"]
                else { throw ControlRoomEventsError.invalid }
            }
        }
        value.transportConnected = true
        generation = event.generation
        revision = event.revision
        snapshot = next
        projection = value
        return .applied
    }

    private static let forbidden: Set<String> = ["__proto__","prototype","constructor"]
    private static func safe(_ value: ProjectionValue) -> Bool {
        switch value {
        case .object(let fields): return fields.allSatisfy { !forbidden.contains($0.key) && safe($0.value) }
        case .array(let items): return items.allSatisfy(safe)
        default: return true
        }
    }
    private static func id(_ row: [String:ProjectionValue]) -> String? {
        guard case .string(let id) = row["id"], !id.isEmpty else { return nil }
        return id
    }
    private static func valid(_ rows: Rows) -> Bool {
        rows.upsert.allSatisfy { id($0) != nil } && rows.remove.allSatisfy { !$0.isEmpty }
    }
    private static func apply(_ previous: ProjectionValue?, rows: Rows) throws -> ProjectionValue {
        var order = [String]()
        var values = [String:ProjectionValue]()
        if let previous {
            guard case .array(let items) = previous else { throw ControlRoomEventsError.invalid }
            for item in items {
                guard case .object(let row) = item, let key = id(row) else { throw ControlRoomEventsError.invalid }
                if values[key] == nil { order.append(key) }
                values[key] = item
            }
        }
        for key in rows.remove { values.removeValue(forKey:key) }
        order.removeAll { values[$0] == nil }
        for row in rows.upsert {
            let key = id(row)!
            if values[key] == nil { order.append(key) }
            values[key] = .object(row)
        }
        return .array(order.compactMap { values[$0] })
    }
}

enum ControlRoomEventsError: Error, LocalizedError {
    case invalid, tooLarge, resync, unsupported, rejected(Int)
    var errorDescription: String? {
        switch self {
        case .invalid: return "관제 이벤트 형식을 확인할 수 없습니다."
        case .tooLarge: return "관제 이벤트가 8 MiB 전송 한도를 초과했습니다."
        case .resync: return "관제 이벤트 순서가 달라 전체 상태를 다시 연결합니다."
        case .unsupported: return "Mac이 관제 이벤트 연결을 지원하지 않습니다. 서버 버전을 확인하세요."
        case .rejected(let code): return "관제 이벤트 연결이 거부되었습니다. 응답 코드 \(code)"
        }
    }
}

struct ControlRoomSSE {
    static let maxFrameBytes = 8 * 1024 * 1024
    static let maxBodyBytes = maxFrameBytes - 8192
    struct Frame {
        let id: String
        let event: String
        let data: Data
    }
    private var line = Data()
    private var body = Data()
    private var event = ""
    private var id = ""
    private var hasData = false
    private var frameBytes = 0
    private var pendingCR = false
    private var firstLine = true

    private mutating func countByte() throws {
        frameBytes += 1
        guard frameBytes <= Self.maxFrameBytes else { throw ControlRoomEventsError.tooLarge }
    }

    mutating func append(_ byte: UInt8) throws -> Frame? {
        if pendingCR {
            pendingCR = false
            if byte == 10 {
                try countByte()
                return try endLine()
            }
            let completed = try endLine()
            try countByte()
            if byte == 13 { pendingCR = true }
            else { line.append(byte) }
            return completed
        }
        try countByte()
        if byte == 13 { pendingCR = true; return nil }
        if byte == 10 { return try endLine() }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> Frame? {
        guard pendingCR else { return nil }
        pendingCR = false
        return try endLine()
    }

    private mutating func endLine() throws -> Frame? {
        guard var text = String(data:line,encoding:.utf8) else { throw ControlRoomEventsError.invalid }
        line.removeAll(keepingCapacity:true)
        if firstLine { firstLine = false; if text.first == "\u{feff}" { text.removeFirst() } }
        if text.isEmpty {
            defer {
                body = Data(); event = ""; id = ""; hasData = false; frameBytes = 0
            }
            return hasData ? Frame(id:id,event:event,data:body) : nil
        }
        if text.first == ":" { return nil }
        let parts = text.split(separator:":",maxSplits:1,omittingEmptySubsequences:false)
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch parts[0] {
        case "id":
            guard !value.contains("\0"), value.utf8.count <= 128 else { throw ControlRoomEventsError.invalid }
            id = value
        case "event": event = value
        case "data":
            if hasData { body.append(10) }
            body.append(contentsOf:value.utf8)
            hasData = true
            guard body.count <= Self.maxBodyBytes else { throw ControlRoomEventsError.tooLarge }
        default: break
        }
        return nil
    }
}

struct ControlRoomConnectionGeneration {
    struct Lease {
        let generation: UUID
        let retainsContent: Bool
    }
    private struct Source: Equatable { let address: String; let token: String }
    private var current = UUID()
    private var source: Source?

    mutating func begin(address: String, token: String) -> Lease {
        let next = Source(address:address,token:token)
        let retainsContent = source == next
        source = next
        current = UUID()
        return Lease(generation:current,retainsContent:retainsContent)
    }
    func owns(_ lease: Lease) -> Bool { current == lease.generation }
}

enum ControlRoomEventUpdate {
    case snapshot(ControlRoomProjection)
    case unavailable
    case disconnected(ControlRoomProjection?, String)

    var projection: ControlRoomProjection? {
        switch self {
        case .snapshot(let projection): return projection
        case .unavailable: return nil
        case .disconnected(let projection, _): return projection
        }
    }
    var message: String? {
        switch self {
        case .snapshot: return nil
        case .unavailable: return "관제 원본 또는 공개 정책을 확인할 수 없습니다. 이전 내용은 표시하지 않습니다."
        case .disconnected(_, let message): return message
        }
    }
}

final class ControlRoomEventRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ControlRoomEventStream {
    // Reduce every patch before coalescing display updates, so a slow UI cannot lose a revision.
    static func updates(request: URLRequest, retaining initial: ControlRoomProjection? = nil,
                        configuration: URLSessionConfiguration = .ephemeral)
        -> AsyncStream<ControlRoomEventUpdate> {
        AsyncStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let worker = Task {
                let session = URLSession(configuration:configuration,delegate:ControlRoomEventRedirects(),delegateQueue:nil)
                defer { session.invalidateAndCancel(); continuation.finish() }
                var reducer = ControlRoomEventsReducer()
                var cursor: String?
                var accepted = false
                var delay = 1
                while !Task.isCancelled {
                    do {
                        var next = request
                        next.setValue("text/event-stream",forHTTPHeaderField:"Accept")
                        next.setValue(cursor,forHTTPHeaderField:"Last-Event-ID")
                        next.timeoutInterval = 45
                        let (bytes,response) = try await session.bytes(for:next)
                        defer { bytes.task.cancel() }
                        guard let http = response as? HTTPURLResponse else { throw ControlRoomEventsError.invalid }
                        if [404,405,410,501].contains(http.statusCode) { throw ControlRoomEventsError.unsupported }
                        guard http.statusCode == 200 else { throw ControlRoomEventsError.rejected(http.statusCode) }
                        guard http.value(forHTTPHeaderField:"Content-Type")?.split(separator:";").first?
                            .trimmingCharacters(in:.whitespaces).lowercased() == "text/event-stream"
                        else { throw ControlRoomEventsError.invalid }
                        var parser = ControlRoomSSE()
                        var needsSnapshot = true
                        func apply(_ frame: ControlRoomSSE.Frame) throws {
                            if needsSnapshot && frame.event != "snapshot" { throw ControlRoomEventsError.resync }
                            switch try reducer.consume(frame,contract:.relayProjection) {
                            case .applied:
                                needsSnapshot = false
                                accepted = true
                                cursor = reducer.cursor
                                delay = 1
                                if let value = reducer.projection, value.hasDisplayContent {
                                    continuation.yield(.snapshot(value))
                                } else {
                                    continuation.yield(.unavailable)
                                }
                            case .resync: throw ControlRoomEventsError.resync
                            case .ignored, .heartbeat: break
                            }
                        }
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if let frame = try parser.append(byte) { try apply(frame) }
                        }
                        if let frame = try parser.finish() { try apply(frame) }
                        throw URLError(.networkConnectionLost)
                    } catch {
                        guard !Task.isCancelled else { return }
                        let terminal: Bool
                        switch error {
                        case ControlRoomEventsError.unsupported: terminal = true
                        case ControlRoomEventsError.rejected(let code): terminal = (300..<500).contains(code) && code != 408 && code != 429
                        default: terminal = false
                        }
                        switch error {
                        case ControlRoomEventsError.invalid, ControlRoomEventsError.tooLarge, ControlRoomEventsError.resync:
                            cursor = nil
                        default:
                            if error is DecodingError { cursor = nil }
                        }
                        let last = accepted ? reducer.projection : initial
                        let retained = last?.hasDisplayContent == true ? last?.disconnected() : nil
                        continuation.yield(.disconnected(retained,
                            "\(error.localizedDescription) 마지막 내용은 읽기 전용이며 다시 연결을 기다립니다."))
                        if terminal { return }
                        do { try await Task.sleep(for:.seconds(delay)) } catch { return }
                        delay = min(delay * 2,10)
                    }
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
