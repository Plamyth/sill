import Foundation

@MainActor
func fixturePrivacy(hal: any HostAudioPrivacyHAL, latched: Bool = false, persist: @escaping () -> Bool = { true },
                    localState: LocalAudioState? = nil, saveLocal: @escaping (LocalAudioState?) -> Bool = { _ in true },
                    clearLatch: @escaping () -> Bool = { false }, authenticateLocal: @escaping (UUID) async -> Bool = { _ in false },
                    cancelAuthentication: @escaping () -> Void = {}, nativeStartup: NativeAudioStartup? = nil) -> HostAudioPrivacy {
    let startup = nativeStartup ?? NativeAudioStartup()
    if nativeStartup == nil { startup.construct { () } }
    let privacy = HostAudioPrivacy(hal: hal, latched: latched, persist: persist, localState: localState, saveLocal: saveLocal,
        clearLatch: clearLatch, authenticateLocal: authenticateLocal, cancelAuthentication: cancelAuthentication, nativeStartup: startup)
    var acknowledged = false
    startup.revoke = { [weak privacy] in
        acknowledged = await privacy?.revokeForLocalReturn?() ?? false
        return acknowledged
    }
    startup.readFacts = { [weak privacy] in
        if let inspection = privacy?.inspectForLocalReturn { return inspection() }
        return .init(admissionFenced: startup.participants.isFenced, startsSettled: acknowledged,
                     mediaDetached: acknowledged, callbacksDrained: acknowledged, buffersEmpty: acknowledged, workersExited: acknowledged)
    }
    var receipt: LocalAudioParticipantReceipt?
    startup.participants.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: { request in
        let facts = LocalAudioParticipantFacts(admissionFenced: startup.participants.isFenced,
            startsSettled: true, mediaDetached: true, callbacksDrained: true, buffersEmpty: true, workersExited: true)
        let result = LocalAudioParticipantReceipt(request, state: .quiescent, facts: facts)
        receipt = result
        return result
    }, inspect: { id in receipt?.operationId == id ? receipt : nil }))
    return privacy
}
