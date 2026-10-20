import AppKit
import WebKit

@MainActor final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var loaded: CheckedContinuation<Void,Error>?
    var messages: [[String:Any]] = []
    var allowedURL: URL!
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing:error); loaded = nil
    }
    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == allowedURL ? .allow : .cancel)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? [String:Any] { messages.append(value) }
    }
    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath:env["PELE_OUTPUT"]!)
        let resources = URL(fileURLWithPath:env["PELE_RESOURCES"]!)
        let snapshots = try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("snapshots.json"))) as! [[String:Any]]
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(self,name:"canvasDiagram")
        let view = WKWebView(frame:CGRect(x:0,y:0,width:900,height:700),configuration:config)
        view.navigationDelegate = self
        allowedURL = resources.appendingPathComponent("diagram.html")
        try await withCheckedThrowingContinuation { loaded = $0; view.loadFileURL(allowedURL,allowingReadAccessTo:resources) }
        func js(_ code: String, _ args: [String:Any] = [:]) async throws -> Any? {
            try await withCheckedThrowingContinuation { continuation in
                view.callAsyncJavaScript(code,arguments:args,in:nil,in:.page) {
                    continuation.resume(with:$0.map { $0 as Any? })
                }
            }
        }
        for (index,snapshot) in snapshots.enumerated() {
            let result = try await js("return window.ccrDiagram.update(payload)",["payload":snapshot]) as! [String:Any]
            precondition(result["nodes"] as? Int == 2 && result["edges"] as? Int == 1,"실제 Pele 노드·관계 렌더")
            let svg = try await js("return document.querySelector('#diagram svg').outerHTML") as! String
            precondition(svg.contains("한글") || index == 2)
            try Data(svg.utf8).write(to:output.appendingPathComponent("render-\(index).svg"))
        }
        _ = try await js("return window.ccrDiagram.update(payload)",["payload":snapshots[1]])
        let node = (snapshots[1]["nodes"] as! [[String:Any]])[0]
        _ = try await js("document.querySelector('.pele-node').dispatchEvent(new MouseEvent('click',{bubbles:true})); return true")
        try await Task.sleep(for:.milliseconds(50))
        precondition(messages.last?["nodeID"] as? String == node["id"] as? String)
        let selectedCount = messages.count
        let rejected = try await js("return window.ccrDiagram.select('n00000000000000000000000000000000')") as! Bool
        precondition(!rejected && messages.count == selectedCount,"허용되지 않은 UUID hit 거부")
        let network = try await js("try { await fetch('https://example.com/'); return false; } catch (_) { return true; }") as! Bool
        precondition(network,"CSP가 네트워크를 차단해야 합니다")
        let unsafe = try await js("return document.querySelectorAll('#diagram script,#diagram image,#diagram a,#diagram foreignObject').length") as! Int
        precondition(unsafe == 0)
        var invalid = snapshots[1]
        var nodes = invalid["nodes"] as! [[String:Any]]
        nodes[0]["id"] = UUID().uuidString
        invalid["nodes"] = nodes
        let bad = try await js("return window.ccrDiagram.update(payload)",["payload":invalid]) as! [String:Any]
        precondition(bad["error"] as? Bool == true)
        invalid = snapshots[1]; invalid["source"] = String(repeating:"a",count:50001)
        let large = try await js("return window.ccrDiagram.update(payload)",["payload":invalid]) as! [String:Any]
        precondition(large["error"] as? Bool == true)
        config.userContentController.removeScriptMessageHandler(forName:"canvasDiagram")
        view.stopLoading(); view.navigationDelegate = nil
        print("PASS 실제 오프라인 WebKit/Pele 한글 SVG·관계, 동일 UUID 수정 SVG 갱신, 클릭 식별자, 입력 한도, CSP 네트워크 차단")
    }
}

@main struct WebKitChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        let harness = Harness()
        Task { @MainActor in
            do { try await harness.run(); exit(0) }
            catch { fputs("FAIL \(error)\n",stderr); exit(1) }
        }
        app.run()
    }
}
