import Foundation
import Security
import StreamProtocol

struct CanvasRelay {
    struct VaultEntry: Decodable, Identifiable {
        let name: String
        let path: String
        let kind: String
        var id: String { path }
    }
    struct VaultEntries: Decodable { let entries: [VaultEntry] }
    typealias VaultNote = VaultNoteSnapshot
    struct VaultCanvas: Decodable {
        let path: String
        let noteSha256: String
        let sceneSha256: String
        let imageSha256: String
        let revision: Int
        let sceneJSONBase64: String
    }
    struct VaultCanvasSaved: Decodable {
        let path: String
        let noteSha256: String
        let sceneSha256: String
        let imageSha256: String
        let revision: Int
    }
    struct DeliveryReadiness: Decodable { let available: Bool }
    struct InboxTarget: Decodable {
        let threadId: UUID
        let sessionId: String
        let targetMode: String
        let title: String

        func session() throws -> VoiceSession {
            guard targetMode == "inbox",
                  sessionId == "inbox:\(threadId.uuidString.lowercased())" else {
                throw CanvasSendError.changedSession
            }
            return VoiceSession(threadId:threadId,sessionId:sessionId,
                                observedAt:ISO8601DateFormatter().string(from:Date()))
        }
    }
    let address: String
    let token: String
    private let session: URLSession

    init(address: String, token: String, session: URLSession = .shared) {
        self.address = address
        self.token = token
        self.session = session
    }

    private struct Connection: Codable { let address: String; let token: String }
    private static let keychainService = "com.ambrion.canvasbridge.relay"

    static func loadConnection() -> (address: String, token: String)? {
        guard let documents = FileManager.default.urls(for:.documentDirectory,
                                                       in:.userDomainMask).first else { return storedConnection() }
        let file = documents.appendingPathComponent("canvas-relay.json")
        if let data = try? Data(contentsOf:file),
           let value = try? JSONDecoder().decode(Connection.self,from:data),
           valid(value) {
            let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
                                       kSecAttrService as String:keychainService,
                                       kSecAttrAccount as String:"local"]
            SecItemDelete(query as CFDictionary)
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(insert as CFDictionary,nil) == errSecSuccess {
                try? FileManager.default.removeItem(at:file)
                return (value.address,value.token)
            }
        }
        return storedConnection()
    }

    private static func valid(_ value: Connection) -> Bool {
        URL(string:value.address)?.scheme == "http" && value.token.count >= 24
    }

    private static func storedConnection() -> (address: String, token: String)? {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
                                   kSecAttrService as String:keychainService,
                                   kSecAttrAccount as String:"local",
                                   kSecReturnData as String:true,
                                   kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,
              let data = result as? Data,
              let value = try? JSONDecoder().decode(Connection.self,from:data),valid(value)
        else { return nil }
        return (value.address,value.token)
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let root = URL(string: address), root.scheme == "http",
              let url = URL(string: path, relativeTo: root)?.absoluteURL,
              !token.isEmpty else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Canvas-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        return request
    }

    private func response<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, raw) = try await session.data(for: request)
        guard let http = raw as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String:String])?["error"]
            throw NSError(domain:"CanvasRelay",code:http.statusCode,
                          userInfo:[NSLocalizedDescriptionKey:message ?? "Mac 수신 오류"])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type,from:data)
    }

    func projection() async throws -> VoiceProjection {
        try await response(request("/voice/projection"),as:VoiceProjection.self)
    }

    func controlRoomProjection() async throws -> ControlRoomProjection {
        try await response(request("/control-room/projection"),as:ControlRoomProjection.self)
    }

    func testDestinations() async throws -> TestDestinationCatalog {
        let envelope = try await response(request("/control-room/projection"), as: TestDestinationsEnvelope.self)
        return try envelope.validated()
    }

    private func vaultURL(_ endpoint: String, path: String) throws -> String {
        guard let root = URL(string:address),
              let url = URL(string:endpoint,relativeTo:root),
              var components = URLComponents(url:url.absoluteURL,resolvingAgainstBaseURL:true) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name:"path",value:path)]
        guard let result = components.url else { throw URLError(.badURL) }
        return result.absoluteString
    }

    func vaultEntries(in directory: String) async throws -> [VaultEntry] {
        let path = try vaultURL("/vault/entries",path:directory)
        return try await response(request(path),as:VaultEntries.self).entries
    }

    func vaultNote(at path: String) async throws -> VaultNote {
        try await response(request(vaultURL("/vault/note",path:path)),as:VaultNote.self).validated(at:path)
    }

    func saveVaultNote(at path: String, baseSha256: String, text: String) async throws -> VaultNote {
        guard VaultNoteReference.validPath(path), baseSha256.count == 64,
              baseSha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              text.utf8.count <= 1024 * 1024 else { throw URLError(.badURL) }
        let body = try JSONSerialization.data(withJSONObject:["baseSha256":baseSha256,"text":text])
        let saved = try await response(request(vaultURL("/vault/note",path:path),method:"PUT",body:body),
                                       as:VaultNote.self).validated(at:path)
        guard saved.text.utf8.elementsEqual(text.utf8) else { throw URLError(.badServerResponse) }
        return saved
    }

    func replaceVaultBlock(at path: String, blockID: String, edit: VaultBlockEdit) async throws -> VaultBlockEditResult {
        guard VaultNoteReference.validPath(path), !blockID.isEmpty,
              blockID.utf8.count <= 1024,
              blockID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 }),
              edit.schemaVersion == 1, edit.replacementText.utf8.count <= 1024 * 1024 else {
            throw URLError(.badURL)
        }
        var components = URLComponents(string:try vaultURL("/vault/block",path:path))!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name:"blockID",value:blockID)]
        guard let endpoint = components.url?.absoluteString else { throw URLError(.badURL) }
        return try await response(request(endpoint,method:"PUT",body:JSONEncoder().encode(edit)),
                                  as:VaultBlockEditResult.self)
    }

    func vaultCanvas(id: UUID) async throws -> VaultCanvas? {
        do {
            return try await response(request("/vault/canvas?id=\(id.uuidString.lowercased())"),
                                      as:VaultCanvas.self)
        } catch let error as NSError where error.domain == "CanvasRelay" && error.code == 404 {
            return nil
        }
    }

    func saveVaultCanvas(scene: CanvasScene, imagePNG: Data,
                         baseSha256: String?) async throws -> VaultCanvasSaved {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sceneBytes = try encoder.encode(scene)
        let body = try JSONSerialization.data(withJSONObject:[
            "revision":scene.revision,
            "baseSha256":(baseSha256 as Any?) ?? NSNull(),
            "sceneJSONBase64":sceneBytes.base64EncodedString(),
            "imagePNGBase64":imagePNG.base64EncodedString()
        ])
        return try await response(request("/vault/canvas?id=\(scene.id.uuidString.lowercased())",
                                          method:"PUT",body:body),as:VaultCanvasSaved.self)
    }

    func inboxTarget() async throws -> InboxTarget {
        try await response(request("/inbox/target"),as:InboxTarget.self)
    }

    func deliveryReadiness(threadId: UUID, targetMode: String?) async throws -> DeliveryReadiness {
        let mode = targetMode ?? "voice"
        let path = "/delivery/ready?threadId=\(threadId.uuidString.lowercased())&targetMode=\(mode)"
        return try await response(request(path),as:DeliveryReadiness.self)
    }

    func send(_ packet: CanvasPacket) async throws -> PacketReceipt {
        try await response(request("/packets",method:"POST",body:JSONEncoder().encode(packet)),as:PacketReceipt.self)
    }

    func receipt(for packet: UUID) async throws -> PacketReceipt {
        try await response(request("/packets/\(packet.uuidString.lowercased())/receipt"),as:PacketReceipt.self)
    }

    func revision(for packet: UUID) async throws -> AgentRevision? {
        try await response(request("/packets/\(packet.uuidString.lowercased())/revision"),
                           as:AgentRevision?.self)
    }
}
