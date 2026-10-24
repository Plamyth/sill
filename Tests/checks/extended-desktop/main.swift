import Foundation
import CoreGraphics

@main
struct Checks {
    @MainActor static var assertions = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ description: String) {
        assertions += 1
        if !value() { fatalError("FAIL \(description)") }
    }
    @MainActor static func settle() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func online(_ display: FakeDisplay, success: Bool = true) async {
        await settle()
        expect(display.online != nil, "creation reached its online wait")
        display.online?.resume(returning: success)
        display.online = nil
        await settle()
    }
    @MainActor static func main() async {
        let a = NWConnection(), b = NWConnection(), c = NWConnection()
        let aid = ObjectIdentifier(a), bid = ObjectIdentifier(b), cid = ObjectIdentifier(c)
        let nativeViewport = Viewport(width: 1350, height: 890, scale: nil)
        let native = ExtendedDesktop.Dimensions(viewport: nativeViewport)!
        let nativeSize = CGSize(width: native.widthPt, height: native.heightPt)
        let keyboard = Viewport(width: 1350, height: 540, scale: 1.5)
        let portraitViewport = Viewport(width: 890, height: 1350, scale: 0.8)
        let portrait = ExtendedDesktop.Dimensions(viewport: portraitViewport)!
        expect(native.widthPt == 1350 && native.heightPt == 890 && native.scale == 2 &&
            native.pixelWidth == 2700 && native.pixelHeight == 1780, "native panel uses 1350x890 points and 2700x1780 pixels")
        expect(ExtendedDesktop.Dimensions(viewport: keyboard)?.scale == 2, "text scale does not change native display scale")
        let invalidViewports = [
            Viewport(width: .nan, height: 890, scale: nil),
            Viewport(width: .infinity, height: 890, scale: nil),
            Viewport(width: -.infinity, height: 890, scale: nil),
            Viewport(width: 1350, height: .nan, scale: nil),
            Viewport(width: 1350, height: .infinity, scale: nil),
            Viewport(width: 1350, height: -.infinity, scale: nil),
            Viewport(width: 0, height: 890, scale: nil),
            Viewport(width: -1, height: 890, scale: nil),
            Viewport(width: 319.9, height: 890, scale: nil),
            Viewport(width: 2048.1, height: 890, scale: nil),
            Viewport(width: 1350, height: 0, scale: nil),
            Viewport(width: 1350, height: -1, scale: nil),
            Viewport(width: 1350, height: 239.9, scale: nil),
            Viewport(width: 1350, height: 2048.1, scale: nil)
        ]
        for viewport in invalidViewports {
            expect(ExtendedDesktop.Dimensions(viewport: viewport) == nil, "invalid dimensions are refused before integer conversion")
        }
        for (width, height) in [(320.0, 240.0), (2048.0, 2048.0), (1350.4, 889.6)] {
            let dimensions = ExtendedDesktop.Dimensions(viewport: Viewport(width: width, height: height, scale: nil))
            expect(dimensions?.widthPt == Int(width.rounded()) && dimensions?.heightPt == Int(height.rounded()),
                   "bounded point dimensions round to a native display mode")
        }

        let waitingDisplay = VirtualDisplay()
        let waiting = Task { @MainActor in await AdapterWaitFixture.waitUntilOnline(waitingDisplay) }
        await settle()
        waiting.cancel()
        let cancelled = await waiting.value
        expect(!cancelled && waitingDisplay.modeChecks < 4, "actual online wait stops cancellation without spinning")
        let removedDisplay = VirtualDisplay()
        removedDisplay.isAlive = false
        let removedOnline = await AdapterWaitFixture.waitUntilOnline(removedDisplay)
        expect(!removedOnline && removedDisplay.modeChecks == 0, "online wait never configures a destroyed display")
        let readyDisplay = VirtualDisplay()
        readyDisplay.requestedMode = true
        let readyOnline = await AdapterWaitFixture.waitUntilOnline(readyDisplay)
        expect(readyOnline, "online wait accepts requested mode")

        for mask in 0..<32 {
            let appKit = mask & 1 != 0, synthetic = mask & 2 != 0, connected = mask & 4 != 0
            let encrypted = mask & 8 != 0, paired = mask & 16 != 0
            expect(ExtendedDesktop.eligible(appKitLoop: appKit, synthetic: synthetic, connected: connected,
                encrypted: encrypted, paired: paired, device: "iPad (iPad14,1)") ==
                (appKit && !synthetic && connected && encrypted && paired), "all eligibility gates")
        }
        for name in [nil, "", "Android", "SM-S911N", "iPhone (iPhone15,2)", "Vision Pro", "my iPad phone", "iPad (iPad14,1) injected"] as [String?] {
            expect(!ExtendedDesktop.eligible(appKitLoop: true, synthetic: false, connected: true, encrypted: true,
                paired: true, device: name), "non-iPad hello refused")
        }
        for name in ["iPad", "iPad (iPad14,1)", "내 태블릿 (iPad16,6)"] {
            expect(ExtendedDesktop.eligible(appKitLoop: true, synthetic: false, connected: true, encrypted: true,
                paired: true, device: name), "iPad model hello including custom device name")
        }

        let onDemand = Rig(), onDemandCoordinator = CoordinatorFixture(onDemand.desktop)
        onDemandCoordinator.independentStreamsEnabled = true
        onDemandCoordinator.connections[aid] = a
        onDemandCoordinator.routes[aid] = Route()
        let peerA = PeerFixture(), peerB = PeerFixture()
        onDemandCoordinator.peerStreams[aid] = peerA
        var request = nativeViewport
        request.extendedDesktopIntent = .request
        var release = nativeViewport
        release.extendedDesktopIntent = .release
        await onDemandCoordinator.receive(request, from: a)
        expect(onDemand.displays.isEmpty && onDemand.desktop.requesters.isEmpty,
               "button request before eligible hello is refused")
        onDemandCoordinator.receiveHello(Hello(), from: a)
        await onDemandCoordinator.receive(nativeViewport, from: a)
        expect(onDemand.displays.isEmpty && onDemand.desktop.requesters.isEmpty,
               "fresh main and ordinary independent viewport must not allocate an extended desktop")
        expect(onDemandCoordinator.extendedDesktopEligible == [aid] && onDemandCoordinator.extendedDesktopViewports.isEmpty,
               "eligible hello records identity without allocation or panel-size latch")
        for var invalid in invalidViewports {
            invalid.extendedDesktopIntent = .request
            onDemandCoordinator.updateExtendedDesktopViewport(invalid, from: a)
            expect(onDemand.displays.isEmpty && onDemand.desktop.requesters.isEmpty,
                   "invalid explicit request cannot register a requester or create a display")
        }
        request.extendedDesktop = .init(width: 1350, height: 976)
        await onDemandCoordinator.receive(request, from: a)
        await onDemandCoordinator.receive(request, from: a)
        onDemandCoordinator.receiveHello(Hello(), from: a)
        await onDemandCoordinator.receive(keyboard, from: a)
        expect(onDemand.displays.count == 1 && onDemand.desktop.requesters == [aid] &&
               onDemand.displays[0].dimensions.heightPt == 976,
               "explicit peer viewport creates one resource at validated allocation size despite repeats and keyboard")
        expect(peerA.viewports.last == keyboard, "resource intent preserves the peer's normal viewport delivery")
        onDemandCoordinator.connections[bid] = b
        onDemandCoordinator.routes[bid] = Route()
        onDemandCoordinator.peerStreams[bid] = peerB
        onDemandCoordinator.receiveHello(Hello(), from: b)
        await onDemandCoordinator.receive(release, from: b)
        expect(onDemand.desktop.requesters == [aid], "non-requester release cannot remove another peer")
        await onDemandCoordinator.receive(request, from: b)
        expect(onDemand.desktop.requesters == [aid, bid] && onDemand.displays.count == 1,
               "second explicit requester shares the existing resource")
        await online(onDemand.displays[0])
        await onDemandCoordinator.receive(release, from: a)
        await onDemandCoordinator.receive(release, from: a)
        expect(onDemand.desktop.requesters == [bid] && onDemand.desktop.displayID == 100 && onDemand.displays[0].destroys == 0,
               "repeated release removes only its own requester and preserves the other peer")
        await onDemandCoordinator.receive(nativeViewport, from: a)
        expect(onDemand.desktop.requesters == [bid], "ordinary viewport after release does not reacquire ownership")
        onDemandCoordinator.disconnect(b)
        expect(onDemand.desktop.requesters.isEmpty && onDemand.desktop.displayID == nil &&
               onDemand.displays[0].destroys == 1 && !onDemandCoordinator.extendedDesktopEligible.contains(bid),
               "last requester disconnect clears eligibility and destroys exactly once")
        let beforeStale = peerB.viewports.count
        _ = await onDemandCoordinator.handlePeerMessage(ViewportMessage(request), from: b, lane: peerB)
        onDemandCoordinator.updateExtendedDesktopViewport(request, from: b)
        expect(onDemand.displays.count == 1 && peerB.viewports.count == beforeStale,
               "late disconnected peer cannot create or update its stream")
        await onDemandCoordinator.receive(nativeViewport, from: a)
        expect(onDemand.displays.count == 1 && onDemand.desktop.requesters.isEmpty,
               "remaining eligible non-requester stays on main without creating a display")
        await onDemandCoordinator.receive(request, from: a)
        expect(onDemand.displays.count == 2 && onDemand.desktop.requesters == [aid],
               "new explicit request after cleanup creates a fresh generation")
        var invalidRelease = Viewport(width: .nan, height: 0, scale: nil)
        invalidRelease.extendedDesktopIntent = .release
        onDemandCoordinator.updateExtendedDesktopViewport(invalidRelease, from: a)
        expect(onDemand.desktop.requesters.isEmpty && onDemand.displays[1].destroys == 1,
               "own release does not depend on allocation geometry")
        await online(onDemand.displays[1])
        expect(onDemand.desktop.displayID == nil, "late online completion after release cannot publish a display")
        onDemandCoordinator.disconnect(a)
        expect(onDemandCoordinator.extendedDesktopEligible.isEmpty && onDemandCoordinator.extendedDesktopViewports.isEmpty,
               "disconnect clears remembered eligibility and dimensions")
        onDemand.desktop.shutdown()

        for invalid in 0..<10 {
            let refused = Rig(), coordinator = CoordinatorFixture(refused.desktop), peer = PeerFixture()
            coordinator.independentStreamsEnabled = true
            coordinator.connections[aid] = a; coordinator.routes[aid] = Route(); coordinator.peerStreams[aid] = peer
            a.state = .ready
            coordinator.receiveHello(Hello(), from: a)
            switch invalid {
            case 0: coordinator.routes[aid] = nil
            case 1: coordinator.routes[aid]?.encrypted = false
            case 2: coordinator.routes[aid]?.fingerprint = nil
            case 3: coordinator.remote?.paired = false
            case 4: coordinator.connections[aid] = b
            case 5: a.state = .cancelled
            case 6: coordinator.shuttingDown = true
            case 7: peer.isClosed = true
            case 8: coordinator.peerStreams[aid] = PeerFixture()
            default: coordinator.receiveHello(Hello(device: "Android"), from: a)
            }
            _ = await coordinator.handlePeerMessage(ViewportMessage(request), from: a, lane: peer)
            expect(refused.displays.isEmpty && refused.desktop.requesters.isEmpty,
                   "request rechecks live identity, closed lane, current paired TLS and device eligibility \(invalid)")
            coordinator.disconnect(a)
        }
        a.state = .ready
        let legacyViewport = try! JSONDecoder().decode(Viewport.self, from: Data(#"{"width":1350,"height":890,"scale":1.5}"#.utf8))
        expect(legacyViewport.extendedDesktopIntent == nil, "old viewport decodes with no resource intent")
        expect(Viewport(width: 1350, height: 890, scale: nil).extendedDesktopIntent == nil,
               "existing initializers default to no resource intent")
        let oldJSON = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyViewport)) as! [String: Any]
        expect(oldJSON["extendedDesktopIntent"] == nil, "nil intent is omitted for older decoders")
        for intent in [Viewport.ExtendedDesktopIntent.request, .release] {
            let viewport = Viewport(width: 1350, height: 890, scale: nil, extendedDesktopIntent: intent)
            let data = try! JSONEncoder().encode(viewport)
            let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            expect(json["extendedDesktopIntent"] as? String == intent.rawValue &&
                   (try! JSONDecoder().decode(Viewport.self, from: data)) == viewport, "intent has exact Codable wire value")
        }
        for bad in [#"{"width":1350,"height":890,"extendedDesktopIntent":"create"}"#,
                    #"{"width":1350,"height":890,"extendedDesktopIntent":1}"#,
                    #"{"width":1350,"height":890,"extendedDesktopIntent":"request","extendedDesktop":{"width":9000,"height":890}}"#] {
            expect((try? JSONDecoder().decode(Viewport.self, from: Data(bad.utf8))) == nil,
                   "invalid intent or allocation fails decoding")
        }

        let rig = Rig(), desktop = rig.desktop
        desktop.request(aid)
        desktop.updateViewport(native, for: aid)
        desktop.request(aid)
        desktop.updateViewport(native, for: aid)
        desktop.request(bid)
        desktop.updateViewport(native, for: bid)
        expect(rig.displays.count == 1 && desktop.requesters.count == 2, "duplicate hello does not create another display")
        desktop.release(cid); desktop.release(aid)
        expect(desktop.phase == .creating && rig.displays[0].destroys == 0, "other session keeps in-flight display alive")
        await online(rig.displays[0])
        expect(desktop.displayID == 100 && rig.published.last! == 100, "publish only after ready")
        desktop.request(cid); desktop.updateViewport(native, for: cid)
        expect(rig.displays.count == 1, "a ready display is reused")
        desktop.release(bid)
        expect(desktop.displayID == 100, "one remaining requester retains desktop")
        desktop.release(cid)
        expect(desktop.phase == .idle && desktop.displayID == nil, "last session removes catalog ID")
        expect(rig.displays[0].events == ["recover", "destroy"], "restore precedes exactly one resource destruction")
        desktop.release(cid)
        expect(rig.displays[0].destroys == 1, "duplicate disconnect is idempotent")
        expect(desktop.dimensions == nil, "last release clears latched dimensions")

        let race = Rig(), rd = race.desktop
        rd.request(aid); rd.updateViewport(native, for: aid); await settle()
        let old = race.displays[0]
        rd.release(aid)
        expect(old.destroys == 1, "disconnect destroys resource before online wait completes")
        rd.request(bid); rd.updateViewport(native, for: bid)
        old.lost()
        expect(rd.phase == .creating && race.displays[1].destroys == 0, "stale termination does not remove replacement")
        await online(old)
        expect(rd.phase == .creating && rd.displayID == nil && old.configured == 0, "stale online success cannot configure or publish")
        await online(race.displays[1])
        expect(rd.displayID == 101, "replacement remains owned after old continuation")
        old.lost()
        expect(rd.displayID == 101 && race.displays[1].destroys == 0, "late old loss cannot clear newer display")
        rd.shutdown()

        for lateFailure in [false, true] {
            let configuring = Rig(), cd = configuring.desktop
            cd.request(aid); cd.updateViewport(native, for: aid)
            configuring.displays[0].blockConfiguration = true
            configuring.displays[0].configurationFails = lateFailure
            await online(configuring.displays[0])
            expect(configuring.displays[0].configuration != nil, "configuration may suspend")
            cd.release(aid); cd.request(bid); cd.updateViewport(native, for: bid)
            await online(configuring.displays[1])
            configuring.displays[0].configuration?.resume()
            await settle()
            expect(cd.displayID == 101 && configuring.displays[0].destroys == 1 && configuring.failures.isEmpty,
                   "stale configuration success or error cannot affect new generation")
            cd.shutdown()
        }

        for failure in 0..<4 {
            let failed = Rig(), fd = failed.desktop
            failed.throwOnCreate = failure == 0
            fd.request(aid); fd.updateViewport(native, for: aid)
            if failure > 0 {
                failed.displays[0].configurationFails = failure == 2
                failed.displays[0].valid = failure != 3
                await online(failed.displays[0], success: failure != 1)
                expect(failed.displays[0].destroys == 1, "failed creation releases its display")
            }
            expect(fd.displayID == nil && failed.failures.count == 1, "creation failure is bounded and unpublished")
            fd.request(aid); fd.updateViewport(native, for: aid); fd.request(bid); fd.updateViewport(native, for: bid); await settle()
            expect(failed.failures.count == 1 && failed.displays.count <= 1, "no hello retry loop within failed requester set")
            fd.release(aid); fd.release(bid)
            expect(fd.phase == .idle, "failed session resets only after all leave")
            failed.throwOnCreate = false
            fd.request(cid); fd.updateViewport(native, for: cid); await online(failed.displays.last!)
            expect(fd.phase == .ready, "a later session can retry once")
            fd.shutdown()
        }

        let lost = Rig(), ld = lost.desktop
        ld.request(aid); ld.updateViewport(native, for: aid); await online(lost.displays[0])
        lost.displays[0].valid = false
        ld.checkDisplay(); ld.checkDisplay(); lost.displays[0].lost(); ld.request(bid); ld.updateViewport(native, for: bid)
        expect(ld.displayID == nil && lost.displays[0].destroys == 1 && lost.failures.count == 1,
               "topology loss cleans up once without automatic recreation")
        expect(lost.published.last! == nil && lost.displays.count == 1, "loss removes allowlist ID")
        ld.shutdown()

        for pending in [false, true] {
            let exiting = Rig(), ed = exiting.desktop
            ed.request(aid); ed.updateViewport(native, for: aid)
            if !pending { await online(exiting.displays[0]) } else { await settle() }
            ed.shutdown(); ed.shutdown(); ed.request(bid); ed.updateViewport(native, for: bid)
            if pending { await online(exiting.displays[0]) }
            expect(ed.phase == .shutdown && ed.requesters.isEmpty && ed.displayID == nil, "shutdown is terminal even after late waits")
            expect(exiting.displays.count == 1 && exiting.displays[0].destroys == 1, "shutdown frees pending or ready display exactly once")
        }

        for invalid in 0..<10 {
            let auth = Rig(), fixture = CoordinatorFixture(auth.desktop)
            fixture.connections[aid] = a; fixture.routes[aid] = Route()
            a.state = .ready
            var hello = Hello()
            switch invalid {
            case 0: fixture.routes[aid] = nil
            case 1: fixture.routes[aid]?.encrypted = false
            case 2: fixture.routes[aid]?.fingerprint = nil
            case 3: fixture.remote?.paired = false
            case 4: fixture.connections[aid] = b
            case 5: a.state = .cancelled
            case 6: fixture.shuttingDown = true
            case 7: fixture.synthetic = true
            case 8: fixture.appKitLoop = false
            default: hello.device = "Android (SM-S911N)"
            }
            fixture.updateExtendedDesktopViewport(nativeViewport, from: a)
            fixture.requestExtendedDesktop(for: a, hello: hello)
            fixture.updateExtendedDesktopViewport(keyboard, from: a)
            expect(auth.displays.isEmpty && auth.desktop.requesters.isEmpty,
                   "actual coordinator admission rejects unauthorized hello with viewport \(invalid)")
        }
        a.state = .ready
        let auth = Rig(), fixture = CoordinatorFixture(auth.desktop)
        fixture.connections[aid] = a; fixture.routes[aid] = Route()
        fixture.requestExtendedDesktop(for: a, hello: Hello())
        expect(auth.displays.isEmpty && auth.desktop.requesters == [aid], "authenticated hello waits for its own valid viewport")
        for viewport in invalidViewports {
            fixture.updateExtendedDesktopViewport(viewport, from: a)
            expect(auth.displays.isEmpty && fixture.extendedDesktopViewports[aid] == nil,
                   "invalid viewport leaves authenticated requester waiting")
        }
        fixture.updateExtendedDesktopViewport(nativeViewport, from: a)
        expect(auth.displays.count == 1 && auth.desktop.requesters == [aid], "actual coordinator admits authenticated connection identity")
        expect(auth.displays[0].dimensions == native, "coordinator passes native dimensions to resource factory")
        fixture.requestExtendedDesktop(for: a, hello: Hello())
        fixture.updateExtendedDesktopViewport(keyboard, from: a)
        expect(auth.displays.count == 1 && auth.desktop.dimensions == native, "repeated hello and keyboard during creation keep the first mode")
        await online(auth.displays[0])
        fixture.updateExtendedDesktopViewport(keyboard, from: a)
        fixture.updateExtendedDesktopViewport(portraitViewport, from: a)
        fixture.requestExtendedDesktop(for: a, hello: Hello())
        expect(auth.desktop.displayID == 100 && auth.displays.count == 1 && auth.desktop.dimensions == native,
               "ready display keeps its ID and dimensions across keyboard and rotation updates")
        fixture.disconnect(a)
        expect(auth.desktop.dimensions == nil && fixture.extendedDesktopViewports.isEmpty,
               "disconnect drops admission and connection viewport cache")
        fixture.updateExtendedDesktopViewport(nativeViewport, from: a)
        fixture.requestExtendedDesktop(for: a, hello: Hello())
        expect(auth.displays.count == 1 && fixture.extendedDesktopViewports.isEmpty, "late disconnected viewport or hello cannot recreate or cache")
        auth.desktop.shutdown()

        for viewportFirst in [false, true] {
            let arrivals = Rig(), coordinator = CoordinatorFixture(arrivals.desktop)
            coordinator.connections[aid] = a; coordinator.routes[aid] = Route()
            coordinator.connections[bid] = b; coordinator.routes[bid] = Route()
            coordinator.updateExtendedDesktopViewport(portraitViewport, from: b)
            coordinator.requestExtendedDesktop(for: b, hello: Hello(device: "Android"))
            expect(arrivals.displays.isEmpty && arrivals.desktop.requesters.isEmpty,
                   "another connection's cached viewport and ineligible hello cannot create")
            if viewportFirst {
                coordinator.updateExtendedDesktopViewport(nativeViewport, from: a)
                coordinator.updateExtendedDesktopViewport(keyboard, from: a)
                expect(arrivals.displays.isEmpty, "viewport before hello waits for same-connection authentication")
                coordinator.requestExtendedDesktop(for: a, hello: Hello())
            } else {
                coordinator.requestExtendedDesktop(for: a, hello: Hello())
                expect(arrivals.displays.isEmpty, "hello cannot borrow another connection's viewport")
                coordinator.updateExtendedDesktopViewport(nativeViewport, from: a)
            }
            expect(arrivals.displays.count == 1 && arrivals.displays[0].dimensions == native,
                   "both arrival orders use only the admitted connection's first valid viewport")
            coordinator.requestExtendedDesktop(for: b, hello: Hello())
            expect(arrivals.displays.count == 1 && arrivals.desktop.dimensions == native,
                   "later authenticated requester shares the first creator's mode")
            await online(arrivals.displays[0])
            coordinator.disconnect(a)
            coordinator.updateExtendedDesktopViewport(portraitViewport, from: b)
            expect(arrivals.desktop.displayID == 100 && arrivals.desktop.dimensions == native,
                   "remaining requester cannot resize the creator's display")
            coordinator.disconnect(b)
            coordinator.connections[cid] = c; coordinator.routes[cid] = Route()
            coordinator.requestExtendedDesktop(for: c, hello: Hello())
            expect(arrivals.displays.count == 1 && arrivals.desktop.dimensions == nil,
                   "fresh hello after last release cannot reuse old dimensions")
            coordinator.updateExtendedDesktopViewport(portraitViewport, from: c)
            expect(arrivals.displays.count == 2 && arrivals.displays[1].dimensions == portrait,
                   "a later session renegotiates rotation after the last release")
            await online(arrivals.displays[1])
            arrivals.desktop.shutdown()
        }

        let firstReady = Rig(), firstReadyCoordinator = CoordinatorFixture(firstReady.desktop)
        firstReadyCoordinator.connections[aid] = a; firstReadyCoordinator.routes[aid] = Route()
        firstReadyCoordinator.connections[bid] = b; firstReadyCoordinator.routes[bid] = Route()
        firstReadyCoordinator.requestExtendedDesktop(for: a, hello: Hello())
        firstReadyCoordinator.updateExtendedDesktopViewport(portraitViewport, from: b)
        expect(firstReady.displays.isEmpty, "unadmitted viewport cannot fulfill another requester's hello")
        firstReadyCoordinator.requestExtendedDesktop(for: b, hello: Hello())
        firstReadyCoordinator.updateExtendedDesktopViewport(nativeViewport, from: a)
        expect(firstReady.displays.count == 1 && firstReady.desktop.dimensions == portrait,
               "first creator with both admission and viewport wins even when another hello arrived earlier")
        await online(firstReady.displays[0])
        firstReady.desktop.shutdown()

        let trustRace = Rig(), trustCoordinator = CoordinatorFixture(trustRace.desktop)
        trustCoordinator.connections[aid] = a; trustCoordinator.routes[aid] = Route()
        trustCoordinator.remote?.paired = false
        trustCoordinator.updateExtendedDesktopViewport(nativeViewport, from: a)
        trustCoordinator.requestExtendedDesktop(for: a, hello: Hello())
        expect(trustRace.displays.isEmpty && trustRace.desktop.requesters.isEmpty,
               "cached viewport cannot bypass pairing admission")
        trustCoordinator.remote?.paired = true
        trustCoordinator.requestExtendedDesktop(for: a, hello: Hello())
        expect(trustRace.displays.count == 1 && trustRace.desktop.dimensions == native,
               "successful hello after pairing uses only that connection's cached viewport")
        await online(trustRace.displays[0])
        trustRace.desktop.shutdown()

        let abandoned = Rig(), abandonedCoordinator = CoordinatorFixture(abandoned.desktop)
        abandonedCoordinator.connections[aid] = a; abandonedCoordinator.routes[aid] = Route()
        abandonedCoordinator.updateExtendedDesktopViewport(nativeViewport, from: a)
        abandonedCoordinator.disconnect(a)
        abandonedCoordinator.requestExtendedDesktop(for: a, hello: Hello())
        expect(abandoned.displays.isEmpty && abandonedCoordinator.extendedDesktopViewports.isEmpty,
               "disconnect before hello discards cached viewport")
        abandonedCoordinator.connections[aid] = b
        abandonedCoordinator.updateExtendedDesktopViewport(nativeViewport, from: a)
        abandonedCoordinator.requestExtendedDesktop(for: a, hello: Hello())
        expect(abandoned.displays.isEmpty && abandonedCoordinator.extendedDesktopViewports.isEmpty,
               "mismatched live connection identity cannot cache or admit")

        for active in [false, true] {
            for sill in [false, true] {
                for physical in [false, true] {
                    expect(CatalogFixture.admitsDisplay(id: 42, active: active, sillVirtual: sill, physical: physical, ownedID: 42) == active,
                           "only exact owned ID bypasses physical filter")
                    expect(CatalogFixture.admitsDisplay(id: 43, active: active, sillVirtual: sill, physical: physical, ownedID: 42) == (active && !sill && physical),
                           "stage and unknown virtual displays stay excluded")
                }
            }
        }
        let catalog = CatalogFixture()
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyJSON = Data(#"{"id":1,"name":"iPad 확장 화면","width":1350,"height":890,"isMain":true}"#.utf8)
        let legacy = try! decoder.decode(DisplayInfo.self, from: legacyJSON)
        expect(legacy.role == nil && legacy.isMain, "legacy display without role decodes without name inference")
        expect(catalog.displayInfo(id: 1, name: ExtendedDesktop.name).role == nil, "matching name alone never grants role")
        catalog.setExtendedDesktopDisplay(42)
        let owned = catalog.displayInfo(id: 42, name: "다른 이름")
        expect(owned.role == "ipadExtendedDesktop" && !owned.isMain, "exact owned ID grants role independently of name and main")
        let ownedMain = catalog.displayInfo(id: 42, name: "다른 이름", mainID: 42)
        expect(ownedMain.isMain && ownedMain.role == owned.role, "role leaves main display identity unchanged")
        for id: UInt32 in [0, 1, 43, UInt32.max] {
            expect(catalog.displayInfo(id: id, name: ExtendedDesktop.name).role == nil, "other IDs never inherit owned role")
        }
        let encoded = try! encoder.encode(owned)
        let encodedObject = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        expect(encodedObject["role"] as? String == "ipadExtendedDesktop", "wire role uses exact contract value")
        expect(try! decoder.decode(DisplayInfo.self, from: encoded) == owned, "owned display round trips")
        struct LegacyDisplay: Decodable { let id: UInt32; let isMain: Bool }
        expect(try! decoder.decode(LegacyDisplay.self, from: encoded).id == 42, "legacy consumer ignores additive role")
        let unknownJSON = Data(#"{"id":42,"name":"iPad 확장 화면","width":1350,"height":890,"isMain":false,"role":"futureRole"}"#.utf8)
        let unknown = try! decoder.decode(DisplayInfo.self, from: unknownJSON)
        expect(unknown.role == "futureRole" && unknown.role != "ipadExtendedDesktop", "unknown role stays unsupported without breaking decode")
        print("DISPLAY_ROLE_FIXTURE_JSON " + String(data: try! encoder.encode([legacy, owned, unknown]), encoding: .utf8)!)
        let regularObject = try! JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
        expect(regularObject["role"] == nil, "nil role is omitted for regular legacy displays")
        catalog.setExtendedDesktopDisplay(nil)
        expect(catalog.displayInfo(id: 42, name: ExtendedDesktop.name).role == nil, "release removes role despite unchanged name")
        catalog.setExtendedDesktopDisplay(43)
        expect(catalog.displayInfo(id: 42, name: ExtendedDesktop.name).role == nil &&
            catalog.displayInfo(id: 43, name: "다른 이름").role == "ipadExtendedDesktop", "replacement grants only the current owned ID")
        catalog.setExtendedDesktopDisplay(0)
        expect(catalog.displayInfo(id: 0, name: ExtendedDesktop.name).role == nil, "invalid zero owned ID cannot grant role")
        catalog.setExtendedDesktopDisplay(nil)
        catalog.displays = [.init(displayID: 1), .init(displayID: 42), .init(displayID: 43)]
        catalog.displayInventory.update([legacy, owned], signatures: ["physical", "desktop"])
        let selection = DisplaySelection(displayID: 42, inventoryID: catalog.displayInventory.revision!)
        expect(catalog.displayInventory.select(selection), "existing display selection accepts desktop catalog ID")
        var invalidations = 0
        catalog.onDisplaysChanged = { invalidations += 1 }
        catalog.setExtendedDesktopDisplay(42)
        catalog.setExtendedDesktopDisplay(42)
        catalog.setExtendedDesktopDisplay(nil)
        expect(invalidations == 2 && catalog.displayInventory.revision == nil, "admission changes use existing catalog invalidation")
        expect(catalog.displays.map(\.displayID) == [1, 43], "cleanup removes only owned catalog display")
        expect(!catalog.displayInventory.contains(selection) && !catalog.displayInventory.select(selection), "stale desktop inventory cannot select after cleanup")

        let screens = [CGRect(x: -1920, y: -200, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 1512, height: 982)]
        let origin = ExtendedDesktop.originRight(of: screens, size: nativeSize)!
        let bounds = CGRect(origin: origin, size: nativeSize)
        expect(origin == CGPoint(x: 1512, y: 0) && screens.allSatisfy { !bounds.intersects($0) }, "right origin is disjoint from offset physical monitors")
        expect(ExtendedDesktop.originRight(of: screens + [CGRect(x: 1512, y: 1500, width: 1280, height: 720)], size: nativeSize) == CGPoint(x: 2792, y: 1500),
               "right display touches the edge even for a staggered arrangement")
        expect(ExtendedDesktop.originRight(of: [], size: nativeSize) == nil, "no geometry cannot create display")
        expect(ExtendedDesktop.originRight(of: [CGRect(x: Double(Int32.max), y: 0, width: 100, height: 100)], size: nativeSize) == nil,
               "reject origin outside CoreGraphics range")
        expect(ExtendedDesktop.originRight(of: [CGRect(x: Double(Int32.max) - 1300, y: 0, width: 1, height: 100)], size: nativeSize) == nil,
               "right bound reserves the requested native width rather than the old 1024 points")
        expect(ExtendedDesktop.originRight(of: [CGRect(x: 0, y: Double(Int32.max) - 850, width: 100, height: 1)], size: nativeSize) == nil,
               "bottom bound reserves the requested native height rather than the old 768 points")
        expect(!ExtendedDesktop.ownsWindow(CGRect(x: 1450, y: 20, width: 80, height: 80), bounds: bounds), "physical-centered overlapping window is never recovered")
        expect(ExtendedDesktop.ownsWindow(CGRect(x: 1500, y: 20, width: 200, height: 100), bounds: bounds), "desktop-centered window may be recovered")
        expect(!ExtendedDesktop.ownsWindow(.zero, bounds: bounds), "empty window is never recovered")
        print("Extended desktop: \(assertions) assertions passed. Pure policy/lifecycle and extracted coordinator/catalog methods only.")
    }
}
