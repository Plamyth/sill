import AppKit

@MainActor
final class NativePanelChecks: NSObject {
    __PRODUCTION_CURTAIN_TYPE__
    __PRODUCTION_CURTAIN_LEVEL__
    private var curtainMessage: (title: String, detail: String) { ("보이지 않는 패널 검사", "화면 표시 없음") }
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
