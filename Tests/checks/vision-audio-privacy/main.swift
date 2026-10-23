import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard value() else { fatalError("FAIL \(name)") }
}
func ready() -> VisionRemoteAudioIntent.Context {
    var context = VisionRemoteAudioIntent.Context()
    context.hostKey = "verified-mac-a"
    context.scope = .init(connection: UUID(), window: UUID(), admission: UUID(), video: UUID(), foreground: UUID(), privacy: 1)
    context.connected = true; context.authenticated = true; context.foreground = true
    context.presented = true; context.inputBlocked = false
    context.privacyVersion = 2; context.protected = true; context.cleanupReady = true
    context.nativeBindingReady = true
    context.playbackAvailable = true; context.microphoneAvailable = true; context.recordPermissionGranted = true
    return context
}
func enabled() -> VisionRemoteAudioIntent {
    var model = VisionRemoteAudioIntent()
    for direction in VisionRemoteAudioIntent.Direction.allCases {
        model.setDesired(true, direction: direction, hostKey: "verified-mac-a")
    }
    return model
}
var model = enabled()
let context = ready()
let first = model.requests(context)
check(first.count == 2, "both desired directions request new grants")
check(model.requests(context).isEmpty, "failed or unanswered attempts never loop")
model.setDesired(false, direction: .microphone, hostKey: "verified-mac-a")
check(!model.isCurrent(first.first { $0.direction == .microphone }!, context: context), "explicit stop invalidates late work")
check(!model.desired(.microphone, hostKey: context.hostKey), "stop clears desired microphone only")
check(model.desired(.playback, hostKey: context.hostKey), "microphone stop retains playback desire")

let denied: [(String, (inout VisionRemoteAudioIntent.Context) -> Void)] = [
    ("connection", { $0.connected = false }), ("authentication", { $0.authenticated = false }),
    ("saved Mac", { $0.hostKey = nil }), ("full lease", { $0.scope = nil }),
    ("foreground", { $0.foreground = false }), ("presented video", { $0.presented = false }),
    ("display input", { $0.inputBlocked = true }), ("old host", { $0.privacyVersion = nil }),
    ("built-in-only privacy version", { $0.privacyVersion = 1 }),
    ("unknown privacy version", { $0.privacyVersion = 3 }), ("privacy lost", { $0.protected = false }),
    ("native cleanup", { $0.cleanupReady = false })
]
for (name, deny) in denied {
    var candidate = enabled(); var invalid = context; deny(&invalid)
    check(candidate.requests(invalid).isEmpty, "gate refuses \(name)")
    check(candidate.requests(context).count == 2, "eligibility can recover after \(name)")
}
var permission = enabled(); var ungranted = context; ungranted.recordPermissionGranted = false
check(permission.requests(ungranted).map(\.direction) == [.playback], "automatic microphone never asks OS permission")
check(permission.requests(context).map(\.direction) == [.microphone], "pregranted microphone can make its one attempt")
var other = context; other.hostKey = "verified-mac-b"
check(enabled().desires[other.hostKey!] == nil, "another verified Mac has no inherited desire")
var otherModel = enabled()
check(otherModel.requests(other).isEmpty, "another Mac cannot resume")
var reconnect = context
reconnect.scope = .init(connection: UUID(), window: context.scope!.window, admission: context.scope!.admission,
    video: context.scope!.video, foreground: context.scope!.foreground, privacy: 1)
check(model.requests(reconnect).map(\.direction) == [.playback], "reconnect retains desire but explicit stop stays off")
check(!model.isCurrent(first[0], context: reconnect), "old connection work cannot authorize new peer")
var background = context; background.foreground = false
var lifecycle = enabled(); _ = lifecycle.requests(context)
check(lifecycle.requests(background).isEmpty, "background has no grants")
check(lifecycle.desired(.microphone, hostKey: context.hostKey), "system stop retains desire")
var foreground = context
foreground.scope = .init(connection: context.scope!.connection, window: context.scope!.window,
    admission: context.scope!.admission, video: context.scope!.video, foreground: UUID(), privacy: 1)
check(lifecycle.requests(foreground).count == 2, "new foreground admission requests fresh grants")
var recovered = foreground
recovered.scope = .init(connection: foreground.scope!.connection, window: foreground.scope!.window,
    admission: foreground.scope!.admission, video: foreground.scope!.video, foreground: foreground.scope!.foreground, privacy: 2)
check(lifecycle.requests(recovered).count == 2, "new protected catalog recovery gets one fresh attempt")
check(lifecycle.requests(recovered).isEmpty, "protected recovery does not repeat failures")
var manual = enabled(); manual.consume(.playback, scope: context.scope)
check(manual.requests(context).map(\.direction) == [.microphone], "manual playback consumes automatic attempt")
let suite = "VisionAudioIntentChecks." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
model.persist(defaults)
let loaded = VisionRemoteAudioIntent.load(defaults)
check(loaded.desires == model.desires, "desired map survives process recreation without grants")
var bounded = VisionRemoteAudioIntent()
for index in 0..<70 { bounded.setDesired(true, direction: .playback, hostKey: "mac-\(index)") }
check(bounded.desires.count == 64, "persistent map is bounded")
checkAuthority()
print("RESULT_ASSERTIONS \(checks)")
