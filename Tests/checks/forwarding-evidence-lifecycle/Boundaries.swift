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
    var forwardingIntentAllowed = true
    let forwardingPrivacyGeneration = UUID()
    init(_ participants: LocalAudioParticipantRegistry) { self.participants = participants }
    func armAndVerify() -> Bool { latched = true; return forwardingIntentAllowed }
    func forwardingProof() -> ForwardingProof? {
        guard forwardingIntentAllowed else { return nil }
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
