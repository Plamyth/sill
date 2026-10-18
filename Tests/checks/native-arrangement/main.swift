import Foundation
import CoreGraphics

@main struct ArrangementChecks {
    @MainActor static func main() async throws {
        var failed = [String]()
        var checked = 0
        func expect(_ actual: Bool, _ wanted: Bool, _ label: String) {
            checked += 1
            if actual != wanted { failed.append(label); print("FAIL \(label): expected \(wanted), actual \(actual)") }
        }
        let display = VirtualDisplay()
        CoreGraphicsFixture.display = display
        expect(AdapterFixture.valid(display),true,"initial right arrangement")
        for (name,x,y) in [("left",-1350.0,0.0),("above",0.0,-976.0),
            ("below",0.0,982.0),("above LG",1512.0,-1074.0)] {
            display.bounds.origin = CGPoint(x:x,y:y)
            expect(AdapterFixture.valid(display),true,"native \(name) position remains valid")
            let before = display.bounds
            try await AdapterFixture.configure(display)
            expect(display.bounds == before && CoreGraphicsFixture.configuredIDs.isEmpty, true,
                   "OS restored \(name) arrangement is not rewritten")
            expect(AdapterFixture.recoveryBounds(display, lastKnown: CGRect(x:3432,y:-98,width:1350,height:976)) == before,
                   true,"cleanup uses latest \(name) bounds even before callback")
        }
        display.bounds.origin = CGPoint(x:200,y:100)
        expect(AdapterFixture.valid(display),false,"physical overlap remains refused")
        let physicalBefore = CoreGraphicsFixture.bounds
        try await AdapterFixture.configure(display)
        expect(display.bounds.origin == CGPoint(x:3432,y:-98),true,"invalid overlap uses safe initial placement")
        expect(CoreGraphicsFixture.bounds == physicalBefore && CoreGraphicsFixture.configuredIDs.allSatisfy { $0 == 13 },
               true,"configuration only writes owned display and preserves physical geometry")
        display.bounds.origin = CGPoint(x:3432,y:-98)
        CoreGraphicsFixture.mirror = 1
        expect(AdapterFixture.valid(display),false,"mirror remains refused")
        CoreGraphicsFixture.mirror = 0
        display.pixelSize.width = 1350
        expect(AdapterFixture.valid(display),false,"wrong HiDPI mode remains refused")
        display.pixelSize.width = 2700
        CoreGraphicsFixture.active = 0
        expect(AdapterFixture.valid(display),false,"inactive display remains refused")
        CoreGraphicsFixture.active = 1
        display.isAlive = false
        expect(AdapterFixture.valid(display),false,"destroyed display remains refused")
        let remembered = CGRect(x:-1350,y:0,width:1350,height:976)
        expect(AdapterFixture.recoveryBounds(display, lastKnown: remembered) == remembered,true,"lost display keeps last validated cleanup bounds")
        display.isAlive = true
        CoreGraphicsFixture.mirrorSet = 1
        expect(AdapterFixture.valid(display),false,"mirror set remains refused")
        CoreGraphicsFixture.mirrorSet = 0
        CoreGraphicsFixture.refresh = 30
        expect(AdapterFixture.valid(display),false,"wrong refresh remains refused")
        CoreGraphicsFixture.refresh = 60

        let physical = DisplayInfo(id:1,name:"physical",width:3024,height:1964,isMain:true)
        let owned = DisplayInfo(id:13,name:"CCR",width:2700,height:1952,isMain:false)
        let infos = [physical,owned]
        let identities = ["physical-uuid","owned-uuid"]
        let oldFrames = [physicalBefore[1]!,CGRect(x:3432,y:-98,width:1350,height:976)]
        let newFrames = [physicalBefore[1]!,remembered]
        let coordinator = CoordinatorFixture()
        coordinator.catalog.displayInventory.update(infos,signatures:identities,frames:oldFrames)
        let selection = DisplaySelection(displayID:13,inventoryID:coordinator.catalog.displayInventory.revision!)
        expect(coordinator.catalog.displayInventory.select(selection),true,"owned display selected")
        coordinator.catalog.displayInventory.invalidate(preservingDisplay:13)
        coordinator.displaysChanged()
        await Task.yield()
        expect(coordinator.catalog.displayInventory.current == nil && coordinator.videoEpoch == nil && coordinator.pointer.cleared,
               true,"topology callback blocks old epoch and pointer geometry")
        expect(coordinator.stops == 0,true,"pending owned geometry refresh does not stop selection")
        coordinator.catalog.displayInventory.update(infos,signatures:identities,frames:newFrames,preservingDisplay:13)
        expect(coordinator.catalog.displayInventory.current?.displayID == 13,true,"same owned identity survives native move")
        expect(coordinator.catalog.displayInventory.contains(selection),false,"old inventory token is rejected after move")
        coordinator.displaysChanged()
        for _ in 0..<20 { await Task.yield() }
        expect(coordinator.restarts == 1 && coordinator.videoEpoch != nil,true,"confirmed native move restarts desktop with fresh epoch")

        var inventory = coordinator.catalog.displayInventory
        inventory.invalidate(preservingDisplay:13)
        inventory.invalidate(preservingDisplay:13)
        inventory.update(infos,signatures:identities,frames:oldFrames,preservingDisplay:13)
        expect(inventory.current?.displayID == 13,true,"repeated topology callbacks retain one pending selection")
        inventory.invalidate(preservingDisplay:13)
        inventory.update(infos,signatures:["physical-uuid","replacement-uuid"],frames:newFrames,preservingDisplay:13)
        expect(inventory.current == nil && inventory.requiresSelection,true,"reused ID with replacement identity requires explicit selection")
        inventory.select(DisplaySelection(displayID:13,inventoryID:inventory.revision!))
        inventory.invalidate(preservingDisplay:13)
        inventory.update([physical],signatures:["physical-uuid"],frames:[oldFrames[0]],preservingDisplay:13)
        expect(inventory.current == nil && inventory.requiresSelection,true,"removed owned display cannot select physical fallback")
        inventory.update(infos,signatures:identities,frames:oldFrames,preservingDisplay:13)
        inventory.select(DisplaySelection(displayID:1,inventoryID:inventory.revision!))
        inventory.invalidate(preservingDisplay:13)
        inventory.update(infos,signatures:identities,frames:newFrames,preservingDisplay:13)
        expect(inventory.current == nil,true,"physical selection keeps existing reselect protection")
        inventory.select(DisplaySelection(displayID:13,inventoryID:inventory.revision!))
        inventory.invalidate(preservingDisplay:13)
        var resized = owned
        resized.width = 1350
        inventory.update([physical,resized],signatures:identities,frames:newFrames,preservingDisplay:13)
        expect(inventory.current == nil,true,"mode change does not retain selection")

        let owner = NSObject()
        let requester = ObjectIdentifier(owner)
        var destroyed = 0
        var recovered: CGRect?
        var failures = 0
        var published: UInt32?
        let managed = ExtendedDesktop(makeDisplay: { _, _ in
            ExtendedDesktop.Resource(id:display.displayID,waitUntilOnline:{ true },
                configure:{ try await AdapterFixture.configure(display) },
                isValid:{ AdapterFixture.valid(display) },
                recoverWindows:{ recovered = AdapterFixture.recoveryBounds(display,lastKnown:oldFrames[1]) },
                destroy:{ destroyed += 1 })
        }, publishID:{ published = $0 }, reportFailure:{ _ in failures += 1 })
        let dimensions = ExtendedDesktop.Dimensions(viewport:Viewport(width:1350,height:976,scale:1))!
        managed.request(requester)
        managed.updateViewport(dimensions,for:requester)
        for _ in 0..<30 { await Task.yield() }
        expect(managed.phase == .ready && published == 13,true,"actual lifecycle publishes initial display")
        display.bounds = remembered
        managed.checkDisplay()
        expect(managed.phase == .ready && destroyed == 0 && failures == 0,true,"actual lifecycle keeps moved display alive")
        managed.release(requester)
        expect(managed.phase == .idle && destroyed == 1 && recovered == remembered,true,"disconnect recovers current moved bounds")
        CoreGraphicsFixture.configuredIDs.removeAll()
        managed.request(requester)
        managed.updateViewport(dimensions,for:requester)
        for _ in 0..<30 { await Task.yield() }
        expect(managed.phase == .ready && display.bounds == remembered && CoreGraphicsFixture.configuredIDs.isEmpty,
               true,"actual reconnect preserves OS restored left arrangement")
        CoreGraphicsFixture.active = 0
        managed.checkDisplay()
        expect(managed.displayID == nil && destroyed == 2 && failures == 1,true,"actual lifecycle still retires genuinely inactive display")
        print("ARRANGEMENT_CHECKS total=\(checked) failed=\(failed.count)")
        if !failed.isEmpty { exit(1) }
    }
}
