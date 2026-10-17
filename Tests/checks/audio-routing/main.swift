// Task: ccr-cross-device-mac-audio-20261016. Baseline d812ec1.
// Architect: caller observes state, sends {revision, expected defaults, optional input/output},
// then consumes the host reply and broadcast. Two candidate shapes were compared:
// (A) per-direction controllers/revisions; (B) one inventory + transaction owner.
// B wins on shared-default CAS, serialization, rollback ownership and smaller coordinator API.
// Graft from A: omit either direction to preserve it. Hardware policy stays behind read/select;
// protocol carries physical endpoint UIDs only. This is sequential design/review, no model panel.
// Ground: StreamServer bounds messages; the coordinator knows TLS routes and current trust,
// serializes commands, and addresses replies per connection. AudioHardwareRoutes owns revision,
// HAL writes, readback and conditional rollback. Polling only observes; no startup auto-selection.
import Foundation
import CoreAudio
import StreamProtocol

var passed = 0
var failed = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { passed += 1 } else { failed += 1; print("FAIL \(name)") }
}
enum FixtureFailure: Error { case read }
final class FakeHardware: AudioRouteHardware {
    var inventory = AudioRouteInventory(endpoints: [
        AudioRouteEndpoint(uid: "in-a", name: "Built-in microphone", input: true, output: false),
        AudioRouteEndpoint(uid: "in-b", name: "USB microphone", input: true, output: false),
        AudioRouteEndpoint(uid: "out-a", name: "Built-in speaker", input: false, output: true),
        AudioRouteEndpoint(uid: "out-b", name: "Bluetooth speaker", input: false, output: true)
    ], defaults: AudioRouteDefaults(inputUID: "in-a", outputUID: "out-a"))
    var writes: [(AudioRouteDirection, String)] = []
    var intents: [AudioRouteWriteIntent] = []
    var reads = 0
    var beforeRead: ((FakeHardware) -> Void)?
    var write: ((FakeHardware, AudioRouteDirection, String, AudioRouteDefaults) -> AudioRouteWrite)?
    func read() throws -> AudioRouteInventory {
        reads += 1; beforeRead?(self)
        if failReads { throw FixtureFailure.read }
        return inventory
    }
    var failReads = false
    func assign(_ direction: AudioRouteDirection, _ uid: String) {
        if direction == .input { inventory.defaults.inputUID = uid } else { inventory.defaults.outputUID = uid }
    }
    func compareAndSet(_ direction: AudioRouteDirection, uid: String, expected: AudioRouteDefaults,
                       intent: AudioRouteWriteIntent) -> AudioRouteWrite {
        guard inventory.defaults == expected else { return .refused }
        writes.append((direction, uid))
        intents.append(intent)
        if let write { return write(self, direction, uid, expected) }
        assign(direction, uid)
        return .attempted(success: true)
    }
}
func request(_ state: AudioRouteState, input: String? = nil, output: String? = nil) -> AudioRouteSelection {
    AudioRouteSelection(revision: state.revision, expected: state.defaults, inputUID: input, outputUID: output)
}

do {
    let h = FakeHardware(); let owner = AudioHardwareRoutes(hardware: h)
    let a = owner.observe(); let b = owner.observe()
    check("observation stable", a == b)
    check("observation never switches", h.writes.isEmpty)
    let change = request(a, input: "in-b")
    let reply = owner.select(change)
    check("input accepted", reply.result == .applied && reply.defaults.inputUID == "in-b")
    check("output untouched", reply.defaults.outputUID == "out-a" && h.writes.count == 1)
    check("request ID echoed", reply.answering == change.requestID)
    check("revision consumed", reply.revision != a.revision)
    check("replay stale", owner.select(change).result == .stale && h.writes.count == 1)
    let otherClient = request(a, output: "out-b")
    check("other client stale", owner.select(otherClient).result == .stale)
    let output = owner.select(request(owner.observe(), output: "out-b"))
    check("independent output", output.result == .applied && output.defaults.inputUID == "in-b" && output.defaults.outputUID == "out-b")
    let noOp = request(owner.observe(), output: "out-b")
    check("no-op consumes revision without setter", owner.select(noOp).result == .unchanged && h.writes.count == 2)
    check("no-op replay stale", owner.select(noOp).result == .stale)
}
do {
    let h = FakeHardware(); let owner = AudioHardwareRoutes(hardware: h)
    let a = owner.observe()
    h.inventory.defaults.outputUID = "out-b"
    check("external default invalidates revision", owner.select(request(a, input: "in-b")).result == .stale)
    let b = owner.observe()
    h.inventory.endpoints.removeLast()
    check("hotplug invalidates revision", owner.select(request(b, input: "in-b")).result == .stale)
    check("external changes have no setters", h.writes.isEmpty)
    let fresh = owner.observe()
    var incorrect = request(fresh, input: "in-b"); incorrect.expected.inputUID = "other"
    check("expected defaults required", owner.select(incorrect).result == .conflict)
    check("wrong direction rejected", owner.select(request(fresh, input: "out-a")).result == .invalid)
    check("unknown UID rejected", owner.select(request(fresh, output: "peer-vision-speaker")).result == .invalid)
    check("empty selection rejected", owner.select(request(fresh)).result == .invalid)
    check("oversize UID rejected", owner.select(request(fresh, input: String(repeating: "a", count: 257))).result == .invalid)
    check("control UID rejected", owner.select(request(fresh, input: "in-b\n")).result == .invalid)
    h.failReads = true
    check("unavailable catalog clears availability", !owner.observe().available)
    check("unavailable selection refused", owner.select(request(owner.observe(), input: "in-b")).result == .unavailable)
    check("invalid/unavailable never switch", h.writes.isEmpty)
}
do {
    let h = FakeHardware(); let owner = AudioHardwareRoutes(hardware: h)
    let a = owner.observe()
    let result = owner.select(request(a, input: "in-b", output: "out-b"))
    check("two-direction transaction", result.result == .applied && h.writes.count == 2)
    check("fresh observer sees effective defaults", owner.observe().defaults == result.defaults)
}
for writeCanHaveEffect in [false, true] {
    let h = FakeHardware(); let owner = AudioHardwareRoutes(hardware: h); let old = owner.observe()
    h.write = { h, d, uid, _ in
        if uid == "out-b" {
            if writeCanHaveEffect { h.assign(d, uid) }
            return .attempted(success: false)
        }
        h.assign(d, uid); return .attempted(success: true)
    }
    let reply = owner.select(request(old, input: "in-b", output: "out-b"))
    check("setter failure restored \(writeCanHaveEffect)", reply.result == .failed && reply.defaults == old.defaults)
    check("failure consumes revision \(writeCanHaveEffect)", reply.revision != old.revision)
}
do {
    let h = FakeHardware(); let owner = AudioHardwareRoutes(hardware: h); let a = owner.observe()
    h.write = { h, d, uid, _ in
        if uid == "in-b" { return .attempted(success: true) }
        h.assign(d, uid); return .attempted(success: true)
    }
    let reply = owner.select(request(a, input: "in-b"))
    check("successful setter still needs readback", reply.result == .conflict && reply.defaults == a.defaults)
}
do {
    let h = FakeHardware(); let owner = AudioHardwareRoutes(hardware: h); let a = owner.observe()
    h.beforeRead = { h in if h.reads == 3 { h.inventory.defaults.outputUID = "out-b" } }
    let reply = owner.select(request(a, input: "in-b"))
    check("CAS catches race after revision validation", reply.result == .conflict && h.writes.isEmpty)
    check("conflict reply reports external state", reply.defaults.outputUID == "out-b")
}
do {
    let h = FakeHardware(); let owner = AudioHardwareRoutes(hardware: h); let a = owner.observe()
    h.write = { h, d, uid, _ in
        if uid == "out-b" {
            h.inventory.defaults.inputUID = "external-input"
            return .refused
        }
        h.assign(d, uid); return .attempted(success: true)
    }
    let reply = owner.select(request(a, input: "in-b", output: "out-b"))
    check("rollback preserves third-party choice", reply.defaults.inputUID == "external-input" && h.writes.count == 2)
    check("rollback incompleteness explicit", reply.result == .rollbackFailed)
}
do {
    let h = FakeHardware(); let owner = AudioHardwareRoutes(hardware: h); let a = owner.observe()
    h.write = { h, d, uid, _ in
        if uid == "out-b" || uid == "in-a" { return .attempted(success: false) }
        h.assign(d, uid); return .attempted(success: true)
    }
    let reply = owner.select(request(a, input: "in-b", output: "out-b"))
    check("rollback failure reports actual partial route", reply.result == .rollbackFailed && reply.defaults.inputUID == "in-b" && reply.defaults.outputUID == "out-a")
}
do {
    let h = FakeHardware(); h.inventory.defaults.inputUID = "virtual-original"
    let owner = AudioHardwareRoutes(hardware: h); let a = owner.observe()
    check("virtual effective default truthful", a.defaults.inputUID == "virtual-original" && !a.endpoints.contains { $0.uid == "virtual-original" })
    h.write = { h, d, uid, _ in
        if uid == "out-b" { return .attempted(success: false) }
        h.assign(d, uid); return .attempted(success: true)
    }
    check("restore original virtual default only on failure", owner.select(request(a, input: "in-b", output: "out-b")).defaults == a.defaults)
    check("virtual restoration has explicit rollback intent", h.intents.last == .rollback && h.writes.last?.1 == "virtual-original")
}
do {
    let h = FakeHardware(); let owner = AudioHardwareRoutes(hardware: h); let a = owner.observe()
    h.write = { h, d, uid, _ in
        h.assign(d, uid); h.failReads = true
        return .attempted(success: true)
    }
    let reply = owner.select(request(a, input: "in-b"))
    check("lost readback cannot claim restoration", reply.result == .rollbackFailed && !reply.available)
    check("lost readback never blindly writes old defaults", h.writes.count == 1)
}
do {
    let h = FakeHardware(); h.inventory.defaults.inputUID = nil
    let owner = AudioHardwareRoutes(hardware: h); let a = owner.observe()
    check("missing rollback target fails closed", owner.select(request(a, input: "in-b")).result == .unavailable && h.writes.isEmpty)
    let second = AudioHardwareRoutes(hardware: FakeHardware()).observe()
    check("host restart does not reuse revision", a.revision != second.revision)
}
check("virtual and aggregate transports excluded", !CoreAudioRouteHardware.physical(kAudioDeviceTransportTypeVirtual) && !CoreAudioRouteHardware.physical(kAudioDeviceTransportTypeAggregate) && !CoreAudioRouteHardware.physical(kAudioDeviceTransportTypeUnknown))
check("USB Bluetooth and built-in admitted", CoreAudioRouteHardware.physical(kAudioDeviceTransportTypeUSB) && CoreAudioRouteHardware.physical(kAudioDeviceTransportTypeBluetooth) && CoreAudioRouteHardware.physical(kAudioDeviceTransportTypeBuiltIn))
for mask in 0..<32 {
    check("authorization truth table \(mask)", AudioRoutingPolicy.authorized(encrypted: mask & 1 != 0, paired: mask & 2 != 0,
        connected: mask & 4 != 0, synthetic: mask & 8 != 0, shuttingDown: mask & 16 != 0) == (mask == 7))
}
check("control capped before body receive", StreamMessage.clientPayloadLimit(for: .changeAudioRoute) == 2048)
check("refresh empty on wire", StreamMessage.clientPayloadLimit(for: .fetchAudioRoutes) == 0)
check("state wrong direction forbidden", StreamMessage.clientPayloadLimit(for: .audioRoutes) < 0)
check("commands wrong direction forbidden", StreamMessage.hostPayloadLimit(for: .changeAudioRoute) < 0 && StreamMessage.hostPayloadLimit(for: .fetchAudioRoutes) < 0)
do {
    let a = AudioHardwareRoutes(hardware: FakeHardware()).observe()
    let r = request(a, input: "in-b")
    let selectionRoundtrip = try JSONDecoder().decode(AudioRouteSelection.self, from: JSONEncoder().encode(r))
    let stateRoundtrip = try JSONDecoder().decode(AudioRouteState.self, from: JSONEncoder().encode(a))
    check("selection wire roundtrip", selectionRoundtrip == r)
    check("state wire roundtrip", stateRoundtrip == a)
    let maxEndpoint = AudioRouteEndpoint(uid: String(repeating: "\"", count: 256), name: String(repeating: "\"", count: 128), input: true, output: true)
    let worst = AudioRouteState(revision: UUID(), endpoints: Array(repeating: maxEndpoint, count: 128), defaults: a.defaults, available: true)
    let worstSize = try JSONEncoder().encode(worst).count
    check("bounded catalog fits state frame", worstSize <= AudioRoutingPolicy.maxStatePayload)
} catch { check("wire encoding unexpected error", false) }

// Production coordinator methods are copied verbatim by the runner into a fixture with fake
// connections, trust and server. No socket, CoreAudio read or live host is used by this suite.
runCoordinatorChecks()
print("Audio routing: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
