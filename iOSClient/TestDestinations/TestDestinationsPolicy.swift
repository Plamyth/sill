import Foundation
import StreamProtocol

enum TestDestinationsError: Error, LocalizedError, Equatable {
    case missing, malformed, stale, changed, unsafeURL, unavailable, relayMissing, connection, externalLogin

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .missing: return "테스트 목록이 아직 전달되지 않았습니다."
        case .malformed: return "테스트 목록 형식이 올바르지 않습니다."
        case .stale: return "테스트 목록의 확인 시간이 지났습니다. 새로고침하세요."
        case .changed: return "선택한 대상의 프로젝트·주소·담당자·이동 허용 범위가 바뀌었습니다. 목록에서 다시 선택하세요."
        case .unsafeURL: return "안전하게 열 수 없는 테스트 주소입니다."
        case .unavailable: return "담당자가 실행 중임을 확인한 테스트 대상이 아닙니다."
        case .relayMissing: return "저장된 Mac 연결이 없습니다. 그림판 연결 설정을 확인하세요."
        case .connection: return "테스트 목록을 가져오지 못했습니다. Mac 연결을 확인하고 다시 시도하세요."
        case .externalLogin: return "다른 주소나 새 창을 사용하는 외부 로그인은 지원하지 않습니다."
        }
    }
}

enum TestDestinationsEnvelope: Decodable {
    case missing, malformed, catalog(TestDestinationCatalog)

    private enum CodingKeys: String, CodingKey { case testDestinations }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard fields.contains(.testDestinations) else {
            self = .missing
            return
        }
        do {
            self = .catalog(try fields.decode(TestDestinationCatalog.self, forKey: .testDestinations))
        } catch {
            self = .malformed
        }
    }

    func validated(now: Date = Date()) throws -> TestDestinationCatalog {
        switch self {
        case .missing: throw TestDestinationsError.missing
        case .malformed: throw TestDestinationsError.malformed
        case .catalog(let catalog):
            try TestDestinationsPolicy.validate(catalog, now: now)
            return catalog
        }
    }
}

struct TestDestinationIdentity: Equatable {
    let id: String
    let projectID: String
    let projectLabel: String
    let url: String
    let owner: String
    let redirectOrigins: [String]

    init(_ entry: TestDestinationCatalog.Entry) {
        id = entry.id
        projectID = entry.projectId
        projectLabel = entry.projectLabel
        url = entry.url
        owner = entry.owner
        redirectOrigins = entry.redirectOrigins
    }
}

struct TestDestinationTarget {
    let entry: TestDestinationCatalog.Entry
    let url: URL
    let allowedOrigins: [TestDestinationOrigin]

    init(_ entry: TestDestinationCatalog.Entry, now: Date = Date()) throws {
        guard entry.reachability == .reachable else { throw TestDestinationsError.unavailable }
        guard let checkedAt = entry.checkedAt, TestDestinationsPolicy.recent(checkedAt, now: now) else { throw TestDestinationsError.stale }
        guard let url = try? entry.validatedURL(), let origin = TestDestinationOrigin(url),
              let redirects = try? entry.validatedRedirectOrigins() else {
            throw TestDestinationsError.unsafeURL
        }
        let redirectOrigins = redirects.compactMap(TestDestinationOrigin.init)
        guard redirectOrigins.count == redirects.count else { throw TestDestinationsError.unsafeURL }
        self.entry = entry
        self.url = url
        allowedOrigins = [origin] + redirectOrigins
    }

    func allows(_ url: URL) -> Bool {
        var candidate = entry
        candidate.url = url.absoluteString
        guard (try? candidate.validatedURL()) != nil else { return false }
        guard let origin = TestDestinationOrigin(url) else { return false }
        return allowedOrigins.contains(origin)
    }
}

struct TestDestinationOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased() else { return nil }
        let labels = host.split(separator: ".")
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            guard labels.count == 4, labels.allSatisfy({ Int($0).map(String.init) == String($0) }) else { return nil }
        }
        self.scheme = scheme
        self.host = host
        port = components.port ?? (scheme == "https" ? 443 : 80)
    }
}

enum TestDestinationsPolicy {
    static func recent(_ value: String, now: Date, maximumAge: TimeInterval = 45) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: value) else { return false }
        return (-5...maximumAge).contains(now.timeIntervalSince(date))
    }

    static func validate(_ catalog: TestDestinationCatalog, now: Date) throws {
        do { try catalog.validate() }
        catch { throw TestDestinationsError.malformed }
        guard recent(catalog.observedAt, now: now) else { throw TestDestinationsError.stale }
    }

    static func revalidate(_ identity: TestDestinationIdentity, in catalog: TestDestinationCatalog,
                           now: Date = Date()) throws -> TestDestinationTarget {
        try validate(catalog, now: now)
        guard let entry = catalog.entries.first(where: { $0.id == identity.id }),
              TestDestinationIdentity(entry) == identity else { throw TestDestinationsError.changed }
        return try TestDestinationTarget(entry, now: now)
    }
}

@MainActor
enum TestDestinationSessions {
    private static let key = "testDestinations.projectSessions.v1"
    private static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    static func identifier(projectID: String, defaults: UserDefaults = .standard) -> UUID {
        var sessions = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let stored = sessions[projectID], let id = UUID(uuidString: stored), id != zero,
           sessions.filter({ $0.value.lowercased() == stored.lowercased() }).count == 1 { return id }
        var id = UUID()
        while id == zero || sessions.values.contains(id.uuidString) { id = UUID() }
        sessions[projectID] = id.uuidString
        defaults.set(sessions, forKey: key)
        return id
    }
}
