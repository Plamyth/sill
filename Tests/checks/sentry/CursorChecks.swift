import Foundation
import CoreGraphics

@MainActor
private final class CursorWindowFixture {
    struct Level: Equatable { let rawValue: Int }
    enum SharingType { case none }
    @MainActor enum NSScreen { static let screens = [Panel()] }
    struct Button {
        let isHiddenOrHasHiddenAncestor = false, isEnabled = true, ancestorsHaveFullOpacity = true
        let visibleRect = CGRect(x: 20, y: 20, width: 60, height: 40)
        var bounds: CGRect { visibleRect }
        func convert(_ rect: CGRect, to: Any?) -> CGRect { rect }
    }
    @MainActor struct Panel {
        let windowNumber = 90
        var isVisible = true, isOnActiveSpace = true, isOpaque = true, ignoresMouseEvents = false
        let alphaValue = 1.0
        let level = CursorWindowFixture.curtainLevel
        let sharingType = SharingType.none
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        func convertToScreen(_ rect: CGRect) -> CGRect { rect }
    }
    struct Curtain { let panel: Panel; let returnButton = Button() }
    static let curtainLevel = Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
    let curtains: [CGDirectDisplayID: Curtain] = [1: Curtain(panel: Panel())]
    let layout: [CGDirectDisplayID: CGRect] = [1: Panel().frame]
    let curtainWindowIDs: [CGWindowID] = [90]
    var rows: [[String: Any]] = []
    var reason: String?
    func invalidate(_ message: String) { reason = message }
    func CGDisplayBounds(_ id: CGDirectDisplayID) -> CGRect { layout[id] ?? .zero }
    func CGWindowListCopyWindowInfo(_ options: CGWindowListOption, _ id: CGWindowID) -> CFArray? { rows as CFArray }
    private func isObservedAuthenticationWindow(_ row: [String: Any]) -> Bool { false }
    __PRODUCTION_CURSOR_BOUNDARY__

    struct SecCode { let pid: pid_t }
    struct SecRequirement { let text: String }
    static let errSecSuccess: Int32 = 0
    static let kSecGuestAttributePid = "pid" as CFString
    static var identities: [pid_t: (apple: Bool, identifier: String)] = [:]
    static var lookupStatus: Int32 = 0, requirementStatus: Int32 = 0, validityStatus: Int32 = 0
    static var missingGuest = false, missingRequirement = false
    static var lookupCalls: [pid_t: Int] = [:]
    static func SecCodeCopyGuestWithAttributes(_ host: SecCode?, _ attributes: CFDictionary,
                                               _ flags: [Int], _ output: inout SecCode?) -> Int32 {
        guard let pid = (attributes as NSDictionary)[kSecGuestAttributePid as String] as? pid_t else { return -1 }
        lookupCalls[pid, default: 0] += 1
        if lookupStatus == 0 && !missingGuest { output = SecCode(pid: pid) }
        return lookupStatus
    }
    static func SecRequirementCreateWithString(_ text: CFString, _ flags: [Int],
                                               _ output: inout SecRequirement?) -> Int32 {
        if requirementStatus == 0 && !missingRequirement { output = SecRequirement(text: text as String) }
        return requirementStatus
    }
    static func SecCodeCheckValidity(_ code: SecCode, _ flags: [Int], _ requirement: SecRequirement) -> Int32 {
        guard validityStatus == 0,
              requirement.text == "anchor apple and identifier \"com.apple.WindowServer\"",
              let identity = identities[code.pid], identity.apple, identity.identifier == "com.apple.WindowServer" else { return -67050 }
        return 0
    }

    func verify(_ covering: [[String: Any]]) -> Bool {
        reason = nil
        let frame = Panel().frame
        rows = covering + [[kCGWindowNumber as String: 90, kCGWindowOwnerPID as String: NSNumber(value: getpid()),
                           kCGWindowAlpha as String: 1, kCGWindowLayer as String: Self.curtainLevel.rawValue,
                           kCGWindowBounds as String: frame.dictionaryRepresentation]]
        return curtainsAreEffective()
    }

    func hitTest(_ covering: [[String: Any]]) -> CGWindowID? {
        _ = verify(covering)
        return visibleReturnButton(at: CGPoint(x: 30, y: 1050))
    }

    static func run() {
        let fixture = CursorWindowFixture(), cursorLevel = CGWindowLevelForKey(.cursorWindow)
        let pid: pid_t = 70835, spoof: pid_t = 70524
        identities = [pid: (true, "com.apple.WindowServer"), spoof: (false, "com.ambrion.sillcanvas.mac")]
        func row(_ owner: pid_t, level: Int32 = CGWindowLevelForKey(.cursorWindow)) -> [String: Any] {
            [kCGWindowNumber as String: 2, kCGWindowOwnerPID as String: NSNumber(value: owner),
             kCGWindowOwnerName as String: "Window Server", kCGWindowLayer as String: NSNumber(value: level),
             kCGWindowAlpha as String: 1,
             kCGWindowBounds as String: CGRect(x: 20, y: 20, width: 28, height: 40).dictionaryRepresentation]
        }
        Checks.expect(fixture.verify([]), "기존 가림 화면은 단독 표시 상태에서 유효함")
        Checks.expect(fixture.verify([row(pid)]), "Apple WindowServer의 SDK 커서 레벨은 실제 가림 판정에서 제외함")
        lookupCalls = [:]
        Checks.expect(fixture.verify([row(pid), row(pid)]), "같은 검사 안의 여러 정규 커서를 제외함")
        Checks.expect(lookupCalls[pid] == 1, "한 가림 검사 안에서 같은 PID 서명은 한 번 조회함")
        Checks.expect(!fixture.verify([row(pid, level: cursorLevel - 1)]), "WindowServer도 커서와 다른 레벨이면 거부함")
        Checks.expect(!fixture.verify([row(spoof)]), "다른 앱은 같은 커서 레벨과 이름과 작은 영역이어도 거부함")
        identities[spoof] = (false, "com.apple.WindowServer")
        Checks.expect(!fixture.verify([row(spoof)]), "WindowServer 식별자를 사칭해도 Apple 서명이 없으면 거부함")
        identities[spoof] = (true, "com.apple.Other")
        Checks.expect(!fixture.verify([row(spoof)]), "다른 Apple 프로세스는 같은 커서 레벨이어도 거부함")
        Checks.expect(!fixture.verify([row(pid), row(spoof)]), "정규 커서가 앞에 있어도 뒤의 다른 소유자는 거부함")
        for key in [kCGWindowLayer, kCGWindowOwnerPID] {
            var missing = row(pid)
            missing.removeValue(forKey: key as String)
            Checks.expect(!fixture.verify([missing]), "커서 예외 필수 정보 \(key)가 없으면 거부함")
            missing[key as String] = "Window Server"
            Checks.expect(!fixture.verify([missing]), "커서 예외 필수 정보 \(key)의 타입이 틀리면 거부함")
        }
        Checks.expect(!fixture.verify([row(0)]) && !fixture.verify([row(-1)]), "유효하지 않은 PID는 거부함")
        var anonymous = row(pid)
        anonymous.removeValue(forKey: kCGWindowOwnerName as String)
        Checks.expect(fixture.verify([anonymous]), "이름 누락은 SDK 레벨과 실제 서명 확인을 대신하지 않음")
        for failure in 0..<5 {
            lookupStatus = failure == 0 ? -1 : 0
            missingGuest = failure == 1
            requirementStatus = failure == 2 ? -1 : 0
            missingRequirement = failure == 3
            validityStatus = failure == 4 ? -1 : 0
            Checks.expect(!fixture.verify([row(pid)]), "Security 경계 실패 \(failure)는 커서 예외를 허용하지 않음")
        }
        lookupStatus = 0; missingGuest = false; requirementStatus = 0; missingRequirement = false; validityStatus = 0
        Checks.expect(fixture.verify([row(pid)]), "새 검사에서 Security 재확인 성공 후 정규 커서를 허용함")
        identities[pid] = (false, "com.apple.WindowServer")
        Checks.expect(!fixture.verify([row(pid)]), "다음 검사에서 PID가 재활용돼도 이전 성공 캐시를 사용하지 않음")
        identities[pid] = (true, "com.apple.WindowServer")
        Checks.expect(fixture.verify([row(pid)]), "다음 검사는 이전 실패도 캐시하지 않고 실제 정체성을 재확인함")
        var atButton = row(pid)
        atButton[kCGWindowBounds as String] = CGRect(x: 20, y: 1040, width: 28, height: 40).dictionaryRepresentation
        Checks.expect(fixture.hitTest([]) == 90, "가려지지 않은 복귀 버튼은 실제 hit-test에서 선택됨")
        Checks.expect(fixture.hitTest([atButton]) == 90, "검증된 시스템 커서만 버튼 위에 있으면 실제 hit-test에서 버튼을 선택함")
        atButton[kCGWindowOwnerPID as String] = NSNumber(value: spoof)
        Checks.expect(fixture.hitTest([atButton]) == nil, "같은 커서 레벨의 다른 소유자가 버튼을 가리면 hit-test에서 거부함")
        atButton[kCGWindowOwnerPID as String] = NSNumber(value: pid)
        atButton[kCGWindowLayer as String] = cursorLevel - 1
        Checks.expect(fixture.hitTest([atButton]) == nil, "WindowServer도 다른 레벨에서 버튼을 가리면 hit-test에서 거부함")
        atButton[kCGWindowLayer as String] = Self.curtainLevel.rawValue + 1
        atButton[kCGWindowOwnerPID as String] = NSNumber(value: spoof)
        Checks.expect(fixture.hitTest([atButton]) == nil, "일반 overlay가 버튼을 가리면 hit-test에서 거부함")
        atButton[kCGWindowLayer as String] = cursorLevel
        atButton.removeValue(forKey: kCGWindowOwnerPID as String)
        Checks.expect(fixture.hitTest([atButton]) == nil, "소유자 미확인 커서 창이 버튼을 가리면 hit-test에서 거부함")
        atButton[kCGWindowOwnerPID as String] = NSNumber(value: pid)
        lookupStatus = -1
        Checks.expect(fixture.hitTest([atButton]) == nil, "서명 조회가 실패하면 버튼 hit-test도 거부함")
        lookupStatus = 0
        print("CURSOR_WINDOW_CHECKS_COMPLETE \(Checks.count)")
    }
}

extension Checks {
    @MainActor static func cursorWindowChecks() { CursorWindowFixture.run() }
}
