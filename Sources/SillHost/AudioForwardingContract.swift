import Foundation
import StreamProtocol

extension AudioForwardingConfiguration {
    init(controllerBootId: UUID, privacyGeneration: UUID, membership: LocalAudioParticipantRegistry.Snapshot) throws {
        guard Set(membership.boots.keys) == Set(LocalAudioParticipantID.allCases), membership.revision < UInt64.max else {
            throw AudioForwardingFailure.invalidMembership
        }
        let registryRevision = AudioForwardingRevision(membership.revision)
        let members = try membership.boots.map { try Member(participantId: $0.key.rawValue, bootId: $0.value) }
            .sorted { $0.participantId < $1.participantId }
        try self.init(controllerBootId: controllerBootId, privacyGeneration: privacyGeneration, registryRevision: registryRevision, members: members)
    }
}

extension AudioForwardingBinding {
    func participantRequest(for participant: LocalAudioParticipantID, budgetMilliseconds: Int) -> LocalAudioParticipantRequest? {
        guard phase == .quiescing,
              let member = configuration.members.first(where: { $0.participantId == participant.rawValue }) else { return nil }
        let request = LocalAudioParticipantRequest(schemaVersion: 1, operationId: operationId,
            privacyGeneration: configuration.privacyGeneration, registryRevision: String(configuration.registryRevision.value),
            participantId: participant, bootId: member.bootId, budgetMilliseconds: budgetMilliseconds)
        return request.isValid ? request : nil
    }
}
