import AppKit

@MainActor
final class LocalAuthenticationPresentation {
    private var window: NSWindow?
    private var operationID: UUID?
    private static weak var registeredOwner: LocalAuthenticationPresentation?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    static func builtinScreen(in screens: [NSScreen]) -> NSScreen? {
        let candidates = screens.filter { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    static func registeredWindow(for operationID: UUID) -> NSWindow? {
        guard let owner = registeredOwner, owner.operationID == operationID else { return nil }
        return owner.window
    }

    static func validatedWindows(for operationID: UUID) -> [NSWindow] {
        guard let root = registeredWindow(for: operationID),
              root.identifier?.rawValue == "CCR.LocalAuthentication", root.isVisible, root.isOnActiveSpace,
              root.windowNumber > 0, root.isOpaque, root.alphaValue == 1,
              !root.ignoresMouseEvents, root.sharingType == .none,
              root.level.rawValue == Int(CGWindowLevelForKey(.screenSaverWindow)) + 2,
              let screen = builtinScreen(in: NSScreen.screens), root.screen === screen,
              screen.frame.contains(root.frame) else { return [] }
        guard let sheet = root.attachedSheet else { return [root] }
        guard sheet.sheetParent === root, sheet.isVisible, sheet.isOnActiveSpace,
              sheet.windowNumber > 0, sheet.alphaValue == 1,
              sheet.level.rawValue >= root.level.rawValue,
              sheet.screen === screen, screen.frame.contains(sheet.frame) else { return [] }
        return [root, sheet]
    }

    func matches(operationID: UUID) -> Bool {
        guard Self.registeredOwner === self, self.operationID == operationID, let window else { return false }
        return Self.validatedWindows(for: operationID).first === window
    }

    func begin(operationID: UUID, invalidated: @escaping @MainActor () -> Void) async -> NSWindow? {
        print("[로컬 복귀 인증] 표시 준비 시작 ownWindow=\(window != nil) registeredOwner=\(Self.registeredOwner != nil)")
        guard window == nil, Self.registeredOwner == nil,
              let screen = Self.builtinScreen(in: NSScreen.screens) else {
            print("[로컬 복귀 인증] 활성 내장 화면을 확정하지 못했습니다. 인증을 요청하지 않습니다.")
            return nil
        }
        let curtains = NSApp.windows.filter { $0.identifier?.rawValue == "CCR.SentryCurtain" }
        let candidates = curtains.filter { $0.screen === screen && $0.frame == screen.frame }
        if !curtains.isEmpty {
            guard candidates.count == 1, let curtain = candidates.first,
                  curtain.isVisible, curtain.isOnActiveSpace, curtain.canBecomeKey,
                  curtain.isOpaque, curtain.alphaValue == 1, !curtain.ignoresMouseEvents,
                  curtain.sharingType == .none,
                  curtain.level.rawValue == Int(CGWindowLevelForKey(.screenSaverWindow)) + 1 else {
                print("[로컬 복귀 인증] 내장 화면의 보호 커튼을 인증 anchor로 확정하지 못했습니다.")
                return nil
            }
        }
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 480, height: 240),
                             styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
        window.hidesOnDeactivate = false
        window.identifier = NSUserInterfaceItemIdentifier("CCR.LocalAuthentication")
        window.title = "Touch ID 또는 Mac 로그인 암호"
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.alphaValue = 1
        window.sharingType = .none
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
        window.setFrameOrigin(.init(x: screen.frame.midX - window.frame.width / 2,
                                    y: screen.frame.midY - window.frame.height / 2))
        self.window = window
        self.operationID = operationID
        Self.registeredOwner = self
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
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { invalidated() } }
        observers.append((NotificationCenter.default, closeObserver))
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular {
            guard NSApp.setActivationPolicy(.regular) else { end(); return nil }
            previousActivationPolicy = previousPolicy
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while self.window === window, !Task.isCancelled, ContinuousClock.now < deadline {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            if window.isKeyWindow { break }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { break }
        }
        guard self.window === window else { return nil }
        guard !Task.isCancelled, window.isKeyWindow, window.isVisible else {
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
        guard matches(operationID: operationID) else {
            print("[로컬 복귀 인증] 표시 검증 거부 visible=\(window.isVisible) activeSpace=\(window.isOnActiveSpace) opaque=\(window.isOpaque) alpha=\(window.alphaValue) mouseIgnored=\(window.ignoresMouseEvents) sharing=\(window.sharingType.rawValue) level=\(window.level.rawValue) window=\(window.windowNumber) sheet=\(window.attachedSheet != nil)")
            end(); return nil
        }
        print("[로컬 복귀 인증] 내장 전용 인증 창 display=\(id) window=\(window.windowNumber) level=\(window.level.rawValue) curtainsPreserved=\(!curtains.isEmpty) appActive=\(NSApp.isActive) keyWindow=\(window.isKeyWindow). 공식 인증 UI의 실물 표시는 별도 확인합니다.")
        return window
    }

    func end() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        let old = window
        if Self.registeredOwner === self { Self.registeredOwner = nil }
        window = nil
        operationID = nil
        old?.close()
        if let previousActivationPolicy {
            self.previousActivationPolicy = nil
            _ = NSApp.setActivationPolicy(previousActivationPolicy)
        }
    }
}
