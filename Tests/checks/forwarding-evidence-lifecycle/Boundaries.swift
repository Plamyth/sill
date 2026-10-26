import Foundation
import StreamProtocol

enum PrivacyAudioScope { case input, output }
struct AudioForwardingPairedDevice {
    let id: AudioForwardingDeviceID
    let pairingGeneration: UUID
}
@MainActor final class HostAudioPrivacy {
    struct ForwardingProof {
        let privacyGeneration: UUID
        let membership: LocalAudioParticipantRegistry.Snapshot
    }
    let participants: LocalAudioParticipantRegistry
    var latched = true
    var arms = 0
    var forwardingIntentAllowed = true
    var forwardingPrivacyGeneration = UUID()
    init(_ participants: LocalAudioParticipantRegistry) { self.participants = participants }
    func armAndVerify() -> Bool { arms += 1; latched = true; forwardingPrivacyGeneration = UUID(); return forwardingIntentAllowed }
    func forwardingProof() -> ForwardingProof? {
        guard latched, forwardingIntentAllowed else { return nil }
        return .init(privacyGeneration: forwardingPrivacyGeneration, membership: participants.snapshot)
    }
    func forwardingProofCurrent(_ proof: ForwardingProof) -> Bool {
        forwardingIntentAllowed && proof.privacyGeneration == forwardingPrivacyGeneration && participants.matches(proof.membership)
    }
}
@MainActor final class HostSentry {
    struct ForwardingProof: Equatable { let value: UUID }
    let value = UUID()
    func activate() -> Bool { true }
    func forwardingProof() -> ForwardingProof? { .init(value: value) }
    func forwardingProofCurrent(_ proof: ForwardingProof) -> Bool { proof.value == value }
}
