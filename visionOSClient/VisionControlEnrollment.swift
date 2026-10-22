import Foundation
import Security
import Combine

struct VisionControlOrigin: Equatable, Codable, Sendable {
    let url: URL
    static let publicDefault: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CCRControlEventsOrigin") as? String,
              (try? VisionControlOrigin(value)) != nil else { return "" }
        return value
    }()
    init(_ text: String) throws {
        guard let parts = URLComponents(string: text), parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw VisionControlEnrollmentFailure.origin }
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = parts.host?.lowercased()
        canonical.port = parts.port == 443 ? nil : parts.port
        guard let normalized = canonical.url, url.scheme == "https" else { throw VisionControlEnrollmentFailure.origin }
        self.url = normalized
    }
    var eventsURL: URL { url.appendingPathComponent("v1/events") }
    var enrollURL: URL { url.appendingPathComponent("v1/enroll") }
}

struct VisionControlCredential: Codable, Equatable, Sendable {
    let origin: VisionControlOrigin
    let token: String
    func gateway() throws -> ControlEventsGateway {
        guard VisionControlEnrollment.hex(token, count: 64), try VisionControlOrigin(origin.url.absoluteString) == origin else {
            throw VisionControlEnrollmentFailure.storage
        }
        return ControlEventsGateway(eventsURL: origin.eventsURL, credentialHeader: "Authorization", authenticatedRequest: {
            var request = URLRequest(url: origin.eventsURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        })
    }
}

struct VisionControlCredentialStore {
    let load: () throws -> VisionControlCredential?
    let save: (VisionControlCredential) throws -> Void

    static let keychain = Self(load: {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 8192 else { throw VisionControlEnrollmentFailure.storage }
        let credential = try JSONDecoder().decode(VisionControlCredential.self, from: data)
        _ = try credential.gateway()
        return credential
    }, save: { credential in
        let data = try JSONEncoder().encode(credential)
        let changes: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(keychainQuery as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = keychainQuery
            item.merge(changes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VisionControlEnrollmentFailure.storage }
        } else if status != errSecSuccess { throw VisionControlEnrollmentFailure.storage }
    })

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.ambrion.SillVision.control-events.enrollment.v1",
         kSecAttrAccount as String: "vision-enrolled-gateway",
         kSecAttrSynchronizable as String: false]
    }
}

enum VisionControlEnrollmentFailure: Error, Equatable {
    case origin, code, response, authentication, rateLimited, oversized, storage, unknown
    var message: String {
        switch self {
        case .origin: return "HTTPS 서버 주소만 입력하세요. 경로·계정·쿼리·추가 주소 정보는 사용할 수 없습니다."
        case .code: return "등록 코드는 공백 없는 24자리 16진수여야 합니다. 자동 제출하지 않습니다."
        case .authentication: return "등록 코드가 거부되었거나 이미 사용되었습니다. 새 코드를 자동 요청하지 않습니다."
        case .rateLimited: return "등록 요청 횟수 제한에 도달했습니다. 자동 재시도하지 않습니다."
        case .oversized: return "등록 요청 또는 응답이 허용 크기를 초과했습니다."
        case .storage: return "이 Vision 앱의 보안 저장소에 등록 정보를 보존하지 못했습니다. 자동 재등록하지 않습니다."
        case .unknown: return "등록 결과 미확인 · 서버에서 코드가 소비되었을 수 있습니다. 자동 재시도하거나 새 코드를 발급하지 않습니다."
        case .response: return "등록 응답 또는 HTTPS 신뢰 검증에 실패했습니다. 자동 재시도하지 않습니다."
        }
    }
}

enum VisionControlEnrollment {
    typealias Exchange = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let maximumResponseBytes = 4096
    static func hex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    static func request(origin: VisionControlOrigin, code: String) throws -> URLRequest {
        guard try VisionControlOrigin(origin.url.absoluteString) == origin else { throw VisionControlEnrollmentFailure.origin }
        guard hex(code, count: 24) else { throw VisionControlEnrollmentFailure.code }
        var request = URLRequest(url: origin.enrollURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code.lowercased()])
        guard (request.httpBody?.count ?? 129) <= 128 else { throw VisionControlEnrollmentFailure.oversized }
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        return request
    }
    static func register(origin: VisionControlOrigin, code: String, exchange: Exchange = { try await exchange($0) }) async throws -> VisionControlCredential {
        let request = try request(origin: origin, code: code)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await exchange(request) }
        catch let error as VisionControlEnrollmentFailure { throw error }
        catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost || error.code == .cancelled {
            throw VisionControlEnrollmentFailure.unknown
        } catch { throw VisionControlEnrollmentFailure.response }
        guard response.url == origin.enrollURL else { throw VisionControlEnrollmentFailure.response }
        if response.statusCode == 403 { throw VisionControlEnrollmentFailure.authentication }
        if response.statusCode == 429 { throw VisionControlEnrollmentFailure.rateLimited }
        if response.statusCode == 413 { throw VisionControlEnrollmentFailure.oversized }
        guard data.count <= maximumResponseBytes else { throw VisionControlEnrollmentFailure.oversized }
        guard response.statusCode == 200, response.mimeType?.lowercased() == "application/json",
              let object = try? JSONDecoder().decode([String: String].self, from: data), Set(object.keys) == ["token"],
              let token = object["token"], hex(token, count: 64) else { throw VisionControlEnrollmentFailure.response }
        return VisionControlCredential(origin: origin, token: token)
    }
    static func exchange(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await exchange(request, configuration: ControlEventsTransport.configuration())
    }
    static func exchange(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: ControlEventsRedirectGuard())
        guard let response = response as? HTTPURLResponse else { throw VisionControlEnrollmentFailure.response }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw VisionControlEnrollmentFailure.oversized }
            data.append(byte)
        }
        return (data, response)
    }
}

@MainActor
final class VisionControlEnrollmentController: ObservableObject {
    @Published private(set) var message = "연결 정보 미제공 · Mac에서 직접 발급한 5분 유효 1회용 코드로 이 Vision 앱을 등록하세요."
    @Published private(set) var submitting = false
    @Published private(set) var registeredOrigin: String?
    private let events: ControlEventsController
    private let store: VisionControlCredentialStore
    private let exchange: VisionControlEnrollment.Exchange
    private var restoredCredential: VisionControlCredential?

    init(events: ControlEventsController, store: VisionControlCredentialStore = .keychain,
         exchange: @escaping VisionControlEnrollment.Exchange = { try await VisionControlEnrollment.exchange($0) }) {
        self.events = events; self.store = store; self.exchange = exchange
    }
    @discardableResult
    func restore() -> Bool {
        guard !submitting else { return false }
        do {
            guard let credential = try store.load() else {
                guard restoredCredential != nil else { return false }
                events.configure(nil)
                restoredCredential = nil
                registeredOrigin = nil
                message = "이 Vision 앱의 등록 정보가 없어 다시 등록해야 합니다."
                return true
            }
            guard credential != restoredCredential else { return false }
            events.configure(try credential.gateway())
            restoredCredential = credential
            registeredOrigin = credential.origin.url.absoluteString
            message = "이 Vision 앱의 기존 등록 정보를 보안 저장소에서 복원했습니다."
            return true
        } catch { message = VisionControlEnrollmentFailure.storage.message; return false }
    }
    @discardableResult
    func submit(origin text: String, code: String) async -> Bool {
        guard !submitting else { return false }
        submitting = true
        defer { submitting = false }
        do {
            let origin = try VisionControlOrigin(text)
            let exchange = exchange
            let credential = try await Task.detached { try await VisionControlEnrollment.register(origin: origin, code: code, exchange: exchange) }.value
            do { try store.save(credential) } catch { throw VisionControlEnrollmentFailure.storage }
            events.configure(try credential.gateway())
            restoredCredential = credential
            registeredOrigin = origin.url.absoluteString
            message = "이 Vision 앱의 등록이 저장되었습니다. 작업 상태 구독에만 사용합니다."
            return true
        } catch {
            message = (error as? VisionControlEnrollmentFailure)?.message ?? VisionControlEnrollmentFailure.response.message
            return false
        }
    }
}
