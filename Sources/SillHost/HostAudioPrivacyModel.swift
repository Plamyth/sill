import Foundation
import StreamProtocol

enum PrivacyAudioScope: String, Codable, Hashable { case input, output }
enum PrivacyAudioDefault: CaseIterable, Equatable { case input, output, systemOutput }

struct PrivacyAudioStream: Codable, Equatable {
    struct Format: Codable, Equatable {
        let sampleRate: Double
        let formatID: UInt32
        let flags: UInt32
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let bytesPerFrame: UInt32
        let channels: UInt32
        let bitsPerChannel: UInt32
        let reserved: UInt32

        var isValid: Bool {
            let interleavedChannels = flags & (1 << 5) == 0 ? channels : 1
            guard interleavedChannels > 0 else { return false }
            return sampleRate.isFinite && sampleRate > 0 && formatID == 0x6c70636d &&
            (1...1024).contains(channels) && (1...64).contains(bitsPerChannel) &&
            framesPerPacket == 1 && bytesPerFrame > 0 && bytesPerPacket == bytesPerFrame && reserved == 0 &&
            bytesPerFrame % interleavedChannels == 0 && UInt64(bitsPerChannel) <= UInt64(bytesPerFrame / interleavedChannels) * 8
        }
    }
    let id: UInt32
    let ownerID: UInt32
    let direction: PrivacyAudioScope
    let startingChannel: UInt32
    let virtualFormat: Format
    let physicalFormat: Format
    var active: Bool
    let activeSettable: Bool

    func hasSameIdentity(as other: Self) -> Bool {
        var other = other
        other.active = active
        return self == other
    }
}

struct PrivacyAudioDevice: Equatable {
    enum Transport: String, Codable { case builtIn, virtual, other, aggregate, unknown }
    let id: UInt32
    let uid: String
    let transport: Transport
    let plugin: String?
    let inputChannels: Int
    let outputChannels: Int
    var inputMuted: Bool?
    var outputMuted: Bool?
    var streams: [PrivacyAudioStream]? = nil

    func validatedStreams(_ scope: PrivacyAudioScope) -> [PrivacyAudioStream]? {
        guard id != 0, !uid.isEmpty, plugin == nil, transport == .builtIn || transport == .other,
              let streams, !streams.isEmpty, Set(streams.map(\.id)).count == streams.count,
              streams.allSatisfy({ $0.id != 0 && $0.id != id && $0.ownerID == id && $0.activeSettable &&
                  $0.virtualFormat.isValid && $0.physicalFormat.isValid &&
                  $0.virtualFormat.channels == $0.physicalFormat.channels }) else { return nil }
        for direction in [PrivacyAudioScope.input, .output] {
            let channels = direction == .input ? inputChannels : outputChannels
            guard (0...1024).contains(channels) else { return nil }
            var next: UInt64 = 1
            for stream in streams.filter({ $0.direction == direction }).sorted(by: { $0.startingChannel < $1.startingChannel }) {
                guard UInt64(stream.startingChannel) == next else { return nil }
                next += UInt64(stream.virtualFormat.channels)
            }
            guard next == UInt64(channels) + 1 else { return nil }
        }
        return streams.filter { $0.direction == scope }
    }
}

struct PrivacyAudioSnapshot: Equatable {
    var devices: [PrivacyAudioDevice]
    var input: UInt32
    var output: UInt32
    var systemOutput: UInt32

    private var identitiesAreUnique: Bool {
        let streams = devices.flatMap { $0.streams ?? [] }
        return devices.allSatisfy { $0.id != 0 && !$0.uid.isEmpty } &&
            Set(devices.map(\.id)).count == devices.count && Set(devices.map(\.uid)).count == devices.count &&
            Set(streams.map(\.id)).count == streams.count &&
            Set(streams.map(\.id)).isDisjoint(with: Set(devices.map(\.id)))
    }

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

    var coverage: [AudioPrivacyCoverage] {
        let isolated = Set([virtual(channels: 2)?.id, virtual(channels: 16)?.id].compactMap { $0 })
        return devices.flatMap { device in
            [PrivacyAudioScope.input, .output].compactMap { scope in
                let channels = scope == .input ? device.inputChannels : device.outputChannels
                guard channels > 0 else { return nil }
                let muted = scope == .input ? device.inputMuted : device.outputMuted
                let virtual = isolated.contains(device.id)
                let streams = muted == nil ? device.validatedStreams(scope) : nil
                let streamProtected = streams?.isEmpty == false && streams?.allSatisfy({ !$0.active }) == true
                let protected = identitiesAreUnique && (virtual || muted == true || streamProtected)
                return AudioPrivacyCoverage(uid: device.uid, direction: scope == .input ? .input : .output,
                    channels: channels, method: virtual ? "validatedVirtualIsolation" : muted != nil ? "masterMute" :
                        streams != nil ? "audioStreamInactive" : "unsupported",
                    protected: protected,
                    reason: protected ? nil : "전체 \(channels)채널의 음소거 또는 검증된 전체 스트림 비활성화를 확인하지 못했습니다.",
                    alternative: muted == nil && streams == nil && device.transport == .other ? "exclusiveIOProcRequiresIndependentDriverAndMixerValidation" : nil)
            }
        }
    }

    func plan(allowPartial: Bool = false) throws -> [PrivacyAudioWrite] {
        guard identitiesAreUnique,
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
                if let muted = scope == .input ? device.inputMuted : device.outputMuted {
                    if !muted { writes.append(.mute(device.id, scope)) }
                } else if let streams = device.validatedStreams(scope), let topology = device.streams, !streams.isEmpty {
                    for stream in streams where stream.active {
                        writes.append(.deactivateStream(uid: device.uid, stream: stream, topology: topology))
                    }
                } else {
                    if allowPartial { continue }
                    throw PrivacyAudioFailure.endpointMute(uid: device.uid, scope: scope)
                }
            }
        }
        for kind in PrivacyAudioDefault.allCases {
            let desired = kind == .input ? inputDevice.id : outputDevice.id
            if target(kind) != desired { writes.append(.select(kind, desired)) }
        }
        return writes
    }

    func applying(_ write: PrivacyAudioWrite) -> Self? {
        guard (try? plan(allowPartial: true).contains(write)) == true else { return nil }
        var next = self
        switch write {
        case .mute(let id, let scope):
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return nil }
            if scope == .input { next.devices[index].inputMuted = true }
            else { next.devices[index].outputMuted = true }
        case .select(let kind, let id):
            switch kind { case .input: next.input = id; case .output: next.output = id; case .systemOutput: next.systemOutput = id }
        case .deactivateStream(let uid, let stream, _):
            guard let device = devices.firstIndex(where: { $0.uid == uid }),
                  let index = devices[device].streams?.firstIndex(of: stream) else { return nil }
            next.devices[device].streams?[index].active = false
        }
        return next
    }
}

enum PrivacyAudioWrite: Equatable {
    case mute(UInt32, PrivacyAudioScope)
    case select(PrivacyAudioDefault, UInt32)
    case deactivateStream(uid: String, stream: PrivacyAudioStream, topology: [PrivacyAudioStream])
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

private final class LocalReturnCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
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
    private var lastSnapshot: PrivacyAudioSnapshot?
    private var reconciling = false
    private var pending: Task<Void, Never>?
    private var watching = false
    private var localState: LocalAudioState?
    private let saveLocal: (LocalAudioState?) -> Bool
    private let clearLatch: () -> Bool
    private let authenticateLocal: (UUID) async -> Bool
    private let cancelAuthentication: () -> Void
    private let authenticationChallengeID: () -> UUID?
    private var localReturnCancellation: LocalReturnCancellation?
    private var localReturnDeadline: ContinuousClock.Instant?
    private var localReturnID = UUID()
    private var returningLocal = false
    var isReturningLocal: Bool { returningLocal }
    private var authenticatingLocal = false
    package var forwardingIntentAllowed: Bool { !authenticatingLocal && !returningLocal }
    private var privacyGeneration = UUID()
    private var persistenceHealthy = true
    var revokeForLocalReturn: (() async -> Bool)?
    private let nativeStartup: NativeAudioStartup
    var participants: LocalAudioParticipantRegistry { nativeStartup.participants }
    var membershipChanged: ((LocalAudioParticipantRegistry.MembershipChange) -> Void)?
    var inspectForLocalReturn: (() -> LocalAudioParticipantFacts)?
    var localReturnDidComplete: ((_ commitAudio: () -> Bool) -> Bool)?
    package var authenticatedLocalReturnWillCommit: ((_ admission: @escaping @MainActor () -> Bool) async -> Bool)?
    private var localReturnFailureReason: String?
    package var localReturnUnavailableReason: String? { participants.authenticatedLocalReturnUnavailableReason }
    package var localReturnStatusReason: String? {
        if localAuthenticationChallengeID != nil {
            return "macOS에 로컬 복귀 인증을 요청했습니다. 운영체제의 본인 인증이 끝날 때까지 보호를 유지합니다."
        }
        return localReturnFailureReason ?? localReturnUnavailableReason
    }
    package var localAuthenticationWillBegin: ((UUID) -> Void)?
    package var localAuthenticationChallengeID: UUID? {
        guard authenticatingLocal, !returningLocal,
              localReturnCancellation?.isCancelled == false,
              let deadline = localReturnDeadline, ContinuousClock.now < deadline,
              let challenge = authenticationChallengeID(), challenge == localReturnID else { return nil }
        return challenge
    }

    init(hal: any HostAudioPrivacyHAL, latched: Bool = false, persist: @escaping () -> Bool = { true },
         localState: LocalAudioState? = nil, saveLocal: @escaping (LocalAudioState?) -> Bool = { _ in true },
         clearLatch: @escaping () -> Bool = { false }, authenticateLocal: @escaping (UUID) async -> Bool = { _ in false },
         cancelAuthentication: @escaping () -> Void = {}, authenticationChallengeID: @escaping () -> UUID? = { nil },
         nativeStartup: NativeAudioStartup? = nil) {
        self.hal = hal; self.latched = latched; self.persist = persist
        self.localState = localState; self.saveLocal = saveLocal; self.clearLatch = clearLatch
        self.authenticateLocal = authenticateLocal; self.cancelAuthentication = cancelAuthentication
        self.authenticationChallengeID = authenticationChallengeID
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
    private var forwardingSnapshot: PrivacyAudioSnapshot?
    var forwardingPrivacyGeneration: UUID { privacyGeneration }
    var forwardingInvalidated: (() -> Void)?

    /// Reads protection health while participants remain fenced; never opens normal admission.
    package func forwardingHealth() -> Bool { forwardingProof() != nil }

    func forwardingProof() -> ForwardingProof? {
        let proof = ForwardingProof(privacyGeneration: privacyGeneration, membership: participants.snapshot,
                                    revision: forwardingRevision, localReturnID: localReturnID)
        guard forwardingProofCurrent(proof), let snapshot = try? readSnapshot(),
              (try? snapshot.plan().isEmpty) == true, forwardingProofCurrent(proof) else {
            forwardingRevision = UUID()
            forwardingSnapshot = nil
            return nil
        }
        if forwardingSnapshot != snapshot {
            forwardingRevision = UUID()
            forwardingSnapshot = snapshot
        }
        return ForwardingProof(privacyGeneration: proof.privacyGeneration, membership: proof.membership,
                               revision: forwardingRevision, localReturnID: proof.localReturnID)
    }

    func forwardingProofCurrent(_ proof: ForwardingProof) -> Bool {
        latched && watching && persistenceHealthy && state.protected && !reconciling &&
        !returningLocal && !authenticatingLocal && localState?.isValid == true &&
        privacyGeneration == proof.privacyGeneration && forwardingRevision == proof.revision &&
        localReturnID == proof.localReturnID && participants.matches(proof.membership)
    }

    @discardableResult
    package func armAndVerify() -> Bool {
        guard forwardingIntentAllowed else { return false }
        invalidateLocalReturn()
        if latched {
            guard localState?.isValid == true else { fail(.persistence); return false }
            persistenceHealthy = persist()
        } else {
            guard let snapshot = try? readSnapshot(), let original = try? LocalAudioState(snapshot), original.isValid else {
                fail(.readback); return false
            }
            persistenceHealthy = saveLocal(original)
            guard persistenceHealthy else { fail(.persistence); return false }
            localState = original
            latched = true
        }
        guard persistenceHealthy else { fail(.persistence); return false }
        return reconcile()
    }

    /// Readback is mandatory at each admission boundary. A mismatch revokes before repair.
    @discardableResult
    package func verify() -> Bool {
        guard latched, watching, persistenceHealthy, !reconciling, !authenticatingLocal, !returningLocal, !participants.isFenced, localState?.isValid == true else { return false }
        do {
            let snapshot = try readSnapshot()
            lastSnapshot = snapshot
            guard try snapshot.plan().isEmpty else { fail(.readback); schedule(); return false }
            return state.protected
        } catch {
            fail((error as? PrivacyAudioFailure) ?? .readback); schedule(); return false
        }
    }

    @discardableResult
    package func reconcile() -> Bool {
        guard latched, !reconciling, persistenceHealthy, !returningLocal else { return false }
        guard let localState, localState.isValid else { fail(.persistence); return false }
        forwardingRevision = UUID()
        reconciling = true
        defer { reconciling = false }
        do {
            var snapshot = try readSnapshot()
            lastSnapshot = snapshot
            let original = try localState.recordingStreams(snapshot)
            if original != localState {
                guard saveLocal(original) else { throw PrivacyAudioFailure.persistence }
                self.localState = original
            }
            watching = hal.observe(snapshot, changed: { [weak self] in self?.propertyChanged() })
            guard watching else { throw PrivacyAudioFailure.listeners }
            var plan = try snapshot.plan(allowPartial: true)
            if !plan.isEmpty { fail(.readback) }
            for _ in 0..<plan.count {
                guard let write = plan.first else { break }
                let before = try readSnapshot()
                guard before == snapshot, let expected = before.applying(write), hal.write(write) else {
                    throw PrivacyAudioFailure.setter
                }
                snapshot = try readSnapshot()
                lastSnapshot = snapshot
                guard snapshot == expected else { throw PrivacyAudioFailure.readback }
                plan = try snapshot.plan(allowPartial: true)
                guard !plan.contains(write) else { throw PrivacyAudioFailure.readback }
            }
            guard try readSnapshot() == snapshot, try snapshot.plan().isEmpty else { throw PrivacyAudioFailure.readback }
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

    private func readSnapshot() throws -> PrivacyAudioSnapshot {
        lastSnapshot = nil
        let snapshot = try hal.read()
        lastSnapshot = snapshot
        return snapshot
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
        var next = next
        next.coverage = lastSnapshot?.coverage
        next.latched = latched
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
    package func requestLocalReturn(budgetMilliseconds: Int = 30_000,
                                    authenticationBudgetMilliseconds: Int = 120_000) async -> Bool {
        let cancellation = LocalReturnCancellation()
        return await withTaskCancellationHandler {
            defer { cancellation.cancel() }
            return await performLocalReturn(budgetMilliseconds: budgetMilliseconds,
                authenticationBudgetMilliseconds: authenticationBudgetMilliseconds, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func performLocalReturn(budgetMilliseconds: Int, authenticationBudgetMilliseconds: Int,
                                    cancellation: LocalReturnCancellation) async -> Bool {
        guard !cancellation.isCancelled, (1...30_000).contains(budgetMilliseconds),
              (1...120_000).contains(authenticationBudgetMilliseconds) else { return false }
        guard !Task.isCancelled, !returningLocal, !authenticatingLocal else { return false }
        localReturnFailureReason = nil
        authenticatingLocal = true
        localReturnCancellation = cancellation
        let authenticationDeadline = ContinuousClock.now.advanced(by: .milliseconds(authenticationBudgetMilliseconds))
        localReturnDeadline = authenticationDeadline
        defer {
            localReturnCancellation = nil
            localReturnDeadline = nil
            authenticatingLocal = false
            returningLocal = false
            if latched && !state.protected { schedule() }
        }
        let request = UUID()
        let generation = privacyGeneration
        let membership = participants.snapshot
        localReturnID = request
        forwardingRevision = UUID()
        forwardingInvalidated?()
        publish(AudioPrivacyState(version: 2, protected: false, reason: "로컬 복귀 인증을 확인하는 동안 원격 오디오를 차단합니다."))
        let authenticated = await LocalAudioCompletion<Bool>.wait(until: authenticationDeadline) {
            let current = {
                !cancellation.isCancelled && !Task.isCancelled && ContinuousClock.now < authenticationDeadline &&
                self.localReturnID == request && self.privacyGeneration == generation &&
                self.participants.snapshot == membership
            }
            guard current() else { return false }
            self.localAuthenticationWillBegin?(request)
            guard current() else { return false }
            return await self.authenticateLocal(request)
        }
        guard authenticated == true, !cancellation.isCancelled, !Task.isCancelled,
              ContinuousClock.now < authenticationDeadline, localReturnID == request,
              privacyGeneration == generation, participants.snapshot == membership else {
            cancelAuthentication()
            localReturnFailureReason = "로컬 복귀 인증이 취소되었거나 완료되지 않았습니다. 보호를 유지합니다."
            return false
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(budgetMilliseconds))
        localReturnDeadline = deadline
        returningLocal = true
        localReturnFailureReason = "인증은 완료됐지만 로컬 복귀의 안전 상태를 확인하지 못했습니다. 보호를 유지합니다."
        guard await participants.recoverClosedLocalReturn(until: deadline), !cancellation.isCancelled else {
            if let reason = participants.authenticatedLocalReturnUnavailableReason {
                localReturnFailureReason = "인증은 완료됐지만 \(reason) 보호를 유지합니다."
            }
            return false
        }
        guard await LocalAudioCompletion<Bool>.wait(until: deadline, operation: {
            await self.nativeStartup.waitUntilInitialized(); return true
        }) == true, !cancellation.isCancelled, !Task.isCancelled, ContinuousClock.now < deadline,
              localReturnID == request, privacyGeneration == generation,
              participants.authenticatedLocalReturnUnavailableReason == nil, participants.matches(membership),
              latched, persistenceHealthy, let original = localState, original.isValid,
              let ticket = participants.beginLocalReturn(operationId: request, privacyGeneration: generation,
                                                        membership: membership) else { return false }
        defer { participants.endLocalReturn(ticket) }
        pending?.cancel(); pending = nil
        publish(AudioPrivacyState(version: 2, protected: false, reason: "인증된 로컬 입출력으로 복귀 중입니다."))
        guard await participants.fenceAndQuiesce(operationId: request, privacyGeneration: generation,
                    membership: membership, budgetMilliseconds: budgetMilliseconds, deadline: deadline),
              await participants.inspectAll(operationId: request, privacyGeneration: generation, membership: membership),
              localReturnID == request, privacyGeneration == generation, latched, persistenceHealthy,
              participants.proofCurrent(operationId: request, privacyGeneration: generation, membership: membership) else { return false }
        let admission: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return !cancellation.isCancelled && !Task.isCancelled && ContinuousClock.now < deadline &&
                self.authenticatingLocal && self.returningLocal &&
                self.localReturnID == request && self.privacyGeneration == generation &&
                self.latched && self.persistenceHealthy &&
                self.participants.proofCurrent(operationId: request, privacyGeneration: generation, membership: membership)
        }
        guard let commitIntent = authenticatedLocalReturnWillCommit,
              await LocalAudioCompletion<Bool>.wait(until: deadline, operation: {
                  guard admission() else { return false }
                  return await commitIntent(admission)
              }) == true, admission(),
              await participants.inspectAll(operationId: request, privacyGeneration: generation, membership: membership),
              admission() else { return false }
        // A failed removal invalidates the HAL generation even when listeners remain registered.
        watching = false
        guard hal.observe(nil, changed: nil) else {
            fail(.listeners)
            schedule()
            return false
        }
        guard localReturnID == request, privacyGeneration == generation, latched, persistenceHealthy,
              participants.proofCurrent(operationId: request, privacyGeneration: generation, membership: membership),
              let beforeRestore = try? readSnapshot(), original.matches(beforeRestore) || (try? beforeRestore.plan(allowPartial: true).isEmpty) == true,
              localReturnID == request, privacyGeneration == generation,
              participants.proofCurrent(operationId: request, privacyGeneration: generation, membership: membership) else { return false }
        guard hal.restoreLocal(original), let restored = try? readSnapshot(), original.matches(restored),
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
        localReturnFailureReason = nil
        publish(AudioPrivacyState(version: 2, protected: false, reason: "인증 후 로컬 입출력으로 복귀했습니다."))
        return true
    }
}
