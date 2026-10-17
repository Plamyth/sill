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

        let rig = Rig(), desktop = rig.desktop
        desktop.request(aid); desktop.request(aid); desktop.request(bid)
        expect(rig.displays.count == 1 && desktop.requesters.count == 2, "duplicate hello does not create another display")
        desktop.release(cid); desktop.release(aid)
        expect(desktop.phase == .creating && rig.displays[0].destroys == 0, "other session keeps in-flight display alive")
        await online(rig.displays[0])
        expect(desktop.displayID == 100 && rig.published.last! == 100, "publish only after ready")
        desktop.request(cid)
        expect(rig.displays.count == 1, "a ready display is reused")
        desktop.release(bid)
        expect(desktop.displayID == 100, "one remaining requester retains desktop")
        desktop.release(cid)
        expect(desktop.phase == .idle && desktop.displayID == nil, "last session removes catalog ID")
        expect(rig.displays[0].events == ["recover", "destroy"], "restore precedes exactly one resource destruction")
        desktop.release(cid)
        expect(rig.displays[0].destroys == 1, "duplicate disconnect is idempotent")

        let race = Rig(), rd = race.desktop
        rd.request(aid); await settle()
        let old = race.displays[0]
        rd.release(aid)
        expect(old.destroys == 1, "disconnect destroys resource before online wait completes")
        rd.request(bid)
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
            cd.request(aid)
            configuring.displays[0].blockConfiguration = true
            configuring.displays[0].configurationFails = lateFailure
            await online(configuring.displays[0])
            expect(configuring.displays[0].configuration != nil, "configuration may suspend")
            cd.release(aid); cd.request(bid)
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
            fd.request(aid)
            if failure > 0 {
                failed.displays[0].configurationFails = failure == 2
                failed.displays[0].valid = failure != 3
                await online(failed.displays[0], success: failure != 1)
                expect(failed.displays[0].destroys == 1, "failed creation releases its display")
            }
            expect(fd.displayID == nil && failed.failures.count == 1, "creation failure is bounded and unpublished")
            fd.request(aid); fd.request(bid); await settle()
            expect(failed.failures.count == 1 && failed.displays.count <= 1, "no hello retry loop within failed requester set")
            fd.release(aid); fd.release(bid)
            expect(fd.phase == .idle, "failed session resets only after all leave")
            failed.throwOnCreate = false
            fd.request(cid); await online(failed.displays.last!)
            expect(fd.phase == .ready, "a later session can retry once")
            fd.shutdown()
        }

        let lost = Rig(), ld = lost.desktop
        ld.request(aid); await online(lost.displays[0])
        lost.displays[0].valid = false
        ld.checkDisplay(); ld.checkDisplay(); lost.displays[0].lost(); ld.request(bid)
        expect(ld.displayID == nil && lost.displays[0].destroys == 1 && lost.failures.count == 1,
               "topology loss cleans up once without automatic recreation")
        expect(lost.published.last! == nil && lost.displays.count == 1, "loss removes allowlist ID")
        ld.shutdown()

        for pending in [false, true] {
            let exiting = Rig(), ed = exiting.desktop
            ed.request(aid)
            if !pending { await online(exiting.displays[0]) } else { await settle() }
            ed.shutdown(); ed.shutdown(); ed.request(bid)
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
            fixture.requestExtendedDesktop(for: a, hello: hello)
            expect(auth.displays.isEmpty, "actual coordinator admission rejects unauthorized hello \(invalid)")
        }
        a.state = .ready
        let auth = Rig(), fixture = CoordinatorFixture(auth.desktop)
        fixture.connections[aid] = a; fixture.routes[aid] = Route()
        fixture.requestExtendedDesktop(for: a, hello: Hello())
        expect(auth.displays.count == 1 && auth.desktop.requesters == [aid], "actual coordinator admits authenticated connection identity")
        await online(auth.displays[0]); auth.desktop.shutdown()

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
        catalog.displays = [.init(displayID: 1), .init(displayID: 42), .init(displayID: 43)]
        catalog.displayInventory.update([.init(id: 1, isMain: true), .init(id: 42)], signatures: ["physical", "desktop"])
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
        let origin = ExtendedDesktop.originRight(of: screens)!
        let bounds = CGRect(origin: origin, size: CGSize(width: 1024, height: 768))
        expect(origin == CGPoint(x: 1512, y: 0) && screens.allSatisfy { !bounds.intersects($0) }, "right origin is disjoint from offset physical monitors")
        expect(ExtendedDesktop.originRight(of: screens + [CGRect(x: 1512, y: 1500, width: 1280, height: 720)]) == CGPoint(x: 2792, y: 1500),
               "right display touches the edge even for a staggered arrangement")
        expect(ExtendedDesktop.originRight(of: []) == nil, "no geometry cannot create display")
        expect(ExtendedDesktop.originRight(of: [CGRect(x: Double(Int32.max), y: 0, width: 100, height: 100)]) == nil,
               "reject origin outside CoreGraphics range")
        expect(!ExtendedDesktop.ownsWindow(CGRect(x: 1450, y: 20, width: 80, height: 80), bounds: bounds), "physical-centered overlapping window is never recovered")
        expect(ExtendedDesktop.ownsWindow(CGRect(x: 1500, y: 20, width: 200, height: 100), bounds: bounds), "desktop-centered window may be recovered")
        expect(!ExtendedDesktop.ownsWindow(.zero, bounds: bounds), "empty window is never recovered")
        print("Extended desktop: \(assertions) assertions passed. Pure policy/lifecycle and extracted coordinator/catalog methods only.")
    }
}
