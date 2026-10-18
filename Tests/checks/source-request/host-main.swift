import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL \(label)") }
        }
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        let peer = NSObject()
        let otherPeer = NSObject()
        for source in [StreamSource.none, .desktop, .window(42)] {
            for origin in [SourceRequest.Origin.human, .automatic] {
                let request = SourceRequest(source: source, origin: origin, selectionRevision: "host:0")
                let data = Wire.encode(request)
                expect(Wire.decode(StreamSource.self, from: data) == source, "old source decoder accepts same-root modern payload")
                expect(Wire.decode(SourceRequest.self, from: data) == request, "modern exact roundtrip")
            }
            expect(Wire.decode(SourceRequest.self, from: Wire.encode(source))?.origin == nil, "old payload has unknown provenance")
        }
        for metadata in ["\"selectionOrigin\":null", "\"selectionOrigin\":\"unknown\"", "\"selectionOrigin\":\"automatic\"", "\"selectionRevision\":\"host:0\"", "\"selectionOrigin\":\"automatic\",\"selectionRevision\":null", "\"selectionOrigin\":\"human\",\"selectionRevision\":42", "\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"\""] {
            let data = Data(("{\"none\":{}," + metadata + "}").utf8)
            expect(Wire.decode(SourceRequest.self, from: data) == nil, "malformed metadata never downgrades to legacy")
        }
        for human in [StreamSource.none, .window(999), .window(42), .desktop] {
            let host = AdmissionHost(); host.join(peer); host.join(otherPeer)
            let revision = host.selectionRevision
            host.receive(.init(source: human, origin: .human, selectionRevision: "old-human-catalog"), peer: peer)
            let afterHuman = host.selectionRevision
            host.receive(.init(source: .window(1), origin: .automatic, selectionRevision: revision), peer: otherPeer)
            expect(host.selectionRevision == afterHuman && afterHuman != revision, "explicit intent including None and failure renews CAS before suspension")
            await settle()
            expect(!host.server.committed.contains(.window(1)), "old cross-client automatic cannot publish after explicit intent")
        }
        let duplicate = AdmissionHost(); duplicate.join(peer); duplicate.join(otherPeer)
        let revision = duplicate.selectionRevision
        duplicate.receive(.init(source: .window(1), origin: .automatic, selectionRevision: revision), peer: peer)
        let consumed = duplicate.selectionRevision
        duplicate.receive(.init(source: .window(2), origin: .automatic, selectionRevision: revision), peer: otherPeer)
        await settle()
        expect(duplicate.selectionRevision == consumed && duplicate.server.committed == [.window(1)], "one CAS consumption admits at most one automatic request")
        let denied = AdmissionHost()
        denied.receive(.init(source: .window(1), origin: .human), peer: peer)
        expect(denied.pickSequence == 0 && denied.audioChanges == 0, "unauthenticated peer cannot invalidate work")

        for phase in ["inventory", "audio", "stop", "start", "stage", "fallback"] {
            let host = AdmissionHost(); host.join(peer)
            let barrier = Barrier()
            let automatic: StreamSource
            switch phase {
            case "inventory": host.catalog.refreshBarrier = barrier; automatic = .desktop
            case "audio": host.audioBarrier = barrier; automatic = .window(1)
            case "stop": host.capture.stopBarrier = barrier; automatic = .window(1)
            case "fallback": host.virtualDisplay = true; host.capture.startBarrier = barrier; host.capture.failNextStart = true; automatic = .window(1)
            case "stage": host.virtualDisplay = true; host.stage.prepareBarrier = barrier; automatic = .window(1)
            default: host.capture.startBarrier = barrier; automatic = .window(1)
            }
            host.receive(.init(source: automatic, origin: .automatic, selectionRevision: host.selectionRevision), peer: peer)
            await barrier.reached()
            host.receive(.init(source: .window(2), origin: .human), peer: peer)
            host.catalog.refreshBarrier = nil; host.audioBarrier = nil; host.capture.stopBarrier = nil
            host.capture.startBarrier = nil; host.stage.prepareBarrier = nil
            barrier.resume()
            await settle()
            expect(host.server.committed == [.window(2)], "superseded automatic cannot commit at full pipeline \(phase)")
            expect(phase == "start" || !host.raised.contains(1), "superseded automatic cannot raise after \(phase), except focus already performed before start")
        }
        let launch = AdmissionHost(); launch.join(peer)
        launch.launch("app.a", peer: peer)
        let launchRevision = launch.selectionRevision
        launch.receive(.init(source: .window(2), origin: .human), peer: peer)
        await launch.completeLaunch([WindowInfo(id: 1, title: "late", appName: "A", bundleID: "app.a", width: 640, height: 480)])
        await settle()
        expect(launch.selectionRevision != launchRevision && launch.server.committed == [.window(2)], "late launch A retains admission and cannot replace B")
        let goodLaunch = AdmissionHost(); goodLaunch.join(peer)
        goodLaunch.launch("app.a", peer: peer)
        let originalRevision = goodLaunch.selectionRevision
        await goodLaunch.completeLaunch([WindowInfo(id: 1, title: "ready", appName: "A", bundleID: "app.a", width: 640, height: 480)])
        goodLaunch.server.drain()
        expect(goodLaunch.selectionRevision == originalRevision && goodLaunch.server.committed == [.window(1)], "legitimate launch completes using its original admission")
        let gone = AdmissionHost(); gone.join(peer)
        gone.receive(.init(source: .window(1), origin: .automatic, selectionRevision: gone.selectionRevision), peer: peer)
        gone.inputFence.leave(ObjectIdentifier(peer))
        await settle()
        expect(gone.server.committed.isEmpty && gone.audioChanges == 0, "peer removed before execution cannot publish or tear down audio")
        let legacy = AdmissionHost(); legacy.join(peer)
        let block = Barrier(); legacy.capture.startBarrier = block
        legacy.receive(.init(source: .window(1), origin: .human), peer: peer)
        await block.reached()
        let legacyRevision = legacy.selectionRevision
        legacy.receive(.init(source: .window(2)), peer: peer)
        expect(legacy.selectionRevision == legacyRevision, "legacy window drops during ordinary modern transition")
        legacy.capture.startBarrier = nil; block.resume(); await settle()
        expect(legacy.server.committed == [.window(1)], "legacy packet cannot replace unsettled modern human")
        let active = AdmissionHost(); active.join(peer)
        active.receive(.init(source: .window(1), origin: .human), peer: peer)
        await settle()
        let activeRevision = active.selectionRevision
        active.receive(.init(source: .window(2), origin: .automatic, selectionRevision: activeRevision), peer: peer)
        expect(active.selectionRevision == activeRevision, "automatic requires eligible idle or internal recovery state")
        let malformed = AdmissionHost(); malformed.join(peer)
        _ = malformed.admitSourceMessage(StreamMessage(kind: .selectSource, timestamp: 0, isKeyframe: false,
            payload: Data("{\"window\":{\"_0\":1},\"selectionOrigin\":null}".utf8)), from: peer)
        expect(malformed.pickSequence == 0 && malformed.gestureChords.forgotten == 0, "malformed modern request has no admission or gesture effects")
        let missingLaunch = AdmissionHost(); missingLaunch.join(peer)
        let beforeLaunch = missingLaunch.selectionRevision
        missingLaunch.launch("missing", peer: peer)
        missingLaunch.receive(.init(source: .window(1), origin: .automatic, selectionRevision: beforeLaunch), peer: peer)
        await settle()
        expect(missingLaunch.pickSequence == 1 && missingLaunch.settledPickSequence == 1, "failed explicit launch invalidates old automatic revision")
        var events: [Int] = []
        let ingress = CoordinatorIngress()
        ingress.submit { events.append(1) }
        ingress.submit { events.append(2) }
        await settle()
        expect(events == [1,2], "single ingress delivers synchronous admission in network event order")
        let stable = AdmissionHost(); stable.join(peer); stable.join(otherPeer)
        stable.catalog.infos = [WindowInfo(id: 1, title: "stable", appName: "A", bundleID: "app.a", width: 640, height: 480)]
        stable.launch("app.a", peer: peer)
        NSWorkspace.shared.completions.last?(1, nil)
        await settle()
        expect(stable.pendingLaunch == nil && stable.settledPickSequence == stable.pickSequence,
               "successful unchanged inventory settles original launch through workspace completion and refresh")
        expect(stable.server.committed == [.window(1)] && stable.inputFence.contains(ObjectIdentifier(otherPeer)),
               "unchanged launch keeps other peer admitted and restores global settlement input guard")
        let noWindow = AdmissionHost(); noWindow.join(peer); noWindow.join(otherPeer)
        noWindow.launch("app.empty", peer: peer)
        NSWorkspace.shared.completions.last?(1, nil); await settle()
        expect(noWindow.pendingLaunch != nil, "no-window launch retains original admission before deadline")
        noWindow.launchExpired()
        await settle()
        expect(noWindow.pendingLaunch == nil && noWindow.settledPickSequence == noWindow.pickSequence,
               "no-window deadline releases global input settlement without another admission")
        let kept = AdmissionHost(); kept.join(peer); kept.join(otherPeer)
        kept.receive(.init(source: .window(1), origin: .human), peer: peer); await settle()
        let settledAdmission = kept.sourcePublicationAdmission
        let settledRevision = kept.selectionRevision
        kept.departed(peer)
        var published = false; settledAdmission.publish { published = true }
        expect(published && kept.selectionRevision == settledRevision && kept.active == .window(1),
               "departed origin does not blanket-revoke settled shared stream")
        let staleStop = AdmissionHost(); staleStop.join(peer); staleStop.active = .window(1)
        staleStop.catalog.clientCount = 0; staleStop.cancelSourcePicksForTest()
        let emptySequence = staleStop.pickSequence
        staleStop.catalog.clientCount = 1; staleStop.join(otherPeer)
        await staleStop.stopEmpty(sequence: emptySequence)
        expect(staleStop.active == .window(1), "buffered new-client count prevents deferred zero-client stop")
        let retained = AdmissionHost(); retained.join(peer)
        retained.receive(.init(source: .window(7), origin: .human), peer: peer)
        await settle(); retained.server.drain()
        let retainedEpoch = retained.videoEpoch?.id
        retained.launch("missing", peer: peer)
        await settle(); retained.server.drain()
        expect(retained.active == .window(7) && retained.videoEpoch?.id == retainedEpoch && retained.capture.running &&
               retained.settledPickSequence == retained.pickSequence,
               "a rejected explicit launch preserves an actually committed predecessor")
        for rejection in ["missing-launch", "stale-display"] {
            let overlap = AdmissionHost(); overlap.join(peer)
            overlap.receive(.init(source: .window(7), origin: .human), peer: peer)
            await settle(); overlap.server.drain()
            let epoch = overlap.videoEpoch?.id
            let audioChanges = overlap.audioChanges
            let inventory = Barrier(); overlap.catalog.refreshBarrier = inventory
            overlap.receive(.init(source: .desktop, origin: .human), peer: peer)
            await inventory.reached()
            if rejection == "missing-launch" { overlap.launch("missing", peer: peer) }
            else {
                _ = overlap.admitSourceMessage(.init(kind: .selectDisplay, timestamp: 0, isKeyframe: false,
                    payload: Wire.encode(DisplaySelection(displayID: 13, inventoryID: UUID()))), from: peer)
            }
            await settle(); overlap.server.drain()
            overlap.catalog.refreshBarrier = nil; inventory.resume(); await settle(); overlap.server.drain()
            expect(overlap.active == .window(7) && overlap.videoEpoch?.id == epoch && overlap.capture.running &&
                   overlap.audioChanges == audioChanges && overlap.settledPickSequence == overlap.pickSequence,
                   "\(rejection) during obsolete inventory wait preserves intact committed video and audio")
        }
        for phase in ["inventory", "audio"] {
            let empty = AdmissionHost(); empty.join(peer)
            empty.receive(.init(source: .window(7), origin: .human), peer: peer)
            await settle()
            let barrier = Barrier()
            if phase == "inventory" { empty.catalog.refreshBarrier = barrier }
            else { empty.audioBarrier = barrier }
            empty.receive(.init(source: phase == "inventory" ? .desktop : .window(8), origin: .human), peer: peer)
            await barrier.reached()
            empty.departed(peer)
            empty.catalog.clientCount = 0
            empty.deselectWhenSettled = true
            empty.cancelSourcePicksForTest()
            empty.catalog.refreshBarrier = nil; empty.audioBarrier = nil
            barrier.resume(); await settle()
            expect(empty.active == .none && empty.videoEpoch == nil && !empty.capture.running,
                   "last client during \(phase) drains the old capture and completes None")
        }
        let abandoned = AdmissionHost(); abandoned.join(peer); abandoned.join(otherPeer)
        abandoned.catalog.clientCount = 2
        abandoned.receive(.init(source: .window(7), origin: .human), peer: peer)
        await settle()
        let stopping = Barrier(); abandoned.capture.stopBarrier = stopping
        abandoned.receive(.init(source: .window(8), origin: .human), peer: peer)
        await stopping.reached()
        abandoned.departed(peer); abandoned.catalog.clientCount = 1
        abandoned.capture.stopBarrier = nil; stopping.resume(); await settle()
        expect(abandoned.active == .none && abandoned.videoEpoch == nil && !abandoned.capture.running,
               "choosing peer departure finishes interrupted teardown for the remaining peer")
        expect(abandoned.publishedCatalogs.last?.source == StreamSource.none && abandoned.publishedCatalogs.last?.epoch == nil,
               "remaining peer receives completed None after interrupted teardown")
        print("SOURCE_REQUEST_HOST_CHECKS total=\(checks) failed=\(failures)")
        if failures > 0 { exit(1) }
    }
}
