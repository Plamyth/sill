import Foundation
import StreamProtocol

private var checks = 0
private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard condition() else { fatalError("FAIL \(name)") }
}

private final class Peer {}
private let a = Peer(), b = Peer()
private let identity = IPadDesiredAudio.Identity(macID: "paired-mac", pin: Data(repeating: 7, count: 32))!
private let changedPin = IPadDesiredAudio.Identity(macID: "paired-mac", pin: Data(repeating: 8, count: 32))!
private let otherMac = IPadDesiredAudio.Identity(macID: "other-mac", pin: identity.pin)!
private let generation = UUID()
private let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
    geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
private let micScope = MicrophoneScope(peer: UUID(), source: .desktop, inputGeneration: generation,
    videoEpoch: epoch.id, destination: UUID(), capability: UUID())

private func catalog(_ privacy: AudioPrivacyState? = .init(version: 2, protected: true), epoch: VideoEpoch = epoch) -> WindowList {
    WindowList(macName: "Test", windows: [], active: epoch.source, remoteAudio: 1,
        inputGeneration: epoch.generation, videoEpoch: epoch,
        microphone: .init(peer: micScope.peer, destination: micScope.destination, generation: micScope.capability),
        audioPrivacy: privacy)
}

private func ready() -> IPadDesiredAudio {
    var state = IPadDesiredAudio()
    state.bind(ObjectIdentifier(a))
    state.authenticate(identity, saved: .init(microphone: true, playback: true))
    state.observe(catalog(), microphone: micScope, from: ObjectIdentifier(a))
    state.observeForeground(true)
    state.observeMicrophoneAuthorization(true)
    return state
}

private func starts(_ state: inout IPadDesiredAudio, foreground: Bool = true, permission: Bool = true) -> [IPadDesiredAudio.Direction] {
    state.takeAutomaticStarts(foreground: foreground,
        microphoneAuthorized: permission, microphoneCanStart: true, playbackCanStart: true)
}

var state = ready()
state.observe(catalog(.init(version: 1, protected: true)), microphone: micScope, from: ObjectIdentifier(a))
expect(!state.permits(.microphone, automatic: false, foreground: true, microphoneAuthorized: true) &&
       !state.permits(.playback, automatic: false, foreground: true, microphoneAuthorized: true) && starts(&state).isEmpty,
       "old built-in-only privacy cannot authorize all-endpoint audio")
state = ready()
expect(starts(&state) == [.microphone, .playback], "fresh protected paired scope admits each direction")
expect(starts(&state).isEmpty, "failure or repeated catalog cannot busy loop")
state.observe(catalog(), microphone: micScope, from: ObjectIdentifier(a))
expect(starts(&state).isEmpty, "same catalog cannot renew an attempt")
state.invalidate()
expect(state.selection == .init(microphone: true, playback: true), "system suspension retains desire")
expect(starts(&state).isEmpty, "foreground alone cannot reuse the same connection scope")
state.bind(ObjectIdentifier(b))
state.authenticate(identity, saved: .init(microphone: true, playback: true))
expect(starts(&state).isEmpty, "new peer needs its own fresh catalog")
state.observe(catalog(), microphone: micScope, from: ObjectIdentifier(a))
expect(starts(&state).isEmpty, "old peer catalog ignored")
state.observe(catalog(), microphone: micScope, from: ObjectIdentifier(b))
expect(starts(&state) == [.microphone, .playback], "reconnect creates fresh requests")

state = ready()
expect(starts(&state, foreground: false).isEmpty, "background blocks both directions")
state = ready()
expect(starts(&state, permission: false) == [.playback], "unapproved OS microphone cannot auto start")
for privacy in [AudioPrivacyState(version: 2, protected: false), .init(version: 3, protected: true)] {
    state = ready()
    state.observe(catalog(privacy), microphone: micScope, from: ObjectIdentifier(a))
    expect(state.privacy == .blocked && starts(&state).isEmpty, "unsafe privacy blocks automatic starts")
    expect(!state.permits(.microphone, automatic: false, foreground: true, microphoneAuthorized: true), "unsafe privacy also blocks manual late capture")
}
state = ready()
state.observe(catalog(nil), microphone: micScope, from: ObjectIdentifier(a))
expect(state.privacy == .blocked, "missing privacy after protection revokes both directions")
expect(starts(&state).isEmpty && state.selection.microphone && state.selection.playback, "revocation retains desired")
state = IPadDesiredAudio()
state.bind(ObjectIdentifier(a))
state.set(.microphone, desired: true)
state.observe(catalog(nil), microphone: micScope, from: ObjectIdentifier(a))
expect(state.privacy == .legacy && starts(&state).isEmpty, "legacy host never auto starts")
expect(!state.permits(.microphone, automatic: false, foreground: true, microphoneAuthorized: false), "legacy manual start cannot bypass host privacy")
state.observe(catalog(), microphone: micScope, from: ObjectIdentifier(a))
expect(starts(&state).isEmpty, "privacy alone cannot authenticate a peer")

state = ready()
let lateRevision = state.revision(for: .microphone)
let playbackRevision = state.revision(for: .playback)
state.set(.microphone, desired: true)
expect(state.revision(for: .microphone) == lateRevision, "reapplying desired ON preserves an in-flight grant")
state.set(.microphone, desired: false)
expect(state.revision(for: .microphone) != lateRevision, "explicit stop invalidates late microphone permission and capture")
expect(state.revision(for: .playback) == playbackRevision, "independent stop retains the other direction's grant fence")
expect(starts(&state) == [.playback], "explicit stop wins desired automatic restart")
state.set(.playback, desired: false)
expect(starts(&state).isEmpty, "both explicit stops stay off")
state = ready()
state.markManualAttempt(.microphone)
expect(starts(&state) == [.playback], "manual failure does not trigger an automatic retry")
state = ready()
_ = starts(&state)
state.sourceWillChange()
state.sourceWillChange()
state.observe(catalog(), microphone: micScope, from: ObjectIdentifier(a))
expect(state.scope == nil && starts(&state).isEmpty, "a source request retires the old input binding immediately")
let nextEpoch = VideoEpoch(generation: UUID().uuidString, source: .window(42),
    geometry: epoch.geometry, width: 100, height: 100)
state.observe(catalog(epoch: nextEpoch), microphone: nil, from: ObjectIdentifier(a))
expect(starts(&state) == [.playback], "new playback scope has its own budget and cannot invent a microphone capability")

state = ready()
expect(starts(&state) == [.microphone, .playback], "drawing without video or pointer ownership uses actual audio scope")
expect(starts(&state).isEmpty, "failure does not retry in the same authorized lifecycle")
state.observeForeground(false)
state.observeForeground(false)
state.observeForeground(true)
expect(starts(&state) == [.microphone, .playback], "foreground return creates fresh requests for saved intent")
expect(starts(&state).isEmpty, "repeated active callbacks do not retry")
state.set(.microphone, desired: false)
state.observeForeground(false)
state.observeForeground(true)
expect(starts(&state) == [.playback], "explicit microphone OFF persists across lifecycle renewal")
state = ready()
_ = starts(&state)
state.observeMicrophoneAuthorization(false)
expect(starts(&state, permission: false).isEmpty, "permission loss cannot restart microphone")
state.observeMicrophoneAuthorization(true)
expect(starts(&state) == [.microphone], "new OS authorization cycle gets one fresh microphone attempt")

for muted in IPadDesiredAudio.Direction.allCases {
    state = ready()
    state.set(muted, desired: false)
    _ = state.observeSession(.mediaReset)
    _ = state.observeSession(.routeChanged)
    state.observeForeground(false)
    state.observeForeground(true)
    expect(starts(&state).isEmpty, "reset pause survives route and foreground changes")
    state.confirmSession(IPadDesiredAudio.Direction.allCases)
    expect(starts(&state) == IPadDesiredAudio.Direction.allCases.filter { $0 != muted },
        "pause confirmation preserves each explicit direction OFF")
    _ = state.observeSession(.outputUnavailable)
    state.bind(ObjectIdentifier(b))
    state.authenticate(identity, saved: .init(microphone: false, playback: false))
    state.observe(catalog(), microphone: micScope, from: ObjectIdentifier(b))
    expect(starts(&state).isEmpty, "new connection with explicit OFF cannot inherit audio ON")
    state.authenticate(otherMac, saved: .init())
    state.confirmSession(IPadDesiredAudio.Direction.allCases)
    expect(starts(&state).isEmpty, "different Mac remains OFF even after local pause confirmation")
}

let suiteName = "IPadDesiredAudioTests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
let store = IPadDesiredAudioStore(defaults: defaults)
store.save(.init(microphone: true, playback: false), for: identity)
expect(IPadDesiredAudioStore(defaults: defaults).selection(for: identity) == .init(microphone: true, playback: false), "desired survives store recreation")
expect(store.selection(for: changedPin) == .init(), "new pin cannot inherit prior desired")
expect(store.selection(for: otherMac) == .init(), "different Mac cannot inherit desired")
store.save(.init(microphone: false, playback: true), for: changedPin)
expect(store.selection(for: identity) == .init(), "pin replacement removes old record")
expect(store.selection(for: changedPin).playback, "directions persist separately")
defaults.set(Data("bad".utf8), forKey: IPadDesiredAudioStore.key)
expect(store.selection(for: changedPin) == .init(), "malformed persistence fails closed")

let legacyJSON = Data(#"{"macName":"legacy","windows":[],"active":{"desktop":{}}}"#.utf8)
expect(Wire.decode(WindowList.self, from: legacyJSON)?.audioPrivacy == nil, "legacy catalog decodes without privacy")
let wire = catalog(.init(protected: true, reason: "verified"))
expect(Wire.decode(WindowList.self, from: Wire.encode(wire))?.audioPrivacy == wire.audioPrivacy, "exact optional privacy schema round trips")

var microphone = IPadMicrophonePolicy()
_ = microphone.setConnection(ObjectIdentifier(a))
_ = microphone.observe(catalog(), from: ObjectIdentifier(a))
_ = microphone.toggle()
let request = microphone.startRequestID!
_ = microphone.permissionResolved(true, requestID: request, scope: micScope, from: ObjectIdentifier(a))
let grant = UUID()
let answer = MicrophoneState(requestID: request, scope: micScope, phase: .active, grantID: grant)
expect(!microphone.receive(answer, from: ObjectIdentifier(a)).isEmpty, "fresh grant prepares capture")
_ = microphone.backgrounded()
expect(microphone.captureStarted(requestID: request, grant: grant, from: ObjectIdentifier(a)).isEmpty, "system stop cannot reopen frames from late capture completion")
expect(microphone.receive(answer, from: ObjectIdentifier(a)).isEmpty, "late grant cannot undo a stop")
state = ready()
state.observe(catalog(.init(protected: false)), microphone: micScope, from: ObjectIdentifier(a))
expect(!state.permits(.microphone, automatic: true, foreground: true, microphoneAuthorized: true), "privacy revocation fences a previously prepared capture")

var requests: [RemoteAudioSubscription] = []
var stops = 0
var packets = 0
let player = IPadRemoteAudioController(send: { _, request in requests.append(request) },
    stop: { stops += 1 }, play: { _, _ in packets += 1 }, changed: { _ in })
player.setConnection(ObjectIdentifier(a))
player.receive(catalog(), from: ObjectIdentifier(a))
player.toggle()
let oldPlaybackRequest = requests.last!.requestID
player.backgrounded()
player.receive(.init(enabled: true, requestID: oldPlaybackRequest), from: ObjectIdentifier(a))
player.receiveAudio(Data([1]), from: ObjectIdentifier(a))
expect(packets == 0 && stops == 1, "stopped playback ignores late grant and queued packets")
player.toggle()
expect(requests.last!.requestID != oldPlaybackRequest, "a later manual playback needs a fresh request")
print("PASS \(checks) iPad desired audio pure checks")
