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

    func isFresh(now: Date = Date()) -> Bool {
        schemaVersion == 1 && Self.recent(generatedAt,now:now)
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

enum BrainTrinityMode: String, Decodable {
    case stopped, starting, running, stopping, blocked
}

enum BrainTrinityPhase: String, Decodable {
    case queued, observationPending = "observation_pending", resultReview = "result_review", attention, completed
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
