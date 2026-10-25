import Foundation
import CoreGraphics
import Darwin

private struct InertTap { var valid = true; var enabled = true }
private func CFMachPortIsValid(_ tap: InertTap) -> Bool { tap.valid }
private final class Event {
    var type = CGEventType.keyDown
    var flags: CGEventFlags = []
    var location = CGPoint.zero
    var fields: [CGEventField: Int64] = [:]
    init?(source: Any?) {}
    func getIntegerValueField(_ field: CGEventField) -> Int64 { fields[field] ?? 0 }
    func setIntegerValueField(_ field: CGEventField, value: Int64) { fields[field] = value }
    func setSource(_ source: EventSource) { fields[.eventSourceUserData] = source.userData }
    static func tapIsEnabled(tap: InertTap) -> Bool { tap.enabled }
    func copy() -> Event? {
        let e = Event(source: nil)!
        e.type = type; e.flags = flags; e.location = location; e.fields = fields
        return e
    }
}

private final class EventSource {
    var userData: Int64 = 0
    let sourceStateID: CGEventSourceStateID
    init?(stateID: CGEventSourceStateID) { sourceStateID = stateID }
}

@MainActor private final class Platform {
    enum State { case idle, engaging, protected, releasing, invalid(String) }
    private var state = State.protected
    private static let remoteEventTag: Int64 = 12345
    private var localAuthenticationInputPolicy = LocalAuthenticationInputPolicy()
    private var authenticationEventTag: Int64 = 1
    private var challengeID: UUID?
    private func currentLocalAuthenticationChallenge() -> UUID? { challengeID }
    private var localReturnDown: CGWindowID?
    private var requestLocalReturn: (() -> Void)?
    private var changingLifecycle = false
    private var changed: (() -> Void)?
    private var sessionTapVerified = true, annotatedTapVerified = true, inputEnvironmentVerified = true
    private var tap: InertTap? = InertTap(), annotatedTap: InertTap? = InertTap()
    private var tapID: UInt32? = 10, annotatedTapID: UInt32? = 11
    private var pointerTargets: [Int: Int] = [:], scrollHandoff: Int?
    private var rebuilds = 0, installations = 0
    private var tapReadbackAvailable = true, windowReadbackAvailable = true, windowRemains = false
    private var remainingTapPID: pid_t?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lockObservers: [NSObjectProtocol] = []
    private enum DistributedNotificationCenter { static func `default`() -> NotificationCenter { .default } }
    private func destroyTap() { tap = nil; sessionTapVerified = false; inputEnvironmentVerified = false }
    private func destroyAnnotatedTap() { annotatedTap = nil; annotatedTapVerified = false; localAuthenticationInputPolicy.revoke() }
    private static var tapOwner: Platform?
    private func observeChanges() {}
    private func rebuildCurtains() -> Bool { rebuilds += 1; return surfacesSafe }
    private func installTap() -> Bool { installations += 1; return tap != nil && sessionTapVerified }
    private func installAnnotatedTap() -> Bool { installations += 1; return annotatedTap != nil && annotatedTapVerified }
    private func eventTapList() -> [CGEventTapInformation]? {
        guard tapReadbackAvailable else { return nil }
        var session = CGEventTapInformation(), annotated = CGEventTapInformation()
        session.eventTapID = 10; annotated.eventTapID = 11
        var rows = [session, annotated]
        if let pid = remainingTapPID {
            var remaining = CGEventTapInformation()
            remaining.eventTapID = 444; remaining.tappingProcess = pid
            remaining.tapPoint = .cgSessionEventTap; remaining.enabled = true
            rows.append(remaining)
        }
        return rows
    }
    private func tapIsEffective(_ row: CGEventTapInformation, at point: CGEventTapLocation = .cgSessionEventTap) -> Bool {
        sessionTapVerified && annotatedTapVerified
    }
    private var observedReturnButtons: [CGWindowID: CGRect] = [:]
    private var observedRemoteTarget: LocalAuthenticationInputPolicy.ProcessIdentity?
    private var inputObservationExpires = ContinuousClock.now
    private var usable = true, surfacesSafe = true
    private var secureInput = false
    private var notifiedLocked = false, sessionActive = true, sleeping = false
    private func AXIsProcessTrusted() -> Bool { usable }
    private func CGPreflightListenEventAccess() -> Bool { usable }
    private func IsSecureEventInputEnabled() -> Bool { secureInput }
    private func CGSessionCopyCurrentDictionary() -> CFDictionary? {
        [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true,
         kCGSessionUserIDKey as String: getuid()] as CFDictionary
    }
    private var layout = [0: 0]
    private func currentLayout() -> [Int: Int]? { [0: 0] }
    private func curtainsAreEffective() -> Bool { surfacesSafe }
    private var rows: [[String: Any]] = []
    private var observationCalls = 0
    private func updateCurtainText() {}
    private final class Button {
        var isHiddenOrHasHiddenAncestor = false, isEnabled = true, ancestorsHaveFullOpacity = true
        var bounds = CGRect(x: 0, y: 0, width: 100, height: 40)
        var visibleRect = CGRect(x: 0, y: 0, width: 100, height: 40)
        func convert(_ rect: CGRect, to: Any?) -> CGRect { rect }
    }
    private final class Panel {
        struct Identifier { var rawValue: String }
        struct Level { var rawValue: Int }
        enum Sharing { case none, readWrite }
        var identifier: Identifier? = Identifier(rawValue: "CCR.LocalAuthentication")
        var level = Level(rawValue: 1002)
        var isKeyWindow = false, isOpaque = true, ignoresMouseEvents = false
        var sharingType = Sharing.none
        var frame = CGRect(x: 40, y: 300, width: 480, height: 240)
        var screen: Screen? = NSScreen.screens.first
        weak var sheetParent: Panel?
        var attachedSheet: Panel?
        var isVisible = true, isOnActiveSpace = true, alphaValue = 1.0
        var windowNumber = 90
        func convertToScreen(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 20, dy: 800) }
        func close() { isVisible = false }
    }
    private struct Curtain { let panel = Panel(); let returnButton = Button() }
    private var curtains: [Int: Curtain] = [:]
    private var curtainWindowIDs: [CGWindowID] { curtains.values.map { CGWindowID($0.panel.windowNumber) } }
    private final class Screen { let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000) }
    private enum NSScreen { static let screens = [Screen()] }
    private typealias NSWindow = Panel
    private static let curtainLevel = Panel.Level(rawValue: 1001)
    private enum NSApp { static var isActive = true; static var keyWindow: Panel? }
    private enum LocalAuthenticationPresentation {
        static weak var root: Panel?
        static var requestID: UUID?
        static func registeredWindow(for id: UUID) -> Panel? { requestID == id ? root : nil }
        static func builtinScreen(in screens: [Screen]) -> Screen? { screens.first }
    }

    private func CGWindowListCopyWindowInfo(_ options: CGWindowListOption, _ id: CGWindowID) -> CFArray? {
        observationCalls += 1
        guard windowReadbackAvailable else { return nil }
        let closed = Set(curtains.values.filter { !$0.panel.isVisible }.map { CGWindowID($0.panel.windowNumber) })
        return rows.filter { row in
            windowRemains || !closed.contains((row[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        } as CFArray
    }
    private static func isSystemCursorWindow(_ row: [String: Any], verifiedOwners: inout [pid_t: Bool]) -> Bool {
        row["verifiedCursor"] as? Bool == true
    }
    enum ActivationPolicy { case regular, accessory }
    @MainActor private final class Workspace { var frontmostApplication: App? }
    @MainActor private enum NSWorkspace { static let shared = Workspace() }
    struct App {
        var activationPolicy = ActivationPolicy.regular
        var processIdentifier: pid_t = 100
        var isTerminated = false
        var launchDate: Date? = Date(timeIntervalSince1970: 100)
        var bundleIdentifier: String? = "com.apple.LocalAuthentication.UIAgent"
        var executableURL: URL? = URL(fileURLWithPath: "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha")
        var appleSigned = true
    }
    private static var apps: [pid_t: App] = [:]
    private static var identities: [pid_t: LocalAuthenticationInputPolicy.ProcessIdentity] = [:]
    private static var paths: [pid_t: String] = [:]
    private static var identityReads = 0
    private static func processIdentity(_ pid: pid_t) -> LocalAuthenticationInputPolicy.ProcessIdentity? {
        identityReads += 1; return identities[pid]
    }
    private static func processPath(_ pid: pid_t) -> String? { paths[pid] }
    private static func NSRunningApplication(processIdentifier: pid_t) -> App? { apps[processIdentifier] }
    private struct SecCode { let pid: pid_t }
    private struct SecRequirement { let text: String }
    private static let errSecSuccess: Int32 = 0
    private static let kSecGuestAttributePid = "pid" as CFString
    private static var signatureCalls = 0
    private static func SecCodeCopyGuestWithAttributes(_ host: SecCode?, _ attributes: CFDictionary,
        _ flags: [Int], _ output: inout SecCode?) -> Int32 {
        signatureCalls += 1
        guard let pid = (attributes as NSDictionary)["pid"] as? pid_t else { return -1 }
        output = .init(pid: pid); return 0
    }
    private static func SecRequirementCreateWithString(_ text: CFString, _ flags: [Int], _ output: inout SecRequirement?) -> Int32 {
        output = .init(text: text as String); return 0
    }
    private static func SecCodeCheckValidity(_ code: SecCode, _ flags: [Int], _ requirement: SecRequirement) -> Int32 {
        guard let app = apps[code.pid], app.appleSigned, let id = app.bundleIdentifier,
              requirement.text == "anchor apple and identifier \"\(id)\"" else { return -1 }
        return 0
    }
    __PRODUCTION__
    __PRODUCTION_OBSERVER__

    private func window(_ id: UInt32 = 70, pid: Int32 = 700, alpha: Double = 1,
                        rect: CGRect = CGRect(x: 10, y: 10, width: 300, height: 200)) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: rect.dictionaryRepresentation]
    }
    private func fresh() {
        LocalAuthenticationPresentation.root = nil; LocalAuthenticationPresentation.requestID = nil
        NSApp.isActive = true; NSApp.keyWindow = nil
        state = .protected; usable = true; surfacesSafe = true; inputEnvironmentVerified = true
        secureInput = false; notifiedLocked = false; sessionActive = true; sleeping = false; curtains = [:]
        tapReadbackAvailable = true; windowReadbackAvailable = true; windowRemains = false; remainingTapPID = nil
        tapID = 10; annotatedTapID = 11; pointerTargets = [:]; layout = [0: 0]
        tap = InertTap(); annotatedTap = InertTap(); sessionTapVerified = true; annotatedTapVerified = true
        let id = UUID(); localAuthenticationWillBegin(id); challengeID = id
        Self.apps = [700: App()]
        Self.identities = [700: .init(pid: 700, startSeconds: 100, startMicroseconds: 10),
                           100: .init(pid: 100, startSeconds: 200, startMicroseconds: 20)]
        var normal = App(); normal.bundleIdentifier = "org.example.editor"
        Self.NSWorkspace.shared.frontmostApplication = normal
        Self.paths = [700: Self.apps[700]!.executableURL!.path]
        rows = [window()]
        refreshInputObservation()
    }
    private func event(_ type: CGEventType = .keyDown, target: Int64 = 700) -> Event {
        let result = Event(source: nil)!
        result.type = type; result.flags = []; result.location = CGPoint(x: 50, y: 50)
        result.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        result.setIntegerValueField(.eventSourceStateID, value: Int64(CGEventSourceStateID.hidSystemState.rawValue))
        result.setIntegerValueField(.eventSourceUserData, value: 0)
        result.setIntegerValueField(.eventTargetUnixProcessID, value: target)
        result.setIntegerValueField(.keyboardEventKeycode, value: 0)
        result.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 70)
        result.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 70)
        return result
    }
    private func transit(_ event: Event) -> Bool {
        filter(event.type, event: event) != nil && filterAnnotated(event.type, event: event) != nil
    }

    func additionalReviewChecks() async {
        fresh()
        Self.apps[700]!.bundleIdentifier = "com.apple.SecurityAgent"
        Self.apps[700]!.executableURL = URL(fileURLWithPath: Self.authenticationExecutables["com.apple.SecurityAgent"]!)
        Self.paths[700] = Self.apps[700]!.executableURL!.path
        refreshInputObservation()
        Checks.check(transit(event()), "독립 SecurityAgent 관측과 생산 callback 양성")
        fresh(); let queued = event()
        Checks.check(filter(.keyDown, event: queued) != nil, "독립 기한 전 session enqueue")
        try? await Task.sleep(for: .milliseconds(280))
        Checks.check(filterAnnotated(.keyDown, event: queued) == nil, "독립 clock 만료 뒤 queued annotated 거절")
        refreshInputObservation()
        Checks.check(filterAnnotated(.keyDown, event: queued) == nil && transit(event()), "독립 재관측 옛 tag 거절·새 입력 수용")
        fresh(); let crossed = event(); _ = filter(.keyDown, event: crossed)
        crossed.setIntegerValueField(.eventTargetUnixProcessID, value: 100)
        Checks.check(filterAnnotated(.keyDown, event: crossed) == nil, "독립 callback 사이 OS 대상 변경 거절")
        fresh(); let reused = event(); _ = filter(.keyDown, event: reused)
        Self.identities[700] = .init(pid: 700, startSeconds: 100, startMicroseconds: 11)
        Checks.check(filterAnnotated(.keyDown, event: reused) == nil, "독립 callback 사이 같은 초 PID 재사용 거절")
        fresh(); let hidden = event(); _ = filter(.keyDown, event: hidden)
        rows = []; refreshInputObservation()
        Checks.check(filterAnnotated(.keyDown, event: hidden) == nil, "독립 queued pass 뒤 창 소실 관측 거절")
        fresh(); let stopped = event(); _ = filter(.keyDown, event: stopped)
        _ = filter(.tapDisabledByTimeout, event: event())
        Checks.check(filterAnnotated(.keyDown, event: stopped) == nil, "독립 session tap 중단 queued annotated 거절")
        await Task.yield()
        fresh(); let noAuth = event(); _ = filter(.keyDown, event: noAuth); challengeID = nil
        Checks.check(filterAnnotated(.keyDown, event: noAuth) == nil && !transit(event()), "독립 auth 종료 후 proof·tag 권한 없음")
        fresh()
        for (type,key,flags): (CGEventType,Int64,CGEventFlags) in [(.keyDown,48,[]),(.keyDown,51,[]),(.keyDown,36,[]),(.keyUp,36,[]),(.flagsChanged,56,[.maskShift]),(.flagsChanged,60,[.maskShift]),(.flagsChanged,57,[.maskAlphaShift])] {
            let e=event(type); e.flags=flags; e.setIntegerValueField(.keyboardEventKeycode,value:key)
            Checks.check(transit(e), "독립 편집·Tab·Return·Shift/Caps 양성 \(key)/\(type.rawValue)")
        }
        fresh(); let newWindow=event(.leftMouseDown); _=filter(.leftMouseDown,event:newWindow)
        newWindow.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:80)
        Checks.check(filterAnnotated(.leftMouseDown,event:newWindow)==nil, "독립 callback 사이 클릭 처리창 변경 거절")
        fresh(); layout=[0: 1]; refreshInputObservation()
        Checks.check(!transit(event()), "독립 layout 변경 양성 경로 폐기")
        layout=[0: 0]; fresh(); let oldTag=localAuthenticationInputPolicy.observation!.handoffTag
        rows=[]; refreshInputObservation(); rows=[window()]; refreshInputObservation()
        Checks.check(localAuthenticationInputPolicy.observation!.handoffTag != oldTag && transit(event()), "독립 관측 복구 전달 세대 갱신")
    }

    private func ownedContainerChecks() {
        fresh()
        let root = Panel(); root.windowNumber = 91; root.isKeyWindow = true
        let requestID = challengeID!
        LocalAuthenticationPresentation.root = root; LocalAuthenticationPresentation.requestID = requestID
        NSApp.keyWindow = root
        Self.identities[getpid()] = .init(pid: getpid(), startSeconds: 300, startMicroseconds: 30)
        func row(_ window: Panel) -> [String: Any] {
            let f = window.frame
            var value = self.window(UInt32(window.windowNumber), pid: getpid(),
                rect: .init(x: f.minX, y: 1000 - f.maxY, width: f.width, height: f.height))
            value[kCGWindowLayer as String] = window.level.rawValue
            return value
        }
        func key() -> Event { event(target: Int64(getpid())) }
        rows = [row(root)]; refreshInputObservation()
        Checks.check(transit(key()), "현재 요청의 정확한 소유 인증 창만 키 입력 수용")
        let queued = key(); _ = filter(.keyDown, event: queued)
        NSApp.keyWindow = Panel()
        Checks.check(filterAnnotated(.keyDown, event: queued) == nil,
            "같은 PID의 다른 창으로 포커스가 바뀌면 250ms 이내에도 키 입력 거절")
        NSApp.keyWindow = root
        LocalAuthenticationPresentation.requestID = UUID(); refreshInputObservation()
        Checks.check(!transit(key()), "이전 요청의 소유 인증 창은 허용하지 않음")
        LocalAuthenticationPresentation.requestID = requestID
        for failure in ["level", "opacity", "sharing", "display", "frame", "visible", "key"] {
            root.level.rawValue = failure == "level" ? 1001 : 1002
            root.isOpaque = failure != "opacity"; root.sharingType = failure == "sharing" ? .readWrite : .none
            root.screen = failure == "display" ? Screen() : NSScreen.screens.first
            root.frame = failure == "frame" ? .init(x: 2000,y: 0,width: 480,height: 240) : .init(x: 40,y: 300,width: 480,height: 240)
            root.isVisible = failure != "visible"; root.isKeyWindow = failure != "key"
            rows = [row(root)]; refreshInputObservation()
            Checks.check(!transit(key()), "소유 인증 창의 잘못된 \(failure)은 거절")
        }
        root.isKeyWindow = true; rows = [row(root)]; refreshInputObservation()
        state = .invalid("secure input during owner authentication")
        refreshInputObservation()
        Checks.check(transit(key()), "일반 보호 상태 오류가 있어도 검증된 인증 창 입력만 수용")
        state = .protected
        let sheet = Panel(); sheet.windowNumber = 92; sheet.level.rawValue = 1003
        sheet.sheetParent = root; root.attachedSheet = sheet; root.isKeyWindow = false
        sheet.isKeyWindow = true; NSApp.keyWindow = sheet
        rows = [row(sheet),row(root)]; refreshInputObservation()
        Checks.check(transit(key()) && localAuthenticationInputPolicy.observation?.target.window == 92,
            "현재 소유 창의 실제 key sheet에만 인증 입력 결속")
        sheet.sheetParent = Panel(); refreshInputObservation()
        Checks.check(!transit(key()), "공식 부모 관계가 없는 같은 PID sheet는 거절")
        sheet.sheetParent = root; refreshInputObservation()
        let closing = key(); _ = filter(.keyDown, event: closing)
        LocalAuthenticationPresentation.root = nil; refreshInputObservation()
        Checks.check(filterAnnotated(.keyDown,event:closing) == nil,
            "소유 인증 창 등록 해제는 대기 중인 입력도 즉시 철회")
        fresh()
    }

    func run() async {
        ownedContainerChecks()
        await additionalReviewChecks()
        await selfReturnChecks()
        authenticationInterleavingChecks()
        authenticatedReleaseChecks()
        fresh()
        Checks.check(CGEventField.eventTargetUnixProcessID.rawValue == 40 && CGEventTapLocation.cgAnnotatedSessionEventTap.rawValue == 2,
                     "공개 Mac SDK targetPID 필드와 annotated tap 확인")
        Checks.check(localAuthenticationInputPolicy.observation != nil, "생산 observer는 검증한 공식 ownerAuth 창의 proof 생성")
        Checks.check((1...Int64(Int32.max)).contains(localAuthenticationInputPolicy.observation!.handoffTag),
                     "전달표식은 원격 표식과 분리한 현재 요청의 세대 범위")
        Checks.check(isObservedAuthenticationWindow(window()) && !isObservedAuthenticationWindow(window(71)),
                     "가림 예외는 현재 proof의 정확한 auth window만 인정")
        for kind in [CGEventType.keyDown, .keyUp, .leftMouseDown, .leftMouseUp] {
            let e = event(kind)
            Checks.check(transit(e) && e.getIntegerValueField(.eventSourceUserData) == 0,
                         "공식 ownerAuth 물리 입력만 두 단계 허용하고 전달표식 제거 \(kind.rawValue)")
        }
        let observed = observationCalls, signatures = Self.signatureCalls, reads = Self.identityReads
        _ = transit(event())
        Checks.check(observed == observationCalls && signatures == Self.signatureCalls && Self.identityReads > reads,
                     "callback은 WindowServer·Security·AX 관측 없이 process identity 경계만 재조회")
        for target in [Int64(0), 100, 701, 999] {
            let e = event(target: target)
            Checks.check(filter(.keyDown, event: e) != nil && filterAnnotated(.keyDown, event: e) == nil,
                         "main 이후 OS targetPID가 정상앱·TCC·foreign·unknown이면 최종 거절 \(target)")
        }
        for field in [CGEventField.mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent] {
            let e = event(.leftMouseDown); e.setIntegerValueField(field, value: 71)
            Checks.check(!transit(e), "다른 window ID로 향하는 왼쪽 클릭 거절 \(field.rawValue)")
        }
        let outside = event(.leftMouseDown); outside.location = CGPoint(x: 500, y: 500)
        Checks.check(!transit(outside), "auth bounds 밖 클릭 거절")
        for flags in [CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn] {
            let e = event(); e.flags = flags
            Checks.check(!transit(e), "전역·창 전환 modifier 거절 \(flags.rawValue)")
        }
        for key: Int64 in [54, 55, 58, 59, 63, 96, 103, 122] {
            let e = event(); e.setIntegerValueField(.keyboardEventKeycode, value: key)
            Checks.check(!transit(e), "modifier·function key 거절 \(key)")
        }
        for kind in [CGEventType.rightMouseDown, .mouseMoved, .leftMouseDragged, .scrollWheel,
                     .tabletPointer, CGEventType(rawValue: 14)!] {
            Checks.check(!transit(event(kind)), "media·타 입력 종류 거절 \(kind.rawValue)")
        }
        let shifted = event(); shifted.flags = [.maskShift]
        Checks.check(transit(shifted), "암호의 Shift 문자 타이핑 허용")
        for field in [CGEventField.eventSourceUnixProcessID, .eventSourceStateID, .eventSourceUserData] {
            let e = event(); e.setIntegerValueField(field, value: 999)
            Checks.check(!transit(e), "unknown·injected credential 입력 거절 \(field.rawValue)")
        }
        let remote = event(); remote.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        remote.setIntegerValueField(.eventSourceUserData, value: Self.remoteEventTag)
        Checks.check(!transit(remote), "인증 중 원격 tagged credential 차단")
        let unmarked = event()
        Checks.check(filterAnnotated(.keyDown, event: unmarked) == nil, "session 전달표식 없는 annotated physical 거절")
        let inflight = event(); _ = filter(.keyDown, event: inflight); challengeID = nil
        Checks.check(filterAnnotated(.keyDown, event: inflight) == nil, "취소 직전 in-flight physical이 일반 앱으로 누출되지 않음")
        refreshInputObservation()
        remote.setIntegerValueField(.eventTargetUnixProcessID, value: 100)
        Checks.check(filter(.keyDown, event: remote) != nil && filterAnnotated(.keyDown, event: remote) != nil,
                     "인증 밖 기존 정상 앱 원격 입력 유지")
        let remoteCredential = remote.copy()!
        remoteCredential.setIntegerValueField(.eventTargetUnixProcessID, value: 700)
        Checks.check(filterAnnotated(.keyDown, event: remoteCredential) == nil,
                     "challenge 종료 뒤에도 원격 tagged credential은 OS auth PID로 전달하지 않음")
        fresh(); let old = event(); _ = filter(.keyDown, event: old)
        let replacement = UUID(); localAuthenticationWillBegin(replacement); challengeID = replacement; refreshInputObservation()
        Checks.check(filterAnnotated(.keyDown, event: old) == nil && transit(event()), "요청 교체 뒤 옛 전달표식 거절·새 물리 입력 허용")
        fresh(); Self.identities[700] = .init(pid: 700, startSeconds: 101, startMicroseconds: 10)
        Checks.check(!transit(event()), "cached PID 재사용은 생성시각 syscall 경계에서 즉시 거절")
        Self.identities[700] = nil
        Checks.check(!transit(event()), "process exit 또는 identity 조회 실패 거절")
        fresh(); annotatedTapVerified = false
        Checks.check(!transit(event()), "수신 annotated tap 검증 소실이면 main에서 거절")
        fresh(); annotatedTap = InertTap(valid: false)
        Checks.check(!transit(event()), "annotated Mach port 무효화 즉시 거절")
        fresh(); _ = filterAnnotated(.tapDisabledByTimeout, event: event())
        Checks.check(!inputEnvironmentVerified && !annotatedTapVerified && !transit(event()), "tap 중단은 callback에서 먼저 허용을 폐기")
        await Task.yield()
        fresh()
        let expired = localAuthenticationInputPolicy.current(challengeID: challengeID, now: .now)!
        Checks.check(localAuthenticationInputPolicy.current(challengeID: challengeID,
            now: expired.expires) == nil, "관측 기한 경계는 즉시 거절")
        challengeID = nil
        Checks.check(!transit(event()), "challenge 기한·membership 취소 getter nil이면 즉시 거절")
        let mutations: [(String, (Platform) -> Void)] = [
            ("UserNotificationCenter", { _ in Self.apps[700]!.bundleIdentifier = "com.apple.UserNotificationCenter" }),
            ("다른 Apple 앱", { _ in Self.apps[700]!.bundleIdentifier = "com.apple.finder" }),
            ("서명 위조", { _ in Self.apps[700]!.appleSigned = false }),
            ("설치 경로 위조", { _ in Self.apps[700]!.executableURL = URL(fileURLWithPath: "/tmp/coreautha") }),
            ("실행 경로 불일치", { _ in Self.paths[700] = "/tmp/coreautha" }),
            ("종료된 app", { _ in Self.apps[700]!.isTerminated = true }),
            ("launch 미확인", { _ in Self.apps[700]!.launchDate = nil }),
            ("가려진 창", { $0.rows.insert($0.window(80, pid: 800), at: 0) }),
            ("동시 auth 창", { $0.rows.append($0.window(71)) }),
            ("투명 창", { $0.rows = [$0.window(alpha: 0.5)] }),
            ("창 소실", { $0.rows = [] }),
        ]
        for (label, mutate) in mutations {
            fresh(); mutate(self); refreshInputObservation()
            Checks.check(localAuthenticationInputPolicy.observation == nil && !transit(event()), "생산 관측의 \(label) 거절")
        }
        fresh(); let previous = localAuthenticationInputPolicy.observation!.target.window
        refreshInputObservation()
        Checks.check(localAuthenticationInputPolicy.observation?.target.window == previous && transit(event()),
                     "OS가 재사용한 auth window ID도 현재 owner 검증 뒤 허용")
        fresh(); challengeID = UUID(); refreshInputObservation()
        Checks.check(!transit(event()), "will-begin과 실제 challenge 불일치 거절")
        fresh(); challengeID = nil
        var permissionApp = App(); permissionApp.bundleIdentifier = "com.apple.UserNotificationCenter"
        Self.NSWorkspace.shared.frontmostApplication = permissionApp
        refreshInputObservation()
        let permissionEvent = event(target: 100)
        permissionEvent.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        permissionEvent.setIntegerValueField(.eventSourceUserData, value: Self.remoteEventTag)
        Checks.check(filterAnnotated(.keyDown, event: permissionEvent) == nil,
                     "TCC가 regular activation을 표시해도 정상 원격 대상으로 관측하지 않음")
        fresh(); state = .invalid("로컬 복귀 작업 중"); inputEnvironmentVerified = false
        refreshInputObservation()
        Checks.check(transit(event()), "오디오 복귀 busy 상태에서도 이미 설치된 두 필터·커튼 재검증 뒤 OS 인증 입력 유지")
        fresh(); state = .invalid("커튼 소실"); surfacesSafe = false
        refreshInputObservation()
        Checks.check(!transit(event()), "커튼 미검증 상태는 실제 challenge가 있어도 입력 거절")
    }

    private func selfReturnChecks() async {
        fresh(); secureInput = true
        refreshInputObservation()
        Checks.check(localAuthenticationInputPolicy.observation != nil && transit(event()),
                     "일치하는 자체 challenge의 secure input은 인증 proof를 폐기하지 않음")
        fresh(); secureInput = true
        Checks.check(!verify() && localAuthenticationInputPolicy.observation != nil && transit(event()),
                     "verify는 일반 보호 승인 없이 자체 secure input 인증 유지")
        fresh(); secureInput = true
        Checks.check(!engage() && localAuthenticationInputPolicy.observation != nil && transit(event()),
                     "protected engage는 일반 보호 승인 없이 자체 secure input 인증 유지")
        fresh(); secureInput = true; state = .invalid("보호 재검증")
        Checks.check(!engage() && localAuthenticationInputPolicy.observation != nil && transit(event()),
                     "복구 engage는 일반 보호 승인 없이 자체 secure input 인증 유지")
        fresh(); secureInput = true; invalidate("실제 보호 증명 소실")
        Checks.check(localAuthenticationInputPolicy.observation == nil && !transit(event()),
                     "자체 secure input 중에도 실제 invalidate는 proof 폐기·입력 차단")
        fresh(); secureInput = true; tap = nil
        Checks.check(!verify() && localAuthenticationInputPolicy.observation == nil && !transit(event()),
                     "자체 secure input 중 tap 소실 verify는 proof 폐기·입력 차단")
        fresh(); secureInput = true
        refreshInputObservation()
        for field in [CGEventField.eventSourceUnixProcessID, .eventSourceUserData] {
            let remote = event(); remote.setIntegerValueField(field, value: 999)
            Checks.check(!transit(remote), "secure input 중에도 미확인·원격 출처 거절")
        }
        fresh(); secureInput = true; usable = false; refreshInputObservation()
        Checks.check(!transit(event()), "secure input 예외도 기존 권한 실패를 우회하지 않음")
        fresh(); secureInput = true; notifiedLocked = true; refreshInputObservation()
        Checks.check(!transit(event()), "secure input 예외도 잠금을 우회하지 않음")
        fresh(); secureInput = true; sessionActive = false; refreshInputObservation()
        Checks.check(!transit(event()), "secure input 예외도 다른 세션을 우회하지 않음")
        fresh(); secureInput = true; sleeping = true; refreshInputObservation()
        Checks.check(!transit(event()), "secure input 예외도 절전을 우회하지 않음")
        fresh(); secureInput = true; challengeID = UUID(); refreshInputObservation()
        Checks.check(!transit(event()), "준비 ID가 불일치하면 secure input 거절")
        fresh(); secureInput = true; challengeID = nil; refreshInputObservation()
        Checks.check(!inputEnvironmentVerified && !isProtected, "인증 밖 secure input은 기존대로 보호 무효")

        var requests = 0
        requestLocalReturn = { requests += 1 }
        let buttonRect = CGRect(x: 20, y: 160, width: 100, height: 40)
        func recover() {
            fresh(); challengeID = nil; state = .invalid("보호 복구 중"); surfacesSafe = false
            inputEnvironmentVerified = false; sessionTapVerified = false; annotatedTapVerified = false
            tap = nil; annotatedTap = nil; curtains = [1: Curtain()]
            rows = [window(90, pid: getpid(), rect: CGRect(x: 0, y: 0, width: 1000, height: 1000))]
            refreshInputObservation()
        }
        func click(_ type: CGEventType, point: CGPoint = CGPoint(x: 50, y: 180)) {
            let e = event(type); e.location = point
            Checks.check(filter(type, event: e) == nil, "자기 버튼 입력은 일반 앱으로 통과시키지 않음")
        }
        recover()
        Checks.check(observedReturnButton(at: CGPoint(x: 50, y: 180)) == 90,
                     "tap0·전체 cover 미증명인 복구 중에도 자기 버튼만 관측")
        click(.leftMouseDown); click(.leftMouseUp); await Task.yield()
        Checks.check(requests == 1, "복구 중 같은 자기 버튼 down/up만 복귀 요청")
        click(.leftMouseUp); await Task.yield()
        Checks.check(requests == 1, "down 없는 up은 요청하지 않음")
        click(.leftMouseDown); click(.leftMouseUp, point: .zero); await Task.yield()
        Checks.check(requests == 1, "버튼 밖 up은 요청하지 않음")
        click(.leftMouseDown)
        observedReturnButtons = [91: buttonRect]
        click(.leftMouseUp); await Task.yield()
        Checks.check(requests == 1, "다른 자기 버튼 up은 요청하지 않음")
        recover(); click(.leftMouseDown)
        rows.insert(window(91, pid: getpid(), rect: buttonRect), at: 0); refreshInputObservation()
        click(.leftMouseUp); await Task.yield()
        Checks.check(requests == 1, "다른 자기 커튼이 가려도 최상단 증명 거절")
        for mutate: (Platform) -> Void in [
            { $0.rows.insert($0.window(80, rect: buttonRect), at: 0) },
            { $0.curtains[1]!.panel.isVisible = false },
            { $0.curtains[1]!.returnButton.isEnabled = false },
            { $0.curtains[1]!.returnButton.ancestorsHaveFullOpacity = false },
            { $0.rows = [$0.window(90, pid: 999, rect: buttonRect)] },
            { $0.rows = [$0.window(90, pid: getpid(), rect: .zero)] }
        ] {
            recover(); mutate(self); refreshInputObservation()
            Checks.check(observedReturnButton(at: CGPoint(x: 50, y: 180)) == nil,
                         "자기 버튼의 비표시·가림·소유자·영역 증명 실패 거절")
        }
        recover(); inputObservationExpires = .now
        Checks.check(observedReturnButton(at: CGPoint(x: 50, y: 180)) == nil, "기한이 지난 자기 버튼 증명 거절")
        recover()
        for field in [CGEventField.eventSourceUnixProcessID, .eventSourceStateID, .eventSourceUserData] {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = event(type); e.location = CGPoint(x: 50, y: 180)
                e.setIntegerValueField(field, value: 999); _ = filter(type, event: e)
            }
        }
        await Task.yield()
        Checks.check(requests == 1, "미확인·원격 출처는 자기 버튼 callback에도 도달하지 않음")
        Checks.check(!transit(event()), "자기 버튼 예외는 일반 물리 입력을 허용하지 않음")
        requestLocalReturn = nil
    }

    private func authenticationInterleavingChecks() {
        fresh(); challengeID = nil
        let admission = SentryAdmission(), peer = NSObject()
        var unavailable: String?
        let owner = HostSentry(admission: admission, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in true }, surfaces: .init(engage: { self.engage() }, verify: { self.verify() },
                release: { false }, reason: { nil }, restoreCurtains: { self.restoreCurtains() }),
            prepareRelease: { self.prepareRelease { true } }, localReturnUnavailableReason: { unavailable })
        let connection = ObjectIdentifier(peer)
        admission.register(connection, externalRoute: true); admission.admit(connection); admission.capture(UUID())
        Checks.check(owner.reconcile() && owner.forwardingProof() != nil && admission.allowsActions(connection),
                     "자체 인증 전 정상 보호·원격 admission 양성 대조")
        let id = UUID(); localAuthenticationWillBegin(id); challengeID = id; secureInput = true
        refreshInputObservation()
        let previousRebuilds = rebuilds, previousInstallations = installations
        Checks.check(owner.forwardingProof() == nil && localAuthenticationInputPolicy.observation != nil,
                     "secure input 중 forwardingProof tick은 일반 권한 없이 인증 proof 보존")
        Checks.check(!owner.reconcile() && !admission.allowsActions(connection) &&
                     localAuthenticationInputPolicy.observation != nil && transit(event()),
                     "실제 reconcile→verify→engage 교차 호출도 원격 차단·native 입력 유지")
        unavailable = "오디오 안전 복구 대기"
        owner.surfacesChanged()
        Checks.check(localAuthenticationInputPolicy.observation != nil && transit(event()) &&
                     !admission.allowsActions(connection),
                     "실제 reconcile→restoreCurtains 복구 분기도 인증창을 덮거나 취소하지 않음")
        Checks.check(!prepareRelease { true } && !prepareRemoteRelease(inputIdle: { true }, cleanup: { true }) &&
                     localAuthenticationInputPolicy.observation != nil,
                     "인증 중 로컬·원격 prepareRelease는 해제 거절·native proof 보존")
        let remote = event(); remote.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        remote.setIntegerValueField(.eventSourceUserData, value: Self.remoteEventTag)
        Checks.check(!transit(remote) && rebuilds == previousRebuilds && installations == previousInstallations,
                     "인증 교차 호출 중 일반 remote 차단·커튼 재구성0·tap 설치0")
        tap = nil; annotatedTap = nil
        Checks.check(!engage() && !restoreCurtains() && !verify() && !transit(event()) &&
                     rebuilds == previousRebuilds && installations == previousInstallations,
                     "tap0 자체 challenge도 일반 입력 허용·새 tap 설치·커튼 재구성 없음")
        challengeID = nil
        Checks.check(!verify() && localAuthenticationInputPolicy.observation == nil,
                     "challenge 종료 뒤 남은 secure input은 일반 보호를 승인하지 않음")
    }

    private func authenticatedReleaseChecks() {
        func recovery() {
            fresh(); challengeID = nil; state = .invalid("전체 보호 미검증")
            tap = nil; annotatedTap = nil; tapID = nil; annotatedTapID = nil; Self.tapOwner = nil
            curtains = [1: Curtain()]
            rows = [window(90, pid: getpid(), rect: CGRect(x: 0, y: 0, width: 1000, height: 1000))]
        }
        recovery()
        let admission = SentryAdmission()
        var effects: [String] = []
        let owner = HostSentry(admission: admission, initiallyLatched: true, persistenceHealthy: true,
            persist: { effects.append($0.rawValue); return true },
            surfaces: .init(engage: { false }, verify: { false }, release: { self.release() },
                reason: { nil }, released: { self.releaseVerified }),
            prepareRelease: { self.prepareAuthenticatedLocalRelease { effects.append("cleanup"); return true } },
            localReturnUnavailableReason: { "HAL 복원은 원담당 소유" })
        let priorInstalls = installations
        Checks.check(owner.completeAuthenticatedLocalReturn { effects.append("audio"); return true } &&
                     releaseVerified && !admission.isRequested && installations == priorInstalls &&
                     effects == ["cleanup", "releasing", "audio", "inactive"],
                     "인증 완료 뒤 tap0·복구 상태도 cleanup→실제 소유 커튼 정리→오디오 commit 완료")
        recovery(); tapReadbackAvailable = false
        Checks.check(!release() && curtains[1]?.panel.isVisible == true && installations == priorInstalls,
                     "tap0이어도 OS tap 목록 readback 실패면 커튼 유지·신규 tap 설치0")
        recovery(); remainingTapPID = getpid()
        Checks.check(!release() && curtains[1]?.panel.isVisible == true && installations == priorInstalls,
                     "기록 ID 없는 자기 활성 tap이 남아 있으면 커튼 제거·복귀 수용 거절")
        recovery(); remainingTapPID = getpid() + 1
        Checks.check(release() && releaseVerified,
                     "다른 소유자의 tap은 조작하지 않고 자기 tap 부재·커튼 제거만 확인")
        recovery(); challengeID = UUID()
        var cleanupCalls = 0
        Checks.check(!prepareAuthenticatedLocalRelease { cleanupCalls += 1; return true } && cleanupCalls == 0,
                     "진행 중 challenge에서는 인증 완료 전용 cleanup 호출0")
        recovery()
        Checks.check(!prepareAuthenticatedLocalRelease { false } && curtains[1]?.panel.isVisible == true,
                     "인증 완료 전용 경로도 injector cleanup 실패 시 보호 유지")
        recovery(); pointerTargets[0] = 1
        Checks.check(!prepareAuthenticatedLocalRelease { true }, "인증 뒤에도 남은 원 대상 held 입력은 임의 폐기하지 않음")
        recovery()
        Checks.check(!prepareAuthenticatedLocalRelease { self.challengeID = UUID(); return true },
                     "cleanup 사이 새 challenge가 시작되면 인증 완료 해제 거절")
        recovery(); Self.tapOwner = Platform()
        Checks.check(!prepareAuthenticatedLocalRelease { cleanupCalls += 1; return true } && cleanupCalls == 0,
                     "다른 보호 소유자가 있으면 인증 완료 cleanup도 호출하지 않음")
        recovery(); windowRemains = true
        Checks.check(!release() && !releaseVerified && installations == priorInstalls,
                     "커튼 제거 readback 실패도 복귀 성공·신규 tap 설치로 처리하지 않음")
        recovery(); secureInput = true
        Checks.check(prepareAuthenticatedLocalRelease { true } && release() && releaseVerified,
                     "인증 종료 뒤 남은 secure input은 OS 상태 변경 없이 소유 자원 제거만 검증")
    }
}

@main private struct Checks {
    static var count = 0, failures = 0
    static func check(_ value: Bool, _ label: String) {
        count += 1; if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL") \(label)")
    }
    @MainActor static func main() async {
        await Platform().run()
        print("LOCAL_AUTH_WINDOW_INPUT \(count - failures)/\(count)")
        exit(failures == 0 ? 0 : 1)
    }
}
