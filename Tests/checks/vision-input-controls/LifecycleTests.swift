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

private let monitorRows = [
    DisplayInfo(id: 11, name: "Mac A", width: 1920, height: 1080, isMain: true),
    DisplayInfo(id: 22, name: "Mac B", width: 1920, height: 1080, isMain: false),
    DisplayInfo(id: 33, name: "Mac C", width: 1920, height: 1080, isMain: false)
]

private func monitorCatalog(_ rows: [DisplayInfo] = monitorRows, inventory: UUID = UUID()) -> WindowList {
    WindowList(macName: "Fixture Mac", windows: [], active: .desktop, displaySelection: 1,
               displays: rows, displayInventoryID: inventory, activeDisplayID: rows.first?.id,
               desktopSelectionRequired: false)
}

private final class LifecycleRig {
    let client = StreamClient()
    let input = VisionInputSession()
    let peer = NWConnection()
    let state = CallbackState()
    let view: SpatialCallbacks

    init() {
        let reset = VisionAudioGain.shared.begin(owner: UUID())
        _ = VisionAudioGain.shared.preview(ticket: reset, degrees: 180)
        VisionAudioGain.shared.end(ticket: reset, commit: true)
        view = SpatialCallbacks(input: input, geometry: testGeometry, state: state)
        input.bind(client)
        client.connection = peer
        seedLegacy(client, peer)
        client.visionDisplaySelection.admit(lease: VisionWindowLease(window: UUID()), foreground: true)
        client.visionDisplaySelection.observe(.init(monitorCatalog()))
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

    for reversed in [false, true] {
        let coalesced = LifecycleRig()
        coalesced.view.changed(contact(0, id: 71))
        let terminal = contact(0.10, 300, 400, .ended, id: 71).first![0]
        let next = contact(0.12, id: 72).first![0]
        let batch = reversed ? [next, terminal] : [terminal, next]
        coalesced.view.changed(GestureValue(first: batch))
        coalesced.view.ended(contact(0.22, 300, 400, .ended, id: 72))
        let count = coalesced.sent.filter { if case .pointer(.leftDown, _, _) = $0 { return true }; return false }.count
        FileHandle.standardOutput.write(Data("native temporal pinch handoff reversed=\(reversed) clicks=\(count) expected=2\n".utf8))
        check(coalesced.sent == clickEvents + clickEvents,
              "nonoverlapping native pinch batch retains two clicks in either collection order")
        coalesced.balanced("coalesced native pinches balance both click pairs")
    }

    let recovered = LifecycleRig()
    recovered.view.changed(contact(0, id: 71))
    recovered.view.changed(contact(0.02, id: 72))
    recovered.view.changed(GestureValue(first: [
        contact(0.10, 300, 400, .ended, id: 71).first![0],
        contact(0.11, 300, 400, .ended, id: 72).first![0],
        contact(0.12, id: 73).first![0]
    ]))
    recovered.view.ended(contact(0.22, 300, 400, .ended, id: 73))
    let recoveredClicks = recovered.sent.filter {
        if case .pointer(.leftDown, _, _) = $0 { return true }; return false
    }.count
    FileHandle.standardOutput.write(Data("native temporal overlap recovery clicks=\(recoveredClicks) expected=1\n".utf8))
    check(recovered.sent == [.pointer(.move, x: 0.3, y: 0.4)] + clickEvents,
          "native pinch after completed overlapping contacts is admitted in the same collection")
    recovered.balanced("native overlap recovery balances only the new click")

    let intervalOrders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    for order in intervalOrders {
        for nextStart in [0.105, 0.11, 0.12] {
            let rig = LifecycleRig()
            rig.view.changed(contact(0, id: 71))
            rig.view.changed(contact(0.02, id: 72))
            let batch = [contact(0.10, 300, 400, .ended, id: 71).first![0],
                         contact(0.11, 300, 400, .ended, id: 72).first![0],
                         contact(nextStart, id: 73).first![0]]
            rig.view.changed(GestureValue(first: order.map { batch[$0] }))
            rig.view.ended(contact(0.22, 300, 400, .ended, id: 73))
            let expected = [.pointer(.move, x: 0.3, y: 0.4)] + (nextStart > 0.11 ? clickEvents : [])
            check(rig.sent == expected,
                  "overlap and equal-time handoffs stay suppressed while a later pinch survives every collection order")
            rig.balanced("interval boundary collection balances its admitted click")
        }
    }

    for reversed in [false, true] {
        let chain = LifecycleRig()
        chain.view.changed(contact(0, id: 81))
        chain.view.changed(contact(0.02, id: 82))
        let batch = [contact(0.10, 300, 400, .ended, id: 81).first![0],
                     contact(0.11, 300, 400, .ended, id: 82).first![0],
                     contact(0.105, id: 83).first![0],
                     contact(0.15, id: 84).first![0]]
        chain.view.changed(GestureValue(first: reversed ? Array(batch.reversed()) : batch))
        let ends = [contact(0.20, 300, 400, .ended, id: 83).first![0],
                    contact(0.21, 300, 400, .ended, id: 84).first![0],
                    contact(0.22, id: 85).first![0]]
        chain.view.changed(GestureValue(first: reversed ? Array(ends.reversed()) : ends))
        chain.view.ended(contact(0.32, 300, 400, .ended, id: 85))
        check(chain.sent == [.pointer(.move, x: 0.3, y: 0.4)] + clickEvents,
              "transitively overlapping native contacts stay suppressed until the entire live chain ends")
        chain.balanced("overlap chain admits only the independent final click")

        let surrounded = LifecycleRig()
        surrounded.view.changed(contact(0, id: 91))
        let middle = [contact(0.10, 300, 400, .ended, id: 91).first![0],
                      contact(0.12, id: 92).first![0], contact(0.13, id: 93).first![0]]
        surrounded.view.changed(GestureValue(first: reversed ? Array(middle.reversed()) : middle))
        let final = [contact(0.20, 300, 400, .ended, id: 92).first![0],
                     contact(0.21, 300, 400, .ended, id: 93).first![0],
                     contact(0.22, id: 94).first![0]]
        surrounded.view.changed(GestureValue(first: reversed ? Array(final.reversed()) : final))
        surrounded.view.ended(contact(0.32, 300, 400, .ended, id: 94))
        check(surrounded.sent == clickEvents + clickEvents,
              "a competing interval cannot suppress independent native clicks before or after it")
        surrounded.balanced("independent clicks around an overlap retain both balanced pairs")
    }

    let lateScroll = LifecycleRig()
    lateScroll.view.changed(contact(0))
    lateScroll.view.changed(contact(0.8, 500, 600))
    lateScroll.view.ended(contact(0.9, 500, 600, .ended))
    check(lateScroll.sent == [.pointer(.move, x: 0.3, y: 0.4),
        .scrollGesture(.began, x: 0.3, y: 0.4), .scroll(x: 0.3, y: 0.4, dx: 0.2, dy: 0.2),
        .scrollGesture(.ended, x: 0.3, y: 0.4)], "holding before motion still scrolls both axes without mouse down")

    for degrees in [-720.0, -40, -25, -24.999, 0, 24.999, 25, 40, 720] {
        let rotation = LifecycleRig()
        let gain = VisionAudioGain.shared.begin(owner: UUID())
        _ = VisionAudioGain.shared.preview(ticket: gain, degrees: -90)
        VisionAudioGain.shared.end(ticket: gain, commit: true)
        rotation.view.changed(turn(degrees / 2, 0.1))
        rotation.view.changed(turn(degrees, 0.2))
        check(rotation.sent.isEmpty && rotation.client.steppedDisplays.isEmpty && VisionAudioGain.shared.value == 0.5,
              "rotation changes neither monitor nor remote gain before completion")
        let ticket = rotation.state.revision!
        rotation.view.ended(turn(degrees, 0.3))
        let steps: [Int] = abs(degrees) >= 25 ? [degrees > 0 ? 1 : -1] : []
        let displays: [UInt32] = steps.isEmpty ? [] : [degrees > 0 ? 22 : 33]
        check(rotation.sent.isEmpty && rotation.client.steppedDisplays == steps &&
              rotation.client.selectedDisplays == displays && VisionAudioGain.shared.value == 0.5,
              "completed rotation selects exactly one adjacent monitor at twenty five degrees and preserves gain")
        rotation.view.ended(turn(degrees * 2, 0.4))
        rotation.input.finishGesture(revision: ticket, completed: true)
        check(rotation.client.steppedDisplays == steps && VisionAudioGain.shared.value == 0.5,
              "duplicate rotation completion cannot select again or change gain")
        rotation.balanced("monitor rotation leaves no held input")
    }
    for terminal in ["recognizing", "disappear", "release", "admission", "geometry", "moving", "disconnected"] {
        let cancelled = LifecycleRig()
        cancelled.view.changed(turn(-90, 0.1))
        let ticket = cancelled.state.revision!
        switch terminal {
        case "recognizing":
            cancelled.view.recognizingChanged(false)
            check(cancelled.input.gestureRevision != ticket, "cancelled rotation retires its input revision")
        case "disappear": cancelled.view.disappeared()
        case "release": cancelled.input.releaseAll()
        case "admission": cancelled.input.allowed = false
        case "geometry": cancelled.view.geometryChanged(.init(
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 1000), video: testGeometry.video))
        case "moving": cancelled.input.setMoving(true)
        default: cancelled.client.connected = false
        }
        cancelled.view.ended(turn(-90, 0.2))
        cancelled.input.finishGesture(revision: ticket, completed: true)
        check(cancelled.client.steppedDisplays.isEmpty && VisionAudioGain.shared.value == 1,
              "\(terminal) cancels monitor rotation without changing gain")
        cancelled.balanced("cancelled monitor rotation leaves no held input")
    }
    for returnsBelowThreshold in [false, true] {
        let terminalAngle = LifecycleRig()
        terminalAngle.view.changed(turn(returnsBelowThreshold ? 90 : 10, 0.1))
        terminalAngle.view.ended(turn(returnsBelowThreshold ? 10 : -40, 0.2))
        check(terminalAngle.client.steppedDisplays == (returnsBelowThreshold ? [] : [-1]),
              "terminal angle determines threshold and direction instead of peak or first angle")
    }
    let zoomTurn = LifecycleRig()
    zoomTurn.view.changed(turn(-40, 0.1))
    zoomTurn.view.changed(zoom(1.5, 0.2))
    zoomTurn.view.ended(turn(-50, 0.3))
    check(zoomTurn.sent.isEmpty && zoomTurn.client.steppedDisplays.isEmpty && zoomTurn.input.viewport.scale == 1.5 && VisionAudioGain.shared.value == 1,
          "meaningful zoom wins over incidental rotation")
    for factor in [0.92, 1.08] {
        for returnsToStart in [false, true] {
            for zoomFirst in [false, true] {
                let boundaryZoom = LifecycleRig()
                if !zoomFirst { boundaryZoom.view.changed(turn(-40, 0.1)) }
                boundaryZoom.view.changed(zoom(factor, 0.2))
                if returnsToStart { boundaryZoom.view.changed(zoom(1, 0.3)) }
                boundaryZoom.view.ended(turn(-40, 0.4))
                check(boundaryZoom.client.steppedDisplays.isEmpty && VisionAudioGain.shared.value == 1,
                      "eight percent zoom boundary and its history suppress rotation")
            }
        }
    }
    for factor in [0.921, 1.079] {
        let incidentalZoom = LifecycleRig()
        incidentalZoom.view.changed(turn(40, 0.1))
        incidentalZoom.view.changed(zoom(factor, 0.2))
        incidentalZoom.view.ended(turn(40, 0.3))
        check(incidentalZoom.client.steppedDisplays == [1] && VisionAudioGain.shared.value == 1,
              "zoom below eight percent permits one completed rotation")
    }
    let simultaneousZoom = LifecycleRig()
    simultaneousZoom.view.changed(turn(40, 0.1))
    var zoomEnd = zoom(1.08, 0.2)
    zoomEnd.second?.second = turn(90, 0.2).second?.second
    simultaneousZoom.view.ended(zoomEnd)
    check(simultaneousZoom.client.steppedDisplays.isEmpty && simultaneousZoom.input.viewport.scale == 1.08 &&
          VisionAudioGain.shared.value == 1, "terminal zoom wins before simultaneous rotation completion")
    for terminal in [false, true] {
        for invalid in [contact(0.3, 300, 400, .cancelled), contact(0.3, .nan, 400), contact(.infinity)] {
            let rejected = LifecycleRig()
            rejected.view.changed(contact(0))
            _ = rejected.sent
            rejected.view.changed(turn(-40, 0.1))
            var transform = turn(-50, 0.3)
            transform.first = invalid.first
            transform.second?.first = zoom(2, 0.3).second?.first
            if terminal { rejected.view.ended(transform) }
            else { rejected.view.changed(transform); rejected.view.ended(turn(-50, 0.4)) }
            var drained = false
            DispatchQueue.main.async { drained = true }
            waitMain { drained }
            check(rejected.client.steppedDisplays.isEmpty && rejected.input.viewport.scale == 1 &&
                  rejected.client.cursorVisible == nil && VisionAudioGain.shared.value == 1,
                  "cancelled or invalid contact rejects transforms and retires queued cursor")
            rejected.balanced("invalid native contact leaves no held input")
        }
    }
    for invalid in [Double.nan, .infinity, -.infinity] {
        for field in ["angle", "time", "anchor"] {
            let invalidTurn = LifecycleRig()
            invalidTurn.view.changed(turn(-40, 0.1))
            var value = turn(field == "angle" ? invalid : -40, field == "time" ? invalid : 0.2)
            if field == "anchor" { value.second?.second?.startLocation.x = CGFloat(invalid) }
            invalidTurn.view.ended(value)
            check(invalidTurn.sent.isEmpty && invalidTurn.client.steppedDisplays.isEmpty && VisionAudioGain.shared.value == 1,
                  "invalid terminal rotation \(field) cancels a previously valid angle")
        }
    }
    for terminal in [false, true] {
        let delayed = LifecycleRig()
        delayed.view.changed(turn(40, 0.2))
        if terminal { delayed.view.ended(turn(-90, 0.1)) }
        else {
            delayed.view.changed(turn(-90, 0.1))
            delayed.view.ended(turn(40, 0.3))
        }
        check(delayed.client.steppedDisplays.isEmpty && VisionAudioGain.shared.value == 1,
              "out of order rotation update or completion cannot commit the previous angle")
    }
    for inventory in ["missing", "empty", "single", "arrives-late"] {
        let unavailable = LifecycleRig()
        if inventory == "missing" || inventory == "arrives-late" {
            unavailable.client.visionDisplaySelection.bind(peerEpoch: UUID())
        } else {
            unavailable.client.visionDisplaySelection.observe(.init(monitorCatalog(
                inventory == "single" ? Array(monitorRows.prefix(1)) : [])))
        }
        unavailable.view.changed(turn(-90, 0.1))
        if inventory == "arrives-late" {
            unavailable.client.visionDisplaySelection.observe(.init(monitorCatalog()))
        }
        unavailable.view.ended(turn(-90, 0.2))
        check(unavailable.client.steppedDisplays.isEmpty && VisionAudioGain.shared.value == 1,
              "\(inventory) monitor inventory cannot switch or change gain")
    }
    for boundary in ["source", "binding", "connection", "token-peer", "window", "admission", "inventory", "rows", "single"] {
        for terminalSample in [false, true] {
            let retired = LifecycleRig()
            retired.view.changed(turn(-90, 0.1))
            let oldToken = retired.client.visionDisplaySelection.token!
            switch boundary {
            case "source": retired.client.active = .window(42)
            case "binding": _ = retired.client.catalog(catalog(.desktop, "monitor-new-binding"), from: retired.peer)
            case "connection":
                let peer = NWConnection()
                retired.client.connection = peer
                seedLegacy(retired.client, peer)
            case "token-peer": retired.client.visionDisplaySelection.bind(peerEpoch: UUID())
            case "window": retired.client.visionDisplaySelection.admit(lease: VisionWindowLease(window: UUID()), foreground: true)
            case "admission":
                retired.client.visionDisplaySelection.admit(lease: retired.client.visionDisplaySelection.lease, foreground: false)
                retired.client.visionDisplaySelection.admit(lease: retired.client.visionDisplaySelection.lease, foreground: true)
            case "inventory": retired.client.visionDisplaySelection.observe(.init(monitorCatalog()))
            case "rows": retired.client.visionDisplaySelection.observe(.init(monitorCatalog(
                Array(monitorRows.reversed()), inventory: oldToken.inventory)))
            default: retired.client.visionDisplaySelection.observe(.init(monitorCatalog(
                Array(monitorRows.prefix(1)), inventory: oldToken.inventory)))
            }
            retired.view.ended(terminalSample ? turn(-90, 0.2) : GestureValue())
            check(retired.client.steppedDisplays.isEmpty && VisionAudioGain.shared.value == 1,
                  "retired \(boundary) cannot select a monitor or change gain with or without a terminal sample")
        }
    }
    let rebound = LifecycleRig()
    rebound.view.changed(turn(90, 0.1))
    let replacement = StreamClient(), replacementPeer = NWConnection()
    replacement.connection = replacementPeer
    seedLegacy(replacement, replacementPeer)
    replacement.visionDisplaySelection = rebound.client.visionDisplaySelection
    let oldRevision = rebound.input.gestureRevision
    rebound.input.bind(replacement)
    check(rebound.client.visionInputSession == nil && rebound.input.gestureRevision != oldRevision,
          "client rebind retires the original input scope even with matching binding source and display token")
    rebound.view.ended(turn(90, 0.2))
    check(rebound.client.steppedDisplays.isEmpty && replacement.steppedDisplays.isEmpty && VisionAudioGain.shared.value == 1,
          "old rotation cannot target the original or rebound client")
    rebound.view.changed(turn(-90, 1))
    rebound.view.ended(turn(-90, 1.1))
    check(rebound.client.steppedDisplays.isEmpty && replacement.steppedDisplays == [-1],
          "fresh rotation sends only through its captured replacement client")
    for kind in ["scroll", "drag"] {
        let competing = LifecycleRig()
        competing.drag(modifier: kind == "drag")
        competing.view.changed(turn(40, 1))
        let released = competing.sent
        competing.balanced("rotation cancels existing \(kind) before selecting a monitor")
        competing.view.ended(turn(40, 1.1))
        check(competing.client.steppedDisplays == [1] && competing.sent == released && VisionAudioGain.shared.value == 1,
              "rotation selects once after \(kind) releases without starting momentum")
    }
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

    for boundary in ["pinch", "magnify", "rotate", "geometry", "source", "route", "admission", "disappear", "key", "overlay"] {
        let rig = LifecycleRig()
        startFlick(rig)
        check(momentumStarted(rig), "\(boundary) starts with a real coast")
        var replacement: NWConnection?
        switch boundary {
        case "pinch": rig.view.changed(contact(1, 500, 500, id: 2))
        case "magnify": rig.view.changed(zoom(2, 1))
        case "rotate": rig.view.changed(turn(40, 1))
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
        if boundary == "rotate" { rig.view.ended(turn(40, 1.1)) }
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
