import AppKit

@MainActor
final class LocalAuthenticationPresentation {
    private var window: NSWindow?
    private var ownsWindow = false
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    static func builtinScreen(in screens: [NSScreen]) -> NSScreen? {
        let candidates = screens.filter { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func begin(invalidated: @escaping @MainActor () -> Void) async -> NSWindow? {
        guard window == nil, let screen = Self.builtinScreen(in: NSScreen.screens) else {
            print("[로컬 복귀 인증] 활성 내장 화면을 확정하지 못했습니다. 인증을 요청하지 않습니다.")
            return nil
        }
        let curtains = NSApp.windows.filter { $0.identifier?.rawValue == "CCR.SentryCurtain" }
        let candidates = curtains.filter { $0.screen === screen && $0.frame == screen.frame }
        let borrowed = !curtains.isEmpty
        let window: NSWindow
        if borrowed {
            guard candidates.count == 1, let curtain = candidates.first,
                  curtain.isVisible, curtain.isOnActiveSpace, curtain.canBecomeKey,
                  curtain.isOpaque, curtain.alphaValue == 1, !curtain.ignoresMouseEvents,
                  curtain.sharingType == .none,
                  curtain.level.rawValue == Int(CGWindowLevelForKey(.screenSaverWindow)) + 1 else {
                print("[로컬 복귀 인증] 내장 화면의 보호 커튼을 인증 anchor로 확정하지 못했습니다.")
                return nil
            }
            window = curtain
        } else {
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
            window.title = "로컬 복귀 인증 대기"
            window.isReleasedWhenClosed = false
            window.sharingType = .none
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.level = .normal
            let label = NSTextField(wrappingLabelWithString: "macOS의 Touch ID 또는 로그인 암호 인증이 완료되어야 로컬로 복귀합니다.")
            label.frame = .init(x: 20, y: 20, width: 320, height: 60)
            window.contentView?.addSubview(label)
            window.setFrameOrigin(.init(x: screen.frame.midX - window.frame.width / 2,
                                        y: screen.frame.midY - window.frame.height / 2))
        }
        self.window = window
        ownsWindow = !borrowed
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
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular {
            guard NSApp.setActivationPolicy(.regular) else { end(); return nil }
            previousActivationPolicy = previousPolicy
        }
        window.makeKeyAndOrderFront(nil)
        if borrowed { window.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while self.window === window, !Task.isCancelled, ContinuousClock.now < deadline {
            if NSApp.isActive {
                window.makeKeyAndOrderFront(nil)
                if borrowed { window.orderFrontRegardless() }
                if window.isKeyWindow { break }
            }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { break }
        }
        guard self.window === window else { return nil }
        guard !Task.isCancelled, NSApp.isActive, window.isKeyWindow, window.isVisible else {
            print("[로컬 복귀 인증] 활성 앱과 내장 anchor의 키보드 포커스를 확인하지 못했습니다. appActive=\(NSApp.isActive) keyWindow=\(window.isKeyWindow) visible=\(window.isVisible). 인증을 요청하지 않습니다.")
            end()
            return nil
        }
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let actualID = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard actualID == id, CGDisplayIsBuiltin(id) != 0, CGDisplayIsActive(id) != 0,
              CGDisplayIsAsleep(id) == 0, screen.frame.contains(window.frame) else {
            print("[로컬 복귀 인증] 소유 anchor의 실제 내장 화면 배치를 확인하지 못했습니다.")
            end()
            return nil
        }
        print("[로컬 복귀 인증] 내장 anchor display=\(id) window=\(window.windowNumber) level=\(window.level.rawValue) protectedCurtain=\(borrowed) appActive=\(NSApp.isActive) keyWindow=\(window.isKeyWindow). 운영체제 인증창의 표시·위치는 미확인입니다.")
        return window
    }

    func end() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        let old = window
        let closeOwnedWindow = ownsWindow
        window = nil
        ownsWindow = false
        if closeOwnedWindow { old?.close() }
        if let previousActivationPolicy {
            self.previousActivationPolicy = nil
            _ = NSApp.setActivationPolicy(previousActivationPolicy)
        }
    }
}
