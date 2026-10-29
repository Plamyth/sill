import Foundation
import Security
import ImageIO
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
    struct VaultCanvas: Codable {
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

    private func response<T: Decodable>(_ request: URLRequest, as type: T.Type, maxBytes: Int? = nil, maximumBytes: Int? = nil,
                                       limitError: Error = VaultPDFError.tooLarge, rejectReconciliation: Bool = false) async throws -> T {
        let data: Data, raw: URLResponse
        if let maxBytes {
            let (stream,response) = try await session.bytes(for:request)
            raw = response
            guard response.expectedContentLength <= maxBytes else { throw limitError }
            var bounded = Data()
            for try await byte in stream {
                guard bounded.count < maxBytes else { throw limitError }
                bounded.append(byte)
            }
            data = bounded
        } else {
            (data,raw) = try await session.data(for:request)
        }
        if let maximumBytes, data.count > maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
        guard let http = raw as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        let vault = request.url?.path.contains("/vault/") ?? false
        let required = body?["reconciliationRequired"] as? Bool
        let preserved = vault && (body?["code"] as? String == "note_reconciliation_required" || required == true)
        if !(200...299).contains(http.statusCode) || (preserved && (request.httpMethod != "GET" || rejectReconciliation)) {
            var info: [String:Any] = [NSLocalizedDescriptionKey:body?["error"] as? String ?? "Mac 수신 오류"]
            let status = preserved ? 409 : http.statusCode
            if vault && status == 409 {
                let document = ["/vault/document","/vault/document/conflict"].contains(request.url?.path ?? "")
                let knownPrepublication = !document || ["document_stale","document_page_loss","document_schema_downgrade"].contains(body?["code"] as? String ?? "")
                let kind: VaultSaveConflict = preserved ? .reconciliationRequired :
                    (required == false && body?["publicationAttempted"] as? Bool == false && knownPrepublication ? .prepublication : .unclassified)
                info[VaultSaveConflict.errorKey] = kind.rawValue
                if let recoveryID = body?["recoveryID"] as? String,
                   (document ? CanvasDocumentRelay.opaqueID(recoveryID) : UUID(uuidString:recoveryID) != nil) { info["CanvasRecoveryID"] = recoveryID }
                if let code = body?["code"] as? String { info["CanvasVaultErrorCode"] = code }
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

    private func documentCurrent(_ isCurrent: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func documentResponse<T: Decodable>(_ path: String, as type: T.Type, limit: Int,
                                                method: String = "GET", body: Data? = nil, conflictSummary: Bool = false) async throws -> T {
        try await response(request(path,method:method,body:body),as:type,maxBytes:limit,
                           limitError:CanvasDocumentRelay.Failure.tooLarge,rejectReconciliation:!conflictSummary)
    }

    /// 호출자의 연결 epoch·문서 snapshot 소유권을 매 비동기 경계에서 확인한다.
    func vaultDocument(id: UUID, isCurrent: @Sendable () async -> Bool) async throws -> CanvasDocumentRelay.Validated {
        try await documentCurrent(isCurrent)
        let bundle = try await documentResponse("/vault/document?id=\(id.uuidString.lowercased())",
            as:CanvasDocumentRelay.Bundle.self,limit:CanvasDocumentRelay.bundleLimit)
        try await documentCurrent(isCurrent)
        let validated = try bundle.validated(id:id)
        try await documentCurrent(isCurrent)
        return validated
    }

    /// 원본 bytes를 보내고 성공 요약과 전체 재열기를 대조한다. 자동 재시도·checkpoint 해제는 하지 않는다.
    func saveVaultDocument(documentJSON: Data, previews: [UUID:Data], base: CanvasDocumentRelay.Base?,
                           isCurrent: @Sendable () async -> Bool) async throws -> CanvasDocumentRelay.Validated {
        let (proposal,document,body) = try CanvasDocumentRelay.Put.make(bytes:documentJSON,previews:previews,base:base)
        try await documentCurrent(isCurrent)
        let capability = try await documentResponse("/vault/canvas/capabilities",as:CanvasDocumentRelay.Capabilities.self,limit:64*1024)
        try capability.require()
        try await documentCurrent(isCurrent)
        let saved = try await documentResponse("/vault/document?id=\(document.id.uuidString.lowercased())",
            as:CanvasDocumentRelay.Summary.self,limit:64*1024,method:"PUT",body:body)
        try await documentCurrent(isCurrent)
        try saved.matches(document,bytes:documentJSON,assets:proposal.pages.map(\.metadata))
        let reopened = try await vaultDocument(id:document.id,isCurrent:isCurrent)
        guard reopened.summary == saved, reopened.documentJSON == documentJSON, reopened.previews == previews else { throw CanvasDocumentRelay.Failure.invalid }
        try await documentCurrent(isCurrent)
        return reopened
    }

    func vaultDocumentConflict(id: UUID, isCurrent: @Sendable () async -> Bool) async throws -> CanvasDocumentRelay.Conflict {
        try await documentCurrent(isCurrent)
        let value = try await documentResponse("/vault/document/conflict?id=\(id.uuidString.lowercased())",
            as:CanvasDocumentRelay.Conflict.self,limit:CanvasDocumentRelay.conflictLimit,conflictSummary:true)
        try await documentCurrent(isCurrent)
        return try value.validated(id:id)
    }

    func vaultDocumentCandidate(_ conflict: CanvasDocumentRelay.Conflict, material: CanvasDocumentRelay.MaterialName,
                                isCurrent: @Sendable () async -> Bool) async throws -> CanvasDocumentRelay.Validated {
        guard let id = UUID(uuidString:conflict.id) else { throw CanvasDocumentRelay.Failure.invalid }
        _ = try conflict.validated(id:id)
        guard let selected = conflict.materials[material], selected.validDocument, let summary = selected.document else { throw CanvasDocumentRelay.Failure.invalid }
        var url = URLComponents(); url.path = "/vault/document/conflict"
        url.queryItems = [.init(name:"id",value:conflict.id),.init(name:"recoveryID",value:conflict.recoveryID),
                          .init(name:"material",value:material.rawValue),.init(name:"sha256",value:selected.sha256)]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        guard let path = url.string else { throw URLError(.badURL) }
        try await documentCurrent(isCurrent)
        let bundle = try await documentResponse(path,as:CanvasDocumentRelay.Bundle.self,limit:CanvasDocumentRelay.bundleLimit)
        try await documentCurrent(isCurrent)
        let validated = try bundle.validated(id:id)
        guard validated.summary == summary, validated.summary.noteSha256 == selected.sha256 else { throw CanvasDocumentRelay.Failure.invalid }
        try await documentCurrent(isCurrent)
        return validated
    }

    func resolveVaultDocumentConflict(_ conflict: CanvasDocumentRelay.Conflict, decision: ConflictDecision,
                                      candidate: CanvasDocumentRelay.Validated,
                                      isCurrent: @Sendable () async -> Bool) async throws -> CanvasDocumentRelay.Validated {
        guard let id = UUID(uuidString:conflict.id) else { throw CanvasDocumentRelay.Failure.invalid }
        _ = try conflict.validated(id:id)
        guard let selected = conflict.materials[conflict.chosen(decision)], selected.validDocument,
              selected.document == candidate.summary else { throw CanvasDocumentRelay.Failure.invalid }
        // candidate는 이미 모든 원문/PKDrawing/PNG를 검증한 읽기 결과다.
        let body = try CanvasDocumentRelay.encoder().encode(CanvasDocumentRelay.Resolve(recoveryID:conflict.recoveryID,expected:conflict.expected,decision:decision))
        guard body.count <= 16*1024 else { throw CanvasDocumentRelay.Failure.tooLarge }
        try await documentCurrent(isCurrent)
        let capability = try await documentResponse("/vault/canvas/capabilities",as:CanvasDocumentRelay.Capabilities.self,limit:64*1024)
        try capability.require()
        try await documentCurrent(isCurrent)
        let result = try await documentResponse("/vault/document/conflict?id=\(conflict.id)",as:CanvasDocumentRelay.Resolved.self,
            limit:64*1024,method:"PUT",body:body)
        try await documentCurrent(isCurrent)
        guard result.resolved, !result.reconciliationRequired, result.recoveryID.utf8.elementsEqual(conflict.recoveryID.utf8),
              result.decision == decision, result.summary == candidate.summary else { throw CanvasDocumentRelay.Failure.invalid }
        let reopened = try await vaultDocument(id:id,isCurrent:isCurrent)
        guard reopened.sameOriginals(as:candidate) else { throw CanvasDocumentRelay.Failure.invalid }
        try await documentCurrent(isCurrent)
        return reopened
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


extension CanvasRelay {
    enum ConflictDecision: String, Codable, CaseIterable, Identifiable {
        case keepCurrent, useDisplaced
        var id: String { rawValue }
        var title: String { self == .keepCurrent ? "현재 서버 원문 유지" : "보존된 외부 변경본 선택" }
    }
    struct ConflictExpected: Codable, Equatable {
        let activeSha256: String?, baseSha256: String?, displacedSha256: String?, proposalSha256: String?
        let historySha256: String
        enum CodingKeys: String, CodingKey, CaseIterable { case activeSha256, baseSha256, displacedSha256, proposalSha256, historySha256 }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy:CodingKeys.self)
            guard CodingKeys.allCases.allSatisfy({ c.contains($0) }) else { throw URLError(.badServerResponse) }
            activeSha256 = try c.decodeIfPresent(String.self,forKey:.activeSha256)
            baseSha256 = try c.decodeIfPresent(String.self,forKey:.baseSha256)
            displacedSha256 = try c.decodeIfPresent(String.self,forKey:.displacedSha256)
            proposalSha256 = try c.decodeIfPresent(String.self,forKey:.proposalSha256)
            historySha256 = try c.decode(String.self,forKey:.historySha256)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy:CodingKeys.self)
            try c.encode(activeSha256,forKey:.activeSha256); try c.encode(baseSha256,forKey:.baseSha256)
            try c.encode(displacedSha256,forKey:.displacedSha256); try c.encode(proposalSha256,forKey:.proposalSha256)
            try c.encode(historySha256,forKey:.historySha256)
        }
    }
    struct ConflictMaterial: Codable {
        let sha256: String, markdownBase64: String
        let validCanvas: Bool
        let canvas: VaultCanvas?
        let imagePNGBase64: String?
        let refusal: String?
        var markdown: String { Data(base64Encoded:markdownBase64).flatMap { String(data:$0,encoding:.utf8) } ?? "UTF-8 원문으로 표시할 수 없습니다. 원본 바이트는 서버에 보존됩니다." }
        func validated(id: UUID, expected: String?) throws {
            guard expected == sha256, Self.hash(sha256), let raw = Data(base64Encoded:markdownBase64),
                  raw.count <= 1024*1024, CanvasPacket.sha(raw) == sha256 else { throw URLError(.badServerResponse) }
            if validCanvas { _ = try scene(id:id) }
            else { guard canvas == nil, imagePNGBase64 == nil, refusal?.isEmpty == false else { throw URLError(.badServerResponse) } }
        }
        static func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        func scene(id: UUID) throws -> CanvasScene {
            guard validCanvas, let c = canvas, let png = imagePNGBase64.flatMap({ Data(base64Encoded:$0) }),
                  png.count <= 5*1024*1024, png.starts(with:[137,80,78,71,13,10,26,10]),
                  Self.hash(c.sceneSha256), Self.hash(c.imageSha256), c.noteSha256 == sha256,
                  c.path == "CCR Canvas/\(id.uuidString.lowercased()).md",
                  CanvasPacket.sha(png) == c.imageSha256,
                  let source = CGImageSourceCreateWithData(png as CFData,nil), CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192,
                  CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                    kCGImageSourceThumbnailMaxPixelSize:1024,kCGImageSourceShouldCache:false] as CFDictionary) != nil,
                  let bytes = Data(base64Encoded:c.sceneJSONBase64), bytes.count <= CanvasScene.localByteLimit,
                  CanvasPacket.sha(bytes) == c.sceneSha256 else { throw URLError(.badServerResponse) }
            let scene = try JSONDecoder().decode(CanvasScene.self,from:bytes)
            guard scene.id == id, scene.revision == c.revision, scene.width > 0, scene.height > 0,
                  scene.nodes.count < 1000, scene.strokes.count < 10000, scene.nodes.allSatisfy(\.hasValidRotation) else { throw URLError(.badServerResponse) }
            try scene.requireCompatibleNodeKinds(); try scene.validateNativeInkProjection()
            return scene
        }
    }
    struct ConflictMaterials: Codable {
        let active: ConflictMaterial?, base: ConflictMaterial?, displaced: ConflictMaterial?, proposal: ConflictMaterial?
    }
    struct ConflictHistory: Codable {
        let recoveryID: UUID
        let files: [String:String?]
    }
    struct VaultConflict: Codable {
        let schema: String, id: UUID, recoveryID: UUID, code: String
        let reconciliationRequired: Bool, publicationAttempted: Bool
        let expected: ConflictExpected, materials: ConflictMaterials
        let history: [ConflictHistory]
        func selected(_ decision: ConflictDecision) -> ConflictMaterial? { decision == .keepCurrent ? materials.active : materials.displaced }
        func validated(id expectedID: UUID) throws -> Self {
            guard schema == "ccr.canvas-conflict/v1", id == expectedID, code == "note_reconciliation_required",
                  reconciliationRequired, ConflictMaterial.hash(expected.historySha256), history.count <= 32,
                  Set(history.map(\.recoveryID)).count == history.count,
                  history.allSatisfy({ $0.files.count <= 7 && $0.files.values.allSatisfy { $0.map(ConflictMaterial.hash) ?? true } }) else { throw URLError(.badServerResponse) }
            for (material,hash) in [(materials.active,expected.activeSha256),(materials.base,expected.baseSha256),
                                    (materials.displaced,expected.displacedSha256),(materials.proposal,expected.proposalSha256)] {
                if let material { try material.validated(id:id,expected:hash) }
                else if hash != nil { throw URLError(.badServerResponse) }
            }
            return self
        }
    }
    struct ConflictResolution: Decodable {
        let path: String, noteSha256: String, sceneSha256: String, imageSha256: String
        let revision: Int, recoveryID: UUID
        let decision: ConflictDecision
        let resolved: Bool, reconciliationRequired: Bool
    }
    private struct ConflictRequest: Encodable {
        let recoveryID: String, expected: ConflictExpected, decision: ConflictDecision
    }
    func vaultCanvasConflict(id: UUID) async throws -> VaultConflict {
        try await response(request("/vault/canvas/conflict?id=\(id.uuidString.lowercased())"),as:VaultConflict.self,
                           maximumBytes:64*1024*1024).validated(id:id)
    }
    func resolveVaultCanvasConflict(_ conflict: VaultConflict, decision: ConflictDecision) async throws -> (ConflictResolution,VaultCanvas) {
        _ = try conflict.validated(id:conflict.id)
        guard let material = conflict.selected(decision), let selected = material.canvas else { throw URLError(.cannotDecodeContentData) }
        _ = try material.scene(id:conflict.id)
        let body = try JSONEncoder().encode(ConflictRequest(recoveryID:conflict.recoveryID.uuidString.lowercased(),expected:conflict.expected,decision:decision))
        let result = try await response(request("/vault/canvas/conflict?id=\(conflict.id.uuidString.lowercased())",method:"PUT",body:body),as:ConflictResolution.self,maximumBytes:64*1024)
        guard result.resolved, !result.reconciliationRequired, result.recoveryID == conflict.recoveryID,
              result.decision == decision, result.path == selected.path, result.noteSha256 == selected.noteSha256,
              result.sceneSha256 == selected.sceneSha256, result.imageSha256 == selected.imageSha256,
              result.revision == selected.revision,
              let reopened = try await vaultCanvas(id:conflict.id), reopened.reconciliationRequired != true,
              reopened.path == result.path, reopened.noteSha256 == result.noteSha256,
              reopened.sceneSha256 == result.sceneSha256, reopened.imageSha256 == result.imageSha256,
              reopened.revision == result.revision, reopened.sceneJSONBase64 == selected.sceneJSONBase64 else { throw URLError(.badServerResponse) }
        let note = try await vaultNote(at:selected.path)
        guard note.reconciliationRequired != true, note.sha256 == selected.noteSha256,
              Data(note.text.utf8) == Data(base64Encoded:material.markdownBase64) else { throw URLError(.badServerResponse) }
        return (result,reopened)
    }
}


extension CanvasRelay {
    struct NoteConflictMaterial: Codable {
        let sha256: String, markdownBase64: String
        let validNote: Bool
        let refusal: String?
        var bytes: Data? { Data(base64Encoded:markdownBase64) }
        var markdown: String? {
            guard let bytes, String(data:bytes,encoding:.utf8) != nil else { return nil }
            // Validate strictly first; decoding preserves the original UTF-8 BOM as U+FEFF.
            return String(decoding:bytes,as:UTF8.self)
        }
        func validated(expected: String?) throws {
            guard sha256 == expected, ConflictMaterial.hash(sha256), let bytes,
                  bytes.count <= 1024*1024, CanvasPacket.sha(bytes) == sha256 else { throw URLError(.badServerResponse) }
            if validNote {
                guard let markdown, !CanvasRelay.managedCanvasMarkdown(markdown) else { throw URLError(.cannotDecodeContentData) }
            } else if refusal?.isEmpty != false { throw URLError(.badServerResponse) }
        }
    }
    static func ordinaryNotePath(_ path: String) -> Bool {
        VaultNoteReference.validPath(path) &&
        path.precomposedStringWithCanonicalMapping.split(separator:"/").first?.lowercased() != "ccr canvas"
    }
    private static func managedCanvasMarkdown(_ text: String) -> Bool {
        let probe = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        guard probe.hasPrefix("---\n") || probe.hasPrefix("---\r\n") else { return false }
        let lines = probe.components(separatedBy:.newlines)
        for line in lines.dropFirst() {
            if line == "---" { break }
            if ["ccr_scene_id:","ccr_scene_sha256:","ccr_image_sha256:"].contains(where:{ line.trimmingCharacters(in:.whitespaces).lowercased().hasPrefix($0) }) { return true }
        }
        return false
    }
    struct NoteConflictMaterials: Codable {
        let active: NoteConflictMaterial?, base: NoteConflictMaterial?, displaced: NoteConflictMaterial?, proposal: NoteConflictMaterial?
        enum CodingKeys: String, CodingKey, CaseIterable { case active, base, displaced, proposal }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy:CodingKeys.self)
            guard CodingKeys.allCases.allSatisfy({ c.contains($0) }) else { throw URLError(.badServerResponse) }
            active = try c.decodeIfPresent(NoteConflictMaterial.self,forKey:.active)
            base = try c.decodeIfPresent(NoteConflictMaterial.self,forKey:.base)
            displaced = try c.decodeIfPresent(NoteConflictMaterial.self,forKey:.displaced)
            proposal = try c.decodeIfPresent(NoteConflictMaterial.self,forKey:.proposal)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy:CodingKeys.self)
            try c.encode(active,forKey:.active); try c.encode(base,forKey:.base)
            try c.encode(displaced,forKey:.displaced); try c.encode(proposal,forKey:.proposal)
        }
    }
    struct NoteConflict: Codable {
        let schema: String, path: String, recoveryID: UUID, code: String
        let reconciliationRequired: Bool, publicationAttempted: Bool
        let expected: ConflictExpected, materials: NoteConflictMaterials
        let history: [ConflictHistory]
        func selected(_ decision: ConflictDecision) -> NoteConflictMaterial? { decision == .keepCurrent ? materials.active : materials.displaced }
        func validated(path expectedPath: String) throws -> Self {
            guard schema == "ccr.note-conflict/v1", path.utf8.elementsEqual(expectedPath.utf8), CanvasRelay.ordinaryNotePath(path),
                  code == "note_reconciliation_required", reconciliationRequired, ConflictMaterial.hash(expected.historySha256),
                  history.count <= 32, Set(history.map(\.recoveryID)).count == history.count,
                  history.allSatisfy({ $0.files.count <= 7 && $0.files.values.allSatisfy { $0.map(ConflictMaterial.hash) ?? true } }) else { throw URLError(.badServerResponse) }
            for (m,h) in [(materials.active,expected.activeSha256),(materials.base,expected.baseSha256),
                          (materials.displaced,expected.displacedSha256),(materials.proposal,expected.proposalSha256)] {
                if let m { try m.validated(expected:h) } else if h != nil { throw URLError(.badServerResponse) }
            }
            return self
        }
    }
    struct NoteConflictResolved: Decodable {
        let path: String, sha256: String, recoveryID: UUID
        let decision: ConflictDecision
        let resolved: Bool, reconciliationRequired: Bool
    }
    func vaultNoteConflict(path: String) async throws -> NoteConflict {
        guard Self.ordinaryNotePath(path) else { throw URLError(.badURL) }
        return try await response(request(vaultURL("/vault/note/conflict",path:path)),as:NoteConflict.self,
                                  maximumBytes:8*1024*1024).validated(path:path)
    }
    func resolveVaultNoteConflict(_ conflict: NoteConflict,decision: ConflictDecision) async throws -> VaultNoteSnapshot {
        _ = try conflict.validated(path:conflict.path)
        guard let chosen = conflict.selected(decision), chosen.validNote, chosen.markdown != nil, let selectedBytes = chosen.bytes else { throw URLError(.cannotDecodeContentData) }
        let body = try JSONEncoder().encode(ConflictRequest(recoveryID:conflict.recoveryID.uuidString.lowercased(),expected:conflict.expected,decision:decision))
        let result = try await response(request(vaultURL("/vault/note/conflict",path:conflict.path),method:"PUT",body:body),as:NoteConflictResolved.self,maximumBytes:64*1024)
        guard result.path.utf8.elementsEqual(conflict.path.utf8), result.recoveryID == conflict.recoveryID, result.decision == decision,
              result.resolved, !result.reconciliationRequired, result.sha256 == chosen.sha256 else { throw URLError(.badServerResponse) }
        let reopened = try await vaultNote(at:conflict.path)
        guard reopened.path.utf8.elementsEqual(conflict.path.utf8), reopened.reconciliationRequired != true, reopened.sha256 == result.sha256,
              Data(reopened.text.utf8) == selectedBytes else { throw URLError(.badServerResponse) }
        return reopened
    }
}
