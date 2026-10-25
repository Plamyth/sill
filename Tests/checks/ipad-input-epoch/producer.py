"""UIKit 실행 없이 실제 touch·인식기·hardware press 함수의 identity 경계를 실행한다."""
import importlib.util
import subprocess


def fixture(root, baseline=False, trackpad_baseline=False, include_adapter=True):
    spec = importlib.util.spec_from_file_location('extract', root / 'Tests/checks/vision-input-controls/extract.py')
    ex = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ex)
    current = (root / 'iOSClient/InputOverlay.swift').read_text()
    source = subprocess.check_output(['git', 'show', 'HEAD:iOSClient/InputOverlay.swift'], cwd=root, text=True) if baseline else current
    methods = ['private func normalized(', 'private func sendPointer(', 'private static func pointerTouch(', 'private func ownPointer(',
               'override func touchesBegan(', 'override func touchesMoved(', 'override func touchesEnded(', 'override func touchesCancelled(',
               '@objc private func handleLongPress(', 'private func forward(']
    helpers = ['private func capturedSender()', 'private func sender(for gesture:', 'private func ownedPointerTouch(',
               'func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch:']
    body = '\n'.join(ex.select_platform(ex.block(source, m), vision=False, ios=True) for m in methods)
    body += '\n' + '\n'.join(ex.select_platform(ex.block(current, m), vision=False, ios=True) for m in helpers)
    trackpad = (root / 'iOSClient/TrackpadView.swift').read_text()
    trackpad_source = subprocess.check_output(['git', 'show', 'HEAD:iOSClient/TrackpadView.swift'], cwd=root, text=True) if trackpad_baseline else trackpad
    trackpad_methods = ['@objc private func handleLongPress(', 'private func beginScroll(', 'private func endScroll(']
    trackpad_body = '\n'.join(ex.select_platform(ex.block(trackpad_source, m), vision=False, ios=True) for m in trackpad_methods)
    trackpad_body += '\n' + '\n'.join(ex.block(trackpad, m) for m in ['private func capturedSender()', 'private func sender(for gesture:',
        'func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch:'])
    adapter = '''
protocol UIViewRepresentable {}
typealias Context = Void
''' + ex.block(trackpad, 'struct TrackpadView: UIViewRepresentable') if include_adapter else ''
    return '''import Foundation
import CoreGraphics
import StreamProtocol
enum PointerPresence { enum Origin { case pencil, none } }
class FakeUIView: NSObject {
    func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}
final class UITouch: NSObject {
    enum TouchType { case direct, pencil, indirectPointer }
    var type = TouchType.pencil
    var point = CGPoint(x: 20, y: 30)
    func location(in view: FakeUIView) -> CGPoint { point }
}
final class UIEvent {
    struct ButtonMask: OptionSet {
        let rawValue: Int
        static let secondary = ButtonMask(rawValue: 1)
    }
    var buttonMask: ButtonMask = []
}
final class UIPress: NSObject {
    struct Code { var rawValue: Int }
    struct Flags { var rawValue: Int }
    struct Key { var keyCode: Code; var modifierFlags = Flags(rawValue: 0) }
    var key: Key? = Key(keyCode: Code(rawValue: 0x50))
}
class UIGestureRecognizer: NSObject {
    enum State { case possible, began, changed, ended, cancelled, failed }
    var state = State.possible
    var numberOfTouches = 0
    var point = CGPoint(x: 20, y: 30)
    func location(in view: FakeUIView) -> CGPoint { point }
}
final class UILongPressGestureRecognizer: UIGestureRecognizer {}
final class UIPanGestureRecognizer: UIGestureRecognizer {}
final class Momentum { func stop() {} }
final class Coast {
    var onStep: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    func stop() { let end = onEnd; onStep = nil; onEnd = nil; end?() }
    func start(velocity: CGPoint, onBegin: @escaping () -> Void, onStep: @escaping (CGPoint) -> Void, onEnd: @escaping () -> Void) {
        self.onStep = onStep; self.onEnd = onEnd; onBegin()
    }
    func step() { onStep?(CGPoint(x: 2, y: 3)) }
}
final class Strokes { var silent = false }
final class InputOverlayView: FakeUIView {
    var send: (InputEvent) -> Void = { _ in }
    var captureInputSender: (() -> (InputEvent) -> Void)?
    var recognizerInputs: [ObjectIdentifier: (InputEvent) -> Void] = [:]
    var pointerInputs: [ObjectIdentifier: (send: (InputEvent) -> Void, secondary: Bool)] = [:]
    var hardwareInputs: [ObjectIdentifier: (send: (InputEvent) -> Void, usage: UInt16)] = [:]
    var hardwareOwners: [UInt16: ObjectIdentifier] = [:]
    var pointerButtonIsSecondary = false
    var videoRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    var setOwnPointer: (CGPoint?, PointerPresence.Origin) -> Void = { _, _ in }
    var forwarded = ForwardedKeys()
    var fingerDragging = false
    var scrollGestureOpen = false
    var scrollPan: UIPanGestureRecognizer?
    let momentum = Momentum()
    let strokes = Strokes()
''' + body.replace('private ', '').replace('@objc ', '') + '''
}
final class Haptic { func impactOccurred(intensity: Double) {} }
final class TrackpadSurface {
    init(frame: CGRect = .zero) {}
    var send: (InputEvent) -> Void = { _ in }
    var captureInputSender: (() -> (InputEvent) -> Void)?
    var recognizerInputs: [ObjectIdentifier: (InputEvent) -> Void] = [:]
    var dragSender: ((InputEvent) -> Void)?
    var dragOwner: ObjectIdentifier?
    var scrollSender: ((InputEvent) -> Void)?
    var bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    var verticalSpan: CGFloat?
    var ySpan: CGFloat { verticalSpan ?? bounds.height }
    var scrolling = false
    var trackSuspended = false
    var scrollVelocity = CGPoint.zero
    var setPointer: (CGPoint) -> Void = { _ in }
    var feed: () -> (anchor: CGPoint?, reseeds: Int) = { (nil, 0) }
    var onFingers: (Int) -> Void = { _ in }
    var latchedModifiers: KeyModifiers = []
    var onModifiersConsumed: (() -> Void)?
    var sendGesture: (TrackpadGestures.Gesture, Int) -> Bool = { _, _ in false }
    let momentum = Coast()
    var dragging = false
    var cursor = CGPoint(x: 0.2, y: 0.3)
    let strokes = Strokes()
    let clickHaptic = Haptic()
    func catchUp() {}
    func pressModifiers(using sender: ((InputEvent) -> Void)? = nil) {}
    func releaseModifiers(using sender: ((InputEvent) -> Void)? = nil) {}
    func consumeLatch() {}
''' + trackpad_body.replace('private ', '').replace('@objc ', '') + '\n}\n' + adapter + '\n' + (root / 'iOSClient/TrackpadGestures.swift').read_text()
