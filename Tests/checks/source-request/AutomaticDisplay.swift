import Foundation

@MainActor func sourceSelectionAdmissionChecks(_ expect: (Bool, String) -> Void) {
    let main = DisplayInfo(id: 14, name: "fixture-main", width: 1920, height: 1080, isMain: true)
    let inventory = UUID()
    var idle = WindowList(macName: "fixture", windows: [], active: .none, launchID: "host",
        selectionRevision: "revision-0", automaticDisplaySelection: 1,
        displaySelection: 1, displays: [main], displayInventoryID: inventory, desktopSelectionRequired: true)
    func catalog(_ generation: Any, ready: Bool, version: Int = 1) -> WindowList? {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(idle)) as! [String: Any]
        object["sourceSelectionAdmission"] = ["schemaVersion": version, "generation": generation, "ready": ready]
        return try? JSONDecoder().decode(WindowList.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func fresh() -> Client { let client = Client(); client.active = .none; return client }
    func picks(_ client: Client) -> [DisplaySelection] {
        client.allSent.filter { $0.0 == .selectDisplay }.compactMap { Wire.decode(DisplaySelection.self, from: $0.1) }
    }
    let legacy = fresh()
    legacy.deliverIdleCatalog(idle)
    legacy.deliverIdleCatalog(idle)
    expect(legacy.allSent.isEmpty && legacy.remoteAudioControl.changes == 0,
           "최초 catalog에 admission이 없는 구형 Host에는 자동 화면 선택을 보내지 않음")
    legacy.selectDisplay(main)
    expect(picks(legacy).count == 1 && picks(legacy).first?.origin == nil,
           "admission 없는 Host에도 명시적인 수동 화면 선택은 기존 wire로 유지")
    let blocked = catalog(1, ready: false)!, ready = catalog(2, ready: true)!
    let waiting = fresh()
    waiting.deliverIdleCatalog(blocked)
    waiting.deliverIdleCatalog(blocked)
    expect(picks(waiting).isEmpty && waiting.remoteAudioControl.changes == 0,
           "보호 준비 중에는 화면 선택과 오디오 해제를 보내지 않고 최초 기회를 보존")
    waiting.deliverIdleCatalog(ready)
    waiting.deliverIdleCatalog(ready)
    expect(picks(waiting).count == 1, "같은 inventory의 새 허용 세대에서 최초 선택 한 번, 반복 catalog는 중복 없음")
    waiting.deliverIdleCatalog(catalog(4, ready: true)!)
    waiting.deliverIdleCatalog(catalog(4, ready: true)!)
    expect(picks(waiting).count == 2, "중간 false가 생략돼도 새 ready 세대에서 미확인 선택만 한 번 재개")
    expect(picks(waiting).allSatisfy { $0.selectionRevision == "revision-0" && $0.inventoryID == inventory },
           "복구는 원래 CAS와 inventory를 보존")
    waiting.deliverIdleCatalog(ready)
    expect(picks(waiting).count == 2, "오래된 ready 세대는 재제출하지 않음")
    waiting.deliverIdleCatalog(catalog(5, ready: false)!)
    waiting.deliverIdleCatalog(idle)
    expect(picks(waiting).count == 2, "현대 admission 관측 뒤 false와 필드 누락은 legacy로 격하해 제출하지 않음")
    waiting.deliverIdleCatalog(catalog(6, ready: true)!)
    expect(picks(waiting).count == 3, "차단 이후 더 새로운 허용 세대가 원래 선택 기회를 복구")
    for change in ["none", "window", "display", "launch", "revision", "peer", "host", "mac"] {
        let client = fresh()
        client.deliverIdleCatalog(blocked)
        var next = ready
        switch change {
        case "none": client.select(.none)
        case "window": client.select(.window(99))
        case "display": client.selectDisplay(main)
        case "launch": client.launch(bundleID: "fixture.manual")
        case "revision": next.selectionRevision = "another-choice"
        case "peer": client.connection = NWConnection()
        case "host": next.launchID = "another-host"
        default: client.session?.macID = "another-mac"
        }
        let count = client.allSent.count
        client.deliverIdleCatalog(next)
        client.deliverIdleCatalog(ready)
        expect(client.allSent.count == count, "새 허용 세대가 \(change)로 취소된 자동 선택을 되살리지 않음")
    }
    let foreign = fresh()
    foreign.deliverIdleCatalog(blocked)
    foreign.deliverIdleCatalog(ready, from: NWConnection())
    expect(picks(foreign).isEmpty, "다른 peer의 ready catalog는 현재 선택을 재개하지 않음")
    let invalidValues: [Any] = [0, -1, 9_007_199_254_740_992 as UInt64, 1.5, true, "2"]
    for invalid in invalidValues {
        expect(catalog(invalid, ready: true) == nil, "잘못된 admission 세대는 catalog 디코딩에서 거절: \(invalid)")
    }
    if let unknown = catalog(7, ready: true, version: 2) {
        let client = fresh(); client.deliverIdleCatalog(unknown)
        expect(picks(client).isEmpty, "미지원 admission schema는 자동 선택을 허용하지 않음")
    }
    let maximum = fresh()
    maximum.deliverIdleCatalog(catalog(9_007_199_254_740_991 as UInt64, ready: true)!)
    maximum.deliverIdleCatalog(catalog(9_007_199_254_740_991 as UInt64, ready: true)!)
    expect(picks(maximum).count == 1, "53bit 최대 세대도 정확히 한 번 제출")
    let contradictory = fresh()
    contradictory.deliverIdleCatalog(blocked)
    contradictory.deliverIdleCatalog(catalog(1, ready: true)!)
    expect(picks(contradictory).isEmpty, "같은 세대의 false→true 모순은 허용 전이로 취급하지 않음")
    contradictory.deliverIdleCatalog(ready)
    expect(picks(contradictory).count == 1, "모순 이후 올바른 새 세대에서만 최초 선택")
    let resuming = fresh()
    resuming.beginAutomaticConnectionOpportunity(peer: resuming.connection)
    resuming.resumeSource = .window(1001)
    idle.windows = [WindowInfo(id: 1001, title: "fixture", appName: "fixture", bundleID: "fixture", width: 800, height: 600)]
    resuming.deliverIdleCatalog(catalog(1, ready: false)!)
    expect(resuming.allSent.isEmpty, "보호 중에는 자동 창 복구 selectSource도 전송하지 않음")
    resuming.deliverIdleCatalog(catalog(2, ready: true)!)
    resuming.deliverIdleCatalog(catalog(2, ready: true)!)
    let firstWindowRequests = resuming.allSent.compactMap { Wire.decode(SourceRequest.self, from: $0.1) }
    expect(firstWindowRequests.count == 1 && firstWindowRequests.first?.source == .window(1001) && picks(resuming).isEmpty,
           "허용되면 원래 창 선택을 한 번 복구하고 desktop으로 바꾸지 않음")
    resuming.deliverIdleCatalog(catalog(4, ready: true)!)
    let retriedWindows = resuming.allSent.compactMap { Wire.decode(SourceRequest.self, from: $0.1) }
    expect(retriedWindows.count == 2 && retriedWindows.allSatisfy { $0.source == .window(1001) && $0.selectionRevision == "revision-0" },
           "중간 차단을 놓친 새 허용 세대에서도 자동 창 선택과 원래 CAS만 재개")
    let queued = fresh()
    let queuedPeer = queued.connection!
    _ = queued.link.hold(queuedPeer)
    queued.deliverIdleCatalog(catalog(2, ready: true)!)
    queued.deliverIdleCatalog(catalog(3, ready: false)!)
    _ = queued.link.unhold(queuedPeer)
    expect(picks(queued).isEmpty, "보호 취소가 실제 SessionLink에 보류된 옛 자동 제출도 폐기")
    queued.deliverIdleCatalog(catalog(4, ready: true)!)
    expect(picks(queued).count == 1, "보류 제출 취소 뒤 새 허용 세대에서 현재 티켓만 제출")
    idle.selectionRevision = "revision-new"
    waiting.deliverIdleCatalog(catalog(8, ready: true)!)
    idle.selectionRevision = "revision-0"
    waiting.deliverIdleCatalog(catalog(9, ready: true)!)
    expect(picks(waiting).count == 3, "다른 CAS를 관측한 뒤 옛 CAS replay와 새 admission으로 재개하지 않음")
}

@MainActor func automaticDisplayChecks(_ expect: (Bool, String) -> Void) async {
    let main = DisplayInfo(id: 14, name: "fixture-main", width: 1920, height: 1080, isMain: true)
    let secondary = DisplayInfo(id: 13, name: "fixture-secondary", width: 1200, height: 800, isMain: false)
    let inventory = UUID()
    var idle = WindowList(macName: "fixture", windows: [], active: .none, launchID: "host",
        selectionRevision: "revision-0", displaySelection: 1, displays: [main, secondary],
        displayInventoryID: inventory, desktopSelectionRequired: true)
    idle.automaticDisplaySelection = 1
    func fresh(_ defaults: TestDefaults? = nil) -> Client {
        let client = Client()
        client.active = .none
        if let defaults { client.defaults = defaults }
        return client
    }
    func picks(_ client: Client) -> [DisplaySelection] {
        client.allSent.filter { $0.0 == .selectDisplay }.compactMap { Wire.decode(DisplaySelection.self, from: $0.1) }
    }
    func seed(_ client: Client, mac: String = "trusted-mac", launch: String = "host", inventoryID: UUID? = nil, id: UInt32 = 13) {
        let saved = Client.RememberedDisplay(macID: mac, launchID: launch, inventoryID: inventoryID ?? inventory, displayID: id)
        client.defaults.set(try! JSONEncoder().encode(saved), forKey: "SillVerifiedDisplay.trusted-mac")
    }
    let initial = fresh()
    initial.deliverIdleCatalog(idle)
    expect(picks(initial).count == 1 && picks(initial).first?.displayID == main.id, "first idle catalog automatically selects the unique main display")
    expect(picks(initial).first?.origin == .automatic && picks(initial).first?.selectionRevision == idle.selectionRevision &&
           picks(initial).first?.inventoryID == inventory, "automatic display request carries exact origin, revision and inventory")
    expect(initial.actions == 0 && initial.explicitSourceIntent == 0, "automatic selection is not a human action or intent")
    expect(initial.defaults.values.isEmpty, "sending a display request never persists an unconfirmed display")
    initial.deliverIdleCatalog(idle)
    expect(picks(initial).count == 1, "repeated idle catalog never retries automatic display selection")
    var confirmed = idle
    confirmed.active = .desktop
    confirmed.activeDisplayID = main.id
    confirmed.selectionRevision = "revision-1"
    confirmed.inputGeneration = "input-1"
    initial.deliverIdleCatalog(confirmed)
    expect(initial.defaults.values.isEmpty, "new revision and active desktop without a video epoch do not persist")
    confirmed.videoEpoch = VideoEpoch(generation: "input-1", source: .desktop,
        geometry: .init(x: 0, y: 0, width: 1920, height: 1080), width: 1920, height: 1080)
    initial.deliverIdleCatalog(confirmed)
    expect(initial.defaults.values.count == 1, "actual desktop with a new valid video epoch confirms persistence")
    let stored = initial.defaults.data(forKey: "SillVerifiedDisplay.trusted-mac")
        .flatMap { try? JSONDecoder().decode(Client.RememberedDisplay.self, from: $0) }
    expect(stored?.macID == "trusted-mac" && stored?.launchID == "host" && stored?.inventoryID == inventory && stored?.displayID == main.id,
           "persisted display is bound to authenticated Mac, launch and inventory")
    initial.connection = NWConnection()
    initial.beginAutomaticConnectionOpportunity(peer: initial.connection)
    initial.deliverIdleCatalog(idle)
    expect(picks(initial).count == 1 && picks(initial).first?.displayID == main.id,
           "same client reconnects with its confirmed display and a new peer ticket")
    for acknowledgment in ["없음", "revision만"] {
        let interrupted = fresh()
        interrupted.deliverIdleCatalog(idle)
        if acknowledgment == "revision만" {
            var withoutEpoch = confirmed
            withoutEpoch.videoEpoch = nil
            interrupted.deliverIdleCatalog(withoutEpoch)
        }
        expect(interrupted.defaults.values.isEmpty, "미확인 자동 요청을 저장하지 않음")
        interrupted.connection = NWConnection()
        interrupted.beginAutomaticConnectionOpportunity(peer: interrupted.connection)
        interrupted.deliverIdleCatalog(idle)
        expect(picks(interrupted).count == 1, "ACK 이전 자동 display 요청도 새 연결에서 재개 acknowledgment=\(acknowledgment) actual=\(picks(interrupted).count)")
    }
    for choice in ["source", "none", "display", "launch"] {
        let interrupted = fresh()
        interrupted.deliverIdleCatalog(idle)
        switch choice {
        case "source": interrupted.select(.window(42))
        case "none": interrupted.select(.none)
        case "display": interrupted.selectDisplay(main)
        default: interrupted.launch(bundleID: "fixture.manual")
        }
        interrupted.connection = NWConnection()
        interrupted.beginAutomaticConnectionOpportunity(peer: interrupted.connection)
        interrupted.deliverIdleCatalog(idle)
        expect(interrupted.allSent.isEmpty, "새 수동 선택은 자동 display 복구로 덮지 않음 choice=\(choice)")
    }
    let sourceInterrupted = fresh()
    let sourceTicket = sourceInterrupted.automaticTicket(peer: sourceInterrupted.connection!, list: idle)!
    sourceInterrupted.requestAutomatic(.window(1001), ticket: sourceTicket)
    sourceInterrupted.connection = NWConnection()
    sourceInterrupted.beginAutomaticConnectionOpportunity(peer: sourceInterrupted.connection)
    sourceInterrupted.resumeSource = .window(1001)
    var sourceIdle = idle
    sourceIdle.windows = [WindowInfo(id: 1001, title: "fixture", appName: "fixture", bundleID: "fixture", width: 800, height: 600)]
    sourceInterrupted.deliverIdleCatalog(sourceIdle)
    expect(sourceInterrupted.allSent.contains { $0.0 == .selectSource }, "ACK 이전 자동 source 요청도 새 연결에서 재개 actual=\(sourceInterrupted.allSent.count)")
    let topology = fresh()
    let nextInventory = UUID(), finalInventory = UUID()
    let trace: [UUID?] = [inventory, nil, nextInventory, nil, finalInventory]
    var topologyLists: [WindowList] = []
    for identity in trace {
        var list = idle
        list.displayInventoryID = identity
        if identity == finalInventory {
            list.displays = [main, secondary, DisplayInfo(id: 15, name: "fixture-extended", width: 2700, height: 1952, isMain: false)]
        }
        topologyLists.append(list)
        topology.deliverIdleCatalog(list)
    }
    let submitted = picks(topology)
    print("COUNTEREXAMPLE initial-inventory-continuation submitted=\(submitted.count) expected=3 activeNone=\(topology.active == .none) confirmed=\(topology.defaults.values.count)")
    expect(submitted.map(\.inventoryID) == [inventory, nextInventory, finalInventory],
           "동일 r0의 초기 inventory trace는 현재 유효 UUID마다 한 번 계속 제출 actual=\(submitted.count)")
    expect(submitted.allSatisfy { $0.origin == .automatic && $0.selectionRevision == idle.selectionRevision },
           "inventory continuation은 원본 r0와 automatic origin을 유지")
    expect(!topology.automaticDisplayCatalogObserved && topology.defaults.values.isEmpty,
           "로컬 전송 접수는 최초 기회의 수렴 또는 화면 확인이 아님")
    topology.deliverIdleCatalog(topologyLists.last!)
    expect(picks(topology).count == 3, "같은 inventory catalog 반복은 자동 요청을 추가하지 않음")
    var accepted = topologyLists.last!
    accepted.selectionRevision = "revision-1"
    topology.deliverIdleCatalog(accepted)
    topology.deliverIdleCatalog(accepted)
    expect(picks(topology).count == 3 && topology.automaticDisplayCatalogObserved,
           "수용된 r1의 active.none은 새 자동 요청을 만들지 않음")
    accepted.active = .desktop; accepted.activeDisplayID = main.id
    topology.deliverIdleCatalog(accepted)
    expect(topology.defaults.values.isEmpty, "r1과 active display만으로 epoch 확인을 대체하지 않음")
    accepted.inputGeneration = "input-final"
    accepted.videoEpoch = VideoEpoch(generation: "input-final", source: .desktop,
        geometry: .init(x: 0, y: 0, width: 1920, height: 1080), width: 1920, height: 1080)
    topology.deliverIdleCatalog(accepted)
    expect(topology.defaults.values.count == 1, "최종 inventory와 새 epoch가 일치할 때만 화면을 저장")
    topology.deliverIdleCatalog(idle)
    expect(picks(topology).count == 3, "r1 관측 뒤 옛 r0 catalog로 돌아가도 최초 기회를 열지 않음")
    let untrustedContinuation = fresh()
    untrustedContinuation.deliverIdleCatalog(idle)
    untrustedContinuation.savedMacs = []
    var untrustedInventory = idle
    untrustedInventory.displayInventoryID = nextInventory
    let audioBeforeUntrusted = untrustedContinuation.remoteAudioControl.changes
    untrustedContinuation.deliverIdleCatalog(untrustedInventory)
    expect(picks(untrustedContinuation).count == 1 && untrustedContinuation.automaticSourceIntent == nil &&
           untrustedContinuation.remoteAudioControl.changes == audioBeforeUntrusted,
           "continuation 중 신뢰가 없으면 자동 의도와 오디오를 복구하지 않음")
    for interruption in ["none", "window", "display", "launch", "revision", "peer", "host", "mac", "capability"] {
        let client = fresh()
        client.deliverIdleCatalog(idle)
        var changed = idle
        switch interruption {
        case "none": client.select(.none)
        case "window": client.select(.window(42))
        case "display": client.selectDisplay(main)
        case "launch": client.launch(bundleID: "fixture.manual")
        case "revision": changed.selectionRevision = "revision-1"
        case "peer": client.connection = NWConnection()
        case "host": changed.launchID = "other-host"
        case "mac": client.session?.macID = "other-mac"
        default: changed.automaticDisplaySelection = nil
        }
        changed.displayInventoryID = nil
        client.deliverIdleCatalog(changed)
        let before = client.allSent.count
        changed.displayInventoryID = nextInventory
        client.deliverIdleCatalog(changed)
        expect(client.allSent.count == before, "\(interruption) 뒤 새 inventory로 자동 의도를 재바인딩하지 않음")
    }
    let restore = fresh()
    seed(restore)
    restore.deliverIdleCatalog(idle)
    expect(picks(restore).first?.displayID == secondary.id, "same inventory and launch restore the verified secondary display")
    let relaunched = fresh(restore.defaults)
    relaunched.deliverIdleCatalog(idle)
    expect(picks(relaunched).first?.displayID == secondary.id, "app relaunch reads the same scoped remembered display")
    for mismatch in ["mac", "launch", "inventory", "missing"] {
        let client = fresh()
        seed(client, mac: mismatch == "mac" ? "other-mac" : "trusted-mac",
             launch: mismatch == "launch" ? "previous-launch" : "host",
             inventoryID: mismatch == "inventory" ? UUID() : inventory, id: mismatch == "missing" ? 99 : secondary.id)
        client.deliverIdleCatalog(idle)
        expect(picks(client).first?.displayID == main.id, "\(mismatch) mismatch falls back only to the unique main display")
    }
    for displays in [[], [secondary], [main, DisplayInfo(id: 15, name: "also-main", width: 800, height: 600, isMain: true)], [main, main]] {
        let client = fresh()
        var list = idle
        list.displays = displays
        client.deliverIdleCatalog(list)
        expect(client.allSent.isEmpty && client.remoteAudioControl.changes == 0, "missing or ambiguous main display sends nothing and preserves audio")
    }
    for cap in [nil, 0, 2] as [Int?] {
        let client = fresh()
        var old = idle
        old.automaticDisplaySelection = cap
        old.selectionRevision = nil
        client.deliverIdleCatalog(old)
        expect(client.allSent.isEmpty && client.remoteAudioControl.changes == 0, "old 143 or unknown capability sends zero automatic requests")
    }
    for revision in [nil, "", String(repeating: "r", count: 129)] as [String?] {
        let client = fresh()
        var malformed = idle
        malformed.selectionRevision = revision
        client.deliverIdleCatalog(malformed)
        expect(client.allSent.isEmpty && client.remoteAudioControl.changes == 0, "missing or invalid revision cannot send an automatic display request")
    }
    for trust in ["plain", "wrong-pin", "missing-mac", "missing-key"] {
        let client = fresh()
        switch trust {
        case "plain": client.session?.home = .plain
        case "wrong-pin": client.session?.home = .saved(pin: Data([2]))
        case "missing-mac": client.session?.macID = nil
        default: client.savedMacs = []
        }
        client.deliverIdleCatalog(idle)
        expect(client.allSent.isEmpty, "\(trust) session cannot restore or choose a display")
    }
    for choice in ["none", "window", "display", "launch"] {
        let client = fresh()
        switch choice {
        case "none": client.select(.none)
        case "window": client.select(.window(32))
        case "display": client.selectDisplay(client.displays[0])
        default: client.launch(bundleID: "fixture")
        }
        let before = client.allSent.count
        client.deliverIdleCatalog(idle)
        expect(client.allSent.count == before, "explicit \(choice) blocks first-catalog automatic display selection")
    }
    for change in ["revision", "inventory", "capability", "human-none", "peer"] {
        let client = fresh()
        let peer = client.connection!
        _ = client.link.hold(peer)
        client.deliverIdleCatalog(idle)
        expect(peer.packets.isEmpty, "automatic display submission waits behind the real SessionLink hold")
        var changed = idle
        switch change {
        case "revision": changed.selectionRevision = "other-peer:1"
        case "inventory": changed.displayInventoryID = UUID()
        case "capability": changed.automaticDisplaySelection = nil
        case "human-none": client.select(.none)
        default: client.connection = NWConnection()
        }
        if change != "human-none" && change != "peer" { client.deliverIdleCatalog(changed) }
        _ = client.link.unhold(peer)
        if change == "inventory" {
            expect(picks(client).count == 1 && picks(client).first?.inventoryID == changed.displayInventoryID,
                   "inventory 변경은 보류 중인 옛 제출을 취소하고 현재 UUID만 전송")
        } else {
            expect(picks(client).isEmpty, "\(change) cancels a queued automatic display submission")
        }
    }
    for change in ["revision", "inventory", "peer", "mac"] {
        let client = fresh()
        client.displayInventoryID = inventory
        client.displays = idle.displays!
        client.automaticDisplaySelection = 1
        let ticket = client.automaticTicket(peer: client.connection!, list: idle)!
        switch change {
        case "revision": client.selectionRevision = "newer"
        case "inventory": client.displayInventoryID = UUID()
        case "peer": client.connection = NWConnection()
        default: client.session?.macID = "other-mac"
        }
        expect(!client.requestDisplay(main, origin: .automatic, ticket: ticket) && client.allSent.isEmpty && client.remoteAudioControl.changes == 0,
               "\(change) mismatch rejects a stale ticket before audio teardown")
    }
    let foreign = fresh()
    foreign.deliverIdleCatalog(idle, from: NWConnection())
    expect(foreign.allSent.isEmpty && !foreign.automaticDisplayCatalogObserved, "catalog from another peer cannot consume or send the display opportunity")
    let activePeer = fresh()
    var nonidle = idle
    nonidle.active = .window(50)
    activePeer.deliverIdleCatalog(nonidle)
    var laterIdle = idle
    laterIdle.selectionRevision = "other-peer:2"
    activePeer.deliverIdleCatalog(laterIdle)
    expect(activePeer.allSent.isEmpty, "another peer's later idle revision never rebases a first-catalog opportunity")
    let preserved = fresh()
    seed(preserved)
    let prior = preserved.defaults.values
    preserved.deliverIdleCatalog(idle)
    preserved.select(.none)
    confirmed.activeDisplayID = secondary.id
    preserved.deliverIdleCatalog(confirmed)
    expect(preserved.defaults.values == prior && preserved.pendingDisplaySelection == nil,
           "explicit None preserves the remembered display and rejects a late desktop acknowledgement")
    let oldEpoch = fresh()
    oldEpoch.sourceCatalogEpoch = confirmed.videoEpoch?.id
    oldEpoch.deliverIdleCatalog(idle)
    oldEpoch.pendingDisplaySelection = Client.PendingDisplaySelection(
        display: Client.RememberedDisplay(macID: "trusted-mac", launchID: "host", inventoryID: inventory, displayID: secondary.id),
        peer: ObjectIdentifier(oldEpoch.connection!), intent: 0, revision: "revision-0", epoch: confirmed.videoEpoch?.id)
    oldEpoch.deliverIdleCatalog(confirmed)
    expect(oldEpoch.defaults.values.isEmpty, "same video epoch never confirms a new display selection")
    let windowResume = fresh()
    windowResume.resumeSource = .window(1001)
    windowResume.beginAutomaticConnectionOpportunity(peer: windowResume.connection)
    var withWindow = idle
    withWindow.windows = [WindowInfo(id: 1001, title: "fixture", appName: "fixture", bundleID: "fixture", width: 800, height: 600)]
    windowResume.deliverIdleCatalog(withWindow)
    expect(picks(windowResume).isEmpty && windowResume.allSent.contains { $0.0 == .selectSource && Wire.decode(SourceRequest.self, from: $0.1)?.source == .window(1001) },
           "modern desktop capability preserves a valid window reconnect intent")
    let manual = fresh()
    manual.displayInventoryID = inventory
    manual.displays = [main]
    manual.selectDisplay(main)
    expect(picks(manual).first?.origin == nil && picks(manual).first?.selectionRevision == nil,
           "manual display selection retains the old host wire format")
    var manualAcknowledgement = confirmed
    manualAcknowledgement.activeDisplayID = main.id
    manual.deliverIdleCatalog(manualAcknowledgement)
    expect(manual.defaults.values.count == 1 && manual.actions == 1,
           "a confirmed manual display choice uses the same persistence path")

    for preparing in ["inventory", "displays", "capability", "authentication"] {
        let client = fresh()
        var early = idle
        switch preparing {
        case "inventory": early.displayInventoryID = nil
        case "displays": early.displays = []
        case "capability": early.automaticDisplaySelection = nil
        default: client.session?.home = .plain
        }
        client.deliverIdleCatalog(early)
        expect(client.allSent.isEmpty && !client.automaticDisplayCatalogObserved,
               "preparing \(preparing) retains the original startup opportunity without a request")
        client.session?.home = .saved(pin: Data([1]))
        client.deliverIdleCatalog(idle)
        expect(picks(client).count == 1 && picks(client).first?.displayID == main.id,
               "ready \(preparing) on the original revision, peer and host starts video")
    }
    for change in ["revision", "host", "peer", "none", "window", "display", "launch"] {
        let client = fresh()
        var early = idle
        early.displayInventoryID = nil
        client.deliverIdleCatalog(early)
        var ready = idle
        switch change {
        case "revision": ready.selectionRevision = "other-peer:ready"
        case "host": ready.launchID = "replacement-host"
        case "peer": client.connection = NWConnection()
        case "none": client.select(.none)
        case "window": client.select(.window(99))
        case "display": client.selectDisplay(main)
        default: client.launch(bundleID: "fixture")
        }
        let before = client.allSent.count
        client.deliverIdleCatalog(ready)
        expect(client.allSent.count == before, "prepared startup never rebases after \(change)")
        client.deliverIdleCatalog(idle)
        expect(client.allSent.count == before, "old catalog replay cannot revive rejected \(change) preparation")
    }
    var recoveryCases: [(String, Client)] = []
    for change in ["unchanged", "revision", "inventory", "peer", "none", "window-restored"] {
        let client = fresh()
        seed(client)
        var watching = idle
        watching.active = .window(1001)
        watching.windows = [WindowInfo(id: 1001, title: "fixture", appName: "fixture", bundleID: "fixture", width: 800, height: 600)]
        client.deliverIdleCatalog(watching)
        client.deliverIdleCatalog(idle)
        expect(client.allSent.isEmpty && client.scheduledAutomaticTicket != nil,
               "modern closed-window recovery keeps the original delay")
        var changed = idle
        switch change {
        case "revision": changed.selectionRevision = "other-peer:closed"
        case "inventory": changed.displayInventoryID = UUID()
        case "peer": client.connection = NWConnection()
        case "none": client.select(.none)
        case "window-restored": changed.windows = watching.windows
        default: break
        }
        client.deliverIdleCatalog(changed)
        recoveryCases.append((change, client))
    }
    try? await Task.sleep(for: .milliseconds(2200))
    for (change, client) in recoveryCases {
        if change == "unchanged" {
            expect(picks(client).count == 1 && picks(client).first?.displayID == secondary.id,
                   "closed window restores the verified display through modern CAS after the delay")
        } else {
            expect(picks(client).isEmpty, "closed-window recovery refuses changed \(change) without rebasing")
        }
    }
}
