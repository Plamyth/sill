import Foundation
import StreamProtocol

var ruleEvents: [String] = []
// Inert API shapes for invoking the production delegate's bodies. SDK compilation remains separate.
protocol ObservableObject {}
protocol WKNavigationDelegate {}
protocol WKUIDelegate {}
final class WKWebsiteDataStore {
    var removals = 0
    static func nonPersistent() -> WKWebsiteDataStore { WKWebsiteDataStore() }
    static func allWebsiteDataTypes() -> Set<String> { ["fixture"] }
    func removeData(ofTypes: Set<String>, modifiedSince: Date, completionHandler: () -> Void) {
        removals += 1
        completionHandler()
    }
}
@propertyWrapper
struct Binding<Value> {
    let get: () -> Value
    let set: (Value) -> Void
    var wrappedValue: Value { get { get() } nonmutating set { set(newValue) } }
    var projectedValue: Binding<Value> { self }
}
final class WKContentRuleList {
    let identifier: String
    init(_ identifier: String) { self.identifier = identifier }
}
final class WKContentRuleListStore {
    static let shared = WKContentRuleListStore()
    static func `default`() -> WKContentRuleListStore { shared }
    var pending: [(id: String, json: String, completion: (WKContentRuleList?, Error?) -> Void)] = []
    var removed: [String] = []
    func compileContentRuleList(forIdentifier identifier: String, encodedContentRuleList: String,
                                completionHandler: @escaping (WKContentRuleList?, Error?) -> Void) {
        pending.append((identifier, encodedContentRuleList, completionHandler))
    }
    func removeContentRuleList(forIdentifier identifier: String, completionHandler: (Error?) -> Void) {
        ruleEvents.append("저장소 제거:\(identifier)")
        removed.append(identifier)
        completionHandler(nil)
    }
    func completeNext(failure: Bool = false, missingList: Bool = false) {
        let next = pending.removeFirst()
        next.completion(failure || missingList ? nil : WKContentRuleList(next.id),
                        failure ? NSError(domain: "격리 규칙 컴파일 실패", code: 1) : nil)
    }
}
final class WKUserContentController {
    var lists: [WKContentRuleList] = []
    func add(_ list: WKContentRuleList) { lists.append(list) }
    func remove(_ list: WKContentRuleList) {
        lists.removeAll { $0 === list }
        ruleEvents.append("컨트롤러 제거:\(list.identifier)")
    }
}
final class WKWebView {
    var url: URL?
    var stops = 0
    let configuration: WKWebViewConfiguration
    var loads: [URLRequest] = []
    var listsAtLoad: [[WKContentRuleList]] = []
    var navigationDelegate: AnyObject?
    var uiDelegate: AnyObject?
    var allowsLinkPreview = true
    var allowsBackForwardNavigationGestures = true
    var accessibilityLabel: String?
    var formValue = "기기 입력 초안"
    init(frame: CGRect = .zero, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.configuration = configuration
    }
    func stopLoading() { stops += 1 }
    func load(_ request: URLRequest) {
        listsAtLoad.append(configuration.userContentController.lists)
        loads.append(request)
        url = request.url
    }
}
final class WKNavigation {}
final class WKFrameInfo {}
struct WKNavigationAction {
    var request: URLRequest
    var targetFrame: WKFrameInfo? = WKFrameInfo()
    var shouldPerformDownload = false
}
struct WKNavigationResponse { var response: URLResponse; var canShowMIMEType = true; var isForMainFrame = true }
enum WKNavigationActionPolicy { case allow, cancel }
enum WKNavigationResponsePolicy { case allow, cancel }
final class WKPreferences { var javaScriptCanOpenWindowsAutomatically = true }
enum WKAudiovisualMediaTypes { case all }
final class WKWebViewConfiguration {
    var websiteDataStore = WKWebsiteDataStore.nonPersistent()
    let userContentController = WKUserContentController()
    let preferences = WKPreferences()
    var mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = .all
}
struct FixtureContext { let coordinator: Coordinator }
final class WKWindowFeatures {}
final class WKContextMenuElementInfo {}
final class UIContextMenuConfiguration {}
final class WKDownload { var cancelled = false; func cancel(_ completion: (Data?) -> Void) { cancelled = true; completion(nil) } }
final class WKSecurityOrigin {}
enum WKMediaCaptureType { case camera }
enum WKPermissionDecision { case grant, deny }
final class FixtureChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

func runWebViewChecks(catalog: TestDestinationCatalog, now: Date) {
    var clock = now
    var model = VisionTestDestinations(clock: { clock })
    let peer = VisionTestDestinations.PeerBinding(peerID: "fixture-peer", generation: UUID())
    var registered = catalog
    registered.entries[0].redirectOrigins = ["https://login.example.test"]
    model.bind(peer)
    model.observe(registered, from: peer)
    model.open(registered.entries[0], from: peer)
    let selection = model.selection!
    let delegate = Coordinator(model: Binding(get: { model }, set: { model = $0 }), selection: selection)
    let view = WKWebView()
    delegate.prepare(view)
    check(view.loads.isEmpty, "규칙 컴파일 전에 페이지를 로드하지 않는다")
    WKContentRuleListStore.shared.completeNext()
    view.url = selection.url
    for (host, port, permitted) in [("example.test", 443, true), ("login.example.test", 443, true),
                                     ("login.example.test", 444, false), ("foreign.example.test", 443, false)] {
        let space = URLProtectionSpace(host: host, port: port, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: FixtureChallengeSender())
        var disposition = URLSession.AuthChallengeDisposition.useCredential
        delegate.webView(view, didReceive: challenge) { disposition = $0; check($1 == nil, "서버 신뢰 처리는 자격 정보를 생성하지 않는다") }
        check(disposition == (permitted ? .performDefaultHandling : .cancelAuthenticationChallenge),
              "등록된 리디렉션을 포함한 정확한 HTTPS 출처에만 기본 TLS 검증을 맡긴다")
    }
    var actionPolicy = WKNavigationActionPolicy.cancel
    let baseAction = WKNavigationAction(request: URLRequest(url: selection.url))
    delegate.webView(view, decidePolicyFor: baseAction) { actionPolicy = $0 }
    check(actionPolicy == .allow, "actual view delegate allows exact base origin")
    var action = baseAction
    action.request = URLRequest(url: URL(string: "https://login.example.test/start")!)
    delegate.webView(view, decidePolicyFor: action) { actionPolicy = $0 }
    check(actionPolicy == .allow, "actual view delegate permits explicitly registered HTTPS redirect")
    action.request = URLRequest(url: URL(string: "https://unregistered.example.test/start")!)
    delegate.webView(view, decidePolicyFor: action) { actionPolicy = $0 }
    check(actionPolicy == .cancel && model.pageStatus == .navigationDenied, "unregistered redirect is cancelled by view delegate")
    action = baseAction
    action.targetFrame = nil
    delegate.webView(view, decidePolicyFor: action) { actionPolicy = $0 }
    check(actionPolicy == .cancel, "new window navigation rejected")
    action = baseAction
    action.shouldPerformDownload = true
    delegate.webView(view, decidePolicyFor: action) { actionPolicy = $0 }
    check(actionPolicy == .cancel, "download navigation rejected")
    var responsePolicy = WKNavigationResponsePolicy.cancel
    for code in [200, 503] {
        delegate.webView(view, didStartProvisionalNavigation: nil)
        check(model.pageStatus == .loading, "provisional navigation only means loading")
        let response = WKNavigationResponse(response: HTTPURLResponse(url: selection.url, statusCode: code,
                                                                     httpVersion: nil, headerFields: nil)!)
        delegate.webView(view, decidePolicyFor: response) { responsePolicy = $0 }
        check(responsePolicy == .allow && model.pageStatus == .responseReceived(code), "HTTP response is distinct from display")
        delegate.webView(view, didCommit: nil)
        check(model.pageStatus == .displaying(code), "commit reports display start with actual HTTP status")
        delegate.webView(view, didFinish: nil)
        check(model.pageStatus == .response(code), "finish retains actual HTTP status without business success claim")
    }
    let attachment = WKNavigationResponse(response: HTTPURLResponse(url: selection.url, statusCode: 200,
        httpVersion: nil, headerFields: ["Content-Disposition": "attachment; filename=fixture"])!)
    delegate.webView(view, decidePolicyFor: attachment) { responsePolicy = $0 }
    check(responsePolicy == .cancel, "attachment response rejected")
    let unshowable = WKNavigationResponse(response: HTTPURLResponse(url: selection.url, statusCode: 200,
        httpVersion: nil, headerFields: nil)!, canShowMIMEType: false)
    delegate.webView(view, decidePolicyFor: unshowable) { responsePolicy = $0 }
    check(responsePolicy == .cancel, "unsupported response MIME type rejected")
    let space = URLProtectionSpace(host: "example.test", port: 443, protocol: "https", realm: nil,
                                   authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
    let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
        previousFailureCount: 0, failureResponse: nil, error: nil, sender: FixtureChallengeSender())
    var authentication = URLSession.AuthChallengeDisposition.performDefaultHandling
    var copiedCredential: URLCredential?
    delegate.webView(view, didReceive: challenge) { authentication = $0; copiedCredential = $1 }
    check(authentication == .cancelAuthenticationChallenge && copiedCredential == nil && model.pageStatus == .authenticationDenied,
          "view refuses credential challenge without importing authentication")
    view.url = URL(string: "https://unregistered.example.test/redirect")!
    delegate.webView(view, didReceiveServerRedirectForProvisionalNavigation: nil)
    check(view.stops == 1 && model.pageStatus == .navigationDenied, "unregistered redirect stops loading")
    delegate.webView(view, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
    check(model.pageStatus == .failed, "actual load failure is reported separately from host reachability")
    delegate.webViewWebContentProcessDidTerminate(view)
    check(model.pageStatus == .failed, "content process failure cannot report successful display")
    let download = WKDownload()
    delegate.webView(view, navigationAction: baseAction, didBecome: download)
    check(download.cancelled, "delegate cancels download conversion")
    var permission = WKPermissionDecision.grant
    delegate.webView(view, requestMediaCapturePermissionFor: WKSecurityOrigin(), initiatedByFrame: WKFrameInfo(), type: .camera) { permission = $0 }
    check(permission == .deny, "web media capture never starts")
    view.url = selection.url
    clock = now.addingTimeInterval(46)
    delegate.webView(view, decidePolicyFor: baseAction) { actionPolicy = $0 }
    delegate.webView(view, didFinish: nil)
    check(actionPolicy == .cancel && model.selection == nil && model.pageStatus == .notOpened,
          "만료된 페이지는 선택을 해제하고 탐색이나 늦은 성공을 허용하지 않는다")
    registered.entries[0].checkedAt = ISO8601DateFormatter().string(from: clock)
    model.observe(registered, from: peer)
    check(model.selection == nil && model.pageStatus == .notOpened,
          "이미 만료로 해제한 페이지는 새 관측만으로 다시 열리지 않는다")

    let stores = VisionTestDestinationStores()
    let epoch = UUID()
    let project = stores.store(projectID: "project-A", epoch: epoch)
    check(stores.store(projectID: "project-A", epoch: epoch) === project, "project login store reused within paired scope")
    let otherProject = stores.store(projectID: "project-B", epoch: epoch)
    check(otherProject !== project, "projects never share login stores")
    stores.synchronize(epoch)
    check(project.removals == 0 && otherProject.removals == 0, "same paired scope preserves device login")
    stores.synchronize(UUID())
    check(project.removals == 1 && otherProject.removals == 1, "disconnect invalidation purges each previous project store")
    check(stores.store(projectID: "project-A", epoch: UUID()) !== project, "new peer never reuses previous project login store")
    delegate.stop(view)
    runResourceRuleChecks(catalog: catalog, now: now)
    runRuleLifecycleChecks(catalog: catalog, now: now)
}

// WebKit 엔진의 검증과 별개로 실제 생성 JSON의 순서와 정규식 의미를 평가한다.
private func resourceAllowed(_ json: String, _ url: String) throws -> Bool {
    let rules = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
    var blocked = false
    for rule in rules {
        let trigger = rule["trigger"] as! [String: Any]
        let pattern = trigger["url-filter"] as! String
        let sensitive = trigger["url-filter-is-case-sensitive"] as? Bool ?? false
        let regex = try NSRegularExpression(pattern: pattern, options: sensitive ? [] : [.caseInsensitive])
        if regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil {
            let action = (rule["action"] as! [String: Any])["type"] as! String
            if action == "block" { blocked = true }
            else if action == "ignore-previous-rules" { blocked = false }
            else { throw NSError(domain: "미지원 규칙 동작", code: 1) }
        }
    }
    return !blocked
}

private func runResourceRuleChecks(catalog: TestDestinationCatalog, now: Date) {
    let peer = VisionTestDestinations.PeerBinding(peerID: "격리 규칙", generation: UUID())
    for base in ["https://example.test/screen", "https://example.test:443/screen", "https://example.test:8443/screen"] {
        var model = VisionTestDestinations(clock: { now })
        var registered = catalog
        registered.entries[0].url = base
        registered.entries[0].redirectOrigins = ["https://login.example.test", "https://assets.example.test:9443"]
        model.bind(peer)
        model.observe(registered, from: peer)
        model.open(registered.entries[0], from: peer)
        let selection = model.selection!
        let json = model.resourceRuleListJSON(for: selection)!
        let rules = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        check(rules.count == 4 && (rules[0]["action"] as? [String: String])?["type"] == "block" &&
              (rules[0]["trigger"] as? [String: Any])?["url-filter"] as? String == ".*",
              "실제 JSON은 모든 요청 차단 뒤 정확한 출처 세 개만 허용한다")
        for rule in rules.dropFirst() {
            let pattern = (rule["trigger"] as! [String: Any])["url-filter"] as! String
            check(pattern.hasPrefix("^https://") && pattern.hasSuffix("$") &&
                  (try? NSRegularExpression(pattern: pattern)) != nil,
                  "허용 규칙은 HTTPS 시작과 출처 경계 및 끝이 고정된 유효 정규식이다")
        }
        for resource in ["https://login.example.test", "https://LOGIN.example.test:443/auth.js",
                         "https://assets.example.test:9443/script.js", base, base + "?asset=1"] {
            check((try? resourceAllowed(json, resource)) == true, "등록된 정확 출처 리소스 허용: \(resource)")
        }
        let defaultPort = !base.contains(":8443")
        for resource in ["https://example.test", "https://EXAMPLE.test:443/script.js"] {
            check((try? resourceAllowed(json, resource)) == defaultPort, "443 포트 생략과 명시는 같은 기본 출처다")
        }
        check((try? resourceAllowed(json, "https://example.test:8443/script.js")) == !defaultPort,
              "명시한 비기본 포트만 허용하고 기본 출처로 확장하지 않는다")
        for resource in ["https://exampleXtest/script.js", "https://example.test.evil.test/script.js",
                         "https://sub.example.test/script.js", "https://example.test:4430/script.js",
                         "https://example.test:84430/script.js", "https://example.test@evil.test/script.js",
                         "https://example.test.evil.test/?https://example.test/", "https://third.example.test/script.js",
                         "https://login.example.test.evil.test/auth.js", "https://assets.example.test/script.js",
                         "https://assets.example.test:94430/script.js", "http://example.test/script.js",
                         "wss://example.test/socket", "file:///script.js", "data:text/javascript,fixture"] {
            check((try? resourceAllowed(json, resource)) == false, "접두사 우회와 제삼자 스크립트 차단: \(resource)")
        }
        model.bind(nil)
        check(model.resourceRuleListJSON(for: selection) == nil, "연결 해제 후 새 허용 규칙을 만들지 않는다")
    }
}

private func runRuleLifecycleChecks(catalog: TestDestinationCatalog, now: Date) {
    let compiler = WKContentRuleListStore.shared
    func scene(clock: @escaping () -> Date) -> (Binding<VisionTestDestinations>, VisionWebViewFixture, Coordinator, WKWebView) {
        var model = VisionTestDestinations(clock: clock)
        let peer = VisionTestDestinations.PeerBinding(peerID: "격리 생명주기", generation: UUID())
        model.bind(peer)
        model.observe(catalog, from: peer)
        model.open(catalog.entries[0], from: peer)
        let binding = Binding(get: { model }, set: { model = $0 })
        let page = VisionWebViewFixture(model: binding, selection: model.selection!, store: .nonPersistent())
        let delegate = page.makeCoordinator()
        let view = page.makeUIView(context: FixtureContext(coordinator: delegate))
        return (binding, page, delegate, view)
    }
    var clock = now
    let (binding, page, delegate, view) = scene(clock: { clock })
    let selection = binding.wrappedValue.selection!
    let ownID = compiler.pending.last!.id
    let unrelated = WKContentRuleList("다른 담당 규칙")
    view.configuration.userContentController.add(unrelated)
    check(view.loads.isEmpty && compiler.pending.count == 1, "실제 makeUIView 본문은 컴파일을 시작하고 첫 로드를 대기한다")
    var policy = WKNavigationActionPolicy.allow
    delegate.webView(view, decidePolicyFor: WKNavigationAction(request: URLRequest(url: selection.url))) { policy = $0 }
    check(policy == .cancel, "규칙 설치 전 탐색 콜백도 허용하지 않는다")
    compiler.completeNext()
    check(view.loads.count == 1 && view.listsAtLoad[0].contains { $0.identifier == ownID },
          "규칙 설치 후에만 첫 페이지 요청이 발생한다")
    binding.wrappedValue.report(.displaying(200), for: selection)
    clock = now.addingTimeInterval(40)
    var renewed = catalog
    renewed.entries[0].checkedAt = ISO8601DateFormatter().string(from: clock)
    renewed.entries[0].embed = .unknown
    binding.wrappedValue.observe(renewed, from: selection.binding)
    clock = now.addingTimeInterval(70)
    page.updateUIView(view, context: FixtureContext(coordinator: delegate))
    check(binding.wrappedValue.selection?.id == selection.id && binding.wrappedValue.pageStatus == .displaying(200) &&
          view.loads.count == 1 && view.stops == 0 && view.formValue == "기기 입력 초안" &&
          view.configuration.websiteDataStore === page.store && compiler.pending.isEmpty,
          "확인 시각 갱신은 같은 WebView와 폼 및 로그인 저장소를 보존하며 재로드하거나 재컴파일하지 않는다")
    let response = WKNavigationResponse(response: HTTPURLResponse(url: selection.url, statusCode: 200,
                                                                 httpVersion: nil, headerFields: nil)!)
    delegate.webView(view, decidePolicyFor: response) { _ in }
    delegate.webView(view, didCommit: nil)
    check(binding.wrappedValue.pageStatus == .displaying(200), "기존 페이지 콜백은 갱신된 현재 카탈로그를 사용한다")
    for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodDefault,
                   NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                   NSURLAuthenticationMethodHTMLForm, NSURLAuthenticationMethodNTLM,
                   NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodClientCertificate] {
        for (host, port, scheme) in [("example.test", 443, "https"), ("foreign.example.test", 443, "https"),
                                     ("example.test.evil.test", 443, "https"), ("example.test", 444, "https"),
                                     ("example.test", 443, "http")] {
            let space = URLProtectionSpace(host: host, port: port, protocol: scheme, realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: FixtureChallengeSender())
            var disposition = URLSession.AuthChallengeDisposition.useCredential
            var credential: URLCredential?
            delegate.webView(view, didReceive: challenge) { disposition = $0; credential = $1 }
            let trustedOrigin = host == "example.test" && port == 443 && scheme == "https"
            let expected: URLSession.AuthChallengeDisposition = trustedOrigin && method == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .cancelAuthenticationChallenge
            check(disposition == expected && credential == nil, "모든 인증 방식은 현재 선택과 정확한 HTTPS 출처 확인 후 기본 TLS 처리만 허용한다")
        }
    }
    clock = now.addingTimeInterval(86)
    let trust = URLAuthenticationChallenge(protectionSpace: URLProtectionSpace(host: "example.test", port: 443,
        protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust), proposedCredential: nil,
        previousFailureCount: 0, failureResponse: nil, error: nil, sender: FixtureChallengeSender())
    var disposition = URLSession.AuthChallengeDisposition.performDefaultHandling
    delegate.webView(view, didReceive: trust) { disposition = $0; check($1 == nil, "만료된 신뢰 요청에 자격 정보를 넘기지 않는다") }
    check(disposition == .cancelAuthenticationChallenge && binding.wrappedValue.selection == nil,
          "현재 카탈로그가 만료되면 서버 신뢰 요청을 취소하고 선택을 해제한다")
    VisionWebViewFixture.dismantleUIView(view, coordinator: delegate)
    check(view.configuration.userContentController.lists.count == 1 && view.configuration.userContentController.lists[0] === unrelated &&
          Array(ruleEvents.suffix(2)) == ["컨트롤러 제거:\(ownID)", "저장소 제거:\(ownID)"],
          "자기 규칙만 컨트롤러에서 제거한 뒤 자기 저장 식별자를 정리한다")
    delegate.webView(view, didReceive: trust) { disposition = $0 }
    check(disposition == .cancelAuthenticationChallenge, "해체된 페이지는 신뢰 요청을 승인하지 않는다")

    let (failedBinding, _, failedDelegate, failedView) = scene(clock: { now })
    let failedID = compiler.pending.last!.id
    compiler.completeNext(failure: true)
    check(failedView.loads.isEmpty && failedView.configuration.userContentController.lists.isEmpty &&
          failedBinding.wrappedValue.pageStatus == .resourceFilterFailed && compiler.removed.contains(failedID),
          "컴파일 실패는 한국어 오류 상태를 남기고 페이지 요청 없이 자기 식별자를 정리한다")
    failedDelegate.prepare(failedView)
    check(compiler.pending.isEmpty && failedView.loads.isEmpty, "실패한 페이지가 규칙 없이 재시도하지 않는다")

    let (missingBinding, _, missingDelegate, missingView) = scene(clock: { now })
    compiler.completeNext(missingList: true)
    check(missingView.loads.isEmpty && missingBinding.wrappedValue.pageStatus == .resourceFilterFailed,
          "오류 값이 없어도 컴파일 결과 규칙이 없으면 페이지를 열지 않는다")
    missingDelegate.stop(missingView)

    var compilingTime = now
    let (renewBinding, _, renewDelegate, renewView) = scene(clock: { compilingTime })
    let renewSelection = renewBinding.wrappedValue.selection!
    compilingTime = now.addingTimeInterval(40)
    var compilingRenewal = catalog
    compilingRenewal.entries[0].checkedAt = ISO8601DateFormatter().string(from: compilingTime)
    renewBinding.wrappedValue.observe(compilingRenewal, from: renewSelection.binding)
    compilingTime = now.addingTimeInterval(70)
    compiler.completeNext()
    check(renewView.loads.count == 1 && renewBinding.wrappedValue.selection?.id == renewSelection.id,
          "컴파일 중 갱신된 최신 관측은 처음 선택 시각이 만료된 뒤에도 같은 선택을 허용한다")
    renewDelegate.stop(renewView)

    for revoke in ["만료", "연결 해제", "권한 변경", "재선택", "해체"] {
        var time = now
        let (nextBinding, nextPage, nextDelegate, nextView) = scene(clock: { time })
        let nextSelection = nextBinding.wrappedValue.selection!
        let identifier = compiler.pending.last!.id
        switch revoke {
        case "만료": time = now.addingTimeInterval(46)
        case "연결 해제": nextBinding.wrappedValue.bind(nil)
        case "권한 변경":
            var changed = catalog
            changed.entries[0].owner = "새 담당"
            nextBinding.wrappedValue.observe(changed, from: nextSelection.binding)
        case "재선택": nextBinding.wrappedValue.open(catalog.entries[0], from: nextSelection.binding)
        default: VisionWebViewFixture.dismantleUIView(nextView, coordinator: nextDelegate)
        }
        nextPage.updateUIView(nextView, context: FixtureContext(coordinator: nextDelegate))
        compiler.completeNext()
        check(nextView.loads.isEmpty && nextView.configuration.userContentController.lists.isEmpty && compiler.removed.contains(identifier),
              "컴파일 중 \(revoke) 뒤 늦게 완료되어도 페이지를 열거나 규칙을 설치하지 않는다")
    }
    check(Set(compiler.removed).count == compiler.removed.count, "각 페이지의 규칙 식별자는 고유하며 정리는 중복되지 않는다")
    check(compiler.pending.isEmpty, "격리 컴파일 콜백이 남지 않는다")
}
