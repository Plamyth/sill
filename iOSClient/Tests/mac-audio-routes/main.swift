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
rejects("no catalog refuses selection") { _ = try session.request(inputUID: nil, outputUID: extra.uid) }
session.receive(initial, from: bID)
check("other peer cannot seed catalog", session.state == nil)
session.receive(initial, from: aID)
check("current peer catalog accepted", session.state == initial)
rejects("no direction refuses selection") { _ = try session.request(inputUID: nil, outputUID: nil) }
rejects("selected default is no change") { _ = try session.request(inputUID: input.uid, outputUID: output.uid) }
rejects("output cannot be input") { _ = try session.request(inputUID: extra.uid, outputUID: nil) }
rejects("unknown output rejected") { _ = try session.request(inputUID: nil, outputUID: "fake") }

let request = try session.request(inputUID: nil, outputUID: extra.uid)
check("only explicit output sent", request.inputUID == nil && request.outputUID == extra.uid)
check("request binds exact revision and both expected defaults", request.revision == initial.revision && request.expected == defaults)
check("request ID retained as pending", session.pending?.requestID == request.requestID)
check("send only records waiting", session.outcome?.title == "Mac의 적용 결과를 기다리는 중…")
check("selection JSON roundtrip", Wire.decode(AudioRouteSelection.self, from: Wire.encode(request)) == request)
rejects("only one in flight") { _ = try session.request(inputUID: nil, outputUID: extra.uid) }

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

rejects("current input stays unchanged") { _ = try session.request(inputUID: input.uid, outputUID: nil) }

for result in [AudioRouteResult.unchanged, .stale, .invalid, .conflict, .unavailable, .failed, .rollbackFailed] {
    var trial = MacAudioRouteSession()
    trial.bind(aID)
    trial.receive(initial, from: aID)
    let sent = try trial.request(inputUID: nil, outputUID: extra.uid)
    let reply = AudioRouteState(revision: initial.revision, endpoints: initial.endpoints,
                                defaults: initial.defaults, available: true,
                                answering: sent.requestID, result: result)
    trial.receive(reply, from: aID)
    check("\(result) clears only matching request", trial.pending == nil)
    check("\(result) exposes host result", trial.outcome?.title.isEmpty == false)
    check("\(result) never claims applied", trial.outcome?.isSuccess == (result == .unchanged))
}

var waiting = MacAudioRouteSession()
waiting.bind(aID)
waiting.receive(initial, from: aID)
let timed = try waiting.request(inputUID: nil, outputUID: extra.uid)
waiting.expire(UUID(), on: aID)
check("wrong timeout token ignored", waiting.pending?.requestID == timed.requestID)
waiting.expire(timed.requestID, on: bID)
check("wrong peer timeout ignored", waiting.pending?.requestID == timed.requestID)
waiting.expire(timed.requestID, on: aID)
check("timeout is indeterminate and clears catalog", waiting.pending == nil && waiting.state == nil && waiting.outcome?.isSuccess == false)
waiting.receive(answered, from: aID)
check("late ACK never retroactively claims applied", waiting.outcome?.isSuccess == false)
waiting.bind(bID)
check("peer change clears old state and result", waiting.state == nil && waiting.outcome == nil && waiting.pending == nil)
waiting.receive(initial, from: aID)
check("old peer cannot repopulate new session", waiting.state == nil)

var unavailable = MacAudioRouteSession()
unavailable.bind(aID)
unavailable.receive(AudioRouteState(revision: UUID(), endpoints: [],
                                    defaults: AudioRouteDefaults(inputUID: nil, outputUID: nil), available: false), from: aID)
rejects("unavailable inventory never selects") { _ = try unavailable.request(inputUID: nil, outputUID: extra.uid) }
unavailable.receive(AudioRouteState(revision: UUID(), endpoints: [input, input], defaults: defaults, available: true), from: aID)
check("duplicate endpoint IDs rejected", unavailable.state?.available == false)

var virtual = MacAudioRouteSession()
virtual.bind(aID)
virtual.receive(AudioRouteState(revision: UUID(), endpoints: [input, output, extra],
                                defaults: AudioRouteDefaults(inputUID: "virtual.input", outputUID: "virtual.output"),
                                available: true), from: aID)
let virtualRequest = try virtual.request(inputUID: input.uid, outputUID: nil)
check("virtual actual defaults retained in CAS", virtualRequest.expected.inputUID == "virtual.input" &&
      virtualRequest.expected.outputUID == "virtual.output" && virtualRequest.outputUID == nil)

print("\(checks) Mac audio routing checks passed")
