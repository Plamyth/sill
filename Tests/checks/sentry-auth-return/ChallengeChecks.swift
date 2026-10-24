import Foundation

enum LAPolicy { case deviceOwnerAuthentication, deviceOwnerAuthenticationWithBiometrics }
@MainActor final class LAContext {
    static var capable = true
    static var instances: [LAContext] = []
    static var capabilityHook: (() -> Void)?
    static var issueHook: (() -> Void)?
    var touchIDAuthenticationAllowableReuseDuration: TimeInterval = -1
    var localizedFallbackTitle: String?
    var capabilityPolicy: LAPolicy?
    var issuedPolicy: LAPolicy?
    var reason: String?
    var callback: ((Bool, Error?) -> Void)?
    var invalidations = 0
    init() { Self.instances.append(self) }
    func canEvaluatePolicy(_ policy: LAPolicy, error: inout NSError?) -> Bool {
        capabilityPolicy = policy
        Self.capabilityHook?()
        return Self.capable
    }
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, Error?) -> Void) {
        issuedPolicy = policy
        reason = localizedReason
        callback = reply
        Self.issueHook?()
    }
    func invalidate() { invalidations += 1 }
    func decline() { callback?(false, nil) }
}

@MainActor var count = 0
@MainActor func check(_ value: Bool, _ name: String) {
    guard value else { print("FAIL \(name)"); exit(1) }
    count += 1
    print("PASS \(name)")
}
@MainActor func settle(_ ready: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !ready(), ContinuousClock.now < deadline { await Task.yield() }
    check(ready(), "challenge observation completed within budget")
}

@MainActor final class ChallengeHAL: HostAudioPrivacyHAL {
    let snapshot = PrivacyAudioSnapshot(devices: [
        .init(id: 1, uid: "fixture-in", transport: .builtIn, plugin: nil,
              inputChannels: 1, outputChannels: 0, inputMuted: false, outputMuted: nil),
        .init(id: 2, uid: "fixture-out", transport: .builtIn, plugin: nil,
              inputChannels: 0, outputChannels: 2, inputMuted: nil, outputMuted: false)
    ], input: 1, output: 2, systemOutput: 2)
    var writes = 0, restores = 0
    func read() throws -> PrivacyAudioSnapshot { snapshot }
    func write(_ change: PrivacyAudioWrite) -> Bool { writes += 1; return false }
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool { true }
    func restoreLocal(_ state: LocalAudioState) -> Bool { restores += 1; return false }
}

@MainActor func challenges() async {
    let authentication = LocalAudioAuthentication()
    check(authentication.activeChallengeID == nil, "no challenge before OS capability check")
    LAContext.capable = false
    check(!(await authentication.evaluate(operationId: UUID())), "unavailable owner authentication rejects request")
    check(authentication.activeChallengeID == nil && LAContext.instances.last?.issuedPolicy == nil,
          "failed capability never exposes a challenge or issues authentication")
    LAContext.capable = true
    LAContext.capabilityHook = { check(authentication.activeChallengeID == nil, "capability check cannot expose a challenge") }
    LAContext.issueHook = { check(authentication.activeChallengeID == nil, "challenge appears only after evaluatePolicy is called") }
    let first = UUID()
    let request = Task { await authentication.evaluate(operationId: first) }
    await settle { authentication.activeChallengeID != nil }
    let context = LAContext.instances.last!
    check(authentication.activeChallengeID == first, "issued OS request exposes its exact operation")
    check(context.capabilityPolicy == .deviceOwnerAuthentication && context.issuedPolicy == .deviceOwnerAuthentication,
          "Touch ID and macOS login password use the same official owner policy")
    check(context.touchIDAuthenticationAllowableReuseDuration == 0 && context.localizedFallbackTitle == "macOS 로그인 암호 사용",
          "fresh authentication retains the native password fallback")
    check(!(await authentication.evaluate(operationId: UUID())) && authentication.activeChallengeID == first,
          "duplicate evaluate cannot replace an active challenge")
    authentication.cancel()
    check(authentication.activeChallengeID == nil && context.invalidations == 1, "cancel clears challenge before context invalidation")
    check(!(await request.value), "cancel never supplies authentication approval")
    let second = UUID()
    let next = Task { await authentication.evaluate(operationId: second) }
    await settle { authentication.activeChallengeID == second }
    context.decline()
    for _ in 0..<20 { await Task.yield() }
    check(authentication.activeChallengeID == second, "late callback cannot close the replacement challenge")
    LAContext.instances.last!.decline()
    check(!(await next.value) && authentication.activeChallengeID == nil, "failed authentication removes the challenge")
    let expires = Task { await authentication.evaluate(operationId: UUID()) }
    await settle { authentication.activeChallengeID != nil }
    check(!(await expires.value) && authentication.activeChallengeID == nil, "authentication expiry removes the challenge")
    LAContext.capabilityHook = nil
    LAContext.issueHook = nil

    for ending in ["decline", "cancel", "generation", "deadline", "mismatch"] {
        let startup = NativeAudioStartup()
        startup.construct { () }
        startup.participants.register(.relay, bootId: UUID(), control: .init(
            fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
        let hal = ChallengeHAL(), auth = LocalAudioAuthentication()
        var wrongIdentity = false
        let privacy = HostAudioPrivacy(hal: hal, latched: true, localState: try! LocalAudioState(hal.snapshot),
            authenticateLocal: { await auth.evaluate(operationId: $0) }, cancelAuthentication: { auth.cancel() },
            authenticationChallengeID: { wrongIdentity ? UUID() : auth.activeChallengeID }, nativeStartup: startup)
        var prepared: UUID?
        privacy.localAuthenticationWillBegin = { operation in
            check(auth.activeChallengeID == nil && privacy.localAuthenticationChallengeID == nil,
                  "\(ending) window snapshot precedes the actual OS challenge")
            prepared = operation
        }
        check(privacy.localAuthenticationChallengeID == nil, "\(ending) starts without an input exemption")
        let work = Task { await privacy.requestLocalReturn(budgetMilliseconds: ending == "deadline" ? 20 : 2000) }
        await settle { privacy.localAuthenticationChallengeID != nil }
        check(privacy.localAuthenticationChallengeID == auth.activeChallengeID,
              "\(ending) model exposes only its current actual challenge")
        check(prepared == auth.activeChallengeID, "\(ending) snapshot and active challenge share the operation")
        switch ending {
        case "cancel":
            work.cancel()
            check(privacy.localAuthenticationChallengeID == nil, "request cancellation removes challenge synchronously")
        case "generation":
            startup.participants.unregister(.relay)
            check(privacy.localAuthenticationChallengeID == nil, "membership generation change removes challenge synchronously")
        case "mismatch":
            wrongIdentity = true
            check(privacy.localAuthenticationChallengeID == nil, "mismatched OS operation never exposes a challenge")
            auth.cancel()
        case "decline": LAContext.instances.last!.decline()
        default:
            let limit = ContinuousClock.now.advanced(by: .milliseconds(25))
            while ContinuousClock.now < limit {}
            check(privacy.localAuthenticationChallengeID == nil,
                  "deadline removes challenge before the timeout task can run")
        }
        check(!(await work.value) && privacy.localAuthenticationChallengeID == nil,
              "\(ending) terminal request retains no challenge")
        check(privacy.latched && hal.writes == 0 && hal.restores == 0,
              "\(ending) never restores audio or clears the durable protection latch")
        privacy.stop()
    }
    let startup = NativeAudioStartup()
    startup.construct { () }
    startup.participants.register(.relay, bootId: UUID(), control: .init(
        fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
    let hal = ChallengeHAL(), auth = LocalAudioAuthentication()
    let privacy = HostAudioPrivacy(hal: hal, latched: true, localState: try! LocalAudioState(hal.snapshot),
        authenticateLocal: { await auth.evaluate(operationId: $0) }, cancelAuthentication: { auth.cancel() },
        authenticationChallengeID: { auth.activeChallengeID }, nativeStartup: startup)
    privacy.localAuthenticationWillBegin = { _ in startup.participants.unregister(.relay) }
    let contexts = LAContext.instances.count
    check(!(await privacy.requestLocalReturn(budgetMilliseconds: 2000)), "snapshot generation change cancels the request")
    check(contexts == LAContext.instances.count && privacy.localAuthenticationChallengeID == nil,
          "snapshot invalidation prevents issuing any OS challenge")
    check(privacy.latched && hal.writes == 0 && hal.restores == 0, "invalidated snapshot preserves audio protection")
    privacy.stop()
    let humanStartup = NativeAudioStartup()
    humanStartup.construct { () }
    humanStartup.participants.register(.relay, bootId: UUID(), control: .init(
        fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
    let humanHAL = ChallengeHAL(), humanAuth = LocalAudioAuthentication()
    let humanPrivacy = HostAudioPrivacy(hal: humanHAL, latched: true,
        localState: try! LocalAudioState(humanHAL.snapshot),
        authenticateLocal: { await humanAuth.evaluate(operationId: $0) },
        cancelAuthentication: { humanAuth.cancel() },
        authenticationChallengeID: { humanAuth.activeChallengeID }, nativeStartup: humanStartup)
    let human = Task { await humanPrivacy.requestLocalReturn(budgetMilliseconds: 20) }
    await settle { humanPrivacy.localAuthenticationChallengeID != nil }
    try? await Task.sleep(for: .milliseconds(35))
    check(humanPrivacy.localAuthenticationChallengeID != nil,
          "human authentication wait does not spend the participant work budget")
    LAContext.instances.last!.decline()
    check(!(await human.value) && humanPrivacy.localAuthenticationChallengeID == nil,
          "declined extended human wait closes the exact request without approval")
    check(humanPrivacy.latched && humanHAL.writes == 0 && humanHAL.restores == 0,
          "extended human wait never changes audio or the protection latch")
    humanPrivacy.stop()
    print("PASS \(count) native challenge checks; no actual OS authentication or positive approval supplied")
}

Task { @MainActor in await challenges(); exit(0) }
dispatchMain()
