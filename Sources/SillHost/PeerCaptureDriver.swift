import Foundation
import CoreGraphics
import ScreenCaptureKit
import StreamProtocol

struct PeerCaptureDescription {
    let source: StreamSource
    let bounds: CGRect
    let width: Int
    let height: Int
    let displayID: UInt32?
    let windowPID: pid_t?
    let title: String
    var screenDemandIdentity: RemoteScreenDemandObservation.Source? = nil
}

@MainActor
protocol PeerCaptureDriver: AnyObject {
    func resolve(source: StreamSource, display: DisplaySelection?, identity: String?,
                 config: HostConfig, viewport: Viewport?) async throws -> PeerCaptureDescription
    func start(_ description: PeerCaptureDescription, epoch: VideoEpoch,
               output: @escaping (StreamMessage, UUID) -> Void) async throws
    func stop() async
    func requestKeyframe()
    func currentBounds() -> CGRect?
    var onStopped: (() -> Void)? { get set }
    var usesSoftwareEncoder: Bool { get }
}

extension PeerCaptureDriver {
    var usesSoftwareEncoder: Bool { false }
}

/// Captures the existing window/display in place. Selection has no AX or WindowServer mutation.
@MainActor
final class NativePeerCaptureDriver: PeerCaptureDriver {
    enum Failure: Error { case unavailable, changed, invalidGeometry }
    private struct Plan {
        let filter: SCContentFilter
        let display: SCDisplay?
        let description: PeerCaptureDescription
        let fps: Int
        let bitrate: Int
        let speed: Bool
    }
    private let capture = WindowCapture()
    private var encoder: HEVCEncoder?
    private var plan: Plan?
    private var active: PeerCaptureDescription?
    private var captureToken: UUID?
    private var software = false
    var usesSoftwareEncoder: Bool { software }
    var onStopped: (() -> Void)?


    func resolve(source: StreamSource, display: DisplaySelection?, identity: String?,
                 config: HostConfig, viewport: Viewport?) async throws -> PeerCaptureDescription {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        let screen: SCDisplay?
        let bounds: CGRect
        let pid: pid_t?
        let title: String
        switch source {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  let app = window.owningApplication,
                  WindowCatalog.isShareableWindow(window), window.isOnScreen else { throw Failure.unavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            bounds = window.frame
            screen = nil
            pid = app.processID
            title = window.title ?? app.applicationName
        case .desktop:
            guard let display, let item = content.displays.first(where: { $0.displayID == display.displayID }),
                  let uuid = CGDisplayCreateUUIDFromDisplayID(display.displayID)?.takeRetainedValue(),
                  let expected = identity,
                  expected == "\(display.displayID)/\(CFUUIDCreateString(nil, uuid) as String)" else { throw Failure.changed }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: item, excludingApplications: own, exceptingWindows: [])
            screen = item
            bounds = item.frame
            pid = nil
            title = "Mac 모니터"
        case .none: throw Failure.unavailable
        }
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw Failure.invalidGeometry }
        let quality = config.effective(away: false)
        let scale = min(max(quality.captureScale, 0.5), software ? 1 : 2)
        func pixels(_ points: CGFloat) -> Int { max(2, min(16384, Int(points * scale)) & ~1) }
        let description = PeerCaptureDescription(source: source, bounds: bounds, width: pixels(bounds.width),
            height: pixels(bounds.height), displayID: screen?.displayID, windowPID: pid, title: title,
            screenDemandIdentity: RemoteScreenDemandIdentity.read(source: source, windowPID: pid, displayID: screen?.displayID))
        plan = Plan(filter: filter, display: screen, description: description,
                    fps: min(software ? 60 : 120, min(config.maxFPS, max(24, viewport?.fps ?? 60))), bitrate: quality.bitrate, speed: config.prioritizeSpeed)
        return description
    }

    func start(_ description: PeerCaptureDescription, epoch: VideoEpoch,
               output: @escaping (StreamMessage, UUID) -> Void) async throws {
        guard let plan, plan.description.source == description.source,
              plan.description.bounds == description.bounds else { throw Failure.changed }
        let enc: HEVCEncoder
        do {
            enc = try HEVCEncoder(width: description.width, height: description.height, fps: plan.fps,
                                  bitrate: plan.bitrate, prioritizeSpeed: plan.speed, software: software)
        } catch {
            guard !software else { throw error }
            software = true
            enc = try HEVCEncoder(width: description.width, height: description.height, fps: min(plan.fps, 60),
                                  bitrate: plan.bitrate, prioritizeSpeed: plan.speed, software: true)
        }
        enc.onEncoded = { data, key, sets in
            let now = Date().timeIntervalSince1970
            if let sets { output(StreamMessage(kind: .parameterSets, timestamp: now, isKeyframe: true, payload: sets.encoded()), epoch.id) }
            output(StreamMessage(kind: .frame, timestamp: now, isKeyframe: key, payload: data), epoch.id)
        }
        enc.onHung = { [weak self, weak enc] in
            Task { @MainActor in
                guard let self, let enc, self.encoder === enc else { return }
                self.software = true
                self.onStopped?()
            }
        }
        let token = UUID()
        captureToken = token
        capture.onStopped = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.captureToken == token else { return }
                self.onStopped?()
            }
        }
        capture.onFrame = { buffer, pts in enc.encode(buffer, pts: pts) }
        encoder = enc
        active = description
        try await capture.start(filter: plan.filter, width: description.width, height: description.height,
                                fps: software ? min(plan.fps, 60) : plan.fps, showsCursor: false, desktopDisplay: plan.display)
    }

    func stop() async {
        captureToken = nil
        capture.onStopped = nil
        await capture.stop()
        capture.onFrame = nil
        encoder = nil
        active = nil
    }

    func requestKeyframe() { encoder?.requestKeyframe() }

    func currentBounds() -> CGRect? {
        guard let active else { return nil }
        if case .window(let id) = active.source {
            guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
                  let entry = entries.first,
                  (entry[kCGWindowOwnerPID as String] as? Int32) == active.windowPID,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return bounds
        }
        guard let id = active.displayID, CGDisplayIsActive(id) != 0 else { return nil }
        return CGDisplayBounds(id)
    }
}
