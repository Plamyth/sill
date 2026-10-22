import Foundation

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
    for interruption in ["none", "window", "display", "launch", "revision", "peer", "host", "capability"] {
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
