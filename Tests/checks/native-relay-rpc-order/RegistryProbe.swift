extension LocalAudioParticipantRegistry {
    func checkedFence(_ request: LocalAudioParticipantRequest) async -> LocalAudioParticipantReceipt? {
        await members[.relay]?.control.fenceAndQuiesce(request)
    }
    func checkedInspect(_ operationId: UUID) async -> LocalAudioParticipantReceipt? {
        await members[.relay]?.control.inspect(operationId)
    }
}
