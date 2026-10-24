import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Security
import StreamProtocol

@MainActor
final class HostSentryPlatform {
    static let remoteEventTag = Int64.random(in: 1...Int64.max)

    var changed: (() -> Void)?
    var requestLocalReturn: (() -> Void)?
    var localReturnReason: () -> String? = { nil }
    var currentLocalAuthenticationChallenge: () -> UUID? = { nil }

    var reason: String? {
        if currentLocalAuthenticationChallenge() != nil {
            return "현재 인증 요청과 운영체제 인증창의 연결을 확인하지 못해 입력 차단을 유지합니다."
        }
        switch state {
        case .invalid(let message): return message
        case .engaging: return "원격 제어 보호 상태를 확인하고 있습니다."
        case .releasing: return "로컬 복귀를 위해 보호 해제 상태를 확인하고 있습니다."
        case .idle, .protected: return nil
        }
    }

    var curtainWindowIDs: [CGWindowID] {
        curtains.values.compactMap { $0.panel.windowNumber > 0 ? CGWindowID($0.panel.windowNumber) : nil }.sorted()
    }

    private enum State {
        case idle, engaging, protected, releasing, invalid(String)
    }

    private struct Curtain {
        let panel: NSPanel
        let returnButton: NSButton
        let title: NSTextField
        let detail: NSTextField
    }

    // Retain the latch and curtains until an authenticated release succeeds.
    private static var tapOwner: HostSentryPlatform?
    private static let eventTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .mouseMoved,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .tabletPointer, .tabletProximity
    ]
    // Media keys use NX_SYSDEFINED, whose value is shared with NSEvent's systemDefined.
    private static let eventMask = eventTypes.reduce(CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue) {
        $0 | (CGEventMask(1) << $1.rawValue)
    }
    private static let curtainLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)

    private var state: State = .idle
    private var curtains: [CGDirectDisplayID: Curtain] = [:]
    private var layout: [CGDirectDisplayID: CGRect] = [:]
    private var tap: CFMachPort?
    private var tapID: UInt32?
    private var tapSource: CFRunLoopSource?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var notifiedLocked = false
    private var sessionActive = true
    private var sleeping = false
    private var localReturnDown: CGWindowID?
    private var changingLifecycle = false

    func engage() -> Bool {
        guard !changingLifecycle else { return false }
        if case .protected = state { return verify() }
        guard Self.tapOwner == nil || Self.tapOwner === self else {
            invalidate("다른 원격 제어 보호 작업이 이벤트 필터를 사용 중입니다.")
            return false
        }
        changingLifecycle = true
        defer { changingLifecycle = false }
        Self.tapOwner = self
        if case .idle = state {
            state = .engaging
            changed?()
        }
        observeChanges()
        guard rebuildCurtains() else { return false }
        guard environmentIsUsable() else { return false }
        guard installTap() else { return false }
        guard environmentIsUsable() else { return false }
        guard currentLayout() == layout else {
            invalidate("화면 구성이 바뀌어 보호 상태를 확인할 수 없습니다.")
            return false
        }
        guard curtainsAreEffective() else { return false }
        state = .protected
        updateCurtainText()
        changingLifecycle = false
        changed?()
        return isProtected
    }

    func restoreCurtains() -> Bool {
        guard !changingLifecycle else { return false }
        changingLifecycle = true
        defer { changingLifecycle = false }
        invalidate("가림 화면을 복구하고 있습니다. 입력 차단과 원격 동작은 아직 확인되지 않았습니다.")
        observeChanges()
        guard rebuildCurtains() else { return false }
        guard currentLayout() == layout else {
            invalidate("화면 구성이 바뀌어 가림 화면 복구를 확인하지 못했습니다. 기존 보호는 유지합니다.")
            return false
        }
        guard curtainsAreEffective() else { return false }
        invalidate("가림 화면만 복구했습니다. 입력 차단과 원격 동작은 아직 확인되지 않았습니다.")
        return true
    }

    private func installTap() -> Bool {
        if let tap, CFMachPortIsValid(tap), let tapID {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            guard let rows = eventTapList(), let row = rows.first(where: { $0.eventTapID == tapID }) else {
                invalidate("운영체제에서 입력 필터를 확인할 수 없습니다.")
                return false
            }
            if row.eventsOfInterest & Self.eventMask == Self.eventMask { return tapIsEffective(row) }
            invalidate("입력 필터의 실제 권한 또는 키보드·마우스 차단 범위가 부족합니다.")
        }
        destroyTap()
        tapID = nil
        guard let before = eventTapList() else { return false }
        let previousIDs = Set(before.map(\.eventTapID))
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                               options: .defaultTap, eventsOfInterest: Self.eventMask,
                               callback: { _, type, event, _ in
            MainActor.assumeIsolated {
                HostSentryPlatform.tapOwner?.filter(type, event: event)
            }
        }, userInfo: nil)
        guard let tap else {
            invalidate("현재 사용자 세션의 입력 필터를 만들 수 없습니다.")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            invalidate("입력 필터의 실행 루프를 만들 수 없습니다.")
            return false
        }
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        guard let after = eventTapList() else { return false }
        let added = after.filter { !previousIDs.contains($0.eventTapID) && $0.tappingProcess == getpid() }
        guard added.count == 1, let row = added.first else {
            invalidate("생성한 입력 필터의 운영체제 식별자를 확정할 수 없습니다.")
            return false
        }
        tapID = row.eventTapID
        return tapIsEffective(row)
    }

    func verify() -> Bool {
        guard isProtected, !changingLifecycle else { return false }
        changingLifecycle = true
        defer { changingLifecycle = false }
        guard environmentIsUsable() else { return false }
        guard currentLayout() == layout else {
            invalidate("디스플레이 구성이 바뀌어 보호 상태를 다시 확인해야 합니다.")
            _ = rebuildCurtains()
            return false
        }
        guard let tap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap), let tapID else {
            invalidate("입력 필터가 중단되었습니다. 원격 입력을 중지해야 합니다.")
            return false
        }
        guard let rows = eventTapList() else { return false }
        guard let row = rows.first(where: { $0.eventTapID == tapID }) else {
            invalidate("운영체제에서 입력 필터를 확인할 수 없습니다.")
            return false
        }
        return tapIsEffective(row) && curtainsAreEffective()
    }

    func prepareRelease(cleanup: () -> Bool) -> Bool {
        guard isProtected, currentLocalAuthenticationChallenge() == nil, verify(),
              isProtected, let tap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap),
              cleanup(), verify(), isProtected, currentLocalAuthenticationChallenge() == nil,
              let finalTap = self.tap, CFMachPortIsValid(finalTap), CGEvent.tapIsEnabled(tap: finalTap),
              pointerTargets.isEmpty else { return false }
        scrollHandoff = nil
        return true
    }

    func prepareRemoteRelease(inputIdle: () -> Bool, cleanup: () -> Bool) -> Bool {
        guard !changingLifecycle, currentLocalAuthenticationChallenge() == nil else { return false }
        if inputIdle(), pointerTargets.isEmpty {
            scrollHandoff = nil
            return true
        }
        return prepareRelease(cleanup: cleanup) && inputIdle()
    }

    var releaseVerified: Bool {
        guard case .idle = state else { return false }
        return !changingLifecycle && tap == nil && tapID == nil && curtains.isEmpty && pointerTargets.isEmpty
    }

    // The parent establishes fresh OS authentication and fences remote participants before release.
    func release() -> Bool {
        guard !changingLifecycle else { return false }
        changingLifecycle = true
        defer { changingLifecycle = false }
        if case .idle = state { return true }
        state = .releasing
        localReturnDown = nil
        updateCurtainText()
        changed?()
        destroyTap()
        if let tapID {
            guard let rows = eventTapList() else {
                return recoverFailedRelease("운영체제에서 입력 필터 해제 상태를 읽지 못했습니다.")
            }
            guard !rows.contains(where: { $0.eventTapID == tapID && $0.enabled }) else {
                return recoverFailedRelease("운영체제에서 입력 필터 해제를 확인하지 못했습니다.")
            }
        }
        let closingWindowIDs = Set(curtainWindowIDs)
        for curtain in curtains.values { curtain.panel.close() }
        guard let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              curtains.values.allSatisfy({ !$0.panel.isVisible }),
              !rows.contains(where: { row in
                  guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return false }
                  return closingWindowIDs.contains(id)
              }) else {
            return recoverFailedRelease("가림 화면 해제를 운영체제에서 확인하지 못했습니다.")
        }
        tapID = nil
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for token in lockObservers { DistributedNotificationCenter.default().removeObserver(token) }
        lockObservers.removeAll()
        curtains.removeAll()
        layout.removeAll()
        if Self.tapOwner === self { Self.tapOwner = nil }
        state = .idle
        changingLifecycle = false
        changed?()
        if case .idle = state { return true }
        return false
    }

    private func recoverFailedRelease(_ message: String) -> Bool {
        state = .engaging
        changingLifecycle = false
        let restored = restoreCurtains()
        changingLifecycle = true
        invalidate(restored ? message + " 가림 화면만 복구했습니다. 입력 차단은 아직 확인되지 않았습니다." :
            message + " 현장 보호 복구를 확인하지 못해 원격 동작을 중지합니다.")
        return false
    }

    private var isProtected: Bool {
        if case .protected = state { return true }
        return false
    }

    private func invalidate(_ message: String) {
        localReturnDown = nil
        if case .invalid(let previous) = state, previous == message { return }
        state = .invalid(message)
        updateCurtainText()
        let wasChanging = changingLifecycle
        changingLifecycle = true
        defer { changingLifecycle = wasChanging }
        changed?()
    }

    private func environmentIsUsable() -> Bool {
        guard AXIsProcessTrusted() else {
            invalidate("기존 손쉬운 사용 권한이 필요합니다. 권한 요청은 자동으로 표시하지 않습니다.")
            return false
        }
        guard CGPreflightListenEventAccess() else {
            invalidate("기존 입력 모니터링 권한을 확인할 수 없습니다. 권한 요청은 자동으로 표시하지 않습니다.")
            return false
        }
        guard !notifiedLocked, sessionActive, !sleeping else {
            invalidate("화면 잠금·절전 또는 사용자 전환 중에는 보호 상태를 보장할 수 없습니다.")
            return false
        }
        guard !IsSecureEventInputEnabled() else {
            invalidate("보안 입력이 활성화되어 일반 키보드 입력 차단을 보장할 수 없습니다.")
            return false
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid() else {
            invalidate("현재 로그인된 콘솔 사용자 세션을 확인할 수 없습니다.")
            return false
        }
        // SessionLock uses this undocumented Quartz key alongside the lock notifications too.
        if let locked = session["CGSSessionScreenIsLocked"] {
            guard let value = locked as? NSNumber, !value.boolValue else {
                invalidate("사용자 세션이 잠겨 보호 상태를 보장할 수 없습니다.")
                return false
            }
        }
        return true
    }

    private func eventTapList() -> [CGEventTapInformation]? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count <= 4096 else {
            invalidate("운영체제의 입력 필터 목록 크기를 읽지 못했습니다.")
            return nil
        }
        var rows = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 16)
        var actual: UInt32 = 0
        let result = rows.withUnsafeMutableBufferPointer { CGGetEventTapList(UInt32($0.count), $0.baseAddress, &actual) }
        guard result == .success, actual <= rows.count else {
            invalidate("운영체제의 입력 필터 목록을 확정하지 못했습니다.")
            return nil
        }
        return Array(rows.prefix(Int(actual)))
    }

    private func tapIsEffective(_ row: CGEventTapInformation) -> Bool {
        guard row.tappingProcess == getpid(), row.processBeingTapped == 0,
              row.tapPoint == .cgSessionEventTap, row.options == .defaultTap, row.enabled,
              row.eventsOfInterest & Self.eventMask == Self.eventMask else {
            invalidate("입력 필터의 실제 권한 또는 키보드·마우스 차단 범위가 부족합니다.")
            return false
        }
        return true
    }

    private func destroyTap() {
        if let tap { CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        tap = nil
    }

    private struct PointerTarget {
        let scope: InputInjector.ProtectedPointerScope
        let window: CGWindowID
        let pid: pid_t
        let launched: Date
    }
    private var pointerTargets: [Int: PointerTarget] = [:]
    private var scrollHandoff: PointerTarget?

    func protectedPointerEgress(_ event: CGEvent, scope: InputInjector.ProtectedPointerScope?) -> Bool {
        postProtectedPointer(event, scope: scope)
    }

    private func postProtectedPointer(_ event: CGEvent, scope: InputInjector.ProtectedPointerScope?) -> Bool {
        let slot: Int
        let begins: Bool
        let ends: Bool
        var momentumBegins = false, gestureEnds = false
        switch event.type {
        case .leftMouseDown: slot = 0; begins = true; ends = false
        case .rightMouseDown: slot = 1; begins = true; ends = false
        case .leftMouseDragged: slot = 0; begins = false; ends = false
        case .rightMouseDragged: slot = 1; begins = false; ends = false
        case .leftMouseUp: slot = 0; begins = false; ends = true
        case .rightMouseUp: slot = 1; begins = false; ends = true
        case .scrollWheel:
            slot = 2
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            momentumBegins = momentum == 1
            gestureEnds = phase == 4
            if phase == 1 { scrollHandoff = nil }
            begins = phase == 1 || momentum == 1 || (phase == 0 && momentum == 0)
            ends = phase == 4 || momentum == 3 || (phase == 0 && momentum == 0)
        default: return false
        }
        guard let scope else { return false }
        let held = pointerTargets[slot]
        let handoff = momentumBegins ? scrollHandoff : nil
        if momentumBegins {
            guard let handoff, handoff.scope.matches(scope), handoff.scope.isCurrent() else { return false }
        }
        let cleanup = ends && !begins && held?.scope.matches(scope) == true
        guard (cleanup || scope.isCurrent()), scope.epoch.isValid,
              event.getIntegerValueField(.eventSourceUserData) == Self.remoteEventTag,
              event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()),
              isProtected, currentLocalAuthenticationChallenge() == nil,
              let tap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap), verify(),
              let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let target = pointerTarget(at: event.location, rows: rows, scope: scope, held: begins ? handoff : held) else { return false }
        if begins {
            guard pointerTargets[slot] == nil else { return false }
            if let handoff {
                guard handoff.pid == target.pid, handoff.window == target.window,
                      handoff.launched == target.launched else { return false }
            }
        } else {
            guard let held, held.scope.matches(scope), cleanup || held.scope.isCurrent(),
                  held.pid == target.pid, held.window == target.window,
                  held.launched == target.launched else { return false }
        }
        guard (cleanup || scope.isCurrent()), isProtected, currentLocalAuthenticationChallenge() == nil,
              CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) else { return false }
        if begins {
            pointerTargets[slot] = target
            if slot == 2 { scrollHandoff = nil }
        }
        event.postToPid(target.pid)
        if ends {
            pointerTargets[slot] = nil
            if slot == 2 { scrollHandoff = gestureEnds ? target : nil }
        }
        return true
    }

    private func pointerTarget(at point: CGPoint, rows: [[String: Any]],
                               scope: InputInjector.ProtectedPointerScope, held: PointerTarget?) -> PointerTarget? {
        let geometry = scope.epoch.geometry
        let sourceRect = CGRect(x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height)
        guard point.x.isFinite, point.y.isFinite, held != nil || sourceRect.contains(point) else { return nil }
        let candidates: [[String: Any]]
        if let held {
            candidates = rows.filter { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == held.window }
            guard candidates.count == 1 else { return nil }
        } else { candidates = rows }
        let own = Set(curtainWindowIDs)
        var verifiedCursorOwners: [pid_t: Bool] = [:]
        for row in candidates {
            guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), !rect.isNull, !rect.isEmpty else { return nil }
            if own.contains(id) { continue }
            if alpha == 0 || (held == nil && !rect.contains(point)) { continue }
            if Self.isSystemCursorWindow(row, verifiedOwners: &verifiedCursorOwners) { continue }
            guard alpha > 0, layer == 0, pid > 0, pid != getpid(),
                  let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  app.activationPolicy == .regular, let launched = app.launchDate,
                  let bundle = app.bundleIdentifier,
                  !["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent",
                    "com.apple.CoreAuthUI", "com.apple.dock"].contains(bundle) else { return nil }
            if held == nil {
                guard let foreground = NSWorkspace.shared.frontmostApplication,
                      foreground.processIdentifier == pid, foreground.launchDate == launched else { return nil }
            }
            switch scope.epoch.source {
            case .window(let expected): guard id == expected else { return nil }
            case .desktop: break
            default: return nil
            }
            return PointerTarget(scope: scope, window: id, pid: pid, launched: launched)
        }
        return nil
    }

    private func filter(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            invalidate("입력 필터가 운영체제에 의해 중단되었습니다. 보호 상태를 다시 확인해야 합니다.")
            return nil
        }
        if currentLocalAuthenticationChallenge() != nil {
            localReturnDown = nil
            return nil
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.remoteEventTag,
           event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
            guard isProtected, environmentIsUsable() else { return nil }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown {
            localReturnDown = visibleReturnButton(at: event.location)
        } else if type == .leftMouseUp {
            let down = localReturnDown
            localReturnDown = nil
            if let down, visibleReturnButton(at: event.location) == down {
                // Consume the click here. No local input is passed to an authentication window.
                requestLocalReturn?()
            }
        }
        return nil
    }

    private func currentLayout() -> [CGDirectDisplayID: CGRect]? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success, count < displays.count else { return nil }
        let expected = Set(displays.prefix(Int(count)).filter { !StreamCoordinator.isSillVirtualDisplay($0) })
        var result: [CGDirectDisplayID: CGRect] = [:]
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            if !StreamCoordinator.isSillVirtualDisplay(id) { result[id] = screen.frame }
        }
        guard !result.isEmpty, Set(result.keys) == expected else { return nil }
        return result
    }

    private func rebuildCurtains() -> Bool {
        guard let next = currentLayout() else {
            invalidate("현재 디스플레이 목록과 화면 영역을 확정할 수 없습니다. 기존 가림 화면을 유지합니다.")
            return false
        }
        for (id, frame) in next {
            let curtain = curtains[id] ?? makeCurtain(frame: frame)
            curtains[id] = curtain
            curtain.panel.setFrame(frame, display: true)
            curtain.panel.orderFrontRegardless()
        }
        layout = next
        // Keep old panels until every replacement has been checked.
        guard curtainsAreEffective() else { return false }
        for id in Array(curtains.keys) where next[id] == nil { curtains.removeValue(forKey: id)?.panel.close() }
        return true
    }

    private func makeCurtain(frame: CGRect) -> Curtain {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = curtainMessage.title
        panel.isFloatingPanel = true
        panel.level = Self.curtainLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.alphaValue = 1
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.sharingType = .none
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        panel.contentView = view
        let title = NSTextField(labelWithString: curtainMessage.title)
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        let detail = NSTextField(wrappingLabelWithString: curtainMessage.detail)
        detail.textColor = .lightGray
        detail.alignment = .center
        let button = NSButton(title: "로컬 복귀 요청", target: self, action: #selector(returnRequested))
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("로컬 복귀 요청. 새 운영체제 인증이 필요합니다.")
        let stack = NSStackView(views: [title, detail, button])
        stack.orientation = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)
        ])
        view.layoutSubtreeIfNeeded()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Animate content only. The black covering panel is opaque from its first frame.
            stack.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                stack.animator().alphaValue = 1
            }
        }
        return Curtain(panel: panel, returnButton: button, title: title, detail: detail)
    }

    private var curtainMessage: (title: String, detail: String) {
        if isProtected && currentLocalAuthenticationChallenge() == nil {
            return ("원격 제어 모드 활성화",
                    "현재 사용자 데스크톱의 일반 입력 차단을 확인했습니다.\n전원 버튼·시스템 보안 화면의 차단은 보장하지 않습니다.\n로컬 복귀에는 새 운영체제 인증이 필요하며 키보드 입력 차단은 유지됩니다.")
        }
        let explanation = localReturnReason() ?? reason ?? "입력 차단과 원격 동작을 다시 확인하고 있습니다."
        return ("원격 제어 보호 복구 중",
                "기존 화면 가림을 유지합니다.\n\(explanation)\n로컬 복귀 요청은 새 운영체제 인증으로 확인합니다.")
    }

    private func updateCurtainText() {
        let message = curtainMessage
        for curtain in curtains.values {
            curtain.panel.ignoresMouseEvents = false
            curtain.panel.title = message.title
            curtain.title.stringValue = message.title
            curtain.detail.stringValue = message.detail
        }
    }

    private func curtainsAreEffective() -> Bool {
        guard let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            invalidate("운영체제에서 가림 화면 표시 상태를 읽지 못했습니다.")
            return false
        }
        var verifiedCursorOwners: [pid_t: Bool] = [:]
        for (id, frame) in layout {
            guard let panel = curtains[id]?.panel, panel.isVisible, panel.isOnActiveSpace,
                  panel.frame == frame, panel.isOpaque, panel.alphaValue == 1, !panel.ignoresMouseEvents,
                  panel.level == Self.curtainLevel, panel.sharingType == .none,
                  let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber }),
                  (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid(),
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 1,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == Self.curtainLevel.rawValue,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect == CGDisplayBounds(id) else {
                invalidate("가림 화면의 실제 표시·불투명도·영역을 확인하지 못했습니다.")
                return false
            }
            let ownIDs = Set(curtainWindowIDs)
            for covering in rows.prefix(while: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue != panel.windowNumber }) {
                guard let number = (covering[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      !ownIDs.contains(number),
                      (covering[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                      let bounds = covering[kCGWindowBounds as String] as? NSDictionary,
                      let coveringRect = CGRect(dictionaryRepresentation: bounds), coveringRect.intersects(rect) else { continue }
                if Self.isSystemCursorWindow(covering, verifiedOwners: &verifiedCursorOwners) { continue }
                invalidate("다른 화면이 가림 화면 위에 표시되어 보호 상태를 보장할 수 없습니다.")
                return false
            }
        }
        return true
    }

    private static func isSystemCursorWindow(_ row: [String: Any], verifiedOwners: inout [pid_t: Bool]) -> Bool {
        guard let level = row[kCGWindowLayer as String] as? Int32,
              level == CGWindowLevelForKey(.cursorWindow),
              let pid = row[kCGWindowOwnerPID as String] as? pid_t, pid > 0 else { return false }
        if let verified = verifiedOwners[pid] { return verified }
        var guest: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary,
                                            [], &guest) == errSecSuccess, let guest,
              SecRequirementCreateWithString("anchor apple and identifier \"com.apple.WindowServer\"" as CFString,
                                             [], &requirement) == errSecSuccess, let requirement else {
            verifiedOwners[pid] = false
            return false
        }
        let verified = SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
        verifiedOwners[pid] = verified
        return verified
    }

    private func visibleReturnButton(at point: CGPoint) -> CGWindowID? {
        guard let main = NSScreen.screens.first,
              let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var verifiedCursorOwners: [pid_t: Bool] = [:]
        let appPoint = CGPoint(x: point.x, y: main.frame.maxY - point.y)
        for curtain in curtains.values {
            let panel = curtain.panel
            let button = curtain.returnButton
            guard panel.isVisible, panel.isOnActiveSpace, panel.alphaValue == 1,
                  panel.windowNumber > 0,
                  !button.isHiddenOrHasHiddenAncestor, button.isEnabled,
                  button.ancestorsHaveFullOpacity else { continue }
            let visible = button.visibleRect.intersection(button.bounds)
            let rect = panel.convertToScreen(button.convert(visible, to: nil))
            guard !visible.isEmpty, rect.contains(appPoint) else { continue }
            // The first on-screen window under the point must be this curtain.
            let front = rows.first { row in
                guard (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                      let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                return rect.contains(point) && !Self.isSystemCursorWindow(row, verifiedOwners: &verifiedCursorOwners)
            }
            let id = CGWindowID(panel.windowNumber)
            if (front?[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id { return id }
        }
        return nil
    }

    @objc private func returnRequested() { requestLocalReturn?() }

    private func observeChanges() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didChangeScreenParametersNotification),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.didWakeNotification)
        ]
        for (center, name) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch notification.name {
                    case NSWorkspace.sessionDidResignActiveNotification: self.sessionActive = false
                    case NSWorkspace.sessionDidBecomeActiveNotification: self.sessionActive = true
                    case NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification: self.sleeping = true
                    case NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification: self.sleeping = false
                    default: break
                    }
                    self.invalidate("화면 또는 사용자 세션이 바뀌어 보호 상태를 다시 확인해야 합니다.")
                    guard !self.changingLifecycle else { return }
                    self.changingLifecycle = true
                    defer { self.changingLifecycle = false }
                    if notification.name == NSApplication.didChangeScreenParametersNotification || notification.name == NSWorkspace.activeSpaceDidChangeNotification {
                        _ = self.rebuildCurtains()
                    }
                }
            }
            observers.append((center, token))
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.notifiedLocked = locked
                    self.invalidate("화면 잠금 상태가 바뀌어 보호 상태를 다시 확인해야 합니다.")
                }
            })
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateCurtainText()
                self?.changed?()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        timer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
        for token in lockObservers { DistributedNotificationCenter.default().removeObserver(token) }
        let panels = curtains.values.map(\.panel)
        DispatchQueue.main.async { for panel in panels { panel.close() } }
    }
}

private extension NSView {
    var ancestorsHaveFullOpacity: Bool {
        alphaValue == 1 && (superview?.ancestorsHaveFullOpacity ?? true)
    }
}
