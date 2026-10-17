import Foundation
#if canImport(StreamProtocol)
import StreamProtocol
#endif

var checks = 0
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
@MainActor func rejected(_ name: String, _ operation: () async throws -> Void) async {
    do { try await operation(); check(false, name) } catch { check(true, name) }
}
@main struct AudioRouteChecks {
@MainActor static func main() async throws {
typealias P = IPadAudioRoutePolicy
let off = P.Selection()
let input = P.Selection(input: .iPadMicrophone)
let output = P.Selection(output: .iPadPlayback)
let both = P.Selection(input: .iPadMicrophone, output: .iPadPlayback)

for mic in [false, true] {
    for playback in [false, true] {
        let supported = P.Capabilities(microphone: mic, playback: playback)
        check(supported.inputs == (mic ? [.off, .iPadMicrophone] : [.off]), "input choices are exactly the advertised paths")
        check(supported.outputs == (playback ? [.off, .iPadPlayback] : [.off]), "output choices are exactly the advertised paths")
        for selection in [off, input, output, both] {
            let legal = (selection.input == .off || mic) && (selection.output == .off || playback)
            do {
                let result = try P.actions(for: selection, capabilities: supported, current: off,
                                           canStartMicrophone: true, cleanupRequired: false)
                check(legal, "unsupported direction cannot create an action plan")
                check(result.microphone == (selection.input == .off ? nil : true), "input selection does not depend on output")
                check(result.playback == (selection.output == .off ? nil : true), "output selection does not depend on input")
            } catch { check(!legal, "unsupported selection is rejected") }
        }
    }
}
do {
    var offer = IPadAudioRouteOffer()
    check(!offer.offer(connected: false, hasSource: true, foreground: true), "disconnected screen never offers routes")
    check(!offer.offer(connected: true, hasSource: false, foreground: true), "first catalog waits for a real stream source")
    check(!offer.offer(connected: true, hasSource: true, foreground: false), "background never offers routes")
    check(offer.offer(connected: true, hasSource: true, foreground: true), "first admitted foreground source offers once")
    check(!offer.offer(connected: true, hasSource: true, foreground: true), "repeated catalog does not reopen chooser")
    _ = offer.offer(connected: false, hasSource: false, foreground: true)
    check(offer.offer(connected: true, hasSource: true, foreground: true), "new connection gets a fresh choice")
}
do {
    let c = StreamClient(); c.advertise(); c.offerInitialAudioRoutes(); c.showAudioRoutes()
    check(c.audioRouteChooserPresented, "first connection and menu open the same chooser")
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "opening chooser never sends consent")
    check(c.remoteAudioStatus == .off && c.microphonePhase == .off, "new capability starts with both directions off")
    try await c.applyAudioRoutes(off, context: c.audioRouteContext)
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "confirming both off has no effect")
}
do {
    let c = StreamClient(); c.advertise(); let context = c.audioRouteContext
    try await c.applyAudioRoutes(output, context: context)
    check(c.playbackRequests.count == 1 && c.playbackRequests[0].enabled, "output-only choice requests playback once")
    check(c.microphoneRequests.isEmpty, "output-only choice never opens microphone")
    check(c.played == 0, "requesting playback does not bypass host ACK")
    try await c.applyAudioRoutes(output, context: context)
    check(c.playbackRequests.count == 1, "repeated apply cannot toggle pending playback off")
    try await c.applyAudioRoutes(off, context: context)
    check(c.playbackRequests.count == 2 && !c.playbackRequests[1].enabled && c.stopped == 1, "explicit output off revokes immediately")
    let old = c.playbackRequests[0]
    c.remoteAudioControl.receive(RemoteAudioState(enabled: true, requestID: old.requestID), from: context!.peer)
    c.remoteAudioControl.receiveAudio(Data([1]), from: context!.peer)
    check(c.played == 0, "late playback ACK after off never re-enables output")
}
do {
    let c = StreamClient(); c.advertise(); let context = c.audioRouteContext
    try await c.applyAudioRoutes(input, context: context)
    check(c.microphoneRequests.count == 1 && c.microphoneRequests[0].operation == .start, "input-only choice requests microphone consent once")
    check(c.playbackRequests.isEmpty, "input-only choice does not enable playback")
    check(!c.microphoneEffects.contains { if case .beginCapture = $0 { true } else { false } }, "microphone request does not bypass host ACK")
    try await c.applyAudioRoutes(input, context: context)
    check(c.microphoneRequests.count == 1, "repeated apply cannot cancel pending input")
    try await c.applyAudioRoutes(off, context: context)
    check(c.microphoneRequests.count == 2 && c.microphoneRequests[1].operation == .stop, "input off cancels pending microphone start")
    let start = c.microphoneRequests[0]
    let late = MicrophoneState(requestID: start.requestID, scope: start.scope, phase: .active, grantID: UUID())
    check(c.microphonePolicy.receive(late, from: context!.peer).isEmpty, "cancelled microphone ACK cannot start capture")
}
do {
    let c = StreamClient(); c.advertise(); let context = c.audioRouteContext
    try await c.applyAudioRoutes(both, context: context)
    check(c.playbackRequests.count == 1 && c.microphoneRequests.count == 1, "input and output can be requested together")
    try await c.applyAudioRoutes(input, context: context)
    check(c.playbackRequests.count == 2 && !c.playbackRequests.last!.enabled && c.microphoneRequests.count == 1,
          "changing output preserves selected microphone consent")
}
for unsupportedInput in [true, false] {
    let c = StreamClient(); c.advertise(playback: unsupportedInput, microphone: !unsupportedInput)
    await rejected("unsupported direction rejects the entire apply before side effects") { try await c.applyAudioRoutes(both, context: c.audioRouteContext) }
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "unsupported target cannot partially enable another direction")
}
for event in 0..<6 {
    let c = StreamClient(); c.advertise(); let context = c.audioRouteContext
    switch event {
    case 0: c.connection = RoutePeer(); c.advertise()
    case 1: c.active = .window(7)
    case 2: c.advertise()
    case 3: c.appInForeground = false
    case 4: c.connected = false
    default: c.connection = nil
    }
    await rejected("stale peer, source, grant scope, background, or disconnected context cannot apply") { try await c.applyAudioRoutes(both, context: context) }
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "stale context has no consent side effects")
}
do {
    let c = StreamClient(); c.advertise(); c.microphoneCleanupProblem = "정리 필요"
    await rejected("cleanup failure prevents combined input start") { try await c.applyAudioRoutes(both, context: c.audioRouteContext) }
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "cleanup refusal cannot partially start playback")
}
do {
    let c = StreamClient(); c.advertise(); let context = c.audioRouteContext
    try await c.applyAudioRoutes(input, context: context); try await c.applyAudioRoutes(off, context: context)
    let count = c.microphoneRequests.count
    await rejected("stop awaiting ACK cannot start another microphone grant") { try await c.applyAudioRoutes(both, context: context) }
    check(c.microphoneRequests.count == count && c.playbackRequests.isEmpty, "stopping microphone remains bounded")
}
do {
    let c = StreamClient(); c.advertise(playback: false, microphone: false); c.offerInitialAudioRoutes()
    check(c.audioRouteChooserPresented && c.audioRouteCapabilities.inputs == [.off] && c.audioRouteCapabilities.outputs == [.off],
          "unsupported host gets an honest off-only first chooser")
    c.audioRouteChooserPresented = false; c.offerInitialAudioRoutes()
    check(!c.audioRouteChooserPresented, "dismissing without applying does not prompt again")
    c.showAudioRoutes()
    check(c.audioRouteChooserPresented && c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "menu reopens without enabling unsupported routes")
}
do {
    let c = StreamClient(); c.active = .none; c.showAudioRoutes(); c.audioRouteChooserPresented = false
    c.active = .desktop; c.advertise(); c.offerInitialAudioRoutes()
    check(!c.audioRouteChooserPresented, "manual chooser consumes the first connection offer")
}

do {
    let c = StreamClient(); c.advertise(); c.permissionAllowed = false
    await rejected("permission denial rejects combined action") { try await c.applyAudioRoutes(both, context: c.audioRouteContext) }
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "permission denial has no partial playback or microphone effect")
}
for event in 0..<8 {
    let c = StreamClient(); c.advertise(); c.holdPermission = true
    let context = c.audioRouteContext
    let pending = Task { @MainActor in try await c.applyAudioRoutes(both, context: context) }
    for _ in 0..<100 where c.permissionWaiter == nil { await Task.yield() }
    check(c.permissionWaiter != nil, "combined action waits at permission boundary")
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "permission prompt cannot revoke a prematurely started playback")
    switch event {
    case 0: c.appActive = false
    case 1: c.appInForeground = false; c.audioRouteAuthorization = nil
    case 2: c.connection = RoutePeer(); c.advertise()
    case 3: c.active = .window(99)
    case 4: c.advertise()
    case 5: c.audioRouteAuthorization = nil
    case 6: pending.cancel()
    default: break
    }
    c.permissionWaiter!.resume(returning: true); c.permissionWaiter = nil
    do { try await pending.value; check(event == 7, "only unchanged foreground action can complete") }
    catch { check(event != 7, "stale permission result is rejected") }
    if event == 7 {
        check(c.playbackRequests.count == 1 && c.microphoneRequests.count == 1, "permission success starts both existing operations exactly once")
    } else {
        check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "invalidated permission sends neither direction")
        c.appActive = true; c.appInForeground = true
        await Task.yield()
        check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "foreground return never restarts invalidated intent")
    }
}
do {
    let c = StreamClient(); c.advertise(); c.holdPermission = true
    let pending = Task { @MainActor in try await c.applyAudioRoutes(both, context: c.audioRouteContext) }
    for _ in 0..<100 where c.permissionWaiter == nil { await Task.yield() }
    try await c.applyAudioRoutes(off, context: c.audioRouteContext)
    c.permissionWaiter!.resume(returning: true)
    do { try await pending.value; check(false, "replacement off must invalidate old permission") } catch {}
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "replacement off prevents stale combined start")
}
do {
    let c = StreamClient(); c.connected = false
    check(c.audioRoutePlaybackUnavailableReason != nil, "disconnected output has a reason")
    c.connected = true; c.active = .none
    check(c.audioRoutePlaybackUnavailableReason != nil, "missing source output has a reason")
    c.active = .desktop
    check(c.audioRoutePlaybackUnavailableReason != nil, "unadvertised playback has a reason")
    c.advertise()
    check(c.audioRoutePlaybackUnavailableReason == nil, "supported output clears unavailable reason")
}

print("\(checks - failures)/\(checks) audio route checks passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)

}
}
