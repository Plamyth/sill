import Foundation
import Network
import StreamProtocol
import SwiftUI

private func contact(_ time: Double, _ x: Double = 300, _ y: Double = 400,
                     _ phase: SpatialEventCollection.Event.Phase = .active, id: Int = 1) -> GestureValue {
    GestureValue(first: [.init(id: id, timestamp: time, kind: .indirectPinch,
                              location: CGPoint(x: x, y: y), phase: phase)])
}

private func zoom(_ factor: CGFloat, _ time: Double, contacts: GestureValue = GestureValue()) -> GestureValue {
    GestureValue(first: contacts.first, second: .init(first: .init(magnification: factor,
                 startLocation: CGPoint(x: 500, y: 500), time: Date(timeIntervalSinceReferenceDate: time))))
}

private func turn(_ degrees: Double, _ time: Double) -> GestureValue {
    GestureValue(second: .init(second: .init(rotation: .init(degrees: degrees), time: Date(timeIntervalSinceReferenceDate: time))))
}

private final class LifecycleRig {
    let client = StreamClient()
    let input = VisionInputSession()
    let peer = NWConnection()
    let state = CallbackState()
    let view: SpatialCallbacks

    init() {
        view = SpatialCallbacks(input: input, geometry: testGeometry, state: state)
        input.bind(client)
        client.connection = peer
        seedLegacy(client, peer)
        input.allowed = true
        view.geometryChanged(testGeometry)
        client.queue.sync {}
    }

    var sent: [InputEvent] { client.queue.sync {}; return events(peer) }

    func drag(modifier: Bool = true) {
        if modifier { input.toggle(.command) }
        view.changed(contact(0))
        view.changed(contact(0.8, 600, 700))
        _ = sent
    }

    func balanced(_ label: String) {
        var keys = Set<UInt16>(), buttons = Set<PointerAction>(), scrolling = false, coasting = false
        var valid = true
        for event in sent {
            switch event {
            case .key(let key, let down, _):
                if down { valid = keys.insert(key).inserted && valid }
                else { valid = (keys.remove(key) != nil) && valid }
            case .pointer(let action, _, _):
                switch action {
                case .leftDown, .rightDown: valid = buttons.insert(action).inserted && valid
                case .leftUp: valid = (buttons.remove(.leftDown) != nil) && valid
                case .rightUp: valid = (buttons.remove(.rightDown) != nil) && valid
                case .move: break
                }
            case .scrollGesture(let phase, _, _):
                if phase == .began { valid = !scrolling && !coasting && valid; scrolling = true }
                else if phase == .ended { valid = scrolling && valid; scrolling = false }
                else if phase == .momentumBegan { valid = !scrolling && !coasting && valid; coasting = true }
                else if phase == .momentumEnded { valid = coasting && valid; coasting = false }
                else { valid = false }
            case .scroll, .text: break
            }
        }
        check(valid && keys.isEmpty && buttons.isEmpty && !scrolling && !coasting, label)
    }
}

func runLifecycleTests() {
    let before = checks
    let click = LifecycleRig()
    click.view.changed(contact(0))
    check(click.state.revision == click.input.gestureRevision, "callback changed captures session revision")
    click.view.ended(contact(0.1, 300, 400, .ended))
    check(click.sent == [.pointer(.move, x: 0.3, y: 0.4), .pointer(.leftDown, x: 0.3, y: 0.4),
                         .pointer(.leftUp, x: 0.3, y: 0.4)], "callback ended dispatches terminal contact before cleanup")
    check(click.state.revision == nil, "callback ended clears view revision")
    let endedRevision = click.input.gestureRevision
    click.view.ended(contact(0.2, 300, 400, .ended))
    click.view.recognizingChanged(false)
    check(click.sent.count == 3 && click.input.gestureRevision == endedRevision,
          "callback duplicate end and reset after end have no effect")
    click.balanced("callback click balances transmitted button")

    let noChange = LifecycleRig()
    let admissions = noChange.state.admissions
    noChange.view.ended(contact(0, 300, 400, .ended))
    noChange.view.recognizingChanged(false)
    noChange.view.disappeared()
    check(noChange.sent.isEmpty && noChange.state.admissions == admissions + 1,
          "callback empty disappearance admits cleanup without phantom input")
    noChange.view.changed(GestureValue())
    noChange.view.ended(GestureValue())
    check(noChange.sent.isEmpty && noChange.state.revision == nil, "callback empty optional values clean up without input")

    let scroll = LifecycleRig()
    scroll.input.toggle(.option)
    scroll.view.changed(contact(0))
    scroll.view.changed(contact(0.1, 400, 600))
    scroll.view.ended(contact(0.2, 500, 700, .ended))
    check(scroll.sent == [.pointer(.move, x: 0.3, y: 0.4)] + KeyChord.modifiersDown(.option) + [
        .scrollGesture(.began, x: 0.3, y: 0.4), .scroll(x: 0.3, y: 0.4, dx: 0.1, dy: 0.2),
        .scroll(x: 0.3, y: 0.4, dx: 0.1, dy: 0.1), .scrollGesture(.ended, x: 0.3, y: 0.4)
    ] + KeyChord.modifiersUp(.option), "callback scroll dispatches final delta and balanced modifier")
    scroll.balanced("callback scroll balances transmitted boundaries")

    let drag = LifecycleRig()
    drag.drag()
    check(drag.sent == [.pointer(.move, x: 0.3, y: 0.4)] + KeyChord.modifiersDown(.command) + [
        .pointer(.leftDown, x: 0.3, y: 0.4), .pointer(.move, x: 0.6, y: 0.7)
    ], "callback hold drag transmits held button and modifier")
    drag.view.ended(contact(0.9, 700, 800, .ended))
    check(Array(drag.sent.suffix(3)) == [.pointer(.move, x: 0.7, y: 0.8), .pointer(.leftUp, x: 0.7, y: 0.8)] +
          KeyChord.modifiersUp(.command), "callback drag end preserves final target before release")
    drag.balanced("callback drag balances transmitted button and modifier")

    let hold = LifecycleRig()
    hold.view.changed(contact(0))
    hold.view.ended(contact(0.8, 300, 400, .ended))
    check(hold.sent == [.pointer(.move, x: 0.3, y: 0.4), .pointer(.rightDown, x: 0.3, y: 0.4),
                        .pointer(.rightUp, x: 0.3, y: 0.4)], "callback stationary hold emits balanced right click")
    let doubleTap = LifecycleRig()
    doubleTap.view.changed(contact(0))
    doubleTap.view.ended(contact(0.1, 300, 400, .ended))
    doubleTap.view.changed(contact(0.2, id: 2))
    doubleTap.view.ended(contact(0.3, 300, 400, .ended, id: 2))
    let clickEvents: [InputEvent] = [.pointer(.move, x: 0.3, y: 0.4), .pointer(.leftDown, x: 0.3, y: 0.4),
                               .pointer(.leftUp, x: 0.3, y: 0.4)]
    check(doubleTap.sent == clickEvents + clickEvents, "two quick native pinches send exactly two balanced clicks")

    let lateScroll = LifecycleRig()
    lateScroll.view.changed(contact(0))
    lateScroll.view.changed(contact(0.8, 500, 600))
    lateScroll.view.ended(contact(0.9, 500, 600, .ended))
    check(lateScroll.sent == [.pointer(.move, x: 0.3, y: 0.4),
        .scrollGesture(.began, x: 0.3, y: 0.4), .scroll(x: 0.3, y: 0.4, dx: 0.2, dy: 0.2),
        .scrollGesture(.ended, x: 0.3, y: 0.4)], "holding before motion still scrolls both axes without mouse down")

    for degrees in [-40.0, 40.0] {
        let rotation = LifecycleRig()
        rotation.view.changed(turn(degrees / 2, 0.1))
        rotation.view.changed(turn(degrees, 0.2))
        check(rotation.sent.isEmpty, "rotation waits until native completion")
        rotation.view.ended(turn(degrees, 0.3))
        let direction = degrees > 0 ? 1 : -1
        check(rotation.sent.isEmpty && rotation.client.steppedDisplays == [direction],
              "rotation requests exactly one monitor in its signed direction without keyboard shortcuts")
        rotation.view.ended(turn(degrees * 2, 0.4))
        check(rotation.sent.isEmpty && rotation.client.steppedDisplays == [direction],
              "duplicate rotation completion cannot switch twice")
        rotation.balanced("monitor rotation leaves no held input")
    }
    for cancel in [false, true] {
        let rotation = LifecycleRig()
        rotation.view.changed(turn(cancel ? 40 : 8, 0.1))
        if cancel { rotation.view.recognizingChanged(false) }
        else { rotation.view.ended(turn(8, 0.2)) }
        check(rotation.sent.isEmpty && rotation.client.steppedDisplays.isEmpty,
              "rotation jitter or cancellation never switches a monitor")
    }
    let zoomTurn = LifecycleRig()
    zoomTurn.view.changed(turn(40, 0.1))
    zoomTurn.view.changed(zoom(1.5, 0.2))
    zoomTurn.view.ended(turn(50, 0.3))
    check(zoomTurn.sent.isEmpty && zoomTurn.client.steppedDisplays.isEmpty && zoomTurn.input.viewport.scale == 1.5,
          "meaningful zoom wins over incidental rotation")
    for factor in [0.92, 1.08] {
        for returnsToStart in [false, true] {
            let boundaryZoom = LifecycleRig()
            boundaryZoom.view.changed(turn(40, 0.1))
            boundaryZoom.view.changed(zoom(factor, 0.2))
            if returnsToStart { boundaryZoom.view.changed(zoom(1, 0.3)) }
            boundaryZoom.view.ended(turn(40, 0.4))
            check(boundaryZoom.client.steppedDisplays.isEmpty,
                  "eight percent zoom boundary and its history suppress rotation")
        }
    }
    for terminal in [false, true] {
        for invalid in [contact(0.3, 300, 400, .cancelled), contact(0.3, .nan, 400), contact(.infinity)] {
            let rejected = LifecycleRig()
            rejected.view.changed(contact(0))
            _ = rejected.sent
            rejected.view.changed(turn(40, 0.1))
            var transform = turn(50, 0.3)
            transform.first = invalid.first
            transform.second?.first = zoom(2, 0.3).second?.first
            if terminal { rejected.view.ended(transform) }
            else { rejected.view.changed(transform); rejected.view.ended(turn(50, 0.4)) }
            var drained = false
            DispatchQueue.main.async { drained = true }
            waitMain { drained }
            check(rejected.client.steppedDisplays.isEmpty && rejected.input.viewport.scale == 1 &&
                  rejected.client.cursorVisible == nil,
                  "cancelled or invalid contact rejects transforms and retires queued cursor")
            rejected.balanced("invalid native contact leaves no held input")
        }
    }
    let invalidTurn = LifecycleRig()
    invalidTurn.view.changed(turn(40, 0.1))
    invalidTurn.view.ended(turn(.nan, 0.2))
    check(invalidTurn.sent.isEmpty && invalidTurn.client.steppedDisplays.isEmpty,
          "invalid terminal rotation cancels a previously valid angle")
    let changedInventory = LifecycleRig()
    changedInventory.view.changed(turn(40, 0.1))
    changedInventory.client.visionDisplaySelection.token = .init(peerEpoch: UUID(), window: UUID(),
        admission: UUID(), inventory: UUID(), revision: 2)
    changedInventory.view.ended(turn(40, 0.2))
    check(changedInventory.client.steppedDisplays.isEmpty,
          "monitor inventory change during rotation cancels the original gesture")
    for delivered in [false, true] {
        let cancelledCursor = LifecycleRig()
        cancelledCursor.view.changed(contact(0))
        _ = cancelledCursor.sent
        if delivered { waitMain { cancelledCursor.client.cursorVisible != nil } }
        cancelledCursor.view.recognizingChanged(false)
        var drained = false
        DispatchQueue.main.async { drained = true }
        waitMain { drained }
        check(cancelledCursor.client.cursorVisible == nil,
              "native cancellation hides spatial cursor before or after its display callback")
    }

    let magnify = LifecycleRig()
    magnify.view.changed(contact(0))
    magnify.view.changed(zoom(2, 0.1, contacts: contact(0.1, 600, 700)))
    check(magnify.sent == [.pointer(.move, x: 0.3, y: 0.4)] && magnify.input.viewport.scale == 2,
          "callback changed magnification wins before contact movement")
    magnify.view.ended(zoom(3, 0.2, contacts: contact(0.2, 600, 700, .ended)))
    check(magnify.sent.count == 1 && magnify.input.viewport.scale == 3 && magnify.state.revision == nil,
          "callback ended magnification keeps contact tail suppressed")
    magnify.view.changed(contact(0.3, 600, 700, .ended))
    magnify.view.ended(contact(0.4, 600, 700, .ended))
    check(magnify.sent.count == 1, "callback retired contact tail cannot create click")
    magnify.balanced("callback magnification has no unmatched releases")

    let endZoom = LifecycleRig()
    endZoom.view.changed(contact(0))
    endZoom.view.ended(zoom(2, 0.1, contacts: contact(0.1, 300, 400, .ended)))
    check(endZoom.sent == [.pointer(.move, x: 0.3, y: 0.4)] && endZoom.input.viewport.scale == 2,
          "callback end only magnification wins before click tail")

    let zoomDrag = LifecycleRig()
    zoomDrag.drag()
    zoomDrag.view.changed(zoom(2, 1, contacts: contact(1, 700, 800)))
    check(Array(zoomDrag.sent.suffix(2)) == [.pointer(.leftUp, x: 0.6, y: 0.7)] + KeyChord.modifiersUp(.command),
          "callback zoom arbitration cancels held drag before contact tail")
    zoomDrag.view.ended(zoom(2.5, 1.1))
    zoomDrag.balanced("callback zoom arbitration balances drag debt")

    for terminal in ["recognizing", "disappear"] {
        let rig = LifecycleRig()
        rig.drag()
        let count = rig.sent.count
        rig.view.recognizingChanged(true)
        check(rig.sent.count == count && rig.state.revision != nil, "callback active recognition preserves held drag")
        if terminal == "recognizing" { rig.view.recognizingChanged(false) }
        else { rig.view.disappeared() }
        check(Array(rig.sent.suffix(2)) == [.pointer(.leftUp, x: 0.6, y: 0.7)] + KeyChord.modifiersUp(.command),
              "callback \(terminal) releases held button before modifier")
        check(rig.state.revision == nil, "callback \(terminal) clears view revision")
        let released = rig.sent
        rig.view.ended(contact(1, 600, 700, .ended))
        rig.view.recognizingChanged(false)
        rig.view.disappeared()
        check(rig.sent == released, "callback \(terminal) before end is idempotent and cannot click")
        rig.balanced("callback \(terminal) balances transmitted debt")
    }

    let pendingReset = LifecycleRig()
    pendingReset.view.changed(contact(0))
    pendingReset.view.recognizingChanged(false)
    pendingReset.view.ended(contact(0.1, 300, 400, .ended))
    check(pendingReset.sent == [.pointer(.move, x: 0.3, y: 0.4)], "callback reset before pending end never invents click")

    for boundary in ["geometry", "source", "admission", "revision"] {
        let rig = LifecycleRig()
        rig.drag()
        let oldView = rig.view
        let queued: [() -> Void] = [
            { oldView.changed(contact(1, 800, 900)) },
            { oldView.ended(contact(1.1, 800, 900, .ended)) },
            { oldView.recognizingChanged(false) }, { oldView.disappeared() }
        ]
        switch boundary {
        case "geometry":
            let geometry = VisionPointer.Geometry(bounds: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                                   video: CGSize(width: 2000, height: 1000))
            oldView.geometryChanged(geometry)
        case "source":
            _ = rig.client.catalog(catalog(.window(42), "callback-new-source"), from: rig.peer)
        case "admission": rig.input.allowed = false; rig.state.admitted = false
        default: rig.input.releaseAll()
        }
        let cancelled = rig.sent
        let revision = rig.input.gestureRevision
        queued.forEach { $0() }
        check(rig.sent == cancelled && rig.input.gestureRevision == revision,
              "callback queued old values cannot cross \(boundary) boundary")
        check(rig.state.revision == nil, "callback old end clears view revision after \(boundary) change")
        rig.balanced("callback \(boundary) change balances original held debt")
        rig.input.allowed = true; rig.state.admitted = true
        let currentGeometry = boundary == "geometry" ? VisionPointer.Geometry(
            bounds: CGRect(x: 0, y: 0, width: 2000, height: 1000), video: CGSize(width: 2000, height: 1000)) : testGeometry
        let next = SpatialCallbacks(input: rig.input, geometry: currentGeometry, state: rig.state)
        next.changed(contact(2, 300, 400, .active, id: 2))
        next.ended(contact(2.1, 300, 400, .ended, id: 2))
        check(rig.sent.count == cancelled.count + 3, "callback fresh gesture admitted after \(boundary) change")
        rig.balanced("callback fresh gesture after \(boundary) balances debt")
    }

    let denied = LifecycleRig()
    denied.state.admitted = false
    denied.view.changed(zoom(2, 0, contacts: contact(0)))
    check(denied.state.revision != nil && denied.sent.isEmpty && denied.input.viewport.scale == 1,
          "callback denied change captures ticket without dispatching input or zoom")
    denied.view.ended(zoom(3, 0.1, contacts: contact(0.1, 300, 400, .ended)))
    check(denied.state.revision == nil && denied.sent.isEmpty && denied.input.viewport.scale == 1,
          "callback denied end clears ticket without dispatch")
    denied.view.changed(contact(1))
    denied.view.recognizingChanged(false)
    check(denied.state.revision == nil && denied.sent.isEmpty, "callback denied recognition reset clears ticket without dispatch")
    denied.view.changed(contact(2))
    denied.view.disappeared()
    check(denied.state.revision == nil && denied.sent.isEmpty, "callback denied disappearance clears ticket without dispatch")
    let changedGeometry = VisionPointer.Geometry(bounds: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                                  video: CGSize(width: 2000, height: 1000))
    denied.view.geometryChanged(changedGeometry)
    denied.state.admitted = true
    denied.view.changed(contact(3))
    denied.view.ended(contact(3.1, 300, 400, .ended))
    check(denied.sent.count == 3, "callback denied geometry leaves original admitted geometry usable")
    denied.balanced("callback denied sequence has no phantom input or release")

    runMomentumTests()
    print("LIFECYCLE_ASSERTIONS \(checks - before)")
}

private func startFlick(_ rig: LifecycleRig) {
    rig.view.changed(contact(0))
    rig.view.changed(contact(0.05, 300, 500))
    rig.view.ended(contact(0.06, 300, 510, .ended))
}

private func momentumStarted(_ rig: LifecycleRig) -> Bool {
    rig.sent.contains { if case .scrollGesture(.momentumBegan, _, _) = $0 { return true }; return false }
}

private func lastScroll(_ rig: LifecycleRig) -> (x: Double, y: Double, dx: Double, dy: Double)? {
    for event in rig.sent.reversed() {
        if case let .scroll(x, y, dx, dy) = event { return (x, y, dx, dy) }
    }
    return nil
}

private func runMomentumTests() {
    let before = checks
    check(CADisplayLink.active.isEmpty, "legacy gestures leave no momentum driver running")
    let flick = LifecycleRig()
    startFlick(flick)
    check(momentumStarted(flick) && CADisplayLink.active.count == 1,
          "normal completed flick starts one existing momentum engine")
    let first = lastScroll(flick)!
    check(first.x == 0.3 && first.y == 0.4 && first.dx == 0 && abs(first.dy - 1.0 / 60) < 0.000001,
          "flick immediately continues latest raw velocity at original remote target")
    check(flick.state.revision == nil, "completed callback releases view ticket while coast continues")
    MomentumClock.advance()
    let second = lastScroll(flick)!
    check(second.dy > 0 && second.dy < first.dy, "existing engine decays flick without reversing direction")
    for _ in 0..<240 { MomentumClock.advance() }
    check(CADisplayLink.active.isEmpty && flick.sent.last == .scrollGesture(.momentumEnded, x: 0.3, y: 0.4),
          "flick converges to a balanced end within four simulated seconds")
    let completed = flick.sent
    MomentumClock.advance()
    check(flick.sent == completed, "finished momentum sends no further remote input")
    flick.balanced("natural coast has balanced scroll and momentum boundaries")

    for scenario in ["slow", "pause", "cancel", "second-hand", "drag", "modifier", "stale-end", "recognizer-reset", "jump"] {
        let rig = LifecycleRig()
        if scenario == "modifier" { rig.input.toggle(.option) }
        if scenario == "drag" { rig.input.toggle(.command) }
        rig.view.changed(contact(0))
        if scenario == "slow" {
            rig.view.changed(contact(0.1, 300, 410))
            rig.view.ended(contact(0.11, 300, 411, .ended))
        } else if scenario == "drag" {
            rig.view.changed(contact(0.8, 300, 500))
            rig.view.ended(contact(0.81, 300, 510, .ended))
        } else {
            rig.view.changed(contact(0.05, 300, 500))
            switch scenario {
            case "pause": rig.view.ended(contact(0.3, 300, 500, .ended))
            case "cancel": rig.view.ended(contact(0.06, 300, 510, .cancelled))
            case "second-hand":
                rig.view.changed(contact(0.055, 700, 500, id: 2))
                rig.view.ended(GestureValue(first: [
                    .init(id: 1, timestamp: 0.06, kind: .indirectPinch, location: CGPoint(x: 300, y: 510), phase: .ended),
                    .init(id: 2, timestamp: 0.06, kind: .indirectPinch, location: CGPoint(x: 700, y: 500), phase: .ended)]))
            case "stale-end": rig.view.ended(contact(0.04, 300, 510, .ended))
            case "recognizer-reset":
                rig.view.changed(contact(0.06, 300, 510, .ended))
                rig.view.recognizingChanged(false)
                rig.view.ended(contact(0.07, 300, 520, .ended))
            case "jump": rig.view.ended(contact(0.06, 300, 900, .ended))
            default: rig.view.ended(contact(0.06, 300, 510, .ended))
            }
        }
        check(!momentumStarted(rig) && CADisplayLink.active.isEmpty,
              "\(scenario) never turns into an unintended flick")
        rig.balanced("\(scenario) leaves no held remote input")
    }

    for boundary in ["pinch", "magnify", "geometry", "source", "route", "admission", "disappear", "key", "overlay"] {
        let rig = LifecycleRig()
        startFlick(rig)
        check(momentumStarted(rig), "\(boundary) starts with a real coast")
        var replacement: NWConnection?
        switch boundary {
        case "pinch": rig.view.changed(contact(1, 500, 500, id: 2))
        case "magnify": rig.view.changed(zoom(2, 1))
        case "geometry": rig.view.geometryChanged(.init(bounds: CGRect(x: 0, y: 0, width: 1200, height: 1000), video: testGeometry.video))
        case "source": _ = rig.client.catalog(catalog(.window(42), "coast-new-source"), from: rig.peer)
        case "route":
            let peer = NWConnection()
            replacement = peer
            rig.client.connection = peer
            seedLegacy(rig.client, peer)
        case "admission": rig.input.allowed = false
        case "disappear": rig.view.disappeared()
        case "key": rig.input.press(.escape)
        default: rig.input.overlayInput(.text("관성 취소"))
        }
        check(CADisplayLink.active.isEmpty, "\(boundary) immediately invalidates coast driver")
        let stopped = rig.sent
        for _ in 0..<5 { MomentumClock.advance() }
        check(rig.sent == stopped && replacement.map { events($0).isEmpty } != false,
              "\(boundary) timer tail never reaches original or replacement target")
        if boundary == "pinch" { rig.view.ended(contact(1.1, 500, 500, .ended, id: 2)) }
        if boundary == "magnify" { rig.view.ended(zoom(2, 1.1)) }
        rig.balanced("\(boundary) cancels exactly one momentum boundary")
    }

    let enlarged = LifecycleRig()
    enlarged.input.magnify(2, at: CGPoint(x: 500, y: 500), time: 0,
                          geometry: testGeometry, revision: enlarged.input.gestureRevision)
    enlarged.input.finishGesture(revision: enlarged.input.gestureRevision)
    startFlick(enlarged)
    let scaled = lastScroll(enlarged)!
    check(scaled.x == 0.4 && scaled.y == 0.45 && abs(scaled.dy - first.dy) < 0.000001,
          "zoomed flick keeps inverse target and unscaled physical scroll speed")
    enlarged.view.disappeared()
    enlarged.balanced("zoomed coast ends when its input surface disappears")
    check(CADisplayLink.active.isEmpty, "all inertial scroll drivers are released")
    print("MOMENTUM_ASSERTIONS \(checks - before)")
}
