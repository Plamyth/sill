import Foundation
import Security

struct CanvasRelay {
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
        guard let http = raw as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String:String])?["error"]
            throw NSError(domain:"CanvasRelay",code:1,userInfo:[NSLocalizedDescriptionKey:message ?? "Mac 수신 오류"])
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
