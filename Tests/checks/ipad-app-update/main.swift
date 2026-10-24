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
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "updates.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        precondition(request.httpMethod == "GET")
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct IPadAppUpdateChecks {
    static var count = 0
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let key = Curve25519.Signing.PrivateKey()
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

    @MainActor static func main() async throws {
        let configuration = try IPadAppUpdateConfiguration(feed: "https://updates.example.test/ipad/latest",
                                                        key: key.publicKey.rawRepresentation.base64EncodedString())
        let signed = try envelope()
        func authenticate(_ data: Data) throws -> IPadAppUpdateRelease {
            try IPadAppUpdatePolicy.authenticate(data, configuration: configuration, now: now)
        }
        let release = try authenticate(signed)
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
        refuses(.signature) { _ = try authenticate(envelope(signer: Curve25519.Signing.PrivateKey())) }
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

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FeedFixture.self]
        FeedFixture.data = signed
        let response = try await IPadAppUpdateFeed.fetch(configuration, sessionConfiguration: sessionConfiguration)
        check(response == signed, "실제 URLSession 피드 fetch")
        for status in [301, 302, 307, 308, 401, 403, 500] {
            FeedFixture.status = status
            do { _ = try await IPadAppUpdateFeed.fetch(configuration, sessionConfiguration: sessionConfiguration); preconditionFailure("HTTP 거부 실패") }
            catch let error as IPadAppUpdateError { check(error == .network, "리다이렉트·HTTP 실패 거부") }
        }
        FeedFixture.status = 200
        FeedFixture.data = Data(repeating: 65, count: 32769)
        do { _ = try await IPadAppUpdateFeed.fetch(configuration, sessionConfiguration: sessionConfiguration); preconditionFailure("크기 거부 실패") }
        catch let error as IPadAppUpdateError { check(error == .malformed, "스트림 크기 상한") }
        var redirected: URLRequest??
        let fence = IPadAppUpdateFeed.Fence()
        let temporarySession = URLSession(configuration: .ephemeral)
        let dummyTask = temporarySession.dataTask(with: configuration.feedURL)
        fence.urlSession(temporarySession, task: dummyTask,
                         willPerformHTTPRedirection: HTTPURLResponse(url: configuration.feedURL, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                         newRequest: URLRequest(url: URL(string: "http://example.test")!)) { redirected = $0 }
        check(redirected != nil && redirected! == nil, "실제 production delegate가 redirect를 취소")
        temporarySession.invalidateAndCancel()

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
        pendingJSON["envelope"] = try envelope(signer: Curve25519.Signing.PrivateKey()).base64EncodedString()
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
