import Foundation

@MainActor
final class AudioForwardingProtection {
    private struct Proof {
        let readback: AudioForwardingCoordinator.ProtectionReadback
        let audio: HostAudioPrivacy.ForwardingProof
        let sentry: HostSentry.ForwardingProof
    }
    private let audio: HostAudioPrivacy
    private let sentry: HostSentry
    private let configuration: () -> AudioForwardingConfiguration?
    private var proof: Proof?
    private var revision = UUID()

    init(audio: HostAudioPrivacy, sentry: HostSentry,
         configuration: @escaping () -> AudioForwardingConfiguration?) {
        self.audio = audio; self.sentry = sentry; self.configuration = configuration
    }

    func invalidate() { revision = UUID(); proof = nil }

    func readback(_ scope: AudioForwardingCoordinator.Scope,
                  until deadline: ContinuousClock.Instant) -> AudioForwardingCoordinator.ProtectionReadback? {
        invalidate()
        let revision = self.revision
        guard !Task.isCancelled, ContinuousClock.now < deadline,
              let audioProof = audio.forwardingProof(), let sentryProof = sentry.forwardingProof() else { return nil }
        let configuration = configuration()
        guard !Task.isCancelled, ContinuousClock.now < deadline,
              self.revision == revision, configuration == scope.binding.configuration, matches(audioProof, scope.binding.configuration),
              audio.forwardingProofCurrent(audioProof), sentry.forwardingProofCurrent(sentryProof) else { return nil }
        let readback = AudioForwardingCoordinator.ProtectionReadback(scope: scope, observedAt: ContinuousClock.now,
                                                                     sentryVerified: true, localMutedVerified: true)
        proof = Proof(readback: readback, audio: audioProof, sentry: sentryProof)
        return readback
    }

    func current(_ readback: AudioForwardingCoordinator.ProtectionReadback) -> Bool {
        let configuration = configuration()
        guard let proof, proof.readback == readback, configuration == readback.scope.binding.configuration,
              !Task.isCancelled, matches(proof.audio, readback.scope.binding.configuration),
              audio.forwardingProofCurrent(proof.audio), sentry.forwardingProofCurrent(proof.sentry) else { return false }
        return true
    }

    private func matches(_ proof: HostAudioPrivacy.ForwardingProof, _ configuration: AudioForwardingConfiguration) -> Bool {
        proof.privacyGeneration == configuration.privacyGeneration &&
        proof.membership.revision == configuration.registryRevision.value &&
        proof.membership.boots.count == configuration.members.count && configuration.members.allSatisfy {
            LocalAudioParticipantID(rawValue: $0.participantId).flatMap { proof.membership.boots[$0] } == $0.bootId
        }
    }
}
