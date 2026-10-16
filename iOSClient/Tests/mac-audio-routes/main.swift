import Foundation

var checks = 0
func check(_ label: String, _ passes: @autoclosure () -> Bool) {
    checks += 1
    if !passes() { fatalError(label) }
}

func rejects(_ label: String, _ body: () throws -> Void) {
    checks += 1
    do { try body(); fatalError(label) } catch is MacAudioRouteSession.Problem { }
    catch { fatalError("\(label): \(error)") }
}

final class Peer {}
let a = Peer()
let b = Peer()
let aID = ObjectIdentifier(a)
let bID = ObjectIdentifier(b)
let input = AudioRouteEndpoint(uid: "mac.input", name: "Mac 내장 마이크", input: true, output: false)
let output = AudioRouteEndpoint(uid: "mac.output", name: "Mac 내장 스피커", input: false, output: true)
let extra = AudioRouteEndpoint(uid: "usb.output", name: "USB 스피커", input: false, output: true)
let defaults = AudioRouteDefaults(inputUID: "mac.input", outputUID: "mac.output")
let initial = AudioRouteState(revision: UUID(), endpoints: [input, output, extra], defaults: defaults, available: true)

check("208 host state kind", StreamMessageKind.audioRoutes.rawValue == 208)
check("209 selection kind", StreamMessageKind.changeAudioRoute.rawValue == 209)
check("210 fetch kind", StreamMessageKind.fetchAudioRoutes.rawValue == 210)
check("selection cap", StreamMessage.clientPayloadLimit(for: .changeAudioRoute) == 2048)
check("fetch empty cap", StreamMessage.clientPayloadLimit(for: .fetchAudioRoutes) == 0)
check("state cap", StreamMessage.hostPayloadLimit(for: .audioRoutes) == 512 * 1024)
check("wrong wire directions forbidden", StreamMessage.clientPayloadLimit(for: .audioRoutes) < 0 &&
      StreamMessage.hostPayloadLimit(for: .changeAudioRoute) < 0 &&
      StreamMessage.hostPayloadLimit(for: .fetchAudioRoutes) < 0)
check("state JSON roundtrip", Wire.decode(AudioRouteState.self, from: Wire.encode(initial)) == initial)

var session = MacAudioRouteSession()
session.bind(aID)
rejects("no catalog refuses selection") {
    _ = try session.request(displayed: .init(revision: UUID(), defaults: defaults), inputUID: nil, outputUID: extra.uid)
}
session.receive(initial, from: bID)
check("other peer cannot seed catalog", session.state == nil)
session.receive(initial, from: aID)
check("current peer catalog accepted", session.state == initial)
let displayed = session.catalogToken!
rejects("no direction refuses selection") { _ = try session.request(displayed: displayed, inputUID: nil, outputUID: nil) }
rejects("selected default is no change") { _ = try session.request(displayed: displayed, inputUID: input.uid, outputUID: output.uid) }
rejects("output cannot be input") { _ = try session.request(displayed: displayed, inputUID: extra.uid, outputUID: nil) }
rejects("unknown output rejected") { _ = try session.request(displayed: displayed, inputUID: nil, outputUID: "fake") }

let request = try session.request(displayed: displayed, inputUID: nil, outputUID: extra.uid)
check("only explicit output sent", request.inputUID == nil && request.outputUID == extra.uid)
check("request binds exact revision and both expected defaults", request.revision == initial.revision && request.expected == defaults)
check("request ID retained as pending", session.pending?.requestID == request.requestID)
check("send only records waiting", session.outcome?.title == "Mac의 적용 결과를 기다리는 중…")
check("selection JSON roundtrip", Wire.decode(AudioRouteSelection.self, from: Wire.encode(request)) == request)
rejects("only one in flight") { _ = try session.request(displayed: displayed, inputUID: nil, outputUID: extra.uid) }

let pushed = AudioRouteState(revision: UUID(), endpoints: initial.endpoints, defaults: defaults, available: true)
session.receive(pushed, from: aID)
check("unsolicited host update keeps pending", session.pending?.requestID == request.requestID)
let foreign = AudioRouteState(revision: UUID(), endpoints: initial.endpoints, defaults: defaults,
                              available: true, answering: UUID(), result: .applied)
session.receive(foreign, from: aID)
check("foreign ACK cannot mark success", session.pending?.requestID == request.requestID && session.outcome?.isSuccess == false)
let answered = AudioRouteState(revision: UUID(), endpoints: initial.endpoints,
                               defaults: AudioRouteDefaults(inputUID: input.uid, outputUID: extra.uid),
                               available: true, answering: request.requestID, result: .applied)
session.receive(answered, from: aID)
check("matching ACK clears pending", session.pending == nil)
check("applied shown only after matching ACK", session.outcome?.isSuccess == true && session.state == answered)

rejects("current input stays unchanged") { _ = try session.request(displayed: session.catalogToken!, inputUID: input.uid, outputUID: nil) }

for result in [AudioRouteResult.stale, .invalid, .conflict, .unavailable, .failed, .rollbackFailed] {
    var trial = MacAudioRouteSession()
    trial.bind(aID)
    trial.receive(initial, from: aID)
    let sent = try trial.request(displayed: trial.catalogToken!, inputUID: nil, outputUID: extra.uid)
    let reply = AudioRouteState(revision: initial.revision, endpoints: initial.endpoints,
                                defaults: initial.defaults, available: true,
                                answering: sent.requestID, result: result)
    trial.receive(reply, from: aID)
    check("\(result) clears only matching request", trial.pending == nil)
    check("\(result) exposes host result", trial.outcome?.title.isEmpty == false)
    check("\(result) never claims applied", trial.outcome?.isSuccess == false)
}

var unchanged = MacAudioRouteSession()
unchanged.bind(aID)
unchanged.receive(initial, from: aID)
let unchangedRequest = try unchanged.request(displayed: unchanged.catalogToken!, inputUID: nil, outputUID: extra.uid)
unchanged.receive(AudioRouteState(revision: UUID(), endpoints: initial.endpoints,
                                  defaults: AudioRouteDefaults(inputUID: input.uid, outputUID: extra.uid),
                                  available: true, answering: unchangedRequest.requestID, result: .unchanged), from: aID)
check("unchanged requires consumed revision and desired readback", unchanged.outcome?.isSuccess == true)

var waiting = MacAudioRouteSession()
waiting.bind(aID)
waiting.receive(initial, from: aID)
let timed = try waiting.request(displayed: waiting.catalogToken!, inputUID: nil, outputUID: extra.uid)
waiting.expire(UUID(), on: aID)
check("wrong timeout token ignored", waiting.pending?.requestID == timed.requestID)
waiting.expire(timed.requestID, on: bID)
check("wrong peer timeout ignored", waiting.pending?.requestID == timed.requestID)
waiting.expire(timed.requestID, on: aID)
check("timeout is indeterminate and clears catalog", waiting.pending == nil && waiting.state == nil && waiting.outcome?.isSuccess == false)
waiting.receive(answered, from: aID)
check("late ACK refreshes catalog without reviving outcome", waiting.state == answered && waiting.outcome?.isSuccess == false)
waiting.bind(bID)
check("peer change clears old state and result", waiting.state == nil && waiting.outcome == nil && waiting.pending == nil)
waiting.receive(initial, from: aID)
check("old peer cannot repopulate new session", waiting.state == nil)

var unavailable = MacAudioRouteSession()
unavailable.bind(aID)
unavailable.receive(AudioRouteState(revision: UUID(), endpoints: [],
                                    defaults: AudioRouteDefaults(inputUID: nil, outputUID: nil), available: false), from: aID)
rejects("unavailable inventory never selects") {
    _ = try unavailable.request(displayed: .init(revision: UUID(), defaults: defaults), inputUID: nil, outputUID: extra.uid)
}
unavailable.receive(AudioRouteState(revision: UUID(), endpoints: [input, input], defaults: defaults, available: true), from: aID)
check("duplicate endpoint IDs rejected", unavailable.state?.available == false)

var virtual = MacAudioRouteSession()
virtual.bind(aID)
virtual.receive(AudioRouteState(revision: UUID(), endpoints: [input, output, extra],
                                defaults: AudioRouteDefaults(inputUID: "virtual.input", outputUID: "virtual.output"),
                                available: true), from: aID)
let virtualRequest = try virtual.request(displayed: virtual.catalogToken!, inputUID: input.uid, outputUID: nil)
check("virtual actual defaults retained in CAS", virtualRequest.expected.inputUID == "virtual.input" &&
      virtualRequest.expected.outputUID == "virtual.output" && virtualRequest.outputUID == nil)

for changed in [
    AudioRouteState(revision: UUID(), endpoints: initial.endpoints, defaults: initial.defaults, available: true),
    AudioRouteState(revision: initial.revision, endpoints: initial.endpoints,
                    defaults: AudioRouteDefaults(inputUID: input.uid, outputUID: extra.uid), available: true)
] {
    var trial = MacAudioRouteSession()
    trial.bind(aID)
    trial.receive(initial, from: aID)
    let shown = trial.catalogToken!
    trial.receive(changed, from: aID)
    do {
        _ = try trial.request(displayed: shown, inputUID: nil, outputUID: extra.uid)
        fatalError("changed displayed catalog was silently replaced")
    } catch MacAudioRouteSession.Problem.catalogChanged {
        check("displayed revision and defaults both fence selection", trial.pending == nil)
    }
}

for result in [AudioRouteResult.applied, .unchanged] {
    for (label, revision, replyDefaults) in [
        ("same revision", initial.revision, AudioRouteDefaults(inputUID: input.uid, outputUID: extra.uid)),
        ("wrong selected output", UUID(), defaults),
        ("wrong untouched input", UUID(), AudioRouteDefaults(inputUID: "other.input", outputUID: extra.uid))
    ] {
        var trial = MacAudioRouteSession()
        trial.bind(aID)
        trial.receive(initial, from: aID)
        let sent = try trial.request(displayed: trial.catalogToken!, inputUID: nil, outputUID: extra.uid)
        trial.receive(AudioRouteState(revision: revision, endpoints: initial.endpoints,
                                      defaults: replyDefaults, available: true,
                                      answering: sent.requestID, result: result), from: aID)
        check("\(result) with \(label) cannot claim success", trial.outcome?.isSuccess == false)
    }
    var pushedTrial = MacAudioRouteSession()
    pushedTrial.bind(aID)
    pushedTrial.receive(initial, from: aID)
    let sent = try pushedTrial.request(displayed: pushedTrial.catalogToken!, inputUID: nil, outputUID: extra.uid)
    let newer = UUID()
    pushedTrial.receive(AudioRouteState(revision: newer, endpoints: initial.endpoints,
                                        defaults: defaults, available: true), from: aID)
    pushedTrial.receive(AudioRouteState(revision: newer, endpoints: initial.endpoints,
                                        defaults: AudioRouteDefaults(inputUID: input.uid, outputUID: extra.uid),
                                        available: true, answering: sent.requestID, result: result), from: aID)
    check("\(result) ACK must consume a revision after a push", pushedTrial.outcome?.isSuccess == false)
}

var noInventory = MacAudioRouteSession()
noInventory.bind(aID)
noInventory.receive(initial, from: aID)
let noInventoryRequest = try noInventory.request(displayed: noInventory.catalogToken!, inputUID: nil, outputUID: extra.uid)
noInventory.receive(AudioRouteState(revision: UUID(), endpoints: [],
                                    defaults: AudioRouteDefaults(inputUID: nil, outputUID: nil),
                                    available: false, answering: noInventoryRequest.requestID, result: .applied), from: aID)
check("unavailable applied reply cannot claim success", noInventory.outcome?.isSuccess == false)

print("\(checks) Mac audio routing checks passed")
