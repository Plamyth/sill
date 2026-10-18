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

private func catalog(_ privacy: AudioPrivacyState? = .init(protected: true), epoch: VideoEpoch = epoch) -> WindowList {
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
    return state
}

private func starts(_ state: inout IPadDesiredAudio, foreground: Bool = true, presented: Bool = true,
                    control: Bool = true, permission: Bool = true) -> [IPadDesiredAudio.Direction] {
    state.takeAutomaticStarts(foreground: foreground, presented: presented, fullControl: control,
        microphoneAuthorized: permission, microphoneCanStart: true, playbackCanStart: true)
}

var state = ready()
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

for gate in 0..<4 {
    state = ready()
    let result = starts(&state, foreground: gate != 0, presented: gate != 1,
                        control: gate != 2, permission: gate != 3)
    expect(result == (gate == 3 ? [.playback] : []), "gate \(gate) blocks the affected directions")
}
for privacy in [AudioPrivacyState(protected: false), .init(version: 2, protected: true)] {
    state = ready()
    state.observe(catalog(privacy), microphone: micScope, from: ObjectIdentifier(a))
    expect(state.privacy == .blocked && starts(&state).isEmpty, "unsafe privacy blocks automatic starts")
    expect(!state.permits(.microphone, automatic: false, foreground: true, presented: true,
                         fullControl: true, microphoneAuthorized: true), "unsafe privacy also blocks manual late capture")
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
expect(state.permits(.microphone, automatic: false, foreground: true, presented: false,
                     fullControl: false, microphoneAuthorized: false), "legacy manual permission flow remains available")
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

var presentation = IPadAudioPresentation()
let scope = ready().scope!
expect(!presentation.observe(scope: scope, ready: true, keyframe: true, healthy: true, attached: true), "old ready layer cannot prove current presentation")
expect(!presentation.observe(scope: scope, ready: false, keyframe: true, healthy: true, attached: true), "enqueued keyframe alone is insufficient")
expect(presentation.observe(scope: scope, ready: true, healthy: true, attached: true), "current keyframe plus readiness cycle proves presentation")
expect(!presentation.observe(scope: scope, ready: true, healthy: true, attached: false), "detached view blocks admission")
expect(!presentation.observe(scope: scope, ready: true, healthy: false, attached: true), "decode failure revokes presentation")
expect(!presentation.observe(scope: scope, ready: true, healthy: true, attached: true), "recovery needs fresh keyframe and readiness")

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
expect(!state.permits(.microphone, automatic: true, foreground: true, presented: true,
                     fullControl: true, microphoneAuthorized: true), "privacy revocation fences a previously prepared capture")

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
