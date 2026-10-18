import Foundation
import CoreGraphics

@main struct RecoveryChecks {
    @MainActor static func main() async {
        var checks = 0
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL \(label)") }
        }
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        func make() -> RecoveryCoordinator {
            let c = RecoveryCoordinator()
            c.catalog.displayInventory.update([DisplayInfo(id:13,name:"CCR",width:2700,height:1952,isMain:false)], signatures:["owned"], frames:[c.catalog.bounds])
            c.catalog.displayInventory.select(c.catalog.displayInventory.current!)
            return c
        }
        func move(_ c: RecoveryCoordinator, x: Double) {
            c.catalog.displayInventory.invalidate(preservingDisplay:13)
            c.displaysChanged()
            c.catalog.bounds.origin.x = x
            c.catalog.displayInventory.update(c.catalog.displayInventory.infos, signatures:["owned"], frames:[c.catalog.bounds], preservingDisplay:13)
            c.displaysChanged()
        }
        let legacy = make()
        let old = legacy.catalog.displayInventory.current!
        expect(legacy.inputFence.join(7,source:.desktop,switching:false,desktopScope:legacy.desktopScope), "legacy joins original revision")
        move(legacy,x:-1350)
        await settle()
        expect(!legacy.catalog.displayInventory.contains(old), "move rejects old inventory")
        expect(!legacy.inputFence.allowsSelection(.desktop,desktopScope:legacy.desktopScope), "legacy pin still refuses new revision")
        expect(legacy.active == .none && !legacy.capture.running && !legacy.audioLive, "refused retained restart stops capture and revokes audio")
        expect(legacy.videoEpoch == nil, "refused restart cannot publish epoch")
        expect(!legacy.inputFence.accepts(7,generation:nil,current:legacy.inputGeneration,source:legacy.active,desktopScope:legacy.desktopScope), "old unscoped input remains refused")

        let delayed = make()
        delayed.capture.pauseNext = true
        let restart = Task { @MainActor in await delayed.select(.desktop) }
        for _ in 0..<100 where delayed.capture.waiter == nil { await Task.yield() }
        expect(delayed.capture.waiter != nil, "production select reaches delayed capture start")
        move(delayed,x:-1350)
        await settle()
        expect(delayed.videoEpoch == nil, "geometry change invalidates epoch during start")
        delayed.capture.resume()
        await restart.value
        await settle()
        expect(delayed.active == .desktop && delayed.videoEpoch != nil && delayed.capture.running && delayed.capture.starts == 2, "delayed stale start recovers with fresh inventory")

        let picked = make()
        picked.capture.pauseNext = true
        let switching = Task { @MainActor in await picked.select(.desktop) }
        for _ in 0..<100 where picked.capture.waiter == nil { await Task.yield() }
        move(picked,x:-1350)
        await settle()
        await picked.handlePick(.window(42))
        picked.capture.resume()
        await switching.value
        await settle()
        expect(picked.active == .window(42) && picked.committed == [.window(42)], "late user window selection overrides queued desktop restore")
        expect(picked.capture.starts == 2, "cancelled restore does not start another desktop pipeline")
        let restoring = make()
        restoring.capture.pauseNext = true
        restoring.capture.pauseStarts = [2]
        let original = Task { @MainActor in await restoring.select(.desktop) }
        for _ in 0..<100 where restoring.capture.waiter == nil { await Task.yield() }
        move(restoring,x:-1350)
        await settle()
        restoring.capture.resume()
        await original.value
        await settle()
        expect(restoring.capture.starts == 2 && restoring.capture.waiter != nil, "queued restore reaches its delayed capture start")
        await restoring.handlePick(.window(84))
        restoring.capture.resume()
        await settle()
        expect(restoring.active == .window(84), "user pick during queued restore wins after capture completes")

        let repeated = make()
        repeated.capture.pauseNext = true
        repeated.capture.pauseStarts = [2]
        let first = Task { @MainActor in await repeated.select(.desktop) }
        for _ in 0..<100 where repeated.capture.waiter == nil { await Task.yield() }
        move(repeated,x:-1350)
        await settle()
        repeated.capture.resume()
        await first.value
        await settle()
        expect(repeated.capture.starts == 2 && repeated.capture.waiter != nil, "second geometry event occurs during restoration")
        move(repeated,x:0)
        await settle()
        repeated.capture.resume()
        await settle()
        expect(repeated.active == .desktop && repeated.videoEpoch != nil && repeated.capture.starts == 3,
               "geometry refresh during queued restore recovers latest revision")

        legacy.inputFence.leave(7)
        await legacy.select(.desktop)
        expect(legacy.active == .desktop && legacy.videoEpoch != nil, "disconnect releases legacy pin and permits explicit fresh selection")

        let leaving = make()
        leaving.capture.pauseNext = true
        let lastClient = Task { @MainActor in await leaving.select(.desktop) }
        for _ in 0..<100 where leaving.capture.waiter == nil { await Task.yield() }
        move(leaving,x:-1350)
        await settle()
        leaving.catalog.clientCount = 0
        leaving.deselectWhenSettled = true
        leaving.capture.resume()
        await lastClient.value
        await settle()
        expect(leaving.active == .none && leaving.capture.starts == 1, "last client leaving cancels pending restoration")

        let lost = make()
        lost.capture.pauseNext = true
        let lostStart = Task { @MainActor in await lost.select(.desktop) }
        for _ in 0..<100 where lost.capture.waiter == nil { await Task.yield() }
        move(lost,x:-1350)
        await settle()
        lost.catalog.displayInventory.invalidate(preservingDisplay:13)
        lost.catalog.displayInventory.update([],signatures:[],frames:[],preservingDisplay:13)
        lost.displaysChanged()
        await settle()
        lost.capture.resume()
        await lostStart.value
        await settle()
        expect(lost.active == .none && !lost.capture.running && !lost.audioLive && lost.capture.starts == 1,
               "actual display loss cancels queued restore and keeps capture stopped")

        func refill(_ c: RecoveryCoordinator) {
            c.catalog.bounds.origin.x = -1350
            c.catalog.displayInventory.update(c.catalog.displayInventory.infos, signatures:["owned"],
                                             frames:[c.catalog.bounds], preservingDisplay:13)
            c.displaysChanged()
        }
        let lateRefill = make()
        lateRefill.capture.pauseNext = true
        let startup = Task { @MainActor in await lateRefill.select(.desktop) }
        for _ in 0..<100_000 where lateRefill.capture.waiter == nil { await Task.yield() }
        expect(lateRefill.capture.waiter != nil, "invalidation repro holds actual pipeline validation await")
        lateRefill.catalog.displayInventory.invalidate(preservingDisplay:13)
        lateRefill.displaysChanged()
        await settle()
        lateRefill.capture.resume()
        await startup.value
        expect(lateRefill.active == .none && lateRefill.videoEpoch == nil,
               "startup rejects invalid inventory before refill")
        refill(lateRefill)
        await settle()
        expect(lateRefill.active == .desktop && lateRefill.videoEpoch != nil && lateRefill.capture.starts == 2,
               "invalidation then startup return then refill preserves owned recovery intent")

        let cleanupPick = make()
        let refresh = PhaseBarrier()
        let shutdown = PhaseBarrier()
        cleanupPick.catalog.refreshBarrier = refresh
        cleanupPick.catalog.refreshResult = false
        move(cleanupPick, x:-1350)
        await refresh.reached()
        await cleanupPick.handlePick(.window(123))
        cleanupPick.audioBarrier = shutdown
        refresh.resume()
        await shutdown.reached()
        for _ in 0..<100_000 where cleanupPick.pickDeliveries < 2 { await Task.yield() }
        expect(cleanupPick.pickDeliveries == 2 && cleanupPick.switching,
               "prior select defer delivers queued pick during suspended cleanup")
        cleanupPick.audioBarrier = nil
        cleanupPick.catalog.refreshBarrier = nil
        shutdown.resume()
        await settle()
        expect(cleanupPick.active == .window(123) && cleanupPick.committed.last == .window(123),
               "failed refresh queued window pick survives suspended audio shutdown")

        print("RECOVERY_CHECKS total=\(checks) failed=\(failures)")
        if failures != 0 { exit(1) }
    }
}
