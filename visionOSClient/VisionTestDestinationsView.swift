import Foundation
import SwiftUI
import StreamProtocol
import WebKit
import UIKit

@MainActor
struct VisionTestDestinationsView: View {
    @Binding var model: VisionTestDestinations
    @ObservedObject var stores: VisionTestDestinationStores
    let close: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in content }
    }

    private var content: some View {
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
                VisionTestDestinationWebView(model: $model, selection: selected,
                                             store: stores.store(projectID: selected.entry.projectId, epoch: model.storageEpoch))
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
                        if entry.reachability == .reachable,
                           model.binding.flatMap({ model.openingURL(for: entry, from: $0) }) == nil {
                            Text("HTTPS 접속 확인 정보가 없거나 확인 시각이 유효하지 않아 열 수 없습니다. 확인 정보는 45초 동안 유효합니다.")
                                .font(.caption)
                        }
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
        .onChange(of: model.storageEpoch, initial: true) { _, epoch in stores.synchronize(epoch) }
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
        case .navigationDenied: return "등록되지 않은 출처 이동·새 창·다운로드는 허용하지 않습니다."
        case .authenticationDenied: return "웹 인증 요청을 차단했습니다. Mac의 인증 정보나 쿠키를 가져오지 않습니다."
        case .resourceFilterFailed: return "웹 리소스 출처 제한을 준비하지 못해 페이지를 열지 않았습니다. 목록에서 다시 선택하세요."
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
final class VisionTestDestinationStores: ObservableObject {
    private var epoch: UUID?
    private var projects: [String: WKWebsiteDataStore] = [:]

    func synchronize(_ next: UUID) {
        guard epoch != next else { return }
        for store in projects.values {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
        projects.removeAll()
        epoch = next
    }

    func store(projectID: String, epoch: UUID) -> WKWebsiteDataStore {
        synchronize(epoch)
        if let store = projects[projectID] { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        projects[projectID] = store
        return store
    }
}

@MainActor
private struct VisionTestDestinationWebView: UIViewRepresentable {
    @Binding var model: VisionTestDestinations
    let selection: VisionTestDestinations.Selection
    let store: WKWebsiteDataStore

    func makeCoordinator() -> Coordinator { Coordinator(model: $model, selection: selection) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.accessibilityLabel = "프로젝트 테스트 웹 화면"
        context.coordinator.prepare(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.model = $model
        context.coordinator.revalidate(view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop(view)
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var model: Binding<VisionTestDestinations>
        let selection: VisionTestDestinations.Selection
        private var responseCode: Int?
        private enum ResourceState {
            case idle, compiling, ready(WKContentRuleList), closed
        }
        private var resourceState: ResourceState = .idle
        private let ruleListStore: WKContentRuleListStore = .default()
        private let ruleListIdentifier = "ccr-vision-test-\(UUID().uuidString)"

        init(model: Binding<VisionTestDestinations>, selection: VisionTestDestinations.Selection) {
            self.model = model
            self.selection = selection
        }

        func prepare(_ webView: WKWebView) {
            guard case .idle = resourceState else { return }
            guard model.wrappedValue.revalidate(selection),
                  let json = model.wrappedValue.resourceRuleListJSON(for: selection) else {
                resourceState = .closed
                model.wrappedValue.report(.resourceFilterFailed, for: selection)
                return
            }
            resourceState = .compiling
            let store = ruleListStore
            let identifier = ruleListIdentifier
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { [weak self, weak webView] list, error in
                guard let self, let webView, case .compiling = self.resourceState,
                      self.model.wrappedValue.revalidate(self.selection) else {
                    self?.resourceState = .closed
                    webView?.stopLoading()
                    store.removeContentRuleList(forIdentifier: identifier) { _ in }
                    return
                }
                guard error == nil, let list else {
                    self.resourceState = .closed
                    self.model.wrappedValue.report(.resourceFilterFailed, for: self.selection)
                    store.removeContentRuleList(forIdentifier: identifier) { _ in }
                    return
                }
                webView.configuration.userContentController.add(list)
                self.resourceState = .ready(list)
                webView.load(URLRequest(url: self.selection.url))
            }
        }

        func revalidate(_ webView: WKWebView) {
            if !model.wrappedValue.revalidate(selection) { stop(webView) }
        }

        func stop(_ webView: WKWebView) {
            model.wrappedValue.revalidate(selection)
            webView.stopLoading()
            if case .ready(let list) = resourceState {
                webView.configuration.userContentController.remove(list)
                ruleListStore.removeContentRuleList(forIdentifier: ruleListIdentifier) { _ in }
            }
            // 진행 중 컴파일의 저장 식별자는 완료 콜백에서 정리한다.
            resourceState = .closed
        }

        private func allowed(_ url: URL?) -> Bool {
            guard case .ready = resourceState, model.wrappedValue.revalidate(selection) else { return false }
            return url.map { model.wrappedValue.allowsNavigation(to: $0, for: selection) } == true
        }

        private func report(_ status: VisionTestDestinations.PageStatus) {
            guard case .ready = resourceState else { return }
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
            guard case .ready = resourceState, model.wrappedValue.revalidate(selection) else {
                webView.stopLoading()
                return
            }
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
            guard allowed(webView.url) else { webView.stopLoading(); report(.navigationDenied); return }
            if let responseCode { report(.displaying(responseCode)) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        private func failed(_ error: Error) {
            guard model.wrappedValue.revalidate(selection) else { return }
            let code = (error as NSError).code
            if code == NSURLErrorCancelled { return }
            if code == NSURLErrorUserCancelledAuthentication, model.wrappedValue.pageStatus == .authenticationDenied { return }
            report(.failed)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { report(.failed) }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            var origin = URLComponents()
            origin.scheme = space.protocol
            origin.host = space.host
            guard (1...65535).contains(space.port) else {
                report(.authenticationDenied)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            origin.port = space.port
            if allowed(origin.url), space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
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
