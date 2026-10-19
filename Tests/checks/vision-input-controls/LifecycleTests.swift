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
    GestureValue(first: contacts.first, second: .init(magnification: factor,
                 startLocation: CGPoint(x: 500, y: 500), time: Date(timeIntervalSinceReferenceDate: time)))
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
        var keys = Set<UInt16>(), buttons = Set<PointerAction>(), scrolling = false
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
                if phase == .began { valid = !scrolling && valid; scrolling = true }
                else if phase == .ended { valid = scrolling && valid; scrolling = false }
                else { valid = false }
            case .scroll, .text: break
            }
        }
        check(valid && keys.isEmpty && buttons.isEmpty && !scrolling, label)
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
    check(noChange.sent.isEmpty && noChange.state.admissions == admissions,
          "callback end reset disappear without change never admit phantom input")
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

    print("LIFECYCLE_ASSERTIONS \(checks - before)")
}
