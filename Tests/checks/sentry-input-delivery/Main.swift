import AppKit
import CoreGraphics
import Darwin

private struct InertTap { var valid = true; var enabled = true }
private func CFMachPortIsValid(_ tap: InertTap) -> Bool { tap.valid }
private extension CGEvent {
    static func tapIsEnabled(tap: InertTap) -> Bool { tap.enabled }
}

@MainActor
private final class HostSentryPlatform: NSObject {
    static let remoteEventTag: Int64 = 0x435352
    enum State { case idle, engaging, protected, releasing, invalid(String) }
    var state = State.idle
    var tap: InertTap?
    var changed: (() -> Void)?
    var changingLifecycle = false
    var localReturnDown: CGWindowID?
    var requestLocalReturn: (() -> Void)?
    var currentLocalAuthenticationChallenge: () -> UUID? = { nil }
    var usable = true
    var buttonID: CGWindowID? = 90
    private var curtains: [Int: Curtain] = [:]
    var curtainMessage: (title: String, detail: String) { ("비표시 검사", "입력 전송 없음") }
    func environmentIsUsable() -> Bool {
        if !usable { invalidate("검사 환경 무효") }
        return usable
    }
    func visibleReturnButton(at point: CGPoint) -> CGWindowID? { buttonID }
    @objc func returnRequested() { requestLocalReturn?() }
    __PRODUCTION_PLATFORM__

    func run() {
        let curtain = makeCurtain(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        curtains[1] = curtain
        defer { curtain.panel.close() }
        print("SDK keyEligible=\(curtain.panel.canBecomeKey) mainEligible=\(curtain.panel.canBecomeMain) mouseIgnored=\(curtain.panel.ignoresMouseEvents)")
        Checks.check(!curtain.panel.canBecomeKey && !curtain.panel.canBecomeMain,
                     "기존 borderless nonactivating 커튼은 키·메인 창이 될 수 없음")
        let opaqueProperties = curtain.panel.isOpaque && curtain.panel.alphaValue == 1 &&
            curtain.panel.level == Self.curtainLevel && curtain.panel.sharingType == .none
        Checks.check(opaqueProperties, "비표시 커튼의 불투명도·레벨·캡처 제외 유지")
        tap = InertTap()
        state = .protected
        updateCurtainText()
        Checks.check(!curtain.panel.ignoresMouseEvents,
                     "검증된 보호와 정상 tap에서도 물리 클릭 차단 유지")
        for state in [State.idle, .engaging, .releasing, .invalid("복구 중")] {
            self.state = state
            updateCurtainText()
            Checks.check(!curtain.panel.ignoresMouseEvents, "미보호·전환·복구에서 fallback 버튼 hit-test 유지")
        }
        state = .protected
        for tap in [nil, InertTap(valid: false), InertTap(enabled: false)] {
            self.tap = tap
            updateCurtainText()
            Checks.check(!curtain.panel.ignoresMouseEvents, "tap 부재·무효·비활성에서 fallback 버튼 hit-test 유지")
        }
        self.tap = InertTap()
        updateCurtainText()
        Checks.check(!curtain.panel.ignoresMouseEvents, "정상 tap과 보호 재확인 뒤에도 물리 클릭 차단 유지")
        self.tap = InertTap(valid: false, enabled: false)
        Checks.check(!curtain.panel.ignoresMouseEvents,
                     "tap 외부 무효화 직후 MainActor 갱신 전에도 물리 클릭 차단 유지")
        self.tap = InertTap(enabled: false)
        Checks.check(!curtain.panel.ignoresMouseEvents,
                     "tap 외부 비활성 직후 callback·timer 없이 물리 클릭 차단 유지")
        self.tap = InertTap()
        invalidate("복구 중")
        Checks.check(!curtain.panel.ignoresMouseEvents, "무효화와 동시에 pass-through 해제")

        let source = CGEventSource(stateID: .hidSystemState)!
        let injector = InputFixture()
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                     .mouseMoved, .leftMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged] {
            let event = CGEvent(source: source)!
            event.type = type
            Checks.check(event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()),
                         "SDK 생성 이벤트는 post 전 자체 PID를 가짐 \(type.rawValue)")
            Checks.check(injector.send(event), "실제 post 본문은 원격 이벤트 태그를 기록함 \(type.rawValue)")
            let posted = injector.posted.last!
            Checks.check(posted.getIntegerValueField(.eventSourceUserData) == Self.remoteEventTag,
                         "post 경계의 실제 이벤트에 원격 태그 존재 \(type.rawValue)")
            state = .protected
            usable = true
            Checks.check(filter(type, event: posted)?.takeUnretainedValue() === posted,
                         "자체 PID·태그·보호·환경이 맞는 원격 이벤트 허용 \(type.rawValue)")
            posted.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()) + 1)
            Checks.check(filter(type, event: posted) == nil, "태그만 위조한 타 PID 거부 \(type.rawValue)")
            posted.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
            let untagged = CGEvent(source: CGEventSource(stateID: .privateState))!
            untagged.type = type
            Checks.check(untagged.getIntegerValueField(.eventSourceUserData) == 0 &&
                         filter(type, event: untagged) == nil, "자체 PID라도 태그 없는 입력 거부 \(type.rawValue)")
            state = .invalid("복구 중")
            Checks.check(filter(type, event: posted) == nil, "복구 중 원격 이벤트 거부 \(type.rawValue)")
            state = .protected
            usable = false
            Checks.check(filter(type, event: posted) == nil, "환경 검증 실패 시 원격 이벤트 거부 \(type.rawValue)")
        }
        usable = true
        state = .protected
        updateCurtainText()
        var requests = 0
        requestLocalReturn = { requests += 1 }
        let local = CGEvent(source: source)!
        Checks.check(filter(.leftMouseDown, event: local) == nil && filter(.leftMouseUp, event: local) == nil && requests == 1,
                     "물리 복귀 버튼 클릭은 소비하고 복귀 요청만 전달함")
        buttonID = nil
        _ = filter(.leftMouseDown, event: local)
        _ = filter(.leftMouseUp, event: local)
        Checks.check(requests == 1, "복귀 버튼 밖의 클릭은 요청도 전달도 하지 않음")
        buttonID = 90
        _ = filter(.leftMouseDown, event: local)
        buttonID = 91
        _ = filter(.leftMouseUp, event: local)
        Checks.check(requests == 1, "서로 다른 버튼에서 down·up하면 복귀 요청 거부")
        for disabled in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            state = .protected
            updateCurtainText()
            Checks.check(filter(disabled, event: local) == nil && !isProtected && !curtain.panel.ignoresMouseEvents,
                         "tap 중단 callback은 보호 무효화와 fallback 복원을 함께 수행함")
        }
        injector.dryRun = true
        let before = injector.posted.count
        _ = injector.send(local)
        Checks.check(injector.posted.count == before, "dryRun은 post 경계에 도달하지 않음")
        Checks.check(!curtain.panel.isVisible && !curtain.panel.isKeyWindow && !curtain.panel.isMainWindow &&
                     NSApp.activationPolicy() == .prohibited && NSApp.keyWindow == nil &&
                     NSApp.windows.allSatisfy { !$0.isVisible }, "전체 검사에서 창 표시·포커스·실제 입력 전송 없음")
    }
}

private enum KeyStrokes { static let capsLock: UInt64 = 0x01_0000 }
@MainActor private final class Stats {
    static let shared = Stats()
    func bump(_ name: String) {}
}
@MainActor private final class InputFixture {
    private var lastKeyFlags: UInt64 = 0
    private static let modifierBits: UInt64 = 0x1E_0000
    struct ProtectedPointerScope {}
    var protectedPointerEgress: ((CGEvent, ProtectedPointerScope?) -> Bool)?
    var postingScope: ProtectedPointerScope?
    var isolatesPhysicalInput = false
    var dryRun = false, testLog = false
    var posted: [CGEvent] = []
    func logTest(_ event: CGEvent) { preconditionFailure("검사 입력은 출력하지 않습니다.") }
    func send(_ event: CGEvent) -> Bool { post(event) }
    __PRODUCTION_POST__
}

@main private struct Checks {
    static var total = 0, failed = 0
    static func check(_ value: Bool, _ label: String) {
        total += 1
        if !value { failed += 1 }
        print("\(value ? "PASS" : "FAIL") \(label)")
    }
    @MainActor static func main() {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSApp.activationPolicy() == .prohibited else { exit(2) }
        HostSentryPlatform().run()
        print("SENTRY_INPUT_DELIVERY \(total - failed)/\(total)")
        exit(failed == 0 ? 0 : 1)
    }
}
