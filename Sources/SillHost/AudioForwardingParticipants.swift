import Foundation

@MainActor
final class AudioForwardingParticipants {
    private let registry: LocalAudioParticipantRegistry
    private var scope: AudioForwardingCoordinator.Scope?
    private var ticket: LocalAudioParticipantRegistry.ForwardingTicket?

    init(registry: LocalAudioParticipantRegistry) { self.registry = registry }

    @discardableResult
    func begin(_ scope: AudioForwardingCoordinator.Scope) -> Bool {
        let binding = scope.binding, configuration = binding.configuration
        var boots: [LocalAudioParticipantID: UUID] = [:]
        for member in configuration.members {
            guard let id = LocalAudioParticipantID(rawValue: member.participantId), boots[id] == nil else { return false }
            boots[id] = member.bootId
        }
        let membership = LocalAudioParticipantRegistry.Snapshot(revision: configuration.registryRevision.value, boots: boots)
        let identity = [binding.pairedDeviceId.hex, binding.intentGeneration.uuidString,
            binding.transportId.uuidString, binding.transportKind.rawValue,
            configuration.controllerBootId.uuidString, scope.intentId.uuidString,
            String(scope.intentRevision.value), String(scope.inputDesired), String(scope.outputDesired)]
        guard let ticket = registry.beginForwarding(epoch: binding.bindingEpoch, intentGeneration: binding.intentGeneration, operationId: binding.operationId,
            privacyGeneration: configuration.privacyGeneration, membership: membership, identity: identity) else { return false }
        self.scope = scope; self.ticket = ticket
        return true
    }

    func prepare(_ scope: AudioForwardingCoordinator.Scope, request: LocalAudioParticipantRequest,
                 until deadline: ContinuousClock.Instant) async -> LocalAudioParticipantReceipt? {
        guard self.scope == scope, let ticket,
              scope.binding.participantRequest(for: request.participantId, budgetMilliseconds: request.budgetMilliseconds) == request else { return nil }
        return await registry.prepareForwarding(ticket, request: request, until: deadline)
    }

    func inspect(_ scope: AudioForwardingCoordinator.Scope, request: LocalAudioParticipantRequest,
                 until deadline: ContinuousClock.Instant) async -> LocalAudioParticipantReceipt? {
        guard self.scope == scope, let ticket,
              scope.binding.participantRequest(for: request.participantId, budgetMilliseconds: request.budgetMilliseconds) == request else { return nil }
        return await registry.inspectForwarding(ticket, request: request, until: deadline)
    }

    func invalidate() {
        if let ticket { registry.cancelForwarding(ticket) }
        scope = nil; ticket = nil
    }
}
