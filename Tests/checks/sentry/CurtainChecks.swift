import Foundation

@MainActor
final class CurtainPlatformFixture {
    static var tapOwner: CurtainPlatformFixture?
    enum State { case idle, engaging, protected, releasing, invalid(String) }
    var state = State.idle
    var changed: (() -> Void)?
    var localReturnReason: () -> String? = { nil }
    var changingLifecycle = false
    var sessionActive = true, sleeping = false, notifiedLocked = false
    var localReturnDown: UInt32?
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var lockObservers: [NSObjectProtocol] = []
    var timer: Timer?
    var layout = 0, displayLayout = 1
    var curtains = false, tap = false, readable = true
    var installs = 0, rebuilds = 0
    var duringReadback: (() -> Void)?
    var reason: String? { if case .invalid(let value) = state { return value }; return nil }
    func currentLayout() -> Int? { displayLayout }
    func rebuildCurtains() -> Bool {
        rebuilds += 1; curtains = true; layout = displayLayout
        return curtainsAreEffective()
    }
    func curtainsAreEffective() -> Bool { duringReadback?(); return readable && curtains }
    func environmentIsUsable() -> Bool { true }
    func installTap() -> Bool { installs += 1; tap = true; return true }
    func verify() -> Bool { isProtected && tap && readable && layout == displayLayout }
    func release() -> Bool { false }
    func updateCurtainText() {}
    func loseVerification() { invalidate("입력 필터 확인 실패") }
    func failRelease() -> Bool { recoverFailedRelease("해제 읽기 확인 실패") }
    var message: (title: String, detail: String) { curtainMessage }
    func stop() {
        timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        for token in lockObservers { FixtureDistributedCenter.default().removeObserver(token) }
        observers.removeAll(); lockObservers.removeAll()
        if Self.tapOwner === self { Self.tapOwner = nil }
    }
    __PRODUCTION_LIFECYCLE__
}

final class FixtureWorkspace {
    static let shared = FixtureWorkspace()
    let notificationCenter = NotificationCenter()
    static let activeSpaceDidChangeNotification = Notification.Name("fixture.space")
    static let sessionDidResignActiveNotification = Notification.Name("fixture.resign")
    static let sessionDidBecomeActiveNotification = Notification.Name("fixture.active")
    static let screensDidSleepNotification = Notification.Name("fixture.screen.sleep")
    static let screensDidWakeNotification = Notification.Name("fixture.screen.wake")
    static let willSleepNotification = Notification.Name("fixture.sleep")
    static let didWakeNotification = Notification.Name("fixture.wake")
}
enum FixtureApplication {
    static let didChangeScreenParametersNotification = Notification.Name("fixture.screens")
}
enum FixtureDistributedCenter {
    static let center = NotificationCenter()
    static func `default`() -> NotificationCenter { center }
}

extension Checks {
    @MainActor static func curtainRecoveryChecks() {
        let platform = CurtainPlatformFixture()
        defer { platform.stop() }
        let gate = SentryAdmission()
        var persistOK = true, recoveryReason: String? = "릴레이 복귀 확인이 필요합니다."
        var fullEngagements = 0, restores = 0
        let owner = HostSentry(admission: gate, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in persistOK }, surfaces: .init(engage: {
                fullEngagements += 1; return platform.engage()
            }, verify: { platform.verify() }, release: { false }, reason: { platform.reason }, restoreCurtains: {
                restores += 1; return platform.restoreCurtains()
            }), localReturnUnavailableReason: { recoveryReason })
        platform.changed = { [weak owner] in owner?.surfacesChanged() }
        let object = NSObject(), peer = ObjectIdentifier(object), epoch = UUID()
        gate.register(peer, externalRoute: false); gate.capture(epoch)
        owner.start(); owner.joined(peer)
        expect(platform.curtains && restores == 2, "persisted requested restart restores curtains when relay recovery is missing")
        expect(fullEngagements == 0 && platform.installs == 0 && !platform.tap,
               "curtain recovery never installs a new HID filter")
        expect(platform.message.title == "원격 제어 보호 복구 중" && platform.message.detail.contains("아직 확인되지 않았습니다"),
               "partial Korean curtain text makes no verified input block claim")
        expect(!gate.allowsActions(peer) && !gate.allows(peer, epoch: epoch) && gate.status(for: peer)?.phase == .blocked,
               "verified curtain recovery cannot grant remote actions or capture admission")
        expect(platform.observers.count == 8 && platform.lockObservers.count == 2 && platform.timer != nil,
               "repeated curtain restore keeps one observer and timer lifecycle")
        let timer = platform.timer
        platform.displayLayout = 2
        NotificationCenter.default.post(name: FixtureApplication.didChangeScreenParametersNotification, object: nil)
        expect(platform.curtains && platform.layout == 2 && platform.installs == 0,
               "screen changes restore partial curtains without installing HID")
        persistOK = false; recoveryReason = nil
        expect(!owner.reconcile() && platform.curtains && platform.installs == 0,
               "failed persistence readback restores curtains while denying full engagement")
        platform.readable = false
        expect(!platform.restoreCurtains() && platform.curtains && platform.reason != nil,
               "failed native curtain readback retains panels and reports failure")
        expect(!owner.reconcile() && !gate.allowsActions(peer) && !gate.allows(peer, epoch: epoch),
               "failed curtain and journal readback keep remote admission closed")
        platform.readable = true; persistOK = true
        expect(owner.reconcile() && platform.tap && platform.installs == 1,
               "fresh recovery authority permits full engagement through the owner")
        expect(platform.message.title == "원격 제어 모드 활성화" && platform.message.detail.contains("일반 입력 차단을 확인했습니다"),
               "verified Korean curtain text follows actual full protection state")
        gate.capture(nil)
        expect(!gate.allows(peer, epoch: epoch), "failed capture exclusion readback cannot borrow curtain recovery proof")
        platform.duringReadback = {
            expect(!gate.allowsActions(peer), "owner revokes remote actions before fallback readback callbacks")
        }
        recoveryReason = "릴레이 복귀 확인이 필요합니다."
        expect(!owner.reconcile() && platform.curtains && platform.tap && platform.installs == 1,
               "lost recovery retains existing curtain and HID protection without reinstalling or releasing")
        platform.duringReadback = nil
        expect(platform.timer === timer && platform.observers.count == 8,
               "partial to full to partial transitions retain the existing observation lifecycle")
        var reentered = 0
        platform.duringReadback = {
            reentered += 1
            expect(!platform.restoreCurtains(), "reentrant curtain restore cannot enter a native lifecycle twice")
            owner.surfacesChanged()
        }
        expect(!owner.reconcile() && reentered > 0 && !gate.allowsActions(peer),
               "synchronous readback notifications remain bounded and cannot authorize remote control")
        platform.duringReadback = nil
        expect(!platform.failRelease() && platform.installs == 1 && platform.tap && platform.curtains,
               "platform failed release restores curtains without bypassing owner authority or replacing an existing tap")
        print("CURTAIN_RECOVERY_CHECKS_COMPLETE \(count)")
    }

    @MainActor static func curtainRefreshChecks() {
        let platform = CurtainPlatformFixture()
        defer { platform.stop() }
        let gate = SentryAdmission()
        var recoveryAvailable = true, persisted = true
        let owner = HostSentry(admission: gate, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in persisted }, surfaces: __PRODUCTION_SURFACES__,
            localReturnUnavailableReason: { recoveryAvailable ? nil : "복귀 릴레이 미확인" })
        __PRODUCTION_CHANGED__
        owner.start()
        expect(platform.installs == 1 && platform.timer != nil, "actual full engagement establishes periodic observation")
        recoveryAvailable = false
        platform.loseVerification()
        let installs = platform.installs
        platform.timer?.fire()
        expect(platform.installs == installs, "periodic refresh cannot bypass missing owner recovery authority to install HID")
        persisted = false; recoveryAvailable = true
        platform.timer?.fire()
        expect(platform.installs == installs, "periodic refresh cannot bypass failed owner persistence readback")
        expect(platform.curtains && platform.tap, "blocked refresh retains previously engaged curtains and input tap")
        print("CURTAIN_REFRESH_CHECKS_COMPLETE \(count)")
    }
}
