import Foundation

struct ControlEventsContract: @unchecked Sendable {
    let decode: (ControlEventsSSEFrame) throws -> ControlEventsEnvelope
    let project: (ControlEventsDocument) throws -> ControlEventsProjection
    static let mobileV1 = Self(decode: ControlEventsCodec.decode, project: ControlEventsCodec.project)
}

struct ControlEventsGateway: @unchecked Sendable {
    let eventsURL: URL
    let credentialHeader: String
    let authenticatedRequest: () throws -> URLRequest
    var contract = ControlEventsContract.mobileV1
    static let maximumPayloadBytes = 8_388_608 - 8192
    var maximumFrameBytes = 8_388_608
    var recoverAuthentication: (@MainActor (ControlEventsAuthenticationFailure) async -> ControlEventsGateway?)?

    func request() throws -> URLRequest {
        let request = try authenticatedRequest()
        let names = ["authorization", "x-canvas-token"]
        guard let url = request.url, url == eventsURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              names.contains(credentialHeader.lowercased()),
              let credential = request.value(forHTTPHeaderField: credentialHeader), !credential.isEmpty,
              credential.utf8.count <= 4096, !credential.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              names.filter({ $0 != credentialHeader.lowercased() }).allSatisfy({ request.value(forHTTPHeaderField: $0) == nil }) else {
            throw ControlEventsTransportFailure.configuration
        }
        var accepted = request
        accepted.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        accepted.setValue(nil, forHTTPHeaderField: "Last-Event-ID") // The current gateway resumes with a full snapshot.
        accepted.cachePolicy = .reloadIgnoringLocalCacheData
        accepted.httpShouldHandleCookies = false
        return accepted
    }
}

struct ControlEventsAuthenticationFailure: Error, CustomStringConvertible {
    let status: Int
    let body: Data
    let authorization: String
    var description: String { "기기 등록 인증이 거부되었습니다." }
}

enum ControlEventsTransportFailure: Error, Equatable {
    case configuration, authentication, serviceUnavailable, response, contentType, redirect, payload, streamEnded, capacity
    var message: String {
        switch self {
        case .configuration: return "연결 정보 미제공 · 인증된 연결 서버 설정을 확인하지 못했습니다."
        case .authentication: return "연결 서버 인증이 거부되었습니다. 이 Vision 앱의 기기 등록을 확인하세요."
        case .serviceUnavailable: return "연결 서버가 아직 준비되지 않았습니다. 잠시 후 다시 연결합니다."
        case .response: return "연결 서버의 이벤트 응답을 확인하지 못했습니다."
        case .contentType: return "연결 서버 응답이 이벤트 스트림 형식이 아닙니다."
        case .redirect: return "다른 주소로 이동하는 이벤트 연결을 차단했습니다."
        case .payload: return "지원하지 않거나 잘못된 이벤트입니다. 상태 동기화를 중지했습니다."
        case .streamEnded: return "이벤트 연결이 끊겼습니다. 기존 정보는 마지막 관측입니다."
        case .capacity: return "이벤트 수신 대기 상한을 초과했습니다. 마지막 관측만 표시합니다."
        }
    }
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Self.response }
        if http.statusCode == 401 || http.statusCode == 403 { throw Self.authentication }
        if (300..<400).contains(http.statusCode) { throw Self.redirect }
        if http.statusCode == 503 { throw Self.serviceUnavailable }
        guard http.statusCode == 200 else { throw Self.response }
        guard http.mimeType?.lowercased() == "text/event-stream" else { throw Self.contentType }
    }
}

final class ControlEventsRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ControlEventsRetryPolicy {
    private var attempts = 0
    mutating func progressed() { attempts = 0 }
    mutating func delay(for error: Error) -> UInt64? {
        if let failure = error as? ControlEventsTransportFailure {
            guard failure == .streamEnded || failure == .serviceUnavailable else { return nil }
        } else if let url = error as? URLError {
            guard [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                   .cannotFindHost, .dnsLookupFailed].contains(url.code) else { return nil }
        } else { return nil }
        let delay = UInt64(min(1 << attempts, 30)) * 1_000_000_000
        attempts = min(attempts + 1, 5)
        return delay
    }
}

enum ControlEventsStreamItem: Sendable {
    case opened(Date)
    case envelope(ControlEventsEnvelope)
}

enum ControlEventsTransport {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 86_400
        return configuration
    }

    static func stream(_ gateway: ControlEventsGateway) -> AsyncThrowingStream<ControlEventsStreamItem, Error> {
        stream(gateway, configuration: configuration())
    }

    static func stream(_ gateway: ControlEventsGateway, configuration: URLSessionConfiguration) -> AsyncThrowingStream<ControlEventsStreamItem, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(4)) { continuation in
            let worker = Task.detached {
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                do {
                    let request = try await MainActor.run { try gateway.request() }
                    let (bytes, response) = try await session.bytes(for: request, delegate: ControlEventsRedirectGuard())
                    if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                        guard http.url == request.url, http.mimeType?.lowercased() == "application/json",
                              let authorization = request.value(forHTTPHeaderField: "Authorization") else {
                            throw ControlEventsTransportFailure.authentication
                        }
                        var body = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            guard body.count < 4096 else { throw ControlEventsTransportFailure.authentication }
                            body.append(byte)
                        }
                        throw ControlEventsAuthenticationFailure(status: http.statusCode, body: body, authorization: authorization)
                    }
                    try ControlEventsTransportFailure.validate(response)
                    continuation.yield(.opened(Date()))
                    var parser = ControlEventsSSEParser(maximumFrameBytes: gateway.maximumFrameBytes)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let frame = try parser.append(byte) else { continue }
                        guard frame.data.utf8.count <= ControlEventsGateway.maximumPayloadBytes else {
                            throw ControlEventsTransportFailure.payload
                        }
                        let envelope = try gateway.contract.decode(frame)
                        if case .dropped = continuation.yield(.envelope(envelope)) { throw ControlEventsTransportFailure.capacity }
                    }
                    try parser.finish()
                    throw ControlEventsTransportFailure.streamEnded
                } catch {
                    if error is ControlEventsCodec.Failure || error is DecodingError || error is ControlEventsSSEParser.Failure {
                        continuation.finish(throwing: ControlEventsTransportFailure.payload)
                    } else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
