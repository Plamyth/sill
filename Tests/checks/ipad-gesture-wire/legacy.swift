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
func list(_ source: StreamSource, scoped: Bool, revision: String?, generation: String = "origin") -> WindowList {
    var result = WindowList(macName: "legacy 메모리 검사", windows: [], active: source,
                            inputGeneration: scoped ? generation : nil)
    result.selectionRevision = revision
    return result
}
func origin(_ scoped: Bool, revision: String? = "origin", source: StreamSource = .window(42)) -> (StreamClient, NWConnection, UUID) {
    let client = StreamClient(), peer = NWConnection()
    client.connection = peer
    client.displayView.onRevoke = { [weak client] in client?.ready(nil) }
    client.catalog(list(source, scoped: scoped, revision: revision), peer: peer)
    return (client, peer, client.visionInputPermit!)
}
func gestures(_ peer: NWConnection) -> Int {
    peer.sent.filter { $0.first == StreamMessageKind.gesture.rawValue }.count
}

for scoped in [false, true] {
    let mode = scoped ? "scoped" : "raw"
    do {
        let (client, peer, oldPermit) = origin(scoped)
        var results: [SessionLink.Submission.Outcome] = []
        let accepted = client.sendGesture(.swipeUp, fingers: 3) { results.append($0) }
        drain(client)
        check(accepted && peer.sent.map { $0.first! } == [StreamMessageKind.selectSource.rawValue] && results.isEmpty,
              "\(mode)-window-select-receipt-before-gesture")
        client.catalog(list(.desktop, scoped: scoped, revision: "desktop", generation: "desktop"), peer: peer)
        let freshPermit = client.visionInputPermit
        drain(client)
        check(gestures(peer) == 1 && results == [.submitted] && freshPermit != nil && freshPermit != oldPermit,
              "\(mode)-window-fresh-desktop-catalog-new-permit")
        client.catalog(list(.desktop, scoped: scoped, revision: "desktop", generation: "desktop"), peer: peer); drain(client)
        check(gestures(peer) == 1 && results == [.submitted], "\(mode)-duplicate-catalog-no-repeat")
    }
    do {
        let (client, peer, oldPermit) = origin(scoped, revision: nil)
        var results: [SessionLink.Submission.Outcome] = []
        _ = client.link.hold(peer)
        _ = client.sendGesture(.swipeRight, fingers: 4) { results.append($0) }
        client.catalog(list(.window(42), scoped: scoped, revision: nil), peer: peer)
        check(peer.sent.isEmpty && results.isEmpty, "\(mode)-held-selection-origin-replay")
        _ = client.link.unhold(peer); drain(client)
        client.catalog(list(.desktop, scoped: scoped, revision: nil, generation: "desktop"), peer: peer); drain(client)
        check(gestures(peer) == 1 && results == [.submitted] && client.visionInputPermit != oldPermit,
              "\(mode)-no-revision-host-normal-window-flow")
    }
    for cancellation in ["cancel", "peer", "foreground", "intent", "source", "revision", "early-catalog"] {
        let (client, peer, _) = origin(scoped)
        let next = NWConnection()
        var results: [SessionLink.Submission.Outcome] = []
        _ = client.link.hold(peer)
        let accepted = client.sendGesture(.swipeLeft, fingers: 3) { results.append($0) }
        if cancellation != "early-catalog" { _ = client.link.unhold(peer); drain(client) }
        switch cancellation {
        case "peer": client.connection = next
        case "foreground": client.appInForeground = false; client.cancelVisionInputs()
        case "intent": client.noteSourceIntent()
        case "source": client.select(.window(99))
        case "revision": client.catalog(list(.window(42), scoped: scoped, revision: "other-selection"), peer: peer)
        case "early-catalog": client.catalog(list(.desktop, scoped: scoped, revision: "desktop", generation: "desktop"), peer: peer)
        default: client.cancel()
        }
        client.catalog(list(.desktop, scoped: scoped, revision: "desktop", generation: "desktop"), peer: peer)
        _ = client.link.unhold(peer); drain(client)
        check(accepted && gestures(peer) == 0 && gestures(next) == 0 && results == [.cancelled], "\(mode)-mid-\(cancellation)-discarded")
    }
    for revision in [String?.some("origin"), nil] {
        let (client, peer, _) = origin(scoped)
        var results: [SessionLink.Submission.Outcome] = []
        let accepted = client.sendGesture(.pinch, fingers: 3) { results.append($0) }; drain(client)
        client.catalog(list(.desktop, scoped: scoped, revision: revision, generation: "desktop"), peer: peer); drain(client)
        check(accepted && gestures(peer) == 0 && results == [.cancelled], "\(mode)-stale-or-missing-selection-revision-discarded-\(revision ?? "nil")")
    }
    do {
        let (client, peer, _) = origin(scoped)
        var results: [SessionLink.Submission.Outcome] = []
        let accepted = client.sendGesture(.spread, fingers: 3) { results.append($0) }; drain(client)
        _ = client.link.hold(peer)
        client.catalog(list(.desktop, scoped: scoped, revision: "desktop", generation: "desktop"), peer: peer)
        client.queue.sync {}
        let permit = client.visionInputPermit
        // legacy binding은 같고 다른 선택의 revision만 도착한 경우다.
        client.queue.sync { client.observeVisionInputCatalog(list(.desktop, scoped: scoped, revision: "replaced", generation: "desktop"), from: peer) }
        _ = client.link.unhold(peer); drain(client)
        check(accepted && gestures(peer) == 0 && results == [.cancelled] && client.visionInputPermit == permit,
              "\(mode)-wire-revision-replacement-blocks-held-gesture")
    }
    do {
        let (client, peer, _) = origin(scoped, source: .desktop)
        var results: [SessionLink.Submission.Outcome] = []
        _ = client.sendGesture(.swipeDown, fingers: 3) { results.append($0) }; drain(client)
        check(gestures(peer) == 1 && results == [.submitted], "\(mode)-normal-desktop-preserved")
    }
}
print("legacy-gesture \(checks - failures)/\(checks); failed \(failures)")
exit(failures == 0 ? 0 : 1)
