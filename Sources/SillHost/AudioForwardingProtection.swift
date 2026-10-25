import StreamProtocol
import Foundation

@MainActor
final class AudioForwardingProtection {
    private struct Proof {
        let readback: AudioForwardingCoordinator.ProtectionReadback
        let audio: HostAudioPrivacy.ForwardingProof?
    }
    private let audio: HostAudioPrivacy
    private let configuration: () -> AudioForwardingConfiguration?
    private let quiescenceCurrent: (AudioForwardingCoordinator.Scope) -> Bool
    private var proof: Proof?
    private var revision = UUID()

    init(audio: HostAudioPrivacy,
         configuration: @escaping () -> AudioForwardingConfiguration?,
         quiescenceCurrent: @escaping (AudioForwardingCoordinator.Scope) -> Bool) {
        self.audio = audio; self.configuration = configuration; self.quiescenceCurrent = quiescenceCurrent
    }

    func invalidate() { revision = UUID(); proof = nil }

    func readback(_ scope: AudioForwardingCoordinator.Scope,
                  until deadline: ContinuousClock.Instant) -> AudioForwardingCoordinator.ProtectionReadback? {
        invalidate()
        let revision = self.revision
        guard !Task.isCancelled, ContinuousClock.now < deadline, audio.forwardingIntentAllowed,
              quiescenceCurrent(scope) else { return nil }
        let audioProof = audio.forwardingProof()
        guard !scope.requiresAudioIsolation || audioProof != nil else { return nil }
        let configuration = configuration()
        guard !Task.isCancelled, ContinuousClock.now < deadline,
              self.revision == revision, configuration == scope.binding.configuration, matches(scope.binding.configuration),
              quiescenceCurrent(scope), audioProof.map({ audio.forwardingProofCurrent($0) }) ?? !scope.requiresAudioIsolation else { return nil }
        let readback = AudioForwardingCoordinator.ProtectionReadback(scope: scope, observedAt: ContinuousClock.now,
                                                                     sentryVerified: false, localMutedVerified: audioProof != nil)
        proof = Proof(readback: readback, audio: audioProof)
        return readback
    }

    func current(_ readback: AudioForwardingCoordinator.ProtectionReadback) -> Bool {
        let configuration = configuration()
        guard let proof, proof.readback == readback, configuration == readback.scope.binding.configuration,
              !Task.isCancelled, audio.forwardingIntentAllowed, matches(readback.scope.binding.configuration),
              quiescenceCurrent(readback.scope),
              proof.audio.map({ audio.forwardingProofCurrent($0) }) ?? !readback.scope.requiresAudioIsolation else { return false }
        return true
    }

    private func matches(_ configuration: AudioForwardingConfiguration) -> Bool {
        let membership = audio.participants.snapshot
        return audio.forwardingPrivacyGeneration == configuration.privacyGeneration &&
        membership.revision == configuration.registryRevision.value &&
        membership.boots.count == configuration.members.count && configuration.members.allSatisfy {
            LocalAudioParticipantID(rawValue: $0.participantId).flatMap { membership.boots[$0] } == $0.bootId
        }
    }
}
