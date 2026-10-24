import Foundation
import CryptoKit

enum IPadAppUpdateError: Error, LocalizedError, Equatable {
    case unconfigured, malformed, signature, identity, expired, rollback, unsafeURL
    case unsupportedChannel, sourceMismatch, network, openFailed, handoffUnknown, storage, cancelled

    var errorDescription: String? {
        switch self {
        case .unconfigured: return "배포채널 준비중"
        case .malformed: return "업데이트 정보 형식이 올바르지 않습니다."
        case .signature: return "업데이트 정보의 서명을 확인하지 못했습니다."
        case .identity: return "이 CCR iPad 앱에 승인된 업데이트가 아닙니다."
        case .expired: return "업데이트 승인 시간이 유효하지 않습니다. 다시 조회하세요."
        case .rollback: return "이전에 확인한 버전보다 오래되거나 변경된 업데이트를 차단했습니다."
        case .unsafeURL: return "승인된 Apple 설치 주소가 아닙니다."
        case .unsupportedChannel: return "이 개발 배포채널은 앱 내 업데이트를 지원하지 않습니다."
        case .sourceMismatch: return "실행 중인 앱의 버전·빌드·소스가 승인된 업데이트와 일치하지 않습니다. 설치 완료로 확인하지 않았습니다."
        case .network: return "업데이트 정보를 가져오지 못했습니다. 네트워크를 확인하고 다시 시도하세요."
        case .openFailed: return "Apple 설치 화면을 열지 못했습니다. 다시 시도하면 최신 승인을 새로 조회합니다."
        case .handoffUnknown: return "Apple 설치 화면 열기의 결과를 확인하지 못했습니다. 설치 완료로 확인하지 않았습니다. 다시 조회하세요."
        case .storage: return "업데이트 확인 정보를 안전하게 저장하지 못했습니다. 설치 완료로 확인하지 않았습니다."
        case .cancelled: return "업데이트 작업 대기를 취소했습니다. 이미 보낸 OS 요청은 별도로 확인하세요."
        }
    }
}

struct IPadAppUpdateRelease: Codable, Equatable {
    let schemaVersion: Int
    let releaseID: String
    let platform: String
    let bundleID: String
    let teamID: String
    let version: String
    let build: String
    let sourceCommit: String
    let sourceTree: String
    let approvedAt: String
    let expiresAt: String
    let channel: String
    let appleAppID: String
    let installURL: String

    func hasSameArtifact(as other: Self) -> Bool {
        schemaVersion == other.schemaVersion && platform == other.platform && bundleID == other.bundleID &&
        teamID == other.teamID && version == other.version && build == other.build &&
        sourceCommit == other.sourceCommit && sourceTree == other.sourceTree && channel == other.channel &&
        appleAppID == other.appleAppID && installURL == other.installURL
    }
}

struct IPadAppUpdateInstalled: Equatable {
    let bundleID: String
    let version: String
    let build: String
    let sourceCommit: String
    let sourceTree: String

    static func read(_ bundle: Bundle = .main) -> Self {
        func value(_ key: String) -> String { bundle.object(forInfoDictionaryKey: key) as? String ?? "" }
        let sourceUnverified = bundle.object(forInfoDictionaryKey: "CCRSourceIdentityVerified") as? Bool == false
        return .init(bundleID: bundle.bundleIdentifier ?? "", version: value("CFBundleShortVersionString"),
                     build: value("CFBundleVersion"), sourceCommit: sourceUnverified ? "" : value("CCRSourceCommit"),
                     sourceTree: sourceUnverified ? "" : value("CCRSourceTree"))
    }

    func matches(_ release: IPadAppUpdateRelease) -> Bool {
        bundleID == release.bundleID && version == release.version && build == release.build &&
        IPadAppUpdatePolicy.isSHA(sourceCommit) && IPadAppUpdatePolicy.isSHA(sourceTree) &&
        sourceCommit == release.sourceCommit && sourceTree == release.sourceTree
    }
}

struct IPadAppUpdateConfiguration {
    let feedURL: URL
    let publicKey: Curve25519.Signing.PublicKey

    init(feed: String, key: String) throws {
        guard let url = IPadAppUpdatePolicy.httpsURL(feed),
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else {
            throw IPadAppUpdateError.unconfigured
        }
        feedURL = url
        self.publicKey = publicKey
    }

    static func bundled(_ bundle: Bundle = .main) -> Self? {
        guard let feed = bundle.object(forInfoDictionaryKey: "CCRUpdateFeedURL") as? String,
              let key = bundle.object(forInfoDictionaryKey: "CCRUpdatePublicKey") as? String else { return nil }
        return try? .init(feed: feed, key: key)
    }
}

enum IPadAppUpdatePolicy {
    static let bundleID = "com.ambrion.sillcanvas.ipad"
    static let teamID = "ZPTXHJ866D"
    static let maximumEnvelopeBytes = 32_768

    private struct Envelope: Decodable {
        let payload: String
        let signature: String
    }

    static func isSHA(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func number(_ value: String) -> UInt64? {
        guard !value.isEmpty, value.utf8.count <= 18,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              value == "0" || !value.hasPrefix("0") else { return nil }
        return UInt64(value)
    }

    static func version(_ value: String) -> [UInt64]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { number(String($0)) }
        guard values.count == parts.count else { return nil }
        return values + Array(repeating: 0, count: 3 - values.count)
    }

    static func httpsURL(_ raw: String) -> URL? {
        guard raw.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !raw.contains("\\"),
              let parts = URLComponents(string: raw), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true, parts.fragment == nil,
              let url = URL(string: raw, encodingInvalidCharacters: false), url.absoluteString == raw else { return nil }
        return url
    }

    static func appStoreURL(appleAppID: String, raw: String) -> URL? {
        guard let id = number(appleAppID), id > 0, appleAppID != "6816359860",
              raw == "https://apps.apple.com/app/id\(appleAppID)" else { return nil }
        return httpsURL(raw)
    }

    static func installURL(_ release: IPadAppUpdateRelease) throws -> URL {
        switch release.channel {
        case "appStore":
            guard let url = appStoreURL(appleAppID: release.appleAppID, raw: release.installURL) else {
                throw IPadAppUpdateError.unsafeURL
            }
            return url
        case "testflight":
            let prefix = "https://testflight.apple.com/join/"
            guard release.installURL.hasPrefix(prefix) else { throw IPadAppUpdateError.unsafeURL }
            let code = release.installURL.dropFirst(prefix.count)
            guard code.utf8.count == 8, code.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }), let url = httpsURL(release.installURL) else { throw IPadAppUpdateError.unsafeURL }
            return url
        default: throw IPadAppUpdateError.unsupportedChannel
        }
    }

    static func timestamp(_ value: String) -> Date? {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$"#,
                          options: .regularExpression) != nil else { return nil }
        let parts = value.dropLast().split(separator: ".")
        let seconds = String(parts[0]) + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let result = formatter.date(from: seconds), formatter.string(from: result) == seconds else { return nil }
        let fraction = parts.count == 2 ? Double("0." + parts[1]) ?? 0 : 0
        return result.addingTimeInterval(fraction)
    }

    static func authenticate(_ data: Data, configuration: IPadAppUpdateConfiguration,
                             now: Date, requireFresh: Bool = true) throws -> IPadAppUpdateRelease {
        guard data.count <= maximumEnvelopeBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = Data(base64Encoded: envelope.payload), String(data: payload, encoding: .utf8) != nil,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64 else {
            throw IPadAppUpdateError.malformed
        }
        guard configuration.publicKey.isValidSignature(signature, for: payload) else { throw IPadAppUpdateError.signature }
        guard let release = try? JSONDecoder().decode(IPadAppUpdateRelease.self, from: payload),
              release.schemaVersion == 1, !release.releaseID.isEmpty, release.releaseID.utf8.count <= 128,
              release.releaseID.utf8.allSatisfy({ (33...126).contains($0) }),
              version(release.version) != nil, let build = number(release.build), build > 0,
              isSHA(release.sourceCommit), isSHA(release.sourceTree),
              let appID = number(release.appleAppID), appID > 0,
              release.appleAppID != "6816359860" else { throw IPadAppUpdateError.malformed }
        guard release.platform == "ipadOS", release.bundleID == bundleID, release.teamID == teamID else {
            throw IPadAppUpdateError.identity
        }
        guard let approved = timestamp(release.approvedAt), let expires = timestamp(release.expiresAt),
              approved < expires, !requireFresh || (approved <= now && now < expires) else {
            throw IPadAppUpdateError.expired
        }
        _ = try installURL(release)
        return release
    }

    static func validateProgress(_ release: IPadAppUpdateRelease, installed: IPadAppUpdateInstalled,
                                 previous: IPadAppUpdateRelease?) throws -> Bool {
        guard installed.bundleID == bundleID else { throw IPadAppUpdateError.identity }
        guard let currentVersion = version(installed.version), let currentBuild = number(installed.build),
              currentBuild > 0, let targetVersion = version(release.version), let targetBuild = number(release.build) else {
            throw IPadAppUpdateError.malformed
        }
        let target = targetVersion + [targetBuild]
        let current = currentVersion + [currentBuild]
        guard !target.lexicographicallyPrecedes(current) else {
            throw IPadAppUpdateError.rollback
        }
        if let previous {
            guard let oldVersion = version(previous.version), let oldBuild = number(previous.build),
                  !target.lexicographicallyPrecedes(oldVersion + [oldBuild]),
                  let approved = timestamp(release.approvedAt), let previousApproved = timestamp(previous.approvedAt),
                  approved >= previousApproved else { throw IPadAppUpdateError.rollback }
            if release.releaseID == previous.releaseID {
                guard release == previous else { throw IPadAppUpdateError.rollback }
            } else if target == oldVersion + [oldBuild] {
                guard release.hasSameArtifact(as: previous) else { throw IPadAppUpdateError.rollback }
            }
        }
        if target == current {
            guard installed.matches(release) else { throw IPadAppUpdateError.sourceMismatch }
            return false
        }
        return true
    }
}

enum IPadAppUpdateFeed {
    final class Fence: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }

    static func fetch(_ configuration: IPadAppUpdateConfiguration,
                      sessionConfiguration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        let session = URLSession(configuration: sessionConfiguration, delegate: Fence(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: configuration.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == configuration.feedURL,
              http.expectedContentLength <= Int64(IPadAppUpdatePolicy.maximumEnvelopeBytes) else {
            throw IPadAppUpdateError.network
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < IPadAppUpdatePolicy.maximumEnvelopeBytes else { throw IPadAppUpdateError.malformed }
            data.append(byte)
        }
        return data
    }
}
