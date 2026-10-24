import Foundation
import Network
import StreamProtocol

var assertions = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    assertions += 1
    if !condition() { failures += 1; print("FAIL \(label)") }
}
func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015)) }
func admissionCatalog(_ catalog: WindowList, _ admission: [String: Any]?) -> WindowList? {
    var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as! [String: Any]
    object["sourceSelectionAdmission"] = admission
    return try? JSONDecoder().decode(WindowList.self, from: JSONSerialization.data(withJSONObject: object))
}
func admission(_ generation: UInt64 = 1, ready: Bool = true) -> [String: Any] {
    ["schemaVersion": 1, "generation": generation, "ready": ready]
}
let inventory = UUID()
let rows = [DisplayInfo(id: 11, name: "호스트 원문 A", width: 1920, height: 1080, isMain: true),
            DisplayInfo(id: 22, name: "Host B", width: 2560, height: 1440, isMain: false)]
func list(_ id: UInt32? = nil, source: StreamSource = .none, generation: String = "g0",
          inventoryID: UUID = inventory, capability: Int? = 1, required: Bool = true,
          epoch: VideoEpoch? = nil) -> WindowList {
    WindowList(macName: "Fixture", windows: [], active: source, inputGeneration: generation,
               presentationInput: 1, videoEpoch: epoch, displaySelection: capability,
               displays: rows, displayInventoryID: inventoryID, activeDisplayID: id,
               desktopSelectionRequired: required)
}
func epoch(_ generation: String = "g1", source: StreamSource = .desktop) -> VideoEpoch {
    VideoEpoch(generation: generation, source: source,
               geometry: .init(x: 0, y: 0, width: 1920, height: 1080), width: 1920, height: 1080)
}
func model() -> VisionDisplaySelection {
    var state = VisionDisplaySelection()
    state.bind(peerEpoch: UUID())
    state.admit(lease: VisionWindowLease(window: UUID()), foreground: true)
    state.observe(.init(list()))
    return state
}
func command(_ state: VisionDisplaySelection, _ display: UInt32 = 22, id: UUID = UUID()) -> VisionDisplaySelection.Command {
    .init(requestID: id, displayID: display, token: state.token!)
}
var state = model()
let first = command(state)
check(state.preview(first).code == .ready && state.pending == nil, "preview has no effects")
check(try! JSONDecoder().decode(VisionDisplaySelection.Command.self, from: JSONEncoder().encode(first)) == first,
      "structured command round trips full token and desired display")
check(state.begin(first).code == .releasing && state.inputBlocked, "begin blocks input")
check(state.begin(first).code == .releasing, "same ID same command stays idempotent")
check(state.begin(command(state)).code == .busy, "one pending command owns admission")
check(state.begin(.init(requestID: first.requestID, displayID: 11, token: first.token)).code == .conflictingID,
      "same ID conflicting display refused")
check(state.released(first.requestID, confirmed: true), "release passes unchanged full scope")
state.submitted(first.requestID)
let displayed = epoch()
var neighbors = model()
var neighborList = list(22, source: .desktop, required: false, epoch: displayed)
neighborList.displays = rows + [DisplayInfo(id: 33, name: "가상 모니터", width: 2560, height: 1440, isMain: false)]
neighbors.observe(.init(neighborList))
let neighborToken = neighbors.token!
check(neighbors.adjacentCommand(by: 1, expected: neighborToken)?.displayID == 33 &&
      neighbors.adjacentCommand(by: -1, expected: neighborToken)?.displayID == 11,
      "rotation selects adjacent actual inventory entries in both directions")
check(neighbors.adjacentCommand(by: 2, expected: neighborToken) == nil &&
      neighbors.adjacentCommand(by: 0, expected: neighborToken) == nil,
      "rotation cannot skip monitors or request no movement")
neighborList.activeDisplayID = 11; neighbors.observe(.init(neighborList))
check(neighbors.adjacentCommand(by: -1, expected: neighbors.token!)?.displayID == 33,
      "previous monitor wraps once from the first entry")
neighborList.activeDisplayID = 33; neighbors.observe(.init(neighborList))
check(neighbors.adjacentCommand(by: 1, expected: neighbors.token!)?.displayID == 11,
      "next monitor wraps once from the last entry")
check(neighbors.adjacentCommand(by: 1, expected: neighborToken) == nil,
      "rotation rejects an obsolete catalog token")
let pendingNeighbor = neighbors.adjacentCommand(by: 1, expected: neighbors.token!)!
_ = neighbors.begin(pendingNeighbor)
check(neighbors.adjacentCommand(by: 1, expected: neighbors.token!) == nil,
      "rotation cannot enqueue another monitor while selection is pending")
var single = model(); var singleList = list(11, source: .desktop, required: false, epoch: displayed)
singleList.displays = [rows[0]]; single.observe(.init(singleList))
check(single.adjacentCommand(by: 1, expected: single.token!) == nil,
      "one monitor never creates a redundant selection request")
state.presented(displayed)
check(state.pending != nil, "presentation alone is not convergence")
state.observe(.init(list(22, source: .desktop, generation: "g1", required: false, epoch: displayed)))
check(state.pending != nil, "post-send catalog alone is not presentation")
state.presented(epoch())
check(state.pending != nil, "unmatched video epoch cannot complete")
state.presented(displayed)
check(state.lastResult?.code == .observed && !state.inputBlocked, "matching post-send catalog and presentation converge")
check(state.begin(first).code == .observed && state.pending == nil, "duplicate completed ID never repeats effects")

for change in 0..<4 {
    var s = model(); let c = command(s); _ = s.begin(c)
    switch change {
    case 0: s.admit(lease: s.lease, foreground: false)
    case 1: s.admit(lease: VisionWindowLease(window: s.lease!.window), foreground: true)
    case 2: s.bind(peerEpoch: UUID())
    default: s.observe(.init(list(inventoryID: UUID())))
    }
    check(!s.released(c.requestID, confirmed: true) && s.pending == nil, "changed scope refuses release callback \(change)")
}
var stale = model(); let old = command(stale)
stale.observe(.init(list(generation: "new")))
check(stale.preview(old).code == .staleScope, "catalog revision binds request")
var invalid = model()
check(invalid.preview(command(invalid, 99)).code == .unknownDisplay, "unknown desired display refused")
var invalidList = list(99, required: false)
invalid.observe(.init(invalidList))
check(invalid.preview(command(invalid)).code == .invalidInventory, "active display must belong to inventory")
invalidList = list(22, source: .desktop, required: true, epoch: displayed)
invalid.observe(.init(invalidList))
check(invalid.preview(command(invalid)).code == .invalidInventory, "required selection cannot claim selected active state")
invalidList = list(); invalidList.displays = nil; invalid.observe(.init(invalidList))
check(invalid.preview(command(invalid)).code == .invalidInventory, "missing inventory rows refused")
invalidList = list(); invalidList.displayInventoryID = nil; invalid.observe(.init(invalidList))
check(invalid.token == nil && invalid.choices.isEmpty, "missing inventory token cannot form a request")
var legacy = VisionDisplaySelection(); legacy.bind(peerEpoch: UUID())
legacy.admit(lease: VisionWindowLease(window: UUID()), foreground: true)
legacy.observe(.init(list(capability: nil, required: false)))
check(legacy.legacyDesktopAllowed && legacy.preview(command(legacy)).code == .legacyOnly, "absent capability explicitly permits legacy desktop only")
legacy.observe(.init(list())); legacy.observe(.init(list(capability: nil, required: false)))
check(!legacy.legacyDesktopAllowed && legacy.preview(command(legacy)).code == .unsupportedCapability, "modern downgrade cannot fall back")
var wrong = model(); let wrongCommand = command(wrong); _ = wrong.begin(wrongCommand)
_ = wrong.released(wrongCommand.requestID, confirmed: true); wrong.submitted(wrongCommand.requestID)
wrong.observe(.init(list(11, source: .desktop, generation: "g1", required: false, epoch: displayed)))
wrong.presented(displayed)
check(wrong.lastResult?.code == .sourceChanged && wrong.inputBlocked, "wrong display never completes")
var timed = model(); let timedCommand = command(timed); _ = timed.begin(timedCommand)
timed.timeout(timedCommand.requestID)
timed.submitted(timedCommand.requestID); timed.presented(displayed)
check(timed.lastResult?.code == .timedOut && timed.pending == nil && timed.inputBlocked, "late timeout callbacks never revive input")

func client() -> (StreamClient, NWConnection) {
    let c = StreamClient(); let peer = NWConnection(); c.connection = peer
    c.admitVisionDisplays(lease: VisionWindowLease(window: UUID()), foreground: true)
    c.observeVisionDisplays(list(), from: peer)
    return (c, peer)
}
let (rotatedClient, rotatedPeer) = client()
rotatedClient.observeVisionDisplays(list(11, source: .desktop, required: false, epoch: displayed), from: rotatedPeer)
let rotatedToken = rotatedClient.visionDisplaySelection.token!
check(rotatedClient.selectAdjacentVisionDisplay(by: 1, expected: rotatedToken),
      "actual rotation adapter enters the existing monitor release transaction")
check(rotatedPeer.sent.isEmpty && rotatedClient.releaseCallbacks.count == 1,
      "rotation waits for actual input release before requesting a monitor")
check(!rotatedClient.selectAdjacentVisionDisplay(by: 1, expected: rotatedToken) && rotatedClient.releaseCallbacks.count == 1,
      "pending rotation cannot create another release transaction")
rotatedClient.releaseCallbacks[0](true); drain()
let rotatedSelection = rotatedPeer.sent.first.flatMap { Wire.decode(DisplaySelection.self,
    from: Data($0.dropFirst(StreamMessage.headerLength))) }
check(rotatedPeer.sent.count == 1 && rotatedPeer.sent[0].first == StreamMessageKind.selectDisplay.rawValue &&
      rotatedSelection == DisplaySelection(displayID: 22, inventoryID: inventory, origin: .human),
      "rotation sends one exact monitor ID and inventory over the existing scoped transport")
let (native, peer) = client()
let request = command(native.visionDisplaySelection)
_ = native.selectVisionDisplay(request)
check(peer.sent.isEmpty && native.releaseCallbacks.count == 1 && native.visionInputSession?.allowed == false &&
      native.draftRevocations == 1 && native.microphoneStops == 1 && native.visionAudio.stops == 1,
      "production adapter revokes input drafts microphone audio before release")
_ = native.selectVisionDisplay(request)
check(native.releaseCallbacks.count == 1 && peer.sent.isEmpty, "adapter duplicate does not release or send twice")
native.releaseCallbacks[0](true); drain()
check(peer.sent.count == 1 && peer.sent[0].first == StreamMessageKind.selectDisplay.rawValue, "production adapter sends only kind211")
let decoded = Wire.decode(DisplaySelection.self, from: Data(peer.sent[0].dropFirst(StreamMessage.headerLength)))
check(decoded == DisplaySelection(displayID: 22, inventoryID: inventory, origin: .human), "wire uses explicit desired display and exact inventory")
native.observeVisionDisplays(list(22, source: .desktop, generation: "g1", required: false, epoch: displayed), from: peer)
check(native.visionDisplaySelection.pending != nil, "adapter catalog observation is not causal ACK")
native.visionInputBinding = .presented(displayed); native.confirmVisionDisplayPresentation()
check(native.visionDisplaySelection.lastResult?.code == .observed, "adapter waits for presented epoch")

for denial in 0..<6 {
    let (c, p) = client(); let r = command(c.visionDisplaySelection); _ = c.selectVisionDisplay(r)
    let replacement = NWConnection()
    switch denial {
    case 0: c.releaseCallbacks[0](false)
    case 1: c.admitVisionDisplays(lease: c.visionDisplaySelection.lease, foreground: false); c.releaseCallbacks[0](true)
    case 2: c.admitVisionDisplays(lease: VisionWindowLease(window: UUID()), foreground: true); c.releaseCallbacks[0](true)
    case 3: c.connection = replacement; c.releaseCallbacks[0](true)
    case 4: c.observeVisionDisplays(list(source: .window(8), generation: "changed"), from: p); c.releaseCallbacks[0](true)
    default: c.visionDisplayDeadline!.perform(); c.releaseCallbacks[0](true)
    }
    drain()
    check(p.sent.isEmpty && replacement.sent.isEmpty && c.visionDisplaySelection.pending == nil,
          "production adapter refuses stale release and denial \(denial)")
}
for invalidation in 0..<4 {
    let (c, p) = client(); _ = c.link.hold(p)
    let r = command(c.visionDisplaySelection); _ = c.selectVisionDisplay(r); c.releaseCallbacks[0](true)
    switch invalidation {
    case 0: c.cancelVisionDisplaySelection()
    case 1: c.visionDisplayDeadline!.perform()
    case 2: c.observeVisionDisplays(list(inventoryID: UUID()), from: p)
    default: c.admitVisionDisplays(lease: nil, foreground: false)
    }
    _ = c.link.unhold(p); drain()
    check(p.sent.isEmpty && c.visionDisplaySelection.pending == nil && c.visionDisplaySelection.inputBlocked,
          "actual SessionLink removes cancelled held selection \(invalidation)")
}
let (late, latePeer) = client()
let lateCommand = command(late.visionDisplaySelection); _ = late.selectVisionDisplay(lateCommand)
late.releaseCallbacks[0](true)
late.visionDisplayDeadline!.perform(); drain()
late.observeVisionDisplays(list(22, source: .desktop, generation: "g1", required: false, epoch: displayed), from: latePeer)
late.visionInputBinding = .presented(displayed); late.confirmVisionDisplayPresentation()
check(late.visionDisplaySelection.lastResult?.code == .timedOut && late.visionDisplaySelection.inputBlocked,
      "submitted late completion cannot revive timed out selection")
let fresh = command(late.visionDisplaySelection)
check(late.selectVisionDisplay(fresh).code == .releasing, "timeout recovery requires a fresh explicit request")
late.cancelVisionDisplaySelection()
let (automatic, autoPeer) = client()
automatic.automatic(.desktop)
check(autoPeer.sent.isEmpty, "actual native request blocks automatic and direct desktop on modern host")
automatic.observeVisionDisplays(list(capability: 1, required: true), from: autoPeer)
automatic.automatic(.desktop)
check(autoPeer.sent.isEmpty, "required selection never triggers desktop fallback")
for queued in [false, true] {
    let (c, p) = client()
    let r = command(c.visionDisplaySelection)
    if queued { _ = c.link.hold(p) }
    _ = c.selectVisionDisplay(r)
    if queued { c.releaseCallbacks[0](true) }
    c.visionDisplayApplicationActive = false
    c.appWillResign()
    if queued { _ = c.link.unhold(p) }
    else { c.releaseCallbacks[0](true) }
    drain()
    check(p.sent.isEmpty && c.visionDisplaySelection.lastResult?.code == .foregroundRequired,
          "native willResign cancels release and queued flush \(queued)")
    c.visionDisplayApplicationActive = true
    c.admitVisionDisplays(lease: c.visionDisplaySelection.lease, foreground: true)
    c.releaseCallbacks[0](true); drain()
    check(p.sent.isEmpty && c.visionDisplaySelection.pending == nil, "foreground return never resumes old request \(queued)")
}
let (inactive, inactivePeer) = client()
let inactiveCommand = command(inactive.visionDisplaySelection)
inactive.visionDisplayApplicationActive = false
check(inactive.selectVisionDisplay(inactiveCommand).code == .foregroundRequired && inactivePeer.sent.isEmpty &&
      inactive.releaseCallbacks.isEmpty, "actual app inactive refuses scene-active selection")
let (race, racePeer) = client()
_ = race.selectVisionDisplay(command(race.visionDisplaySelection))
race.visionDisplayApplicationActive = false
race.releaseCallbacks[0](true); drain()
check(racePeer.sent.isEmpty && race.visionDisplaySelection.lastResult?.code == .foregroundRequired,
      "release callback rechecks actual app state before native phase notification")
let oldClient = StreamClient(); let oldPeer = NWConnection(); oldClient.connection = oldPeer
oldClient.observeVisionDisplays(list(capability: nil, required: false), from: oldPeer)
oldClient.automatic(.desktop)
check(oldPeer.sent.count == 1 && oldPeer.sent[0].first == StreamMessageKind.selectSource.rawValue,
      "legacy explicit desktop keeps its wire action")
native.cancelVisionDisplaySelection(); automatic.cancelVisionDisplaySelection()
var transitionCatalog = model()
transitionCatalog.observe(.init(list(nil, source: .window(7), generation: "old", required: false, epoch: epoch("old", source: .window(7)))))
let transitionCommand = command(transitionCatalog)
_ = transitionCatalog.begin(transitionCommand)
_ = transitionCatalog.released(transitionCommand.requestID, confirmed: true)
transitionCatalog.submitted(transitionCommand.requestID)
transitionCatalog.observe(.init(list(22, source: .window(7), generation: "next", required: false)))
let finalDisplayEpoch = epoch("next")
transitionCatalog.observe(.init(list(22, source: .desktop, generation: "next", required: false, epoch: finalDisplayEpoch)))
transitionCatalog.presented(finalDisplayEpoch)
check(transitionCatalog.lastResult?.code == .observed && !transitionCatalog.inputBlocked,
      "ordinary epochless host transition can converge without permanent input block")
var orphanModal = model()
orphanModal.setModal(true)
orphanModal.admit(lease: nil, foreground: false)
orphanModal.bind(peerEpoch: UUID())
orphanModal.admit(lease: VisionWindowLease(window: UUID()), foreground: true)
orphanModal.observe(.init(list()))
check(!orphanModal.inputBlocked, "released window cannot leave hidden chooser admission in replacement session")

var interruptedCatalog = model()
let interruptedCommand = command(interruptedCatalog)
_ = interruptedCatalog.begin(interruptedCommand)
_ = interruptedCatalog.released(interruptedCommand.requestID, confirmed: true)
interruptedCatalog.submitted(interruptedCommand.requestID)
interruptedCatalog.observe(.init(list(22, source: .desktop, generation: "g1", required: false, epoch: displayed)))
interruptedCatalog.observe(.init(list(generation: "next", required: false)))
interruptedCatalog.presented(displayed)
check(interruptedCatalog.pending?.code == .observing && interruptedCatalog.inputBlocked,
      "epochless transition invalidates prior convergence catalog without completing or cancelling")
let conflictingEpoch = epoch("conflict", source: .window(8))
interruptedCatalog.observe(.init(list(source: .window(8), generation: "conflict", required: false, epoch: conflictingEpoch)))
interruptedCatalog.presented(conflictingEpoch)
check(interruptedCatalog.pending == nil && interruptedCatalog.lastResult?.code == .sourceChanged && interruptedCatalog.inputBlocked,
      "conflicting final catalog after epochless transition remains rejected")
var cancelledModal = model()
cancelledModal.setModal(true)
let cancelledModalCommand = command(cancelledModal)
_ = cancelledModal.begin(cancelledModalCommand)
cancelledModal.admit(lease: VisionWindowLease(window: cancelledModal.lease!.window), foreground: true)
check(!cancelledModal.modal && cancelledModal.pending == nil &&
      cancelledModal.lastResult?.code == .admissionChanged && cancelledModal.inputBlocked,
      "replacement lease clears modal while cancelled selection remains unresolved")

let (startupDisplay, startupDisplayPeer) = client()
startupDisplay.session = .init(macID: "0123456789ABCDEF")
startupDisplay.trustedDisplayPeer = true
var startupDisplayCatalog = list()
startupDisplayCatalog.launchID = "host-launch"
startupDisplayCatalog.automaticDisplaySelection = 1
startupDisplayCatalog.selectionRevision = "r0"
startupDisplayCatalog = admissionCatalog(startupDisplayCatalog, admission())!
startupDisplay.observeVisionDisplays(startupDisplayCatalog, from: startupDisplayPeer)
check(startupDisplay.releaseCallbacks.count == 1 && startupDisplayPeer.sent.isEmpty,
      "인증한 최초 빈 화면은 별도 모드 없이 main 선택의 입력 해제를 시작한다")

startupDisplay.observeVisionDisplays(startupDisplayCatalog, from: startupDisplayPeer)
check(startupDisplay.releaseCallbacks.count == 1, "같은 inventory 반복 catalog는 자동 요청을 추가하지 않는다")
startupDisplay.releaseCallbacks[0](true); drain()
let initialAutomatic = startupDisplayPeer.sent.first.flatMap { Wire.decode(DisplaySelection.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
check(initialAutomatic?.displayID == 11 && initialAutomatic?.origin == .automatic && initialAutomatic?.selectionRevision == "r0",
      "main 자동 요청은 최초 revision과 명시적 automatic을 그대로 보낸다")
check(UserDefaults.standard.values.isEmpty, "제출만으로 마지막 화면을 저장하지 않는다")
var startupAccepted = startupDisplayCatalog
startupAccepted.selectionRevision = "r1"; startupAccepted.active = .desktop
startupAccepted.activeDisplayID = 11; startupAccepted.desktopSelectionRequired = false
startupAccepted.inputGeneration = "auto1"; startupAccepted.videoEpoch = epoch("auto1")
startupDisplay.observeVisionDisplays(startupAccepted, from: startupDisplayPeer)
check(UserDefaults.standard.values.isEmpty, "catalog만으로 실제 표시를 확정하거나 저장하지 않는다")
startupDisplay.visionInputBinding = .presented(startupAccepted.videoEpoch!)
startupDisplay.confirmVisionDisplayPresentation()
check(!startupDisplay.visionDisplaySelection.inputBlocked && UserDefaults.standard.values.count == 1,
      "현재 catalog와 실제 표시 epoch가 수렴한 뒤 입력과 저장을 확정한다")

func automaticCatalog(inventoryID: UUID? = inventory, revision: String = "r0") -> WindowList {
    var result = list()
    result.launchID = "host-launch"; result.automaticDisplaySelection = 1
    result.selectionRevision = revision; result.displayInventoryID = inventoryID
    return admissionCatalog(result, admission())!
}
func automaticClient(_ catalog: WindowList = automaticCatalog(), trusted: Bool = true) -> (StreamClient, NWConnection) {
    UserDefaults.standard.values = [:]
    let (client, peer) = client()
    client.session = .init(macID: "0123456789ABCDEF"); client.trustedDisplayPeer = trusted
    client.observeVisionDisplays(catalog, from: peer)
    return (client, peer)
}
for invalid in ["legacy", "cap", "revision", "longRevision", "launch", "main", "twoMain", "unauthenticated"] {
    var catalog = automaticCatalog()
    switch invalid {
    case "legacy": catalog.automaticDisplaySelection = nil
    case "cap": catalog.automaticDisplaySelection = 2
    case "revision": catalog.selectionRevision = ""
    case "longRevision": catalog.selectionRevision = String(repeating: "가", count: 43)
    case "launch": catalog.launchID = ""
    case "main": catalog.displays = rows.map { var row = $0; row.isMain = false; return row }
    case "twoMain": catalog.displays = rows.map { var row = $0; row.isMain = true; return row }
    default: break
    }
    let (client, peer) = automaticClient(catalog, trusted: invalid != "unauthenticated")
    check(client.releaseCallbacks.isEmpty && peer.sent.isEmpty, "자동 시작 경계가 맞지 않으면 전송0 \(invalid)")
}
let (lateAuthentication, lateAuthenticationPeer) = automaticClient(trusted: false)
lateAuthentication.trustedDisplayPeer = true; lateAuthentication.reconcileVisionAutomaticDisplay()
check(lateAuthentication.releaseCallbacks.count == 1 && lateAuthenticationPeer.sent.isEmpty,
      "catalog보다 인증이 늦어도 새 catalog 없이 기존 입력 해제 경로로 진행한다")

let (topologyClient, topologyPeer) = automaticClient()
let topologyIDs = [inventory, UUID(), UUID()]
for index in 0..<topologyIDs.count {
    if index > 0 {
        topologyClient.observeVisionDisplays(automaticCatalog(inventoryID: nil), from: topologyPeer)
        topologyClient.observeVisionDisplays(automaticCatalog(inventoryID: topologyIDs[index]), from: topologyPeer)
    }
    check(topologyClient.releaseCallbacks.count == index + 1, "새 유효 inventory마다 최초 r0 기회를 한 번 이어간다 \(index)")
    topologyClient.releaseCallbacks[index](true); drain()
    topologyClient.observeVisionDisplays(automaticCatalog(inventoryID: topologyIDs[index]), from: topologyPeer)
    check(topologyClient.releaseCallbacks.count == index + 1, "같은 inventory 중복은 추가 제출0 \(index)")
}
let topologySelections = topologyPeer.sent.compactMap { Wire.decode(DisplaySelection.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
check(topologySelections.count == 3 && topologySelections.allSatisfy { $0.origin == .automatic && $0.selectionRevision == "r0" } && topologySelections.map(\.inventoryID) == topologyIDs,
      "A에서 B와 C로 바뀌어도 새 inventory와 원래 r0만 전송한다")
topologyClient.observeVisionDisplays(automaticCatalog(inventoryID: topologyIDs.last!, revision: "r1"), from: topologyPeer)
let afterAcceptanceCount = topologyClient.releaseCallbacks.count
let hostRecoveredInventory = UUID()
topologyClient.observeVisionDisplays(automaticCatalog(inventoryID: hostRecoveredInventory, revision: "r1"), from: topologyPeer)
check(topologyClient.releaseCallbacks.count == afterAcceptanceCount, "r1 뒤에는 새 inventory라도 client가 재기준화하지 않는다")
var recoveredCatalog = automaticCatalog(inventoryID: hostRecoveredInventory, revision: "r1")
recoveredCatalog.active = .desktop; recoveredCatalog.activeDisplayID = 11
recoveredCatalog.desktopSelectionRequired = false; recoveredCatalog.inputGeneration = "recovered"
recoveredCatalog.videoEpoch = epoch("recovered")
topologyClient.observeVisionDisplays(recoveredCatalog, from: topologyPeer)
check(topologyClient.visionDisplaySelection.inputBlocked && UserDefaults.standard.values.isEmpty,
      "host-owned 복구 catalog도 실제 표시 전에는 입력·저장 수렴이 아니다")
topologyClient.visionInputBinding = .presented(recoveredCatalog.videoEpoch!)
topologyClient.confirmVisionDisplayPresentation()
check(!topologyClient.visionDisplaySelection.inputBlocked && UserDefaults.standard.values.count == 1,
      "host-owned 실제 새 epoch를 표시하면 취소된 자동 요청을 ACK로 바꾸지 않고 입력을 복원한다")

for mutation in ["auth", "mac", "host", "cap", "lease", "background", "modal"] {
    for queued in [false, true] {
        let (client, peer) = automaticClient()
        if queued { _ = client.link.hold(peer); client.releaseCallbacks[0](true) }
        switch mutation {
        case "auth": client.trustedDisplayPeer = false; client.reconcileVisionAutomaticDisplay()
        case "mac": client.session = .init(macID: "OTHER-MAC"); client.reconcileVisionAutomaticDisplay()
        case "host": var changed = automaticCatalog(); changed.launchID = "other-host"; client.observeVisionDisplays(changed, from: peer)
        case "cap": var changed = automaticCatalog(); changed.automaticDisplaySelection = nil; client.observeVisionDisplays(changed, from: peer)
        case "lease": client.admitVisionDisplays(lease: nil, foreground: false)
        case "background": client.visionDisplayApplicationActive = false; client.appWillResign()
        default: client.setVisionDisplayModal(true)
        }
        if queued { _ = client.link.unhold(peer) } else { client.releaseCallbacks[0](true) }
        drain()
        check(peer.sent.isEmpty, "해제 대기·실제 큐 전송 중 경계 변경은 이전 제출을 제거한다 \(mutation)/\(queued)")
    }
}
let (manualOverride, manualOverridePeer) = automaticClient()
_ = manualOverride.link.hold(manualOverridePeer); manualOverride.releaseCallbacks[0](true)
manualOverride.automatic(.window(81)); _ = manualOverride.link.unhold(manualOverridePeer); drain()
let manualWindow = manualOverridePeer.sent.first.flatMap { Wire.decode(SourceRequest.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
check(manualOverridePeer.sent.count == 1 && manualWindow?.source == .window(81) && manualWindow?.origin == .human,
      "명시적 창 선택은 대기 중 자동 화면을 취소하고 human 요청만 보낸다")
manualOverride.observeVisionDisplays(automaticCatalog(inventoryID: UUID()), from: manualOverridePeer)
check(manualOverride.releaseCallbacks.count == 1, "명시적 사람 선택 뒤에는 초기 자동 의도를 되살리지 않는다")

for kind in ["matching", "mac", "launch", "inventory", "malformed", "oversized"] {
    UserDefaults.standard.values = [:]
    let (client, peer) = client()
    client.session = .init(macID: "0123456789ABCDEF"); client.trustedDisplayPeer = true
    let remembered = VisionDisplaySelection.Remembered(macID: kind == "mac" ? "OTHER" : "0123456789ABCDEF",
        launchID: kind == "launch" ? "OTHER" : "host-launch", inventoryID: kind == "inventory" ? UUID() : inventory, displayID: 22)
    let bytes = kind == "malformed" ? Data([0, 1]) : kind == "oversized" ? Data(repeating: 0, count: 4097) : try! JSONEncoder().encode(remembered)
    UserDefaults.standard.values["SillVerifiedDisplay.0123456789ABCDEF"] = bytes
    client.observeVisionDisplays(automaticCatalog(), from: peer)
    client.releaseCallbacks[0](true); drain()
    let selected = peer.sent.first.flatMap { Wire.decode(DisplaySelection.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
    check(selected?.displayID == (kind == "matching" ? 22 : 11), "마지막 화면은 같은 인증 Mac·host·inventory에서만 복원한다 \(kind)")
}
let (forgedAuto, forgedPeer) = client()
let forgedCommand = VisionDisplaySelection.Command(requestID: UUID(), displayID: 11,
    token: forgedAuto.visionDisplaySelection.token!, automaticRevision: "forged")
check(forgedAuto.selectVisionDisplay(forgedCommand).code == .staleScope && forgedAuto.releaseCallbacks.isEmpty && forgedPeer.sent.isEmpty,
      "외부 구조화 명령이 임의 automatic revision으로 준비·해제 효과를 만들지 않는다")
for boundary in ["foreground", "admission", "modal"] {
    let (client, peer) = automaticClient()
    let lease = client.visionDisplaySelection.lease!
    if boundary == "foreground" {
        client.admitVisionDisplays(lease: lease, foreground: false)
        client.admitVisionDisplays(lease: lease, foreground: true)
    } else if boundary == "admission" {
        client.admitVisionDisplays(lease: VisionWindowLease(window: lease.window), foreground: true)
    } else {
        client.setVisionDisplayModal(true); client.setVisionDisplayModal(false)
    }
    check(client.releaseCallbacks.count == 2, "정상 재입장에서는 같은 r0라도 새 사용권의 해제를 다시 확인한다 \(boundary)")
    client.releaseCallbacks[0](true); drain()
    check(peer.sent.isEmpty, "재입장 전 해제 완료는 새 사용권의 요청을 대신 보내지 않는다 \(boundary)")
    client.releaseCallbacks[1](true); drain()
    check(peer.sent.count == 1, "새 사용권의 실제 해제 뒤 한 번만 전송한다 \(boundary)")
}
let (remoteHuman, remoteHumanPeer) = automaticClient()
remoteHuman.releaseCallbacks[0](true); drain()
var remoteHumanCatalog = automaticCatalog(revision: "r1")
remoteHumanCatalog.active = .window(81); remoteHumanCatalog.desktopSelectionRequired = false
remoteHumanCatalog.inputGeneration = "human-window"; remoteHumanCatalog.videoEpoch = epoch("human-window", source: .window(81))
remoteHuman.observeVisionDisplays(remoteHumanCatalog, from: remoteHumanPeer)
remoteHuman.visionInputBinding = .presented(remoteHumanCatalog.videoEpoch!)
remoteHuman.confirmVisionDisplayPresentation()
check(!remoteHuman.visionDisplaySelection.inputBlocked && remoteHuman.visionDisplaySelection.lastResult?.code == .sourceChanged && UserDefaults.standard.values.isEmpty,
      "다른 사람 선택의 실제 표시를 따라가되 자동 선택 성공이나 모니터 저장으로 위조하지 않는다")

for stale in [false, true] {
    let (client, peer) = automaticClient()
    _ = client.link.hold(peer); client.releaseCallbacks[0](true)
    let oldDeadline = client.visionDisplayDeadline!
    let token = client.visionDisplaySelection.token!
    let manualToken = stale ? VisionDisplaySelection.Token(peerEpoch: token.peerEpoch, window: token.window,
        admission: token.admission, inventory: token.inventory, revision: token.revision + 1) : token
    let human = VisionDisplaySelection.Command(requestID: UUID(), displayID: 22, token: manualToken)
    let result = client.selectVisionDisplay(human)
    _ = client.link.unhold(peer); drain()
    check(peer.sent.isEmpty && oldDeadline.isCancelled,
          "직접 수동 모니터 명령은 거절돼도 이전 자동 큐와 deadline을 취소한다 \(stale)")
    if stale {
        check(result.code == .staleScope && client.releaseCallbacks.count == 1,
              "stale 수동 명령은 새 해제 효과를 만들지 않는다")
    } else {
        check(result.code == .releasing && client.releaseCallbacks.count == 2,
              "유효 수동 모니터는 독립적인 새 입력 해제를 기다린다")
        client.releaseCallbacks[1](true); drain()
        let sent = peer.sent.first.flatMap { Wire.decode(DisplaySelection.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
        check(peer.sent.count == 1 && sent?.origin == .human && sent?.displayID == 22,
              "직접 수동 해제가 끝난 뒤 human 모니터 명령만 한 번 보낸다")
    }
}
for malformed in ["duplicate", "inventory", "capability", "required"] {
    let (client, peer) = automaticClient()
    client.releaseCallbacks[0](true); drain()
    var display = automaticCatalog(revision: "r1")
    display.active = .desktop; display.activeDisplayID = 11; display.desktopSelectionRequired = false
    display.inputGeneration = "invalid-catalog"; display.videoEpoch = epoch("invalid-catalog")
    switch malformed {
    case "duplicate": display.displays = [rows[0], rows[0]]
    case "inventory": display.displayInventoryID = nil
    case "capability": display.displaySelection = 2
    default: display.desktopSelectionRequired = true
    }
    client.observeVisionDisplays(display, from: peer)
    client.visionInputBinding = .presented(display.videoEpoch!); client.confirmVisionDisplayPresentation()
    check(client.visionDisplaySelection.inputBlocked && UserDefaults.standard.values.isEmpty,
          "표시 epoch만 맞아도 잘못된 desktop 목록은 입력·저장을 수용하지 않는다 \(malformed)")
}

let (blockedSelection, blockedSelectionPeer) = automaticClient(admissionCatalog(automaticCatalog(), admission(1, ready: false))!)
check(blockedSelection.releaseCallbacks.isEmpty && blockedSelectionPeer.sent.isEmpty,
      "보호 준비 중에는 자동 선택의 해제와 전송 기회를 소모하지 않는다")
let readySelection = admissionCatalog(automaticCatalog(), admission(2))!
blockedSelection.observeVisionDisplays(readySelection, from: blockedSelectionPeer)
check(blockedSelection.releaseCallbacks.count == 1, "같은 inventory의 새 허용 세대에서 자동 선택을 시작한다")
blockedSelection.observeVisionDisplays(readySelection, from: blockedSelectionPeer)
check(blockedSelection.releaseCallbacks.count == 1, "같은 허용 세대의 반복 목록은 해제를 중복 요청하지 않는다")
if blockedSelection.releaseCallbacks.count == 1 { blockedSelection.releaseCallbacks[0](true); drain() }
check(blockedSelectionPeer.sent.count == 1, "새 허용 세대는 기존 입력 해제 뒤 한 번만 전송한다")

let (coalescedSelection, coalescedPeer) = automaticClient()
coalescedSelection.releaseCallbacks[0](true); drain()
coalescedSelection.observeVisionDisplays(admissionCatalog(automaticCatalog(), admission(3))!, from: coalescedPeer)
check(coalescedSelection.releaseCallbacks.count == 2,
      "중간 불가 목록이 생략돼도 새 허용 세대에서 미확인 원래 선택을 재개한다")
if coalescedSelection.releaseCallbacks.count == 2 { coalescedSelection.releaseCallbacks[1](true); drain() }
check(coalescedPeer.sent.count == 2, "미확인 선택은 새 허용 세대에만 한 번 재제출한다")
coalescedSelection.observeVisionDisplays(admissionCatalog(automaticCatalog(), admission(3))!, from: coalescedPeer)
check(coalescedSelection.releaseCallbacks.count == 2 && coalescedPeer.sent.count == 2,
      "같은 세대의 반복 목록은 재전송하지 않는다")
let recoveredSelections = coalescedPeer.sent.compactMap { Wire.decode(DisplaySelection.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
check(recoveredSelections.count == 2 && recoveredSelections.allSatisfy { $0.displayID == 11 && $0.inventoryID == inventory && $0.selectionRevision == "r0" && $0.origin == .automatic },
      "재개는 원래 모니터와 inventory와 CAS와 자동 의도를 유지한다")

for invalidAdmission: [String: Any]? in [nil, admission(1, ready: false),
    ["schemaVersion": 2, "generation": 1, "ready": true], admission(0), admission(9_007_199_254_740_992),
    ["schemaVersion": 1, "generation": true, "ready": true],
    ["schemaVersion": 1, "generation": 1.5, "ready": true],
    ["schemaVersion": 1, "generation": 1, "ready": 1],
    ["schemaVersion": 1, "generation": "1", "ready": true]] {
    if let catalog = admissionCatalog(automaticCatalog(), invalidAdmission) {
        let (client, peer) = automaticClient(catalog)
        check(client.releaseCallbacks.isEmpty && peer.sent.isEmpty, "미확인·잘못된 선택 허가로 자동 효과를 만들지 않는다")
    } else { check(true, "잘못된 선택 허가는 원본 DTO에서 거부한다") }
}
let (backwardSelection, backwardPeer) = automaticClient(admissionCatalog(automaticCatalog(), admission(5, ready: false))!)
backwardSelection.observeVisionDisplays(admissionCatalog(automaticCatalog(), admission(4))!, from: backwardPeer)
check(backwardSelection.releaseCallbacks.isEmpty, "역행한 허용 세대로 자동 선택을 만들지 않는다")
backwardSelection.observeVisionDisplays(admissionCatalog(automaticCatalog(), admission(5))!, from: backwardPeer)
check(backwardSelection.releaseCallbacks.isEmpty, "같은 세대의 상충한 ready 값은 허가로 사용하지 않는다")
backwardSelection.observeVisionDisplays(admissionCatalog(automaticCatalog(), admission(6))!, from: backwardPeer)
check(backwardSelection.releaseCallbacks.count == 1, "상충 뒤의 새 정상 세대에서만 자동 선택을 진행한다")

let (manualStop, manualStopPeer) = automaticClient()
manualStop.releaseCallbacks[0](true); drain()
manualStop.automatic(.none)
manualStop.observeVisionDisplays(admissionCatalog(automaticCatalog(), admission(3))!, from: manualStopPeer)
check(manualStop.releaseCallbacks.count == 1, "사람이 화면 없음을 고르면 새 허용 세대가 자동 의도를 되살리지 않는다")
let (changedCAS, changedCASPeer) = automaticClient()
changedCAS.releaseCallbacks[0](true); drain()
changedCAS.observeVisionDisplays(admissionCatalog(automaticCatalog(revision: "r1"), admission(3))!, from: changedCASPeer)
check(changedCAS.releaseCallbacks.count == 1, "다른 선택 CAS에서는 새 허용 세대로 재기준화하지 않는다")

print("RESULT_ASSERTIONS \(assertions)")
exit(failures == 0 ? 0 : 1)
