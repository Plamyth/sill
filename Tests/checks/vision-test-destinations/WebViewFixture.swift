import Foundation
import StreamProtocol

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
struct Binding<Value> {
    let get: () -> Value
    let set: (Value) -> Void
    var wrappedValue: Value { get { get() } nonmutating set { set(newValue) } }
}
final class WKWebView { var url: URL?; var stops = 0; func stopLoading() { stops += 1 } }
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
final class WKWebViewConfiguration {}
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
    view.url = selection.url
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
    let prior = model.pageStatus
    delegate.webView(view, decidePolicyFor: baseAction) { actionPolicy = $0 }
    delegate.webView(view, didFinish: nil)
    check(actionPolicy == .cancel && model.pageStatus == prior, "expired view cannot navigate or publish late success")

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
}
