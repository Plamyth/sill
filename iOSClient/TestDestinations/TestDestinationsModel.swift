import Foundation
import Combine
import StreamProtocol

struct TestDestinationProbe {
    private final class Fence: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }

    static func check(_ target: TestDestinationTarget) async throws -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: Fence(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var url = target.url
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.httpMethod = "HEAD"
            request.httpShouldHandleCookies = false
            let response: URLResponse
            do {
                let result = try await session.data(for: request)
                response = result.1
            } catch let error as URLError where error.code == .userAuthenticationRequired || error.code == .userCancelledAuthentication {
                return "로그인이 필요합니다. 이 프로젝트에 저장된 로그인만 사용합니다."
            }
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            switch http.statusCode {
            case 200...299: return nil
            case 401, 403: return "로그인이 필요합니다. 이 프로젝트에 저장된 로그인만 사용합니다."
            case 300...399:
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      URL(string: location, encodingInvalidCharacters: false) != nil, !location.contains("\\"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL,
                      target.allows(next) else { throw TestDestinationsError.externalLogin }
                url = next
            default: throw URLError(.cannotConnectToHost)
            }
        }
        throw URLError(.httpTooManyRedirects)
    }
}

@MainActor
final class TestDestinationsModel: ObservableObject {
    enum CatalogState {
        case loading, loaded(TestDestinationCatalog), problem(String)
    }
    enum Selection {
        case checking(TestDestinationIdentity)
        case ready(TestDestinationTarget, String?)
        case problem(TestDestinationIdentity, String)
    }

    @Published private(set) var catalog: CatalogState = .loading
    @Published private(set) var selection: Selection?
    private let fetch: () async throws -> TestDestinationCatalog
    private let probe: (TestDestinationTarget) async throws -> String?
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    init(fetch: @escaping () async throws -> TestDestinationCatalog,
         probe: @escaping (TestDestinationTarget) async throws -> String? = TestDestinationProbe.check) {
        self.fetch = fetch
        self.probe = probe
    }

    func refresh() {
        cancel()
        catalog = .loading
        let request = requestID
        task = Task {
            do {
                let result = try await fetch()
                try Task.checkCancellation()
                try TestDestinationsPolicy.validate(result, now: Date())
                guard request == requestID else { return }
                catalog = .loaded(result)
            } catch {
                guard !Task.isCancelled, request == requestID else { return }
                catalog = .problem(Self.catalogMessage(error))
            }
        }
    }

    func select(_ entry: TestDestinationCatalog.Entry) {
        cancel()
        let identity = TestDestinationIdentity(entry)
        selection = .checking(identity)
        let request = requestID
        task = Task {
            do {
                let result = try await fetch()
                try Task.checkCancellation()
                let target = try TestDestinationsPolicy.revalidate(identity, in: result)
                guard request == requestID else { return }
                catalog = .loaded(result)
                let notice = try await probe(target)
                try Task.checkCancellation()
                _ = try TestDestinationsPolicy.revalidate(identity, in: result)
                guard request == requestID else { return }
                selection = .ready(target, notice)
            } catch {
                guard !Task.isCancelled, request == requestID else { return }
                let message: String
                if let error = error as? TestDestinationsError {
                    message = error.message
                } else if error is DecodingError {
                    message = TestDestinationsError.malformed.message
                } else {
                    message = "이 iPad에서 테스트 주소에 연결하지 못했습니다. 로그인·네트워크 또는 서버 상태를 확인하세요."
                }
                selection = .problem(identity, message)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        selection = nil
    }

    private static func catalogMessage(_ error: Error) -> String {
        if let error = error as? TestDestinationsError { return error.message }
        if error is DecodingError { return TestDestinationsError.malformed.message }
        return TestDestinationsError.connection.message
    }
}
