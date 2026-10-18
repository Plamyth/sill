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
        print("RECOVERY_CHECKS total=\(checks) failed=\(failures)")
        if failures != 0 { exit(1) }
    }
}
