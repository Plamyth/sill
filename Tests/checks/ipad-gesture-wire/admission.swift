import Foundation
import Network
import StreamProtocol

var checks = 0, failures = 0
func check(_ passed: Bool, _ name: String) {
    checks += 1
    if passed { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func drain(_ client: StreamClient) {
    client.queue.sync {}
    var done = false
    DispatchQueue.main.async { done = true }
    while !done { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
    client.queue.sync {}
}
func gestures(_ peer: NWConnection) -> Int {
    peer.sent.filter { $0.first == StreamMessageKind.gesture.rawValue }.count
}
func epoch(_ generation: String, _ source: StreamSource = .desktop) -> VideoEpoch {
    VideoEpoch(generation: generation, source: source,
        geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
}
func catalog(_ client: StreamClient, _ peer: NWConnection, _ epoch: VideoEpoch, revision: String? = nil) {
    var list = WindowList(macName: "메모리 검사", windows: [], active: epoch.source,
        inputGeneration: epoch.generation, presentationInput: 1, videoEpoch: epoch)
    list.selectionRevision = revision ?? epoch.generation
    client.catalog(list, peer: peer)
}
let layer = NSObject()
func ready(_ client: StreamClient, _ peer: NWConnection, _ epoch: VideoEpoch) {
    client.ready(VisionPresentation.Ticket(epoch: epoch, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(layer)))
}
func presented(_ source: StreamSource = .desktop) -> (StreamClient, NWConnection, VideoEpoch) {
    let client = StreamClient(), peer = NWConnection(), initial = epoch("origin", source)
    client.connection = peer
    client.displayView.onRevoke = { [weak client] in client?.ready(nil) }
    catalog(client, peer, initial); ready(client, peer, initial)
    return (client, peer, initial)
}

// 원래 두 반례를 유지한다.
do {
    let client = StreamClient(), peer = NWConnection()
    client.connection = peer
    _ = client.sendGesture(.swipeUp, fingers: 3); drain(client)
    check(gestures(peer) == 0, "kind28-unpresented-admission")
}
do {
    let (client, peer, _) = presented()
    _ = client.link.hold(peer)
    _ = client.sendGesture(.swipeRight, fingers: 3); client.queue.sync {}
    client.cancel(); _ = client.link.unhold(peer); drain(client)
    check(gestures(peer) == 0, "kind28-revoked-queued-admission")
}

do {
    let (client, peer, _) = presented()
    var results: [SessionLink.Submission.Outcome] = []
    let accepted = client.sendGesture(.swipeUp, fingers: 4) { results.append($0) }
    drain(client)
    let payload = peer.sent.first.flatMap { Wire.decode(TrackpadGesture.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
    check(accepted && gestures(peer) == 1 && payload == TrackpadGesture(gesture: "swipeUp", fingers: 4), "normal-desktop-wire-unchanged")
    check(results == [.submitted], "normal-desktop-actual-submission-once")
}
for blocked in ["foreground", "none", "connected"] {
    let (client, peer, _) = presented()
    if blocked == "foreground" { client.appInForeground = false }
    if blocked == "none" { client.active = .none }
    if blocked == "connected" { client.connected = false }
    var results: [SessionLink.Submission.Outcome] = []
    let accepted = client.sendGesture(.swipeUp, fingers: 3) { results.append($0) }; drain(client)
    check(!accepted && gestures(peer) == 0 && results == [.cancelled], "entry-\(blocked)-rejected")
}
for cancellation in ["cancel", "epoch", "peer", "foreground", "nil-ticket"] {
    let (client, peer, old) = presented()
    let next = NWConnection()
    _ = client.link.hold(peer)
    var results: [SessionLink.Submission.Outcome] = []
    let accepted = client.sendGesture(.swipeLeft, fingers: 3) { results.append($0) }
    client.queue.sync {}
    check(accepted && gestures(peer) == 0 && results.isEmpty, "held-\(cancellation)-is-not-submitted")
    switch cancellation {
    case "epoch": catalog(client, peer, epoch("next"))
    case "peer": client.connection = next
    case "foreground": client.appInForeground = false; client.visionInputPermit = nil; _ = client.link.setInputPermit(nil); client.cancelVisionInputs()
    case "nil-ticket": client.ready(nil)
    default: client.cancelVisionInputs()
    }
    _ = client.link.unhold(peer); drain(client)
    ready(client, peer, old); drain(client)
    check(gestures(peer) == 0 && gestures(next) == 0 && results == [.cancelled], "held-\(cancellation)-cancelled-once")
}
do {
    let (client, peer, _) = presented()
    _ = client.link.hold(peer)
    var results: [SessionLink.Submission.Outcome] = []
    _ = client.sendGesture(.swipeDown, fingers: 3) { results.append($0) }; client.queue.sync {}
    _ = client.link.unhold(peer); drain(client)
    check(gestures(peer) == 1 && results == [.submitted], "normal-hold-unhold-submits-once")
}

do {
    let (client, peer, old) = presented(.window(42))
    var results: [SessionLink.Submission.Outcome] = []
    let accepted = client.sendGesture(.spread, fingers: 3) {
        check(Thread.isMainThread, "window-completion-on-main")
        results.append($0)
    }
    let waitingForReceipt: Bool
    if let pending = client.pendingIPadDesktopGesture, case .selecting = pending.phase { waitingForReceipt = true }
    else { waitingForReceipt = false }
    check(waitingForReceipt && results.isEmpty, "pending-installed-before-main-selection-receipt")
    drain(client)
    check(accepted && peer.sent.map { $0.first! } == [StreamMessageKind.selectSource.rawValue] && results.isEmpty,
          "window-select-transmitted-before-gesture")
    ready(client, peer, old); drain(client)
    check(gestures(peer) == 0, "window-old-presentation-cannot-resume")
    let desktop = epoch("selected-desktop")
    catalog(client, peer, desktop); drain(client)
    check(client.visionInputBinding == .awaitingPresentation(desktop) && gestures(peer) == 0 && results.isEmpty,
          "window-desktop-catalog-alone-cannot-submit")
    ready(client, peer, desktop); drain(client)
    check(peer.sent.map { $0.first! } == [StreamMessageKind.selectSource.rawValue, StreamMessageKind.gesture.rawValue]
          && results == [.submitted], "window-fresh-desktop-confirm-submits-new-permit")
    ready(client, peer, desktop); catalog(client, peer, desktop); drain(client)
    check(gestures(peer) == 1 && results == [.submitted], "window-duplicate-confirm-no-repeat")
}

for cancellation in ["cancel", "source", "epoch", "peer", "foreground", "nil-ticket", "intent", "metadata"] {
    let (client, peer, _) = presented(.window(42))
    var results: [SessionLink.Submission.Outcome] = []
    _ = client.sendGesture(.pinch, fingers: 3) { results.append($0) }; drain(client)
    let desktop = epoch("selected-desktop")
    catalog(client, peer, desktop)
    switch cancellation {
    case "source": client.select(.window(99))
    case "epoch": catalog(client, peer, epoch("other-desktop"))
    case "peer": client.connection = NWConnection()
    case "foreground": client.appInForeground = false; client.cancelVisionInputs()
    case "nil-ticket": client.ready(nil)
    case "intent": client.noteSourceIntent()
    case "metadata": client.catalog(WindowList(macName: "메타데이터 누락", windows: [], active: .desktop), peer: peer)
    default: client.cancel()
    }
    ready(client, peer, desktop); drain(client)
    check(gestures(peer) == 0 && results == [.cancelled], "window-mid-\(cancellation)-discarded")
}
do {
    let (client, peer, _) = presented(.window(42))
    _ = client.link.hold(peer)
    var results: [SessionLink.Submission.Outcome] = []
    _ = client.sendGesture(.swipeUp, fingers: 3) { results.append($0) }
    client.cancel(); _ = client.link.unhold(peer); drain(client)
    check(peer.sent.isEmpty && results == [.cancelled], "window-held-selection-cancel-removes-own-select")
}
do {
    let (client, peer, _) = presented(.window(42))
    _ = client.link.hold(peer)
    var results: [SessionLink.Submission.Outcome] = []
    _ = client.sendGesture(.swipeUp, fingers: 3) { results.append($0) }
    let premature = epoch("premature-desktop")
    catalog(client, peer, premature); ready(client, peer, premature)
    _ = client.link.unhold(peer); drain(client)
    check(gestures(peer) == 0 && results == [.cancelled], "window-confirm-before-select-submission-rejected")
}
do {
    let (client, peer, origin) = presented(.window(42))
    _ = client.link.hold(peer)
    var results: [SessionLink.Submission.Outcome] = []
    _ = client.sendGesture(.swipeRight, fingers: 3) { results.append($0) }
    catalog(client, peer, origin); ready(client, peer, origin)
    check(peer.sent.isEmpty && client.pendingIPadDesktopGesture != nil, "window-origin-replay-preserves-own-wait")
    _ = client.link.unhold(peer); drain(client)
    let desktop = epoch("desktop-after-hold")
    catalog(client, peer, desktop); ready(client, peer, desktop); drain(client)
    check(peer.sent.map { $0.first! } == [StreamMessageKind.selectSource.rawValue, StreamMessageKind.gesture.rawValue]
          && results == [.submitted], "window-held-select-then-fresh-confirm-normal")
}
do {
    let (client, peer, origin) = presented(.window(42))
    var first: [SessionLink.Submission.Outcome] = [], second: [SessionLink.Submission.Outcome] = []
    _ = client.sendGesture(.swipeUp, fingers: 3) { first.append($0) }
    client.cancelVisionInputs()
    catalog(client, peer, origin); ready(client, peer, origin)
    _ = client.sendGesture(.swipeDown, fingers: 3) { second.append($0) }
    drain(client)
    let desktop = epoch("second-choice")
    catalog(client, peer, desktop); ready(client, peer, desktop); drain(client)
    check(gestures(peer) == 1 && first == [.cancelled] && second == [.submitted], "old-selection-receipt-cannot-revive-or-replace-new-pending")
}
do {
    let (client, peer, _) = presented()
    _ = client.link.hold(peer)
    var outcomes: [SessionLink.Submission.Outcome] = []
    _ = client.sendGesture(.swipeUp, fingers: 3) { outcome in
        check(Thread.isMainThread, "cancel-completion-on-main")
        outcomes.append(outcome)
        _ = client.sendGesture(.swipeDown, fingers: 3) { outcomes.append($0) }
    }
    _ = client.sendGesture(.swipeLeft, fingers: 3) { outcomes.append($0) }
    client.queue.sync {}
    client.cancelVisionInputs()
    _ = client.link.unhold(peer); drain(client); drain(client)
    check(gestures(peer) == 1 && outcomes.filter { $0 == .cancelled }.count == 2
          && outcomes.filter { $0 == .submitted }.count == 1 && client.ipadGestureSubmissions.isEmpty,
          "cancel-and-completion-reentry-preserve-new-request")
}
for cancellation in ["cancel", "peer", "nil-ticket"] {
    let (client, peer, _) = presented()
    var outcomes: [SessionLink.Submission.Outcome] = []
    client.queue.suspend()
    _ = client.sendGesture(.swipeUp, fingers: 3) { outcomes.append($0) }
    if cancellation == "peer" { client.connection = NWConnection() }
    else if cancellation == "nil-ticket" { client.ready(nil) }
    else { client.cancelVisionInputs() }
    client.queue.resume(); drain(client)
    check(gestures(peer) == 0 && outcomes == [.cancelled], "before-queue-\(cancellation)-cannot-submit")
}
do {
    let (client, peer, _) = presented(.window(42))
    var results: [SessionLink.Submission.Outcome] = []
    _ = client.sendGesture(.swipeUp, fingers: 3) { results.append($0) }; drain(client)
    let desktop = epoch("unrelated-desktop")
    catalog(client, peer, desktop, revision: "origin"); ready(client, peer, desktop); drain(client)
    check(gestures(peer) == 0 && results == [.cancelled], "window-unchanged-selection-revision-rejected")
}
do {
    let client = StreamClient(), peer = NWConnection()
    client.connection = peer
    client.catalog(WindowList(macName: "구형 desktop", windows: [], active: .desktop, inputGeneration: "legacy"), peer: peer)
    _ = client.sendGesture(.swipeRight, fingers: 3); drain(client)
    check(gestures(peer) == 1, "confirmed-legacy-desktop-keeps-existing-wire")
}
print("gesture-admission \(checks - failures)/\(checks); failed \(failures)")
exit(failures == 0 ? 0 : 1)
