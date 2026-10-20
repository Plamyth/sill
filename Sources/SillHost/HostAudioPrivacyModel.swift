import Foundation
import StreamProtocol

enum PrivacyAudioScope: Hashable { case input, output }
enum PrivacyAudioDefault: CaseIterable, Equatable { case input, output, systemOutput }

struct PrivacyAudioDevice: Equatable {
    enum Transport: String, Codable { case builtIn, virtual, other }
    let id: UInt32
    let uid: String
    let transport: Transport
    let plugin: String?
    let inputChannels: Int
    let outputChannels: Int
    var inputMuted: Bool?
    var outputMuted: Bool?
}

struct PrivacyAudioSnapshot: Equatable {
    var devices: [PrivacyAudioDevice]
    var input: UInt32
    var output: UInt32
    var systemOutput: UInt32

    func target(_ kind: PrivacyAudioDefault) -> UInt32 {
        switch kind { case .input: return input; case .output: return output; case .systemOutput: return systemOutput }
    }

    func virtual(channels: Int) -> PrivacyAudioDevice? {
        let uid = "BlackHole\(channels)ch_UID"
        let plugin = "audio.existential.BlackHole\(channels)ch"
        let matches = devices.filter { $0.uid == uid || $0.plugin == plugin }
        guard matches.count == 1, let device = matches.first,
              device.id != 0, device.uid == uid, device.plugin == plugin,
              device.transport == .virtual, device.inputChannels == channels,
              device.outputChannels == channels else { return nil }
        return device
    }

    func plan() throws -> [PrivacyAudioWrite] {
        guard Set(devices.map(\.id)).count == devices.count,
              let inputDevice = virtual(channels: 2), let outputDevice = virtual(channels: 16) else {
            throw PrivacyAudioFailure.virtualIdentity
        }
        let builtIns = devices.filter { $0.transport == .builtIn }
        guard builtIns.contains(where: { $0.inputChannels > 0 }),
              builtIns.contains(where: { $0.outputChannels > 0 }) else { throw PrivacyAudioFailure.builtInMute }
        var writes: [PrivacyAudioWrite] = []
        for device in devices where device.id != inputDevice.id && device.id != outputDevice.id {
            for scope in [PrivacyAudioScope.input, .output] {
                let channels = scope == .input ? device.inputChannels : device.outputChannels
                guard channels > 0 else { continue }
                guard let muted = scope == .input ? device.inputMuted : device.outputMuted else {
                    throw PrivacyAudioFailure.endpointMute(uid: device.uid, scope: scope)
                }
                if !muted { writes.append(.mute(device.id, scope)) }
            }
        }
        for kind in PrivacyAudioDefault.allCases {
            let desired = kind == .input ? inputDevice.id : outputDevice.id
            if target(kind) != desired { writes.append(.select(kind, desired)) }
        }
        return writes
    }
}

enum PrivacyAudioWrite: Equatable {
    case mute(UInt32, PrivacyAudioScope)
    case select(PrivacyAudioDefault, UInt32)
}

enum PrivacyAudioFailure: Error {
    case virtualIdentity, builtInMute, readback, setter, listeners, persistence
    case endpointMute(uid: String, scope: PrivacyAudioScope)
    var reason: String {
        switch self {
        case .virtualIdentity: return "BlackHole 2/16채널 장치의 고유 식별자와 플러그인을 확인할 수 없습니다."
        case .builtInMute: return "Mac 내장 마이크와 스피커의 전체 음소거를 확인할 수 없습니다."
        case .endpointMute(let uid, let scope):
            let direction = scope == .input ? "입력" : "출력"
            return "오디오 장치 \(uid)의 \(direction) 전체 음소거를 읽고 제어할 수 없어 보호를 보장할 수 없습니다."
        case .readback: return "Mac 오디오 보호 설정을 다시 읽어 확인하지 못했습니다."
        case .setter: return "Mac 오디오 보호 설정을 적용하지 못했습니다."
        case .listeners: return "Mac 오디오 장치 변경 감시를 시작하지 못했습니다."
        case .persistence: return "Mac 오디오 보호 상태를 저장하지 못했습니다."
        }
    }
}

@MainActor
protocol HostAudioPrivacyHAL: AnyObject {
    func read() throws -> PrivacyAudioSnapshot
    func write(_ change: PrivacyAudioWrite) -> Bool
    /// Replaces this owner's listeners. A nil callback removes only this owner's listeners.
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool
    func restoreLocal(_ state: LocalAudioState) -> Bool
}

@MainActor
package final class HostAudioPrivacy {
    private let hal: any HostAudioPrivacyHAL
    private let persist: () -> Bool
    package private(set) var latched: Bool
    package private(set) var state = AudioPrivacyState(version: 2, protected: false, reason: "Mac 오디오 보호가 준비되지 않았습니다.")
    var changed: ((AudioPrivacyState) -> Void)?
    private var reconciling = false
    private var pending: Task<Void, Never>?
    private var watching = false
    private var localState: LocalAudioState?
    private let saveLocal: (LocalAudioState?) -> Bool
    private let clearLatch: () -> Bool
    private let authenticateLocal: (UUID) async -> Bool
    private let cancelAuthentication: () -> Void
    private var localReturnID = UUID()
    private var returningLocal = false
    private var authenticatingLocal = false
    private var privacyGeneration = UUID()
    private var persistenceHealthy = true
    var revokeForLocalReturn: (() async -> Bool)?
    private let nativeStartup: NativeAudioStartup
    var participants: LocalAudioParticipantRegistry { nativeStartup.participants }
    var membershipChanged: ((LocalAudioParticipantRegistry.MembershipChange) -> Void)?
    var inspectForLocalReturn: (() -> LocalAudioParticipantFacts)?
    var localReturnDidComplete: ((_ commitAudio: () -> Bool) -> Bool)?
    package var localReturnUnavailableReason: String? { participants.authenticatedLocalReturnUnavailableReason }

    init(hal: any HostAudioPrivacyHAL, latched: Bool = false, persist: @escaping () -> Bool = { true },
         localState: LocalAudioState? = nil, saveLocal: @escaping (LocalAudioState?) -> Bool = { _ in true },
         clearLatch: @escaping () -> Bool = { false }, authenticateLocal: @escaping (UUID) async -> Bool = { _ in false },
         cancelAuthentication: @escaping () -> Void = {}, nativeStartup: NativeAudioStartup? = nil) {
        self.hal = hal; self.latched = latched; self.persist = persist
        self.localState = localState; self.saveLocal = saveLocal; self.clearLatch = clearLatch
        self.authenticateLocal = authenticateLocal; self.cancelAuthentication = cancelAuthentication
        let startup = nativeStartup ?? NativeAudioStartup()
        self.nativeStartup = startup
        startup.participants.membershipChanged = { [weak self] phase in
            guard let self else { return }
            if phase == .willChange { self.invalidateLocalReturn() }
            self.membershipChanged?(phase)
        }
        startup.revoke = { [weak self] in await self?.revokeForLocalReturn?() ?? false }
        startup.readFacts = { [weak self] in self?.inspectForLocalReturn?() ?? .unknown }
    }

    struct ForwardingProof: Equatable {
        let privacyGeneration: UUID
        let membership: LocalAudioParticipantRegistry.Snapshot
        fileprivate let revision: UUID
        fileprivate let localReturnID: UUID
    }
    private var forwardingRevision = UUID()
    var forwardingPrivacyGeneration: UUID { privacyGeneration }
    var forwardingInvalidated: (() -> Void)?

    func forwardingProof() -> ForwardingProof? {
        forwardingRevision = UUID()
        let proof = ForwardingProof(privacyGeneration: privacyGeneration, membership: participants.snapshot,
                                    revision: forwardingRevision, localReturnID: localReturnID)
        guard forwardingProofCurrent(proof), let snapshot = try? hal.read(),
              (try? snapshot.plan().isEmpty) == true, forwardingProofCurrent(proof) else { return nil }
        return proof
    }

    func forwardingProofCurrent(_ proof: ForwardingProof) -> Bool {
        latched && watching && persistenceHealthy && state.protected && !reconciling &&
        !returningLocal && !authenticatingLocal && localState?.isValid == true &&
        privacyGeneration == proof.privacyGeneration && forwardingRevision == proof.revision &&
        localReturnID == proof.localReturnID && participants.matches(proof.membership)
    }

    @discardableResult
    package func armAndVerify() -> Bool {
        invalidateLocalReturn()
        let wasLatched = latched
        persistenceHealthy = persist()
        guard persistenceHealthy else { fail(.persistence); return false }
        latched = true
        if !wasLatched {
            localState = nil
            guard let snapshot = try? hal.read(), let original = try? LocalAudioState(snapshot),
                  saveLocal(original) else { fail(.persistence); return false }
            localState = original
        }
        return reconcile()
    }

    /// Readback is mandatory at each admission boundary. A mismatch revokes before repair.
    @discardableResult
    package func verify() -> Bool {
        guard latched, watching, persistenceHealthy, !returningLocal, !participants.isFenced, localState?.isValid == true else { return false }
        do {
            let snapshot = try hal.read()
            guard try snapshot.plan().isEmpty else { fail(.readback); schedule(); return false }
            return state.protected
        } catch {
            fail((error as? PrivacyAudioFailure) ?? .readback); schedule(); return false
        }
    }

    @discardableResult
    package func reconcile() -> Bool {
        guard latched, !reconciling, persistenceHealthy, !returningLocal else { return false }
        guard localState?.isValid == true else { fail(.persistence); return false }
        forwardingRevision = UUID()
        reconciling = true
        defer { reconciling = false }
        do {
            var snapshot = try hal.read()
            // Install before changing controls. Failure cannot leave an advertised ready state.
            watching = hal.observe(snapshot, changed: { [weak self] in self?.propertyChanged() })
            guard watching else { throw PrivacyAudioFailure.listeners }
            var plan = try snapshot.plan()
            if !plan.isEmpty { fail(.readback) }
            // One bounded pass. Changes during setters fail closed and await a new event/admission.
            for write in plan {
                let before = try hal.read()
                guard before == snapshot, try before.plan().contains(write), hal.write(write) else {
                    throw PrivacyAudioFailure.setter
                }
                snapshot = try hal.read()
                plan = try snapshot.plan()
                guard !plan.contains(write) else { throw PrivacyAudioFailure.readback }
            }
            guard try hal.read().plan().isEmpty else { throw PrivacyAudioFailure.readback }
            publish(AudioPrivacyState(version: 2, protected: true))
            return true
        } catch {
            if !watching {
                watching = hal.observe(nil, changed: { [weak self] in self?.propertyChanged() })
            }
            fail((error as? PrivacyAudioFailure) ?? .readback)
            return false
        }
    }

    private func propertyChanged() {
        invalidateLocalReturn()
        // Even a transient failure cancels existing grants. Repair never revives them.
        _ = verify()
        schedule()
    }

    private func schedule() {
        guard latched, pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self else { return }
            // Keep the pending marker while reconciling so own setter events cannot spawn a loop.
            _ = self.reconcile()
            self.pending = nil
        }
    }

    private func fail(_ error: PrivacyAudioFailure) {
        publish(AudioPrivacyState(version: 2, protected: false, reason: error.reason))
    }

    private func publish(_ next: AudioPrivacyState) {
        guard next != state else { return }
        forwardingRevision = UUID()
        state = next
        changed?(next)
    }

    /// Stops observation only. The durable latch and all safe defaults/mutes survive exit.
    package func stop() {
        invalidateLocalReturn()
        pending?.cancel(); pending = nil
        _ = hal.observe(nil, changed: nil)
        watching = false
        publish(AudioPrivacyState(version: 2, protected: false, reason: "Mac 오디오 보호 감시가 종료되었습니다."))
    }

    private func invalidateLocalReturn() {
        forwardingRevision = UUID()
        localReturnID = UUID()
        privacyGeneration = UUID()
        cancelAuthentication()
        forwardingInvalidated?()
    }

    /// This request owns authentication. Callers cannot supply an authentication result.
    package func requestLocalReturn(budgetMilliseconds: Int = 30_000) async -> Bool {
        guard (1...30_000).contains(budgetMilliseconds), localReturnUnavailableReason == nil else { return false }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(budgetMilliseconds))
        guard await LocalAudioCompletion<Bool>.wait(until: deadline, operation: {
            await self.nativeStartup.waitUntilInitialized(); return true
        }) == true else { return false }
        guard !Task.isCancelled, ContinuousClock.now < deadline, localReturnUnavailableReason == nil,
              latched, persistenceHealthy, !returningLocal, !authenticatingLocal,
              let original = localState, original.isValid else { return false }
        authenticatingLocal = true
        defer {
            authenticatingLocal = false
            returningLocal = false
            if latched && !state.protected { schedule() }
        }
        let request = UUID()
        let generation = privacyGeneration
        let membership = participants.snapshot
        guard let ticket = participants.beginLocalReturn(operationId: request, privacyGeneration: generation,
                                                        membership: membership) else { return false }
        defer { participants.endLocalReturn(ticket) }
        localReturnID = request
        forwardingRevision = UUID()
        forwardingInvalidated?()
        let authenticated = await LocalAudioCompletion<Bool>.wait(until: deadline) {
            guard !Task.isCancelled, ContinuousClock.now < deadline, self.localReturnID == request,
                  self.privacyGeneration == generation, self.participants.matches(membership),
                  self.latched, self.persistenceHealthy else { return false }
            return await self.authenticateLocal(request)
        }
        guard authenticated == true, !Task.isCancelled, ContinuousClock.now < deadline, localReturnID == request,
              privacyGeneration == generation, participants.matches(membership), latched, persistenceHealthy else {
            cancelAuthentication()
            return false
        }
        returningLocal = true
        pending?.cancel(); pending = nil
        publish(AudioPrivacyState(version: 2, protected: false, reason: "인증된 로컬 입출력으로 복귀 중입니다."))
        guard await participants.fenceAndQuiesce(operationId: request, privacyGeneration: generation,
                    membership: membership, budgetMilliseconds: budgetMilliseconds, deadline: deadline),
              await participants.inspectAll(operationId: request, privacyGeneration: generation, membership: membership),
              localReturnID == request, privacyGeneration == generation, latched, persistenceHealthy,
              participants.proofCurrent(operationId: request, privacyGeneration: generation, membership: membership) else { return false }
        // A failed removal invalidates the HAL generation even when listeners remain registered.
        watching = false
        guard hal.observe(nil, changed: nil) else {
            fail(.listeners)
            schedule()
            return false
        }
        guard localReturnID == request, privacyGeneration == generation, latched, persistenceHealthy,
              participants.proofCurrent(operationId: request, privacyGeneration: generation, membership: membership),
              let beforeRestore = try? hal.read(), original.matches(beforeRestore) || (try? beforeRestore.plan().isEmpty) == true,
              localReturnID == request, privacyGeneration == generation,
              participants.proofCurrent(operationId: request, privacyGeneration: generation, membership: membership) else { return false }
        guard hal.restoreLocal(original), let restored = try? hal.read(), original.matches(restored),
              !Task.isCancelled, ContinuousClock.now < deadline,
              localReturnID == request, privacyGeneration == generation, latched, persistenceHealthy,
              participants.proofCurrent(operationId: request, privacyGeneration: generation, membership: membership) else {
            fail(.readback)
            returningLocal = false
            _ = reconcile()
            return false
        }
        var audioAttempted = false
        var audioCommitted = false
        let commitAudio = {
            guard !audioAttempted else { return false }
            audioAttempted = true
            guard !Task.isCancelled, ContinuousClock.now < deadline,
                  self.localReturnID == request, self.privacyGeneration == generation,
                  self.latched, self.persistenceHealthy,
                  self.participants.proofCurrent(operationId: request, privacyGeneration: generation, membership: membership) else { return false }
            audioCommitted = self.clearLatch()
            return audioCommitted
        }
        let completed = localReturnDidComplete?(commitAudio) ?? commitAudio()
        guard completed && audioCommitted else {
            let originalSaved = !audioCommitted || saveLocal(original)
            persistenceHealthy = persist() && originalSaved
            fail(.persistence)
            returningLocal = false
            if persistenceHealthy { _ = reconcile() }
            return false
        }
        latched = false
        localState = nil
        publish(AudioPrivacyState(version: 2, protected: false, reason: "인증 후 로컬 입출력으로 복귀했습니다."))
        return true
    }
}
