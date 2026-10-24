import Foundation
import Network
import StreamProtocol

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ witness: String) {
    guard value() else { print("FAIL \(witness)"); exit(1) }
    checks += 1
    print("PASS \(witness)")
}
func pump(_ witness: String = "terminal callback arrives within bounded inert run", _ ready: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !ready(), Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
    check(ready(), witness)
}
func drainMain() {
    var drained = false
    DispatchQueue.main.async { drained = true }
    pump { drained }
}
func events(_ peer: NWConnection) -> [InputEvent] {
    peer.sent.filter { $0.first == 8 }.map { bytes in
        let payload = Data(bytes.dropFirst(StreamMessage.headerLength))
        if let input = Wire.decode(SourceInput.self, from: payload) { return input.event }
        return try! JSONDecoder().decode(InputEvent.self, from: payload)
    }
}
let input = Data([8, 1]), other = Data([9, 2])

do {
    let link = SessionLink(), peer = NWConnection()
    link.connection = peer
    var results: [SessionLink.Submission.Outcome] = []
    let ticket = SessionLink.Submission { results.append($0) }
    link.cancel(ticket)
    check(!link.send(input, onlyOn: peer, submission: ticket), "cancel before enqueue refuses actual send")
    pump { results.count == 1 }
    check(results == [.cancelled] && peer.sent.isEmpty && link.inputsOnSession == 0,
          "cancel before enqueue has one terminal and zero counted input")
}
do {
    let link = SessionLink(), peer = NWConnection()
    link.connection = peer
    let permit = UUID()
    _ = link.setInputPermit(permit)
    _ = link.hold(peer)
    var first: [SessionLink.Submission.Outcome] = [], second: [SessionLink.Submission.Outcome] = []
    let a = SessionLink.Submission { first.append($0) }, b = SessionLink.Submission { second.append($0) }
    check(link.send(input, onlyOn: peer, permit: permit, submission: a), "held ticket admitted")
    check(!link.send(input, onlyOn: peer, permit: permit, submission: a) && link.inputsOnSession == 1,
          "ticket cannot be enqueued twice")
    check(link.send(input, onlyOn: peer, permit: permit, submission: b), "independent held ticket admitted")
    link.send(other)
    link.cancel(a)
    check(link.inputsOnSession == 1, "specific cancellation removes only own input count")
    let released = link.unhold(peer)!
    pump { first.count == 1 && second.count == 1 }
    check(first == [.cancelled] && second == [.submitted] && peer.sent == [input, other]
          && released.held == 2 && link.inputsOnSession == 1, "specific cancellation preserves other queue items")
    link.cancel(b)
    drainMain()
    check(second == [.submitted], "submitted ticket cannot be cancelled or notified twice")
}
for loss in ["cancelInputs", "drop", "permit", "peer", "epoch"] {
    let link = SessionLink(), peer = NWConnection(), next = NWConnection()
    link.connection = peer
    let permit = UUID()
    _ = link.setInputPermit(permit)
    _ = link.hold(peer)
    var outcomes: [SessionLink.Submission.Outcome] = []
    let ticket = SessionLink.Submission { outcomes.append($0) }
    _ = link.send(input, onlyOn: peer, permit: permit, submission: ticket)
    link.send(other)
    switch loss {
    case "cancelInputs": check(link.cancelInputs(onlyOn: peer, releases: { [] }) == 1, "cancelInputs reports per-message drop")
    case "drop": _ = link.dropHandOver()
    case "permit": _ = link.setInputPermit(UUID())
    case "peer": link.connection = next
    default: link.observeInputEpoch(UUID(), modern: true)
    }
    pump { outcomes.count == 1 }
    check(outcomes == [.cancelled] && link.inputsOnSession == 0 && peer.sent.isEmpty && next.sent.isEmpty,
          "queued ticket terminates and decrements once on \(loss)")
    _ = link.unhold(peer)
    check(link.inputsOnSession == 0, "late flush does not decrement cancelled ticket twice on \(loss)")
}
do {
    let link = SessionLink(), a = NWConnection(), b = NWConnection()
    link.connection = a
    link.handOver(from: a, to: b, fencePing: Data([12]), nonce: Data([1]))
    var result: [SessionLink.Submission.Outcome] = []
    let ticket = SessionLink.Submission { result.append($0) }
    _ = link.send(input, onlyOn: b, submission: ticket)
    link.cancel(ticket)
    _ = link.fenceReturned(Data([1]), on: a)
    pump { result.count == 1 }
    check(b.sent.isEmpty && link.inputsOnSession == 0 && result == [.cancelled], "fenced cancellation has no late send or input debt")
    var refused: [SessionLink.Submission.Outcome] = []
    let noPeer = SessionLink.Submission { refused.append($0) }
    check(!link.send(input, onlyOn: a, submission: noPeer), "peer refusal reports false immediately")
    let noPermit = SessionLink.Submission { refused.append($0) }
    check(!link.send(input, onlyOn: b, permit: UUID(), submission: noPermit), "permit refusal reports false immediately")
    pump { refused.count == 2 }
    check(refused == [.cancelled, .cancelled] && link.inputsOnSession == 0, "refused tickets terminate without counting input")
}
do {
    let link = SessionLink(), peer = NWConnection()
    link.connection = peer
    _ = link.hold(peer)
    link.send(input)
    link.send(other)
    _ = link.unhold(peer)
    check(peer.sent == [input, other] && link.inputsOnSession == 1, "default nil ticket preserves legacy queue and counters")
}
do {
    var link: SessionLink? = SessionLink()
    let peer = NWConnection()
    link!.connection = peer
    _ = link!.hold(peer)
    var results: [SessionLink.Submission.Outcome] = []
    let ticket = SessionLink.Submission { results.append($0) }
    _ = link!.send(input, onlyOn: peer, submission: ticket)
    link = nil
    pump { results.count == 1 }
    check(results == [.cancelled] && peer.sent.isEmpty, "link destruction cancels orphaned held ticket")
}
for _ in 0..<64 {
    let link = SessionLink(), peer = NWConnection()
    link.connection = peer
    var result: [SessionLink.Submission.Outcome] = []
    let ticket = SessionLink.Submission { result.append($0) }
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { _ = link.send(input, onlyOn: peer, submission: ticket); group.leave() }
    group.enter()
    DispatchQueue.global().async { link.cancel(ticket); group.leave() }
    check(group.wait(timeout: .now() + 2) == .success, "send cancel race avoids lock inversion")
    pump { result.count == 1 }
    drainMain()
    check(result.count == 1 && peer.sent.count == (result == [.submitted] ? 1 : 0)
          && link.inputsOnSession == peer.sent.count, "actual send cancel race has exactly one matching terminal")
}
do {
    let link = SessionLink(), peer = NWConnection()
    link.connection = peer
    var callbackInline = false, returned = false, onMain = false
    let ticket = SessionLink.Submission { _ in
        callbackInline = !returned
        onMain = Thread.isMainThread
        _ = link.cancelInputs(onlyOn: peer, releases: { [] })
    }
    _ = link.send(input, onlyOn: peer, submission: ticket)
    returned = true
    pump { onMain }
    check(!callbackInline && onMain, "terminal callback is async main and can reenter link")
}
do {
    let link = SessionLink(), peer = NWConnection()
    link.connection = peer
    let entered = DispatchSemaphore(value: 0), allowSend = DispatchSemaphore(value: 0)
    peer.onSend = { entered.signal(); _ = allowSend.wait(timeout: .now() + 2) }
    var result: [SessionLink.Submission.Outcome] = []
    let ticket = SessionLink.Submission { result.append($0) }
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { _ = link.send(input, onlyOn: peer, submission: ticket); group.leave() }
    check(entered.wait(timeout: .now() + 2) == .success, "actual send boundary entered under ticket admission")
    drainMain()
    check(result.isEmpty, "terminal is not published before actual send returns")
    group.enter()
    DispatchQueue.global().async { link.cancel(ticket); group.leave() }
    allowSend.signal()
    check(group.wait(timeout: .now() + 2) == .success, "cancel during actual send completes without inversion")
    pump { result.count == 1 }
    check(result == [.submitted] && peer.sent == [input] && link.inputsOnSession == 1,
          "cancellation cannot undo a send already inside admission lock")
}

let accepted = ["한글", "한글", "e\u{301}", "👩🏽‍💻 👨‍👩‍👧‍👦", "  그대로  ", String(repeating: "가", count: 256), "a" + String(repeating: "\u{301}", count: 15)]
for text in accepted { check(VisionDraftText.accepts(text), "ordinary Unicode remains admissible") }
for text in ["", " \t ", "\n", "a\rb", "a\nb", "a\tb", "a\u{8}b", "a\u{0}b", "a\u{85}b", "a\u{2028}b", "a\u{2029}b", "a\u{7F}b", String(repeating: "가", count: 257)] {
    check(!VisionDraftText.accepts(text), "empty oversized and effectful control text refused")
}
check(!VisionDraftText.accepts("a" + String(repeating: "\u{301}", count: 16)), "over sixteen UTF16 units in a Character refused")
check(!VisionDraftText.accepts(String(repeating: "👨‍👩‍👧‍👦", count: 100)), "over 2048 UTF8 bytes refused within Character bound")

typealias Draft = VisionTextDraft<Int>
func observation(_ draft: Draft, _ text: String = "검토한 글", marked: Bool = false,
                 composition: VisionDraftComposition = VisionDraftComposition(), revision: UInt64 = 1) -> VisionDraftObservation {
    guard case .editing(let editor) = draft.phase else { fatalError("fixture requires editing") }
    return VisionDraftObservation(editorID: editor.id, revision: revision, text: text, marked: marked, composition: composition)
}
for text in accepted {
    var draft = Draft(target: 1)
    check(draft.review(observation(draft, text)), "review accepts exact bounded Unicode")
    let command = draft.beginSubmission(currentTarget: 1)!
    check(Array(command.0.text.utf8) == Array(text.utf8), "review and command preserve exact UTF8 without normalization")
}
do {
    var draft = Draft(target: 1)
    _ = draft.review(observation(draft))
    check(draft.beginSubmission(currentTarget: 2) == nil, "different target cannot submit frozen text")
    if case .stale = draft.phase { check(true, "target refusal revokes review rather than retargeting") }
    else { check(false, "target refusal revokes review rather than retargeting") }
}
do {
    var draft = Draft(target: 7)
    let old = observation(draft)
    check(!draft.review(observation(draft, marked: true)), "marked Korean composition blocks review")
    draft.observe(observation(draft, revision: 4))
    check(!draft.review(old), "older editor revision cannot be frozen")
    check(draft.review(observation(draft, revision: 5)), "fresh same editor snapshot freezes")
    draft.observe(old)
    check(draft.observation == nil, "review excludes old editor callbacks")
    draft.editAgain()
    draft.observe(old)
    check(draft.observation == nil, "new editor generation excludes late callbacks")
    check(draft.review(observation(draft)), "fresh editor can review again")
    let sent = draft.beginSubmission(currentTarget: 7)!
    check(draft.beginSubmission(currentTarget: 7) == nil, "duplicate press cannot submit review twice")
    draft.finish(reviewID: UUID(), requestID: sent.1, submitted: true)
    if case .submitting = draft.phase {} else { check(false, "wrong review callback ignored") }
    draft.finish(reviewID: sent.0.id, requestID: UUID(), submitted: true)
    if case .submitting = draft.phase {} else { check(false, "wrong request callback ignored") }
    draft.invalidate()
    draft.finish(reviewID: sent.0.id, requestID: sent.1, submitted: true)
    if case .stale = draft.phase { check(true, "late terminal cannot restore invalidated draft") }
    else { check(false, "late terminal cannot restore invalidated draft") }
}
do {
    var composition = VisionDraftComposition()
    let a = UUID(), b = UUID()
    composition.placeholder(a); composition.placeholder(b)
    composition.removed(a, willInsert: false)
    check(!composition.canReview, "one removed placeholder cannot clear another")
    composition.removed(b, willInsert: true)
    check(!composition.canReview, "removal before insertion stays unresolved")
    var draft = Draft(target: 1)
    let pending = observation(draft, composition: composition)
    check(!draft.review(pending), "unresolved placeholder ordering blocks review")
    draft.recover(pending)
    draft.observe(pending)
    check(draft.observation == nil && draft.review(observation(draft)), "explicit fresh editor recovery rejects late speech callbacks")
    var ended = VisionDraftComposition()
    ended.ended()
    check(!ended.canReview, "end before result never implies completion")
    ended.failed()
    check(!ended.canReview, "failure never resolves late result ambiguity")
    var unknown = VisionDraftComposition()
    unknown.removed(nil, willInsert: false)
    check(!unknown.canReview, "unknown placeholder cannot imply completion")
}

func legacyClient() -> (StreamClient, NWConnection) {
    let client = StreamClient(), peer = NWConnection()
    client.connection = peer
    client.setVisionPresentationForeground(true)
    _ = client.catalog(WindowList(macName: "Fixture", windows: [], active: .desktop), from: peer)
    client.queue.sync {}
    return (client, peer)
}
do {
    let (client, peer) = legacyClient()
    let target = client.captureVisionTextTarget()!
    client.macName = "Renamed Mac"
    check(client.captureVisionTextTarget() == target, "human label does not grant or revoke authority")
    for text in accepted {
        client.revokeVisionTextDrafts()
        let target = client.captureVisionTextTarget()!
        var outcomes: [SessionLink.Submission.Outcome] = []
        let request = UUID()
        client.submitVisionText(text, target: target, requestID: request) { outcomes.append($0) }
        client.submitVisionText("duplicate", target: target, requestID: request) { outcomes.append($0) }
        client.queue.sync {}
        pump { !outcomes.isEmpty }
        drainMain()
        check(outcomes == [.submitted], "duplicate client request emits one matching terminal and one message")
        let exact: Bool
        if let event = events(peer).last, case .text(let sent) = event { exact = Array(sent.utf8) == Array(text.utf8) }
        else { exact = false }
        check(outcomes == [.submitted] && exact, "client submits accepted Unicode exactly once unchanged")
        client.submitVisionText("retry", target: target, requestID: request) { outcomes.append($0) }
        drainMain()
        check(outcomes == [.submitted], "known handoff request has no retry or contradictory terminal")
    }
    for text in ["bad\n", "bad\t", "\u{2028}", "", String(repeating: "x", count: 257), "a" + String(repeating: "\u{301}", count: 16)] {
        client.revokeVisionTextDrafts()
        let target = client.captureVisionTextTarget()!
        let count = peer.sent.count
        var outcomes: [SessionLink.Submission.Outcome] = []
        client.submitVisionText(text, target: target, requestID: UUID()) { outcomes.append($0) }
        client.queue.sync {}
        pump { outcomes.count == 1 }
        check(outcomes == [.cancelled] && peer.sent.count == count, "final client boundary refuses invalid text without send")
    }
}
do {
    let (client, peer) = legacyClient()
    let target = client.captureVisionTextTarget()!
    let gate = DispatchSemaphore(value: 0)
    client.queue.async { gate.wait() }
    let request = UUID()
    var outcomes: [SessionLink.Submission.Outcome] = []
    client.submitVisionText("cancel", target: target, requestID: request) { outcomes.append($0) }
    client.cancelVisionText(request)
    gate.signal()
    client.queue.sync {}
    pump { outcomes.count == 1 }
    check(outcomes == [.cancelled] && events(peer).isEmpty && client.link.inputsOnSession == 0,
          "actual client cancel before async enqueue prevents send")
}
do {
    var client: StreamClient? = StreamClient()
    let peer = NWConnection()
    client!.connection = peer
    client!.setVisionPresentationForeground(true)
    _ = client!.catalog(WindowList(macName: "Fixture", windows: [], active: .desktop), from: peer)
    client!.queue.sync {}
    let target = client!.captureVisionTextTarget()!
    let queue = client!.queue
    let gate = DispatchSemaphore(value: 0)
    queue.async { gate.wait() }
    var outcomes: [SessionLink.Submission.Outcome] = []
    client!.submitVisionText("orphan", target: target, requestID: UUID()) { outcomes.append($0) }
    weak var old = client
    client = nil
    check(old == nil, "queued text retains no old client owner")
    gate.signal()
    queue.sync {}
    pump { outcomes.count == 1 }
    check(outcomes == [.cancelled] && events(peer).isEmpty, "lost client before async enqueue terminates without send")
}
do {
    let (client, peer) = legacyClient()
    let target = client.captureVisionTextTarget()!
    _ = client.link.hold(peer)
    var outcomes: [SessionLink.Submission.Outcome] = []
    client.submitVisionText("old scope", target: target, requestID: UUID()) { outcomes.append($0) }
    client.queue.sync {}
    client.setVisionPresentationForeground(false)
    pump("foreground false cancels queued text even on legacy host") { outcomes.count == 1 }
    _ = client.link.unhold(peer)
    check(outcomes == [.cancelled] && events(peer).isEmpty && client.link.inputsOnSession == 0,
          "foreground false cancels queued text even on legacy host")
    client.setVisionPresentationForeground(true)
    check(client.captureVisionTextTarget() != target, "foreground return never restores old scope")
    var stale: [SessionLink.Submission.Outcome] = []
    client.submitVisionText("stale", target: target, requestID: UUID()) { stale.append($0) }
    client.queue.sync {}
    pump { stale.count == 1 }
    check(stale == [.cancelled] && events(peer).isEmpty, "old target cannot send after foreground return")
}
do {
    let (client, peer) = legacyClient()
    let a = client.captureVisionTextTarget()!
    _ = client.catalog(WindowList(macName: "Fixture", windows: [], active: .window(9)), from: peer)
    _ = client.catalog(WindowList(macName: "Fixture", windows: [], active: .desktop), from: peer)
    client.queue.sync {}
    check(a != client.captureVisionTextTarget(), "A B A catalog cannot restore original permit and scope")
    let current = client.captureVisionTextTarget()!
    _ = client.link.hold(peer)
    var outcomes: [SessionLink.Submission.Outcome] = []
    client.submitVisionText("observed old source", target: current, requestID: UUID()) { outcomes.append($0) }
    client.queue.sync {}
    client.observe(WindowList(macName: "Fixture", windows: [], active: .window(20)), from: peer)
    pump { outcomes.count == 1 }
    _ = client.link.unhold(peer)
    check(outcomes == [.cancelled] && events(peer).isEmpty, "network source observation revokes held text before main catalog applies")
}
do {
    let (client, peer) = legacyClient()
    let target = client.captureVisionTextTarget()!
    _ = client.link.hold(peer)
    var outcomes: [SessionLink.Submission.Outcome] = []
    client.submitVisionText("route", target: target, requestID: UUID()) { outcomes.append($0) }
    client.queue.sync {}
    client.moving = StreamClient.Move(connection: NWConnection())
    pump { outcomes.count == 1 }
    _ = client.link.unhold(peer)
    check(client.captureVisionTextTarget() == nil && outcomes == [.cancelled] && events(peer).isEmpty,
          "route start revokes pending text before completion")
}
do {
    let client = StreamClient(), peer = NWConnection()
    client.connection = peer
    client.setVisionPresentationForeground(true)
    let epoch = VideoEpoch(generation: "A", source: .desktop,
                          geometry: VideoEpoch.Geometry(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
    let catalog = WindowList(macName: "Fixture", windows: [], active: .desktop, inputGeneration: "A",
                             presentationInput: 1, videoEpoch: epoch)
    _ = client.catalog(catalog, from: peer)
    check(client.captureVisionTextTarget() == nil, "modern capture requires presented epoch permit")
    let layer = NSObject()
    client.ready(VisionPresentation.Ticket(epoch: epoch, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(layer)))
    let target = client.captureVisionTextTarget()!
    let gate = DispatchSemaphore(value: 0)
    client.queue.async { gate.wait() }
    var outcomes: [SessionLink.Submission.Outcome] = []
    client.submitVisionText("obsolete", target: target, requestID: UUID()) { outcomes.append($0) }
    let next = VideoEpoch(generation: "A", source: .desktop, geometry: epoch.geometry, width: 800, height: 600)
    client.observe(WindowList(macName: "Fixture", windows: [], active: .desktop, inputGeneration: "A",
                              presentationInput: 1, videoEpoch: next), from: peer)
    gate.signal()
    client.queue.sync {}
    pump { outcomes.count == 1 }
    check(outcomes == [.cancelled] && events(peer).isEmpty && client.link.inputsOnSession == 0,
          "network epoch change refuses captured text while main target is stale")
}
for (modern, layoutBeforeCallback) in [(false, true), (false, false), (true, true), (true, false)] {
    let (client, peer) = legacyClient()
    let controls = VisionInputSession()
    controls.bind(client)
    controls.allowed = true
    let bounds = CGRect(x: 0, y: 0, width: 1240, height: 140)
    let video = CGSize(width: 64, height: 64)
    controls.setGeometry(.init(bounds: bounds, video: video))
    controls.allowed = false
    let layer = NSObject()
    if modern {
        let epoch = VideoEpoch(generation: "draft-layout", source: .desktop,
            geometry: .init(x: 0, y: 0, width: 64, height: 64), width: 64, height: 64)
        _ = client.catalog(WindowList(macName: "Fixture", windows: [], active: .desktop,
            inputGeneration: epoch.generation, presentationInput: 1, videoEpoch: epoch), from: peer)
        client.ready(VisionPresentation.Ticket(epoch: epoch, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(layer)))
    }
    let workspace = DraftWorkspace(client)
    workspace.textDraft = VisionTextDraft(target: client.captureVisionTextTarget()!)
    guard case .editing(let editor) = workspace.textDraft!.phase else { fatalError("editing required") }
    check(workspace.textDraft!.review(VisionDraftObservation(editorID: editor.id, revision: 1,
        text: "remote fixture 41", marked: false, composition: VisionDraftComposition())), "layout fixture reviews actual draft")
    let command = workspace.textDraft!.beginSubmission(currentTarget: client.captureVisionTextTarget())!
    var outcomes: [SessionLink.Submission.Outcome] = []
    client.submitVisionText(command.0.text, target: command.0.target, requestID: command.1) { outcome in
        outcomes.append(outcome)
        workspace.textDraft?.finish(reviewID: command.0.id, requestID: command.1, submitted: outcome == .submitted)
    }
    client.queue.sync {}
    if !layoutBeforeCallback { pump { outcomes.count == 1 } }
    let scope = client.visionTextScope
    controls.setGeometry(.init(bounds: CGRect(x: 0, y: 0, width: 1240, height: 119.5), video: video))
    if client.visionTextScope != scope { workspace.scopeChanged() }
    check(workspace.draftShown && workspace.textDraft != nil, "modal layout preserves draft sheet after actual send")
    pump { outcomes.count == 1 }
    check(outcomes == [.submitted] && events(peer).filter { $0 == .text("remote fixture 41") }.count == 1,
          "layout has one text handoff and one terminal callback")
    if case .submitted? = workspace.textDraft?.phase { check(true, "layout preserves submitted acknowledgement state") }
    else { check(false, "layout preserves submitted acknowledgement state") }
    client.setVisionPresentationForeground(false)
    workspace.scopeChanged()
    check(!workspace.draftShown && workspace.textDraft == nil, "scene loss still clears draft after modal layout")
}
do {
    let (client, peer) = legacyClient()
    let controls = VisionInputSession()
    controls.bind(client)
    controls.allowed = true
    let geometry = VisionPointer.Geometry(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), video: CGSize(width: 64, height: 64))
    controls.setGeometry(geometry)
    _ = client.link.hold(peer)
    var outcomes: [SessionLink.Submission.Outcome] = []
    client.submitVisionText("queued", target: client.captureVisionTextTarget()!, requestID: UUID()) { outcomes.append($0) }
    client.queue.sync {}
    controls.setGeometry(.init(bounds: CGRect(x: 0, y: 0, width: 100, height: 80), video: geometry.video))
    client.queue.sync {}
    pump { outcomes.count == 1 }
    _ = client.link.unhold(peer)
    check(outcomes == [.cancelled] && events(peer).isEmpty, "active pointer geometry still cancels queued input")
}
print("RESULT_ASSERTIONS \(checks)")
