#if canImport(UIKit)
import SwiftUI
import WebKit

struct CanvasPeleView: UIViewRepresentable {
    let scene: CanvasScene
    let selectedNode: UUID?
    let onSelect: (UUID) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator,name:"canvasDiagram")
        let view = WKWebView(frame:.zero,configuration:configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "canvasPeleDiagram"
        guard let url = Bundle.main.url(forResource:"diagram",withExtension:"html",subdirectory:"Pele") else {
            context.coordinator.report("다이어그램 리소스를 찾지 못했습니다. 원본은 보존됩니다.")
            return view
        }
        context.coordinator.documentURL = url
        view.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent())
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(in:view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName:"canvasDiagram")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: CanvasPeleView
        var documentURL: URL?
        private var ready = false
        private var rendered: CanvasDiagramSnapshot?
        private var selected: UUID?
        private var generation = 0
        private var failedRevision: (UUID,Int)?

        init(_ parent: CanvasPeleView) { self.parent = parent }

        func report(_ message: String) {
            DispatchQueue.main.async { [weak self] in self?.parent.onError(message) }
        }

        func render(in view: WKWebView) {
            guard ready else { return }
            if let failedRevision, failedRevision == (parent.scene.id,parent.scene.revision) { return }
            do {
                let snapshot = try CanvasDiagramSnapshot(scene:parent.scene)
                failedRevision = nil
                guard snapshot != rendered || selected != parent.selectedNode else { return }
                var payload: [String:Any] = ["sceneID":snapshot.sceneID.uuidString,"revision":snapshot.revision,
                    "source":snapshot.source,"nodes":snapshot.nodes.map {
                        ["diagramID":$0.diagramID,"id":$0.id.uuidString,"text":$0.text]
                    }]
                payload["selectedNodeID"] = parent.selectedNode?.uuidString
                rendered = snapshot
                selected = parent.selectedNode
                generation += 1
                let requestedGeneration = generation
                view.callAsyncJavaScript("return window.ccrDiagram.update(payload)",arguments:["payload":payload],
                                         in:nil,in:.page) { [weak self] result in
                    guard let self, self.generation == requestedGeneration else { return }
                    if case .failure = result { self.report("다이어그램 실행에 실패했습니다. 원본은 보존됩니다.") }
                }
            } catch {
                failedRevision = (parent.scene.id,parent.scene.revision)
                rendered = nil
                generation += 1
                view.evaluateJavaScript("document.getElementById('diagram').replaceChildren()",completionHandler:nil)
                report(error.localizedDescription)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            rendered = nil
            render(in:webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && action.request.url == documentURL ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            rendered = nil
            report("다이어그램 실행이 중단됐습니다. 원본 보기로 전환한 뒤 다시 열어 주세요.")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? [String:Any] else { return }
            if value["type"] as? String == "error" {
                report("다이어그램을 표시하지 못했습니다. 원본 그림과 구조 데이터는 보존됩니다.")
                return
            }
            guard value["type"] as? String == "select", let snapshot = rendered,
                  let sceneID = value["sceneID"] as? String, UUID(uuidString:sceneID) == snapshot.sceneID,
                  value["revision"] as? Int == snapshot.revision,
                  let text = value["nodeID"] as? String, let id = UUID(uuidString:text),
                  snapshot.nodes.contains(where:{ $0.id == id }),
                  let current = try? CanvasDiagramSnapshot(scene:parent.scene), current == snapshot else { return }
            parent.onSelect(id)
        }
    }
}
#endif
