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
        var blocksRotation = false
    }
    private var magnification: Magnification?
    private struct Rotation {
        var degrees: Double
        var time: TimeInterval
        let client: StreamClient
        let peer: ObjectIdentifier
        let scope: VisionInputBinding
        let source: StreamSource
        let token: VisionDisplaySelection.Token?
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
        if self.client !== client {
            releaseAll()
            if self.client?.visionInputSession === self { self.client?.visionInputSession = nil }
        }
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
        magnification?.blocksRotation = zoom.blocksRotation || factor <= 0.92 || factor >= 1.08
        if magnification?.blocksRotation == true { rotation = nil }
        if let next = zoom.base.magnified(by: factor, at: zoom.anchor, in: geometry) { viewport = next }
    }

    func rotate(_ degrees: Double, at anchor: CGPoint, time: TimeInterval, geometry: VisionPointer.Geometry, revision: UUID) {
        guard revision == gestureRevision, self.geometry == geometry else { return }
        guard canSend else { releaseAll(); return }
        guard degrees.isFinite, time.isFinite, viewport.point(anchor, in: geometry) != nil,
              time >= (rotation?.time ?? -.infinity) else { finishGesture(revision: revision); return }
        guard magnification?.blocksRotation != true else { return }
        guard let client, let peer = client.connection else { return }
        let scope = client.visionInputBinding
        if let turn = rotation,
           turn.client !== client || turn.peer != ObjectIdentifier(peer) || turn.scope != scope ||
           turn.source != client.active || turn.token != client.visionDisplaySelection.token {
            finishGesture(revision: revision)
            return
        }
        if rotation == nil {
            momentum.stop()
            pointer.cancel().forEach { client.sendInput($0) }
            consumeLatch()
            rotation = Rotation(degrees: degrees, time: time, client: client, peer: ObjectIdentifier(peer),
                                scope: scope, source: client.active, token: client.visionDisplaySelection.token)
        } else {
            rotation?.degrees = degrees
            rotation?.time = time
        }
    }

    func finishGesture(revision: UUID, completed: Bool = false) {
        guard revision == gestureRevision else { return }
        let flick = completed ? pointer.flick : nil
        let completedRotation = completed && magnification?.blocksRotation != true ? rotation : nil
        let wasRotating = rotation != nil
        let events = cancelPointer()
        if canSend {
            events.forEach { client?.sendInput($0) }
            if !wasRotating, let flick, let geometry { startMomentum(flick, geometry: geometry) }
        }
        else if !events.isEmpty { client?.cancelVisionInputs() }
        if !completed { client?.cancelVisionCursor() }
        if let turn = completedRotation, let token = turn.token, canSend,
           client === turn.client, turn.client.connection.map(ObjectIdentifier.init) == turn.peer,
           turn.client.visionInputBinding == turn.scope, turn.client.active == turn.source,
           turn.client.visionDisplaySelection.token == token, abs(turn.degrees) >= 25 {
            _ = turn.client.selectAdjacentVisionDisplay(by: turn.degrees > 0 ? 1 : -1, expected: token)
        }
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
