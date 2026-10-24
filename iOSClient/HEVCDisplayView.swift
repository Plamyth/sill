import UIKit
import AVFoundation
import Combine
import CoreMedia
import SwiftUI
import StreamProtocol

final class HEVCDisplayView: UIView {
    override class var layerClass: AnyClass { CALayer.self }
    private var nativeLayer: AVSampleBufferDisplayLayer?
    private var displayLayer: AVSampleBufferDisplayLayer { nativeLayer! }
    private enum NativeBinding: Equatable {
        case closed
        case legacy
        case epoch(VideoEpoch, ObjectIdentifier)
    }
    private var nativeBinding = NativeBinding.closed
    private var nativeLegacyPeer: ObjectIdentifier?
    private var presentation = VisionPresentation()
    private var retiring: (id: UUID, layer: AVSampleBufferDisplayLayer)?
    private var presentationObservers: [NSObjectProtocol] = []
    private var presentationForeground = true
    private let presentationShield = CALayer()
    private var pendingNativePS: ParameterSets?
    private var pendingNativeIDR: Data?
    var onPresentation: ((VisionPresentation.Ticket?) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private var lastParameterSets: Data?

    /// The streamed frame's pixel size, reported on main whenever new parameter sets arrive.
    /// Input needs it: touches are normalized against the video, not against this view.
    var onVideoSize: ((CGSize) -> Void)?
    /// The same event, fired on main right after `onVideoSize`. `StreamClient` owns `onVideoSize`
    /// (it feeds `videoSize`); `StreamView` owns this one and tells the client's pointer on it
    /// (`StreamClient.pointerFrameChanged`). Two hooks instead of a chain, so re-hosting after a
    /// rotation cannot stack closures.
    var onVideoSizeForPointer: ((CGSize) -> Void)?

    // MARK: The pointer sprite
    //
    // The Mac's cursor is never in the video (the host captures without it), so every pointer the
    // device shows is this sprite, in the Mac's live shape (kind 14). It is one of two things
    // (docs/pointer-visibility-plan.md, "What the device draws"; `StreamClient.renderPointer` decides):
    // the Mac's own pointer, while the Mac or another device moved it last, placed where kind 26
    // says it is and moved at the rate those reports come; or this device's own, for the portrait
    // trackpad (and the Pencil, with Q2's flip), placed at touch rate rather than a network round
    // trip behind, which is where the Mac's cursor in the video would be. All of it main thread.

    private let cursorLayer = HEVCDisplayView.makeCursorLayer()
    /// Where the sprite's tip is, a fraction of the video frame, or nil when hidden: what
    /// `StreamClient.renderPointer` last handed over.
    private var pointer: CGPoint?
    /// Main-thread copy of the frame size the layer draws. `apply` runs on the network queue and
    /// hops here with it; `clear` zeroes it. Zero hides the sprite: there is no frame to point into.
    private var pointerVideoSize: CGSize = .zero
    /// Stacking inside this view's layer, which is the video layer: sibling sublayers draw in
    /// zPosition order, so the sprite sits above the picture whatever the display layer adds
    /// underneath, and the DEBUG readout sits above the sprite.
    private static let cursorZ: CGFloat = 100
    private static let hudZ: CGFloat = 200

    #if DEBUG
    /// The `-SillHUD 1` readout and its subscriptions to the client. nil unless that argument is set.
    private var hud: DiagnosticsHUDView?
    private var hudSubscriptions = Set<AnyCancellable>()
    #endif

    /// Where `resizeAspect` actually draws a `videoSize` frame inside `bounds`: the same letterboxed
    /// rect the layer uses, which is what maps a touch to a fraction of the frame.
    /// Returns `.zero` while the video size is unknown, so callers can tell "no video" from "top left".
    static func videoRect(in bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.minX + (bounds.width - size.width) / 2,
                      y: bounds.minY + (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        presentationShield.backgroundColor = UIColor.black.cgColor
        presentationShield.zPosition = 90
        layer.addSublayer(presentationShield)
        layer.addSublayer(cursorLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A standalone layer renders at 1× unless told otherwise; the arrow should be crisp.
        cursorLayer.contentsScale = traitCollection.displayScale
        if window == nil { invalidateNativeMedia() }
        else { rebuildNativeLayer() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nativeLayer?.frame = bounds
        presentationShield.frame = bounds
        CATransaction.commit()
        placeCursor()   // rotation and letterbox changes move the video rect under it
        #if DEBUG
        if let debugFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            debugFrame.frame = Self.videoRect(in: bounds, videoSize: pointerVideoSize)
            CATransaction.commit()
        }
        if let hud {
            // Rotation reparents this view into a new SwiftUI host; keep the readout above anything
            // added since and pinned to the new bounds.
            bringSubviewToFront(hud)
            hud.place(in: bounds)
        }
        #endif
    }

    #if DEBUG
    /// Shows the diagnostics readout fed by `client`, when launched with `-SillHUD 1`. Idempotent:
    /// the view is shared across layouts, so every re-host calls this and only the first one counts.
    func attachDiagnostics(to client: StreamClient) {
        guard DiagnosticsHUDView.isEnabled, hud == nil else { return }
        let hud = DiagnosticsHUDView(frame: .zero)
        hud.layer.zPosition = Self.hudZ   // above the pointer sprite
        addSubview(hud)
        self.hud = hud
        // [weak hud]: the view owns the subscriptions, the subscriptions must not own the view.
        Publishers.CombineLatest(client.$linkStats, client.$videoSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak hud] stats, size in hud?.update(stats: stats, videoSize: size) }
            .store(in: &hudSubscriptions)
        setNeedsLayout()
    }
    #endif

    /// Shows the sprite at `p` (a fraction of the video frame) or hides it (nil): the Mac's pointer
    /// or this device's own, whichever `StreamClient.renderPointer` says. Up to 120 times a second.
    /// Main thread.
    func setPointer(_ p: CGPoint?) {
        pointer = p
        placeCursor()
    }

    #if DEBUG
    /// The layout harness (`-SillPointer`): the frame size the sprite needs, as the host's parameter
    /// sets would give it, for a mock that never streams; and a dim rectangle where that frame is
    /// drawn, so a photo shows what the sprite points into (the mock's picture is black).
    func debugFrameSize(_ size: CGSize) {
        pointerVideoSize = size
        if debugFrame == nil {
            let frame = CALayer()
            frame.backgroundColor = UIColor(white: 0.16, alpha: 1).cgColor
            frame.zPosition = Self.cursorZ - 1
            layer.addSublayer(frame)
            debugFrame = frame
        }
        setNeedsLayout()
        placeCursor()
    }

    /// `debugFrameSize`'s rectangle; nil unless the harness asked for it.
    private var debugFrame: CALayer?
    #endif

    /// Gives the sprite the Mac's current cursor image (I-beam, hand, resize…) with its hotspot at
    /// the layer's anchor, or falls back to the built-in arrow when nil. Sizes are Mac points, drawn
    /// 1:1 in device points. Main thread, never animated.
    func setCursorShape(_ shape: StreamClient.CursorShape?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let shape, let cg = shape.image.cgImage, shape.size.width > 0, shape.size.height > 0 {
            cursorLayer.path = nil
            cursorLayer.shadowPath = nil
            cursorLayer.shadowOpacity = 0
            cursorLayer.contents = cg
            cursorLayer.contentsGravity = .resize
            cursorLayer.bounds = CGRect(origin: .zero, size: shape.size)
            cursorLayer.anchorPoint = CGPoint(x: shape.hotspot.x / shape.size.width, y: shape.hotspot.y / shape.size.height)
        } else {
            let arrow = Self.arrowPath
            cursorLayer.contents = nil
            cursorLayer.path = arrow
            cursorLayer.shadowPath = arrow
            cursorLayer.shadowOpacity = 0.3
            cursorLayer.bounds = arrow.boundingBox
            cursorLayer.anchorPoint = .zero
        }
        placeCursor()
    }

    /// Puts the sprite's tip on the pointer inside the letterboxed video rect, or hides it when
    /// there is no pointer or no video yet. Never animated: an implicit 0.25 s action on a
    /// standalone layer is exactly the lag the sprite exists to remove. Main thread.
    private func placeCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if case .epoch = nativeBinding, presentation.admitted == nil { cursorLayer.isHidden = true; return }
        let rect = Self.videoRect(in: bounds, videoSize: pointerVideoSize)
        guard let p = pointer, rect.width > 0, rect.height > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let x = min(max(p.x, 0), 1), y = min(max(p.y, 0), 1)
        cursorLayer.position = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        cursorLayer.isHidden = false
    }

    /// A macOS-style arrow, about 20 pt tall: white, 1 pt black outline, a soft shadow. Its tip is
    /// the hotspot and sits at the layer's origin, so `position` is the point being pointed at.
    static let arrowPath: CGPath = {
        let arrow = CGMutablePath()
        arrow.addLines(between: [
            CGPoint(x: 0, y: 0),        // tip
            CGPoint(x: 0, y: 16.8),     // down the straight left edge
            CGPoint(x: 4.0, y: 12.8),   // in to the tail
            CGPoint(x: 6.8, y: 19.2),   // tail, lower left
            CGPoint(x: 9.6, y: 18.0),   // tail, lower right
            CGPoint(x: 6.9, y: 12.0),   // back up to the head
            CGPoint(x: 12.0, y: 12.0),  // right wing
        ])
        arrow.closeSubpath()
        return arrow
    }()

    private static func makeCursorLayer() -> CAShapeLayer {
        let arrow = arrowPath
        let shape = CAShapeLayer()
        shape.path = arrow
        shape.fillColor = UIColor.white.cgColor
        shape.strokeColor = UIColor.black.cgColor
        shape.lineWidth = 1
        shape.lineJoin = .round        // a mitred 45° tip would poke 1.3 pt past the hotspot
        shape.bounds = arrow.boundingBox
        shape.anchorPoint = .zero
        shape.shadowPath = arrow       // spares Core Animation an offscreen pass to find the shape
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.3
        shape.shadowRadius = 1
        shape.shadowOffset = CGSize(width: 0, height: 1)
        shape.zPosition = cursorZ
        shape.isHidden = true
        return shape
    }

    func apply(_ ps: ParameterSets) {
        return
    }

    func applyLegacy(_ ps: ParameterSets, peer: ObjectIdentifier) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.nativeBinding == .legacy, self.nativeLegacyPeer == peer else { return }
            if let prior = self.lastParameterSets, prior != ps.encoded() { self.invalidateNativeMedia() }
            if let prior = self.pendingNativePS, prior.encoded() != ps.encoded() { self.pendingNativeIDR = nil }
            self.pendingNativePS = ps
            self.rebuildNativeLayer()
            if self.nativeLayer != nil { self.applyFormat(ps) }
        }
    }

    private func applyFormat(_ ps: ParameterSets) {
        // The host repeats the parameter sets with every keyframe. Only a real change (a new source,
        // a resize) needs a new format description and a blank layer; a repeat must not flicker.
        let encoded = ps.encoded()
        if encoded == lastParameterSets, formatDescription != nil { return }
        lastParameterSets = encoded
        let buffers = ps.sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = ps.sets.map(\.count)

        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
            parameterSetSizes: sizes, nalUnitHeaderLength: Int32(ps.nalUnitHeaderLength),
            extensions: nil, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { print("format description failed: \(status)"); return }
        if case .epoch(let epoch, _) = nativeBinding {
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            guard epoch.matchesEncodedDimensions(width: Int(dimensions.width), height: Int(dimensions.height)) else {
                invalidateNativeMedia()
                return
            }
        }
        formatDescription = desc
        waitingForKeyframe = true
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        let size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        pointerVideoSize = size
        onVideoSize?(size)
        placeCursor()
        onVideoSizeForPointer?(size)
        // Remove the last frame too: switching sources should show black until the new keyframe,
        // not the previous window frozen in place.
    }

    /// Session over: drop the picture and forget the format so the next Mac starts clean.
    func clear() {
        nativeBinding = .closed
        nativeLegacyPeer = nil
        invalidateNativeMedia()
        return
    }

    func enqueue(_ data: Data, isKeyframe: Bool) {
        return
    }

    func enqueueLegacy(_ data: Data, isKeyframe: Bool, peer: ObjectIdentifier) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.nativeBinding == .legacy, self.nativeLegacyPeer == peer else { return }
            guard self.nativeLayer != nil else {
                if isKeyframe { self.pendingNativeIDR = data }
                return
            }
            self.enqueueSample(data, isKeyframe: isKeyframe)
        }
    }

    private func enqueueSample(_ data: Data, isKeyframe: Bool) {
        guard let desc = formatDescription else { return }
        if waitingForKeyframe {
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }

        let count = data.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferAssureBlockMemory(block) == noErr else { return }
        let replaced = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard replaced == noErr else { return }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var size = count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: desc, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return }

        // Show each frame as soon as it decodes instead of scheduling by timestamp.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
           let first = attachments.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        }

        if displayLayer.status == .failed {
            print("display layer failed: \(String(describing: displayLayer.error))")
            invalidateNativeMedia()
            waitingForKeyframe = true
            return
        }
        displayLayer.sampleBufferRenderer.enqueue(sample)
        if let ticket = presentation.ticket {
            if isKeyframe { presentation.enqueuedIDR(ticket) }
            readPresentation(ticket)
        }
    }

    func setPresentation(epoch: VideoEpoch?, peer: ObjectIdentifier?, modern: Bool) {
        let next: NativeBinding
        if modern, let epoch, let peer { next = .epoch(epoch, peer) }
        else { next = modern ? .closed : .legacy }
        guard nativeBinding != next || (next == .legacy && nativeLegacyPeer != peer) else { return }
        nativeLegacyPeer = modern ? nil : peer
        nativeBinding = next
        invalidateNativeMedia()
        rebuildNativeLayer()
    }

    func setPresentationForeground(_ foreground: Bool) {
        guard presentationForeground != foreground else { return }
        presentationForeground = foreground
        invalidateNativeMedia()
        if foreground { rebuildNativeLayer() }
    }

    func receiveParameters(_ ps: ParameterSets, epoch: UUID, peer: ObjectIdentifier) {
        guard window != nil, presentationForeground,
              case .epoch(let binding, let expected) = nativeBinding, binding.id == epoch, expected == peer else { return }
        if let prior = lastParameterSets, prior != ps.encoded(), formatDescription != nil {
            invalidateNativeMedia()
        }
        if let prior = pendingNativePS, prior.encoded() != ps.encoded() { pendingNativeIDR = nil }
        pendingNativePS = ps
        rebuildNativeLayer()
        guard nativeLayer != nil else { return }
        applyFormat(ps)
    }

    func receiveFrame(_ data: Data, keyframe: Bool, epoch: UUID, peer: ObjectIdentifier) {
        guard window != nil, presentationForeground,
              case .epoch(let binding, let expected) = nativeBinding, binding.id == epoch, expected == peer,
              let ps = pendingNativePS, PresentationMedia.validFrame(data, nalLength: ps.nalUnitHeaderLength, keyframe: keyframe) else { return }
        if nativeLayer == nil {
            if keyframe { pendingNativeIDR = data }
            return
        }
        enqueueSample(data, isKeyframe: keyframe)
    }

    private func invalidateNativeMedia() {
        presentation.revoke()
        onPresentation?(nil)
        presentationShield.isHidden = false
        cursorLayer.isHidden = true
        formatDescription = nil
        lastParameterSets = nil
        waitingForKeyframe = true
        pendingNativePS = nil
        pendingNativeIDR = nil
        pointerVideoSize = .zero
        onVideoSize?(.zero)
        presentationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        presentationObservers = []
        guard let old = nativeLayer else { return }
        nativeLayer = nil
        old.isHidden = true
        old.removeFromSuperlayer()
        let id = UUID()
        retiring = (id, old)
        old.sampleBufferRenderer.flush(removingDisplayedImage: true) { [weak self, old] in
            DispatchQueue.main.async {
                guard let self, self.retiring?.id == id, self.retiring?.layer === old else { return }
                self.retiring = nil
                self.rebuildNativeLayer()
            }
        }
    }

    private func rebuildNativeLayer() {
        guard window != nil, presentationForeground, nativeLayer == nil, retiring == nil, nativeBinding != .closed else { return }
        let child = AVSampleBufferDisplayLayer()
        child.videoGravity = .resizeAspect
        child.frame = bounds
        layer.insertSublayer(child, at: 0)
        nativeLayer = child
        switch nativeBinding {
        case .epoch(let epoch, let peer):
            presentation.begin(epoch: epoch, peer: peer, layer: ObjectIdentifier(child))
            let ticket = presentation.ticket!
            for name in [NSNotification.Name.AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                         NSNotification.Name.AVSampleBufferDisplayLayerFailedToDecode,
                         NSNotification.Name.AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange] {
                presentationObservers.append(NotificationCenter.default.addObserver(forName: name, object: child, queue: .main) { [weak self, weak child] note in
                    guard let self, let child, self.nativeLayer === child, self.presentation.ticket == ticket else { return }
                    if note.name == .AVSampleBufferDisplayLayerFailedToDecode { self.invalidateNativeMedia() }
                    else { self.readPresentation(ticket) }
                })
            }
        case .legacy: presentationShield.isHidden = true
        case .closed: break
        }
        if let ps = pendingNativePS { applyFormat(ps) }
        if let idr = pendingNativeIDR { pendingNativeIDR = nil; enqueueSample(idr, isKeyframe: true) }
    }

    private func readPresentation(_ ticket: VisionPresentation.Ticket) {
        guard presentation.ticket == ticket, let child = nativeLayer, ObjectIdentifier(child) == ticket.layer else { return }
        let healthy = child.status != .failed && !child.requiresFlushToResumeDecoding
        presentation.observe(ticket, ready: child.isReadyForDisplay, healthy: healthy,
                             attached: window != nil, foreground: presentationForeground)
        guard presentation.ticket != nil else { invalidateNativeMedia(); return }
        let admitted = presentation.admitted
        presentationShield.isHidden = admitted != nil
        onPresentation?(admitted)
    }
}

struct StreamView: UIViewRepresentable {
    let client: StreamClient

    /// Hosts the client's single display view. SwiftUI may build the new layout's host before it
    /// dismantles the old one, so detach the view from wherever it was first.
    func makeUIView(context: Context) -> HEVCDisplayView {
        let view = client.displayView
        view.removeFromSuperview()
        #if DEBUG
        view.attachDiagnostics(to: client)
        #endif
        wirePointer(view)
        return view
    }

    /// Connects the client's pointer to the sprite, with no SwiftUI in between (a re-render per move
    /// is the lag this avoids). Runs on every re-host, rotation included: the hooks are plain
    /// assignments, so the newest replaces the last instead of stacking. This is the only place that
    /// sets `onPointerChange`. Main thread, like everything the closures touch.
    private func wirePointer(_ view: HEVCDisplayView) {
        let client = self.client
        client.onCursorShapeChange = { [weak view] shape in view?.setCursorShape(shape) }
        view.setCursorShape(client.cursorShape)
        client.onPointerChange = { [weak view] p in view?.setPointer(p) }
        // A new frame size (another source, an Aa resize) changes what a fraction means: this
        // device's own pointer, while it shows, starts again in the middle and the Mac's goes there
        // too (after the tour, while one shows: `pointerFrameChanged`); the Mac's arrow follows the
        // host's next report.
        view.onVideoSizeForPointer = { [weak client] _ in client?.pointerFrameChanged() }
        // Catch up with what the sprite shows now (a pointer set before this view was hosted).
        client.renderPointer()
    }

    func updateUIView(_ uiView: HEVCDisplayView, context: Context) {}
}
