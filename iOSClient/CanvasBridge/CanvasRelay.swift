import Foundation
import Security
import StreamProtocol

struct CanvasSceneCapabilities: Decodable {
    let schema: String
    let sceneSchemaVersions: [Int]
    let nodeKinds: [String]
    let diagramProjection: String
    func require(_ scene: CanvasScene) throws {
        guard schema == "ccr.canvas-capabilities/v1", sceneSchemaVersions.contains(scene.schemaVersion),
              scene.nodes.allSatisfy({ nodeKinds.contains($0.kind.rawValue) }),
              diagramProjection == "ccr.diagram-shapes/v1" else { throw CanvasSceneWireError.relayCapability }
    }
}

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
        var reconciliationRequired: Bool? = nil
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
        #if DEBUG
        switch CanvasRuntime.launch {
        case .isolated(let context): return (context.relayAddress,context.token)
        case .invalid: return nil
        case .normal: break
        }
        #endif
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
        #if DEBUG
        switch CanvasRuntime.launch {
        case .isolated(let context):
            guard address == context.relayAddress, token == context.token else { throw CanvasRuntime.TestError.invalid }
        case .invalid: throw CanvasRuntime.TestError.invalid
        case .normal: break
        }
        #endif
        guard let root = URL(string: address), root.scheme == "http",
              let url = URL(string: path, relativeTo: root)?.absoluteURL,
              !token.isEmpty else { throw URLError(.badURL) }
        #if DEBUG
        if case .isolated = CanvasRuntime.launch {
            guard url.scheme == root.scheme, url.host == root.host, url.port == root.port,
                  url.user == nil, url.password == nil else { throw CanvasRuntime.TestError.invalid }
        }
        #endif
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Canvas-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        return request
    }

    private func response<T: Decodable>(_ request: URLRequest, as type: T.Type, maxBytes: Int? = nil) async throws -> T {
        let data: Data, raw: URLResponse
        if let maxBytes {
            let (stream,response) = try await session.bytes(for:request)
            raw = response
            guard response.expectedContentLength <= maxBytes else { throw VaultPDFError.tooLarge }
            var bounded = Data()
            for try await byte in stream {
                guard bounded.count < maxBytes else { throw VaultPDFError.tooLarge }
                bounded.append(byte)
            }
            data = bounded
        } else {
            (data,raw) = try await session.data(for:request)
        }
        guard let http = raw as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        let vault = request.url?.path.contains("/vault/") ?? false
        let required = body?["reconciliationRequired"] as? Bool
        let preserved = vault && (body?["code"] as? String == "note_reconciliation_required" || required == true)
        if !(200...299).contains(http.statusCode) || (preserved && request.httpMethod != "GET") {
            var info: [String:Any] = [NSLocalizedDescriptionKey:body?["error"] as? String ?? "Mac 수신 오류"]
            let status = preserved ? 409 : http.statusCode
            if vault && status == 409 {
                let kind: VaultSaveConflict = preserved ? .reconciliationRequired :
                    (required == false && body?["publicationAttempted"] as? Bool == false ? .prepublication : .unclassified)
                info[VaultSaveConflict.errorKey] = kind.rawValue
                // No raw error/recovery path parsing or private path disclosure.
                info[NSLocalizedDescriptionKey] = kind == .prepublication ?
                    "Obsidian 게시 전에 저장 요청이 거부됐습니다. 입력을 보존했습니다. 원문을 다시 확인하세요." :
                    VaultBlockRecoveryError.publicationConflict.localizedDescription
            }
            throw NSError(domain:"CanvasRelay",code:status,userInfo:info)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type,from:data)
    }

    func projection() async throws -> VoiceProjection {
        try await response(request("/voice/projection"),as:VoiceProjection.self)
    }

    func controlRoomEvents(retaining projection: ControlRoomProjection?) throws -> AsyncStream<ControlRoomEventUpdate> {
        ControlRoomEventStream.updates(request:try request("/control-room/events"),retaining:projection)
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

    func vaultPDF(at path: String) async throws -> VaultPDFSnapshot {
        guard VaultPDFSnapshot.validPath(path) else { throw VaultPDFError.invalid }
        do {
            let value = try await response(request(vaultURL("/vault/pdf",path:path)),as:VaultPDFSnapshot.self,
                maxBytes:(VaultPDFSnapshot.byteLimit + 2) / 3 * 4 + 8192)
            _ = try value.bytes(at:path)
            return value
        } catch let error as NSError where error.domain == "CanvasRelay" {
            switch error.code {
            case 404: throw VaultPDFError.missing
            case 409: throw VaultPDFError.changed
            case 413: throw VaultPDFError.tooLarge
            case 400: throw VaultPDFError.invalid
            default: throw VaultPDFError.unavailable
            }
        }
    }

    func createVaultNote(at path: String, text: String) async throws -> VaultNote {
        guard VaultNoteReference.validPath(path), text.utf8.count <= 1024 * 1024 else { throw URLError(.badURL) }
        let body = try JSONSerialization.data(withJSONObject:["baseSha256":NSNull(),"text":text])
        let saved = try await response(request(vaultURL("/vault/note",path:path),method:"PUT",body:body),
                                       as:VaultNote.self).validated(at:path)
        guard saved.text.utf8.elementsEqual(text.utf8) else { throw URLError(.badServerResponse) }
        return saved
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
        try scene.requireCompatibleNodeKinds()
        try await requireSceneSupport(scene)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sceneBytes = try encoder.encode(scene)
        let body = try JSONSerialization.data(withJSONObject:[
            "revision":scene.revision,
            "baseSha256":(baseSha256 as Any?) ?? NSNull(),
            "sceneJSONBase64":sceneBytes.base64EncodedString(),
            "imagePNGBase64":imagePNG.base64EncodedString()
        ],options:[.withoutEscapingSlashes])
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

    private func requireSceneSupport(_ scene: CanvasScene) async throws {
        try scene.requireCompatibleNodeKinds()
        if scene.schemaVersion == 3 {
            let capability = try await response(request("/vault/canvas/capabilities"), as:CanvasSceneCapabilities.self)
            try capability.require(scene)
        }
        try Task.checkCancellation()
    }

    func send(_ packet: CanvasPacket) async throws -> PacketReceipt {
        let scene = try packet.frozenScene()
        try await requireSceneSupport(scene)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try await response(request("/packets",method:"POST",body:encoder.encode(packet)),as:PacketReceipt.self)
    }

    func receipt(for packet: UUID) async throws -> PacketReceipt {
        try await response(request("/packets/\(packet.uuidString.lowercased())/receipt"),as:PacketReceipt.self)
    }

    func revision(for packet: UUID) async throws -> AgentRevision? {
        try await response(request("/packets/\(packet.uuidString.lowercased())/revision"),
                           as:AgentRevision?.self)
    }
}
