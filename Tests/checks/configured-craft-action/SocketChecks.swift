import Foundation
import Darwin
import StreamProtocol

// This executable links an inert peer verifier; production peer verification runs separately.
struct ProviderPeerPolicy { static let core = Self() }
enum ProviderPeerAnchor {
    static func verify(_ fd: Int32, policy: ProviderPeerPolicy) throws -> [String: Any] {
        guard fd >= 0 else { throw ProviderCallFailure.unavailable }
        return [:]
    }
}

final class CraftSocketCore: @unchecked Sendable {
    let fd: Int32
    let path: String
    let queue = DispatchQueue(label: "configured-craft.fake-core")
    let lock = NSLock()
    var commands: [[String: Any]] = []
    var captured: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return commands }
    init(_ path: String) throws {
        self.path = path; fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ProviderCallFailure.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + Array(repeating: 0, count: $0.count - bytes.count)) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { throw ProviderCallFailure.unavailable }
        queue.async { [self] in
            for _ in 0..<3 {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var data = Data(), byte: UInt8 = 0
                while recv(client, &byte, 1, 0) == 1, byte != 10 { data.append(byte) }
                guard let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { Darwin.close(client); return }
                lock.lock(); commands.append(command); lock.unlock()
                var reply: [String: Any] = ["op":"configuredCraftAction.reply", "schemaVersion":1,
                    "requestId":command["requestId"]!, "outcome":"ok"]
                if command["op"] as? String == "configuredCraftAction.catalog" {
                    reply["catalog"] = ["schemaVersion":1,"supported":true,"expectedProfileId":"11234567-89ab-4cde-8fab-0123456789ab",
                        "inputID":"speed.button.stop-play","trigger":"longPress","expectedAssignmentSha256":String(repeating:"a",count:64)]
                } else {
                    let clientBody = command["client"] as? [String:Any]
                    reply["actionResult"] = ["outcome":"unknown", "operationId":clientBody?["operationId"] ?? command["operationId"]!,
                        "deviceId":command["deviceId"]!,"bindingSha256":NSNull(),"invoked":false,"effectConfirmed":false]
                }
                if var bytes = try? JSONSerialization.data(withJSONObject: reply) {
                    bytes.append(10)
                    _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                }
                var end: UInt8 = 0
                _ = recv(client, &end, 1, 0)
                Darwin.close(client)
            }
        }
    }
    func close() { shutdown(fd, SHUT_RDWR); Darwin.close(fd); queue.sync {}; unlink(path) }
}

@main struct SocketChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let core = try CraftSocketCore(directory.appendingPathComponent("c.sock").path)
        defer { core.close() }
        let peer = AudioForwardingDeviceID(hex: String(repeating:"ab",count:32))!, sessionID = UUID()
        let runtime = HostConfiguredCraftRuntime(open: { deadline in
            try await ProviderCallSocket.open(path: core.path, until: deadline, frameLimit: 16385)
        })
        let session = HostConfiguredCraftSession(deviceId: peer, deviceSessionId: sessionID, pairingGeneration: UUID(),
            sentryProtected: { false }, isCurrent: { true }, readSnapshot: {
                let generation = sessionID
                let configuration = try! AudioForwardingConfiguration(controllerBootId: generation, privacyGeneration: generation,
                    registryRevision: .init(1), members: [
                        .init(participantId: "native.sill", bootId: generation), .init(participantId: "s23.audio.relay", bootId: generation)])
                let intent = try! AudioForwardingSnapshot.Intent(pairedDeviceId: peer, intentId: generation,
                    intentRevision: .init(1), intentGeneration: generation, inputDesired: false, outputDesired: false)
                let binding = AudioForwardingBinding(pairedDeviceId: peer, intentGeneration: generation, bindingEpoch: generation,
                    transportId: generation, transportKind: .native, operationId: generation, phase: .off, configuration: configuration)
                return try! AudioForwardingSnapshot(revision: .init(1), intent: intent, binding: binding)
            })
        let catalog = await runtime.exchange(ConfiguredCraftActionControl(requestId: UUID()), session: session)
        precondition(catalog?.catalog?.supported == true, "catalog fixture failed: \(catalog?.error ?? "no reply")")
        let op = UUID()
        let request = try ConfiguredCraftActionRequest(operationId: op, deviceId: peer, catalog: catalog!.catalog!,
                                                       issuedAt: Int64(Date().timeIntervalSince1970 * 1000))
        let invoked = await runtime.exchange(ConfiguredCraftActionControl(requestId: UUID(), client: request), session: session)
        precondition(invoked?.result?.outcome == .unknown)
        let query = await runtime.exchange(ConfiguredCraftActionControl(requestId: UUID(), operationId: op), session: session)
        precondition(query?.result?.outcome == .unknown && query?.result?.operationId == op)
        let commands = core.captured
        precondition(commands.count == 3)
        for command in commands {
            precondition(command["deviceId"] as? String == peer.hex && command["deviceSessionId"] as? String == sessionID.uuidString.lowercased())
            precondition(command["acceptedAt"] as? Int64 != nil)
            let op = command["op"] as! String
            let keys: Set<String> = ["op", "schemaVersion", "requestId", "deviceId", "deviceSessionId", "acceptedAt"]
            precondition(Set(command.keys) == keys.union(op.hasSuffix(".invoke") ? ["client", "sentryState"] : op.hasSuffix(".query") ? ["operationId"] : []))
        }
        print("production ProviderCallSocket + runtime: 3 isolated fake Core exchanges passed; inert identity seam; actual Core/Craft effects=0")
    }
}
