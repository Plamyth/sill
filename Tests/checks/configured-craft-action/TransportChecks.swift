import Foundation
import Darwin
import StreamProtocol

final class Flags: @unchecked Sendable {
    let lock = NSLock()
    private var liveValue = true, protectedValue = false
    var live: Bool { lock.lock(); defer { lock.unlock() }; return liveValue }
    var protected: Bool { lock.lock(); defer { lock.unlock() }; return protectedValue }
    func change(live: Bool? = nil, protected: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let live { liveValue = live }; if let protected { protectedValue = protected }
    }
}
// Inert identity seam only. The production socket source is compiled unchanged.
struct ProviderPeerPolicy { static let core = Self() }
enum ProviderPeerAnchor {
    static let lock = NSLock()
    static var calls = 0
    static var beforeWrite: (() -> Void)?
    static func reset(_ hook: (() -> Void)? = nil) { lock.lock(); calls = 0; beforeWrite = hook; lock.unlock() }
    static func verify(_ fd: Int32, policy: ProviderPeerPolicy) throws -> [String: Any] {
        guard fd >= 0 else { throw ProviderCallFailure.unavailable }
        lock.lock(); calls += 1; let hook = calls == 2 ? beforeWrite : nil; lock.unlock()
        hook?(); return [:]
    }
}

final class FakeCore: @unchecked Sendable {
    let fd: Int32, path: String
    let queue = DispatchQueue(label: "independent.fake.core")
    let lock = NSLock()
    var captured: [String: Any]?
    var observed: [String: Any]? { lock.lock(); defer { lock.unlock() }; return captured }
    init(path: String, respond: @escaping ([String: Any]) throws -> Data) throws {
        self.path = path; fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ProviderCallFailure.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + Array(repeating: 0, count: $0.count - bytes.count)) }
        let bound = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { throw ProviderCallFailure.unavailable }
        queue.async { [self] in
            let client = accept(fd, nil, nil); guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var data = Data(), byte: UInt8 = 0
            while recv(client, &byte, 1, 0) == 1, byte != 10 { data.append(byte) }
            guard let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lock.lock(); captured = command; lock.unlock()
            if var reply = try? respond(command) {
                reply.append(10); _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            }
            _ = shutdown(client, SHUT_WR)
        }
    }
    func close() { shutdown(fd, SHUT_RDWR); Darwin.close(fd); queue.sync {}; unlink(path) }
}

@main struct TransportChecks {
    static var count = 0, regressions = 0
    static let peer = AudioForwardingDeviceID(hex: String(repeating: "ab", count: 32))!
    static let hash = String(repeating: "a", count: 64)
    static let profile = UUID(uuidString: "11234567-89ab-4cde-8fab-0123456789ab")!
    static func check(_ name: String, _ value: Bool) {
        count += 1; if !value { regressions += 1 }
        print("\(value ? "PASS" : "FAIL") \(name)")
    }
    static func json(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
    static func obj(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }
    static func catalog() throws -> ConfiguredCraftActionCatalog { try .init(expectedProfileId: profile, expectedAssignmentSha256: hash) }
    static func invoke(_ id: UUID = UUID()) throws -> ConfiguredCraftActionControl {
        .init(requestId: UUID(), client: try .init(operationId: id, deviceId: peer, catalog: catalog(), issuedAt: 1793910000000))
    }
    static func snapshot(revision: UInt64 = 1) throws -> AudioForwardingSnapshot {
        let g = profile
        let config = try AudioForwardingConfiguration(controllerBootId: g, privacyGeneration: g, registryRevision: .init(1), members: [.init(participantId: "native.sill", bootId: g), .init(participantId: "s23.audio.relay", bootId: g)])
        let intent = try AudioForwardingSnapshot.Intent(pairedDeviceId: peer, intentId: g, intentRevision: .init(1), intentGeneration: g, inputDesired: false, outputDesired: false)
        let binding = AudioForwardingBinding(pairedDeviceId: peer, intentGeneration: g, bindingEpoch: g, transportId: g, transportKind: .native, operationId: g, phase: .off, configuration: config)
        return try .init(revision: .init(revision), intent: intent, binding: binding)
    }
    @MainActor static func session(_ flags: Flags = Flags(), generation: UUID = profile, sessionID: UUID = UUID()) throws -> HostConfiguredCraftSession {
        let snap = try snapshot()
        return .init(deviceId: peer, deviceSessionId: sessionID, pairingGeneration: generation, sentryProtected: { flags.protected }, isCurrent: { flags.live }, readSnapshot: { snap })
    }
    static func reply(_ c: [String: Any], outcome: String = "unknown", reason: String? = nil) throws -> Data {
        let body = c["client"] as? [String: Any]
        let operation = body?["operationId"] ?? c["operationId"]!
        var result: [String: Any] = ["outcome":outcome, "operationId":operation, "deviceId":c["deviceId"]!, "bindingSha256":NSNull(), "invoked":outcome == "invoked", "effectConfirmed":false]
        if let reason { result["reason"] = reason }
        return try json(["op":"configuredCraftAction.reply", "schemaVersion":1, "requestId":c["requestId"]!, "outcome":"ok", "actionResult":result])
    }
    @MainActor static func main() async throws {
        let dir = CommandLine.arguments[1]
        for mode in ["ownership_before_write", "sentry_before_write", "exponent_schema", "fraction_schema", "duplicate_schema", "invalid_json", "nested_reason", "valid", "legacy_exponent"] {
            let flags = Flags()
            ProviderPeerAnchor.reset(mode == "ownership_before_write" ? { flags.change(live:false) } : mode == "sentry_before_write" ? { flags.change(protected:true) } : nil)
            let core = try FakeCore(path:dir + "/c.sock") { c in
                let body = c["client"] as? [String: Any]
                let id = body?["operationId"] ?? c["operationId"]!
                let result: [String: Any] = ["outcome":"invoked", "operationId":id, "deviceId":c["deviceId"]!,
                    "bindingSha256":hash, "invoked":true, "effectConfirmed":false,
                    "reason":"executor-submitted-result-unknown"]
                let good = try json(["op":"configuredCraftAction.reply", "schemaVersion":1, "requestId":c["requestId"]!, "outcome":"ok", "actionResult":result])
                let text = String(data:good,encoding:.utf8)!
                switch mode {
                case "exponent_schema", "legacy_exponent": return Data(text.replacingOccurrences(of:"\"schemaVersion\":1",with:"\"schemaVersion\":1e0").utf8)
                case "fraction_schema": return Data(text.replacingOccurrences(of:"\"schemaVersion\":1",with:"\"schemaVersion\":1.0").utf8)
                case "duplicate_schema": return Data(text.replacingOccurrences(of:"\"schemaVersion\":1",with:"\"schemaVersion\":1,\"schemaVersion\":1").utf8)
                case "invalid_json": return Data("{broken}".utf8)
                default: return good
                }
            }
            if mode == "legacy_exponent" {
                struct LegacyReply: Decodable { let schemaVersion: Int }
                let socket = try await ProviderCallSocket.open(path:core.path,until:ProcessInfo.processInfo.systemUptime+1)
                let control = try invoke()
                let command = HostConfiguredCraftCommand(control:control,operation:.invoke,deviceId:peer,deviceSessionId:UUID(),acceptedAt:1793910000010)
                let result = try await socket.exchange(command,as:LegacyReply.self,until:ProcessInfo.processInfo.systemUptime+2)
                socket.invalidate()
                check("legacy generic provider JSON semantics unchanged",result.schemaVersion == 1)
            } else {
                let runtime = HostConfiguredCraftRuntime(open:{ deadline in try await ProviderCallSocket.open(path:core.path,until:deadline,frameLimit:16385) })
                let result = await runtime.exchange(try invoke(),session:try session(flags))
                if mode == "ownership_before_write" || mode == "sentry_before_write" {
                    check("actual first write blocks \(mode)", core.observed == nil)
                } else if ["exponent_schema","fraction_schema","duplicate_schema","invalid_json"].contains(mode) {
                    check("raw Core reply rejected without success: \(mode)",result == nil)
                } else {
                    check("valid Core result and nested reason preserved",result?.result?.outcome == .invoked && result?.result?.reason == "executor-submitted-result-unknown")
                }
                print("OBS \(mode) CoreFrameReceived=\(core.observed != nil) response=\(result?.result?.outcome.rawValue ?? result?.error ?? "nil")")
            }
            core.close()
        }
        print("TRANSPORT checks=\(count) failures=\(regressions); actual Core/Craft effects=0")
        exit(regressions == 0 ? 0 : 1)
    }
}
