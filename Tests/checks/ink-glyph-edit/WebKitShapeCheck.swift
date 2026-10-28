import Foundation
import AppKit
import WebKit

@MainActor final class Page: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var ready: CheckedContinuation<Void, Error>?
    var messages: [[String:Any]] = []
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready?.resume(); ready = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { ready?.resume(throwing:error); ready = nil }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String:Any] { messages.append(body) }
    }
}
@main struct WebKitShapeCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath:CommandLine.arguments[1])
        let output = URL(fileURLWithPath:CommandLine.arguments[2])
        let payload = try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("projection-snapshot.json"))) as! [String:Any]
        let controller = Page()
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(controller,name:"canvasDiagram")
        let view = WKWebView(frame:NSRect(x:0,y:0,width:900,height:900),configuration:config)
        view.navigationDelegate = controller
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            controller.ready = continuation
            view.loadFileURL(directory.appendingPathComponent("diagram.html"),allowingReadAccessTo:directory)
        }
        let script = """
        const result = window.ccrDiagram.update(payload);
        if (result.error) throw Error('bridge render failure');
        const root = document.querySelector('#diagram svg');
        const ellipse = root.querySelector('.ccrEllipse rect');
        const box = ellipse.getBBox(), x = box.x, y = box.y;
        const endpoints = [...root.querySelectorAll('.ccrLineEndpoint rect')];
        const edge = root.querySelector('.pele-edge path');
        const lineNode = payload.nodes.find(n => n.kind === 'line');
        const group = root.querySelector('.pele-edge');
        group.dispatchEvent(new MouseEvent('click',{bubbles:true}));
        const endpointSelected = window.ccrDiagram.select('x' + lineNode.diagramID.slice(1));
        const measured = {result,rx:getComputedStyle(ellipse).rx,ry:getComputedStyle(ellipse).ry,
          ellipseCenter:ellipse.isPointInFill(new DOMPoint(x+box.width/2,y+box.height/2)),
          ellipseCorner:ellipse.isPointInFill(new DOMPoint(x+1,y+1)),
          ellipseSize:[box.width,box.height], endpointCount:endpoints.length,
          endpointsHidden:endpoints.every(e => getComputedStyle(e).fill === 'none' && getComputedStyle(e).stroke === 'none'),
          lineLength:edge.getTotalLength(),linePath:edge.getAttribute('d'),
          lineHasArrow:!!root.querySelector('marker'),endpointSelected,
          expectedLineID:lineNode.id,
          actualSVG:root.outerHTML};
        measured.countMismatchRejected = window.ccrDiagram.update({...payload,displayedNodeCount:payload.displayedNodeCount+1}).error === true;
        measured.edgeMismatchRejected = window.ccrDiagram.update({...payload,displayedEdgeCount:payload.displayedEdgeCount+1}).error === true;
        measured.restored = !window.ccrDiagram.update(payload).error;
        return measured;
        """
        let value: [String:Any] = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(script,arguments:["payload":payload],in:nil,in:.page) { result in
                continuation.resume(with:result.map { $0 as! [String:Any] })
            }
        }
        precondition(value["ellipseCenter"] as? Bool == true && value["ellipseCorner"] as? Bool == false,"WebKit ellipse fill geometry")
        precondition(value["endpointsHidden"] as? Bool == true && value["endpointCount"] as? Int == 2,"line transparent endpoint geometry")
        precondition((value["lineLength"] as? Double ?? 0) > 10 && value["lineHasArrow"] as? Bool == false,"actual primitive path without arrow")
        precondition(value["countMismatchRejected"] as? Bool == true && value["edgeMismatchRejected"] as? Bool == true && value["restored"] as? Bool == true,"actual parsed/SVG count mismatch rejected and restored")
        precondition(value["endpointSelected"] as? Bool == true,"synthetic endpoint maps to original UUID")
        try await Task.sleep(nanoseconds:100_000_000)
        let expected = value["expectedLineID"] as! String
        precondition(controller.messages.filter { $0["nodeID"] as? String == expected }.count == 2,"edge and endpoint select original UUID")
        var result = value
        result["messages"] = controller.messages
        result["scope"] = "실제 macOS WKWebView·번들 bridge/SVG DOM 기하·선 선택. 자동 배치이며 원본 좌표 재현 또는 iPad 터치/시각 수용이 아님. 화면·앱 활성화·네트워크·설치 없음."
        result["passed"] = true
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("webkit-shapes.json"))
        print("WEBKIT_SHAPES_OK center=true corner=false linePath=true selectionUUID=true")
        view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName:"canvasDiagram")
    }
}
