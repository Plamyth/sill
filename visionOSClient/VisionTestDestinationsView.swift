import Foundation
import SwiftUI
import StreamProtocol
import WebKit
import UIKit

@MainActor
struct VisionTestDestinationsView: View {
    @Binding var model: VisionTestDestinations
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("프로젝트 테스트 화면").font(.title2)
                Spacer()
                Button("닫기") { model.close(); close() }
            }
            Text(catalogMessage)
            if let catalog = model.catalog {
                Text("Mac 관측 시각: \(catalog.observedAt)").font(.caption)
            }
            if let selected = model.selection, model.isCurrent(selected) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: selected.entry.projectLabel).font(.headline)
                        Text(verbatim: selected.entry.label)
                    }
                    Spacer()
                    Button("목록으로") { model.close() }
                }
                Text(pageMessage).accessibilityLabel(pageMessage)
                VisionTestDestinationWebView(model: $model, selection: selected)
                    .id(selected.id)
                    .accessibilityLabel("선택한 프로젝트 테스트 웹 화면")
            } else if !model.entries.isEmpty {
                List(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: entry.projectLabel).font(.headline)
                        Text(verbatim: entry.label)
                        Text("담당: \(entry.owner)").font(.caption)
                        Text(verbatim: entry.url).font(.caption).textSelection(.enabled)
                        Text(reachabilityMessage(entry)).font(.caption)
                        Text(embedMessage(entry)).font(.caption)
                        Text(entry.checkedAt.map { "Mac 확인 시각: \($0)" } ?? "Mac 확인 시각 미확인")
                            .font(.caption)
                        if let reason = entry.reason, !reason.isEmpty { Text(verbatim: reason).font(.caption) }
                        Button("앱 안에서 열기") {
                            if let binding = model.binding { model.open(entry, from: binding) }
                        }
                        .disabled(model.binding.flatMap { model.openingURL(for: entry, from: $0) } == nil)
                        .accessibilityHint("Mac이 전달한 이 주소만 열고 기기의 실제 응답을 확인합니다.")
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 660, minHeight: 500)
        .onDisappear { model.close() }
    }

    private var catalogMessage: String {
        switch model.catalogStatus {
        case .disconnected: return "Mac 연결이 끊겨 테스트 화면 선택을 지웠습니다."
        case .unavailable: return "연결된 Mac에서 유효한 테스트 화면 목록을 아직 받지 못했습니다."
        case .unsupported: return "지원하지 않는 테스트 화면 목록 버전입니다."
        case .invalid: return "테스트 화면 목록을 검증할 수 없어 열기를 차단했습니다."
        case .empty: return "등록된 테스트 화면이 없습니다."
        case .available: return "Mac의 도달 가능 관측은 이 기기의 접속 확인과 다릅니다. 열기를 누른 뒤 기기 응답을 확인하세요."
        }
    }

    private var pageMessage: String {
        switch model.pageStatus {
        case .notOpened: return "아직 기기에서 접속하지 않았습니다."
        case .loading: return "기기에서 페이지를 여는 중입니다."
        case .responseReceived(let code): return "기기에서 HTTP \(code) 응답을 받았습니다. 페이지 표시를 기다리는 중입니다."
        case .displaying(let code): return "기기에서 HTTP \(code) 페이지를 표시하기 시작했습니다."
        case .response(let code): return "기기에서 HTTP \(code) 페이지 표시를 마쳤습니다. 업무 완료 여부는 화면에서 확인하세요."
        case .failed: return "기기에서 페이지를 열지 못했습니다. Mac의 도달 가능 관측과 별개입니다."
        case .navigationDenied: return "다른 출처 이동·새 창·다운로드는 허용하지 않습니다."
        case .authenticationDenied: return "웹 인증 요청을 차단했습니다. Mac의 인증 정보나 쿠키를 가져오지 않습니다."
        }
    }

    private func reachabilityMessage(_ entry: TestDestinationCatalog.Entry) -> String {
        switch entry.reachability {
        case .reachable: return "Mac 관측: 도달 가능 · 기기 접속은 별도 확인"
        case .unreachable: return "Mac 관측: 도달 불가 · 열 수 없음"
        case .unknown: return "Mac 관측: 도달 여부 미확인 · 열 수 없음"
        }
    }

    private func embedMessage(_ entry: TestDestinationCatalog.Entry) -> String {
        switch entry.embed {
        case .allowed: return "iframe 삽입: 허용 관측"
        case .blocked: return "iframe 삽입: 차단 관측 · 앱 안에서 직접 열기는 별도"
        case .unknown: return "iframe 삽입: 미확인 · 앱 안에서 직접 열기는 별도"
        }
    }
}

@MainActor
private struct VisionTestDestinationWebView: UIViewRepresentable {
    @Binding var model: VisionTestDestinations
    let selection: VisionTestDestinations.Selection

    func makeCoordinator() -> Coordinator { Coordinator(model: $model, selection: selection) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.accessibilityLabel = "프로젝트 테스트 웹 화면"
        if model.isCurrent(selection) { view.load(URLRequest(url: selection.url)) }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.model = $model
        if !model.isCurrent(selection) { view.stopLoading() }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                       modifiedSince: .distantPast) {}
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var model: Binding<VisionTestDestinations>
        let selection: VisionTestDestinations.Selection
        private var responseCode: Int?

        init(model: Binding<VisionTestDestinations>, selection: VisionTestDestinations.Selection) {
            self.model = model
            self.selection = selection
        }

        private func allowed(_ url: URL?) -> Bool {
            url.map { model.wrappedValue.allowsNavigation(to: $0, for: selection) } == true
        }

        private func report(_ status: VisionTestDestinations.PageStatus) {
            model.wrappedValue.report(status, for: selection)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame != nil, !action.shouldPerformDownload, allowed(action.request.url) else {
                report(.navigationDenied)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let http = response.response as? HTTPURLResponse
            let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?
                .trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") == true
            guard allowed(response.response.url), response.canShowMIMEType, !attachment else {
                report(.navigationDenied)
                decisionHandler(.cancel)
                return
            }
            if response.isForMainFrame, let code = http?.statusCode {
                responseCode = code
                report(.responseReceived(code))
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            responseCode = nil
            report(.loading)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if !allowed(webView.url) { webView.stopLoading(); report(.navigationDenied) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard allowed(webView.url), let responseCode else { report(.failed); return }
            report(.response(responseCode))
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let responseCode { report(.displaying(responseCode)) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        private func failed(_ error: Error) {
            let code = (error as NSError).code
            if code == NSURLErrorCancelled { return }
            if code == NSURLErrorUserCancelledAuthentication, model.wrappedValue.pageStatus == .authenticationDenied { return }
            report(.failed)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { report(.failed) }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               model.wrappedValue.isCurrent(selection) {
                completionHandler(.performDefaultHandling, nil)
            } else {
                report(.authenticationDenied)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            report(.navigationDenied)
            return nil
        }

        func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo,
                     completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            completionHandler(nil)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.cancel { _ in }
            report(.navigationDenied)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.cancel { _ in }
            report(.navigationDenied)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }
}
