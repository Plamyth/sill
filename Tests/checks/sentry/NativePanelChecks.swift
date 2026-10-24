import AppKit

@MainActor
final class NativePanelChecks: NSObject {
    __PRODUCTION_CURTAIN_TYPE__
    __PRODUCTION_CURTAIN_LEVEL__
    private enum State { case idle, protected, invalid(String) }
    private var state = State.idle
    private var curtains: [Int: Curtain] = [:]
    private var localReturnDown: UInt32?
    private var changingLifecycle = false
    private var changed: (() -> Void)?
    private var localReturnReason: () -> String? = { nil }
    private var currentLocalAuthenticationChallenge: () -> UUID? = { nil }
    private var reason: String? { if case .invalid(let value) = state { return value }; return nil }
    __PRODUCTION_PANEL_REFRESH__
    private func refreshTimer() -> Timer {
        __PRODUCTION_REFRESH_TIMER__
        return timer
    }
    @objc private func returnRequested() { preconditionFailure("검사에서 인증 요청을 실행하면 안 됩니다.") }
    __PRODUCTION_MAKE_CURTAIN__

    func run() -> Bool {
        func check(_ value: Bool, _ message: String) -> Bool {
            print("\(value ? "PASS" : "FAIL") \(message)")
            return value
        }
        let witness = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        witness.isReleasedWhenClosed = false
        defer { witness.close() }
        witness.level = Self.curtainLevel
        let before = witness.level.rawValue
        witness.isFloatingPanel = true
        let after = witness.level.rawValue
        print("SDK 기존 순서의 레벨 \(before) → \(after)")
        guard check(before == Self.curtainLevel.rawValue && after == NSWindow.Level.floating.rawValue,
                    "실제 SDK에서 뒤늦은 floating 설정이 화면 보호 레벨을 덮어씀"),
              check(!witness.isVisible, "기존 순서 증명 패널은 화면에 표시되지 않음") else { return false }

        let curtain = makeCurtain(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        defer { curtain.panel.close() }
        print("추출한 실제 makeCurtain 최종 레벨 \(curtain.panel.level.rawValue), 요구 레벨 \(Self.curtainLevel.rawValue)")
        guard check(!curtain.panel.isVisible && !curtain.panel.isKeyWindow && !curtain.panel.isMainWindow,
                    "실제 생성한 가림 패널은 비표시·비포커스 유지"),
              check(curtain.panel.level == Self.curtainLevel, "실제 makeCurtain은 화면 보호 레벨 유지"),
              check(curtain.panel.isFloatingPanel && curtain.panel.isOpaque && curtain.panel.alphaValue == 1 &&
                    curtain.panel.sharingType == .none, "실제 패널의 floating·불투명도·공유 차단 속성 유지"),
              check(NSApp.activationPolicy() == .prohibited && NSApp.keyWindow == nil && NSApp.mainWindow == nil &&
                    NSApp.windows.allSatisfy { !$0.isVisible }, "검사 앱은 활성화·창 표시·포커스 획득 없음") else { return false }
        curtains[1] = curtain
        defer { curtains.removeAll() }
        var busy: String? = "이전 로컬 복귀 작업을 정리하고 있습니다."
        localReturnReason = { busy }
        let sameInvalid = "가림 화면 위의 창을 확인할 수 없습니다."
        invalidate(sameInvalid)
        let timer = refreshTimer()
        defer { timer.invalidate() }
        timer.fire()
        guard check(curtain.detail.stringValue.contains(busy!),
                    "실제 비표시 패널에 이전 로컬 복귀 정리 안내 표시") else { return false }
        busy = nil
        invalidate(sameInvalid)
        guard check(curtain.detail.stringValue.contains("이전 로컬 복귀 작업을 정리하고 있습니다."),
                    "같은 invalid 사유의 조기 반환 자체는 기존 안내를 갱신하지 않음") else { return false }
        timer.fire()
        guard check(curtain.detail.stringValue == curtainMessage.detail && curtain.detail.stringValue.contains(sameInvalid) &&
                    !curtain.detail.stringValue.contains("이전 로컬 복귀 작업을 정리하고 있습니다."),
                    "기존 production timer·text 본문이 같은 invalid 사유에서 busy→실제 nil 안내 갱신"),
              check(!curtain.panel.isVisible && NSApp.windows.allSatisfy { !$0.isVisible } && NSApp.keyWindow == nil,
                    "안내 회귀 검사 뒤에도 실제 패널 비표시·포커스 변경 없음") else { return false }
        return true
    }
}

@main
struct NativePanelMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        _ = application.setActivationPolicy(.prohibited)
        guard application.activationPolicy() == .prohibited else {
            print("FAIL 검사 앱의 활성화 금지 상태를 확인하지 못했습니다.")
            exit(1)
        }
        exit(NativePanelChecks().run() ? 0 : 1)
    }
}
