import Foundation
import StreamProtocol

struct AudioForwardingPairedDevice { let id: AudioForwardingDeviceID; let pairingGeneration: UUID }
struct ProviderCallSession {
    init(relay: LocalAudioRelay, peer: AudioForwardingPairedDevice, credential: AudioForwardingCredential,
         snapshot: AudioForwardingSnapshot, admitted: @escaping @MainActor () -> Bool,
         readSnapshot: @escaping @MainActor () async -> AudioForwardingSnapshot?) {}
}
@MainActor final class LocalAudioRelay {
    var value = try! AudioForwardingSnapshot(revision: .init(1), intent: nil, binding: nil)
    var detaches = 0, localReturns = 0, disconnects = 0
    var detachGate: (() async -> Void)?
    var snapshotHook: (() -> Void)?
    var detachAccepted = true
    var detachReadbackBinding = false
    let registry: LocalAudioParticipantRegistry
    let boot = UUID(), controller = UUID()
    init(_ registry: LocalAudioParticipantRegistry) { self.registry = registry }
    func start() async -> Bool {
        var receipt: LocalAudioParticipantReceipt?
        registry.register(.relay, bootId: boot, control: .init(fenceAndQuiesce: { request in
            let next = facts(request); receipt = next; return next
        }, inspect: { id in receipt?.operationId == id ? receipt : nil }, supportsForwarding: true))
        return true
    }
    func forwardingConfiguration(privacyGeneration: UUID) -> AudioForwardingConfiguration? {
        try? .init(controllerBootId: controller, privacyGeneration: privacyGeneration, membership: registry.snapshot)
    }
    func forwardingConfigure(privacyGeneration: UUID, admission: (@MainActor () -> Bool)? = nil) async -> AudioForwardingResult<AudioForwardingSnapshot>? { .accepted(value) }
    func forwardingBootstrap(peer: AudioForwardingPairedDevice, admission: (@MainActor () -> Bool)? = nil) async -> AudioForwardingResult<AudioForwardingBootstrap>? { nil }
    func forwardingEvidence(peer: AudioForwardingPairedDevice, connectionID: UUID,
                            operation: AudioForwardingEvidenceOperation, admission: (@MainActor () -> Bool)? = nil,
                            onSubmission: (@MainActor () -> Void)? = nil) async -> AudioForwardingResult<AudioForwardingSnapshot>? {
        guard admission?() != false else { return nil }
        onSubmission?()
        if operation == .detach {
            detaches += 1
            if let detachGate { await detachGate() }
            guard detachAccepted else { return nil }
            value = try! .init(revision: .init(value.revision.value + 1), intent: value.intent,
                               binding: detachReadbackBinding ? value.binding : nil)
        }
        return .accepted(value)
    }
    func forwardingSnapshot() async -> AudioForwardingResult<AudioForwardingSnapshot>? { snapshotHook?(); return .accepted(value) }
    func forwardingRequest(_ intent: AudioForwardingIntentRequest, peer: AudioForwardingPairedDevice,
                           credential: AudioForwardingCredential, admission: @escaping @MainActor () -> Bool) async -> AudioForwardingResult<AudioForwardingSnapshot>? { nil }
    func forwardingCommit(_ command: AudioForwardingCoordinator.Commit) async -> AudioForwardingResult<AudioForwardingSnapshot>? { nil }
    func forwardingDisconnect(_ binding: AudioForwardingBinding) async -> AudioForwardingResult<AudioForwardingSnapshot>? { disconnects += 1; return .accepted(value) }
    func forwardingLocalReturn(expectedRevision: AudioForwardingRevision, admission: @escaping @MainActor () -> Bool) async -> AudioForwardingResult<AudioForwardingSnapshot>? { localReturns += 1; value = try! .init(revision: .init(value.revision.value + 1), intent: nil, binding: nil); return .accepted(value) }
    func waitUntilExited(until deadline: ContinuousClock.Instant) async -> Bool { true }
    func lost() {}
}
@MainActor func facts(_ request: LocalAudioParticipantRequest) -> LocalAudioParticipantReceipt {
    .init(request, state: .quiescent, facts: .init(admissionFenced: true, startsSettled: true, mediaDetached: true, callbacksDrained: true, buffersEmpty: true, workersExited: true))
}
@MainActor final class InertHAL: HostAudioPrivacyHAL {
    var snapshot = PrivacyAudioSnapshot(devices: [
        .init(id: 10, uid: "builtin", transport: .builtIn, plugin: nil, inputChannels: 2, outputChannels: 2, inputMuted: false, outputMuted: false),
        .init(id: 20, uid: "BlackHole2ch_UID", transport: .virtual, plugin: "audio.existential.BlackHole2ch", inputChannels: 2, outputChannels: 2),
        .init(id: 30, uid: "BlackHole16ch_UID", transport: .virtual, plugin: "audio.existential.BlackHole16ch", inputChannels: 16, outputChannels: 16)
    ], input: 10, output: 10, systemOutput: 10)
    var restores = 0
    var original: PrivacyAudioSnapshot!
    func read() throws -> PrivacyAudioSnapshot { snapshot }
    func write(_ change: PrivacyAudioWrite) -> Bool { guard let next = snapshot.applying(change) else { return false }; snapshot = next; return true }
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool { true }
    func restoreLocal(_ state: LocalAudioState) -> Bool { restores += 1; snapshot = original; return state.matches(snapshot) }
}
