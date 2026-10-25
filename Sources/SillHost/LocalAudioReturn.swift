import Foundation
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

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
        var streams: [PrivacyAudioStream]? = nil

        init(_ device: PrivacyAudioDevice) {
            uid = device.uid; transport = device.transport; plugin = device.plugin
            inputChannels = device.inputChannels; outputChannels = device.outputChannels
            inputMuted = device.inputMuted; outputMuted = device.outputMuted; streams = device.streams
        }

        var streamTopologyIsValid: Bool {
            guard let streams else { return true }
            let device = PrivacyAudioDevice(id: streams.first?.ownerID ?? 0, uid: uid, transport: transport,
                plugin: plugin, inputChannels: inputChannels, outputChannels: outputChannels,
                inputMuted: inputMuted, outputMuted: outputMuted, streams: streams)
            return device.validatedStreams(.input) != nil
        }

        func matches(_ current: Device, includeActive: Bool = true) -> Bool {
            guard uid == current.uid, transport == current.transport, plugin == current.plugin,
                  inputChannels == current.inputChannels, outputChannels == current.outputChannels,
                  !includeActive || (inputMuted == current.inputMuted && outputMuted == current.outputMuted) else { return false }
            guard let streams else { return true }
            guard let currentStreams = current.streams, streams.count == currentStreams.count else { return false }
            return streams.allSatisfy { saved in
                currentStreams.contains { includeActive ? saved == $0 : saved.hasSameIdentity(as: $0) }
            }
        }
    }
    let version: Int
    let inputUID: String
    let outputUID: String
    let systemOutputUID: String
    var devices: [Device]

    init(_ snapshot: PrivacyAudioSnapshot) throws {
        func uid(_ id: UInt32) throws -> String {
            guard let device = snapshot.devices.first(where: { $0.id == id }) else { throw PrivacyAudioFailure.readback }
            return device.uid
        }
        version = 2
        inputUID = try uid(snapshot.input)
        outputUID = try uid(snapshot.output)
        systemOutputUID = try uid(snapshot.systemOutput)
        devices = snapshot.devices.map(Device.init)
    }

    var isValid: Bool {
        let streamIDs = devices.flatMap { $0.streams ?? [] }.map(\.id)
        return version == 2 && !devices.isEmpty && Set(devices.map(\.uid)).count == devices.count &&
        Set(streamIDs).count == streamIDs.count &&
        devices.allSatisfy { !$0.uid.isEmpty && $0.inputChannels >= 0 && $0.outputChannels >= 0 &&
            ($0.inputMuted == nil || $0.inputChannels > 0) && ($0.outputMuted == nil || $0.outputChannels > 0) && $0.streamTopologyIsValid } &&
        devices.contains { $0.uid == inputUID && $0.inputChannels > 0 } &&
        devices.contains { $0.uid == outputUID && $0.outputChannels > 0 } &&
        devices.contains { $0.uid == systemOutputUID && $0.outputChannels > 0 }
    }

    func matches(_ snapshot: PrivacyAudioSnapshot) -> Bool {
        guard isValid, let current = try? LocalAudioState(snapshot) else { return false }
        return current.inputUID == inputUID && current.outputUID == outputUID && current.systemOutputUID == systemOutputUID &&
            current.devices.count == devices.count && devices.allSatisfy { saved in current.devices.contains { saved.matches($0) } }
    }

    func recordingStreams(_ snapshot: PrivacyAudioSnapshot) throws -> Self {
        var next = self
        for device in snapshot.devices where device.streams != nil {
            guard device.validatedStreams(.input) != nil, let observed = device.streams else {
                throw PrivacyAudioFailure.readback
            }
            var saved = Device(device)
            if let index = next.devices.firstIndex(where: { $0.uid == device.uid }) {
                let previous = next.devices[index]
                let originals = previous.streams ?? []
                guard previous.transport == device.transport, previous.plugin == device.plugin,
                      originals.allSatisfy({ original in observed.contains { original.hasSameIdentity(as: $0) } }) else {
                    throw PrivacyAudioFailure.persistence
                }
                saved.streams = observed.map { stream in originals.first { $0.hasSameIdentity(as: stream) } ?? stream }
                let original = PrivacyAudioDevice(id: device.id, uid: device.uid, transport: device.transport,
                    plugin: device.plugin, inputChannels: device.inputChannels, outputChannels: device.outputChannels,
                    inputMuted: previous.inputMuted, outputMuted: previous.outputMuted, streams: saved.streams)
                next.devices[index] = Device(original)
            } else { next.devices.append(saved) }
        }
        guard next.isValid else { throw PrivacyAudioFailure.persistence }
        return next
    }
}

@MainActor
final class LocalAudioAuthentication {
    static let maximumWaitMilliseconds = 120_000
    @MainActor private final class Attempt {
        enum Phase { case checking, resetting, authorizing, retired }
        let operationID: UUID
        let right = LARight(requirement: .biometry(fallback: .devicePasscode))
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(LocalAudioAuthentication.maximumWaitMilliseconds))
        var phase = Phase.checking
        var callbackPending = false
        var revocationPending = false
        var revocationAcknowledged = false
        var needsFinalRevocation = false
        init(_ operationID: UUID) { self.operationID = operationID }
    }
    private var attempt: Attempt?
    private var retiring: Attempt?
    private var completion: CheckedContinuation<Bool, Never>?
    private var expiry: Task<Void, Never>?
    private let presentation = LocalAuthenticationPresentation()

    var activeChallengeID: UUID? {
        guard let attempt, attempt.phase == .authorizing, ContinuousClock.now < attempt.deadline else { return nil }
        return attempt.operationID
    }

    func cancel() { finish(false) }

    func evaluate(operationId: UUID) async -> Bool {
        guard attempt == nil, !Task.isCancelled else { return false }
        guard retiring == nil else {
            print("[로컬 복귀 인증] 이전 권한 폐기와 운영체제 콜백 종료가 미확인입니다. 새 인증을 겹치지 않습니다.")
            return false
        }
        let attempt = Attempt(operationId)
        self.attempt = attempt
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
                expiry = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Self.maximumWaitMilliseconds))
                    if !Task.isCancelled { self?.finish(false) }
                }
                guard attempt.right.state == .unknown else { finish(false); return }
                attempt.callbackPending = true
                attempt.right.checkCanAuthorize { [weak self] error in
                    let errorCode = (error as NSError?)?.code
                    Task { @MainActor in
                        attempt.callbackPending = false
                        guard let self, self.remainsCurrent(attempt) else { return }
                        guard errorCode == nil else {
                            print("[로컬 복귀 인증] 정책 사용 불가 code=\(errorCode!)")
                            self.finish(false); return
                        }
                        self.resetAndAuthorize(attempt)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.attempt === attempt else { return }
                self?.finish(false)
            }
        }
        return accepted && !Task.isCancelled
    }

    private func remainsCurrent(_ candidate: Attempt) -> Bool {
        guard attempt === candidate else { settleRetired(candidate); return false }
        guard ContinuousClock.now < candidate.deadline else { finish(false); return false }
        return true
    }

    private func resetAndAuthorize(_ candidate: Attempt) {
        candidate.phase = .resetting
        candidate.callbackPending = true
        candidate.right.deauthorize { [weak self] in
            Task { @MainActor in
                candidate.callbackPending = false
                guard let self, self.remainsCurrent(candidate) else { return }
                guard candidate.right.state == .notAuthorized || candidate.right.state == .unknown,
                      let window = await self.presentation.begin(invalidated: { [weak self] in
                          guard self?.attempt === candidate else { return }
                          self?.cancel()
                      }) else { self.finish(false); return }
                guard self.remainsCurrent(candidate) else { return }
                candidate.callbackPending = true
                candidate.right.authorize(localizedReason: "Touch ID 또는 macOS 로그인 암호로 로컬 입출력 복귀",
                                          in: window) { [weak self] error in
                    let errorCode = (error as NSError?)?.code
                    Task { @MainActor in
                        candidate.callbackPending = false
                        guard let self, self.remainsCurrent(candidate) else { return }
                        let accepted = errorCode == nil && candidate.right.state == .authorized
                        print("[로컬 복귀 인증] anchored 권한 응답 operation=\(candidate.operationID) accepted=\(accepted) state=\(candidate.right.state.rawValue) errorCode=\(errorCode.map(String.init) ?? "none")")
                        self.finish(accepted)
                    }
                }
                candidate.phase = .authorizing
            }
        }
    }

    private func finish(_ accepted: Bool) {
        guard let candidate = attempt else { return }
        let continuation = completion
        completion = nil
        attempt = nil
        candidate.phase = .retired
        retiring = candidate
        expiry?.cancel(); expiry = nil
        presentation.end()
        candidate.needsFinalRevocation = candidate.callbackPending
        revoke(candidate)
        continuation?.resume(returning: accepted)
    }

    private func revoke(_ candidate: Attempt) {
        candidate.revocationPending = true
        candidate.revocationAcknowledged = false
        candidate.right.deauthorize { [weak self] in
            Task { @MainActor in
                candidate.revocationPending = false
                candidate.revocationAcknowledged = true
                self?.settleRetired(candidate)
            }
        }
    }

    private func settleRetired(_ candidate: Attempt) {
        guard retiring === candidate, !candidate.callbackPending, !candidate.revocationPending,
              candidate.revocationAcknowledged else { return }
        if candidate.right.state == .authorized, candidate.needsFinalRevocation {
            candidate.needsFinalRevocation = false
            revoke(candidate)
            return
        }
        guard candidate.right.state == .notAuthorized || candidate.right.state == .unknown else {
            print("[로컬 복귀 인증] 권한 폐기 상태 미확인. 재요청을 보류합니다.")
            return
        }
        retiring = nil
        print("[로컬 복귀 인증] 권한 폐기와 콜백 종료 확인. 운영체제 인증창 종료는 별도 확인이 필요합니다.")
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
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), (envelope.version == 2 || envelope.version == 3),
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
        guard let data = try? JSONEncoder().encode(Envelope(version: 3, latched: latched, original: original)) else { return false }
        store(data)
        guard synchronize(), load() == data else { return false }
        self.latched = latched
        self.original = original
        return true
    }
}
