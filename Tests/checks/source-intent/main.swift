import Foundation

@main struct Checks {
    @MainActor static func main() async {
        var checks = 0
        func expect(_ ok: Bool, _ label: String) { checks += 1; if !ok { fatalError("FAIL " + label) } }
        func idle(_ host: AdmissionHost) async {
            for _ in 0..<1000 { if !host.switching && host.pickArrivedWhileSwitching == nil { return }; await Task.yield() }
            fatalError("selection did not settle")
        }
        func send(_ host: AdmissionHost, _ source: StreamSource, _ origin: SourceRequest.Origin? = nil, _ revision: String? = nil, peer: NWConnection) async {
            await host.receiveMessage(.init(kind: .selectSource, timestamp: 0, isKeyframe: false,
                payload: Wire.encode(SourceRequest(source: source, origin: origin, selectionRevision: revision))), from: peer)
        }
        func display(_ host: AdmissionHost, _ selection: DisplaySelection, peer: NWConnection) async {
            await host.receiveMessage(.init(kind: .selectDisplay, timestamp: 0, isKeyframe: false, payload: Wire.encode(selection)), from: peer)
        }
        let uuid = UUID()
        let base = "\"displayID\":13,\"inventoryID\":\"\(uuid.uuidString)\""
        for metadata in ["\"selectionOrigin\":null", "\"selectionOrigin\":3", "\"selectionOrigin\":\"robot\"",
            "\"selectionOrigin\":\"automatic\"", "\"selectionRevision\":\"x\"",
            "\"selectionOrigin\":\"human\",\"selectionRevision\":null", "\"selectionOrigin\":\"human\",\"selectionRevision\":0",
            "\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"\"",
            "\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"\(String(repeating: "가", count: 43))\""] {
            expect(Wire.decode(DisplaySelection.self, from: Data("{\(base),\(metadata)}".utf8)) == nil, "kind211 rejects malformed intent metadata")
            expect(Wire.decode(SourceRequest.self, from: Data("{\"desktop\":{},\(metadata)}".utf8)) == nil, "kind6 rejects malformed intent metadata")
        }
        expect(Wire.decode(DisplaySelection.self, from: Data("{\(base)}".utf8))?.origin == nil, "legacy kind211 decodes")
        let bare = Wire.encode(StreamSource.desktop)
        expect(Wire.decode(SourceRequest.self, from: bare)?.source == .desktop, "bare kind6 decodes")
        expect(Wire.decode(StreamSource.self, from: Wire.encode(SourceRequest(source: .desktop, origin: .human))) == .desktop, "new kind6 preserves old root")
        let automatic = DisplaySelection(displayID: 13, inventoryID: uuid, origin: .automatic, selectionRevision: "r")
        expect(Wire.decode(DisplaySelection.self, from: Wire.encode(automatic)) == automatic, "kind211 strict metadata roundtrip")
        let list = WindowList(macName: "test", windows: [], active: .none, selectionRevision: "r", automaticDisplaySelection: 1, displaySelection: 1)
        let decoded = Wire.decode(WindowList.self, from: Wire.encode(list))!
        expect(decoded.automaticDisplaySelection == 1 && decoded.selectionRevision == "r" && decoded.displaySelection == 1, "capability preserves monitor generation1")
        for kind211 in [false, true] {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            let advertised = Wire.decode(WindowList.self, from: host.listMessage().payload)!
            expect(advertised.selectionRevision == host.selectionRevision && advertised.automaticDisplaySelection == 1 && advertised.displaySelection == 1, "production host advertises implemented CAS and both monitor capabilities")
            let original = host.selectionRevision
            let selection = DisplaySelection(displayID: 13, inventoryID: host.catalog.displayInventory.revision!, origin: .automatic, selectionRevision: original)
            if kind211 { await display(host, selection, peer: peer) }
            else { await send(host, .desktop, .automatic, original, peer: peer) }
            expect(host.active == .desktop && host.server.committed == [.desktop], "kind6/kind211 automatic commits production pipeline")
            expect(host.selectionRevision != original, "automatic consumes revision")
            let sequence = host.pickSequence
            await display(host, selection, peer: peer)
            expect(host.pickSequence == sequence, "duplicate automatic cannot overwrite active source")
            await send(host, .none, .human, peer: peer)
            await display(host, selection, peer: peer)
            expect(host.active == .none && host.server.committed == [.desktop], "ABA old revision rejected after human none")
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            let revision = host.selectionRevision
            await send(host, .window(81), .automatic, revision, peer: peer)
            expect(host.active == .window(81), "explicit automatic window kind6 supported from idle current revision")
            await send(host, .window(82), .automatic, host.selectionRevision, peer: peer)
            expect(host.active == .window(81), "explicit automatic window cannot replace active source")
            await send(host, .window(82), peer: peer)
            expect(host.active == .window(82), "legacy unannotated Android window restore retains prior behavior without automatic CAS claim")
            let inventory = host.catalog.displayInventory.revision!
            await display(host, .init(displayID: 13, inventoryID: inventory), peer: peer)
            expect(host.active == .desktop, "legacy unannotated Android monitor restore retains prior behavior without automatic CAS claim")
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            let barrier = Barrier(); host.capture.startBarrier = barrier
            let initial = Task { @MainActor in await send(host, .desktop, .automatic, host.selectionRevision, peer: peer) }
            await barrier.reached()
            await host.receiveMessage(.init(kind: .launchApp, timestamp: 0, isKeyframe: false, payload: Wire.encode(LaunchApp(bundleID: "app"))), from: peer)
            await host.completeLaunch([WindowInfo(id: 74, title: "app", appName: "app", bundleID: "app", width: 640, height: 480)])
            host.capture.startBarrier = nil; barrier.resume(); await initial.value; await idle(host)
            expect(host.active == .window(74) && host.server.committed == [.window(74)], "launch result arriving inside capture await retains resolved window and latest intent")
        }
        for phase in ["refresh", "audio", "capture"] {
            for newer in ["human", "cli", "launch", "automatic"] {
                let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
                let barrier = Barrier()
                if phase == "refresh" { host.catalog.refreshBarrier = barrier }
                if phase == "audio" { host.audioBarrier = barrier }
                if phase == "capture" { host.capture.startBarrier = barrier }
                let revision = host.selectionRevision
                let initial = Task { @MainActor in
                    await display(host, .init(displayID: 13, inventoryID: host.catalog.displayInventory.revision!, origin: .automatic, selectionRevision: revision), peer: peer)
                }
                await barrier.reached()
                let sequence = host.pickSequence
                if newer == "human" { await send(host, .window(72), .human, peer: peer) }
                if newer == "cli" { await host.select(.window(72), bringForward: true) }
                if newer == "launch" {
                    await host.receiveMessage(.init(kind: .launchApp, timestamp: 0, isKeyframe: false, payload: Wire.encode(LaunchApp(bundleID: "app"))), from: peer)
                }
                if newer == "automatic" { await send(host, .desktop, .automatic, host.selectionRevision, peer: peer) }
                host.catalog.refreshBarrier = nil; host.audioBarrier = nil; host.capture.startBarrier = nil
                barrier.resume(); await initial.value; await idle(host)
                if newer == "human" || newer == "cli" {
                    expect(host.active == .window(72) && !host.server.committed.contains(.desktop), "latest manual/CLI beats automatic at \(phase)")
                } else if newer == "launch" {
                    expect(host.pendingLaunch != nil && host.server.committed.isEmpty, "pending launch prevents obsolete auto publication at \(phase)")
                    await display(host, .init(displayID: 13, inventoryID: host.catalog.displayInventory.revision!, origin: .automatic, selectionRevision: host.selectionRevision), peer: peer)
                    expect(host.pendingLaunch != nil && host.active == .none, "pending launch rejects fresh-revision automatic")
                    await host.completeLaunch([WindowInfo(id: 73, title: "app", appName: "app", bundleID: "app", width: 640, height: 480)])
                    expect(host.active == .window(73), "original launch intent selects resulting window")
                } else {
                    expect(host.pickSequence == sequence && host.active == .desktop && host.server.committed.count == 1, "two automatic requests cannot supersede in-flight automatic at \(phase)")
                }
            }
        }
        for invalidation in ["peer", "participation", "connection", "inventory", "topology"] {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            let barrier = Barrier(); host.capture.startBarrier = barrier
            let initial = Task { @MainActor in await send(host, .desktop, .automatic, host.selectionRevision, peer: peer) }
            await barrier.reached()
            switch invalidation {
            case "peer": host.departed(peer)
            case "participation":
                host.inputFence.leave(ObjectIdentifier(peer)); host.join(peer)
            case "connection": host.connections[ObjectIdentifier(peer)] = NWConnection()
            case "inventory": host.catalog.displayInventory.invalidate()
            default: host.catalog.displayInventory.update([.init(id: 14, name: "new", width: 640, height: 480, isMain: true)], signatures: ["new"]); host.displaysChanged()
            }
            host.capture.startBarrier = nil; barrier.resume(); await initial.value
            expect(host.server.committed.isEmpty, "stale \(invalidation) refuses capture publication")
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            host.catalog.displayInventory.update([.init(id: 14, name: "changed", width: 640, height: 480, isMain: true)], signatures: ["changed"])
            host.displaysChanged()
            expect(host.catalog.displayInventory.requiresSelection, "topology requires explicit current monitor")
            let advertised = Wire.decode(WindowList.self, from: host.listMessage().payload)!
            await display(host, .init(displayID: 14, inventoryID: advertised.displayInventoryID!, origin: .automatic, selectionRevision: advertised.selectionRevision), peer: peer)
            expect(host.active == .desktop && host.catalog.displayInventory.selectedID == 14 && !host.catalog.displayInventory.requiresSelection, "new automatic capability selects main after topology requiresSelection")
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            let revision = host.selectionRevision
            await display(host, .init(displayID: 13, inventoryID: UUID(), origin: .automatic, selectionRevision: revision), peer: peer)
            expect(host.selectionRevision == revision && host.server.prepared == 0, "invalid inventory has no side effects")
            await display(host, .init(displayID: 13, inventoryID: host.catalog.displayInventory.revision!, origin: .automatic, selectionRevision: "stale"), peer: peer)
            expect(host.selectionRevision == revision, "stale revision has no side effects")
            await send(host, .desktop, peer: peer)
            expect(host.active == .desktop, "legacy bare desktop remains supported")
            await send(host, .window(70), .human, peer: peer)
            await display(host, .init(displayID: 13, inventoryID: host.catalog.displayInventory.revision!), peer: peer)
            expect(host.active == .desktop, "legacy explicit monitor can still replace active window")
        }
        print("source-intent production checks passed=\(checks)")
    }
}
