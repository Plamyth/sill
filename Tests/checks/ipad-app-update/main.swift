import Foundation
import CryptoKit

@MainActor
private final class PendingStore {
    var data: Data?
    var writes = 0
    var acceptsWrites = true
    func save(_ data: Data) { writes += 1; if acceptsWrites { self.data = data } }
}

@MainActor
private final class FetchQueue {
    var requests: [CheckedContinuation<Data, Error>] = []
    func next() async throws -> Data { try await withCheckedThrowingContinuation { requests.append($0) } }
}

@MainActor
private final class OpenQueue {
    var requests: [CheckedContinuation<Bool, Never>] = []
    func next() async -> Bool { await withCheckedContinuation { requests.append($0) } }
}

private final class FeedFixture: URLProtocol {
    static var status = 200
    static var data = Data()
    static var requests = 0
    static var lastRequest: URLRequest?
    static var responseURL: URL?
    static var contentLength: Int?
    static var failure: URLError.Code?
    static var stalls = false
    static var bodyStalls = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.lastRequest = request
        precondition(request.httpMethod == "GET")
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        if Self.stalls { return }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        var headers = ["Content-Type": "application/json"]
        if let length = Self.contentLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: Self.responseURL ?? request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.bodyStalls { return }
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { preconditionFailure("자격증명 사용 금지") }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

@main
struct IPadAppUpdateChecks {
    static var count = 0
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func fixtureKey(_ hex: String) -> Curve25519.Signing.PrivateKey {
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes))
    }
    static let key = fixtureKey("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    static let otherKey = fixtureKey("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
    static let commit = String(repeating: "a", count: 40)
    static let tree = String(repeating: "b", count: 40)

    static func check(_ result: @autoclosure () throws -> Bool, _ message: String) rethrows {
        let accepted = try result()
        precondition(accepted, message)
        count += 1
    }

    static func refuses(_ expected: IPadAppUpdateError, _ work: () throws -> Void) {
        do { try work(); preconditionFailure("거부되지 않음: \(expected)") }
        catch let error as IPadAppUpdateError { check(error == expected, "예상 오류 \(expected), 실제 \(error)") }
        catch { preconditionFailure("예상 밖 오류 \(error)") }
    }

    static func fields() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return ["schemaVersion": 1, "releaseID": "ccr-ipad-fixture-62", "platform": "ipadOS",
                "bundleID": IPadAppUpdatePolicy.bundleID, "teamID": IPadAppUpdatePolicy.teamID,
                "version": "0.5.2", "build": "62", "sourceCommit": commit, "sourceTree": tree,
                "approvedAt": formatter.string(from: now.addingTimeInterval(-60)),
                "expiresAt": formatter.string(from: now.addingTimeInterval(3600)),
                "channel": "appStore", "appleAppID": "1234567890",
                "installURL": "https://apps.apple.com/app/id1234567890"]
    }

    static func envelope(_ fields: [String: Any] = fields(), signer: Curve25519.Signing.PrivateKey = key) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(),
                                                           "signature": signer.signature(for: payload).base64EncodedString()])
    }

    static func installed(build: String = "61", version: String = "0.5.1",
                          commit: String = String(repeating: "c", count: 40),
                          tree: String = String(repeating: "d", count: 40)) -> IPadAppUpdateInstalled {
        .init(bundleID: IPadAppUpdatePolicy.bundleID, version: version, build: build, sourceCommit: commit, sourceTree: tree)
    }

    @MainActor static func settle(_ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("비동기 검사 상태에 도달하지 못함")
    }

    static let syntheticAuthorization = "Bearer " + String(repeating: "a1", count: 32)

    static func authenticatedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(syntheticAuthorization, forHTTPHeaderField: "Authorization")
        return request
    }

    @MainActor static func feedChecks(configuration: IPadAppUpdateConfiguration, signed: Data) async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [FeedFixture.self]
        settings.timeoutIntervalForRequest = 86400
        settings.timeoutIntervalForResource = 86400
        settings.httpAdditionalHeaders = ["Authorization": syntheticAuthorization, "Cookie": "fixture=1",
                                          "X-Canvas-Token": "synthetic-canvas", "X-Unrelated": "synthetic-global"]
        settings.urlCache = URLCache(memoryCapacity: 1024, diskCapacity: 0)
        settings.urlCredentialStorage = .shared
        settings.httpCookieStorage = .shared
        settings.httpShouldSetCookies = true
        let isolated = IPadAppUpdateFeed.isolatedConfiguration(settings)
        check(isolated !== settings && isolated.timeoutIntervalForRequest == 15 && isolated.timeoutIntervalForResource == 30,
              "실제 production session 구성은 복사본에 15초·30초 고정")
        check(isolated.httpAdditionalHeaders == nil && isolated.urlCache == nil && isolated.httpCookieStorage == nil &&
              isolated.urlCredentialStorage == nil && !isolated.httpShouldSetCookies, "실제 session 구성의 전역 인증·쿠키·캐시·자격증명 제거")
        check(settings.timeoutIntervalForResource == 86400 && settings.httpAdditionalHeaders?.count == 4,
              "호출자가 빌려준 SSE session 구성은 변경하지 않음")
        let request = authenticatedRequest(configuration.feedURL)
        FeedFixture.data = signed
        let response = try await IPadAppUpdateFeed.fetch(configuration, authenticatedRequest: request, sessionConfiguration: settings)
        check(response == signed, "명시 인증 production fetch는 원문 바이트 반환")
        try check(try IPadAppUpdatePolicy.authenticate(response, configuration: configuration, now: now).build == "62",
                  "production fetch 성공 원문을 production 서명 검증으로 수용")
        let sent = FeedFixture.lastRequest!
        check(sent.url == configuration.feedURL && sent.httpMethod == "GET" && sent.timeoutInterval == 15 &&
              !sent.httpShouldHandleCookies && sent.httpBody == nil && sent.httpBodyStream == nil, "새 GET request의 URL·15초·무본문·쿠키 차단")
        check(sent.value(forHTTPHeaderField: "Authorization") == syntheticAuthorization &&
              sent.value(forHTTPHeaderField: "X-Canvas-Token") == nil && sent.value(forHTTPHeaderField: "X-Unrelated") == nil &&
              sent.value(forHTTPHeaderField: "Accept") == "application/json", "검증한 Authorization 하나만 새 요청에 전달")
        let legacy = try await IPadAppUpdateFeed.fetch(configuration, sessionConfiguration: settings)
        check(legacy == signed && FeedFixture.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil,
              "기존 fetch 원형·익명 동작 보존, 전역 인증 헤더는 전용하지 않음")
        settings.httpAdditionalHeaders = ["Authorization": 7]
        _ = try await IPadAppUpdateFeed.fetch(configuration, authenticatedRequest: request, sessionConfiguration: settings)
        check(FeedFixture.lastRequest?.value(forHTTPHeaderField: "Authorization") == syntheticAuthorization,
              "잘못된 type의 session 전역 인증은 명시 인증과 혼합하지 않음")

        var requestCase = 0
        func refuseRequest(_ candidate: URLRequest?, config: IPadAppUpdateConfiguration? = nil) async throws {
            requestCase += 1
            let before = FeedFixture.requests
            do {
                _ = try await IPadAppUpdateFeed.fetch(config ?? configuration, authenticatedRequest: candidate, sessionConfiguration: settings)
                preconditionFailure("잘못된 인증 요청 수용: fixture 번호 \(requestCase)")
            } catch let error as IPadAppUpdateError {
                check(error == .authentication && FeedFixture.requests == before, "인증·scope 위반은 network 0")
            }
        }
        try await refuseRequest(nil)
        var invalid = request
        invalid.setValue(nil, forHTTPHeaderField: "Authorization")
        try await refuseRequest(invalid)
        for value in ["Basic fixture", "bearer " + String(repeating: "a", count: 64), "Bearer ", "Bearer    ",
                      "Bearer " + String(repeating: "A", count: 64), "Bearer " + String(repeating: "a", count: 63),
                      "Bearer " + String(repeating: "a", count: 65), "Bearer " + String(repeating: "g", count: 64),
                      syntheticAuthorization + " ", syntheticAuthorization + "\n", "Bearer \r\n" + String(repeating: "a", count: 64)] {
            invalid = request
            invalid.setValue(nil, forHTTPHeaderField: "Authorization")
            invalid.setValue(value, forHTTPHeaderField: "Authorization")
            try await refuseRequest(invalid)
        }
        invalid = request; invalid.addValue(syntheticAuthorization, forHTTPHeaderField: "aUtHoRiZaTiOn")
        try await refuseRequest(invalid)
        invalid = request
        invalid.allHTTPHeaderFields = ["Authorization": syntheticAuthorization, "authorization": syntheticAuthorization]
        check(invalid.allHTTPHeaderFields?.count == 1, "Foundation은 dictionary 대소문자 중복을 API 진입 전 하나로 축약하므로 원래 중복은 관측 불가")
        invalid = request; invalid.httpMethod = "get"
        check(invalid.httpMethod == "GET", "Foundation이 표준 method를 정규화한 뒤 공통 경계에서는 정확 GET 확인")
        for method in ["POST", "PATCH", "HEAD"] {
            invalid = request; invalid.httpMethod = method
            try await refuseRequest(invalid)
        }
        invalid = request; invalid.httpBody = Data()
        try await refuseRequest(invalid)
        invalid = request; invalid.httpBodyStream = InputStream(data: Data("synthetic".utf8))
        try await refuseRequest(invalid)
        invalid = request; invalid.httpShouldHandleCookies = true
        try await refuseRequest(invalid)
        invalid = request; invalid.setValue("", forHTTPHeaderField: "cOoKiE")
        try await refuseRequest(invalid)
        for url in ["https://other.example.test/v1/releases/latest?platform=ipadOS",
                    "https://updates.example.test:17649/v1/releases/latest?platform=ipadOS",
                    "http://updates.example.test/v1/releases/latest?platform=ipadOS"] {
            invalid = authenticatedRequest(URL(string: url)!)
            try await refuseRequest(invalid)
        }
        for suffix in ["/ipad/latest", "/v1/releases/latest", "/v1/releases/latest/", "/v1/releases/%6catest?platform=ipadOS",
                       "/v1/releases/latest?platform=%69padOS", "/v1/releases/latest?platform=visionOS",
                       "/v1/releases/latest?platform=ipadOS&platform=ipadOS", "/v1/releases/latest?platform=ipadOS&token=synthetic",
                       "/v1/releases/latest?token=synthetic&platform=ipadOS", "/v1/releases/latest?Platform=ipadOS",
                       "/v1/releases/latest?platform=ipadOS&", "/v1/releases/latest?platform=ipadOS%20"] {
            let config = try IPadAppUpdateConfiguration(feed: "https://updates.example.test" + suffix,
                                                       key: key.publicKey.rawRepresentation.base64EncodedString())
            try await refuseRequest(authenticatedRequest(config.feedURL), config: config)
        }
        invalid = request; invalid.setValue("synthetic-input", forHTTPHeaderField: "X-Canvas-Token")
        _ = try await IPadAppUpdateFeed.fetch(configuration, authenticatedRequest: invalid, sessionConfiguration: settings)
        check(FeedFixture.lastRequest?.value(forHTTPHeaderField: "X-Canvas-Token") == nil, "명시 request의 관계없는 인증 헤더도 전파하지 않음")

        let notConfigured: [String: Any] = ["schemaVersion": 1, "status": "notConfigured", "code": "release_not_configured", "platform": IPadAppUpdatePolicy.platform]
        let unconfiguredData = try JSONSerialization.data(withJSONObject: notConfigured)
        func refuseResponse(_ status: Int, _ data: Data, expected: IPadAppUpdateError) async throws {
            FeedFixture.status = status; FeedFixture.data = data
            do {
                _ = try await IPadAppUpdateFeed.fetch(configuration, authenticatedRequest: request, sessionConfiguration: settings)
                preconditionFailure("잘못된 HTTP 응답 수용")
            } catch let error as IPadAppUpdateError { check(error == expected, "production fetch HTTP 상태·본문 분류") }
        }
        try await refuseResponse(503, unconfiguredData, expected: .unconfigured)
        for (field, value) in [("schemaVersion", 0 as Any), ("schemaVersion", -1), ("schemaVersion", 2), ("schemaVersion", true),
                               ("schemaVersion", "1"), ("schemaVersion", NSNull()), ("platform", "visionOS"),
                               ("platform", "ipados"), ("status", "notconfigured"), ("code", "release_Not_Configured")] {
            var body = notConfigured; body[field] = value
            try await refuseResponse(503, JSONSerialization.data(withJSONObject: body), expected: .network)
        }
        for field in notConfigured.keys {
            var body = notConfigured; body[field] = nil
            try await refuseResponse(503, JSONSerialization.data(withJSONObject: body), expected: .network)
            body = notConfigured; body[field.uppercased()] = body.removeValue(forKey: field)
            try await refuseResponse(503, JSONSerialization.data(withJSONObject: body), expected: .network)
        }
        var extra = notConfigured; extra["extra"] = "ignored-is-not-allowed"
        try await refuseResponse(503, JSONSerialization.data(withJSONObject: extra), expected: .network)
        for body in [signed, Data("[]".utf8), Data("not JSON".utf8)] {
            try await refuseResponse(503, body, expected: .network)
        }
        for schema in ["1.0", "1e0", "-1", "true", "null"] {
            let body = Data(("{\"schemaVersion\":" + schema + ",\"status\":\"notConfigured\",\"code\":\"release_not_configured\",\"platform\":\"ipadOS\"}").utf8)
            try await refuseResponse(503, body, expected: .network)
        }
        for status in [301, 302, 307, 308, 400, 404, 429, 500, 502, 504] {
            try await refuseResponse(status, unconfiguredData, expected: .network)
        }
        for status in [401, 403] { try await refuseResponse(status, unconfiguredData, expected: .authentication) }
        for status in [401, 403] {
            FeedFixture.contentLength = 32769
            FeedFixture.bodyStalls = true
            try await refuseResponse(status, Data(), expected: .authentication)
            FeedFixture.bodyStalls = false
            try await refuseResponse(status, Data(repeating: 65, count: 32769), expected: .authentication)
        }
        FeedFixture.contentLength = nil
        for status in [200, 503] {
            try await refuseResponse(status, Data(repeating: 65, count: 32769), expected: .malformed)
        }
        FeedFixture.contentLength = 32769
        try await refuseResponse(200, Data(), expected: .network)
        FeedFixture.contentLength = nil
        FeedFixture.status = 200; FeedFixture.data = Data(repeating: 65, count: 32768)
        let maximum = try await IPadAppUpdateFeed.fetch(configuration, authenticatedRequest: request, sessionConfiguration: settings)
        check(maximum.count == 32768, "정확 32768바이트까지 읽고 서명 단계에 반환")
        FeedFixture.responseURL = URL(string: "https://other.example.test/v1/releases/latest?platform=ipadOS")
        try await refuseResponse(200, signed, expected: .network)
        FeedFixture.responseURL = configuration.feedURL.appendingPathComponent("different")
        try await refuseResponse(200, signed, expected: .network)
        FeedFixture.responseURL = nil

        FeedFixture.status = 200; FeedFixture.data = signed; FeedFixture.failure = .timedOut
        do { _ = try await IPadAppUpdateFeed.fetch(configuration, authenticatedRequest: request, sessionConfiguration: settings); preconditionFailure("timeout 누락") }
        catch let error as URLError { check(error.code == .timedOut, "실제 fetch가 timeout 전달") }
        FeedFixture.failure = nil; FeedFixture.stalls = true
        let beforeCancel = FeedFixture.requests
        let cancelled = Task { try await IPadAppUpdateFeed.fetch(configuration, authenticatedRequest: request, sessionConfiguration: settings) }
        await settle { FeedFixture.requests > beforeCancel }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("fetch 취소 누락") }
        catch { check(error is CancellationError || (error as? URLError)?.code == .cancelled, "실제 네트워크 대기 취소") }
        FeedFixture.stalls = false

        var redirected: URLRequest??
        let fence = IPadAppUpdateFeed.Fence()
        let temporarySession = URLSession(configuration: isolated)
        let dummyTask = temporarySession.dataTask(with: request)
        fence.urlSession(temporarySession, task: dummyTask,
                         willPerformHTTPRedirection: HTTPURLResponse(url: configuration.feedURL, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                         newRequest: authenticatedRequest(URL(string: "https://other.example.test/")!)) { redirected = $0 }
        check(redirected != nil && redirected! == nil, "production redirect callback은 인증 요청을 다음 origin에 전달하지 않음")
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault,
                       NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodServerTrust] {
            let protection = URLProtectionSpace(host: "updates.example.test", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: protection,
                                                       proposedCredential: URLCredential(user: "synthetic", password: "synthetic", persistence: .none),
                                                       previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
            var called = false
            fence.urlSession(temporarySession, task: dummyTask, didReceive: challenge) { disposition, credential in
                called = true
                check(credential == nil && disposition == (method == NSURLAuthenticationMethodServerTrust
                      ? .performDefaultHandling : .cancelAuthenticationChallenge), "production challenge callback은 TLS trust 외 인증과 credential 전달 차단")
            }
            check(called, "인증 callback 완료")
        }
        temporarySession.invalidateAndCancel()

        let store = PendingStore()
        var opens = 0
        let defaultController = IPadAppUpdateController(configuration: configuration, readInstalled: { installed() },
                                                         loadPending: { store.data }, savePending: { store.save($0) })
        let beforeDefault = FeedFixture.requests
        defaultController.checkAndInstall { _ in opens += 1; return true }
        await settle { defaultController.canCheck }
        check(defaultController.state == .failed(.authentication) && FeedFixture.requests == beforeDefault && opens == 0 && store.writes == 0,
              "iPad 기본 controller는 credential 미연결로 authentication, network·저장·설치 전달 0")
        let controller = IPadAppUpdateController(configuration: configuration, readInstalled: { installed() },
                                                loadPending: { store.data }, savePending: { store.save($0) },
                                                fetch: { try await IPadAppUpdateFeed.fetch($0, authenticatedRequest: request, sessionConfiguration: settings) },
                                                now: { now })
        FeedFixture.status = 503; FeedFixture.data = unconfiguredData
        controller.checkAndInstall { _ in opens += 1; return true }
        await settle { controller.canCheck }
        check(controller.state == .unconfigured && controller.message.contains("준비중") && controller.message.contains("다시 시도") &&
              controller.canCheck && opens == 0 && store.writes == 0, "정확 503은 준비중·재시도, 성공·저장·설치 전달 없음")
        FeedFixture.status = 200
        controller.checkAndInstall { _ in opens += 1; return true }
        await settle { controller.canCheck }
        check(controller.state == .failed(.malformed) && opens == 0 && store.writes == 0, "200 unsigned notConfigured는 계속 서명 봉투 실패")
        for status in [401, 403, 503, 500] {
            FeedFixture.status = status; FeedFixture.data = Data("{}".utf8)
            controller.checkAndInstall { _ in opens += 1; return true }
            await settle { controller.canCheck }
            check(controller.state == .failed(status == 401 || status == 403 ? .authentication : .network) && opens == 0 && store.writes == 0,
                  "거짓 503·다른 HTTP·인증 오류는 최신이나 설치 상태로 승격하지 않음")
        }
        FeedFixture.status = 200; FeedFixture.data = signed
        FeedFixture.failure = .timedOut
        controller.checkAndInstall { _ in opens += 1; return true }
        await settle { controller.canCheck }
        check(controller.state == .failed(.network) && opens == 0 && store.writes == 0, "controller timeout은 재시도 가능한 네트워크 실패")
        FeedFixture.failure = nil
        controller.checkAndInstall { _ in opens += 1; return true }
        await settle { controller.canCheck }
        try check(controller.state == .handoffPending(try IPadAppUpdatePolicy.authenticate(signed, configuration: configuration, now: now)) &&
              opens == 1 && store.writes == 2, "실제 production fetch와 controller의 정상 서명 200 전달 경로")
    }

    @MainActor static func main() async throws {
        let configuration = try IPadAppUpdateConfiguration(feed: "https://updates.example.test/v1/releases/latest?platform=ipadOS",
                                                        key: key.publicKey.rawRepresentation.base64EncodedString())
        let signed = try envelope()
        func authenticate(_ data: Data) throws -> IPadAppUpdateRelease {
            try IPadAppUpdatePolicy.authenticate(data, configuration: configuration, now: now)
        }
        let release = try authenticate(signed)
        var diagnostic = try JSONSerialization.jsonObject(with: signed) as! [String: Any]
        diagnostic["keyID"] = "untrusted-diagnostic-only"
        try check(try authenticate(JSONSerialization.data(withJSONObject: diagnostic)) == release, "상위 keyID는 진단 필드로만 무시하고 고정 공개키 서명 사용")
        let raw = try JSONSerialization.data(withJSONObject: fields(), options: [.prettyPrinted, .sortedKeys])
        let rawEnvelope = try JSONSerialization.data(withJSONObject: ["payload": raw.base64EncodedString(), "signature": key.signature(for: raw).base64EncodedString(), "keyID": "untrusted"])
        try check(try authenticate(rawEnvelope) == release, "재직렬화하지 않은 원문 공백·줄바꿈 payload의 서명 확인")
        var nodeFields = fields()
        nodeFields["approvedAt"] = "2027-01-15T07:59:00.000Z"
        nodeFields["expiresAt"] = "2027-01-15T09:00:00.000Z"
        let nodeRelease = try authenticate(envelope(nodeFields))
        check(IPadAppUpdatePolicy.timestamp(nodeRelease.approvedAt) == IPadAppUpdatePolicy.timestamp(release.approvedAt), "Node 밀리초와 초 표기의 동일 시각")
        var fractionalFields = nodeFields
        fractionalFields["releaseID"] = "fractional-approval"
        fractionalFields["approvedAt"] = "2027-01-15T07:59:00.001Z"
        let fractionalRelease = try authenticate(envelope(fractionalFields))
        try check(try IPadAppUpdatePolicy.validateProgress(fractionalRelease, installed: installed(), previous: release), "시각은 문자열 대신 Date로 비교")
        refuses(.rollback) { _ = try IPadAppUpdatePolicy.validateProgress(release, installed: installed(), previous: fractionalRelease) }
        check(IPadAppUpdatePolicy.timestamp("2027-02-30T08:00:00.000Z") == nil, "존재하지 않는 날짜 거부")
        check(release.build == "62", "실제 CryptoKit Ed25519 서명 검증")
        try check(try IPadAppUpdatePolicy.installURL(release).absoluteString == fields()["installURL"] as! String, "App Store ID 결합")
        check(SillLinks.appStore == nil, "CCR에서 upstream App Store fallback 제거")
        check(IPadAppUpdateConfiguration.bundled() == nil, "미설정 Bundle 구성")
        refuses(.signature) { _ = try authenticate(envelope(signer: otherKey)) }
        var outer = try JSONSerialization.jsonObject(with: signed) as! [String: Any]
        outer["payload"] = Data("{}".utf8).base64EncodedString()
        refuses(.signature) { _ = try authenticate(JSONSerialization.data(withJSONObject: outer)) }
        outer = try JSONSerialization.jsonObject(with: signed) as! [String: Any]
        outer["payload"] = try JSONSerialization.data(withJSONObject: fields(), options: [.prettyPrinted]).base64EncodedString()
        refuses(.signature) { _ = try authenticate(JSONSerialization.data(withJSONObject: outer)) }
        for data in [Data("{}".utf8), Data("[]".utf8), Data(repeating: 32, count: 32769)] {
            refuses(.malformed) { _ = try authenticate(data) }
        }
        let cases: [(String, Any, IPadAppUpdateError)] = [
            ("schemaVersion", 2, .malformed), ("releaseID", "", .malformed),
            ("platform", "iOS", .identity), ("bundleID", "dev.sill.ipad", .identity),
            ("teamID", "OTHERTEAM", .identity), ("sourceCommit", String(repeating: "A", count: 40), .malformed),
            ("sourceTree", "abc", .malformed), ("build", "-1", .malformed), ("build", "062", .malformed),
            ("build", 62, .malformed), ("build", "0", .malformed), ("build", "1.2", .malformed),
            ("version", "1..2", .malformed), ("version", "1.2.3.4", .malformed),
            ("version", "1.02", .malformed), ("version", "1.2-beta", .malformed),
            ("appleAppID", "6816359860", .malformed), ("appleAppID", "0", .malformed),
            ("approvedAt", "2027-01-15T09:00:00Z", .expired), ("expiresAt", "2020-01-01T00:00:00Z", .expired),
            ("expiresAt", "not-a-date", .expired), ("channel", "development", .unsupportedChannel),
            ("channel", "testflight", .unsafeURL)
        ]
        for (field, value, error) in cases {
            var candidate = fields(); candidate[field] = value
            refuses(error) { _ = try authenticate(envelope(candidate)) }
        }
        for field in fields().keys {
            var candidate = fields(); candidate[field] = nil
            refuses(.malformed) { _ = try authenticate(envelope(candidate)) }
        }
        let unsafe = ["http://apps.apple.com/app/id1234567890", "https://apps.apple.com.evil.test/app/id1234567890",
                      "https://apps.apple.com@evil.test/app/id1234567890", "https://user:pass@apps.apple.com/app/id1234567890",
                      "https://apps.apple.com:443/app/id1234567890", "https://apps.apple.com/app/id9999999999",
                      "https://apps.apple.com/app/id6816359860", "https://apps.apple.com/app/id1234567890?next=evil",
                      "https://apps.apple.com/app/id1234567890#x", "https://apps.apple.com/app/id1234567890/",
                      "https://apps.apple.com/app/%69d1234567890", "https://testflight.apple.com/join/fixture",
                      "itms-services://?action=download-manifest", "https://example.test/app.ipa"]
        for url in unsafe {
            var candidate = fields(); candidate["installURL"] = url
            refuses(.unsafeURL) { _ = try authenticate(envelope(candidate)) }
        }
        for url in ["http://updates.example.test/feed", "https://user@updates.example.test/feed",
                    "https://updates.example.test/feed#x", "https://updates.example.test:0/feed",
                    "https://updates.example.test:65536/feed",
                    "https://updates.example.test/space here", "https://updates.example.test\\@evil.test/feed"] {
            refuses(.unconfigured) { _ = try IPadAppUpdateConfiguration(feed: url, key: key.publicKey.rawRepresentation.base64EncodedString()) }
        }
        refuses(.unconfigured) { _ = try IPadAppUpdateConfiguration(feed: configuration.feedURL.absoluteString, key: "bad-key") }
        for port in [443, 17649, 65535] {
            let customPort = try IPadAppUpdateConfiguration(feed: "https://updates.example.test:\(port)/feed",
                                                           key: key.publicKey.rawRepresentation.base64EncodedString())
            check(customPort.feedURL.port == port, "피드 유효 HTTPS 포트")
        }
        try check(try IPadAppUpdatePolicy.validateProgress(release, installed: installed(), previous: nil), "정상 새 버전")
        refuses(.rollback) { _ = try IPadAppUpdatePolicy.validateProgress(release, installed: installed(build: "63", version: "0.5.2"), previous: nil) }
        refuses(.rollback) { _ = try IPadAppUpdatePolicy.validateProgress(release, installed: installed(version: "0.6.0"), previous: nil) }
        let exact = installed(build: "62", version: "0.5.2", commit: commit, tree: tree)
        try check(try !IPadAppUpdatePolicy.validateProgress(release, installed: exact, previous: nil), "정확한 최신 소스")
        refuses(.sourceMismatch) { _ = try IPadAppUpdatePolicy.validateProgress(release, installed: installed(build: "62", version: "0.5.2"), previous: nil) }
        var laterFields = fields()
        laterFields["releaseID"] = "new-release"; laterFields["build"] = "63"
        laterFields["approvedAt"] = "2027-01-15T07:59:30Z"
        let later = try authenticate(envelope(laterFields))
        refuses(.rollback) { _ = try IPadAppUpdatePolicy.validateProgress(release, installed: installed(), previous: later) }
        var changedFields = fields(); changedFields["sourceTree"] = String(repeating: "e", count: 40)
        let changed = try authenticate(envelope(changedFields))
        refuses(.rollback) { _ = try IPadAppUpdatePolicy.validateProgress(changed, installed: installed(), previous: release) }
        var renewedFields = fields()
        renewedFields["releaseID"] = "ccr-fixture-renewed"
        renewedFields["approvedAt"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(7199))
        renewedFields["expiresAt"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(10800))
        let renewedData = try envelope(renewedFields)
        let renewedRelease = try IPadAppUpdatePolicy.authenticate(renewedData, configuration: configuration, now: now.addingTimeInterval(7200))
        try check(try IPadAppUpdatePolicy.validateProgress(renewedRelease, installed: installed(), previous: release), "같은 아티팩트의 새 releaseID 재승인")
        var mutatedRenewal = renewedFields; mutatedRenewal["releaseID"] = release.releaseID
        let reusedID = try IPadAppUpdatePolicy.authenticate(envelope(mutatedRenewal), configuration: configuration, now: now.addingTimeInterval(7200))
        refuses(.rollback) { _ = try IPadAppUpdatePolicy.validateProgress(reusedID, installed: installed(), previous: release) }
        mutatedRenewal = renewedFields; mutatedRenewal["sourceTree"] = String(repeating: "e", count: 40)
        let changedArtifact = try IPadAppUpdatePolicy.authenticate(envelope(mutatedRenewal), configuration: configuration, now: now.addingTimeInterval(7200))
        refuses(.rollback) { _ = try IPadAppUpdatePolicy.validateProgress(changedArtifact, installed: installed(), previous: release) }
        var testFlightFields = fields()
        testFlightFields["channel"] = "testflight"
        testFlightFields["installURL"] = "https://testflight.apple.com/join/Ab12Cd34"
        let testFlight = try authenticate(envelope(testFlightFields))
        try check(try IPadAppUpdatePolicy.installURL(testFlight).absoluteString == testFlight.installURL, "서명된 TestFlight 초대 원문만 허용")
        for url in ["http://testflight.apple.com/join/Ab12Cd34", "https://testflight.apple.com/join/Ab12Cd34?appID=1234567890",
                    "https://testflight.apple.com/join/Ab12Cd34#x", "https://testflight.apple.com:443/join/Ab12Cd34",
                    "https://user@testflight.apple.com/join/Ab12Cd34", "https://testflight.apple.com.evil.test/join/Ab12Cd34",
                    "https://testflight.apple.com/join/%41b12Cd34", "https://testflight.apple.com/join/Ab12Cd34/",
                    "https://testflight.apple.com/join/short", "https://testflight.apple.com/join/Ab12Cd3-",
                    "https://testflight.apple.com/v1/app/1234567890", "https://testflight.apple.com/"] {
            var invalidInvite = testFlightFields; invalidInvite["installURL"] = url
            refuses(.unsafeURL) { _ = try authenticate(envelope(invalidInvite)) }
        }
        for build in ["1", "61"] {
            var upgradedFields = fields()
            upgradedFields["version"] = "0.6"; upgradedFields["build"] = build
            upgradedFields["releaseID"] = "ccr-upgrade-\(build)"
            let upgrade = try authenticate(envelope(upgradedFields))
            try check(try IPadAppUpdatePolicy.validateProgress(upgrade, installed: installed(), previous: release),
                      "버전 상향은 빌드 초기화 허용")
            refuses(.rollback) { _ = try IPadAppUpdatePolicy.validateProgress(release, installed: installed(), previous: upgrade) }
        }

        try await feedChecks(configuration: configuration, signed: signed)

        let store = PendingStore()
        var fetches = 0
        var opens = 0
        let firstProcess = UUID()
        var running = installed()
        func controller(process: UUID = firstProcess, config: IPadAppUpdateConfiguration? = configuration,
                        fetch: ((IPadAppUpdateConfiguration) async throws -> Data)? = nil) -> IPadAppUpdateController {
            IPadAppUpdateController(configuration: config, readInstalled: { running }, loadPending: { store.data },
                                    savePending: { store.save($0) }, fetch: fetch ?? { _ in fetches += 1; return signed },
                                    now: { now }, processID: process)
        }
        let unconfigured = controller(config: nil)
        unconfigured.checkAndInstall { _ in opens += 1; return true }
        check(unconfigured.state == .unconfigured && fetches == 0 && opens == 0 && store.writes == 0, "미설정 외부 작동 0")
        let model = controller()
        model.checkAndInstall { url in
            opens += 1
            check(store.data != nil, "Apple 전달 전에 pending 저장")
            check(url.absoluteString == release.installURL, "검증된 exact URL만 전달")
            return true
        }
        model.checkAndInstall { _ in preconditionFailure("중복 전달") }
        await settle { model.canCheck }
        check(model.state == .handoffPending(release) && fetches == 1 && opens == 1, "한 번 버튼으로 조회와 전달, 설치 미확인")
        model.readback()
        check(model.state == .handoffPending(release), "같은 프로세스 복귀는 설치 성공 아님")
        running = exact
        let sameProcess = controller()
        check(sameProcess.state == .handoffPending(release), "동일 프로세스에서 Bundle 일치여도 설치 성공 아님")
        let relaunched = controller(process: UUID())
        check(relaunched.state == .verifiedInstalled(release), "다음 앱 프로세스 exact version/build/source 확인")
        for badRunning in [installed(build: "62", version: "0.5.2", commit: "", tree: tree),
                           installed(build: "62", version: "0.5.2", commit: commit, tree: String(repeating: "f", count: 40))] {
            running = badRunning
            check(controller(process: UUID()).state == .failed(.sourceMismatch), "재실행 소스 불일치 거부")
        }
        running = exact
        let latest = controller(process: UUID())
        latest.checkAndInstall { _ in preconditionFailure("최신 앱은 열지 않음") }
        await settle { latest.canCheck }
        check(latest.state == .upToDate(release), "최신 버전 표시")
        running = installed()
        let failedOpen = controller()
        failedOpen.checkAndInstall { _ in opens += 1; return false }
        await settle { failedOpen.canCheck }
        check(failedOpen.state == .failed(.openFailed), "openURL 실패")
        failedOpen.readback()
        check(failedOpen.state == .failed(.openFailed), "다시 활성화해도 open 실패 보존")
        check(controller(process: UUID()).state == .failed(.openFailed), "새 프로세스에도 open 실패 보존")
        let beforeRetry = fetches
        failedOpen.checkAndInstall { _ in opens += 1; return true }
        await settle { failedOpen.canCheck }
        check(fetches == beforeRetry + 1 && failedOpen.state == .handoffPending(release), "재시도는 캐시 권한 대신 재조회")
        let queue = FetchQueue()
        let cancelled = controller(fetch: { _ in try await queue.next() })
        cancelled.checkAndInstall { _ in preconditionFailure("취소 뒤 열림") }
        await settle { queue.requests.count == 1 }
        cancelled.cancel()
        queue.requests.removeFirst().resume(returning: signed)
        for _ in 0..<100 { await Task.yield() }
        check(cancelled.state == .failed(.cancelled), "늦게 도착한 취소 요청 결과 무시")
        let stale = IPadAppUpdateController(configuration: configuration, readInstalled: { installed() }, loadPending: { store.data },
                                           savePending: { store.save($0) }, now: { now.addingTimeInterval(7200) }, processID: UUID())
        check(stale.state == .failed(.expired), "pending 재실행 시 서명과 만료 재검증")
        let opensBeforeReadback = opens
        stale.readback()
        check(opens == opensBeforeReadback && stale.state == .failed(.expired), "만료 미설치는 재실행·활성화에 open 0")
        let installedAfterExpiry = IPadAppUpdateController(configuration: configuration, readInstalled: { exact }, loadPending: { store.data },
                                                          savePending: { store.save($0) }, now: { now.addingTimeInterval(7200) }, processID: UUID())
        check(installedAfterExpiry.state == .verifiedInstalled(release), "만료 뒤에도 정확한 새 앱의 설치 사실 readback")
        let beforeRenewal = store.data
        let renewController = IPadAppUpdateController(configuration: configuration, readInstalled: { installed() }, loadPending: { store.data },
                                                     savePending: { store.save($0) }, fetch: { _ in renewedData },
                                                     now: { now.addingTimeInterval(7200) }, processID: UUID())
        renewController.checkAndInstall { _ in true }
        await settle { renewController.canCheck }
        check(renewController.state == .handoffPending(renewedRelease), "만료 pending 뒤 실제 controller 재승인")
        store.data = beforeRenewal
        let oldPending = store.data
        var pendingJSON = try JSONSerialization.jsonObject(with: oldPending!) as! [String: Any]
        pendingJSON["envelope"] = try envelope(signer: otherKey).base64EncodedString()
        store.data = try JSONSerialization.data(withJSONObject: pendingJSON)
        check(controller(process: UUID()).state == .failed(.signature), "pending 변조 서명 거부")
        store.data = oldPending
        store.acceptsWrites = false
        let storageFailure = controller(process: UUID())
        storageFailure.checkAndInstall { _ in preconditionFailure("저장 실패 뒤 열림") }
        await settle { storageFailure.canCheck }
        check(storageFailure.state == .failed(.storage), "pending 저장 readback 실패")
        store.acceptsWrites = true
        let badFeed = controller(fetch: { _ in try envelope(changedFields) })
        badFeed.checkAndInstall { _ in preconditionFailure("replay 뒤 열림") }
        await settle { badFeed.canCheck }
        check(badFeed.state == .failed(.rollback), "실제 controller replay 거부")

        let openQueue = OpenQueue()
        let awaitingOpen = controller()
        awaitingOpen.checkAndInstall { _ in await openQueue.next() }
        await settle { openQueue.requests.count == 1 }
        check(awaitingOpen.state == .available(release), "open 완료 전에는 전달 성공 표시 안 함")
        check(controller(process: UUID()).state == .failed(.handoffUnknown), "열기 도중 종료된 요청은 결과 미확인")
        awaitingOpen.cancel()
        check(controller(process: UUID()).state == .failed(.cancelled), "열기 대기 중 닫기 취소 영구 보존")
        openQueue.requests.removeFirst().resume(returning: true)
        for _ in 0..<100 { await Task.yield() }
        check(awaitingOpen.state == .failed(.cancelled), "취소 뒤 늦은 open 성공 응답 권한 없음")
        let authorityQueue = OpenQueue()
        let authority = controller()
        authority.checkAndInstall { _ in await authorityQueue.next() }
        await settle { authorityQueue.requests.count == 1 }
        var foreign = try JSONSerialization.jsonObject(with: store.data!) as! [String: Any]
        foreign["requestID"] = UUID().uuidString
        store.data = try JSONSerialization.data(withJSONObject: foreign)
        authorityQueue.requests.removeFirst().resume(returning: true)
        await settle { authority.canCheck }
        check(authority.state == .failed(.storage), "open await 뒤 pending 소유 요청이 바뀌면 수용 차단")
        store.data = oldPending

        var testFlightUpgrade = testFlightFields
        testFlightUpgrade["build"] = "63"
        testFlightUpgrade["releaseID"] = "testflight-fixture-63"
        let testFlightData = try envelope(testFlightUpgrade)
        let testFlightRelease = try authenticate(testFlightData)
        let flightController = controller(fetch: { _ in testFlightData })
        flightController.checkAndInstall { url in
            check(url.absoluteString == testFlightRelease.installURL, "controller는 서명된 TestFlight 초대를 조립 없이 전달")
            return true
        }
        await settle { flightController.canCheck }
        check(flightController.state == .handoffPending(testFlightRelease), "실제 controller TestFlight 전달만 확인")
        store.data = oldPending

        for build in ["1", "61"] {
            var upgradeFields = fields()
            upgradeFields["version"] = "0.6"; upgradeFields["build"] = build
            upgradeFields["releaseID"] = "new-major-\(build)"
            let upgradeData = try envelope(upgradeFields)
            let upgradeRelease = try authenticate(upgradeData)
            let upgradeController = controller(fetch: { _ in upgradeData })
            upgradeController.checkAndInstall { _ in true }
            await settle { upgradeController.canCheck }
            check(upgradeController.state == .handoffPending(upgradeRelease), "실제 controller 버전 상향과 빌드 초기화")
            store.data = oldPending
        }

        let bundleRoot = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("ReadbackFixture.bundle")
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": IPadAppUpdatePolicy.bundleID, "CFBundleShortVersionString": "0.5.2",
                                   "CFBundleVersion": "62", "CCRSourceCommit": commit, "CCRSourceTree": tree,
                                   "CCRUpdateFeedURL": configuration.feedURL.absoluteString,
                                   "CCRUpdatePublicKey": key.publicKey.rawRepresentation.base64EncodedString()]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundleRoot.appendingPathComponent("Info.plist"))
        let bundle = Bundle(path: bundleRoot.path)!
        check(IPadAppUpdateInstalled.read(bundle).matches(release), "실제 Bundle Info.plist readback")
        check(IPadAppUpdateConfiguration.bundled(bundle)?.feedURL == configuration.feedURL, "실제 번들 구성 주입")
        let unverifiedBundleRoot = bundleRoot.deletingLastPathComponent().appendingPathComponent("UnverifiedReadbackFixture.bundle")
        try FileManager.default.createDirectory(at: unverifiedBundleRoot, withIntermediateDirectories: true)
        var unverifiedInfo = info; unverifiedInfo["CCRSourceIdentityVerified"] = false
        try PropertyListSerialization.data(fromPropertyList: unverifiedInfo, format: .xml, options: 0)
            .write(to: unverifiedBundleRoot.appendingPathComponent("Info.plist"))
        check(!IPadAppUpdateInstalled.read(Bundle(path: unverifiedBundleRoot.path)!).matches(release), "미검증 Debug 출처는 설치 완료 근거로 거부")
        print("PASS \(count)개 실제 업데이트 소스 검사. UI·실기기·설치·호스트·운영 효과 0.")
    }
}
