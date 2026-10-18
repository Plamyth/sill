import Foundation
import CoreGraphics
import StreamProtocol

/// A desktop belongs to authenticated sessions, independently of the single-window stage.
@MainActor
final class ExtendedDesktop {
    static let name = "CCR Sill iPad 확장 화면"

    struct Dimensions: Equatable {
        let widthPt: Int
        let heightPt: Int
        let scale = 2
        var pixelWidth: Int { widthPt * scale }
        var pixelHeight: Int { heightPt * scale }

        init?(viewport: Viewport) {
            let width = viewport.extendedDesktop?.width ?? viewport.width
            let height = viewport.extendedDesktop?.height ?? viewport.height
            guard width.isFinite, height.isFinite,
                  (320...2048).contains(width), (240...2048).contains(height) else { return nil }
            widthPt = Int(width.rounded())
            heightPt = Int(height.rounded())
        }
    }

    enum Phase: Equatable {
        case idle, creating, ready, failed(String), shutdown
    }

    struct Resource {
        let id: UInt32
        let waitUntilOnline: @MainActor () async -> Bool
        let configure: @MainActor () async throws -> Void
        let isValid: @MainActor () -> Bool
        let recoverWindows: @MainActor () -> Void
        let destroy: @MainActor () -> Void
    }

    private(set) var requesters: Set<ObjectIdentifier> = []
    private(set) var phase: Phase = .idle
    private(set) var dimensions: Dimensions?
    private var generation: UInt64 = 0
    private var resource: Resource?
    private var creation: Task<Void, Never>?
    private let makeDisplay: (Dimensions, @escaping @MainActor () -> Void) throws -> Resource
    private let publishID: (UInt32?) -> Void
    private let reportFailure: (String) -> Void

    init(makeDisplay: @escaping (Dimensions, @escaping @MainActor () -> Void) throws -> Resource,
         publishID: @escaping (UInt32?) -> Void, reportFailure: @escaping (String) -> Void) {
        self.makeDisplay = makeDisplay
        self.publishID = publishID
        self.reportFailure = reportFailure
    }

    static func eligible(appKitLoop: Bool, synthetic: Bool, connected: Bool,
                         encrypted: Bool, paired: Bool, device: String?) -> Bool {
        guard appKitLoop, !synthetic, connected, encrypted, paired, let device else { return false }
        return device == "iPad" || device.range(of: #"\(iPad[0-9]+,[0-9]+\)$"#, options: .regularExpression) != nil
    }

    var displayID: UInt32? { phase == .ready ? resource?.id : nil }

    func request(_ requester: ObjectIdentifier) {
        guard phase != .shutdown else { return }
        requesters.insert(requester)
    }

    func updateViewport(_ dimensions: Dimensions, for requester: ObjectIdentifier) {
        guard requesters.contains(requester), phase == .idle else { return }
        self.dimensions = dimensions
        generation &+= 1
        let token = generation
        phase = .creating
        do {
            let display = try makeDisplay(dimensions) { [weak self] in self?.lost(token: token) }
            resource = display
            creation = Task { @MainActor [weak self] in
                let online = await display.waitUntilOnline()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                guard online else { self.fail("display did not come online", token: token); return }
                do {
                    try await display.configure()
                    guard self.generation == token, !Task.isCancelled else { return }
                    guard display.isValid() else {
                        self.fail("display geometry or non-mirror verification failed", token: token)
                        return
                    }
                    self.creation = nil
                    self.phase = .ready
                    self.publishID(display.id)
                } catch {
                    self.fail(String(describing: error), token: token)
                }
            }
        } catch {
            fail(String(describing: error), token: token)
        }
    }

    func release(_ requester: ObjectIdentifier) {
        guard requesters.remove(requester) != nil, requesters.isEmpty else { return }
        dimensions = nil
        retire(to: .idle)
    }

    func checkDisplay() {
        if phase == .ready, resource?.isValid() != true { lost(token: generation) }
    }

    func shutdown() {
        requesters.removeAll()
        dimensions = nil
        retire(to: .shutdown)
    }

    private func lost(token: UInt64) { fail("the system removed or changed the display", token: token) }

    private func fail(_ reason: String, token: UInt64) {
        guard generation == token, phase != .shutdown else { return }
        let bounded = String(reason.prefix(240))
        retire(to: .failed(bounded))
        reportFailure(bounded)
    }

    private func retire(to next: Phase) {
        generation &+= 1
        creation?.cancel()
        creation = nil
        let old = resource
        resource = nil
        phase = next
        publishID(nil)
        old?.recoverWindows()
        old?.destroy()
    }

    static func originRight(of displays: [CGRect], size: CGSize) -> CGPoint? {
        let usable = displays.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard let right = usable.max(by: { $0.maxX < $1.maxX }),
              right.maxX.isFinite, right.minY.isFinite,
              right.maxX >= Double(Int32.min), right.maxX < Double(Int32.max) - size.width,
              right.minY >= Double(Int32.min), right.minY < Double(Int32.max) - size.height else { return nil }
        return CGPoint(x: ceil(right.maxX), y: ceil(right.minY))
    }

    static func ownsWindow(_ frame: CGRect, bounds: CGRect) -> Bool {
        !frame.isEmpty && !bounds.isEmpty && bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
}

// MARK: macOS display adapter

import AppKit
import ApplicationServices

extension ExtendedDesktop {
    enum Failure: Error { case screenRecordingOff, noPhysicalDisplay, configuration, verification, notListedBySCK }

    convenience init(catalog: WindowCatalog) {
        self.init(makeDisplay: { dimensions, lost in
            guard CGPreflightScreenCaptureAccess() else { throw Failure.screenRecordingOff }
            guard !WindowCatalog.physicalDisplayIDs().isEmpty else { throw Failure.noPhysicalDisplay }
            let display = try VirtualDisplay(name: Self.name, widthPt: dimensions.widthPt, heightPt: dimensions.heightPt,
                scale: dimensions.scale, refreshHz: 60, vendorID: VirtualStage.vendorID, productID: 0x0002, serialNum: 1)
            let id = display.displayID
            var ownedBounds = CGRect.zero
            display.onTerminated = { Task { @MainActor in lost() } }
            return Resource(id: id, waitUntilOnline: { await Self.waitUntilOnline(display) },
                configure: {
                    try await Self.configure(display)
                    ownedBounds = display.bounds
                    guard let content = await WindowCatalog.shareableContent(excludingDesktopWindows: false,
                        onScreenWindowsOnly: true, timeout: 3),
                        content.displays.contains(where: { $0.displayID == id }) else { throw Failure.notListedBySCK }
                    try Task.checkCancellation()
                },
                isValid: {
                    guard Self.valid(display) else { return false }
                    ownedBounds = display.bounds
                    return true
                },
                recoverWindows: { Self.recoverWindows(in: Self.recoveryBounds(display, lastKnown: ownedBounds)) },
                destroy: { display.onTerminated = nil; display.destroy() })
        }, publishID: { [weak catalog] in catalog?.setExtendedDesktopDisplay($0) },
        reportFailure: { print("iPad extended desktop unavailable: \($0). Physical monitors remain available; reconnect to try again.") })
    }

    /// The stage's legacy wait swallows sleep cancellation. Disconnect must stop this wait.
    private static func waitUntilOnline(_ display: VirtualDisplay) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        var nextSelect = Date()
        while !Task.isCancelled, display.isAlive, Date() < deadline {
            if display.hasRequestedMode { return true }
            if display.bounds.width > 0, Date() >= nextSelect {
                display.selectRequestedMode()
                nextSelect = Date().addingTimeInterval(0.5)
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return !Task.isCancelled && display.isAlive && display.hasRequestedMode
    }

    private static func configure(_ display: VirtualDisplay) async throws {
        let physical = WindowCatalog.physicalDisplayIDs()
        guard !physical.isEmpty else { throw Failure.noPhysicalDisplay }
        if valid(display) { return }
        // Include other virtual screens so VirtualStage's eviction area cannot overlap this one.
        let others = WindowCatalog.onlineDisplayIDs().filter { $0 != display.displayID }
        guard let origin = originRight(of: others.map { CGDisplayBounds($0) },
            size: CGSize(width: display.widthPt, height: display.heightPt)) else { throw Failure.configuration }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw Failure.configuration }
        guard CGConfigureDisplayMirrorOfDisplay(config, display.displayID, kCGNullDirectDisplay) == .success,
              CGConfigureDisplayOrigin(config, display.displayID, Int32(origin.x), Int32(origin.y)) == .success else {
            CGCancelDisplayConfiguration(config)
            throw Failure.configuration
        }
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { throw Failure.configuration }
        for _ in 0..<20 {
            try Task.checkCancellation()
            if valid(display), display.bounds.origin == origin { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.verification
    }

    private static func valid(_ display: VirtualDisplay) -> Bool {
        let id = display.displayID
        let pixels = display.pixelSize
        let physical = WindowCatalog.physicalDisplayIDs().map { CGDisplayBounds($0) }
        let refreshHz = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return id != 0 && display.isAlive && CGDisplayIsActive(id) != 0 &&
            CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay && CGDisplayIsInMirrorSet(id) == 0 &&
            display.bounds.size == CGSize(width: display.widthPt, height: display.heightPt) &&
            pixels.width == display.widthPt * display.scale && pixels.height == display.heightPt * display.scale &&
            abs(refreshHz - 60) < 0.5 && !physical.isEmpty &&
            !display.bounds.isInfinite && !display.bounds.isNull &&
            physical.allSatisfy { !display.bounds.intersects($0) }
    }

    private static func recoveryBounds(_ display: VirtualDisplay, lastKnown: CGRect) -> CGRect {
        valid(display) ? display.bounds : lastKnown
    }

    private static func recoverWindows(in bounds: CGRect) {
        let physical = WindowCatalog.physicalDisplayIDs()
        guard !bounds.isEmpty, AXIsProcessTrusted(),
              let homeID = physical.first, physical.allSatisfy({ !bounds.intersects(CGDisplayBounds($0)) }),
              let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            print("iPad extended desktop cleanup: WindowServer handles remaining windows, including fullscreen windows.")
            return
        }
        let home = VirtualStage.usableArea(of: homeID) ?? CGDisplayBounds(homeID)
        let deadline = Date().addingTimeInterval(0.4)
        var attempted = 0
        var moved = 0
        for row in rows {
            guard attempted < 4, Date() < deadline else { break }
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary), ownsWindow(frame, bounds: bounds) else { continue }
            attempted += 1
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.05)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows.prefix(16) {
                guard Date() < deadline else { break }
                AXUIElementSetMessagingTimeout(window, 0.05)
                guard let live = WindowSizer.frame(of: window), ownsWindow(live, bounds: bounds),
                      abs(live.minX - frame.minX) < 2, abs(live.minY - frame.minY) < 2,
                      abs(live.width - frame.width) < 2, abs(live.height - frame.height) < 2 else { continue }
                guard Date() < deadline, !WindowSizer.isFullScreen(window) else { break }
                let origin = CGPoint(x: home.minX + max(0, (home.width - live.width) / 2),
                                     y: home.minY + max(0, (home.height - live.height) / 2))
                if WindowSizer.setPosition(window, origin) == .success { moved += 1 }
                break
            }
        }
        print("iPad extended desktop cleanup: \(moved) window move requests accepted. WindowServer handles remaining/fullscreen windows; physical recovery is unverified.")
    }
}
