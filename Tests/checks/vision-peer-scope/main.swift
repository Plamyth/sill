import Foundation
import Network
import StreamProtocol

var count = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    count += 1
    guard value() else { print("FAIL \(name)"); exit(1) }
}
func epoch(_ source: StreamSource = .window(8)) -> VideoEpoch {
    VideoEpoch(generation: UUID().uuidString, source: source, geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 1600, height: 1200)
}
func catalog(_ epoch: VideoEpoch?) -> WindowList {
    var list = WindowList(macName: "격리 Mac", windows: [], active: epoch?.source ?? .none,
                          inputGeneration: epoch?.generation, presentationInput: 1, videoEpoch: epoch)
    list.independentStreams = 1; list.sourceSelectionEffects = 0
    return list
}
func top(_ epoch: VideoEpoch?, version: Int = 2) -> MacMenu {
    MacMenu(version: version, app: "격리 앱", menus: [MacMenuItem(id: "1", title: "파일", submenu: true)],
            generation: epoch?.generation, videoEpoch: epoch?.id)
}
func frames(_ peer: NWConnection, kind: StreamMessageKind) -> [Data] {
    peer.sent.filter { StreamMessage.parseHeader($0)?.kind == kind }.map { Data($0.dropFirst(StreamMessage.headerLength)) }
}
func present(_ client: StreamClient, _ epoch: VideoEpoch, list: WindowList? = nil) {
    client.active = epoch.source
    client.visionPeerStreams.observe(list ?? catalog(epoch))
    client.visionInputBinding = .presented(epoch)
    client.link.observeInputEpoch(epoch.id, modern: true)
    let permit = UUID()
    check(client.link.setInputPermit(permit, epoch: epoch.id), "presentation permit admitted")
    client.visionInputPermit = permit
    client.reconcileVisionPeerMenus()
    client.queue.sync {}
}

let a = epoch(), b = epoch(.window(9))
if CommandLine.arguments.contains("--no-op-only") {
    let noOp = StreamClient(); noOp.connection = NWConnection()
    present(noOp, a)
    let before = noOp.visionInputPermit
    noOp.prepareVisionPeerSourceChange(.source(a.source))
    noOp.visionPeerStreams.observe(catalog(a))
    check(noOp.visionInputBinding == .presented(a) && noOp.visionInputPermit == before && noOp.visionPeerStreams.epoch == a,
          "reselecting the displayed window is a safe no-op without revision or epoch changes")
    print("PASS no-op production state probe"); exit(0)
}
let unchanged = StreamClient(); unchanged.connection = NWConnection()
var shownApp = catalog(a)
shownApp.selectionRevision = "unchanged"
shownApp.windows = [.init(id: 8, title: "현재 창", appName: "현재 앱", bundleID: "test.current", width: 800, height: 600)]
present(unchanged, a, list: shownApp)
let samePermit = unchanged.visionInputPermit
unchanged.request(a.source)
unchanged.visionPeerStreams.observe(shownApp)
check(unchanged.visionInputBinding == .presented(a) && unchanged.visionInputPermit == samePermit && unchanged.visionPeerStreams.epoch == a,
      "same-window catalog with unchanged revision and epoch preserves displayed admission")
unchanged.launch(bundleID: "test.current")
unchanged.visionPeerStreams.observe(shownApp)
check(unchanged.visionInputBinding == .presented(a) && unchanged.visionInputPermit == samePermit && unchanged.visionPeerStreams.epoch == a,
      "launch selecting the already displayed app window needs no invented acknowledgement")
check(unchanged.visionAudio.stops == 0 && unchanged.microphoneStops == 0, "same-source request preserves existing audio and microphone intent")
unchanged.prepareVisionPeerSourceChange(.source(b.source))
unchanged.prepareVisionPeerSourceChange(.source(a.source))
unchanged.visionPeerStreams.observe(shownApp)
check(unchanged.visionInputBinding == .awaitingPresentation(nil) && unchanged.visionPeerStreams.epoch == nil,
      "returning to the original target while another choice is pending still requires its acknowledgement")
unchanged.resetVisionPeerStreams()
check(Wire.decode(SourceRequest.self, from: frames(unchanged.connection!, kind: .selectSource).last!)?.source == a.source,
      "same-window no-op still sends the explicit source request")
check(Wire.decode(LaunchApp.self, from: frames(unchanged.connection!, kind: .launchApp).last!)?.bundleID == "test.current",
      "current-app no-op still sends the explicit launch request")
let desktopEpoch = epoch(.desktop)
var shownDisplay = catalog(desktopEpoch); shownDisplay.activeDisplayID = 11; shownDisplay.selectionRevision = "display-unchanged"
present(unchanged, desktopEpoch, list: shownDisplay)
let displayPermit = unchanged.visionInputPermit
unchanged.prepareVisionPeerSourceChange(.display(11))
unchanged.visionPeerStreams.observe(shownDisplay)
check(unchanged.visionInputBinding == .presented(desktopEpoch) && unchanged.visionInputPermit == displayPermit && unchanged.visionPeerStreams.epoch == desktopEpoch,
      "same-display catalog with unchanged revision and epoch preserves displayed admission")
unchanged.prepareVisionPeerSourceChange(.display(12))
unchanged.visionPeerStreams.observe(shownDisplay)
check(unchanged.visionPeerStreams.epoch == nil, "a different display cannot be acknowledged by the old display catalog")

var displayModel = VisionDisplaySelection()
displayModel.bind(peerEpoch: UUID())
displayModel.admit(lease: VisionWindowLease(window: UUID()), foreground: true)
shownDisplay.displaySelection = 1; shownDisplay.displayInventoryID = UUID()
shownDisplay.displays = [.init(id: 11, name: "현재 모니터", width: 1600, height: 1200, isMain: true),
                         .init(id: 12, name: "다른 모니터", width: 1600, height: 1200, isMain: false)]
displayModel.observe(.init(shownDisplay))
let sameDisplayCommand = VisionDisplaySelection.Command(requestID: UUID(), displayID: 11, token: displayModel.token!)
check(displayModel.begin(sameDisplayCommand, presented: desktopEpoch).code == .unchanged && displayModel.pending == nil && !displayModel.inputBlocked,
      "production display model creates no pending or input suspension for the already presented monitor")
check(displayModel.begin(sameDisplayCommand, presented: desktopEpoch).code == .unchanged,
      "same-display no-op request ID stays idempotent")
let nextDisplayCommand = VisionDisplaySelection.Command(requestID: UUID(), displayID: 12, token: displayModel.token!)
check(displayModel.begin(nextDisplayCommand, presented: desktopEpoch).code == .releasing && displayModel.inputBlocked,
      "another monitor still requires the existing input release and presentation transition")

var policy = VisionPeerStreams()
policy.observe(catalog(a))
check(policy.presentedEpoch(.awaitingPresentation(a)) == nil, "catalog alone never authorizes commands")
check(policy.presentedEpoch(.presented(a)) == a, "presented exact epoch authorizes commands")
check(policy.presentedEpoch(.presented(b)) == nil, "another displayed epoch cannot authorize this catalog")
var invalid = catalog(a); invalid.sourceSelectionEffects = nil
policy.observe(invalid)
check(policy.presentedEpoch(.presented(a)) == nil && policy.inputCatalog(invalid).videoEpoch == nil, "partial capability blocks input without legacy fallback")
policy.observe(WindowList(macName: "이전", windows: [], active: .none))
check(policy.requiresScope && policy.failure != nil, "capability removal stays blocked on the same connection")
invalid = catalog(a); invalid.sourceSelectionFailure = "선택한 화면을 찾을 수 없습니다."
policy.observe(invalid)
check(policy.failure == invalid.sourceSelectionFailure && policy.epoch == nil, "selection failure is consumed and blocks commands")

policy.observe(catalog(a))
policy.selectionRequested(.source(a.source))
policy.observe(catalog(a))
check(policy.presentedEpoch(.presented(a)) == nil, "same in-flight catalog cannot undo a human source request")
var acknowledged = catalog(a); acknowledged.selectionRevision = "new-human-choice"
policy.observe(acknowledged)
check(policy.presentedEpoch(.presented(a)) == a, "same-source choice can converge after explicit selection acknowledgement")

policy.selectionRequested(.source(a.source))
policy.selectionRequested(.source(b.source))
policy.observe(acknowledged)
check(policy.epoch == nil, "late first choice cannot undo the latest human target")
var selectedB = catalog(b); selectedB.selectionRevision = "newer-human-choice"
policy.observe(selectedB)
check(policy.presentedEpoch(.presented(b)) == b, "latest human target converges after its own catalog")
policy.selectionRequested(.launch("test.late.app"))
var noWindow = catalog(nil); noWindow.selectionRevision = "launch-pending"
policy.observe(noWindow)
check(policy.epoch == nil, "launch with no first window keeps command admission closed")
var wrongApp = catalog(a); wrongApp.selectionRevision = "launch-pending"
wrongApp.windows = [.init(id: 8, title: "이전 창", appName: "이전 앱", bundleID: "test.other", width: 800, height: 600)]
policy.observe(wrongApp)
check(policy.epoch == nil, "an unrelated app cannot satisfy a pending launch")
wrongApp.windows[0].bundleID = "test.late.app"
policy.observe(wrongApp)
check(policy.presentedEpoch(.presented(a)) == a, "late first window consumes the original app launch intent")

let blockedMenu = StreamClient(), blockedPeer = NWConnection()
blockedMenu.connection = blockedPeer
blockedMenu.visionDisplaySelection.inputBlocked = true
present(blockedMenu, a)
check(frames(blockedPeer, kind: .fetchMenu).isEmpty, "modal admission blocks subscription sends")
blockedMenu.visionDisplaySelection.inputBlocked = false
blockedMenu.reconcileVisionPeerMenus()
check(frames(blockedPeer, kind: .fetchMenu).count == 1,
      "a refused subscription is retried after modal admission recovers on the same permit")

let client = StreamClient(), peer = NWConnection()
client.connection = peer
present(client, a)
client.receiveMenus(top(a))
let row = client.menus.menus[0]
check(row.scope?.generation == a.generation && row.scope?.videoEpoch == a.id, "top row retains the wire response scope")
MacMenuElements.deferred(for: row, topLevelVersion: row.version, client: client).open()
client.queue.sync {}
let fetch = Wire.decode(FetchMenu.self, from: frames(peer, kind: .fetchMenu).last!)!
check(fetch.id == row.id, "actual top menu provider fetches its original scoped row")
check(fetch.generation == a.generation && fetch.videoEpoch == a.id, "fetch uses the row's original generation and epoch")
let items = [MacMenuItem(id: "1.1", title: "저장")]
client.receiveMenus(MacMenu(version: 2, answering: fetch.token, menu: "1", items: items,
                            generation: b.generation, videoEpoch: b.id))
check(!client.menus.waitingKeys.isEmpty, "wrong-scope submenu cannot settle a pending request")
client.receiveMenus(MacMenu(version: 2, answering: fetch.token, menu: "1", items: items, generation: a.generation))
check(!client.menus.waitingKeys.isEmpty, "half-scope submenu is rejected")
client.receiveMenus(MacMenu(version: 2, answering: fetch.token, menu: "1", items: items,
                            generation: a.generation, videoEpoch: a.id))
let content = client.finished.last!.content
guard case .sections(let sections, _) = content else { fatalError("submenu missing") }
let item = sections.flatMap { $0 }.first!
check(item.scope == row.scope, "submenu row retains the response scope")
client.pressMenuItem(item); client.command(.minimize, window: 8)
check(client.sendGesture(.swipeUp, fingers: 3), "presented gesture queued")
client.queue.sync {}
let press = Wire.decode(PressMenuItem.self, from: frames(peer, kind: .pressMenuItem).last!)!
let command = Wire.decode(WindowCommand.self, from: frames(peer, kind: .windowCommand).last!)!
let gesture = Wire.decode(TrackpadGesture.self, from: frames(peer, kind: .gesture).last!)!
check(press.generation == a.generation && press.videoEpoch == a.id, "press preserves original row scope")
check(command.generation == a.generation && command.videoEpoch == a.id, "window command captures displayed scope")
check(gesture.generation == a.generation && gesture.videoEpoch == a.id && client.selected.isEmpty, "independent gesture never selects a different source first")
let commandCount = frames(peer, kind: .windowCommand).count
client.command(.close, window: 9); client.queue.sync {}
check(frames(peer, kind: .windowCommand).count == commandCount, "window command cannot target an unpresented window")
present(client, b)
client.receiveMenus(top(a, version: 99))
check(client.menus.menus.isEmpty, "late old top cannot overwrite the new scope")
client.receiveMenus(top(b))
let pressCount = frames(peer, kind: .pressMenuItem).count
client.pressMenuItem(item); client.queue.sync {}
check(frames(peer, kind: .pressMenuItem).count == pressCount, "old row is not repackaged under the current catalog")
var staleFetch: MacMenuState.Content?
client.fetchMenu(row) { staleFetch = $0 }
check(staleFetch == .message(MacMenuState.scopeChangedNote), "old top row fetch is rejected locally")
let before = client.menus.top
var half = top(b); half.videoEpoch = nil
client.receiveMenus(half)
check(client.menus.top == before, "half-scope top is rejected")
client.receiveMenus(top(b, version: 1))
check(client.menus.top == before, "older menu version cannot replace the current tree")

client.visionPeerStreams.observe(catalog(nil)); client.visionInputBinding = .awaitingPresentation(nil)
client.link.setInputPermit(nil); client.visionInputPermit = nil
client.reconcileVisionPeerMenus(); client.receiveMenus(top(nil))
check(client.menus.menus.count == 1 && !client.menus.menus[0].enabled, "source.none accepts unscoped top as read-only")
client.fetchMenu(client.menus.menus[0]) { staleFetch = $0 }
check(staleFetch == .message(MacMenuState.scopeChangedNote), "read-only top cannot fetch an actionable submenu")
check(!client.sendGesture(.swipeUp, fingers: 3), "source.none cannot send gestures")

present(client, a)
let oldScope = MacMenuState.Scope(generation: a.generation, videoEpoch: a.id, connection: client.visionPeerStreams.connection)!
client.resetVisionPeerStreams(); present(client, a)
check(!client.sendVisionPeerCommand(.windowCommand, WindowCommand(id: 8, action: .close), scope: oldScope), "old connection scope is rejected even if host epoch repeats")
_ = client.link.hold(peer)
client.command(.close, window: 8); client.queue.sync {}
let heldCount = frames(peer, kind: .windowCommand).count
client.link.setInputPermit(nil)
_ = client.link.unhold(peer)
check(frames(peer, kind: .windowCommand).count == heldCount, "queued command cannot outlive its presentation permit")

present(client, a)
let subscription = Wire.decode(FetchMenu.self, from: frames(peer, kind: .fetchMenu).last!)!
client.receiveMenus(top(a))
let currentRow = client.menus.menus[0]
client.visionTextForeground = false
var rejected: MacMenuState.Content?
client.fetchMenu(currentRow) { rejected = $0 }
check(rejected == .message(MacMenuState.scopeChangedNote) && client.menus.waitingKeys.isEmpty,
      "pre-presentation or foreground send refusal settles only the rejected fetch")
client.visionTextForeground = true
var subscriptionReply = top(a, version: 3); subscriptionReply.answering = subscription.token
client.receiveMenus(subscriptionReply)
check(client.menus.version == 3, "declined fetch preserves the top subscription token")
var recovered: MacMenuState.Content?
client.fetchMenu(client.menus.menus[0]) { recovered = $0 }
client.queue.sync {}
let retry = Wire.decode(FetchMenu.self, from: frames(peer, kind: .fetchMenu).last!)!
client.receiveMenus(MacMenu(version: 3, answering: retry.token, menu: "1", items: items,
                            generation: a.generation, videoEpoch: a.id))
check(recovered != nil, "a fresh row can fetch after presentation admission recovers")

_ = client.link.hold(peer)
client.command(.close, window: 8)
let cancelledCount = frames(peer, kind: .windowCommand).count
let revokedPermit = client.visionInputPermit!
client.cancelVisionInputs()
check(client.visionInputPermit == nil && client.visionInputBinding == .awaitingPresentation(a),
      "cancel revokes the permit synchronously before waiting for the network queue")
_ = client.link.setInputPermit(revokedPermit, epoch: a.id)
_ = client.link.unhold(peer)
check(frames(peer, kind: .windowCommand).count == cancelledCount,
      "cancelled submission cannot resurrect if the same renderer ticket is re-admitted")
client.queue.sync {}
client.link.setInputPermit(nil)
let layer = NSObject()
let ticket = VisionPresentation.Ticket(epoch: a, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(layer))
client.visionPresentationChanged(ticket)
let resumedPermit = client.visionInputPermit
check(resumedPermit != nil && resumedPermit != revokedPermit && client.visionInputBinding == .presented(a),
      "the next actual presentation callback grants a fresh permit after cancellation")
client.cancelVisionInputs(); client.queue.sync {}
client.visionPresentationChanged(ticket)
check(client.visionInputPermit != nil && client.visionInputPermit != resumedPermit,
      "reusing an admitted renderer ticket cannot reuse a revoked transport permit")
present(client, a)
client.prepareVisionPeerSourceChange(.source(b.source))
check(client.visionInputBinding == .awaitingPresentation(nil) && client.menus.menus.isEmpty,
      "human source request immediately closes old display and menu admission")
check(!client.sendGesture(.swipeUp, fingers: 3), "source request blocks gestures before the next catalog")

let legacy = StreamClient(), legacyPeer = NWConnection()
legacy.connection = legacyPeer; legacy.active = .window(8)
legacy.visionPeerStreams.observe(WindowList(macName: "146", windows: [], active: .window(8)))
legacy.command(.close, window: 9)
check(legacy.sendGesture(.swipeUp, fingers: 3), "legacy gesture behavior remains available")
legacy.queue.sync {}
check(Wire.decode(WindowCommand.self, from: frames(legacyPeer, kind: .windowCommand).last!)?.generation == nil, "host146 command wire remains unchanged")
check(legacy.selected == [.desktop], "legacy desktop-first gesture behavior is preserved")
legacy.receiveMenus(MacMenu(version: 2, menus: [MacMenuItem(id: "1", title: "파일", submenu: true)]))
let oldLegacyRow = legacy.menus.menus[0]
let beforeOldScope = frames(legacyPeer, kind: .fetchMenu).count
MacMenuElements.deferred(for: row, topLevelVersion: row.version, client: legacy).open()
check(frames(legacyPeer, kind: .fetchMenu).count == beforeOldScope,
      "a scoped row from a previous connection cannot be downgraded into a legacy fetch")
let beforeOldPress = frames(legacyPeer, kind: .pressMenuItem).count
legacy.pressMenuItem(item)
check(frames(legacyPeer, kind: .pressMenuItem).count == beforeOldPress,
      "a scoped item from a previous connection cannot become a legacy press")
legacy.receiveMenus(MacMenu(version: 3, menus: [MacMenuItem(id: "2", title: "파일", submenu: true)]))
MacMenuElements.deferred(for: oldLegacyRow, topLevelVersion: 2, client: legacy).open()
legacy.queue.sync {}
check(Wire.decode(FetchMenu.self, from: frames(legacyPeer, kind: .fetchMenu).last!)?.id == "2",
      "legacy deferred top provider retains the existing title-based rebuild behavior")
print("PASS \(count) production Vision peer scope checks")
