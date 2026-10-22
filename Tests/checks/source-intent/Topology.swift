import Foundation

@main struct TopologyChecks {
    @MainActor static func main() async {
        var checks = 0
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL " + label) }
        }
        func spin(_ host: AdmissionHost) async {
            for _ in 0..<2000 { await Task.yield() }
        }
        func request(_ host: AdmissionHost, peer: NWConnection, origin: SourceRequest.Origin, revision: String? = nil) async {
            let selection = DisplaySelection(displayID: 1, inventoryID: host.catalog.displayInventory.revision!, origin: origin, selectionRevision: revision)
            await host.receiveMessage(.init(kind: .selectDisplay, timestamp: 0, isKeyframe: false, payload: Wire.encode(selection)), from: peer)
        }
        let records = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let events = records["sequence"] as! [[String: Any]]
        expect(events.count == 5 && records["automaticSelectionSubmissions"] as? Int == 0, "actual143 trace is evidence of topology only")
        func inventory(_ host: AdmissionHost, _ event: [String: Any]) {
            if event["inventory"] as? String == "nil" { host.catalog.displayInventory.invalidate() }
            else {
                var infos = (1...3).map { DisplayInfo(id: UInt32($0), name: "physical\($0)", width: 640, height: 480, isMain: $0 == 1) }
                var identities = ["physical-uuid-1/frame", "physical-uuid-2/frame", "physical-uuid-3/frame"]
                if event["hasExtended39"] as? Bool == true {
                    infos.append(.init(id: 39, name: "iPad39", width: 640, height: 480, isMain: false)); identities.append("extended39/frame")
                }
                host.catalog.displayInventory.update(infos, signatures: identities)
            }
            host.displaysChanged()
        }
        do {
            var displays = DisplayInventory()
            let info = DisplayInfo(id: 1, name: "main", width: 640, height: 480, isMain: true)
            displays.update([info], signatures: ["/frame"])
            expect(displays.identity(of: 1) == nil, "unknown physical UUID never authorizes topology recovery")
            displays.update([info], signatures: ["physical-uuid-1/old-frame"])
            let physical = displays.identity(of: 1)
            displays.update([info], signatures: ["physical-uuid-1/new-frame"])
            expect(physical != nil && displays.identity(of: 1) == physical, "same physical UUID survives geometry change while pipeline rechecks geometry")
        }
        for phase in ["admission", "refresh", "capture"] {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            inventory(host, events[0])
            let firstRevision = host.selectionRevision
            let barrier = Barrier()
            if phase == "refresh" { host.catalog.refreshBarrier = barrier }
            if phase == "capture" { host.capture.startBarrier = barrier }
            let first = Task { @MainActor in await request(host, peer: peer, origin: .automatic, revision: firstRevision) }
            if phase != "admission" { await barrier.reached() } else { await first.value }
            for event in events.dropFirst() { inventory(host, event) }
            host.catalog.refreshBarrier = nil; host.capture.startBarrier = nil
            if phase != "admission" { barrier.resume(); await first.value }
            await spin(host)
            expect(host.active == .desktop && host.catalog.displayInventory.selectedID == 1 && host.videoEpoch != nil,
                   "normal five-catalog trace recovers admitted automatic without client revision rebase at \(phase)")
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            let revision = host.selectionRevision
            for event in events { inventory(host, event) }
            expect(host.selectionRevision == revision, "unowned topology never changes source-intent revision")
            await request(host, peer: peer, origin: .automatic, revision: revision)
            expect(host.active == .desktop, "same original opportunity can submit latest inventory before first admission")
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            inventory(host, events[0])
            await host.receiveMessage(.init(kind: .launchApp, timestamp: 0, isKeyframe: false, payload: Wire.encode(LaunchApp(bundleID: "app"))), from: peer)
            let revision = host.selectionRevision
            for event in events.dropFirst() { inventory(host, event) }
            await spin(host)
            expect(host.pendingLaunch != nil && host.selectionRevision == revision, "normal topology preserves newer launch intent")
            await host.completeLaunch([.init(id: 71, title: "app", appName: "app", bundleID: "app", width: 640, height: 480)])
            expect(host.active == .window(71), "launch still publishes its original resulting window")
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            host.virtualDisplay = true
            host.stage.onPrepare = {
                let admission = host.sourcePublicationAdmission
                host.catalog.displayInventory.invalidate(); host.displaysChanged()
                host.catalog.displayInventory.update([.init(id: 13, name: "main", width: 640, height: 480, isMain: true), .init(id: 40, name: "stage", width: 640, height: 480, isMain: false)], signatures: ["main", "stage-uuid/frame"])
                host.displaysChanged()
                expect(host.sourcePublicationAdmission === admission, "window stage topology retains its source publication admission")
            }
            await host.receiveMessage(.init(kind: .selectSource, timestamp: 0, isKeyframe: false, payload: Wire.encode(SourceRequest(source: .window(77), origin: .human))), from: peer)
            await spin(host)
            expect(host.active == .window(77) && host.stage.prepares == 1 && host.server.committed == [.window(77)], "stage.prepare self-created topology commits once without retry or release loop")
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            inventory(host, events[0])
            let revision = host.selectionRevision
            let stale = DisplaySelection(displayID: 1, inventoryID: host.catalog.displayInventory.revision!, origin: .automatic, selectionRevision: revision)
            for event in events.dropFirst() { inventory(host, event) }
            await host.receiveMessage(.init(kind: .selectDisplay, timestamp: 0, isKeyframe: false, payload: Wire.encode(stale)), from: peer)
            expect(host.active == .none && host.pickSequence == 0, "pre-admission stale inventory remains strictly rejected without consuming intent")
            await request(host, peer: peer, origin: .automatic, revision: revision)
            expect(host.active == .desktop, "new inventory under same initial revision can submit after local transport success was not host acceptance")
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            host.virtualDisplay = true
            let barrier = Barrier(); host.stage.prepareBarrier = barrier
            let first = Task { @MainActor in
                await host.receiveMessage(.init(kind: .selectSource, timestamp: 0, isKeyframe: false, payload: Wire.encode(SourceRequest(source: .window(81), origin: .human))), from: peer)
            }
            await barrier.reached()
            for event in events { inventory(host, event) }
            await host.receiveMessage(.init(kind: .selectSource, timestamp: 0, isKeyframe: false, payload: Wire.encode(SourceRequest(source: .window(82), origin: .human))), from: peer)
            host.stage.prepareBarrier = nil; barrier.resume(); await first.value; await spin(host)
            expect(host.active == .window(82) && host.server.committed == [.window(82)], "own stage await still fences a genuinely newer human source")
        }
        for newer in ["human", "launch", "peer", "rejoin", "identity"] {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            inventory(host, events[0])
            let barrier = Barrier(); host.capture.startBarrier = barrier
            let first = Task { @MainActor in await request(host, peer: peer, origin: .automatic, revision: host.selectionRevision) }
            await barrier.reached()
            if newer == "human" {
                await host.receiveMessage(.init(kind: .selectSource, timestamp: 0, isKeyframe: false, payload: Wire.encode(SourceRequest(source: .window(78), origin: .human))), from: peer)
            } else if newer == "launch" {
                await host.receiveMessage(.init(kind: .launchApp, timestamp: 0, isKeyframe: false, payload: Wire.encode(LaunchApp(bundleID: "app"))), from: peer)
            } else if newer == "peer" || newer == "rejoin" {
                host.departed(peer)
                if newer == "rejoin" { host.join(peer) }
            }
            for event in events.dropFirst() { inventory(host, event) }
            if newer == "identity" {
                host.catalog.displayInventory.update([.init(id: 1, name: "physical1", width: 640, height: 480, isMain: true)], signatures: ["different-physical-uuid/frame"]); host.displaysChanged()
            }
            host.capture.startBarrier = nil; barrier.resume(); await first.value; await spin(host)
            if newer == "human" { expect(host.active == .window(78) && !host.server.committed.contains(.desktop), "topology preserves newer pending human selection") }
            else if newer == "launch" {
                expect(host.pendingLaunch != nil && host.active == .none && host.server.committed.isEmpty, "topology cannot revive automatic over newer launch")
                await host.completeLaunch([.init(id: 79, title: "app", appName: "app", bundleID: "app", width: 640, height: 480)])
                expect(host.active == .window(79), "newer launch still commits after five catalog events")
            } else { expect(host.server.committed.isEmpty, "automatic recovery refuses changed \(newer)") }
        }
        do {
            let host = AdmissionHost(), peer = NWConnection(); host.join(peer)
            inventory(host, events[0])
            await request(host, peer: peer, origin: .automatic, revision: host.selectionRevision)
            let accepted = host.pickSequence
            inventory(host, events[1]); await spin(host)
            host.catalog.displayInventory.update([.init(id: 2, name: "physical2", width: 640, height: 480, isMain: true)], signatures: ["physical-uuid-2/frame"])
            host.displaysChanged(); await spin(host)
            let other = NWConnection(); host.join(other)
            let steal = DisplaySelection(displayID: 2, inventoryID: host.catalog.displayInventory.revision!, origin: .automatic, selectionRevision: host.selectionRevision)
            await host.receiveMessage(.init(kind: .selectDisplay, timestamp: 0, isKeyframe: false, payload: Wire.encode(steal)), from: other)
            expect(host.pickSequence == accepted && host.active == .none, "second automatic cannot steal an accepted topology recovery opportunity")
            inventory(host, events.last!); await spin(host)
            expect(host.active == .desktop && host.catalog.displayInventory.selectedID == 1 && host.pickSequence == accepted, "original accepted automatic restores when its physical display returns")
        }
        print("topology production checks=\(checks) failures=\(failures)")
        if failures != 0 { exit(1) }
    }
}
