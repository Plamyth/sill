import Foundation

var checks = 0
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
let a = VisionAudioScope(connection: UUID(), source: 1)
let b = VisionAudioScope(connection: a.connection, source: 2)
let other = VisionAudioScope(connection: UUID(), source: 1)
var state = VisionAudioState()
check(!state.canEnable && state.phase == .off, "initial state cannot activate")
check(state.request(id: UUID(), now: 0) == nil, "packets and request cannot create missing eligibility")
state.update(.unsupported, foreground: true)
check(!state.canEnable, "unsupported host cannot subscribe")
state.update(.noSource, foreground: true)
check(!state.canEnable, "missing source cannot subscribe")
state.update(.available(a), foreground: false)
check(!state.canEnable, "background cannot subscribe")
state.update(.available(a), foreground: true)
check(state.canEnable, "eligible foreground exposes explicit Enable")
let first = state.request(id: UUID(), now: 10)!
check(!state.canEnable, "a pending request cannot mint another request")
check(!state.admits(first, now: 10), "request alone cannot admit packets")
check(state.acknowledge(id: UUID(), enabled: true, scope: a, now: 11, reason: nil) == nil, "wrong request response is ignored")
check(state.acknowledge(id: first.id, enabled: true, scope: other, now: 11, reason: nil) == nil, "other connection response is ignored")
check(state.acknowledge(id: first.id, enabled: true, scope: b, now: 11, reason: nil) == nil, "other source response is ignored")
check(state.acknowledge(id: first.id, enabled: true, scope: a, now: 11, reason: nil) == first, "matching acknowledgement permits waiting samples")
check(state.phase == .waiting(first, until: 19), "acknowledgement does not report rendering")
check(state.admits(first, now: 12), "only matching acknowledged grant admits")
check(state.rendered(first, now: 12) && state.phase == .rendering(first), "render callback establishes rendering")
state.underrun(first, now: 13)
check(state.phase == .waiting(first, until: 21), "underrun has a bounded fresh-samples wait")
check(state.stop() == first && !state.admits(first, now: 14), "Stop revokes previously acknowledged samples")
check(!state.rendered(first, now: 14), "late render completion cannot resurrect Stop")
check(state.acknowledge(id: first.id, enabled: true, scope: a, now: 14, reason: nil) == nil, "late acknowledgement cannot resurrect Stop")
let second = state.request(id: UUID(), now: 15)!
check(state.acknowledge(id: first.id, enabled: true, scope: a, now: 16, reason: nil) == nil, "old enabled response cannot satisfy new opt-in")
check(state.acknowledge(id: second.id, enabled: true, scope: a, now: 16, reason: nil) == second, "fresh request uses its own response")
check(state.update(.available(b), foreground: true) == second, "source change revokes before next samples")
check(state.phase == .off && !state.admits(second, now: 17), "source change never resumes automatically")
state.update(.available(a), foreground: true)
check(!state.admits(second, now: 18), "A to B to A cannot revive the previous grant")
let third = state.request(id: UUID(), now: 20)!
check(state.update(.available(other), foreground: true) == third, "connection handover revokes without connected Boolean")
check(!state.admits(third, now: 21), "old connection never supplies new context")
let fourth = state.request(id: UUID(), now: 22)!
check(state.update(.available(other), foreground: false) == fourth, "background revokes immediately")
state.update(.available(other), foreground: true)
check(state.phase == .off && !state.admits(fourth, now: 23), "foreground does not restore consent")
let fifth = state.request(id: UUID(), now: 30)!
check(state.expire(now: 37) == nil, "request stays bounded until its deadline")
check(state.expire(now: 38) == fifth && state.phase.grant == nil, "deadline revokes unanswered request")
check(state.acknowledge(id: fifth.id, enabled: true, scope: other, now: 39, reason: nil) == nil, "expired acknowledgement does not enable")
let sixth = state.request(id: UUID(), now: 40)!
check(state.acknowledge(id: sixth.id, enabled: false, scope: other, now: 41, reason: "refused") == nil, "host refusal grants no playback")
check(state.phase == .failed("refused") && !state.admits(sixth, now: 41), "host failure is visible and closed")
check(state.request(id: UUID(), now: .nan) == nil, "nonfinite clock cannot create unbounded request")
let seventh = state.request(id: UUID(), now: 50)!
_ = state.acknowledge(id: seventh.id, enabled: true, scope: other, now: 51, reason: nil)
check(state.expire(now: 59) == seventh, "ack without samples also has a bounded wait")
print("Vision audio consent: \(checks - failures)/\(checks) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
