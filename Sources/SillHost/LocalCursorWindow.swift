import AppKit
import ApplicationServices
import ScreenCaptureKit
import StreamProtocol

@MainActor
final class LocalCursorWindow {
    let id: CGWindowID
    let process: LocalCursorProcessIdentity
    let element: AXUIElement
    let frame: CGRect

    private init(id: CGWindowID, process: LocalCursorProcessIdentity, element: AXUIElement, frame: CGRect) {
        self.id = id; self.process = process; self.element = element; self.frame = frame
    }

    static func capture(window: SCWindow, pid: pid_t, sizer: WindowSizer) -> LocalCursorWindow? {
        guard AXIsProcessTrusted(), window.owningApplication?.processID == pid,
              let identity = LocalCursorProcessIdentity.capture(pid, application: .cursor),
              let frame = liveFrame(window.windowID, pid: pid),
              let element = sizer.element(for: window, input: true) else { return nil }
        let record = LocalCursorWindow(id: window.windowID, process: identity, element: element, frame: frame)
        return record.isLive ? record : nil
    }

    var isLive: Bool {
        guard AXIsProcessTrusted(), process.isCurrent, let current = Self.liveFrame(id, pid: process.pid),
              Self.matches(current, frame), let elementFrame = WindowSizer.frame(of: element),
              Self.matches(elementFrame, frame) else { return false }
        var actual: pid_t = 0
        guard AXUIElementGetPid(element, &actual) == .success, actual == process.pid else { return false }
        return true
    }

    func permits(_ event: InputEvent) -> Bool {
        guard isLive, NSWorkspace.shared.frontmostApplication?.processIdentifier == process.pid,
              WindowSizer.hasKeyboardFocus(element, pid: process.pid) else { return false }
        let point: CGPoint?
        switch event {
        case .pointer(_, let x, let y), .scroll(let x, let y, _, _), .scrollGesture(_, let x, let y):
            point = CGPoint(x: frame.minX + CGFloat(x) * frame.width, y: frame.minY + CGFloat(y) * frame.height)
        default: point = nil
        }
        let front = StreamCoordinator.topmostInputWindow(at: point)
        return front?.id == id && front?.pid == process.pid
    }

    func focus(authorize: (_ operation: () -> Void) -> Bool) -> Bool {
        guard isLive else { return false }
        let app = AXUIElementCreateApplication(process.pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard authorize({ _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }),
              authorize({ _ = WindowSizer.raise(element) }), authorize({ WindowSizer.makeKey(element) }) else { return false }
        return isLive && WindowSizer.hasKeyboardFocus(element, pid: process.pid)
    }

    private static func liveFrame(_ id: CGWindowID, pid: pid_t) -> CGRect? {
        guard let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              rows.count == 1, let row = rows.first,
              row[kCGWindowNumber as String] as? CGWindowID == id,
              row[kCGWindowOwnerPID as String] as? pid_t == pid,
              row[kCGWindowLayer as String] as? Int == 0,
              row[kCGWindowIsOnscreen as String] as? Bool == true,
              (row[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let raw = row[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: raw as CFDictionary),
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    private static func matches(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 0.5 && abs(first.minY - second.minY) < 0.5 &&
        abs(first.width - second.width) < 0.5 && abs(first.height - second.height) < 0.5
    }
}
