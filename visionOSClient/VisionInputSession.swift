import SwiftUI
import StreamProtocol

final class VisionInputSession: ObservableObject {
    @Published private(set) var latched: KeyModifiers = []
    @Published private(set) var moving = false
    let keyboard = InputOverlayProxy()
    private weak var client: StreamClient?
    private var pointer = VisionPointer()
    var allowed = false {
        didSet { if oldValue && !allowed { releaseAll() } }
    }
    var canSend: Bool {
        guard let client else { return false }
        return allowed && !moving && client.connected && client.active != .none
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
        let releases = pointer.cancel()
        releases.forEach { client?.sendInput($0) }
        client?.sendInput(event)
    }

    func tap(_ p: CGPoint, mode: VisionPointer.Mode) {
        guard canSend else { return }
        let events = pointer.tap(p, mode: mode, modifiers: latched)
        if !events.isEmpty { consumeLatch() }
        events.forEach { client?.sendInput($0) }
    }

    func drag(from start: CGPoint, to p: CGPoint, mode: VisionPointer.Mode) {
        guard canSend else { return }
        let first = pointer.isIdle
        let events = pointer.drag(from: start, to: p, mode: mode, modifiers: latched)
        if first && !events.isEmpty { consumeLatch() }
        events.forEach { client?.sendInput($0) }
    }

    func endGesture() {
        let events = pointer.end()
        if canSend { events.forEach { client?.sendInput($0) } }
        else if !events.isEmpty { client?.cancelVisionInputs() }
    }

    func takeReleases() -> [InputEvent] {
        consumeLatch()
        return pointer.cancel() + (keyboard.view?.takeVisionKeyReleases() ?? [])
    }

    private func releaseForNextAction() { takeReleases().forEach { client?.sendInput($0) } }

    func releaseAll() {
        _ = takeReleases()
        client?.cancelVisionInputs()
    }

    func setMoving(_ value: Bool) { moving = value }
}
