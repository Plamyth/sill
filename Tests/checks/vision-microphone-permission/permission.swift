import Foundation
import StreamProtocol

var checks = 0, failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL \(name)") }
}
final class Peer {}
let object = Peer(), replacement = Peer()
let peer = ObjectIdentifier(object), other = ObjectIdentifier(replacement)
func catalog(_ capability: MicrophoneCapability? = MicrophoneCapability(peer: UUID(), destination: UUID(), generation: UUID())) -> WindowList {
    let generation = UUID().uuidString
    let epoch = VideoEpoch(generation: generation, source: .desktop,
        geometry: .init(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1)
    return WindowList(macName: "Test Mac", windows: [], active: .desktop,
        inputGeneration: generation, videoEpoch: epoch, microphone: capability)
}
func ready() -> IPadMicrophonePolicy {
    var policy = IPadMicrophonePolicy()
    _ = policy.setConnection(peer)
    _ = policy.observe(catalog(), from: peer)
    return policy
}
func starts(_ effects: [IPadMicrophonePolicy.Effect]) -> Int {
    effects.filter { if case .send(_, let control) = $0 { return control.operation == .start }; return false }.count
}

var p = ready()
let permission = p.toggle(), request = p.startRequestID!, scope = p.scope!
check(permission == [.requestPermission(peer, scope, request)] && p.phase == .authorizing,
      "explicit toggle requests scoped permission without host start")
check(p.receive(MicrophoneState(requestID: request, scope: scope, phase: .active, grantID: UUID()), from: peer).isEmpty,
      "host ACK before authorization cannot begin capture")
check(p.permissionResolved(true, requestID: UUID(), scope: scope, from: peer).isEmpty,
      "wrong permission request is inert")
check(p.permissionResolved(true, requestID: request, scope: scope, from: other).isEmpty,
      "wrong permission peer is inert")
check(starts(p.permissionResolved(true, requestID: request, scope: scope, from: peer)) == 1 && p.phase == .requesting,
      "matching permission emits exactly one host start")
check(p.permissionResolved(true, requestID: request, scope: scope, from: peer).isEmpty,
      "duplicate permission resolution is inert")

for allowed in [false, true] {
    var denied = ready()
    _ = denied.toggle()
    let effects = denied.permissionResolved(allowed, requestID: denied.startRequestID!, scope: denied.scope!,
        from: peer, microphoneAvailable: !allowed)
    check(starts(effects) == 0 && denied.startRequestID == nil && denied.canStart,
          "denial or unavailable hardware never starts host and requires another toggle")
}

for cancellation in ["cancel", "source", "peer", "background", "window"] {
    var cancelled = ready()
    _ = cancelled.toggle()
    let request = cancelled.startRequestID!, scope = cancelled.scope!
    let effects: [IPadMicrophonePolicy.Effect]
    switch cancellation {
    case "cancel": effects = cancelled.toggle()
    case "source": effects = cancelled.sourceWillChange()
    case "peer": effects = cancelled.setConnection(other)
    default: effects = cancelled.backgrounded()
    }
    check(starts(effects) == 0 && cancelled.phase != .authorizing,
          "\(cancellation) cancels authorization without host effects")
    check(cancelled.permissionResolved(true, requestID: request, scope: scope, from: peer).isEmpty,
          "\(cancellation) makes delayed permission inert")
}

var inactive = ready()
_ = inactive.toggle()
let inactiveRequest = inactive.startRequestID!, inactiveScope = inactive.scope!
check(inactive.inactive().isEmpty && inactive.phase == .authorizing && inactive.startRequestID == inactiveRequest,
      "inactive preserves permission wait for native active admission")
check(starts(inactive.permissionResolved(true, requestID: inactiveRequest, scope: inactiveScope, from: peer)) == 1,
      "native may consume stored permission when active again")
check(inactive.inactive().contains(.closeFrames) && inactive.phase == .stopping,
      "inactive after authorization stops transmission")

var cleanup = ready()
let sameCatalog = catalog()
_ = cleanup.observe(sameCatalog, from: peer)
_ = cleanup.toggle()
let cleanupRequest = cleanup.startRequestID!, cleanupScope = cleanup.scope!
_ = cleanup.permissionResolved(true, requestID: cleanupRequest, scope: cleanupScope, from: peer)
let failed = cleanup.receive(MicrophoneState(requestID: cleanupRequest, scope: cleanupScope, phase: .cleanupFailed, grantID: nil), from: peer)
check(cleanup.phase == .cleanupRequired && cleanup.hostCleanupRequired && !cleanup.canStart && failed.contains(.closeFrames),
      "host cleanup failure blocks consent and closes frames")
check(cleanup.toggle().isEmpty && cleanup.backgrounded().contains(.stopCapture) && cleanup.phase == .cleanupRequired,
      "toggle and background cannot erase host cleanup requirement")
_ = cleanup.sourceWillChange()
check(cleanup.phase == .cleanupRequired && cleanup.hostCleanupRequired,
      "source release preserves host cleanup requirement")
_ = cleanup.observe(catalog(nil), from: peer)
check(cleanup.phase == .cleanupRequired && !cleanup.canStart, "missing capability cannot clear cleanup failure")
let recovered = cleanup.observe(sameCatalog, from: peer)
check(cleanup.phase == .off && !cleanup.hostCleanupRequired && starts(recovered) == 0,
      "fresh supported catalog recovers cleanup without starting recording")
check(cleanup.toggle().count == 1 && cleanup.phase == .authorizing,
      "recovered host requires explicit authorization again")

print("RESULT_ASSERTIONS \(checks)")
print("RESULT_FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
