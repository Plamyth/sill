import Foundation

var checks = 0
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func rejected(_ name: String, _ operation: () throws -> Void) {
    do { try operation(); check(false, name) } catch { check(true, name) }
}
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
    try c.applyAudioRoutes(off, context: c.audioRouteContext)
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "confirming both off has no effect")
}
do {
    let c = StreamClient(); c.advertise(); let context = c.audioRouteContext
    try c.applyAudioRoutes(output, context: context)
    check(c.playbackRequests.count == 1 && c.playbackRequests[0].enabled, "output-only choice requests playback once")
    check(c.microphoneRequests.isEmpty, "output-only choice never opens microphone")
    check(c.played == 0, "requesting playback does not bypass host ACK")
    try c.applyAudioRoutes(output, context: context)
    check(c.playbackRequests.count == 1, "repeated apply cannot toggle pending playback off")
    try c.applyAudioRoutes(off, context: context)
    check(c.playbackRequests.count == 2 && !c.playbackRequests[1].enabled && c.stopped == 1, "explicit output off revokes immediately")
    let old = c.playbackRequests[0]
    c.remoteAudioControl.receive(RemoteAudioState(enabled: true, requestID: old.requestID), from: context!.peer)
    c.remoteAudioControl.receiveAudio(Data([1]), from: context!.peer)
    check(c.played == 0, "late playback ACK after off never re-enables output")
}
do {
    let c = StreamClient(); c.advertise(); let context = c.audioRouteContext
    try c.applyAudioRoutes(input, context: context)
    check(c.microphoneRequests.count == 1 && c.microphoneRequests[0].operation == .start, "input-only choice requests microphone consent once")
    check(c.playbackRequests.isEmpty, "input-only choice does not enable playback")
    check(!c.microphoneEffects.contains { if case .beginCapture = $0 { true } else { false } }, "microphone request does not bypass host ACK")
    try c.applyAudioRoutes(input, context: context)
    check(c.microphoneRequests.count == 1, "repeated apply cannot cancel pending input")
    try c.applyAudioRoutes(off, context: context)
    check(c.microphoneRequests.count == 2 && c.microphoneRequests[1].operation == .stop, "input off cancels pending microphone start")
    let start = c.microphoneRequests[0]
    let late = MicrophoneState(requestID: start.requestID, scope: start.scope, phase: .active, grantID: UUID())
    check(c.microphonePolicy.receive(late, from: context!.peer).isEmpty, "cancelled microphone ACK cannot start capture")
}
do {
    let c = StreamClient(); c.advertise(); let context = c.audioRouteContext
    try c.applyAudioRoutes(both, context: context)
    check(c.playbackRequests.count == 1 && c.microphoneRequests.count == 1, "input and output can be requested together")
    try c.applyAudioRoutes(input, context: context)
    check(c.playbackRequests.count == 2 && !c.playbackRequests.last!.enabled && c.microphoneRequests.count == 1,
          "changing output preserves selected microphone consent")
}
for unsupportedInput in [true, false] {
    let c = StreamClient(); c.advertise(playback: unsupportedInput, microphone: !unsupportedInput)
    rejected("unsupported direction rejects the entire apply before side effects") { try c.applyAudioRoutes(both, context: c.audioRouteContext) }
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
    rejected("stale peer, source, grant scope, background, or disconnected context cannot apply") { try c.applyAudioRoutes(both, context: context) }
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "stale context has no consent side effects")
}
do {
    let c = StreamClient(); c.advertise(); c.microphoneCleanupProblem = "정리 필요"
    rejected("cleanup failure prevents combined input start") { try c.applyAudioRoutes(both, context: c.audioRouteContext) }
    check(c.playbackRequests.isEmpty && c.microphoneRequests.isEmpty, "cleanup refusal cannot partially start playback")
}
do {
    let c = StreamClient(); c.advertise(); let context = c.audioRouteContext
    try c.applyAudioRoutes(input, context: context); try c.applyAudioRoutes(off, context: context)
    let count = c.microphoneRequests.count
    rejected("stop awaiting ACK cannot start another microphone grant") { try c.applyAudioRoutes(both, context: context) }
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
print("\(checks - failures)/\(checks) audio route checks passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
