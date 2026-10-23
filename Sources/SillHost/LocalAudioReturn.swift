import Foundation
import LocalAuthentication

/// Owns the interval before StreamCoordinator installs its real revocation barrier.
@MainActor
package final class NativeAudioStartup {
    private enum State { case initializing, coordinatorCreated, failedBeforeParticipants }
    private var state = State.initializing
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    let participants = LocalAudioParticipantRegistry()
    private let bootId = UUID()
    private var request: LocalAudioParticipantRequest?
    private var acknowledged = false
    var revoke: (() async -> Bool)?
    var readFacts: (() -> LocalAudioParticipantFacts)?

    package init() {
        participants.register(.native, bootId: bootId, control: .init(fenceAndQuiesce: { [weak self] request in
            guard let self else { return .init(request, state: .unknown, facts: .unknown) }
            return await self.prepare(request)
        }, inspect: { [weak self] id in
            guard let self, let request = self.request, request.operationId == id,
                  self.participants.requestIsCurrent(request) else { return nil }
            return self.receipt(request)
        }, supportsForwarding: true, forwardingPrepare: { [weak self] preparation in
            guard let self else { return nil }
            return await self.prepare(preparation.request)
        }))
    }

    private func prepare(_ request: LocalAudioParticipantRequest) async -> LocalAudioParticipantReceipt {
        guard participants.requestIsCurrent(request) else { return .init(request, state: .blocked, facts: .unknown) }
        if let prior = self.request, sameRequest(prior, request) { return receipt(request) }
        self.request = request
        acknowledged = false
        let stopped = await quiesce(using: revoke, while: {
            self.request.map({ self.sameRequest($0, request) }) == true && self.participants.requestIsCurrent(request)
        })
        guard self.request.map({ sameRequest($0, request) }) == true,
              participants.requestIsCurrent(request) else { return .init(request, state: .blocked, facts: .unknown) }
        acknowledged = stopped
        return receipt(request)
    }

    private func sameRequest(_ first: LocalAudioParticipantRequest, _ second: LocalAudioParticipantRequest) -> Bool {
        first.schemaVersion == second.schemaVersion && first.operationId == second.operationId &&
        first.privacyGeneration == second.privacyGeneration && first.registryRevision == second.registryRevision &&
        first.participantId == second.participantId && first.bootId == second.bootId
    }

    private func receipt(_ request: LocalAudioParticipantRequest) -> LocalAudioParticipantReceipt {
        let facts: LocalAudioParticipantFacts
        if state == .failedBeforeParticipants {
            facts = .init(admissionFenced: participants.isFenced, startsSettled: true, mediaDetached: true,
                          callbacksDrained: true, buffersEmpty: true, workersExited: true)
        } else { facts = readFacts?() ?? .unknown }
        let current = self.request.map { sameRequest($0, request) } == true && participants.requestIsCurrent(request)
        return .init(request, state: current && acknowledged && facts.quiescent ? .quiescent : .unknown,
                     facts: current ? facts : .unknown)
    }

    /// The constructor must throw only before any native audio participant can start.
    package func construct<T>(_ make: () throws -> T) rethrows -> T {
        precondition(state == .initializing)
        do {
            let coordinator = try make()
            finish(.coordinatorCreated)
            return coordinator
        } catch {
            finish(.failedBeforeParticipants)
            throw error
        }
    }

    func waitUntilInitialized() async {
        guard state == .initializing else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume() }
        }
    }

    private var quiescenceTail: Task<Void, Never>?
    func quiesce(using barrier: (() async -> Bool)?, while current: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        let previous = quiescenceTail
        let task = Task { @MainActor in
            if let previous { await previous.value }
            await self.waitUntilInitialized()
            guard current() else { return false }
            switch self.state {
            case .failedBeforeParticipants: return true
            case .coordinatorCreated:
                guard let barrier else { return false }
                return await barrier()
            case .initializing: return false
            }
        }
        quiescenceTail = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    private func finish(_ next: State) {
        state = next
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

struct LocalAudioState: Codable, Equatable {
    struct Device: Codable, Equatable {
        let uid: String
        let transport: PrivacyAudioDevice.Transport
        let plugin: String?
        let inputChannels: Int
        let outputChannels: Int
        let inputMuted: Bool?
        let outputMuted: Bool?
    }
    let version: Int
    let inputUID: String
    let outputUID: String
    let systemOutputUID: String
    let devices: [Device]

    init(_ snapshot: PrivacyAudioSnapshot) throws {
        func uid(_ id: UInt32) throws -> String {
            guard let device = snapshot.devices.first(where: { $0.id == id }) else { throw PrivacyAudioFailure.readback }
            return device.uid
        }
        version = 2
        inputUID = try uid(snapshot.input)
        outputUID = try uid(snapshot.output)
        systemOutputUID = try uid(snapshot.systemOutput)
        devices = snapshot.devices.map { Device(uid: $0.uid, transport: $0.transport, plugin: $0.plugin, inputChannels: $0.inputChannels,
            outputChannels: $0.outputChannels, inputMuted: $0.inputMuted, outputMuted: $0.outputMuted) }
    }

    var isValid: Bool {
        version == 2 && !devices.isEmpty && Set(devices.map(\.uid)).count == devices.count &&
        devices.allSatisfy { !$0.uid.isEmpty && $0.inputChannels >= 0 && $0.outputChannels >= 0 &&
            ($0.inputMuted == nil || $0.inputChannels > 0) && ($0.outputMuted == nil || $0.outputChannels > 0) } &&
        devices.contains { $0.uid == inputUID && $0.inputChannels > 0 } &&
        devices.contains { $0.uid == outputUID && $0.outputChannels > 0 } &&
        devices.contains { $0.uid == systemOutputUID && $0.outputChannels > 0 }
    }

    func matches(_ snapshot: PrivacyAudioSnapshot) -> Bool {
        guard isValid, let current = try? LocalAudioState(snapshot) else { return false }
        return current.inputUID == inputUID && current.outputUID == outputUID && current.systemOutputUID == systemOutputUID &&
            current.devices.count == devices.count && devices.allSatisfy { saved in current.devices.contains(saved) }
    }
}

@MainActor
final class LocalAudioAuthentication {
    private var context: LAContext?
    private var attemptID: UUID?
    private var completion: CheckedContinuation<Bool, Never>?
    private var expiry: Task<Void, Never>?

    func cancel() { finish(false) }

    func evaluate(operationId: UUID) async -> Bool {
        guard completion == nil else { return false }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        self.context = context
        let attempt = operationId
        attemptID = attempt
        return await withCheckedContinuation { continuation in
            completion = continuation
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                if !Task.isCancelled { self?.finish(false) }
            }
            context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: "Mac의 로컬 마이크와 스피커로 복귀") { [weak self] accepted, _ in
                Task { @MainActor in
                    guard let self, self.attemptID == attempt else { return }
                    self.finish(accepted)
                }
            }
        }
    }

    private func finish(_ accepted: Bool) {
        let continuation = completion
        completion = nil
        let old = context
        context = nil
        attemptID = nil
        expiry?.cancel(); expiry = nil
        old?.invalidate()
        continuation?.resume(returning: accepted)
    }
}

@MainActor
final class LocalAudioJournal {
    struct Envelope: Codable {
        let version: Int
        let latched: Bool
        let original: LocalAudioState?
    }
    static let key = "CCRHostAudioPrivacyJournal.v2"
    private let store: (Data) -> Void
    private let load: () -> Data?
    private let synchronize: () -> Bool
    private(set) var latched: Bool
    private(set) var original: LocalAudioState?

    init(data: Data?, legacyLatched: Bool = false, legacyOriginal: LocalAudioState? = nil,
         store: @escaping (Data) -> Void, load: @escaping () -> Data?, synchronize: @escaping () -> Bool) {
        self.store = store; self.load = load; self.synchronize = synchronize
        if let data {
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 2,
               (!envelope.latched || envelope.original?.isValid == true) {
                latched = envelope.latched
                original = envelope.latched ? envelope.original : nil
            } else {
                latched = true; original = nil
            }
        } else {
            latched = legacyLatched
            original = legacyLatched && legacyOriginal?.isValid == true ? legacyOriginal : nil
        }
    }

    convenience init(defaults: UserDefaults) {
        let original = defaults.data(forKey: "CCRHostAudioOriginalLocalState.v1")
            .flatMap { try? JSONDecoder().decode(LocalAudioState.self, from: $0) }
        self.init(data: defaults.data(forKey: Self.key),
            legacyLatched: defaults.bool(forKey: "CCRHostAudioPrivacyLatched.v1"), legacyOriginal: original,
            store: { defaults.set($0, forKey: Self.key) }, load: { defaults.data(forKey: Self.key) },
            synchronize: { defaults.synchronize() })
    }

    func write(latched: Bool, original: LocalAudioState?) -> Bool {
        guard !latched || original?.isValid == true else { return false }
        guard let data = try? JSONEncoder().encode(Envelope(version: 2, latched: latched, original: original)) else { return false }
        store(data)
        guard synchronize(), load() == data else { return false }
        self.latched = latched
        self.original = original
        return true
    }
}
