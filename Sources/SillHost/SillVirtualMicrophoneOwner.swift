import CoreAudio
import Foundation
import StreamProtocol

@MainActor
package final class SillVirtualMicrophoneOwner: HostMicrophoneOriginalOwner {
    private let ownerID = UUID()
    private let routeGeneration = UUID()
    private enum PrivacyProof: Equatable {
        case local(generation: UUID, membership: LocalAudioParticipantRegistry.Snapshot)
        case forwarding(HostAudioPrivacy.ForwardingProof)
    }
    private struct Grant {
        let value: HostLocalOwnerGrant
        let proof: PrivacyProof
    }
    private var grants: [UUID: Grant] = [:]
    private var activeLease: VirtualMicrophoneLease?

    private let ops: HALMicrophoneOperations
    private let privacy: HostAudioPrivacy?
    package convenience init(privacy: HostAudioPrivacy? = nil) { self.init(ops: .native, privacy: privacy) }
    init(ops: HALMicrophoneOperations, privacy: HostAudioPrivacy? = nil) {
        self.ops = ops; self.privacy = privacy
    }

    package func microphoneGrant(peer: UUID, source: StreamSource, inputGeneration: UUID,
                                  videoEpoch: UUID, fingerprint: Data) -> HostLocalOwnerGrant? {
        guard let proof = privacyProof(),
              let target = VirtualMicrophoneRoute.discover(ops: ops), source != .none,
              !fingerprint.isEmpty, proofCurrent(proof) else { return nil }
        if let issued = grants[peer] {
            let old = issued.value
            if old.scope.source == source, old.scope.inputGeneration == inputGeneration,
               old.scope.videoEpoch == videoEpoch, old.fingerprint == fingerprint,
               old.destination == target.destination, issued.proof == proof,
               old.valid(at: DispatchTime.now().uptimeNanoseconds) { return old }
            old.revoke()
        }
        let scope = MicrophoneScope(peer: peer, source: source,
            inputGeneration: inputGeneration, videoEpoch: videoEpoch,
            destination: UUID(), capability: UUID())
        let grant = HostLocalOwnerGrant(owner: ownerID, callGeneration: routeGeneration,
            scope: scope, fingerprint: fingerprint, destination: target.destination,
            expiresAt: .max)
        grants[peer] = Grant(value: grant, proof: proof)
        return grant
    }

    private func privacyProof() -> PrivacyProof? {
        guard let privacy else { return nil }
        if privacy.participants.isFenced {
            guard let proof = privacy.forwardingProof() else { return nil }
            return .forwarding(proof)
        }
        let proof = PrivacyProof.local(generation: privacy.forwardingPrivacyGeneration,
                                       membership: privacy.participants.snapshot)
        return proofCurrent(proof) ? proof : nil
    }

    private func proofCurrent(_ proof: PrivacyProof) -> Bool {
        guard let privacy else { return false }
        switch proof {
        case .local(let generation, let membership):
            return privacy.verify() && !privacy.participants.isFenced &&
                privacy.forwardingPrivacyGeneration == generation && privacy.participants.snapshot == membership
        case .forwarding(let forwarding):
            return privacy.participants.isFenced && privacy.forwardingProofCurrent(forwarding) &&
                privacy.forwardingProof() == forwarding && privacy.forwardingProofCurrent(forwarding)
        }
    }

    private func grantCurrent(_ grant: HostLocalOwnerGrant) -> Bool {
        guard grant.owner == ownerID, grant.callGeneration == routeGeneration,
              let issued = grants[grant.scope.peer], issued.value === grant else { return false }
        guard grant.valid(at: DispatchTime.now().uptimeNanoseconds), proofCurrent(issued.proof) else {
            grant.revoke()
            return false
        }
        return true
    }

    package func prepareMicrophone(grant: HostLocalOwnerGrant,
                                    render: MicrophoneRenderBuffer) async -> HostMicrophonePreparation {
        guard grantCurrent(grant), render.grant === grant,
              let target = VirtualMicrophoneRoute.discover(ops: ops),
              target.destination == grant.destination else {
            return HostMicrophonePreparation(resource: nil, error: "iPad 마이크 입력 대상이 변경되었습니다.")
        }
        guard activeLease == nil else {
            return HostMicrophonePreparation(resource: nil, error: "다른 iPad 마이크 연결을 먼저 종료하세요.")
        }
        let activation = target.acquire(current: { [weak self] in self?.grantCurrent(grant) == true })
        guard let lease = activation.lease else {
            return HostMicrophonePreparation(resource: nil,
                error: activation.error ?? "Mac 가상 마이크가 이미 사용 중이거나 기본 입력을 전환할 수 없습니다.")
        }
        activeLease = lease
        if let error = activation.error {
            return HostMicrophonePreparation(
                resource: LeasedMicrophoneSink(lease: lease, sink: nil, owner: self), error: error)
        }
        let result = await HALMicrophoneSink.prepare(grant: grant, render: render, ops: ops)
        let current = lease.isCurrent
        if !current { render.close() }
        return HostMicrophonePreparation(
            resource: LeasedMicrophoneSink(lease: lease, sink: result.resource, owner: self),
            error: result.error ?? (current ? nil : "Mac 오디오 보호 또는 마이크 입력 범위가 변경되었습니다."))
    }

    package func restoreMicrophoneForExit() {
        for grant in grants.values { grant.value.revoke() }
        _ = activeLease?.restore()
        activeLease = nil
    }

    fileprivate func finished(_ lease: VirtualMicrophoneLease) {
        if activeLease === lease, lease.isClosed { activeLease = nil }
    }
}

@MainActor
private final class LeasedMicrophoneSink: HostMicrophoneSink {
    let lease: VirtualMicrophoneLease
    let sink: (any HostMicrophoneSink)?
    weak var owner: SillVirtualMicrophoneOwner?
    init(lease: VirtualMicrophoneLease, sink: (any HostMicrophoneSink)?, owner: SillVirtualMicrophoneOwner) {
        self.lease = lease; self.sink = sink; self.owner = owner
    }
    func runtimeValid() -> Bool { lease.isCurrent && sink?.runtimeValid() == true }
    func close() async -> String? {
        let sinkError = await sink?.close()
        let routeError = lease.restore()
        owner?.finished(lease)
        let errors = [sinkError, routeError].compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }
    func retryClose() async -> String? {
        let sinkError = await sink?.retryClose()
        let routeError = lease.restore()
        owner?.finished(lease)
        let errors = [sinkError, routeError].compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }
}

@MainActor
private struct VirtualMicrophoneRoute {
    let device: AudioDeviceID
    let destination: HostMicrophoneDestination

    static func discover(ops: HALMicrophoneOperations) -> Self? {
        let registry = HALMicrophoneDeviceRegistry(ops: ops)
        let bundleID = "audio.existential.BlackHole2ch"
        guard let devices = try? registry.devices(pluginBundleID: bundleID), devices.count == 1 else { return nil }
        let candidates = devices.compactMap { device -> Self? in
            guard let uid = try? registry.string(device, kAudioDevicePropertyDeviceUID),
                  uid == "BlackHole2ch_UID",
                  (try? registry.resolve(uid)) == device,
                  (try? registry.validate(device, uid: uid, scope: kAudioObjectPropertyScopeOutput,
                      channels: 2, pluginBundleID: bundleID)) != nil,
                  (try? registry.validate(device, uid: uid, scope: kAudioObjectPropertyScopeInput,
                      channels: 2, pluginBundleID: bundleID)) != nil,
                  let destination = HostMicrophoneDestination(outputUID: uid, inputUID: uid,
                      pluginBundleID: bundleID, outputChannels: 2, inputChannels: 2,
                      outputChannel: 0, inputChannel: 0) else { return nil }
            return Self(device: device, destination: destination)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func acquire(current: @escaping @MainActor () -> Bool) -> (lease: VirtualMicrophoneLease?, error: String?) {
        guard current() else {
            return (nil, "Mac 오디오 보호를 확인할 수 없어 마이크 연결을 시작하지 않았습니다.")
        }
        // Privacy already selected BlackHole2. The owner checked no active lease before here.
        // A call app consuming the virtual input is expected, so runningSomewhere is not a veto.
        return (VirtualMicrophoneLease(current: current), nil)
    }
}

@MainActor
private final class VirtualMicrophoneLease {
    private let current: @MainActor () -> Bool
    private var closed = false
    var isClosed: Bool { closed }
    init(current: @escaping @MainActor () -> Bool) { self.current = current }
    var isCurrent: Bool { !closed && current() }
    func restore() -> String? {
        // Cleanup retires ownership only. It must never restore an earlier physical default.
        closed = true
        return nil
    }
}
