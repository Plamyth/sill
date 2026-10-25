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
let neverArmed = StreamClient("never-armed")
neverArmed.context.nativeBindingReady = false
store.register(neverArmed)
var privacyList = neverArmed.visionAudioIntentCatalog!
privacyList.audioPrivacy = AudioPrivacyState(protected: false)
neverArmed.observeVisionAudioPrivacy(privacyList)
check(neverArmed.visionAudioIntentContext.admitted && !neverArmed.visionAudioIntentContext.eligible,
      "최초 v2 미보호 화면은 요청 가능하지만 실제 오디오 자격은 없음")
check(store.setDesired(true, client: neverArmed, direction: .playback, expectedScope: nil),
      "처음 보호를 켜지 않은 화면에서 수동 재생 요청 수용")
check(neverArmed.nativeSelections == 1 && neverArmed.visionAudio.starts == 0,
      "최초 미보호 수동 선택을 native 요청 한 번으로 전달: selections=\(neverArmed.nativeSelections), starts=\(neverArmed.visionAudio.starts)")
let pendingEpoch = store.model.epoch
neverArmed.observeVisionAudioPrivacy(privacyList)
store.refresh()
check(!neverArmed.visionAudioPrivacyBlocked && neverArmed.nativeSelections == 1 &&
      neverArmed.visionAudio.starts == 0 && store.model.epoch == pendingEpoch,
      "반복된 정상 OFF 관측은 수동 준비를 철회하거나 재선택하지 않음")
check(neverArmed.queue.work.isEmpty, "HAL 보호와 native binding 전에는 capability 조회도 대기")
privacyList.audioPrivacy = AudioPrivacyState(protected: true)
neverArmed.observeVisionAudioPrivacy(privacyList)
neverArmed.visionAudioIntentCatalog = privacyList
store.refresh()
check(!neverArmed.visionAudioIntentContext.eligible && neverArmed.visionAudio.starts == 0 &&
      neverArmed.nativeSelections == 1 && neverArmed.queue.work.isEmpty,
      "true HAL 보호만으로 native binding 없는 오디오는 시작하지 않음")
neverArmed.context.nativeBindingReady = true
store.refresh()
check(neverArmed.visionAudio.starts == 0 && neverArmed.queue.work.count == 1,
      "native binding 준비 뒤에도 상관된 fresh catalog를 기다림")
neverArmed.queue.drain()
let catalogQuery = Wire.decode(FetchCatalog.self, from: Data(neverArmed.connection!.sent.last!
    .dropFirst(StreamMessage.headerLength)))!
var wrongPeer = privacyList
wrongPeer.responseRequestID = catalogQuery.requestID
neverArmed.receiveCatalog(wrongPeer, from: NWConnection())
check(neverArmed.visionAudio.starts == 0, "정확한 nonce라도 다른 peer 응답은 실제 재생을 시작하지 않음")
var unrelated = privacyList
unrelated.responseRequestID = UUID()
neverArmed.receiveCatalog(unrelated, from: neverArmed.connection!)
check(neverArmed.visionAudio.starts == 0, "상관없는 catalog 응답은 실제 재생을 시작하지 않음")
neverArmed.respondToQuery()
check(neverArmed.visionAudio.starts == 1 && store.permits(neverArmed, direction: .playback),
      "보호와 native binding 및 상관된 fresh catalog 뒤 실제 시작 한 번")
var authorityAtStart = store.model
let lateTicket = authorityAtStart.request(neverArmed.visionAudioOwnerID, direction: .playback, manual: true)!
check(store.model.isCurrent(lateTicket), "보호 상실 전에 실제 권한 ticket이 유효함")
let stopsBeforeLoss = neverArmed.visionAudio.stops
privacyList.audioPrivacy = AudioPrivacyState(protected: false)
neverArmed.observeVisionAudioPrivacy(privacyList)
check(neverArmed.visionAudioPrivacyBlocked && neverArmed.visionAudio.stops > stopsBeforeLoss &&
      VisionAudioSharedHardware.shared.revoked.contains(neverArmed.visionAudioOwnerID) &&
      !store.permits(neverArmed, direction: .playback), "true에서 false 전환은 반환 전에 동기 오디오 철회")
check(!store.model.isCurrent(lateTicket), "보호 상실 전 ticket의 늦은 callback을 거절")
neverArmed.observeVisionAudioPrivacy(privacyList)
store.refresh()
check(neverArmed.visionAudioPrivacyBlocked && neverArmed.visionAudio.starts == 1 && neverArmed.nativeSelections == 1,
      "보호 상실 뒤 refresh는 실제 시작이나 수동 선택을 반복하지 않음")
check(store.model.intent.desired(.playback, hostKey: "never-armed") &&
      VisionRemoteAudioIntent.load(defaults).desired(.playback, hostKey: "never-armed"),
      "보호 상실은 저장한 사용자 재생 희망을 보존")
store.retire(neverArmed)

let waitingPrivacy = StreamClient("never-armed-waiting")
waitingPrivacy.context.nativeBindingReady = false
store.register(waitingPrivacy)
var waitingList = waitingPrivacy.visionAudioIntentCatalog!
waitingList.audioPrivacy = AudioPrivacyState(protected: false)
waitingPrivacy.observeVisionAudioPrivacy(waitingList)
check(store.beginPermission(legacy.visionAudioOwnerID), "기존 권한 callback 뒤로 수동 native 선택을 대기")
_ = store.setDesired(true, client: waitingPrivacy, direction: .playback, expectedScope: nil)
waitingPrivacy.observeVisionAudioPrivacy(waitingList)
store.refresh()
check(waitingPrivacy.nativeSelections == 0, "반복 OFF 관측 중 미제출 선택은 권한 대기 상태를 유지")
store.endPermission(legacy.visionAudioOwnerID)
check(waitingPrivacy.nativeSelections == 1 && waitingPrivacy.visionAudio.starts == 0,
      "대기 중 반복 OFF 관측 뒤에도 수동 native 선택 한 번을 보존")
store.retire(waitingPrivacy)

for privacy in [nil, AudioPrivacyState(version: 1, protected: false),
                AudioPrivacyState(version: 3, protected: true)] as [AudioPrivacyState?] {
    let unsupported = StreamClient("unsupported-\(privacy?.version ?? 0)")
    unsupported.context.nativeBindingReady = false
    store.register(unsupported)
    var list = unsupported.visionAudioIntentCatalog!
    list.audioPrivacy = privacy
    unsupported.observeVisionAudioPrivacy(list)
    _ = store.setDesired(true, client: unsupported, direction: .playback, expectedScope: nil)
    check(unsupported.visionAudioIntentContext.privacyVersion == privacy?.version &&
          !unsupported.visionAudioIntentContext.admitted && unsupported.nativeSelections == 0 &&
          unsupported.visionAudio.starts == 0, "최초 미지원 또는 알 수 없는 privacy 버전은 안전 거절")
    list.audioPrivacy = AudioPrivacyState(protected: false)
    unsupported.observeVisionAudioPrivacy(list)
    store.refresh()
    check(unsupported.visionAudioIntentContext.admitted && !unsupported.visionAudioIntentContext.eligible &&
          unsupported.nativeSelections == 0, "초기 unknown 뒤 유효한 v2 false는 새 수동 선택을 기다림")
    _ = store.setDesired(true, client: unsupported, direction: .playback, expectedScope: nil)
    check(unsupported.nativeSelections == 1 && unsupported.visionAudio.starts == 0,
          "초기 unknown에서 유효한 v2 false가 된 뒤 새 수동 native 요청 한 번 허용")
    list.audioPrivacy = AudioPrivacyState(protected: true)
    unsupported.observeVisionAudioPrivacy(list)
    let beforeLoss = unsupported.visionAudio.stops
    list.audioPrivacy = privacy
    unsupported.observeVisionAudioPrivacy(list)
    check(unsupported.visionAudioPrivacyBlocked && unsupported.visionAudio.stops > beforeLoss &&
          unsupported.visionAudio.starts == 0, "기존 true에서 privacy 지원 상실은 동기 철회")
    store.retire(unsupported)
}

for change in ["peer", "video", "missing", "version"] {
    let pending = StreamClient("never-armed-pending-" + change)
    pending.context.nativeBindingReady = false
    store.register(pending)
    var list = pending.visionAudioIntentCatalog!
    list.audioPrivacy = AudioPrivacyState(protected: false)
    pending.observeVisionAudioPrivacy(list)
    check(store.beginPermission(legacy.visionAudioOwnerID), "미제출 native 선택의 세대 변경을 대기")
    _ = store.setDesired(true, client: pending, direction: .playback, expectedScope: nil)
    let oldScope = pending.context.scope!
    if change == "peer" || change == "video" {
        if change == "peer" { pending.connection = NWConnection() }
        pending.context.scope = .init(connection: change == "peer" ? UUID() : oldScope.connection,
            window: oldScope.window, admission: oldScope.admission,
            video: change == "video" ? UUID() : oldScope.video,
            foreground: oldScope.foreground, privacy: oldScope.privacy)
    } else {
        list.audioPrivacy = change == "missing" ? nil : AudioPrivacyState(version: 3, protected: false)
        pending.observeVisionAudioPrivacy(list)
    }
    store.endPermission(legacy.visionAudioOwnerID)
    check(pending.nativeSelections == 0 && pending.visionAudio.starts == 0,
          "미제출 선택 뒤 " + change + " 변경은 pending과 실제 오디오를 열지 않음")
    check(store.model.intent.desired(.playback, hostKey: "never-armed-pending-" + change),
          "안전 거절 후에도 사용자 희망은 보존")
    store.retire(pending)
}

let protectedUnknown = StreamClient("protected-to-unknown")
store.register(protectedUnknown)
var unknownList = protectedUnknown.visionAudioIntentCatalog!
unknownList.audioPrivacy = AudioPrivacyState(protected: true)
protectedUnknown.observeVisionAudioPrivacy(unknownList)
protectedUnknown.visionAudioIntentCatalog = unknownList
_ = store.setDesired(true, client: protectedUnknown, direction: .playback, expectedScope: nil)
protectedUnknown.respondToQuery()
var protectedAuthority = store.model
let beforeUnknownTicket = protectedAuthority.request(protectedUnknown.visionAudioOwnerID,
    direction: .playback, manual: true)!
check(protectedUnknown.visionAudio.starts == 1 && store.model.isCurrent(beforeUnknownTicket),
      "unknown 전환 전 실제 권한과 재생이 유효함")
let beforeUnknownStops = protectedUnknown.visionAudio.stops
let beforeUnknownCatalog = protectedUnknown.visionAudioIntentCatalog!
unknownList.audioPrivacy = nil
protectedUnknown.observeVisionAudioPrivacy(unknownList)
check(!protectedUnknown.visionAudioIntentContext.admitted && protectedUnknown.visionAudioPrivacyBlocked &&
      protectedUnknown.visionAudio.stops > beforeUnknownStops && store.model.owner == nil &&
      !store.model.isCurrent(beforeUnknownTicket), "기존 true에서 unknown 전환은 admitted false로 owner와 늦은 권한 철회")
protectedUnknown.receiveCatalog(beforeUnknownCatalog, from: protectedUnknown.connection!)
check(protectedUnknown.visionAudio.starts == 1 && !store.permits(protectedUnknown, direction: .playback),
      "unknown 뒤 이전 peer catalog의 늦은 응답으로 다시 열리지 않음")
unknownList.audioPrivacy = AudioPrivacyState(protected: false)
protectedUnknown.observeVisionAudioPrivacy(unknownList)
_ = store.setDesired(true, client: protectedUnknown, direction: .playback, expectedScope: nil)
check(protectedUnknown.visionAudioPrivacyBlocked && protectedUnknown.nativeSelections == 1 &&
      protectedUnknown.visionAudio.starts == 1, "진짜 보호 상실 뒤 false는 최초 정상 OFF로 정규화하지 않음")
store.retire(protectedUnknown)
print("RESULT_ASSERTIONS \(checks)")
