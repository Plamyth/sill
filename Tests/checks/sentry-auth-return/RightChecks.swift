import Foundation

@MainActor final class NSWindow {}
@MainActor final class LocalAuthenticationPresentation {
    static var available = true
    static var instances: [LocalAuthenticationPresentation] = []
    private(set) var window: NSWindow?
    private var operationID: UUID?
    var intact = true
    var invalidated: (() -> Void)?
    var active: Bool { window != nil }
    init() { Self.instances.append(self) }
    func begin(invalidated: @escaping @MainActor () -> Void) -> NSWindow? {
        guard Self.available else { return nil }
        self.invalidated = invalidated
        let window = NSWindow()
        self.window = window
        return window
    }
    func begin(operationID: UUID, invalidated: @escaping @MainActor () -> Void) -> NSWindow? {
        self.operationID = operationID
        return begin(invalidated: invalidated)
    }
    func matches(operationID: UUID) -> Bool { intact && self.operationID == operationID && window != nil }
    func end() { window = nil; operationID = nil }
}
enum LABiometryFallbackRequirement: Equatable { case devicePasscode }
enum LAAuthenticationRequirement: Equatable { case biometry(fallback: LABiometryFallbackRequirement) }
@MainActor final class LARight {
    enum State: Int { case unknown, authorizing, authorized, notAuthorized }
    static var instances: [LARight] = []
    static var capable = true
    static var capabilityHook: (() -> Void)?
    static var issueHook: (() -> Void)?
    static var holdCapability = false
    static var holdDeauthorization = false
    static var initialState = State.unknown
    var state: State
    let requirement: LAAuthenticationRequirement
    var anchor: NSWindow?
    var callback: ((Error?) -> Void)?
    var capabilityCallback: ((Error?) -> Void)?
    var deauthorizationCallbacks: [() -> Void] = []
    var deauthorizationCalls = 0
    init(requirement: LAAuthenticationRequirement) {
        self.requirement = requirement
        state = Self.initialState
        Self.instances.append(self)
    }
    func checkCanAuthorize(completion: @escaping (Error?) -> Void) {
        Self.capabilityHook?()
        if Self.holdCapability { capabilityCallback = completion }
        else { completion(Self.capable ? nil : NSError(domain: "inert", code: -1)) }
    }
    func deauthorize(completion: @escaping () -> Void) {
        deauthorizationCalls += 1
        if Self.holdDeauthorization { deauthorizationCallbacks.append(completion) }
        else { state = .notAuthorized; completion() }
    }
    func completeDeauthorization() {
        guard !deauthorizationCallbacks.isEmpty else { return }
        state = .notAuthorized
        deauthorizationCallbacks.removeFirst()()
    }
    func authorize(localizedReason: String, in window: NSWindow, completion: @escaping (Error?) -> Void) {
        anchor = window
        authorize(localizedReason: localizedReason, completion: completion)
    }
    func authorize(localizedReason: String, completion: @escaping (Error?) -> Void) {
        state = .authorizing
        callback = completion
        Self.issueHook?()
    }
    func complete(_ state: State, error: Error? = nil) {
        self.state = state
        callback?(error)
    }
    func decline() { complete(.notAuthorized, error: NSError(domain: "inert", code: -2)) }
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

@MainActor func drain() async { for _ in 0..<40 { await Task.yield() } }
@MainActor func challenges() async {
    let authentication = LocalAudioAuthentication()
    check(authentication.activeChallengeID == nil, "new right starts without active challenge")
    LARight.capable = false
    check(!(await authentication.evaluate(operationId: UUID())), "unavailable right rejects request")
    await drain()
    check(LARight.instances.last?.anchor == nil && authentication.activeChallengeID == nil,
          "capability failure cannot issue anchored UI or input exemption")
    LARight.capable = true
    LARight.capabilityHook = { check(authentication.activeChallengeID == nil, "capability check is not authorization") }
    LARight.issueHook = {
        check(authentication.activeChallengeID == nil, "challenge appears only after native authorize is issued")
        let right = LARight.instances.last!
        check(right.anchor != nil && right.anchor === LocalAuthenticationPresentation.instances.last?.window,
              "native authorize receives the exact owned builtin NSWindow anchor")
        check(right.deauthorizationCalls == 1, "new right is deauthorized before the authorization request")
    }
    let first = UUID()
    let work = Task { await authentication.evaluate(operationId: first) }
    await settle { authentication.activeChallengeID == first }
    let firstRight = LARight.instances.last!
    check(firstRight.requirement == .biometry(fallback: .devicePasscode), "Touch ID retains official device password fallback")
    let rights = LARight.instances.count
    check(!(await authentication.evaluate(operationId: UUID())) && LARight.instances.count == rights,
          "duplicate request neither replaces the challenge nor constructs another right")
    authentication.cancel()
    check(authentication.activeChallengeID == nil && LocalAuthenticationPresentation.instances.last?.active == false,
          "cancel removes challenge and owned anchor immediately")
    check(!(await work.value), "cancel supplies no authentication approval")
    check(firstRight.deauthorizationCalls == 2, "cancel requests native deauthorization")
    await drain()
    check(!(await authentication.evaluate(operationId: UUID())) && LARight.instances.count == rights,
          "deauthorization acknowledgment alone cannot prove pending native UI ended")
    firstRight.complete(.authorized)
    await drain()
    check(firstRight.deauthorizationCalls == 3 && firstRight.state == .notAuthorized,
          "late success is deauthorized again after its callback drains")
    let second = UUID()
    let next = Task { await authentication.evaluate(operationId: second) }
    await settle { authentication.activeChallengeID == second }
    let secondRight = LARight.instances.last!
    check(firstRight !== secondRight, "every new attempt owns a fresh right instance")
    firstRight.callback?(nil)
    await drain()
    check(authentication.activeChallengeID == second, "retired callback cannot close a replacement challenge")
    secondRight.decline()
    check(!(await next.value), "native failure cannot approve return")
    await drain()
    LARight.capabilityHook = nil
    LARight.issueHook = nil

    LocalAuthenticationPresentation.available = false
    check(!(await authentication.evaluate(operationId: UUID())), "missing builtin anchor rejects authorization")
    check(LARight.instances.last?.anchor == nil && authentication.activeChallengeID == nil,
          "missing builtin anchor never issues native authorize")
    LocalAuthenticationPresentation.available = true
    await drain()

    LARight.initialState = .authorized
    check(!(await authentication.evaluate(operationId: UUID())), "a newly supplied right must start unknown")
    await drain()
    check(LARight.instances.last?.anchor == nil && LARight.instances.last?.state == .notAuthorized,
          "unexpected initial authority is revoked without issuing anchored UI")
    LARight.initialState = .unknown

    LARight.holdDeauthorization = true
    let resetMismatch = Task { await authentication.evaluate(operationId: UUID()) }
    await settle { LARight.instances.last?.deauthorizationCallbacks.isEmpty == false }
    let resetRight = LARight.instances.last!
    resetRight.state = .authorized
    let resetCallback = resetRight.deauthorizationCallbacks.removeFirst()
    LARight.holdDeauthorization = false
    resetCallback()
    check(!(await resetMismatch.value) && resetRight.anchor == nil,
          "reset completion with authorized state cannot proceed to native authorize")
    await drain()

    LARight.holdDeauthorization = true
    let resetExpired = Task { await authentication.evaluate(operationId: UUID()) }
    await settle { LARight.instances.last?.deauthorizationCallbacks.isEmpty == false }
    let pendingReset = LARight.instances.last!
    check(!(await resetExpired.value) && pendingReset.anchor == nil,
          "deadline during preauthorization reset never constructs an anchor or issues native UI")
    LARight.holdDeauthorization = false
    while !pendingReset.deauthorizationCallbacks.isEmpty { pendingReset.completeDeauthorization() }
    await drain()

    let sameID = UUID()
    let topology = Task { await authentication.evaluate(operationId: sameID) }
    await settle { authentication.activeChallengeID == sameID }
    let topologyRight = LARight.instances.last!
    let oldInvalidation = LocalAuthenticationPresentation.instances.last!.invalidated
    oldInvalidation?()
    check(!(await topology.value) && authentication.activeChallengeID == nil,
          "screen/session invalidation rejects return and clears challenge")
    topologyRight.decline()
    await drain()
    let replacement = Task { await authentication.evaluate(operationId: sameID) }
    await settle { authentication.activeChallengeID == sameID }
    oldInvalidation?()
    topologyRight.callback?(nil)
    await drain()
    check(authentication.activeChallengeID == sameID && LocalAuthenticationPresentation.instances.last?.active == true,
          "same operation retry ignores retired window and authorization callbacks")
    replacement.cancel()
    LARight.instances.last!.complete(.authorized)
    check(!(await replacement.value), "task cancellation wins over a queued authorized callback")
    await drain()

    let expired = Task { await authentication.evaluate(operationId: UUID()) }
    await settle { authentication.activeChallengeID != nil }
    let expiredRight = LARight.instances.last!
    check(!(await expired.value) && authentication.activeChallengeID == nil,
          "provider deadline closes local challenge without waiting for native callback")
    let beforeRetry = LARight.instances.count
    check(!(await authentication.evaluate(operationId: UUID())) && LARight.instances.count == beforeRetry,
          "expired pending native UI cannot overlap a fresh authorization")
    expiredRight.complete(.authorized)
    await drain()
    check(expiredRight.state == .notAuthorized, "success arriving after provider expiry is revoked")

    for (state, error, expected) in [(LARight.State.authorized, nil, true),
        (.authorized, NSError(domain: "inert", code: -3), false), (.notAuthorized, nil, false),
        (.unknown, nil, false), (.authorizing, nil, false)] as [(LARight.State, NSError?, Bool)] {
        let auth = LocalAudioAuthentication()
        let request = Task { await auth.evaluate(operationId: UUID()) }
        await settle { auth.activeChallengeID != nil }
        LARight.instances.last!.complete(state, error: error)
        check((await request.value) == expected, "only nil error with authorized state can approve: \(state)/\(error?.code ?? 0)")
        check(auth.activeChallengeID == nil && LocalAuthenticationPresentation.instances.last?.active == false,
              "terminal native result closes the owned challenge and anchor")
        await drain()
        check(LARight.instances.last?.state == .notAuthorized, "terminal native right is deauthorized")
    }

    let detachedAuth = LocalAudioAuthentication()
    let detached = Task { await detachedAuth.evaluate(operationId: UUID()) }
    await settle { detachedAuth.activeChallengeID != nil }
    LocalAuthenticationPresentation.instances.last!.intact = false
    LARight.instances.last!.complete(.authorized)
    check(!(await detached.value), "detached authentication container cannot accept a late authorized result")
    await drain()

    for stage in ["capability", "reset", "retirement"] {
        let auth = LocalAudioAuthentication()
        LARight.holdCapability = stage == "capability"
        LARight.holdDeauthorization = stage != "capability"
        let request = Task { await auth.evaluate(operationId: UUID()) }
        if stage == "capability" { await settle { LARight.instances.last?.capabilityCallback != nil } }
        else { await settle { LARight.instances.last?.deauthorizationCallbacks.isEmpty == false } }
        let right = LARight.instances.last!
        if stage == "retirement" {
            right.completeDeauthorization()
            await settle { auth.activeChallengeID != nil }
        }
        auth.cancel()
        check(!(await request.value) && auth.activeChallengeID == nil,
              "\(stage) cancellation is locally bounded before native cleanup callbacks")
        let countBefore = LARight.instances.count
        check(!(await auth.evaluate(operationId: UUID())) && countBefore == LARight.instances.count,
              "\(stage) cleanup uncertainty blocks a new right")
        LARight.holdCapability = false
        LARight.holdDeauthorization = false
        right.capabilityCallback?(nil)
        if stage == "retirement" { right.complete(.authorized) }
        while !right.deauthorizationCallbacks.isEmpty { right.completeDeauthorization() }
        await drain()
        check(right.state == .notAuthorized, "\(stage) cleanup leaves no authorized retired right")
        let retryID = UUID()
        let retry = Task { await auth.evaluate(operationId: retryID) }
        await settle { auth.activeChallengeID == retryID }
        LARight.instances.last!.decline()
        check(!(await retry.value), "\(stage) drained cleanup permits only a new native challenge")
        await drain()
    }

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
        let work = Task { await privacy.requestLocalReturn(budgetMilliseconds: 2000,
            authenticationBudgetMilliseconds: ending == "deadline" ? 20 : 2000) }
        await settle { privacy.localAuthenticationChallengeID != nil }
        check(privacy.localAuthenticationChallengeID == auth.activeChallengeID,
              "\(ending) model exposes only its current actual challenge")
        check(prepared == auth.activeChallengeID, "\(ending) snapshot and active challenge share the operation")
        check(privacy.localReturnStatusReason?.contains("macOS에 로컬 복귀 인증을 요청") == true,
              "\(ending) own UI status identifies an issued OS request without claiming acceptance")
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
        case "decline": LARight.instances.last!.decline()
        default:
            let limit = ContinuousClock.now.advanced(by: .milliseconds(25))
            while ContinuousClock.now < limit {}
            check(privacy.localAuthenticationChallengeID == nil,
                  "deadline removes challenge before the timeout task can run")
        }
        check(!(await work.value) && privacy.localAuthenticationChallengeID == nil,
              "\(ending) terminal request retains no challenge")
        check(privacy.localReturnStatusReason?.contains("macOS에 로컬 복귀 인증을 요청") != true,
              "\(ending) terminal request clears the issued authentication UI status")
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
    let contexts = LARight.instances.count
    check(!(await privacy.requestLocalReturn(budgetMilliseconds: 2000)), "snapshot generation change cancels the request")
    check(contexts == LARight.instances.count && privacy.localAuthenticationChallengeID == nil,
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
    for (workBudget, authenticationBudget) in [(0, 120_000), (30_001, 120_000), (30_000, 0), (30_000, 120_001)] {
        let contexts = LARight.instances.count
        check(!(await humanPrivacy.requestLocalReturn(budgetMilliseconds: workBudget,
            authenticationBudgetMilliseconds: authenticationBudget)),
            "invalid work/authentication budget \(workBudget)/\(authenticationBudget) rejects the request")
        check(LARight.instances.count == contexts && humanPrivacy.localAuthenticationChallengeID == nil &&
              humanPrivacy.latched && humanHAL.writes == 0 && humanHAL.restores == 0,
              "invalid budgets never issue authentication or change audio protection")
    }
    let human = Task { await humanPrivacy.requestLocalReturn(budgetMilliseconds: 20) }
    await settle { humanPrivacy.localAuthenticationChallengeID != nil }
    try? await Task.sleep(for: .milliseconds(35))
    check(humanPrivacy.localAuthenticationChallengeID != nil,
          "human authentication wait does not spend the participant work budget")
    for budget in [0, 30_000, 30_001, 120_000] {
        let request = LocalAudioParticipantRequest(schemaVersion: 1, operationId: UUID(), privacyGeneration: UUID(),
            registryRevision: "1", participantId: .relay, bootId: UUID(), budgetMilliseconds: budget)
        let decoded = try? JSONDecoder().decode(LocalAudioParticipantRequest.self, from: JSONEncoder().encode(request))
        check((decoded != nil) == (budget == 30_000),
              "pending human authentication retains the participant 30-second wire limit for \(budget) ms")
    }
    LARight.instances.last!.decline()
    check(!(await human.value) && humanPrivacy.localAuthenticationChallengeID == nil,
          "declined extended human wait closes the exact request without approval")
    check(humanPrivacy.latched && humanHAL.writes == 0 && humanHAL.restores == 0,
          "extended human wait never changes audio or the protection latch")
    humanPrivacy.stop()
    print("PASS \(count) anchored right checks; right and window are inert; actual OS authentication 0")
}

Task { @MainActor in await challenges(); exit(0) }
dispatchMain()
