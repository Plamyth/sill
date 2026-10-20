import AppKit
import Foundation
import ScreenCaptureKit

final class DesktopFrameAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = UUID()
    private var admitted = false
    private var privatePIDs = Set<pid_t>()

    var current: UUID { lock.withLock { revision } }
    var requiredPIDs: Set<pid_t> { lock.withLock { privatePIDs } }

    func invalidate() { lock.withLock { revision = UUID(); admitted = false } }

    func changed(pid: pid_t, running: Bool) {
        lock.withLock {
            if running { privatePIDs.insert(pid) } else { privatePIDs.remove(pid) }
            revision = UUID()
            admitted = false
        }
    }

    @discardableResult
    func open(_ expected: UUID) -> Bool {
        lock.withLock {
            guard revision == expected else { return false }
            admitted = true
            return true
        }
    }

    func deliver(_ body: () -> Void) {
        lock.withLock { if admitted { body() } }
    }
}

@MainActor
final class DesktopCapturePrivacy {
    enum Failure: Error { case inventoryUnavailable, privateApplicationMissing, updateTimedOut }
    nonisolated let admission = DesktopFrameAdmission()
    private let display: SCDisplay
    private let drain: () async -> Void
    private var observers: [NSObjectProtocol] = []
    private var stream: SCStream?
    private var refresh: Task<Void, Never>?
    private var stopped = false

    init(display: SCDisplay, drain: @escaping () async -> Void) {
        self.display = display
        self.drain = drain
        let gate = admission
        for app in NSWorkspace.shared.runningApplications where WindowCatalog.isPrivateApplication(app.bundleIdentifier ?? "") {
            gate.changed(pid: app.processIdentifier, running: true)
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      WindowCatalog.isPrivateApplication(app.bundleIdentifier ?? "") else { return }
                gate.changed(pid: app.processIdentifier, running: note.name == NSWorkspace.didLaunchApplicationNotification)
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            })
        }
    }

    func initialFilter() async throws -> (SCContentFilter, UUID) {
        let revision = admission.current
        return (try await filter(), revision)
    }

    private func filter() async throws -> SCContentFilter {
        guard let content = await WindowCatalog.shareableContent(excludingDesktopWindows: false, onScreenWindowsOnly: false, timeout: 3) else {
            throw Failure.inventoryUnavailable
        }
        var excluded: [pid_t: SCRunningApplication] = [:]
        for app in content.applications + content.windows.compactMap(\.owningApplication) {
            if app.processID == WindowCatalog.ownPID || WindowCatalog.isPrivateApplication(app.bundleIdentifier) {
                excluded[app.processID] = app
            }
        }
        guard admission.requiredPIDs.isSubset(of: Set(excluded.keys)) else {
            throw Failure.privateApplicationMissing
        }
        return SCContentFilter(display: display, excludingApplications: Array(excluded.values), exceptingWindows: [])
    }

    func attach(_ stream: SCStream, revision: UUID) {
        guard !stopped else { return }
        self.stream = stream
        if !admission.open(revision) { scheduleRefresh() }
    }

    private func scheduleRefresh() {
        guard !stopped, stream != nil, refresh == nil else { return }
        refresh = Task { [weak self] in
            guard let self else { return }
            defer { self.refresh = nil }
            for _ in 0..<3 {
                guard !Task.isCancelled, !self.stopped, let stream = self.stream else { return }
                let revision = self.admission.current
                do {
                    let filter = try await self.filter()
                    guard !Task.isCancelled, !self.stopped else { return }
                    if revision != self.admission.current { continue }
                    try await self.update(stream, filter: filter)
                    await self.drain()
                    guard !Task.isCancelled, !self.stopped else { return }
                    if self.admission.open(revision) { return }
                } catch {
                    self.stop()
                    print("Desktop privacy filter could not refresh; video delivery remains paused: \(error)")
                    return
                }
            }
            print("Desktop privacy inventory kept changing; video delivery remains paused")
        }
    }

    private func update(_ stream: SCStream, filter: SCContentFilter) async throws {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false
            func take() -> Bool {
                lock.withLock {
                    guard !finished else { return false }
                    finished = true
                    return true
                }
            }
        }
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.updateContentFilter(filter) { error in
                guard once.take() else { return }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if once.take() { continuation.resume(throwing: Failure.updateTimedOut) }
            }
        }
    }

    func stop() {
        stopped = true
        admission.invalidate()
        refresh?.cancel()
        refresh = nil
        stream = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }
}
