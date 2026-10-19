import Foundation
import CoreGraphics
import StreamProtocol

var count = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name)
    count += 1
}
func near(_ a: CGPoint?, _ b: CGPoint) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) < 0.000001 && abs(a.y - b.y) < 0.000001
}
let geometry = VisionPointer.Geometry(bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), video: CGSize(width: 1000, height: 1000))
let fitted = VisionPointer.Geometry(bounds: CGRect(x: 10, y: 20, width: 100, height: 100), video: CGSize(width: 200, height: 100))
let viewport = VisionViewport()
let center = CGPoint(x: 0.5, y: 0.5)
check(viewport.point(CGPoint(x: 60, y: 70), in: fitted) == center, "origin and letterboxing")
check(viewport.point(CGPoint(x: 60, y: 25), in: fitted) == nil, "letterbox is not a click")
check(viewport.point(.zero, in: .init(bounds: .zero, video: .zero)) == nil, "no video means no input")
check(viewport.point(CGPoint(x: CGFloat.nan, y: 0), in: geometry) == nil, "invalid gesture")
check(viewport.point(.zero, in: .init(bounds: geometry.bounds, video: CGSize(width: CGFloat.infinity, height: 10))) == nil, "invalid frame")
check(viewport.point(CGPoint(x: 200, y: 0), in: fitted, clamp: true) == CGPoint(x: 1, y: 0), "outside drag clamps to the frame")
let anchor = CGPoint(x: 750, y: 250)
let enlarged = viewport.magnified(by: 2, at: anchor, in: geometry)!
check(enlarged.scale == 2 && enlarged.offset == CGSize(width: -250, height: 250), "zoom anchors exact centered transform")
check(near(enlarged.point(anchor, in: geometry), CGPoint(x: 0.75, y: 0.25)), "zoom anchor stays on the same video point")
check(near(enlarged.point(CGPoint(x: 250, y: 750), in: geometry), center), "zoom mapping reverses scale then offset")
check(enlarged.point(CGPoint(x: -1, y: 500), in: geometry) == nil, "offscreen content is not clickable")
check(enlarged.magnified(by: 0.1, at: anchor, in: geometry) == viewport, "inward gesture returns to one and clears offset")
check(viewport.magnified(by: 100, at: anchor, in: geometry)?.scale == 4, "zoom has a finite upper bound")
check(viewport.magnified(by: 0, at: anchor, in: geometry) == nil && viewport.magnified(by: .nan, at: anchor, in: geometry) == nil, "malformed zoom is rejected")
check(viewport.magnified(by: 2, at: CGPoint(x: 60, y: 25), in: fitted) == nil, "letterbox cannot anchor magnification")
let wideZoom = viewport.magnified(by: 1.5, at: CGPoint(x: 60, y: 70), in: fitted)!
check(wideZoom.point(CGPoint(x: 60, y: 25), in: fitted) == nil, "scaled letterbox still rejects clicks")
check(near(wideZoom.point(CGPoint(x: 60, y: 70), in: fitted), center), "nonzero origin zoom maps correctly")
for scale in [CGFloat(1), 1.25, 2, 4] {
    let zoom = viewport.magnified(by: scale, at: anchor, in: geometry)!
    let source = CGPoint(x: 0.6, y: 0.4)
    let rendered = CGPoint(x: geometry.bounds.midX + (source.x * 1000 - geometry.bounds.midX) * zoom.scale + zoom.offset.width,
                           y: geometry.bounds.midY + (source.y * 1000 - geometry.bounds.midY) * zoom.scale + zoom.offset.height)
    check(near(zoom.point(rendered, in: geometry), source), "render and inverse mapping agree at every bounded scale")
}
func sample(_ id: Int, _ time: TimeInterval, _ x: CGFloat = 500, _ y: CGFloat = 500,
            _ phase: VisionPointer.Sample.Phase = .active) -> VisionPointer.Sample {
    .init(id: id, timestamp: time, location: CGPoint(x: x, y: y), phase: phase)
}
func feed(_ pointer: inout VisionPointer, _ values: [VisionPointer.Sample], modifiers: KeyModifiers = []) -> [InputEvent] {
    pointer.receive(values, geometry: geometry, viewport: viewport, modifiers: modifiers)
}
var pointer = VisionPointer()
check(feed(&pointer, [sample(1, 0)]) == [.pointer(.move, x: 0.5, y: 0.5)], "pinch begin targets Mac pointer before any press")
check(feed(&pointer, [sample(1, 0.1, 500, 500, .ended)]) == [.pointer(.leftDown, x: 0.5, y: 0.5), .pointer(.leftUp, x: 0.5, y: 0.5)], "short pinch clicks once")
check(feed(&pointer, [sample(1, 0.2)]).isEmpty && feed(&pointer, [sample(1, 0.3, 500, 500, .ended)]).isEmpty, "ended ID cannot rearm or duplicate click")
check(feed(&pointer, [sample(2, 0.4, 500, 500, .ended)]).isEmpty, "a terminal with no beginning cannot click")
_ = feed(&pointer, [sample(3, 1)], modifiers: .control)
check(feed(&pointer, [sample(3, 1.8, 502, 501, .ended)]) == KeyChord.modifiersDown(.control) + [.pointer(.rightDown, x: 0.5, y: 0.5), .pointer(.rightUp, x: 0.5, y: 0.5)] + KeyChord.modifiersUp(.control), "stationary held release is a balanced contextual click")
_ = feed(&pointer, [sample(4, 2)])
let scroll = feed(&pointer, [sample(4, 2.1, 500, 600)])
check(scroll == [.scrollGesture(.began, x: 0.5, y: 0.5), .scroll(x: 0.5, y: 0.5, dx: 0, dy: 0.6 - 0.5)], "immediate downward motion starts natural scroll with no button down")
check(feed(&pointer, [sample(4, 3, 600, 700)]).count == 1, "scroll cannot turn into drag after hold deadline")
check(feed(&pointer, [sample(4, 3.1, 600, 700, .ended)]) == [.scrollGesture(.ended, x: 0.5, y: 0.5)], "scroll ends at original target without trailing click")
_ = feed(&pointer, [sample(5, 4)], modifiers: [.command, .shift])
check(feed(&pointer, [sample(5, 4.7, 600, 700)]) == KeyChord.modifiersDown([.command, .shift]) + [.pointer(.leftDown, x: 0.5, y: 0.5), .pointer(.move, x: 0.6, y: 0.7)], "held then moved pinch presses left once with snapshotted modifiers")
check(feed(&pointer, [sample(5, 4.6, 800, 800)]).isEmpty, "out of order active sample cannot move held pointer")
check(pointer.cancel() == [.pointer(.leftUp, x: 0.6, y: 0.7)] + KeyChord.modifiersUp([.command, .shift]), "cancel releases pointer before reverse modifier ups")
check(pointer.cancel().isEmpty && feed(&pointer, [sample(5, 4.8, 800, 800)]).isEmpty, "cancelled stroke cannot restart")
check(feed(&pointer, [sample(5, 4.9, 800, 800, .ended)]).isEmpty, "cancelled terminal cannot become click")
_ = feed(&pointer, [sample(6, 5)])
check(feed(&pointer, [sample(6, 5.1, 500, 500, .cancelled)]).isEmpty, "native cancelled pending pinch never clicks")
var released = VisionPointer()
_ = feed(&released, [sample(60, 0)])
_ = feed(&released, [sample(60, 0.7, 600, 700)])
check(feed(&released, [sample(60, 0.8, 700, 800, .ended)]) == [.pointer(.move, x: 0.7, y: 0.8), .pointer(.leftUp, x: 0.7, y: 0.8)], "native drag terminal moves then releases exactly once")
check(feed(&released, [sample(60, 0.9, 700, 800, .ended)]).isEmpty, "duplicate native drag terminal cannot release again")
_ = feed(&released, [sample(61, 1)], modifiers: .option)
_ = feed(&released, [sample(61, 1.7, 600, 700)])
check(feed(&released, [sample(61, 1.8, 900, 900, .cancelled)]) == [.pointer(.leftUp, x: 0.6, y: 0.7)] + KeyChord.modifiersUp(.option), "native drag cancellation releases at last accepted position without terminal motion")
_ = feed(&pointer, [sample(7, 6)])
_ = feed(&pointer, [sample(7, 6.1, 500, 600)])
check(feed(&pointer, [sample(8, 6.2, 700, 500)]) == [.scrollGesture(.ended, x: 0.5, y: 0.5)], "second hand cancels existing scroll")
check(feed(&pointer, [sample(8, 6.3, 700, 500, .ended)]).isEmpty, "second hand terminal owns no click")
check(feed(&pointer, [sample(7, 6.4, 700, 600)]).isEmpty && feed(&pointer, [sample(7, 6.5, 700, 600, .ended)]).isEmpty, "remaining hand after zoom cannot resume scroll or click")
for reversed in [false, true] {
    var competing = VisionPointer()
    _ = feed(&competing, [sample(10, 10)])
    let batch = [sample(10, 10.1, 500, 500, .ended), sample(11, 10.1, 700, 500)]
    check(feed(&competing, reversed ? Array(batch.reversed()) : batch).isEmpty, "same batch ending hand and starting hand suppress regardless of order")
    check(feed(&competing, [sample(11, 10.2, 700, 500, .ended)]).isEmpty, "competing final tail is inert")
}
var held = VisionPointer()
_ = feed(&held, [sample(20, 20)])
_ = feed(&held, [sample(20, 20.7, 600, 700)])
check(feed(&held, [sample(21, 20.8, 700, 500)]) == [.pointer(.leftUp, x: 0.6, y: 0.7)], "second hand releases held Mac button")
_ = feed(&held, [sample(20, 21, 600, 700, .ended), sample(21, 21, 700, 500, .ended)])
_ = feed(&held, [sample(22, 22)])
_ = feed(&held, [sample(22, 22.7, 600, 700)])
check(feed(&held, [sample(22, .nan, 600, 700)]) == [.pointer(.leftUp, x: 0.6, y: 0.7)], "invalid timestamp releases live button and inhibits its tail")
check(feed(&held, [sample(22, 23, 600, 700, .ended)]).isEmpty, "invalid sample cannot turn into a click later")
var outside = VisionPointer()
check(outside.receive([sample(30, 30, 60, 25)], geometry: fitted, viewport: viewport).isEmpty, "letterbox beginning is rejected")
check(outside.receive([sample(30, 30.1, 60, 70, .ended)], geometry: fitted, viewport: viewport).isEmpty, "letterbox start cannot migrate into a clickable image")
var scaled = VisionPointer()
check(scaled.receive([sample(31, 31, 750, 250)], geometry: geometry, viewport: enlarged) == [.pointer(.move, x: 0.75, y: 0.25)], "production reducer targets inverse transformed video coordinates")
check(scaled.receive([sample(31, 31.1, 750, 250, .ended)], geometry: geometry, viewport: enlarged) == [.pointer(.leftDown, x: 0.75, y: 0.25), .pointer(.leftUp, x: 0.75, y: 0.25)], "zoomed click uses the rendered content point")
var edge = VisionPointer()
_ = feed(&edge, [sample(32, 0, 999, 500)])
check(feed(&edge, [sample(32, 0.1, 1001, 500, .ended)]).isEmpty, "stationary release outside viewport cannot click clamped content")
check(VisionPointer.isRelease(.key(hidUsage: 227, down: false, modifiers: 0)), "inactive hardware key-up is admitted")
check(!VisionPointer.isRelease(.key(hidUsage: 227, down: true, modifiers: 0)), "inactive key-down is refused")
check(VisionPointer.isRelease(.pointer(.leftUp, x: 0.5, y: 0.5)), "gesture cancellation may release when inactive")
let queue = DispatchQueue(label: "vision.fence.checks")
let peer = NSObject(), stranger = NSObject()
let fence = VisionInputFence(queue: queue)
queue.sync {
    var writes: [String] = ["release"]
    var results: [Bool] = []
    let id = fence.begin(peer: ObjectIdentifier(peer), timeout: 0.1, send: { _ in writes.append("ping") }, finished: { results.append($0); writes.append("transition") })
    check(writes == ["release", "ping"], "transition waits until the host reads the release")
    check(!fence.receive(id, peer: ObjectIdentifier(stranger)), "another connection cannot acknowledge input")
    check(results.isEmpty, "wrong peer leaves transition pending")
    check(fence.receive(id, peer: ObjectIdentifier(peer)), "matching echo settles the fence")
    check(writes == ["release", "ping", "transition"] && results == [true], "transition follows acknowledged release")
    check(!fence.receive(id, peer: ObjectIdentifier(peer)), "duplicate echo cannot replay transition")
}
let expired = DispatchSemaphore(value: 0)
queue.sync {
    fence.begin(peer: ObjectIdentifier(peer), timeout: 0.03, send: { _ in }, finished: { ok in
        check(!ok, "missing echo refuses transition")
        expired.signal()
    })
}
check(expired.wait(timeout: .now() + 2) == .success, "fence has a bounded deadline")
var transition = VisionTransition()
let ticket = transition.request(.desktop)!
check(transition.isPending, "source transition owns one fence")
check(transition.request(.disconnect) == nil, "disconnect reuses the pending release fence")
check(transition.settle(ticket, confirmed: true) == .disconnect, "closing the window supersedes source selection")
check(transition.settle(ticket, confirmed: true) == nil, "receipt cannot repeat a transition")
let obsolete = transition.request(.desktop)!
transition.cancel()
let replacement = transition.request(.disconnect)!
check(transition.settle(obsolete, confirmed: true) == nil && transition.isPending, "stale receipt cannot consume replacement intent")
check(transition.settle(replacement, confirmed: false) == nil, "missing receipt performs neither source nor disconnect")
let disconnect = transition.request(.disconnect)!
check(transition.request(.desktop) == nil, "source cannot supersede disconnect")
check(transition.settle(disconnect, confirmed: true) == .disconnect, "disconnect keeps priority")
print("Vision input: \(count) behavioral checks passed")
