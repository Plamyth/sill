import Foundation

final class NSRunningApplication: NSObject {
    let bundleIdentifier: String?
    let processIdentifier: Int32
    init(_ id: String?, _ pid: Int32) { bundleIdentifier = id; processIdentifier = pid }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    static let didLaunchApplicationNotification = Notification.Name("launch")
    static let didTerminateApplicationNotification = Notification.Name("terminate")
    static let applicationUserInfoKey = "application"
    let notificationCenter = NotificationCenter()
    var runningApplications: [NSRunningApplication] = []
}
struct SCDisplay {}
struct SCRunningApplication { let bundleIdentifier: String; let processID: Int32 }
struct SCWindow { let owningApplication: SCRunningApplication? }
struct SCShareableContent { let applications: [SCRunningApplication]; var windows: [SCWindow] = [] }
struct SCContentFilter {
    let pids: Set<Int32>
    init(display: SCDisplay, excludingApplications: [SCRunningApplication], exceptingWindows: [SCWindow]) {
        pids = Set(excludingApplications.map(\.processID))
    }
}
final class SCStream {
    var filters: [SCContentFilter] = []
    var held = false
    var callbacks: [(Error?) -> Void] = []
    func updateContentFilter(_ filter: SCContentFilter, completionHandler: @escaping (Error?) -> Void) {
        filters.append(filter)
        if held { callbacks.append(completionHandler) } else { completionHandler(nil) }
    }
    func complete(_ error: Error? = nil) { callbacks.removeFirst()(error) }
}
@MainActor final class WindowCatalog {
    static let ownPID: Int32 = 99
    static var content: SCShareableContent?
    static func shareableContent(excludingDesktopWindows: Bool, onScreenWindowsOnly: Bool, timeout: Double) async -> SCShareableContent? {
        content
    }
    // PREDICATE
}

@MainActor var checks = 0
@MainActor func check(_ value: Bool, _ label: String) {
    guard value else { print("FAIL \(label)"); exit(1) }
    checks += 1
}
@MainActor func wait(_ ready: () -> Bool) async {
    let limit = Date().addingTimeInterval(5)
    while !ready(), Date() < limit { await Task.yield() }
    check(ready(), "async operation settled within bounded check")
}
@MainActor func admitted(_ gate: DesktopFrameAdmission) -> Bool {
    var delivered = false
    gate.deliver { delivered = true }
    return delivered
}
@MainActor func notify(_ app: NSRunningApplication, launched: Bool = true) {
    NSWorkspace.shared.notificationCenter.post(name: launched ? NSWorkspace.didLaunchApplicationNotification : NSWorkspace.didTerminateApplicationNotification,
        object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: app])
}
@MainActor func runChecks() async throws {
    let privateID = "com.openai.sky.CUAService"
    let helper = SCRunningApplication(bundleIdentifier: privateID, processID: 500)
    let ordinary = SCRunningApplication(bundleIdentifier: "com.openai.codex", processID: 600)
    let lookalike = SCRunningApplication(bundleIdentifier: privateID + ".user", processID: 601)
    NSWorkspace.shared.runningApplications = [NSRunningApplication(privateID, 500)]
    WindowCatalog.content = SCShareableContent(applications: [helper, ordinary, lookalike], windows: [SCWindow(owningApplication: helper)])
    var drains = 0
    let monitor = DesktopCapturePrivacy(display: SCDisplay(), drain: { drains += 1; await Task.yield() })
    check(!admitted(monitor.admission), "desktop frames start closed")
    let initial = try await monitor.initialFilter()
    check(initial.0.pids == [500], "CUA excluded even when own app absent; normal Codex and lookalike retained; duplicate owner deduplicated")
    check(!admitted(monitor.admission), "inventory alone never opens delivery")
    let stream = SCStream()
    monitor.attach(stream, revision: initial.1)
    check(admitted(monitor.admission), "same revision opens after native stream startup")
    notify(NSRunningApplication("com.openai.codex", 600))
    check(admitted(monitor.admission) && stream.filters.isEmpty, "ordinary user app launch does not interrupt desktop")

    stream.held = true
    let next = SCRunningApplication(bundleIdentifier: privateID, processID: 700)
    WindowCatalog.content = SCShareableContent(applications: [helper, next, ordinary])
    notify(NSRunningApplication(privateID, 700))
    check(!admitted(monitor.admission), "observed new CUA PID closes delivery synchronously")
    await wait { stream.callbacks.count == 1 }
    check(stream.filters.last?.pids == [500,700], "replacement filter contains all known private processes")
    check(!admitted(monitor.admission) && drains == 0, "pending native update cannot deliver frames")
    let newest = SCRunningApplication(bundleIdentifier: privateID, processID: 701)
    WindowCatalog.content = SCShareableContent(applications: [helper,next,newest,ordinary])
    notify(NSRunningApplication(privateID, 701))
    stream.complete()
    await wait { stream.callbacks.count == 1 && stream.filters.count == 2 }
    check(!admitted(monitor.admission), "obsolete update completion cannot reopen newer revision")
    check(stream.filters.last?.pids == [500,700,701], "newest observed PID is included before reopening")
    stream.complete()
    await wait { admitted(monitor.admission) }
    check(drains == 2, "sample queue drain required after each successful native update")

    WindowCatalog.content = SCShareableContent(applications: [helper,next])
    notify(NSRunningApplication(privateID, 701), launched: false)
    await wait { stream.callbacks.count == 1 }
    check(!admitted(monitor.admission) && stream.filters.last?.pids == [500,700], "private termination closes delivery and refreshes active identity set")
    monitor.stop()
    stream.complete()
    for _ in 0..<20 { await Task.yield() }
    check(!admitted(monitor.admission), "completion after stop never reopens retired monitor")
    let count = stream.filters.count
    notify(NSRunningApplication(privateID, 702))
    for _ in 0..<20 { await Task.yield() }
    check(stream.filters.count == count, "stopped observer no longer schedules updates")

    NSWorkspace.shared.runningApplications = []
    WindowCatalog.content = SCShareableContent(applications: [SCRunningApplication(bundleIdentifier: "host", processID: 99)], windows: [SCWindow(owningApplication: helper)])
    let own = DesktopCapturePrivacy(display: SCDisplay(), drain: {})
    let ownFilter = try await own.initialFilter()
    check(ownFilter.0.pids == [99,500], "own host and CUA window-owner fallback are excluded together")
    own.stop()
    NSWorkspace.shared.runningApplications = [NSRunningApplication(privateID, 999)]
    let missing = DesktopCapturePrivacy(display: SCDisplay(), drain: {})
    do { _ = try await missing.initialFilter(); check(false,"missing private owner must throw") }
    catch { check(!admitted(missing.admission), "known private PID absent from SCK inventory fails closed") }
    missing.stop()
    NSWorkspace.shared.runningApplications = []
    WindowCatalog.content = nil
    let unavailable = DesktopCapturePrivacy(display: SCDisplay(), drain: {})
    do { _ = try await unavailable.initialFilter(); check(false,"unavailable inventory must throw") }
    catch { check(!admitted(unavailable.admission), "enumeration failure cannot choose an unfiltered fallback") }
    unavailable.stop()

    WindowCatalog.content = SCShareableContent(applications: [helper])
    let failed = DesktopCapturePrivacy(display: SCDisplay(), drain: {})
    let ready = try await failed.initialFilter(), failing = SCStream()
    failed.attach(failing, revision: ready.1)
    failing.held = true
    notify(NSRunningApplication(privateID,500))
    await wait { failing.callbacks.count == 1 }
    failing.complete(NSError(domain:"fixture",code:1))
    for _ in 0..<20 { await Task.yield() }
    check(!admitted(failed.admission), "native update failure keeps delivery closed")
    notify(NSRunningApplication(privateID,500))
    for _ in 0..<20 { await Task.yield() }
    check(failing.filters.count == 1, "failed monitor is terminal so late update effects cannot reopen delivery")

    let timed = DesktopCapturePrivacy(display: SCDisplay(), drain: {})
    let timedInitial = try await timed.initialFilter(), hung = SCStream()
    timed.attach(hung, revision: timedInitial.1)
    hung.held = true
    notify(NSRunningApplication(privateID,500))
    await wait { hung.callbacks.count == 1 }
    try await Task.sleep(for: .milliseconds(3200))
    check(!admitted(timed.admission), "bounded native update timeout remains closed")
    hung.complete()
    for _ in 0..<20 { await Task.yield() }
    check(!admitted(timed.admission), "late native success after timeout cannot reopen delivery or resume continuation twice")
    timed.stop()
    print("PASS \(checks) desktop privacy checks; inert OS adapters, no screen capture or device input")
}
Task { @MainActor in
    do { try await runChecks(); exit(0) }
    catch { print("FAIL unexpected \(error)"); exit(1) }
}
dispatchMain()
