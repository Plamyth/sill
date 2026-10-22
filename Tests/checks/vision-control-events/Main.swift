import Foundation

private var checks = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { fatalError("검사 실패: \(label)") }
}
private func rejects(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); expect(false, label) } catch { expect(true, label) }
}
private let date = "2026-10-23T00:00:00.000Z"
private func frame(_ object: [String: Any]) throws -> ControlEventsSSEFrame {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return ControlEventsSSEFrame(event: object["type"] as! String, data: String(decoding: data, as: UTF8.self),
        id: "\(object["generation"]!):\(object["revision"]!)", retryMilliseconds: nil)
}
private func object(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}
private func encodeState(_ reducer: ControlEventsReducer, _ status: String) throws -> ControlEventsValue {
    let state: ControlEventsValue
    if let version = reducer.version, let document = reducer.document {
        state = .object(["generation": .string(version.generation.uuidString.lowercased()),
                         "revision": .number(Double(version.revision)), "snapshot": .object(document.root)])
    } else { state = .null }
    return .object(["state": state, "status": .string(status)])
}
private func golden(_ fixture: [String: Any]) throws -> [ControlEventsValue] {
    let events = fixture["events"] as! [[String: Any]]
    let sequence = events + [events[1], fixture["gap"] as! [String: Any], fixture["replacement"] as! [String: Any]]
    var reducer = ControlEventsReducer()
    let token = UUID()
    reducer.begin(token); reducer.opened(token, at: Date(timeIntervalSince1970: 100))
    var result = [ControlEventsValue]()
    var statuses = [String]()
    for raw in sequence {
        let outcome = reducer.consume(try ControlEventsCodec.decode(frame(raw)), subscription: token)
        let status: String
        switch outcome {
        case .applied: status = "applied"
        case .ignored: status = "ignored"
        case .heartbeat: status = "heartbeat"
        case .resyncRequired: status = "resync"
        case .invalid: status = "invalid"
        }
        statuses.append(status)
        result.append(try encodeState(reducer, status))
    }
    expect(statuses == ["applied", "applied", "heartbeat", "ignored", "resync", "applied"], "공통 순서와 상태")
    return result
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            let (response, data) = try handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }
private func stubConfiguration() -> URLSessionConfiguration {
    let config = ControlEventsTransport.configuration()
    config.protocolClasses = [StubURLProtocol.self]
    return config
}
private func response(_ url: URL, _ status: Int = 200, _ type: String = "application/json; charset=utf-8") -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
}
private func gateway() throws -> ControlEventsGateway {
    try VisionControlCredential(origin: VisionControlOrigin("https://unit.invalid:10443"), token: String(repeating: "a", count: 64)).gateway()
}
private final class Streams {
    var opened = 0
    var authorizations = [String?]()
    var continuations = [AsyncThrowingStream<ControlEventsStreamItem, Error>.Continuation]()
    func open(_ gateway: ControlEventsGateway) -> AsyncThrowingStream<ControlEventsStreamItem, Error> {
        opened += 1
        authorizations.append(try? gateway.request().value(forHTTPHeaderField: "Authorization"))
        return AsyncThrowingStream { continuations.append($0) }
    }
}
@MainActor private func eventually(_ label: String, _ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { expect(true, label); return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    expect(false, label)
}

@main struct ControlEventsChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let common = try object(directory.appendingPathComponent("control-events-v1.json"))
        let mobile = try object(directory.appendingPathComponent("mobile-control-events-v1.json"))
        let commonGolden = try golden(common)
        let mobileGolden = try golden(mobile)
        try largeCatalogChecks(mobile)
        try sessionConnectionChecks(mobile)
        let events = mobile["events"] as! [[String: Any]]
        let first = try ControlEventsCodec.decode(frame(events[0]))
        let patch = try ControlEventsCodec.decode(frame(events[1]))
        guard case .snapshot(let version, let document) = first else { fatalError() }
        let projected = try ControlEventsCodec.project(document)
        expect(projected.work.count == 3, "모바일 실제 허용 필드의 세 소스")
        expect(Set(projected.work.map(\.id)).count == 3, "서로 같은 ID 문자열의 provider 격리")
        let local = projected.work.first { $0.id.provider == .cursorDesktop }!
        expect(local.ownerID == nil && local.ownerVerified == false, "담당 null 보존")
        expect(local.execution.state == nil && local.execution.observedAt == nil, "로컬 열린 대화를 실행으로 승격하지 않음")
        expect(local.id.instanceID != nil && local.id.startedAt != nil && local.id.workspaceIdentity != nil, "로컬 복합 식별자")
        let cloud = projected.work.first { $0.id.provider == .cursorCloud }!
        expect(cloud.execution.state == "FINISHED" && cloud.agentStatus == "IDLE", "Cloud 실행과 에이전트 상태 분리")
        expect(cloud.sourceRevision != nil && cloud.capabilities != nil, "원본 권한 보고와 revision 보존")
        var reducer = ControlEventsReducer()
        let old = UUID(); reducer.begin(old); reducer.opened(old, at: Date())
        expect(reducer.consume(first, subscription: old) == .applied, "최초 snapshot")
        let before = reducer.document
        let openedAt = reducer.transportOpenedAt
        expect(reducer.consume(.heartbeat(version), subscription: old) == .heartbeat, "heartbeat 순서 확인")
        expect(reducer.document == before && reducer.transportOpenedAt == openedAt && reducer.version == version, "heartbeat 상태·관측·권한 불변")
        let mismatch = ControlEventsVersion(generation: version.generation, revision: version.revision + 1, emittedAt: date)
        expect(reducer.consume(.heartbeat(mismatch), subscription: old) == .resyncRequired && reducer.document == before, "heartbeat gap 복구")
        let next = UUID(); reducer.begin(next); reducer.opened(next, at: Date())
        expect(reducer.consume(first, subscription: old) == .ignored, "이전 snapshot 콜백 차단")
        expect(reducer.consume(patch, subscription: old) == .ignored, "이전 patch 콜백 차단")
        reducer.stop(old, failed: true)
        expect(reducer.subscription == next && reducer.transport == .open, "이전 실패 콜백 차단")
        expect(reducer.consume(patch, subscription: next) == .resyncRequired, "재접속 snapshot 전 patch 거절")
        expect(reducer.consume(first, subscription: next) == .applied, "재접속 동일 revision snapshot 복구")
        expect(reducer.consume(patch, subscription: next) == .applied, "순차 patch")
        expect(reducer.consume(first, subscription: next) == .ignored, "역순 snapshot 거절")
        var selection = ControlEventsSelection(provider: cloud.id.provider, workID: cloud.id)
        selection.reconcile(ControlEventsProjection(sources: [], work: []))
        expect(selection.workID == nil, "삭제된 선택 정리")
        let selectionBefore = reducer.document
        selection.select(.codex)
        expect(reducer.document == selectionBefore, "선택은 원본 상태를 만들지 않음")

        var root = document.root
        var normalized = root["unifiedControl"]!
        if case .object(var fields) = normalized, case .array(var rows) = fields["rows"],
           let index = rows.firstIndex(where: { if case .object(let row) = $0 { return row.text("source") == "cursor-desktop" }; return false }),
           case .object(var localRow) = rows[index] {
            localRow["executionStatus"] = .string("RUNNING")
            localRow["statusSource"] = .string("synthetic-native-execution")
            rows[index] = .object(localRow); fields["rows"] = .array(rows); normalized = .object(fields)
        }
        root["unifiedControl"] = normalized
        let future = try ControlEventsCodec.project(ControlEventsDocument(root: root)).work.first { $0.id.provider == .cursorDesktop }!
        expect(future.execution.state == "RUNNING" && future.execution.observedAt != nil, "명시 원본 실행 근거는 로컬도 보존")
        let unknown = ControlEventsDocument(root: ["schemaVersion": .number(1), "threads": .array([.object(["id": .string("unknown")])])])
        let unknownProjection = try ControlEventsCodec.project(unknown)
        expect(unknownProjection.work.isEmpty && unknownProjection.unsupportedRows == 1, "출처 누락을 Codex로 추정하지 않음")

        var raw = events[0]; raw["schema"] = "unknown"
        rejects("미지원 schema") { _ = try ControlEventsCodec.decode(frame(raw)) }
        raw = events[2]; raw["observedAt"] = date
        rejects("heartbeat에 관측 필드 추가 거절") { _ = try ControlEventsCodec.decode(frame(raw)) }
        raw = events[1]; raw["revision"] = 9_007_199_254_740_992 as Int64
        rejects("JS safe integer 초과") { _ = try ControlEventsCodec.decode(frame(raw)) }
        raw = events[1]; raw["baseRevision"] = 0.5
        rejects("소수 revision") { _ = try ControlEventsCodec.decode(frame(raw)) }
        raw = events[1]; raw["set"] = ["__proto__": ["bad": true]]
        rejects("위험한 root 키") { _ = try ControlEventsCodec.decode(frame(raw)) }
        let wrongID = ControlEventsSSEFrame(event: "snapshot", data: try frame(events[0]).data, id: "bad", retryMilliseconds: nil)
        rejects("SSE ID 일치") { _ = try ControlEventsCodec.decode(wrongID) }
        var unset = ControlEventsPatch(set: ["extra": .string("new")], unset: ["extra", "workspace"])
        unset.upsertThreads = [ControlEventsRecord(id: "fresh", value: .object(["id": .string("fresh"), "source": .string("codex")]))]
        unset.removeThreads = ["nonexistent"]
        let unsetVersion = ControlEventsVersion(generation: version.generation, revision: 2, emittedAt: date)
        expect(reducer.consume(.patch(unsetVersion, baseRevision: 1, unset), subscription: next) == .applied, "set/unset 및 ID별 upsert/remove")
        expect(reducer.document?.root["extra"] == nil && reducer.document?.root["workspace"] == nil, "root unset은 set 뒤에 적용")

        let wire = Data("\u{FEFF}: 주석\r\nid: abc\revent: patch\ndata: 한글\r\ndata: 두번째\nid: ignored\0id\nretry: 123\nretry: invalid\n\n".utf8)
        for split in 0...wire.count {
            var parser = ControlEventsSSEParser()
            let frames = try parser.append(wire.prefix(split)) + parser.append(wire.suffix(wire.count - split))
            try parser.finish()
            expect(frames == [ControlEventsSSEFrame(event: "patch", data: "한글\n두번째", id: "abc", retryMilliseconds: 123)], "SSE 바이트 경계 \(split)")
        }
        var parser = ControlEventsSSEParser()
        _ = try parser.append(Data("data: incomplete".utf8))
        rejects("끝의 미완성 프레임") { try parser.finish() }
        var limited = ControlEventsSSEParser(maximumFrameBytes: 8)
        rejects("프레임 상한") { _ = try limited.append(Data("data:123456789".utf8)) }
        var invalidUTF8 = ControlEventsSSEParser()
        rejects("잘못된 UTF-8") { _ = try invalidUTF8.append(Data([0xFF, 10])) }
        var retry = ControlEventsRetryPolicy()
        expect(retry.delay(for: ControlEventsTransportFailure.streamEnded) == 1_000_000_000, "EOF 제한 backoff")
        expect(retry.delay(for: ControlEventsTransportFailure.streamEnded) == nil, "같은 실패 두 번 종료")
        retry.progressed()
        expect(retry.delay(for: URLError(.timedOut)) != nil, "일시 네트워크 재접속")
        expect(retry.delay(for: URLError(.serverCertificateUntrusted)) == nil, "TLS 실패 재시도 금지")
        expect(retry.delay(for: ControlEventsTransportFailure.authentication) == nil, "인증 실패 재시도 금지")
        expect(retry.delay(for: ControlEventsTransportFailure.payload) == nil, "계약 실패 재시도 금지")
        let gateway = try gateway()
        let recoveryRequest = try gateway.request()
        expect(recoveryRequest.value(forHTTPHeaderField: "Last-Event-ID") == nil, "전체 snapshot 재접속 정책")
        rejects("HTTPS 제한") { _ = try VisionControlOrigin("http://unit.invalid") }
        for url in ["https://name:password@unit.invalid", "https://unit.invalid?token=secret", "https://unit.invalid#fragment", "https://unit.invalid/path"] {
            rejects("origin 경계") { _ = try VisionControlOrigin(url) }
        }
        try await enrollmentChecks()
        try await lifecycleChecks(first: first)
        let result: ControlEventsValue = .object(["checks": .number(Double(checks)), "externalEffects": .number(0),
            "commonGolden": .array(commonGolden), "mobileGolden": .array(mobileGolden)])
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }

    static func sessionConnectionChecks(_ fixture: [String: Any]) throws {
        let event = (fixture["events"] as! [[String: Any]])[0]
        guard case .snapshot(_, let document) = try ControlEventsCodec.decode(frame(event)),
              case .object(let unified) = document.root["unifiedControl"],
              let rows = unified.rows("rows"), let row = rows.first(where: { $0.text("source") == "codex" }),
              case .object(let connection) = row["sourceConnection"] else { fatalError("새 개별 연결 fixture 누락") }
        func project(_ row: [String: ControlEventsValue]) throws -> ControlEventsProjection {
            var root = document.root
            var fields = unified
            fields["rows"] = .array([.object(row)])
            root["unifiedControl"] = .object(fields)
            return try ControlEventsCodec.project(ControlEventsDocument(root: root))
        }
        func work(_ row: [String: ControlEventsValue]) throws -> ControlEventsWork { try project(row).work[0] }
        func changing(_ key: String, _ value: ControlEventsValue?) -> [String: ControlEventsValue] {
            var updated = row
            var source = connection
            source[key] = value
            updated["sourceConnection"] = .object(source)
            return updated
        }
        let current = try work(row)
        expect(current.sourceConnection.isCurrent, "새 fixture 개별 Codex 연결 수용")
        let source = current.sourceConnection.observation!
        expect(source.owner == "fixture-runtime-owner" && current.ownerID == row.text("ownerThreadId") && source.owner != current.ownerID,
               "실행 환경 담당과 원담당 대화 독립 보존")
        expect(source.readOnly == true && source.capabilities == .object(["read": .bool(false), "send": .bool(false)]),
               "관측기 권한 false 보존")
        expect(current.readOnly == false && current.capabilities == .object(["read": .bool(true), "send": .bool(true)]),
               "기존 명령 도우미 행 send true와 관측기 send false 독립")
        expect(source.sourceRevision == .number(7), "개별 변경 번호는 행과 별도로 보존")

        var disconnected = changing("connected", .bool(false))
        if case .object(var raw) = disconnected["sourceConnection"] {
            raw["state"] = .string("stale")
            raw["observedAt"] = .string("2020-01-01T00:00:00.000Z")
            disconnected["sourceConnection"] = .object(raw)
        }
        let split = try project(disconnected)
        expect(split.sources.first { $0.provider == .codex }?.connected == true, "제공자 요약은 계속 연결")
        let last = split.work[0]
        if case .stale = last.sourceConnection { expect(true, "개별 원본 단절은 마지막 관측") }
        else { expect(false, "개별 원본 단절은 마지막 관측") }
        expect(last.connection.state == "connected" && !last.sourceConnection.isCurrent, "flat 연결값으로 개별 단절을 복원하지 않음")
        expect(last.execution == current.execution && last.recordObservedAt == current.recordObservedAt,
               "개별 단절에도 기존 실행 상태와 관측 시각 보존")
        expect(last.sourceConnection.observation?.connection.observedAt != last.execution.observedAt,
               "실행 관측과 연결 관측은 서로 덮지 않음")
        expect(last.sourceConnection.label.contains("마지막 관측"), "개별 UI에 마지막 관측 문구 제공")
        var stale = row
        stale["stale"] = .bool(true)
        let staleWork = try work(stale)
        expect(!staleWork.sourceConnection.isCurrent && staleWork.execution == current.execution, "행 stale는 실행 관측을 보존하며 현재 연결 거부")
        var quiet = changing("observedAt", .string("2020-01-01T00:00:00.000Z"))
        quiet["agentStatus"] = .string("quiet")
        quiet["fresh"] = .bool(false)
        let quietWork = try work(quiet)
        expect(quietWork.sourceConnection.isCurrent && quietWork.agentStatus == "quiet", "조용한 세션의 오래된 시각에 TTL 단절을 적용하지 않음")
        expect(quietWork.execution == current.execution, "연결 관측 시각으로 실행 관측을 덮지 않음")

        for (key, value) in [("sessionId", "55555555-5555-4555-8555-555555555555"),
                             ("runId", "66666666-6666-4666-8666-666666666666"), ("provider", "cursor-cloud")] {
            let wrong = try work(changing(key, .string(value)))
            if case .mismatched(let observation) = wrong.sourceConnection {
                expect(observation.owner == source.owner, "잘못된 결박에도 관측 원문 보존 \(key)")
            } else { expect(false, "잘못된 결박 거부 \(key)") }
            expect(!wrong.sourceConnection.isCurrent && wrong.execution == current.execution, "결박 거부는 실행 기록을 바꾸지 않음 \(key)")
            expect(wrong.sourceConnection.label.contains("결박 거부"), "잘못된 결박의 UI 문구 \(key)")
        }
        for key in ["externalId", "sessionId", "threadId", "runId", "activeTurnId"] {
            var alias = row
            alias[key] = .string("77777777-7777-4777-8777-777777777777")
            let rejected = try work(alias)
            expect(!rejected.sourceConnection.isCurrent, "서로 다른 Codex UUID 별칭 거부 \(key)")
            expect(rejected.sourceConnection.observation == source, "거부한 별칭에 맞춰 연결 JSON을 조작하지 않음 \(key)")
        }
        for key in ["threadId", "activeTurnId"] {
            var alias = row
            alias[key] = .string("not-a-uuid")
            let invalid = try work(alias)
            expect(!invalid.sourceConnection.isCurrent, "Codex UUID 형식 검사 \(key)")
        }
        let invalidRevisions: [ControlEventsValue?] = [nil, .null, .string("7"), .number(-1), .number(0.5),
            .number(9_007_199_254_740_992), .bool(true)]
        for revision in invalidRevisions {
            let invalid = try work(changing("sourceRevision", revision))
            expect(!invalid.sourceConnection.isCurrent, "잘못된 개별 JS safe integer는 현재 연결 불가")
        }
        let maximum = try work(changing("sourceRevision", .number(9_007_199_254_740_991)))
        expect(maximum.sourceConnection.isCurrent, "개별 JS safe integer 최댓값 수용")
        for owner in [ControlEventsValue.null, .string(""), .string("  ")] {
            let invalid = try work(changing("owner", owner))
            expect(!invalid.sourceConnection.isCurrent, "실행 환경 담당 없이는 현재 연결 불가")
        }
        let contradictory = try work(changing("state", .string("stale")))
        expect(!contradictory.sourceConnection.isCurrent, "connected true만으로 state stale를 복원하지 않음")
        for missing in [ControlEventsValue.null, .string("legacy")] {
            var legacy = row
            legacy["sourceConnection"] = missing
            let unknown = try work(legacy)
            expect(unknown.sourceConnection == .unavailable, "없는 개별 객체는 요약과 flat값이 있어도 미확인")
        }
        var legacy = row
        legacy["sourceConnection"] = nil
        let absent = try work(legacy)
        expect(absent.sourceConnection == .unavailable && absent.execution == current.execution, "legacy 개별 필드 미제공 보존")
        var unverified = row
        unverified["ownerVerified"] = .bool(false)
        let unverifiedOwner = try work(unverified)
        expect(unverifiedOwner.ownerID == nil && unverifiedOwner.reportedOwnerID == current.ownerID && unverifiedOwner.ownerVerified == false,
               "미확인 원담당은 확정하지 않고 보고값으로만 보존")

        var structured = document.root
        var ownedThread = document.root.rows("threads")![0]
        ownedThread["owner"] = .object(["verified": .bool(true), "name": .string("합성 담당"), "threadId": row["ownerThreadId"]!])
        structured["threads"] = .array([.object(ownedThread)])
        let modern = try ControlEventsCodec.project(ControlEventsDocument(root: structured))
        expect(modern.work.count == 3, "정규화 관제는 구조화된 기존 담당 필드와 독립 소비")
        structured["unifiedControl"] = nil
        structured["catalog"] = .array([])
        let structuredFallback = try ControlEventsCodec.project(ControlEventsDocument(root: structured)).work[0]
        expect(structuredFallback.ownerID == row.text("ownerThreadId") && structuredFallback.ownerVerified == true,
               "기존 구조화 담당은 검증된 대화 식별자로 소비")

        let thread = document.root.rows("threads")![0]
        for name in ["threads", "catalog"] {
            var root = document.root
            root["unifiedControl"] = nil
            root["threads"] = .array([])
            root["catalog"] = .array([])
            var record = thread
            record["ownerThreadId"] = row["ownerThreadId"]
            root[name] = .array([.object(record)])
            let fallback = try ControlEventsCodec.project(ControlEventsDocument(root: root)).work[0]
            expect(fallback.sourceConnection.isCurrent && fallback.sourceConnection.observation?.owner != fallback.ownerID,
                   "\(name) 개별 연결과 담당 분리")
            record["sourceConnection"] = nil
            root[name] = .array([.object(record)])
            let missing = try ControlEventsCodec.project(ControlEventsDocument(root: root)).work[0]
            expect(missing.sourceConnection == .unavailable, "\(name) legacy 개별 연결 미확인")
        }
        var idle = row
        idle["runId"] = .null
        idle["activeTurnId"] = .null
        var idleSource = connection
        idleSource["runId"] = .null
        idle["sourceConnection"] = .object(idleSource)
        let idleWork = try work(idle)
        expect(idleWork.sourceConnection.isCurrent, "활성 실행 없는 조용한 세션의 null 실행 결박 수용")
    }

    static func largeCatalogChecks(_ fixture: [String: Any]) throws {
        var event = (fixture["events"] as! [[String: Any]])[0]
        var snapshot = event["snapshot"] as! [String: Any]
        var unified = snapshot["unifiedControl"] as! [String: Any]
        let tail = (unified["rows"] as! [[String: Any]]).filter { $0["source"] as? String != "codex" }
        var rows = (0..<4000).map { index -> [String: Any] in
            let id = "large-codex-\(index)"
            return ["key": "codex:\(id)", "source": "codex", "provider": "codex", "externalId": id,
                    "sessionId": id, "status": "대기", "title": String(repeating: "x", count: 640)]
        }
        rows.append(contentsOf: tail)
        unified["rows"] = rows
        snapshot["unifiedControl"] = unified
        event["snapshot"] = snapshot
        let large = try frame(event)
        expect(large.data.utf8.count > 2_097_152 && large.data.utf8.count < ControlEventsGateway.maximumPayloadBytes,
               "실제 규모의 큰 모바일 본문")
        var parser = ControlEventsSSEParser(maximumFrameBytes: try gateway().maximumFrameBytes)
        func wire(_ frame: ControlEventsSSEFrame) -> Data {
            Data("id: \(frame.id)\nevent: \(frame.event)\ndata: \(frame.data)\n\n".utf8)
        }
        let frames = try parser.append(wire(large))
        expect(frames.count == 1, "8MiB 수신 한도로 2MiB 초과 snapshot 수용")
        var reducer = ControlEventsReducer()
        let id = UUID(); reducer.begin(id); reducer.opened(id, at: Date())
        let initial = try ControlEventsCodec.decode(frames[0])
        expect(reducer.consume(initial, subscription: id) == .applied, "큰 snapshot 적용")
        var projected = try ControlEventsCodec.project(reducer.document!)
        expect(projected.work.count == 4000 + tail.count, "4천 Codex 뒤 원본 행 전체 보존")
        expect(projected.work.filter { $0.id.provider == .codex }.allSatisfy { $0.sourceConnection == .unavailable },
               "개별 연결 없는 대형 Codex 행은 자르지 않고 미확인 보존")
        expect(projected.work.contains { $0.id.provider == .cursorDesktop } && projected.work.contains { $0.id.provider == .cursorCloud },
               "뒤쪽 Cursor 로컬과 Cloud 보존")
        let oldCloud = projected.work.first { $0.id.provider == .cursorCloud }!
        let cloudIndex = rows.firstIndex { $0["source"] as? String == "cursor-cloud" }!
        rows[cloudIndex]["runId"] = "large-next-run"
        rows[cloudIndex]["executionStatus"] = "RUNNING"
        unified["rows"] = rows
        let patch: [String: Any] = ["schema": ControlEventsCodec.schema, "type": "patch", "generation": event["generation"]!,
            "revision": 1, "baseRevision": 0, "emittedAt": date,
            "set": ["unifiedControl": unified], "unset": [],
            "threads": ["upsert": [], "remove": []], "catalog": ["upsert": [], "remove": []]]
        let changes = try parser.append(wire(frame(patch)))
        let outcome = reducer.consume(try ControlEventsCodec.decode(changes[0]), subscription: id)
        expect(outcome == .applied, "큰 본문의 후속 patch 적용")
        projected = try ControlEventsCodec.project(reducer.document!)
        expect(projected.work.count == 4000 + tail.count && projected.work.first { $0.id.provider == .cursorCloud }?.id.runID == "large-next-run",
               "큰 목록의 뒤쪽 실행 변경 보존")
        var selection = ControlEventsSelection(provider: .cursorCloud, workID: oldCloud.id)
        selection.reconcile(projected)
        expect(selection.workID == nil, "실행 교체는 이전 선택을 새 실행으로 자동 이동하지 않음")
    }

    @MainActor static func enrollmentChecks() async throws {
        let origin = try VisionControlOrigin("https://unit.invalid:10443/")
        let token = String(repeating: "a", count: 64)
        let code = String(repeating: "b", count: 24)
        let calls = Box(0)
        StubURLProtocol.handler = { request in
            calls.value += 1
            expect(request.url == origin.enrollURL && request.httpMethod == "POST", "등록 endpoint와 POST 결박")
            expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "charset 없는 exact Content-Type")
            // URLProtocol may expose the outgoing body as a stream.
            if let body = request.httpBody {
                expect(try! JSONSerialization.jsonObject(with: body) as! [String: String] == ["code": code], "exact 코드 body")
            }
            return (response(origin.enrollURL), try JSONEncoder().encode(["token": token]))
        }
        let exchange: VisionControlEnrollment.Exchange = { request in
            try await VisionControlEnrollment.exchange(request, configuration: stubConfiguration())
        }
        let request = try VisionControlEnrollment.request(origin: origin, code: code)
        expect(request.httpBody?.count == 35 && request.value(forHTTPHeaderField: "Authorization") == nil, "등록 body 크기와 자격 분리")
        let uppercase = try VisionControlEnrollment.request(origin: origin, code: code.uppercased())
        expect(uppercase.httpBody == request.httpBody, "대문자 16진수 코드도 서버의 소문자 계약으로 제출")
        let credential = try await VisionControlEnrollment.register(origin: origin, code: code, exchange: exchange)
        expect(calls.value == 1 && credential.token == token && credential.origin == origin, "등록 POST 한 번")
        let authenticated = try credential.gateway().request()
        expect(authenticated.url == origin.eventsURL && authenticated.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)", "등록 origin에만 이벤트 자격 공급")
        var wrong = try credential.gateway()
        wrong = ControlEventsGateway(eventsURL: URL(string: "https://other.invalid/v1/events")!, credentialHeader: "Authorization", authenticatedRequest: wrong.authenticatedRequest)
        rejects("다른 origin 자격 결박 거절") { _ = try wrong.request() }
        rejects("공백 코드 거절") { _ = try VisionControlEnrollment.request(origin: origin, code: " " + code) }
        for status in [400, 403, 413, 429, 307] {
            calls.value = 0
            StubURLProtocol.handler = { _ in calls.value += 1; return (response(origin.enrollURL, status), Data("{}".utf8)) }
            do { _ = try await VisionControlEnrollment.register(origin: origin, code: code, exchange: exchange); expect(false, "등록 오류 거절") }
            catch { expect(calls.value == 1, "등록 오류 자동 POST 재시도 없음") }
        }
        for data in [Data("{\"token\":\"bad\"}".utf8), Data(repeating: 65, count: 4097)] {
            StubURLProtocol.handler = { _ in (response(origin.enrollURL), data) }
            do { _ = try await VisionControlEnrollment.register(origin: origin, code: code, exchange: exchange); expect(false, "잘못된 등록 응답") }
            catch { expect(true, "응답 상한과 토큰 형식") }
        }
        calls.value = 0
        do {
            _ = try await VisionControlEnrollment.register(origin: origin, code: code, exchange: { _ in calls.value += 1; throw URLError(.timedOut) })
            expect(false, "timeout 미확인")
        } catch { expect(error as? VisionControlEnrollmentFailure == .unknown && calls.value == 1, "timeout 결과 미확인 및 중복 없음") }
        let memory = Box<VisionControlCredential?>(nil)
        let events = ControlEventsController(stream: { _ in fatalError("실제 네트워크 사용 금지") })
        let registration = VisionControlEnrollmentController(events: events,
            store: VisionControlCredentialStore(load: { memory.value }, save: { memory.value = $0 }),
            exchange: { request in (try JSONEncoder().encode(["token": token]), response(request.url!)) })
        registration.restore()
        expect(!events.configured, "등록 정보 없으면 미설정")
        await registration.submit(origin: origin.url.absoluteString, code: code)
        expect(memory.value == credential && events.configured, "등록·저장·구독 설정 생산 연결")
        let restored = VisionControlEnrollmentController(events: events,
            store: VisionControlCredentialStore(load: { memory.value }, save: { _ in fatalError() }),
            exchange: { _ in fatalError("복원 중 등록 POST 금지") })
        restored.restore()
        expect(restored.registeredOrigin == origin.url.absoluteString, "자기 저장소 기존 자격 재사용")
        let renewalCalls = Box(0)
        let renewal = VisionControlEnrollmentController(events: events,
            store: VisionControlCredentialStore(load: { memory.value }, save: { memory.value = $0 }),
            exchange: { request in
                renewalCalls.value += 1
                return (try JSONEncoder().encode(["token": String(repeating: "c", count: 64)]), response(request.url!))
            })
        renewal.restore()
        let renewed = await renewal.submit(origin: origin.url.absoluteString, code: code)
        expect(renewed && renewalCalls.value == 1 && memory.value?.token == String(repeating: "c", count: 64), "기존 등록도 삭제 없이 한 번 갱신")
        let failing = VisionControlEnrollmentController(events: events,
            store: VisionControlCredentialStore(load: { memory.value }, save: { _ in throw VisionControlEnrollmentFailure.storage }),
            exchange: { request in (Data("{\"token\":\"\(token)\"}".utf8), response(request.url!)) })
        failing.restore()
        let failed = await failing.submit(origin: origin.url.absoluteString, code: code)
        expect(!failed && memory.value?.token == String(repeating: "c", count: 64) && events.configured, "등록 갱신 저장 실패는 기존 자격과 연결 보존")
        let restoreEvents = ControlEventsController(stream: { _ in fatalError("실제 네트워크 사용 금지") })
        let loads = Box(0)
        let recoverable = VisionControlEnrollmentController(events: restoreEvents,
            store: VisionControlCredentialStore(load: {
                loads.value += 1
                if loads.value == 1 { throw VisionControlEnrollmentFailure.storage }
                return memory.value
            }, save: { _ in fatalError("복원 중 저장 금지") }),
            exchange: { _ in fatalError("복원 중 등록 POST 금지") })
        recoverable.restore()
        expect(!restoreEvents.configured, "잠긴 보안 저장소는 연결을 시작하지 않음")
        recoverable.restore()
        expect(restoreEvents.configured && loads.value == 2, "다음 표시에서 보안 저장소 복원 재시도")
        recoverable.restore()
        expect(loads.value == 3, "다음 표시에서 다른 창의 자격 갱신 확인")
        memory.value = credential
        let secondStreams = Streams()
        let secondEvents = ControlEventsController(stream: secondStreams.open)
        let secondWindow = VisionControlEnrollmentController(events: secondEvents,
            store: VisionControlCredentialStore(load: { memory.value }, save: { _ in fatalError("복원 중 저장 금지") }),
            exchange: { _ in fatalError("다른 창 복원 중 등록 POST 금지") })
        secondWindow.restore()
        secondEvents.setVisible(true); secondEvents.setForeground(true)
        await eventually("다른 창 기존 자격 연결") { secondStreams.opened == 1 }
        secondStreams.continuations[0].finish(throwing: ControlEventsTransportFailure.authentication)
        await eventually("회전 이전 자격 인증 거부") { secondEvents.reducer.subscription == nil }
        let changed = await renewal.submit(origin: origin.url.absoluteString, code: code)
        expect(changed && secondWindow.restore(), "다른 창의 갱신 자격 수용")
        await eventually("새 자격으로 구독 복원") { secondStreams.opened == 2 }
        expect(secondStreams.authorizations == ["Bearer \(token)", "Bearer \(String(repeating: "c", count: 64))"],
               "다른 창은 기존 토큰 대신 갱신 토큰 사용")
        expect(!secondWindow.restore() && secondStreams.opened == 2, "같은 자격 재조회는 구독을 초기화하지 않음")
        secondEvents.release()
        let redirect = ControlEventsRedirectGuard()
        let session = URLSession(configuration: stubConfiguration())
        let task = session.dataTask(with: origin.eventsURL)
        var allowed = true
        redirect.urlSession(session, task: task, willPerformHTTPRedirection: response(origin.eventsURL, 302),
            newRequest: URLRequest(url: URL(string: "https://other.invalid")!)) { allowed = $0 != nil }
        expect(!allowed, "공유 HTTPS redirect 거절")
        session.invalidateAndCancel()
    }

    @MainActor static func lifecycleChecks(first: ControlEventsEnvelope) async throws {
        let streams = Streams()
        let sleepGate = Box<CheckedContinuation<Void, Error>?>(nil)
        let controller = ControlEventsController(stream: streams.open, sleep: { _ in
            try await withCheckedThrowingContinuation { sleepGate.value = $0 }
        })
        controller.configure(try gateway()); controller.setForeground(true)
        expect(streams.opened == 0, "숨겨진 패널은 구독 없음")
        controller.setVisible(true)
        await eventually("창 전경 구독 시작") { streams.opened == 1 }
        streams.continuations[0].yield(.opened(Date())); streams.continuations[0].yield(.envelope(first))
        await eventually("생산 controller 최초 상태") { controller.reducer.isCurrent }
        let oldID = controller.reducer.subscription
        controller.setForeground(false)
        expect(!controller.reducer.isCurrent && controller.reducer.document != nil, "배경 연결 중지와 마지막 관측 보존")
        controller.setForeground(true)
        await eventually("전경 구독 복원") { streams.opened == 2 }
        streams.continuations[0].yield(.envelope(first)); streams.continuations[0].finish(throwing: ControlEventsTransportFailure.authentication)
        streams.continuations[1].yield(.opened(Date())); streams.continuations[1].yield(.envelope(first))
        await eventually("이전 구독의 늦은 콜백 차단") { controller.reducer.isCurrent && controller.reducer.subscription != oldID }
        streams.continuations[1].finish(throwing: ControlEventsTransportFailure.streamEnded)
        await eventually("생산 backoff 진입") { sleepGate.value != nil }
        expect(!controller.reducer.isCurrent, "backoff 동안 stale")
        controller.setVisible(false)
        sleepGate.value?.resume(); sleepGate.value = nil
        try await Task.sleep(nanoseconds: 5_000_000)
        expect(streams.opened == 2, "취소된 backoff는 새 구독을 만들지 않음")
        let retryStreams = Streams()
        let delays = Box([UInt64]())
        let retrying = ControlEventsController(stream: retryStreams.open, sleep: { delays.value.append($0) })
        retrying.configure(try gateway()); retrying.setVisible(true); retrying.setForeground(true)
        await eventually("재접속 시험 최초 연결") { retryStreams.opened == 1 }
        retryStreams.continuations[0].finish(throwing: ControlEventsTransportFailure.streamEnded)
        await eventually("EOF 이후 제한 재접속") { retryStreams.opened == 2 }
        retryStreams.continuations[1].finish(throwing: ControlEventsTransportFailure.streamEnded)
        await eventually("동일 오류 두 번 종료") { retrying.reducer.subscription == nil }
        expect(delays.value == [1_000_000_000], "동일 조건 반복 루프 없음")
        retrying.release(); controller.release()
    }
}
