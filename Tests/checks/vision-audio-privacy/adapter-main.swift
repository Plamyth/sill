import Foundation
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { fatalError("FAIL \(name)") }
}
let suite = "VisionSharedAudioAdapter." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let store = VisionRemoteAudioStore(defaults: defaults)
let a = StreamClient("mac-a"), b = StreamClient("mac-a"), c = StreamClient("mac-b")
store.register(a); store.register(b); store.register(c)
check(store.setDesired(true, client: a, direction: .playback, expectedScope: nil), "manual enable admitted")
check(a.visionAudio.starts == 1 && b.visionAudio.starts == 0 && c.visionAudio.starts == 0, "actual store starts only elected client")
check(store.setDesired(false, client: b, direction: .playback, expectedScope: nil), "STOP accepted from other window")
check(a.visionAudio.stops > 0 && b.visionAudio.stops > 0, "STOP synchronously reaches both same Mac clients")
check(c.visionAudio.stops == 0, "STOP does not reach unrelated Mac")
store.refresh()
check(a.visionAudio.starts == 1, "later refresh cannot resurrect explicit STOP")
store.observedCatalog(a)
_ = store.setDesired(true, client: a, direction: .microphone, expectedScope: nil)
check(store.model.intent.desired(.microphone, hostKey: "mac-a"), "microphone desire shared")
check(!store.model.intent.desired(.playback, hostKey: "mac-a"), "microphone enable preserves playback STOP")
check(store.beginPermission(a.visionAudioOwnerID), "one permission request acquires slot")
check(!store.beginPermission(b.visionAudioOwnerID), "parallel permission request refused")
a.context.foreground = false
VisionAudioSharedHardware.shared.isIdle = false
VisionAudioSharedHardware.shared.holdCleanup = true
store.retire(a)
check(store.model.owner == nil && b.microphoneStarts == 0, "retirement waits actual cleanup and original permission callback")
check(VisionAudioSharedHardware.shared.revoked.contains(a.visionAudioOwnerID), "both physical roles revoked before owner retirement closes either role")
VisionAudioSharedHardware.shared.isIdle = true
VisionAudioSharedHardware.shared.holdCleanup = false
store.refresh()
check(store.model.owner == nil, "physical cleanup alone does not release pending OS request")
store.endPermission(a.visionAudioOwnerID)
check(store.model.owner == b.visionAudioOwnerID, "cleanup and permission drainage allow survivor election")
check(b.microphoneStarts == 0, "survivor waits fresh capability event")
store.observedCatalog(b); store.refresh()
check(b.microphoneStarts == 1, "fresh recipient catalog permits one automatic grant request")
store.refresh(); store.refresh()
check(b.microphoneStarts == 1, "refresh is not a retry loop")
store.withdrawPrivacy(b)
check(b.microphoneStops > 0 && store.model.owner == nil, "protected false revokes I/O synchronously")
check(store.model.intent.desired(.microphone, hostKey: "mac-a"), "privacy revocation preserves desired true")
_ = store.setDesired(false, client: b, direction: .microphone, expectedScope: nil)
b.visionAudioPrivacyBlocked = false
store.observedCatalog(b); store.refresh()
check(b.microphoneStarts == 1, "explicit STOP survives privacy recovery")
let loaded = VisionRemoteAudioIntent.load(defaults)
check(!loaded.desired(.microphone, hostKey: "mac-a"), "latest STOP persisted by single writer")
print("RESULT_ASSERTIONS \(checks)")
