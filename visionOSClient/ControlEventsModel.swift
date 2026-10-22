import Foundation

indirect enum ControlEventsValue: Codable, Equatable, Sendable {
    case object([String: ControlEventsValue]), array([ControlEventsValue])
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

struct ControlEventsDocument: Equatable, Sendable {
    var root: [String: ControlEventsValue]
}

struct ControlEventsRecord: Equatable, Sendable {
    let id: String
    let value: ControlEventsValue
}

struct ControlEventsPatch: Equatable, Sendable {
    var set: [String: ControlEventsValue] = [:]
    var unset: [String] = []
    var upsertThreads: [ControlEventsRecord] = []
    var removeThreads: [String] = []
    var upsertCatalog: [ControlEventsRecord] = []
    var removeCatalog: [String] = []
}

struct ControlEventsVersion: Equatable, Sendable {
    let generation: UUID
    let revision: Int64
    let emittedAt: String
}

enum ControlEventsEnvelope: Equatable, Sendable {
    case snapshot(ControlEventsVersion, ControlEventsDocument)
    case patch(ControlEventsVersion, baseRevision: Int64, ControlEventsPatch)
    case heartbeat(ControlEventsVersion)
}

enum ControlEventsProvider: String, CaseIterable, Identifiable, Sendable {
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

struct ControlEventsWorkID: Hashable, Sendable {
    let provider: ControlEventsProvider
    let originalID: String
    let sessionID: String?
    let runID: String?
    var hostID: String? = nil
    var rowKey: String? = nil
    var instanceID: String? = nil
    var startedAt: String? = nil
    var workspaceIdentity: String? = nil
}

struct ControlEventsExecutionObservation: Equatable, Sendable {
    let state: String?
    let observedAt: String?
}

struct ControlEventsConnectionObservation: Equatable, Sendable {
    let state: String?
    let observedAt: String?
    let connectedAt: String?
}

enum ControlEventsNativeSupport: Equatable, Sendable {
    case supported, unsupported(String), unknown
    var label: String {
        switch self {
        case .supported: return "원본 이벤트 지원"
        case .unsupported(let reason): return "원본 이벤트 미지원 · \(reason)"
        case .unknown: return "원본 이벤트 지원 여부 미확인"
        }
    }
}

struct ControlEventsSourceObservation: Equatable, Sendable {
    let provider: ControlEventsProvider
    let support: ControlEventsNativeSupport
    let connection: ControlEventsConnectionObservation
    let connected: Bool?
    let owner: String?
    let sessionID: String?
    let runID: String?
    let sourceRevision: ControlEventsValue?
    let readOnly: Bool?
    let capabilities: ControlEventsValue?
}

enum ControlEventsSessionConnection: Equatable, Sendable {
    case unavailable
    case mismatched(ControlEventsSourceObservation)
    case current(ControlEventsSourceObservation)
    case stale(ControlEventsSourceObservation)

    var observation: ControlEventsSourceObservation? {
        switch self {
        case .unavailable: return nil
        case .mismatched(let observation), .current(let observation), .stale(let observation): return observation
        }
    }

    var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .unavailable: return "개별 연결 미확인 · 개별 정보 미제공 또는 해석 불가"
        case .mismatched: return "개별 연결 미확인 · 세션·실행 결박 거부"
        case .current: return "개별 원본 연결 확인"
        case .stale: return "마지막 관측 · 개별 원본 연결 미확인"
        }
    }
}

struct ControlEventsWork: Equatable, Identifiable, Sendable {
    let id: ControlEventsWorkID
    let title: String
    let ownerID: String?
    let execution: ControlEventsExecutionObservation
    let connection: ControlEventsConnectionObservation
    var sourceConnection: ControlEventsSessionConnection = .unavailable
    var reportedOwnerID: String? = nil
    var ownerVerified: Bool? = nil
    var sourceRevision: ControlEventsValue? = nil
    var agentStatus: String? = nil
    var statusSource: String? = nil
    var fresh: Bool? = nil
    var readOnly: Bool? = nil
    var capabilities: ControlEventsValue? = nil
    var threadID: String? = nil
    var activeTurnID: String? = nil
    var recordObservedAt: String? = nil
    var reportedStatus: String? = nil
    var currentResult: String? = nil
}

struct ControlEventsProjection: Equatable, Sendable {
    let sources: [ControlEventsSourceObservation]
    let work: [ControlEventsWork]
    var unsupportedRows: Int = 0
    var adapterError: String? = nil
    var truncated: Bool = false
}

struct ControlEventsSelection: Equatable {
    var provider: ControlEventsProvider = .codex
    var workID: ControlEventsWorkID?

    mutating func reconcile(_ projection: ControlEventsProjection?) {
        guard let workID else { return }
        if workID.provider != provider || projection?.work.contains(where: { $0.id == workID }) != true {
            self.workID = nil
        }
    }

    mutating func select(_ provider: ControlEventsProvider) {
        self.provider = provider
        workID = nil
    }
}
