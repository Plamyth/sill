import AppKit

@MainActor
final class LocalAuthenticationPresentation {
    private var window: NSWindow?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    static func builtinScreen(in screens: [NSScreen]) -> NSScreen? {
        let candidates = screens.filter { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func begin(invalidated: @escaping @MainActor () -> Void) -> Bool {
        guard window == nil, let screen = Self.builtinScreen(in: NSScreen.screens) else {
            print("[로컬 복귀 인증] 활성 내장 화면을 확정하지 못했습니다. 인증을 요청하지 않습니다.")
            return false
        }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
        window.title = "로컬 복귀 인증 대기"
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // LAContext has no public window anchor. Keep this activation window below the unchanged sentry curtains.
        window.level = .normal
        let label = NSTextField(wrappingLabelWithString: "macOS의 Touch ID 또는 로그인 암호 인증이 완료되어야 로컬로 복귀합니다.")
        label.frame = .init(x: 20, y: 20, width: 320, height: 60)
        window.contentView?.addSubview(label)
        window.setFrameOrigin(.init(x: screen.frame.midX - window.frame.width / 2,
                                    y: screen.frame.midY - window.frame.height / 2))
        self.window = window
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.willSleepNotification)
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { invalidated() }
            }
            observers.append((center, observer))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        print("[로컬 복귀 인증] 내장 화면 활성화 요청 display=\(id) appActive=\(NSApp.isActive) keyWindow=\(window.isKeyWindow). 운영체제 인증창의 표시·위치는 미확인입니다.")
        return true
    }

    func end() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        let old = window
        window = nil
        old?.close()
    }
}
