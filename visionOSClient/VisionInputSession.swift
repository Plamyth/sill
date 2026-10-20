import SwiftUI
import StreamProtocol

final class VisionInputSession: ObservableObject {
    @Published private(set) var latched: KeyModifiers = []
    @Published private(set) var moving = false
    @Published private(set) var viewport = VisionViewport()
    @Published private(set) var gestureRevision = UUID()
    let keyboard = InputOverlayProxy()
    private weak var client: StreamClient?
    private var pointer = VisionPointer()
    private let momentum = ScrollMomentum()
    private var geometry: VisionPointer.Geometry?
    private struct Magnification {
        let base: VisionViewport
        let anchor: CGPoint
        var time: TimeInterval
        var largestChange: CGFloat = 0
    }
    private var magnification: Magnification?
    private struct Rotation {
        var degrees: Double
        var time: TimeInterval
        let scope: VisionDisplaySelection.Token
    }
    private var rotation: Rotation?
    var allowed = false {
        didSet { if oldValue && !allowed { releaseAll() } }
    }
    var canSend: Bool {
        guard let client else { return false }
        return !client.visionDisplaySelection.inputBlocked && allowed && !moving && client.connected && client.active != .none && client.visionInputBinding.isConfirmed
    }

    func bind(_ client: StreamClient) {
        self.client = client
        client.visionInputSession = self
    }

    func toggle(_ modifier: VisionModifier) {
        guard canSend, pointer.isIdle else { return }
        if latched.contains(modifier.flag) { latched.remove(modifier.flag) }
        else { latched.insert(modifier.flag) }
        keyboard.view?.latchedModifiers = latched
    }

    func consumeLatch() {
        latched = []
        keyboard.view?.latchedModifiers = []
    }

    func press(_ key: VisionRemoteKey) {
        guard canSend else { return }
        let modifiers = latched
        releaseForNextAction()
        KeyChord.press(key.rawValue, with: modifiers).forEach { client?.sendInput($0) }
    }

    func perform(_ shortcut: VisionShortcut) {
        guard canSend, !shortcut.desktopOnly || client?.active == .desktop else { return }
        releaseForNextAction()
        KeyChord.press(shortcut.keys.0, with: shortcut.keys.1).forEach { client?.sendInput($0) }
    }

    func overlayInput(_ event: InputEvent) {
        guard canSend else { return }
        let releases = cancelPointer()
        releases.forEach { client?.sendInput($0) }
        client?.sendInput(event)
    }

    func setGeometry(_ value: VisionPointer.Geometry) {
        guard geometry != value else { return }
        releaseAll()
        geometry = value
        viewport = VisionViewport()
    }

    func spatial(_ samples: [VisionPointer.Sample], geometry: VisionPointer.Geometry, revision: UUID) {
        guard revision == gestureRevision, self.geometry == geometry else { return }
        guard canSend else { releaseAll(); return }
        guard magnification == nil, rotation == nil else { return }
        momentum.stop()
        let first = pointer.isIdle
        let events = pointer.receive(samples, geometry: geometry, viewport: viewport, modifiers: latched)
        if first && !events.isEmpty { consumeLatch() }
        events.forEach { client?.sendInput($0) }
    }

    func magnify(_ factor: CGFloat, at anchor: CGPoint, time: TimeInterval,
                 geometry: VisionPointer.Geometry, revision: UUID) {
        guard revision == gestureRevision, self.geometry == geometry else { return }
        guard canSend else { releaseAll(); return }
        guard time.isFinite, factor.isFinite, factor > 0 else { finishGesture(revision: revision); return }
        if magnification == nil {
            momentum.stop()
            let releases = pointer.cancel()
            releases.forEach { client?.sendInput($0) }
            magnification = Magnification(base: viewport, anchor: anchor, time: time)
            consumeLatch()
        }
        guard let zoom = magnification, time >= zoom.time else { return }
        magnification?.time = time
        magnification?.largestChange = max(zoom.largestChange, abs(factor - 1))
        if let next = zoom.base.magnified(by: factor, at: zoom.anchor, in: geometry) { viewport = next }
    }

    func rotate(_ degrees: Double, at anchor: CGPoint, time: TimeInterval, geometry: VisionPointer.Geometry, revision: UUID) {
        guard revision == gestureRevision, self.geometry == geometry, canSend else { return }
        guard viewport.point(anchor, in: geometry) != nil else { return }
        guard degrees.isFinite, time.isFinite else { finishGesture(revision: revision); return }
        guard time >= (rotation?.time ?? -.infinity) else { return }
        guard let scope = client?.visionDisplaySelection.token else { return }
        guard rotation == nil || rotation?.scope == scope else { finishGesture(revision: revision); return }
        if rotation == nil {
            momentum.stop()
            pointer.cancel().forEach { client?.sendInput($0) }
            consumeLatch()
        }
        rotation = Rotation(degrees: degrees, time: time, scope: scope)
    }

    func finishGesture(revision: UUID, completed: Bool = false) {
        guard revision == gestureRevision else { return }
        let flick = completed ? pointer.flick : nil
        let turn = completed && (magnification?.largestChange ?? 0) <= 0.08 ? rotation : nil
        let baseViewport = magnification?.base
        let events = cancelPointer()
        if canSend {
            events.forEach { client?.sendInput($0) }
            if let turn, abs(turn.degrees) >= 25 {
                if client?.selectAdjacentVisionDisplay(by: turn.degrees > 0 ? 1 : -1, expected: turn.scope) == true,
                   let baseViewport { viewport = baseViewport }
            } else if let flick, let geometry { startMomentum(flick, geometry: geometry) }
        }
        else if !events.isEmpty { client?.cancelVisionInputs() }
        if !completed { client?.cancelVisionCursor() }
    }

    func resetViewport() {
        releaseAll()
        viewport = VisionViewport()
    }

    func stopMomentum() { momentum.stop() }

    func takeReleases() -> [InputEvent] {
        consumeLatch()
        return cancelPointer() + (keyboard.view?.takeVisionKeyReleases() ?? [])
    }

    private func cancelPointer() -> [InputEvent] {
        momentum.stop()
        gestureRevision = UUID()
        magnification = nil
        rotation = nil
        let releases = pointer.cancel()
        pointer = VisionPointer()
        return releases
    }

    private func startMomentum(_ flick: VisionPointer.Flick, geometry: VisionPointer.Geometry) {
        guard let rect = geometry.fittedRect else { return }
        let revision = gestureRevision
        momentum.start(velocity: flick.velocity,
            onBegin: { [weak self] in
                self?.client?.sendInput(.scrollGesture(.momentumBegan, x: flick.anchor.x, y: flick.anchor.y))
            },
            onStep: { [weak self] step in
                guard let self else { return }
                guard self.canSend, self.gestureRevision == revision, self.geometry == geometry else {
                    self.momentum.stop()
                    return
                }
                self.client?.sendInput(.scroll(x: flick.anchor.x, y: flick.anchor.y,
                                              dx: step.x / rect.width, dy: step.y / rect.height))
            },
            onEnd: { [weak self] in
                guard let self else { return }
                if self.canSend, self.gestureRevision == revision {
                    self.client?.sendInput(.scrollGesture(.momentumEnded, x: flick.anchor.x, y: flick.anchor.y))
                } else { self.client?.cancelVisionInputs() }
            })
    }

    private func releaseForNextAction() { takeReleases().forEach { client?.sendInput($0) } }

    func releaseAll() {
        _ = takeReleases()
        client?.cancelVisionInputs()
    }

    func setMoving(_ value: Bool) { moving = value }
}
