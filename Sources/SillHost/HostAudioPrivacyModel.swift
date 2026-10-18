import Foundation
import StreamProtocol

enum PrivacyAudioScope: Hashable { case input, output }
enum PrivacyAudioDefault: CaseIterable, Equatable { case input, output, systemOutput }

struct PrivacyAudioDevice: Equatable {
    enum Transport: Equatable { case builtIn, virtual, other }
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
        for device in builtIns {
            for scope in [PrivacyAudioScope.input, .output] {
                let channels = scope == .input ? device.inputChannels : device.outputChannels
                guard channels > 0 else { continue }
                guard let muted = scope == .input ? device.inputMuted : device.outputMuted else {
                    throw PrivacyAudioFailure.builtInMute
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
    var reason: String {
        switch self {
        case .virtualIdentity: return "BlackHole 2/16채널 장치의 고유 식별자와 플러그인을 확인할 수 없습니다."
        case .builtInMute: return "Mac 내장 마이크와 스피커의 전체 음소거를 확인할 수 없습니다."
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
    package private(set) var state = AudioPrivacyState(protected: false, reason: "Mac 오디오 보호가 준비되지 않았습니다.")
    var changed: ((AudioPrivacyState) -> Void)?
    private var reconciling = false
    private var pending: Task<Void, Never>?
    private var watching = false
    private var localState: LocalAudioState?
    private let saveLocal: (LocalAudioState?) -> Bool
    private let clearLatch: () -> Bool
    private let authenticateLocal: () async -> Bool
    private let cancelAuthentication: () -> Void
    private var localReturnID = UUID()
    private var returningLocal = false

    init(hal: any HostAudioPrivacyHAL, latched: Bool = false, persist: @escaping () -> Bool = { true },
         localState: LocalAudioState? = nil, saveLocal: @escaping (LocalAudioState?) -> Bool = { _ in true },
         clearLatch: @escaping () -> Bool = { false }, authenticateLocal: @escaping () async -> Bool = { false },
         cancelAuthentication: @escaping () -> Void = {}) {
        self.hal = hal; self.latched = latched; self.persist = persist
        self.localState = localState; self.saveLocal = saveLocal; self.clearLatch = clearLatch
        self.authenticateLocal = authenticateLocal; self.cancelAuthentication = cancelAuthentication
    }

    @discardableResult
    package func armAndVerify() -> Bool {
        invalidateLocalReturn()
        let wasLatched = latched
        guard persist() else { fail(.persistence); return false }
        latched = true
        if !wasLatched && localState == nil {
            guard let snapshot = try? hal.read(), let original = try? LocalAudioState(snapshot),
                  saveLocal(original) else { fail(.persistence); return false }
            localState = original
        }
        return reconcile()
    }

    /// Readback is mandatory at each admission boundary. A mismatch revokes before repair.
    @discardableResult
    package func verify() -> Bool {
        guard latched, watching else { return false }
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
        guard latched, !reconciling else { return false }
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
            publish(AudioPrivacyState(protected: true))
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
        publish(AudioPrivacyState(protected: false, reason: error.reason))
    }

    private func publish(_ next: AudioPrivacyState) {
        guard next != state else { return }
        state = next
        changed?(next)
    }

    /// Stops observation only. The durable latch and all safe defaults/mutes survive exit.
    package func stop() {
        invalidateLocalReturn()
        pending?.cancel(); pending = nil
        _ = hal.observe(nil, changed: nil)
        watching = false
        publish(AudioPrivacyState(protected: false, reason: "Mac 오디오 보호 감시가 종료되었습니다."))
    }

    private func invalidateLocalReturn() {
        localReturnID = UUID()
        cancelAuthentication()
    }

    /// This request owns authentication. Callers cannot supply an authentication result.
    package func requestLocalReturn() async -> Bool {
        guard latched, !returningLocal, let original = localState else { return false }
        returningLocal = true
        defer { returningLocal = false }
        let request = UUID()
        localReturnID = request
        guard await authenticateLocal(), localReturnID == request, latched else { return false }
        pending?.cancel(); pending = nil
        guard hal.observe(nil, changed: nil) else { fail(.listeners); return false }
        watching = false
        publish(AudioPrivacyState(protected: false, reason: "인증된 로컬 입출력으로 복귀 중입니다."))
        guard hal.restoreLocal(original), let restored = try? hal.read(), original.matches(restored),
              clearLatch() else {
            fail(.readback)
            _ = reconcile()
            return false
        }
        latched = false
        publish(AudioPrivacyState(protected: false, reason: "인증 후 로컬 입출력으로 복귀했습니다."))
        if saveLocal(nil) { localState = nil }
        return true
    }
}
