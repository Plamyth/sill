import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia

/// Runs one ScreenCaptureKit stream (a window or a display) and hands out 420f pixel buffers.
/// The coordinator stops and restarts it whenever the client picks a different source.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var privacy: DesktopCapturePrivacy?
    private let streamLock = NSLock()
    private let queue = DispatchQueue(label: "sill.capture", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// The stream ended on its own (window closed, permission revoked). Called on an SCK thread.
    var onStopped: ((Error) -> Void)?

    /// `showsCursor`: draw the Mac cursor into the frames. The host passes false: the client draws
    /// the pointer itself (with the Mac's current shape, sent separately), so the video never
    /// carries a round-trip-late cursor. Never change this on a running stream:
    /// `SCStream.updateConfiguration` wedged the stream on macOS 27 (frames stopped, the next
    /// `stopCapture` never returned, and the coordinator's switch flag stayed set for good).
    ///
    /// `sourceRect`: `--virtual-display` only. The part of a display filter to encode, in points in
    /// the display's own coordinate system (origin at its top-left, SCStream.h), i.e. exactly the
    /// staged window's rectangle, so the device gets the window and nothing else. Nil (the default,
    /// and the whole default path) leaves the configuration exactly as it was.
    @MainActor
    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, showsCursor: Bool, sourceRect: CGRect? = nil,
               desktopDisplay: SCDisplay? = nil, requireOwnApplicationExclusion: Bool = false) async throws {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5   // headroom: a wedged encoder may keep one buffer forever
        config.showsCursor = showsCursor
        config.colorSpaceName = CGColorSpace.sRGB
        if let sourceRect {
            config.sourceRect = sourceRect
            config.ignoreShadowsDisplay = true                 // the crop is the window's frame; its shadow would be clipped anyway
            config.backgroundColor = Self.black                  // deterministic black behind the rounded corners
        }

        let queue = self.queue
        let privacy = desktopDisplay.map { display in
            DesktopCapturePrivacy(display: display, requireOwnApplicationExclusion: requireOwnApplicationExclusion, drain: {
                await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
            })
        }
        let prepared: (SCContentFilter, UUID)?
        do { prepared = try await privacy?.initialFilter() }
        catch { privacy?.stop(); throw error }
        let stream = SCStream(filter: prepared?.0 ?? filter, configuration: config, delegate: self)
        // Register before starting: a stop error that arrives during start must not be swallowed
        // by the identity check in didStopWithError.
        streamLock.withLock { self.stream = stream; self.privacy = privacy }
        framesSeen = 0
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            if let revision = prepared?.1 { privacy?.attach(stream, revision: revision) }
        } catch {
            privacy?.stop()
            streamLock.withLock {
                if self.stream === stream { self.stream = nil; self.privacy = nil }
            }
            throw error
        }
        let crop = sourceRect.map { String(format: " sourceRect (%.0f,%.0f,%.0f,%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? ""
        print("Capture started: \(width)×\(height) @\(fps) fps, cursor \(showsCursor ? "in" : "out"), filter \(filter.contentRect.size) scale \(filter.pointPixelScale)" + crop)
    }

    private var framesSeen = 0
    /// Held by the type: `SCStreamConfiguration.backgroundColor` is unowned(unsafe) and would not keep
    /// a temporary alive.
    private static let black = CGColor(gray: 0, alpha: 1)

    @MainActor
    func stop() async {
        let (stream, privacy) = streamLock.withLock {
            let old = (self.stream, self.privacy)
            self.stream = nil; self.privacy = nil
            return old
        }
        privacy?.stop()
        guard let stream else { return }
        try? await stream.stopCapture()
        // stopCapture returning does not mean the sample-handler queue has drained. Wait for it,
        // so no late frame reaches the next encoder at the old size.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let current = streamLock.withLock { (self.stream === stream, self.privacy?.admission) }
        guard current.0, type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw)
        else { Stats.shared.bump("cap.noStatus"); return }
        // .idle frames (nothing changed) are skipped, which is what we want.
        guard status == .complete else { Stats.shared.bump(status == .idle ? "cap.idle" : "cap.status\(statusRaw)"); return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { Stats.shared.bump("cap.noPixels"); return }
        Stats.shared.bump("cap.complete")
        framesSeen += 1
        if framesSeen == 1 { print("Capture: first frame \(CVPixelBufferGetWidth(pixelBuffer))×\(CVPixelBufferGetHeight(pixelBuffer))") }
        let deliver: () -> Void = { self.onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) }
        if let admission = current.1 { admission.deliver(deliver) }
        else { deliver() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let (current, privacy) = streamLock.withLock {
            guard stream === self.stream else { return (false, Optional<DesktopCapturePrivacy>.none) }
            let privacy = self.privacy
            self.stream = nil; self.privacy = nil
            return (true, privacy)
        }
        privacy?.admission.invalidate()
        Task { @MainActor in privacy?.stop() }
        print("Capture stream stopped (\(current ? "current" : "replaced")): \(error) — \((error as NSError).userInfo)")
        guard current else { return }   // a stream we already replaced
        onStopped?(error)
    }
}

/// HEVC wants even dimensions.
func evenPixels(_ v: CGFloat) -> Int { Int(v.rounded(.down)) & ~1 }
