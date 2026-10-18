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
check(decoded == DisplaySelection(displayID: 22, inventoryID: inventory), "wire uses explicit desired display and exact inventory")
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

print("RESULT_ASSERTIONS \(assertions)")
exit(failures == 0 ? 0 : 1)
