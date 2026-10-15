import Foundation
import CoreGraphics
import StreamProtocol

var count = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name)
    count += 1
}
let video = CGSize(width: 200, height: 100)
let bounds = CGRect(x: 10, y: 20, width: 100, height: 100)
let center = CGPoint(x: 0.5, y: 0.5)
check(VisionPointer.point(CGPoint(x: 60, y: 70), bounds: bounds, video: video) == center, "origin and letterboxing")
check(VisionPointer.point(CGPoint(x: 60, y: 25), bounds: bounds, video: video) == nil, "letterbox is not a click")
check(VisionPointer.point(.zero, bounds: bounds, video: .zero) == nil, "no video means no input")
check(VisionPointer.point(CGPoint(x: CGFloat.nan, y: 0), bounds: bounds, video: video) == nil, "invalid gesture")
check(VisionPointer.point(.zero, bounds: bounds, video: CGSize(width: CGFloat.infinity, height: 10)) == nil, "invalid frame")
check(VisionPointer.point(CGPoint(x: 200, y: 0), bounds: bounds, video: video, clamp: true) == CGPoint(x: 1, y: 0), "outside drag clamps to the frame")
var pointer = VisionPointer()
check(pointer.tap(center, mode: .right) == [.pointer(.rightDown, x: 0.5, y: 0.5), .pointer(.rightUp, x: 0.5, y: 0.5)], "right click emits no left event")
check(pointer.tap(center, mode: .pointer) == [.pointer(.leftDown, x: 0.5, y: 0.5), .pointer(.leftUp, x: 0.5, y: 0.5)], "short pinch clicks once")
check(pointer.tap(center, mode: .scroll).isEmpty, "scroll tap does not click")
let next = CGPoint(x: 0.7, y: 0.8)
check(pointer.drag(from: center, to: next, mode: .pointer) == [.pointer(.leftDown, x: 0.5, y: 0.5), .pointer(.move, x: 0.7, y: 0.8)], "press precedes drag motion")
check(pointer.tap(next, mode: .pointer).isEmpty, "drag cannot also click")
check(pointer.drag(from: center, to: center, mode: .pointer) == [.pointer(.move, x: 0.5, y: 0.5)], "drag does not press twice")
check(pointer.end() == [.pointer(.leftUp, x: 0.5, y: 0.5)], "cancellation releases held button")
check(pointer.end().isEmpty, "duplicate cancellation is inert")
let scroll = pointer.drag(from: center, to: next, mode: .scroll)
check(scroll.count == 2 && scroll[0] == .scrollGesture(.began, x: 0.5, y: 0.5), "scroll opens before delta")
check(pointer.end() == [.scrollGesture(.ended, x: 0.5, y: 0.5)], "cancel closes scroll at its anchor")
check(pointer.end().isEmpty, "scroll end cannot replay")
check(pointer.drag(from: center, to: next, mode: .right).isEmpty, "right mode cannot start left drag")
check(pointer.end().isEmpty, "ignored drag owns no button")
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
