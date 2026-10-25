import Foundation

@MainActor final class NSWindow {}
@MainActor final class LocalAuthenticationPresentation {
    static var instances: [LocalAuthenticationPresentation] = []
    init() { Self.instances.append(self) }
    var intact = true
    private var currentID: UUID?
    private var suppliedContext: LAContext?
    func matches(operationID: UUID) -> Bool { intact && currentID == operationID && suppliedContext != nil }
    func begin(operationID: UUID, context: LAContext, invalidated: @escaping @MainActor () -> Void) async -> NSWindow? { currentID = operationID; suppliedContext = context; return NSWindow() }
    func end() { currentID = nil; suppliedContext = nil }
}
enum LAPolicy { case deviceOwnerAuthenticationWithBiometrics }
@MainActor final class LAContext {
    static var capable = true
    static var instances: [LAContext] = []
    var touchIDAuthenticationAllowableReuseDuration: TimeInterval = -1
    var interactionNotAllowed = true
    var localizedCancelTitle: String?
    var localizedFallbackTitle: String?
    var callback: ((Bool, Error?) -> Void)?
    var invalidations = 0
    init() { Self.instances.append(self) }
    func canEvaluatePolicy(_ policy: LAPolicy, error: inout NSError?) -> Bool { Self.capable }
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, Error?) -> Void) {
        callback = reply
    }
    func invalidate() { invalidations += 1 }
}
@MainActor var count = 0
@MainActor func check(_ value: Bool, _ name: String) {
    guard value else { print("FAIL \(name)"); exit(1) }
    count += 1
    print("PASS \(name)")
}
@MainActor func issued(_ auth: LocalAudioAuthentication) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while auth.activeChallengeID == nil, ContinuousClock.now < deadline { await Task.yield() }
    check(auth.activeChallengeID != nil, "현재 요청만 시스템 정책 평가를 시작함")
}
@MainActor func checks() async {
    let auth = LocalAudioAuthentication()
    LAContext.capable = false
    check(!(await auth.evaluate(operationId: UUID())), "사용 불가 정책은 인증 성공을 반환하지 않음")
    check(LAContext.instances.last?.callback == nil, "정책 사용 불가 때 인증창 요청 없음")
    LAContext.capable = true
    let firstID = UUID()
    let first = Task { await auth.evaluate(operationId: firstID) }
    await issued(auth)
    let old = LAContext.instances.last!
    check(old.touchIDAuthenticationAllowableReuseDuration == 0 && !old.interactionNotAllowed && old.localizedFallbackTitle == "",
          "새 context는 잠금화면 인증을 재사용하지 않고 공식 UI 상호작용을 허용함")
    check(!(await auth.evaluate(operationId: UUID())) && auth.activeChallengeID == firstID,
          "중복 요청은 현재 인증을 대체하지 않음")
    auth.cancel()
    check(!(await first.value) && auth.activeChallengeID == nil && old.invalidations == 1,
          "취소는 challenge를 지우고 context를 폐기함")
    check(!(await auth.evaluate(operationId: UUID())), "이전 OS 콜백 종료 전 새 요청을 발행하지 않음")
    old.callback?(true, nil)
    for _ in 0..<20 { await Task.yield() }
    let nextID = UUID()
    let next = Task { await auth.evaluate(operationId: nextID) }
    await issued(auth)
    let replacement = LAContext.instances.last!
    check(replacement !== old, "다음 요청은 별도 새 context를 사용함")
    old.callback?(true, nil)
    for _ in 0..<20 { await Task.yield() }
    check(auth.activeChallengeID == nextID, "이전 콜백은 새 요청을 승인하거나 종료하지 않음")
    replacement.callback?(false, nil)
    check(!(await next.value), "실패 응답은 복귀 인증으로 수용하지 않음")
    let detached = Task { await auth.evaluate(operationId: UUID()) }
    await issued(auth)
    LocalAuthenticationPresentation.instances.last!.intact = false
    LAContext.instances.last!.callback?(true, nil)
    check(!(await detached.value), "현재 인증 컨테이너가 소실되면 공식 성공 콜백도 복귀로 수용하지 않음")
    LocalAuthenticationPresentation.instances.last!.intact = true
    let errored = Task { await auth.evaluate(operationId: UUID()) }
    await issued(auth)
    LAContext.instances.last!.callback?(true, NSError(domain: "inert", code: -1))
    check(!(await errored.value), "오류가 있는 성공 콜백은 복귀 인증으로 수용하지 않음")
    let accepted = Task { await auth.evaluate(operationId: UUID()) }
    await issued(auth)
    LAContext.instances.last!.callback?(true, nil)
    check(await accepted.value, "현재 시스템 정책의 성공 응답만 반환함")
    let expiry = Task { await auth.evaluate(operationId: UUID()) }
    await issued(auth)
    let expired = LAContext.instances.last!
    check(!(await expiry.value) && auth.activeChallengeID == nil, "기한 만료는 성공을 반환하지 않고 challenge를 제거함")
    check(!(await auth.evaluate(operationId: UUID())), "만료된 OS 콜백 미종료 상태에서 새 인증을 중첩하지 않음")
    expired.callback?(false, nil)
    for _ in 0..<20 { await Task.yield() }
    print("PASS \(count) embedded Touch ID context checks; actual OS UI/authentication/actions 0")
}
Task { @MainActor in await checks(); exit(0) }
RunLoop.main.run()
