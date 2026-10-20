import Foundation
import Darwin

struct LocalAudioRelayRuntimeExpectation {
    let python: String
    let router: String
    var port: Int = 17648
}

enum LocalAudioRelayJSON {
    static let limit = 16_384

    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count < limit, !data.starts(with: [0xEF, 0xBB, 0xBF]),
              String(data: data, encoding: .utf8) != nil,
              try JSONSerialization.jsonObject(with: data) is [String: Any] else { throw Failure.invalid }
        var scan = Scanner(bytes: Array(data))
        try scan.value(depth: 0)
        scan.space()
        guard scan.offset == scan.bytes.count else { throw Failure.invalid }
    }

    enum Failure: Error { case invalid }

    private struct Scanner {
        let bytes: [UInt8]
        var offset = 0

        mutating func space() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }

        mutating func string() throws -> String {
            let start = offset
            offset += 1
            while offset < bytes.count {
                if bytes[offset] == 34 {
                    offset += 1
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
                }
                offset += bytes[offset] == 92 ? 2 : 1
            }
            throw Failure.invalid
        }

        mutating func value(depth: Int) throws {
            space()
            guard depth < 64, offset < bytes.count else { throw Failure.invalid }
            switch bytes[offset] {
            case 34: _ = try string()
            case 123:
                offset += 1
                space()
                var keys = Set<String>()
                if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
                while offset < bytes.count {
                    space()
                    guard bytes[offset] == 34, keys.insert(try string()).inserted else { throw Failure.invalid }
                    space()
                    guard bytes[offset] == 58 else { throw Failure.invalid }
                    offset += 1
                    try value(depth: depth + 1)
                    space()
                    if bytes[offset] == 125 { offset += 1; return }
                    guard bytes[offset] == 44 else { throw Failure.invalid }
                    offset += 1
                }
                throw Failure.invalid
            case 91:
                offset += 1
                space()
                if offset < bytes.count, bytes[offset] == 93 { offset += 1; return }
                while offset < bytes.count {
                    try value(depth: depth + 1)
                    space()
                    if bytes[offset] == 93 { offset += 1; return }
                    guard bytes[offset] == 44 else { throw Failure.invalid }
                    offset += 1
                }
                throw Failure.invalid
            default:
                while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            }
        }
    }
}

@MainActor
final class LocalAudioRelay {
    private enum State { case idle, bootstrapping, checkingRuntime(UUID), connected(UUID), closed }
    private struct Empty: Codable {}
    private struct Inspection: Encodable { let operationId: UUID }
    private struct Runtime: Decodable {
        let runtimeVersion: Int
        let serverListening: Bool
        let address: String
        let port: Int
        let python: String
        let router: String
        let pythonArguments: [String]
        enum CodingKeys: String, CodingKey, CaseIterable {
            case runtimeVersion, serverListening, address, port, python, router, pythonArguments
        }
        init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: AnyKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw LocalAudioRelayJSON.Failure.invalid
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeVersion = try c.decode(Int.self, forKey: .runtimeVersion)
            serverListening = try c.decode(Bool.self, forKey: .serverListening)
            address = try c.decode(String.self, forKey: .address)
            port = try c.decode(Int.self, forKey: .port)
            python = try c.decode(String.self, forKey: .python)
            router = try c.decode(String.self, forKey: .router)
            pythonArguments = try c.decode([String].self, forKey: .pythonArguments)
        }
    }
    private struct Bootstrap: Decodable {
        let participantId: LocalAudioParticipantID
        let capabilities: [String]
        enum CodingKeys: String, CodingKey, CaseIterable { case participantId, capabilities }
        init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: AnyKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw LocalAudioRelayJSON.Failure.invalid
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            participantId = try c.decode(LocalAudioParticipantID.self, forKey: .participantId)
            capabilities = try c.decode([String].self, forKey: .capabilities)
        }
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private struct Request<Payload: Encodable>: Encodable {
        let schemaVersion = 1
        let controllerBootId: UUID
        let sequence: String
        let requestId: UUID
        let method: String
        let payload: Payload
    }
    private struct Reply<Result: Decodable>: Decodable {
        let schemaVersion: Int
        let controllerBootId: UUID
        let sequence: String
        let requestId: UUID
        let relayBootId: UUID
        let processId: Int32
        let result: Result
        enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion, controllerBootId, sequence, requestId, relayBootId, processId, result
        }
        init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: AnyKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw LocalAudioRelayJSON.Failure.invalid
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            controllerBootId = try c.decode(UUID.self, forKey: .controllerBootId)
            sequence = try c.decode(String.self, forKey: .sequence)
            requestId = try c.decode(UUID.self, forKey: .requestId)
            relayBootId = try c.decode(UUID.self, forKey: .relayBootId)
            processId = try c.decode(Int32.self, forKey: .processId)
            result = try c.decode(Result.self, forKey: .result)
        }
    }
    private struct Pending {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let completion: CheckedContinuation<Data?, Never>
        let timer: Task<Void, Never>
    }

    private let participants: LocalAudioParticipantRegistry
    private let process: Process
    private let validateLaunch: () -> Bool
    private let packagedRuntime: LocalAudioRelayRuntimeExpectation?
    private let forwarding: Bool
    private let input = Pipe()
    private let output = Pipe()
    private let writer = DispatchQueue(label: "ccr.audio-relay.control.write")
    private let controllerBootId = UUID()
    private var state = State.idle
    private var buffer = Data()
    private var pending: Pending?
    private var sequence: UInt64 = 0
    private var busy = false
    private var registeredBoot: UUID?

    init(participants: LocalAudioParticipantRegistry, process: Process,
         packagedRuntime: LocalAudioRelayRuntimeExpectation? = nil, forwarding: Bool = false,
         validateLaunch: @escaping () -> Bool) {
        self.participants = participants
        self.process = process
        self.validateLaunch = validateLaunch
        self.packagedRuntime = packagedRuntime
        self.forwarding = forwarding
    }

    func start() async -> Bool {
        guard case .idle = state, !forwarding || packagedRuntime != nil, validateLaunch() else { return false }
        state = .bootstrapping
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.lost() } }
        do { try process.run() } catch { lost(); return false }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        guard validateLaunch() else { lost(); return false }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            var bytes = [UInt8](repeating: 0, count: LocalAudioRelayJSON.limit + 1)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { return }
            let chunk = count > 0 ? Data(bytes.prefix(count)) : nil
            Task { @MainActor in
                guard let self else { return }
                guard let chunk, !chunk.isEmpty else { self.lost(); return }
                self.receive(chunk)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard let reply: Reply<Bootstrap> = await call("bootstrap", payload: Empty(), until: deadline),
              reply.result.participantId == .relay,
              reply.result.capabilities == (["quiesce-v1", "inspect-v1"] +
                  (packagedRuntime == nil ? [] : ["runtime-v1"]) +
                  (forwarding ? ["forwarding-v1"] : [])) else { lost(); return false }
        guard case .bootstrapping = state, !Task.isCancelled, process.isRunning else { lost(); return false }
        if let expected = packagedRuntime {
            state = .checkingRuntime(reply.relayBootId)
            guard let runtime: Reply<Runtime> = await call("inspectRuntime", payload: Empty(), until: deadline),
                  runtime.result.runtimeVersion == 1, runtime.result.serverListening,
                  runtime.result.address == "127.0.0.1", runtime.result.port == expected.port,
                  runtime.result.python == expected.python, runtime.result.router == expected.router,
                  runtime.result.pythonArguments == ["-I", "-B"], validateLaunch(),
                  !Task.isCancelled, process.isRunning else { lost(); return false }
            guard case .checkingRuntime = state else { lost(); return false }
        }
        state = .connected(reply.relayBootId)
        registeredBoot = reply.relayBootId
        participants.register(.relay, bootId: reply.relayBootId, control: .init(fenceAndQuiesce: { [weak self] request in
            guard let self else { return .init(request, state: .unknown, facts: .unknown) }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(request.budgetMilliseconds))
            guard let reply: Reply<LocalAudioParticipantReceipt> = await self.call("fenceAndQuiesce", payload: request, until: deadline),
                  reply.result.proves(request) else {
                self.lost()
                return .init(request, state: .unknown, facts: .unknown)
            }
            return reply.result
        }, inspect: { [weak self] operationId in
            guard let self else { return nil }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            guard let reply: Reply<LocalAudioParticipantReceipt?> = await self.call("inspect", payload: Inspection(operationId: operationId), until: deadline) else {
                return nil
            }
            return reply.result
        }))
        if case .connected = state, participants.snapshot.boots[.relay] == reply.relayBootId { return true }
        if participants.snapshot.boots[.relay] == reply.relayBootId { participants.unregister(.relay) }
        lost()
        return false
    }

    func forwardingRegister(_ peer: AudioForwardingPairedDevice) async -> AudioForwardingResult<AudioForwardingCredential>? {
        struct Registration: Encodable { let pairedDeviceId: AudioForwardingDeviceID; let pairingGeneration: UUID }
        let result: AudioForwardingResult<AudioForwardingCredential>? = await forwardingCall("forwardingRegister",
            payload: Registration(pairedDeviceId: peer.id, pairingGeneration: peer.pairingGeneration))
        if case .accepted(let credential) = result,
           credential.pairedDeviceId != peer.id || credential.pairingGeneration != peer.pairingGeneration {
            lost(); return nil
        }
        return result
    }

    func forwardingConfigure(privacyGeneration: UUID) async -> AudioForwardingResult<AudioForwardingSnapshot>? {
        let membership = participants.snapshot
        guard let configuration = try? AudioForwardingConfiguration(controllerBootId: controllerBootId,
            privacyGeneration: privacyGeneration, membership: membership) else { return nil }
        let result: AudioForwardingResult<AudioForwardingSnapshot>? = await forwardingCall("forwardingConfigure", payload: configuration)
        guard participants.matches(membership) else { lost(); return nil }
        return result
    }

    func forwardingSnapshot() async -> AudioForwardingResult<AudioForwardingSnapshot>? {
        await forwardingCall("forwardingSnapshot", payload: Empty())
    }

    func forwardingRequest(_ intent: AudioForwardingIntentRequest, peer: AudioForwardingPairedDevice,
                           credential: AudioForwardingCredential) async -> AudioForwardingResult<AudioForwardingSnapshot>? {
        struct Submission: Encodable {
            let pairedDeviceId: AudioForwardingDeviceID
            let credential: String
            let intent: AudioForwardingIntentRequest
        }
        guard intent.transportKind == .native, intent.pairedDeviceId == peer.id,
              credential.pairedDeviceId == peer.id, credential.pairingGeneration == peer.pairingGeneration else { return nil }
        return await forwardingCall("forwardingRequest",
            payload: Submission(pairedDeviceId: peer.id, credential: credential.credential, intent: intent))
    }

    func forwardingPrepare(_ binding: AudioForwardingBinding) async -> AudioForwardingResult<LocalAudioParticipantReceipt>? {
        struct Preparation: Encodable { let intentGeneration: UUID; let bindingEpoch: UUID }
        let membership = participants.snapshot
        guard let configuration = try? AudioForwardingConfiguration(controllerBootId: controllerBootId,
            privacyGeneration: binding.configuration.privacyGeneration, membership: membership),
              binding.configuration == configuration,
              let expected = binding.participantRequest(for: .relay, budgetMilliseconds: 2000) else { return nil }
        let result: AudioForwardingResult<LocalAudioParticipantReceipt>? = await forwardingCall("forwardingPrepare",
            payload: Preparation(intentGeneration: binding.intentGeneration, bindingEpoch: binding.bindingEpoch))
        guard participants.matches(membership) else { lost(); return nil }
        if case .accepted(let receipt) = result, !receipt.proves(expected) { lost(); return nil }
        return result
    }

    func forwardingDisconnect(_ binding: AudioForwardingBinding) async -> AudioForwardingResult<AudioForwardingSnapshot>? {
        struct Disconnection: Encodable { let bindingEpoch: UUID }
        return await forwardingCall("forwardingDisconnect", payload: Disconnection(bindingEpoch: binding.bindingEpoch))
    }

    func forwardingRevoke(_ peer: AudioForwardingPairedDevice) async -> AudioForwardingResult<AudioForwardingSnapshot>? {
        struct Revocation: Encodable { let pairedDeviceId: AudioForwardingDeviceID }
        return await forwardingCall("forwardingRevoke", payload: Revocation(pairedDeviceId: peer.id))
    }

    private func forwardingCall<Payload: Encodable, Result: Decodable>(_ method: String,
        payload: Payload) async -> AudioForwardingResult<Result>? {
        guard forwarding, case .connected = state else { return nil }
        let reply: Reply<AudioForwardingResult<Result>>? = await call(method, payload: payload,
            until: ContinuousClock.now.advanced(by: .seconds(3)))
        return reply?.result
    }

    private func call<Payload: Encodable, Result: Decodable>(_ method: String, payload: Payload,
                                                           until deadline: ContinuousClock.Instant) async -> Reply<Result>? {
        guard !Task.isCancelled, !busy, sequence < UInt64.max, process.isRunning, ContinuousClock.now < deadline else {
            lost(); return nil
        }
        let expectedBoot: UUID?
        switch state {
        case .bootstrapping: guard method == "bootstrap" else { lost(); return nil }; expectedBoot = nil
        case .checkingRuntime(let boot): guard method == "inspectRuntime" else { lost(); return nil }; expectedBoot = boot
        case .connected(let boot): expectedBoot = boot
        case .idle, .closed: return nil
        }
        busy = true
        defer { busy = false }
        sequence += 1
        let requestId = UUID(), expectedSequence = String(sequence)
        let request = Request(controllerBootId: controllerBootId, sequence: expectedSequence,
                              requestId: requestId, method: method, payload: payload)
        guard var bytes = try? JSONEncoder().encode(request), bytes.count < LocalAudioRelayJSON.limit else {
            lost(); return nil
        }
        bytes.append(10)
        let response: Data? = await withTaskCancellationHandler {
            await withCheckedContinuation { completion in
                let timer = Task { [weak self] in
                    try? await ContinuousClock().sleep(until: deadline)
                    if !Task.isCancelled, self?.pending?.id == requestId { self?.lost() }
                }
                pending = Pending(id: requestId, deadline: deadline, completion: completion, timer: timer)
                let handle = input.fileHandleForWriting, frame = bytes
                writer.async { [weak self] in
                    do { try handle.write(contentsOf: frame) }
                    catch { Task { @MainActor in self?.lost() } }
                }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.lost() } }
        guard let response, !Task.isCancelled, ContinuousClock.now < deadline else { lost(); return nil }
        do {
            try LocalAudioRelayJSON.validate(response)
            let reply = try JSONDecoder().decode(Reply<Result>.self, from: response)
            guard reply.schemaVersion == 1, reply.controllerBootId == controllerBootId,
                  reply.sequence == expectedSequence, reply.requestId == requestId,
                  reply.processId == process.processIdentifier,
                  expectedBoot == nil || reply.relayBootId == expectedBoot,
                  process.isRunning else { lost(); return nil }
            if case .closed = state { return nil }
            return reply
        } catch { lost(); return nil }
    }

    private func receive(_ bytes: Data) {
        guard let pending, ContinuousClock.now < pending.deadline,
              buffer.count + bytes.count <= LocalAudioRelayJSON.limit else { lost(); return }
        buffer.append(bytes)
        guard let newline = buffer.firstIndex(of: 10) else { return }
        guard newline == buffer.index(before: buffer.endIndex), newline > buffer.startIndex else { lost(); return }
        let response = Data(buffer[..<newline])
        buffer.removeAll(keepingCapacity: false)
        self.pending = nil
        pending.timer.cancel()
        pending.completion.resume(returning: response)
    }

    func lost() {
        if case .closed = state { return }
        state = .closed
        if let boot = registeredBoot, participants.snapshot.boots[.relay] == boot { participants.unregister(.relay) }
        registeredBoot = nil
        let completing = pending
        pending = nil
        completing?.timer.cancel()
        completing?.completion.resume(returning: nil)
        buffer.removeAll(keepingCapacity: false)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning {
            Self.retire(process)
        }
    }

    private nonisolated static func retire(_ process: Process) {
        Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, process.isRunning { process.terminate() }
        }
    }

    isolated deinit { lost() }
}
