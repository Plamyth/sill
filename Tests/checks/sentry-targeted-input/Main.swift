import AppKit
import CoreGraphics
import StreamProtocol

struct InertTap { var valid = true; var enabled = true }
private func CFMachPortIsValid(_ tap: InertTap) -> Bool { tap.valid }
private extension CGEvent { static func tapIsEnabled(tap: InertTap) -> Bool { tap.enabled } }

@MainActor final class TargetPlatform: NSObject {
    static let remoteEventTag = HostSentryPlatform.remoteEventTag
    enum State { case idle, engaging, protected, releasing, invalid(String) }
    var state = State.protected
    var tap: InertTap? = InertTap()
    var changingLifecycle = false
    static var tapOwner: TargetPlatform?
    struct Curtain { let panel: NSPanel }
    var curtains: [Int: Curtain] = [:]
    var layout: [Int: Int] = [:]
    var localReturnDown: CGWindowID?
    var tapID: UInt32?
    var timer: Timer?
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var lockObservers: [NSObjectProtocol] = []
    func updateCurtainText() {}
    func destroyTap() { tap = nil }
    func eventTapList() -> [CGEventTapInformation]? { [] }
    func recoverFailedRelease(_ reason: String) -> Bool { false }
    var changed: (() -> Void)?
    var currentLocalAuthenticationChallenge: () -> UUID? = { nil }
    var usable = true, effective = true, layoutValid = true
    var onVerify: (() -> Void)?
    var rows: [[String: Any]]? = []
    var posted: [(pid_t, CGEvent)] = []
    struct App {
        var isTerminated = false
        var activationPolicy = NSApplication.ActivationPolicy.regular
        var launchDate: Date? = Date(timeIntervalSince1970: 100)
        var bundleIdentifier: String? = "org.example.editor"
        var processIdentifier: pid_t
    }
    var apps: [pid_t: App] = [100: App(processIdentifier: 100), 200: App(processIdentifier: 200)]
    var foreground: App? = App(processIdentifier: 100)
    var curtainWindowIDs: [CGWindowID] = [90]
    func verify() -> Bool { onVerify?(); return usable && effective && layoutValid }
    func CGWindowListCopyWindowInfo(_ options: CGWindowListOption, _ id: CGWindowID) -> CFArray? { rows.map { $0 as CFArray } }
    static func isSystemCursorWindow(_ row: [String: Any], verifiedOwners: inout [pid_t: Bool]) -> Bool {
        (row["verifiedCursor"] as? Bool) == true
    }
    __PRODUCTION_EGRESS__
}

final class Peer {}
@MainActor final class Fixture {
    let a = Peer(), b = Peer()
    let platform = TargetPlatform(), injector = InputInjector()
    var admissionCurrent: () -> Bool = { true }
    var current = true
    var epochID = UUID()
    var source = StreamSource.window(10)
    let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
    var owner: ObjectIdentifier { ObjectIdentifier(a) }
    var other: ObjectIdentifier { ObjectIdentifier(b) }
    init() {
        platform.rows = [row(90, pid: getpid(), layer: 1001), row(10)]
        injector.isolatesPhysicalInput = true
        injector.protectedPointerEgress = { [weak platform] event, scope in platform?.protectedPointerEgress(event, scope: scope) == true }
    }
    func row(_ id: UInt32, pid: pid_t = 100, layer: Int = 0, bounds: CGRect? = nil) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: layer, kCGWindowAlpha as String: 1,
         kCGWindowBounds as String: (bounds ?? rect).dictionaryRepresentation]
    }
    func scope(_ peer: ObjectIdentifier? = nil) -> InputInjector.ProtectedPointerScope {
        let id = epochID, source = source
        return .init(device: peer ?? owner, epoch: .init(id: id, generation: "generation-1", source: source,
            geometry: .init(x: 0, y: 0, width: 400, height: 300), width: 400, height: 300),
            isCurrent: { [weak self] in self?.admissionCurrent() == true && self?.current == true && self?.epochID == id && self?.source == source })
    }
    func send(_ action: PointerAction, peer: ObjectIdentifier? = nil, x: Double = 0.5) {
        injector.apply(.pointer(action, x: x, y: 0.5), in: rect, from: peer ?? owner, protectedScope: scope(peer))
    }
    func scroll(_ phase: ScrollPhase? = nil, peer: ObjectIdentifier? = nil) {
        let event: InputEvent = phase.map { .scrollGesture($0, x: 0.5, y: 0.5) } ?? .scroll(x: 0.5, y: 0.5, dx: 0, dy: 0.01)
        injector.apply(event, in: rect, from: peer ?? owner, protectedScope: scope(peer))
    }
    func debt(_ peer: ObjectIdentifier? = nil) -> Bool {
        injector.isUpOfSomethingDown(.pointer(.leftUp, x: 0, y: 0), from: peer ?? owner)
    }
}

@main @MainActor struct Checks {
    static var total = 0, failed = 0
    static func check(_ value: Bool, _ label: String) {
        total += 1
        if !value { failed += 1 }
        print("\(value ? "PASS" : "FAIL") \(label)")
    }
    static func main() async {
        await coordinatorChecks()
        followupChecks()
        let f = Fixture()
        f.send(.leftDown)
        check(f.platform.posted.count == 1 && f.platform.posted[0].0 == 100 && f.debt(), "admitted down은 현재 창 PID에 한 번 전송 시도하고 원 peer 부채 보유")
        let event = f.platform.posted[0].1
        check(event.location == CGPoint(x: 200, y: 150) && event.flags.rawValue == 0 &&
              event.getIntegerValueField(.mouseEventNumber) == 0 && event.getIntegerValueField(.mouseEventClickState) == 1,
              "실제 이벤트 좌표·flags·eventNumber·clickCount 보존")
        f.send(.move, peer: f.other, x: 0.8); f.send(.leftDown, peer: f.other); f.send(.leftUp, peer: f.other)
        check(f.platform.posted.count == 1 && f.debt() && !f.debt(f.other), "다른 peer의 move/down/up는 버튼·목적지·부채를 바꾸지 않음")
        f.injector.releaseInput(of: f.other)
        check(f.platform.posted.count == 1 && f.debt(), "다른 peer의 disconnect는 원 peer 부채 보존")
        f.send(.move, x: 0.6); f.send(.leftUp, x: 0.6)
        check(f.platform.posted.map { $0.1.type } == [.leftMouseDown, .leftMouseDragged, .leftMouseUp] && !f.debt(), "동일 peer의 down/drag/up만 같은 창으로 전송 시도")
        f.send(.leftUp)
        check(f.platform.posted.count == 3, "중복 up은 새 전송 없음")
        check(f.injector.globalPosts.isEmpty, "보호된 버튼은 global fallback 없음")
        f.send(.move)
        check(f.injector.globalPosts.last?.type == .mouseMoved, "평소 move만 기존 tagged global 경로 사용")

        let split = Fixture(); split.send(.leftDown); split.send(.rightDown, peer: split.other)
        split.send(.move, peer: split.other, x: 0.6)
        check(split.platform.posted.last?.1.type == .rightMouseDragged && split.debt(), "서로 다른 peer의 좌·우 버튼 원 소유자별 drag 선택")
        split.injector.releaseInput(of: split.owner)
        check(!split.debt() && split.injector.isUpOfSomethingDown(.pointer(.rightUp, x: 0, y: 0), from: split.other),
              "A cleanup은 B의 오른쪽 버튼 부채 보존")
        split.injector.releaseInput(of: split.other)
        check(split.platform.posted.map { $0.1.type } == [.leftMouseDown, .rightMouseDown, .rightMouseDragged, .leftMouseUp, .rightMouseUp],
              "서로 다른 peer의 좌·우 target 수명주기 독립 유지")
        let separate = Fixture(); separate.send(.leftDown)
        separate.platform.rows = [separate.row(11, pid: 200), separate.row(10)]
        separate.platform.foreground = separate.platform.apps[200]
        let otherEpoch = VideoEpoch(generation: "peer-b", source: .window(11),
            geometry: .init(x: 0, y: 0, width: 400, height: 300), width: 400, height: 300)
        let otherScope = InputInjector.ProtectedPointerScope(device: separate.other, epoch: otherEpoch, isCurrent: { true })
        for action in [PointerAction.rightDown, .move] {
            separate.injector.apply(.pointer(action, x: 0.5, y: 0.5), in: separate.rect, from: separate.other, protectedScope: otherScope)
        }
        separate.injector.releaseInput(of: separate.owner); separate.injector.releaseInput(of: separate.other)
        check(separate.platform.posted.map { $0.0 } == [100, 200, 200, 100, 200],
              "서로 다른 peer 좌·우 버튼은 각각의 최초 PID/window에 결박하고 독립 cleanup")
        let normal = Fixture(); normal.injector.isolatesPhysicalInput = false
        normal.send(.leftDown); normal.send(.leftUp)
        check(normal.platform.posted.isEmpty && normal.injector.globalPosts.map { $0.type } == [.leftMouseDown, .leftMouseUp] && !normal.debt(),
              "보호 비요청 상태는 scope 인자 유무와 관계없이 기존 global down/up 유지")
        let rejected = Fixture(); rejected.platform.tap = InertTap(valid: false)
        rejected.send(.leftDown)
        check(!rejected.debt() && rejected.platform.posted.isEmpty, "거절된 down은 소유자·up 부채를 만들지 않음")
        rejected.send(.leftUp)
        check(rejected.platform.posted.isEmpty && rejected.injector.globalPosts.isEmpty, "거절된 down의 up도 전송 없음")
        let absent = Fixture(); absent.injector.protectedPointerEgress = nil; absent.send(.leftDown)
        check(!absent.debt() && absent.injector.globalPosts.isEmpty, "nil egress에서 global fallback·거짓 부채 없음")

        let mutations: [(String, (Fixture) -> Void)] = [
            ("tap 외부 무효화", { $0.platform.tap = InertTap(valid: false) }),
            ("tap 외부 비활성", { $0.platform.tap = InertTap(enabled: false) }),
            ("인증 진행", { $0.platform.currentLocalAuthenticationChallenge = { UUID() } }),
            ("환경 실패", { $0.platform.usable = false }),
            ("커튼 실패", { $0.platform.effective = false }),
            ("배치 변경", { $0.platform.layoutValid = false }),
            ("동일 PID 다른 창", { $0.platform.rows = [$0.row(11)] }),
            ("창 소멸", { $0.platform.rows = [] }),
            ("다른 앱", { $0.platform.rows = [$0.row(10, pid: 200)]; $0.platform.foreground = $0.platform.apps[200] }),
            ("PID 재사용", { $0.platform.apps[100]?.launchDate = Date(timeIntervalSince1970: 200); $0.platform.foreground = $0.platform.apps[100] }),
            ("창 목록 미확인", { $0.platform.rows = nil }),
            ("OS 인증 앱", { $0.platform.apps[100]?.bundleIdentifier = "com.apple.SecurityAgent" }),
            ("Dock", { $0.platform.apps[100]?.bundleIdentifier = "com.apple.dock" }),
            ("자기 앱", { $0.platform.rows = [$0.row(10, pid: getpid())] }),
        ]
        for (label, mutate) in mutations {
            let m = Fixture(); m.send(.leftDown); mutate(m); m.send(.leftUp)
            check(m.platform.posted.count == 1 && m.debt() && m.injector.globalPosts.isEmpty,
                  "\(label) 시 up 부채·원 대상 보존, 재지정·global 전송 없음")
            m.injector.releaseInput(of: m.owner)
            check(m.platform.posted.count == 1 && m.debt(), "\(label) 뒤 cleanup도 같은 검증 경계 유지")
        }
        for mutation in 0..<3 {
            let cleanup = Fixture(); cleanup.send(.leftDown)
            if mutation == 0 { cleanup.current = false }
            if mutation == 1 { cleanup.epochID = UUID() }
            if mutation == 2 { cleanup.source = .window(11) }
            cleanup.injector.releaseInput(of: cleanup.owner)
            check(cleanup.platform.posted.count == 2 && cleanup.platform.posted.last?.0 == 100 && !cleanup.debt(),
                  "취소·연결종료·source/epoch 변경 뒤 known-held cleanup은 원 앱에만 시도 \(mutation)")
            cleanup.platform.rows = [cleanup.row(11, pid: 200)]; cleanup.current = false; cleanup.send(.leftDown)
            check(cleanup.platform.posted.count == 2 && !cleanup.debt(), "cleanup 허용이 새 target down 권한으로 확대되지 않음 \(mutation)")
        }
        let captured = Fixture(); captured.send(.leftDown)
        captured.platform.rows = [captured.row(11, pid: 200), captured.row(10, bounds: CGRect(x: 50, y: 0, width: 400, height: 300))]
        captured.platform.foreground = captured.platform.apps[200]
        captured.send(.move, x: 1.5); captured.send(.leftUp, x: 1.5)
        check(captured.platform.posted.count == 3 && captured.platform.posted.allSatisfy { $0.0 == 100 } && !captured.debt(),
              "창 이동·창 밖 drag/up·다른 전경에서도 down의 같은 창 capture 보존")
        for layer in [101, Int(CGWindowLevelForKey(.cursorWindow)), Int(CGWindowLevelForKey(.desktopWindow))] {
            let covered = Fixture(); covered.platform.rows = [covered.row(11, pid: 300, layer: layer), covered.row(10)]; covered.send(.leftDown)
            check(covered.platform.posted.isEmpty && !covered.debt(), "새 down은 메뉴/Dock/미확인 WindowServer/desktop layer를 건너뛰지 않음 \(layer)")
        }
        let cancelled = Fixture(); cancelled.platform.onVerify = { cancelled.current = false }; cancelled.send(.leftDown)
        check(cancelled.platform.posted.isEmpty && !cancelled.debt(), "verify 이후 취소도 post 직전 재검증하여 down 거절")
        let retry = Fixture(); retry.send(.leftDown); retry.platform.tap = InertTap(enabled: false); retry.send(.leftUp)
        retry.platform.tap = InertTap(); retry.send(.leftUp)
        check(retry.platform.posted.count == 2 && !retry.debt(), "복구 뒤 동일 원 대상에만 up 전송 시도 가능")
        let durable = Fixture(); durable.send(.leftDown); durable.current = false; durable.injector.isolatesPhysicalInput = false
        durable.injector.releaseAll()
        check(!durable.debt() && durable.platform.posted.count == 2 && durable.injector.globalPosts.isEmpty, "래치 전환 뒤 기존 보호 부채는 원 targeted cleanup만 사용")
        let desktop = Fixture(); desktop.source = .desktop; desktop.send(.leftDown)
        check(desktop.platform.posted.count == 1, "desktop은 현재 전경 일반 앱창에만 전송 시도")
        let background = Fixture(); background.source = .desktop; background.platform.foreground = background.platform.apps[200]; background.send(.leftDown)
        check(background.platform.posted.isEmpty && !background.debt(), "desktop의 background click-to-focus를 추측하지 않고 거절")
        let forged = Fixture(); let fake = CGEvent(source: CGEventSource(stateID: .privateState))!; fake.type = .leftMouseDown; fake.location = CGPoint(x: 200, y: 150)
        fake.setIntegerValueField(.eventSourceUserData, value: HostSentryPlatform.remoteEventTag)
        fake.setIntegerValueField(.eventSourceUnixProcessID, value: 1234)
        check(!forged.platform.protectedPointerEgress(fake, scope: forged.scope()), "위조 태그의 다른 PID는 targeted 경로에서도 거절")
        fake.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        check(!forged.platform.protectedPointerEgress(fake, scope: nil), "자체 PID·태그도 원 scope 없으면 거절")

        let scroll = Fixture(); scroll.scroll(.began); scroll.scroll()
        check(scroll.platform.posted.count == 1 && scroll.injector.protectedScrollPending, "scroll began의 원 peer·창·부채 보유")
        scroll.scroll(peer: scroll.other); scroll.scroll(.ended, peer: scroll.other)
        check(scroll.platform.posted.count == 1 && scroll.injector.protectedScrollPending, "다른 peer scroll/end는 기존 gesture를 바꾸지 않음")
        scroll.platform.rows = [scroll.row(11)]
        scroll.injector.testWatchdog()
        check(scroll.platform.posted.count == 1 && scroll.injector.protectedScrollPending && scroll.injector.globalPosts.isEmpty,
              "watchdog는 다른 창으로 end를 보내지 않고 부채 유지")
        scroll.platform.rows = [scroll.row(10)]; scroll.injector.testWatchdog()
        check(scroll.platform.posted.count == 2 && !scroll.injector.protectedScrollPending &&
              scroll.platform.posted.last?.1.getIntegerValueField(.scrollWheelEventScrollPhase) == 4,
              "watchdog는 원 scope·같은 창 검증 후에만 end 전송 시도")
        let latchedScroll = Fixture(); latchedScroll.scroll(.began); latchedScroll.scroll()
        latchedScroll.injector.isolatesPhysicalInput = false; latchedScroll.platform.tap = nil
        latchedScroll.injector.testWatchdog(); latchedScroll.scroll()
        check(latchedScroll.platform.posted.count == 1 && latchedScroll.injector.protectedScrollPending && latchedScroll.injector.globalPosts.isEmpty,
              "래치 전환·tap 실패 뒤 scroll debt와 scope 유지, 새 global fallback 없음")
        latchedScroll.platform.tap = InertTap(); latchedScroll.injector.releaseInput(of: latchedScroll.owner)
        check(latchedScroll.platform.posted.count == 2 && !latchedScroll.injector.protectedScrollPending,
              "래치 전환 뒤에도 원 scroll target에만 cleanup 종료 시도")
        let lostScroll = Fixture(); lostScroll.platform.tap = nil; lostScroll.scroll(.began); lostScroll.scroll()
        check(lostScroll.platform.posted.isEmpty && !lostScroll.injector.protectedScrollPending, "거절된 scroll began은 전송 부채를 만들지 않음")
        let momentum = Fixture(); momentum.scroll(.began); momentum.scroll(); momentum.scroll(.ended)
        momentum.scroll(.momentumBegan); momentum.scroll(); momentum.current = false; momentum.injector.testWatchdog()
        check(momentum.platform.posted.count == 4 && !momentum.injector.protectedScrollPending, "취소된 momentum watchdog도 동일 원 앱에만 cleanup 종료 시도")
        check(NSApp == nil || NSApp.windows.allSatisfy { !$0.isVisible }, "검사에서 Host·표시 창·실제 post 실행 없음")
        print("SENTRY_TARGETED_INPUT \(total-failed)/\(total)")
        exit(failed == 0 ? 0 : 1)
    }
}
