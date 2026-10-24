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
    private var observedReturnButtons: [CGWindowID: CGRect] = [:]
    private var observedRemoteTarget: LocalAuthenticationInputPolicy.ProcessIdentity?
    private var inputObservationExpires = ContinuousClock.now
    private var usable = true, surfacesSafe = true
    private var layout = 0
    private func currentLayout() -> Int? { 0 }
    private func curtainsAreEffective() -> Bool { surfacesSafe }
    private var rows: [[String: Any]] = []
    private var observationCalls = 0
    private func updateCurtainText() {}
    private func environmentIsUsable() -> Bool { observationCalls += 1; return usable }
    private func refreshReturnButtons(rows: [[String: Any]]) {}
    private func CGWindowListCopyWindowInfo(_ options: CGWindowListOption, _ id: CGWindowID) -> CFArray? {
        observationCalls += 1; return rows as CFArray
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
        state = .protected; usable = true; surfacesSafe = true; inputEnvironmentVerified = true
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
        fresh(); layout=1; refreshInputObservation()
        Checks.check(!transit(event()), "독립 layout 변경 양성 경로 폐기")
        layout=0; fresh(); let oldTag=localAuthenticationInputPolicy.observation!.handoffTag
        rows=[]; refreshInputObservation(); rows=[window()]; refreshInputObservation()
        Checks.check(localAuthenticationInputPolicy.observation!.handoffTag != oldTag && transit(event()), "독립 관측 복구 전달 세대 갱신")
    }

    func run() async {
        await additionalReviewChecks()
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
