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
a.context.presented = false
a.receiveCatalog(a.visionAudioIntentCatalog!, from: a.connection!)
a.context.presented = true
check(store.setDesired(true, client: a, direction: .playback, expectedScope: nil), "manual enable admitted")
check(a.visionAudio.starts == 0, "catalog before initial admission cannot satisfy election")
a.respondToQuery()
check(a.visionAudio.starts == 1 && b.visionAudio.starts == 0 && c.visionAudio.starts == 0, "actual response starts only elected client")
check(store.setDesired(false, client: b, direction: .playback, expectedScope: nil), "STOP accepted from other window")
check(a.visionAudio.stops > 0 && b.visionAudio.stops > 0, "STOP synchronously reaches both same Mac clients")
check(c.visionAudio.stops == 0, "STOP does not reach unrelated Mac")
store.refresh()
check(a.visionAudio.starts == 1, "later refresh cannot resurrect explicit STOP")
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
check(b.queue.work.count == 1, "survivor election sends one actual refresh without Mac activity")
store.refresh(); store.refresh()
check(b.queue.work.count == 1, "authority epoch never queues a second catalog request")
var unsolicited = b.visionAudioIntentCatalog!
unsolicited.responseRequestID = UUID()
b.receiveCatalog(unsolicited, from: b.connection!)
check(b.microphoneStarts == 0, "unrelated response nonce cannot refresh authority")
b.respondToQuery()
check(b.microphoneStarts == 1, "actual recipient response permits one automatic grant request")
store.refresh(); store.refresh()
check(b.microphoneStarts == 1, "refresh is not a retry loop")
store.withdrawPrivacy(b)
check(b.microphoneStops > 0 && !store.permits(b, direction: .microphone), "protected false revokes I/O synchronously")
check(store.model.intent.desired(.microphone, hostKey: "mac-a"), "privacy revocation preserves desired true")
_ = store.setDesired(false, client: b, direction: .microphone, expectedScope: nil)
b.visionAudioPrivacyBlocked = false
store.refresh()
check(b.microphoneStarts == 1, "explicit STOP survives privacy recovery")
let loaded = VisionRemoteAudioIntent.load(defaults)
check(!loaded.desired(.microphone, hostKey: "mac-a"), "latest STOP persisted by single writer")

let d = StreamClient("mac-d")
store.register(d)
_ = store.setDesired(true, client: d, direction: .playback, expectedScope: nil)
d.queue.drain()
let stalePeer = d.connection!
let staleBytes = stalePeer.sent.last!
let staleQuery = Wire.decode(FetchCatalog.self, from: Data(staleBytes.dropFirst(StreamMessage.headerLength)))!
d.connection = NWConnection()
let old = d.context.scope!
d.context.scope = .init(connection: UUID(), window: old.window, admission: old.admission,
    video: old.video, foreground: old.foreground, privacy: old.privacy)
store.refresh()
var staleList = d.visionAudioIntentCatalog!
staleList.responseRequestID = staleQuery.requestID
d.receiveCatalog(staleList, from: stalePeer)
d.receiveCatalog(staleList, from: d.connection!)
check(d.visionAudio.starts == 0, "old peer and old owner epoch response cannot reopen reconnect")
d.respondToQuery()
check(d.visionAudio.starts == 1, "static Mac reconnect resumes from new correlated response")
let stopped = StreamClient("stopped")
store.register(stopped)
_ = store.setDesired(true, client: stopped, direction: .microphone, expectedScope: nil)
_ = store.setDesired(false, client: stopped, direction: .microphone, expectedScope: nil)
stopped.respondToQuery()
check(stopped.microphoneStarts == 0, "STOP revision defeats late catalog response and deferred permission work")
let legacy = StreamClient("legacy")
legacy.visionAudioIntentCatalog?.catalogRefresh = nil
store.register(legacy)
_ = store.setDesired(true, client: legacy, direction: .playback, expectedScope: nil)
store.refresh(); store.refresh()
check(legacy.queue.work.isEmpty && legacy.visionAudio.starts == 0, "old host unavailable without retry or source selection")
for client in [a, b, c, d, stopped, legacy] { client.context.foreground = false }
store.refresh()
let held = StreamClient("lifecycle-held")
store.register(held)
check(store.beginPermission(legacy.visionAudioOwnerID), "hold native election behind existing permission callback")
_ = store.setDesired(true, client: held, direction: .playback, expectedScope: nil)
check(held.nativeSelections == 0, "manual native selection remains unsubmitted during cleanup")
held.context.foreground = false
store.refresh()
held.context.foreground = true
let heldScope = held.context.scope!
held.context.scope = .init(connection: heldScope.connection, window: heldScope.window,
    admission: heldScope.admission, video: heldScope.video, foreground: UUID(), privacy: heldScope.privacy)
store.endPermission(legacy.visionAudioOwnerID)
check(held.nativeSelections == 0, "background discards store native selection before returning foreground")
check(store.model.intent.desired(.playback, hostKey: "lifecycle-held") &&
      VisionRemoteAudioIntent.load(defaults).desired(.playback, hostKey: "lifecycle-held"),
      "discarded native selection preserves in-memory and persisted desired")
store.retire(held)

let pendingManualClient = StreamClient("lifecycle-manual")
store.register(pendingManualClient)
_ = store.setDesired(true, client: pendingManualClient, direction: .microphone, expectedScope: nil)
check(pendingManualClient.microphoneStarts == 0, "manual microphone waits correlated fresh catalog")
pendingManualClient.context.foreground = false
store.refresh()
pendingManualClient.context.foreground = true
pendingManualClient.context.recordPermissionGranted = false
store.refresh()
pendingManualClient.respondToQuery()
check(pendingManualClient.microphoneStarts == 0,
      "old pending manual cannot prompt microphone after a new foreground lifecycle")
check(store.model.intent.desired(.microphone, hostKey: "lifecycle-manual"),
      "cancelled deferred microphone selection preserves desired")
store.retire(pendingManualClient)

let privacyUpgrade = StreamClient("privacy-upgrade")
privacyUpgrade.context.recordPermissionGranted = false
store.register(privacyUpgrade)
_ = store.setDesired(true, client: privacyUpgrade, direction: .microphone, expectedScope: nil)
let beforePrivacy = privacyUpgrade.context.scope!
privacyUpgrade.context.scope = .init(connection: beforePrivacy.connection, window: beforePrivacy.window,
    admission: beforePrivacy.admission, video: beforePrivacy.video, foreground: beforePrivacy.foreground,
    privacy: beforePrivacy.privacy + 1)
store.refresh()
privacyUpgrade.respondToQuery()
check(privacyUpgrade.microphoneStarts == 1,
      "same lifecycle privacy upgrade preserves an explicit microphone choice awaiting fresh capability")
store.retire(privacyUpgrade)

for change in ["connection", "window", "admission", "foreground"] {
    let scoped = StreamClient("scoped-" + change)
    store.register(scoped)
    check(store.beginPermission(legacy.visionAudioOwnerID), "hold scoped unsubmitted native selection")
    _ = store.setDesired(true, client: scoped, direction: .playback, expectedScope: nil)
    let previous = scoped.context.scope!
    scoped.context.scope = .init(connection: change == "connection" ? UUID() : previous.connection,
        window: change == "window" ? UUID() : previous.window,
        admission: change == "admission" ? UUID() : previous.admission,
        video: previous.video, foreground: change == "foreground" ? UUID() : previous.foreground,
        privacy: previous.privacy)
    store.endPermission(legacy.visionAudioOwnerID)
    check(scoped.nativeSelections == 0, "changed " + change + " cannot replay pending native selection")
    store.retire(scoped)
}
print("RESULT_ASSERTIONS \(checks)")
