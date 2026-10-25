import Foundation
import Network
import StreamProtocol

var checks = 0, failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if condition() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func inputs(_ peer: NWConnection) -> [SourceInput] {
    peer.sent.compactMap { bytes in
        guard bytes.first == StreamMessageKind.input.rawValue else { return nil }
        return Wire.decode(SourceInput.self, from: Data(bytes.dropFirst(StreamMessage.headerLength)))
    }
}
let client = StreamClient(), peer = NWConnection(), layer = NSObject()
client.connection = peer
let epoch = VideoEpoch(generation: "A", source: .desktop,
    geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
func present() {
    client.catalog(WindowList(macName: "메모리 검사", windows: [], active: .desktop, inputGeneration: "A",
                              presentationInput: 1, videoEpoch: epoch), peer: peer)
    client.ready(VisionPresentation.Ticket(epoch: epoch, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(layer)))
}
present()
func overlay() -> InputOverlayView {
    let view = InputOverlayView()
    view.captureInputSender = { client.captureInputSender() }
    return view
}
func events(since count: Int) -> [InputEvent] {
    client.flush()
    return Array(inputs(peer).dropFirst(count)).map(\.event)
}

// 시작할 영상 좌표가 없었던 pan은 중간에 크기가 생겨도 bare wheel을 만들지 않는다.
let noVideo = overlay(), rejectedPan = UIPanGestureRecognizer()
noVideo.videoRect = .zero
let beforeRejected = inputs(peer).count
rejectedPan.state = .began; noVideo.handlePan(rejectedPan)
noVideo.videoRect = CGRect(x: 0, y: 0, width: 100, height: 100)
rejectedPan.translation = CGPoint(x: 0, y: 20)
rejectedPan.state = .changed; noVideo.handlePan(rejectedPan)
rejectedPan.state = .ended; noVideo.handlePan(rejectedPan)
let rejected = events(since: beforeRejected)
print("TRACE no-video pan wire \(rejected)")
check(rejected.isEmpty, "unopened-pan-emits-no-wire")

// long press가 scroll을 닫은 뒤 pan의 후속 changed가 독립 wheel을 만들지 않는다.
let drag = overlay(), pan = UIPanGestureRecognizer(), hold = UILongPressGestureRecognizer()
pan.state = .began; drag.handlePan(pan)
hold.state = .began; drag.handleLongPress(hold)
hold.state = .ended; drag.handleLongPress(hold)
client.flush()
let beforeClosed = inputs(peer).count
pan.translation = CGPoint(x: 0, y: 30); pan.state = .changed; drag.handlePan(pan)
pan.state = .ended; drag.handlePan(pan)
check(events(since: beforeClosed).isEmpty, "drag-closed-pan-emits-no-wheel")

let scroll = overlay(), two = UIPanGestureRecognizer()
scroll.videoRect = CGRect(x: 0, y: 100, width: 200, height: 1000)
two.point = CGPoint(x: 100, y: 200); two.numberOfTouches = 2
let beforeScroll = inputs(peer).count
two.state = .began; scroll.handlePan(two)
two.translation = CGPoint(x: 20, y: 50); two.state = .changed; scroll.handlePan(two)
two.velocity = CGPoint(x: 400, y: 500); two.state = .ended; scroll.handlePan(two)
check(events(since: beforeScroll) == [.scrollGesture(.began, x: 0.5, y: 0.1),
    .scroll(x: 0.5, y: 0.1, dx: 0.1, dy: 0.05), .scrollGesture(.ended, x: 0.5, y: 0.1),
    .scrollGesture(.momentumBegan, x: 0.5, y: 0.1)], "two-finger-letterbox-scale-phase-wire")
// Coast 어댑터는 시간 계산을 대체한다. 실제 변환·sender·종료 closure만 실행한다.
scroll.momentum.step(); scroll.momentum.stop()
check(Array(events(since: beforeScroll).suffix(2)) == [.scroll(x: 0.5, y: 0.1, dx: 0.01, dy: 0.003),
    .scrollGesture(.momentumEnded, x: 0.5, y: 0.1)], "momentum-frame-fractions-and-end-wire")

let pad = TrackpadSurface()
pad.captureInputSender = { client.captureInputSender() }
pad.verticalSpan = 50
let beforePad = inputs(peer).count
pad.beginScroll(); pad.endScroll(momentumVelocity: CGPoint(x: 200, y: 300))
pad.momentum.step(); pad.momentum.stop()
check(events(since: beforePad) == [.scrollGesture(.began, x: 0.2, y: 0.3),
    .scrollGesture(.ended, x: 0.2, y: 0.3), .scrollGesture(.momentumBegan, x: 0.2, y: 0.3),
    .scroll(x: 0.2, y: 0.3, dx: 0.02, dy: 0.06), .scrollGesture(.momentumEnded, x: 0.2, y: 0.3)],
    "portrait-vertical-span-momentum-wire")

let typing = overlay(), beforeText = inputs(peer).count
typing.insertText("한글👩‍💻"); typing.deleteBackward()
check(events(since: beforeText) == [.text("한글👩‍💻"), .text("\u{8}")], "keyboard-unicode-delete-wire")
typing.latchedModifiers = .command
let beforeShortcut = inputs(peer).count
typing.insertText("s")
check(events(since: beforeShortcut) == KeyChord.press(0x16, with: .command), "keyboard-command-shortcut-wire")
check(inputs(peer).allSatisfy { $0.generation == "A" && $0.videoEpoch == epoch.id }, "all-wire-preserves-generation-and-video-epoch")

let stale = overlay(), stalePan = UIPanGestureRecognizer()
stalePan.state = .began; stale.handlePan(stalePan); client.flush()
client.cancel(); client.flush()
let beforeStale = inputs(peer).count
stalePan.translation = CGPoint(x: 0, y: 25); stalePan.state = .changed; stale.handlePan(stalePan)
stalePan.state = .ended; stale.handlePan(stalePan); stale.momentum.step(); stale.momentum.stop()
check(events(since: beforeStale).isEmpty, "revoked-admission-rejects-pan-and-coast")
print("gesture-wire \(checks - failures)/\(checks); failed \(failures)")
exit(failures == 0 ? 0 : 1)
