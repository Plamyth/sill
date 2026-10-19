import SwiftUI
import WebKit
import StreamProtocol

struct TestDestinationsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = TestDestinationsModel(fetch: {
        guard let connection = CanvasRelay.loadConnection() else { throw TestDestinationsError.relayMissing }
        return try await CanvasRelay(address: connection.address, token: connection.token).testDestinations()
    })

    var body: some View {
        NavigationStack {
            Group {
                if let selection = model.selection {
                    selected(selection)
                } else {
                    catalog
                }
            }
            .navigationTitle("프로젝트 테스트")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Mac 화면") { model.cancel(); dismiss() }
                        .accessibilityIdentifier("closeTestDestinations")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.selection != nil {
                        Button("목록") { model.cancel() }
                    }
                    Button("목록 새로고침", systemImage: "arrow.clockwise") { model.refresh() }
                        .accessibilityLabel("테스트 목록 새로고침")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.refresh() }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var catalog: some View {
        switch model.catalog {
        case .loading:
            ProgressView("테스트 목록을 확인하는 중입니다.")
        case .problem(let message):
            ContentUnavailableView("목록을 확인할 수 없습니다", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded(let catalog):
            if catalog.entries.isEmpty {
                ContentUnavailableView("등록된 테스트 대상이 없습니다", systemImage: "globe",
                                       description: Text("담당자가 실행 중인 테스트 주소를 등록하면 여기에 표시됩니다."))
            } else {
                List {
                    ForEach(Array(Set(catalog.entries.map(\.projectId))).sorted(), id: \.self) { project in
                        let entries = catalog.entries.filter { $0.projectId == project }
                        Section(entries.first?.projectLabel ?? "프로젝트") {
                            ForEach(entries, id: \.id) { entry in
                                Button { model.select(entry) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.label).font(.headline)
                                        Text(entry.url).font(.caption).foregroundStyle(.secondary)
                                        Text(entry.reachability == .reachable ? "실행 확인됨 · 열 때 iPad 연결 확인" : "실행 상태 미확인")
                                            .font(.caption)
                                    }
                                    .frame(minHeight: 44, alignment: .leading)
                                }
                                .accessibilityLabel("\(entry.projectLabel), \(entry.label), 테스트 열기")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func selected(_ selection: TestDestinationsModel.Selection) -> some View {
        switch selection {
        case .checking(let identity):
            VStack(spacing: 12) {
                Text(identity.projectLabel).font(.headline)
                ProgressView("선택한 대상과 iPad 연결을 확인하는 중입니다.")
            }
        case .problem(let identity, let message):
            VStack {
                Text(identity.projectLabel).font(.headline)
                ContentUnavailableView("테스트를 열 수 없습니다", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            }
        case .ready(let target, let notice):
            VStack(spacing: 8) {
                Text("\(target.entry.projectLabel) · \(target.entry.label)").font(.headline)
                if let notice { Text(notice).font(.callout) }
                if target.entry.embed == .blocked {
                    Text("프레임 삽입 제한이 관측되었습니다. 이 화면은 주소를 직접 엽니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("페이지 이동 주소만 제한합니다. 페이지 내부의 모든 통신을 차단하는 기능은 아닙니다. 카메라·마이크는 허용하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                TestDestinationBrowser(target: target)
                    .id(TestDestinationIdentity(target.entry).projectID + ":" + target.entry.id)
            }
            .padding(.top, 8)
        }
    }
}

private struct TestDestinationBrowser: View {
    let target: TestDestinationTarget
    @State private var message: String?

    var body: some View {
        VStack(spacing: 8) {
            if let message {
                Text(message).font(.callout).padding(.horizontal)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            TestDestinationWebView(target: target, message: $message)
        }
    }
}

private struct TestDestinationWebView: UIViewRepresentable {
    let target: TestDestinationTarget
    @Binding var message: String?

    func makeCoordinator() -> Coordinator { Coordinator(target: target, message: $message) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier:
            TestDestinationSessions.identifier(projectID: target.entry.projectId))
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.accessibilityLabel = "프로젝트 테스트 웹 화면"
        web.load(URLRequest(url: target.url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let target: TestDestinationTarget
        let message: Binding<String?>
        var active = true

        init(target: TestDestinationTarget, message: Binding<String?>) {
            self.target = target
            self.message = message
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard active, action.targetFrame != nil, let url = action.request.url, target.allows(url),
                  !action.shouldPerformDownload else {
                report(TestDestinationsError.externalLogin.message)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard active, let url = response.response.url, target.allows(url), response.canShowMIMEType else {
                report(TestDestinationsError.externalLogin.message)
                decisionHandler(.cancel)
                return
            }
            if let http = response.response as? HTTPURLResponse, [401, 403].contains(http.statusCode) {
                report("로그인이 필요합니다. 이 프로젝트 화면 안에서 로그인하세요.")
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            guard active, let url = webView.url, target.allows(url) else {
                webView.stopLoading()
                report(TestDestinationsError.externalLogin.message)
                return
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            report(TestDestinationsError.externalLogin.message)
            return nil
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            report("테스트 화면에는 카메라·마이크 권한을 제공하지 않습니다.")
            decisionHandler(.deny)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            showFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            report("웹 화면이 중단되었습니다. 목록에서 다시 선택하세요.")
        }

        private func report(_ text: String) {
            guard active else { return }
            message.wrappedValue = text
        }

        private func showFailure(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            report("테스트 페이지를 불러오지 못했습니다. 로그인·네트워크 또는 서버 상태를 확인하세요.")
        }
    }
}
