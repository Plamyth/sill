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
        let startupBarrier = PhaseBarrier()
        lateRefill.capture.startBarrier = startupBarrier
        let startup = Task { @MainActor in await lateRefill.select(.desktop) }
        await startupBarrier.reached()
        expect(startupBarrier.entered, "invalidation repro holds actual pipeline validation await")
        lateRefill.catalog.displayInventory.invalidate(preservingDisplay:13)
        lateRefill.displaysChanged()
        await settle()
        lateRefill.capture.startBarrier = nil
        startupBarrier.resume()
        await startup.value
        expect(lateRefill.active == .none && lateRefill.videoEpoch == nil,
               "startup rejects invalid inventory before refill")
        refill(lateRefill)
        await settle()
        expect(lateRefill.active == .desktop && lateRefill.videoEpoch != nil && lateRefill.capture.starts == 2,
               "invalidation then startup return then refill preserves owned recovery intent")

        let cleanupPick = make()
        expect(cleanupPick.inputFence.join(9, source:.desktop, switching:false, desktopScope:cleanupPick.desktopScope),
               "scoped pick peer joins original source")
        cleanupPick.inputFence.negotiate(9, supportsScoped:true)
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
        await cleanupPick.picksDelivered(2)
        expect(cleanupPick.pickDeliveries == 2 && cleanupPick.switching,
               "prior select defer delivers queued pick during suspended cleanup")
        cleanupPick.audioBarrier = nil
        cleanupPick.catalog.refreshBarrier = nil
        shutdown.resume()
        await settle()
        expect(cleanupPick.active == .window(123) && cleanupPick.committed.last == .window(123),
               "failed refresh queued window pick survives suspended audio shutdown")

        for outcome in ["none", "disconnect", "legacy", "window", "loss"] {
            let c = make()
            expect(c.inputFence.join(11, source:.desktop, switching:false, desktopScope:c.desktopScope),
                   "inventory-gap/\(outcome) peer joins")
            if outcome != "legacy" { c.inputFence.negotiate(11, supportsScoped:true) }
            let start = PhaseBarrier()
            c.capture.startBarrier = start
            let task = Task { @MainActor in await c.select(.desktop) }
            await start.reached()
            c.catalog.displayInventory.invalidate(preservingDisplay:13)
            c.displaysChanged()
            c.capture.startBarrier = nil
            start.resume()
            await task.value
            expect(c.active == .none && c.videoEpoch == nil,
                   "inventory-gap/\(outcome) invalid startup completes before refill")
            if outcome == "none" { await c.handlePick(.none) }
            if outcome == "window" { await c.handlePick(.window(204)) }
            if outcome == "disconnect" {
                c.inputFence.leave(11)
                c.catalog.clientCount = 0
            }
            if outcome == "loss" {
                c.catalog.displayInventory.update([], signatures:[], frames:[], preservingDisplay:13)
                c.displaysChanged()
            } else { refill(c) }
            await settle()
            expect(c.active == (outcome == "window" ? .window(204) : .none),
                   "inventory-gap/\(outcome) refill respects cancellation or input fence")
            expect(c.capture.starts == (outcome == "window" ? 2 : 1),
                   "inventory-gap/\(outcome) cannot resurrect desktop after cancellation")
        }

        for boundary in ["audio", "capture"] {
            for outcome in ["window", "none", "disconnect", "legacy", "no-pick", "latest"] {
                let c = make()
                let legacyPeer = outcome == "legacy"
                expect(c.inputFence.join(10, source:.desktop, switching:false, desktopScope:c.desktopScope),
                       "\(boundary)/\(outcome) peer joins")
                if !legacyPeer { c.inputFence.negotiate(10, supportsScoped:true) }
                let oldGeneration = c.inputGeneration
                let refresh = PhaseBarrier()
                let stop = PhaseBarrier()
                c.catalog.refreshBarrier = refresh
                c.catalog.refreshResult = false
                move(c, x:-1350)
                await refresh.reached()
                if outcome != "no-pick" { await c.handlePick(.window(201)) }
                if boundary == "audio" { c.audioBarrier = stop } else { c.capture.stopBarrier = stop }
                refresh.resume()
                await stop.reached()
                if outcome != "no-pick" {
                    await c.picksDelivered(2)
                    expect(c.pickDeliveries == 2, "\(boundary)/\(outcome) queued task arrived inside cleanup")
                }
                if outcome == "none" { await c.handlePick(.none) }
                if outcome == "latest" { await c.handlePick(.window(202)) }
                if outcome == "disconnect" {
                    c.inputFence.leave(10)
                    c.catalog.clientCount = 0
                    c.deselectWhenSettled = true
                }
                c.audioBarrier = nil
                c.capture.stopBarrier = nil
                c.catalog.refreshBarrier = nil
                stop.resume()
                await settle()
                let expected: StreamSource = outcome == "latest" ? .window(202) : (outcome == "window" ? .window(201) : .none)
                expect(c.active == expected, "\(boundary)/\(outcome) failed refresh keeps latest permitted intent")
                expect(!c.inputFence.accepts(10, generation:oldGeneration, current:c.inputGeneration,
                                             source:c.active, desktopScope:c.desktopScope),
                       "\(boundary)/\(outcome) old input epoch stays fenced")
                if expected == .none {
                    expect(!c.capture.running && !c.audioLive && c.videoEpoch == nil && c.capture.starts == 0,
                           "\(boundary)/\(outcome) cleanup has no pipeline or audio")
                }
                if legacyPeer {
                    expect(!c.inputFence.allowsSelection(.window(201)), "legacy pin survives cleanup")
                    c.inputFence.leave(10)
                    expect(c.inputFence.allowsSelection(.window(201)), "disconnect alone releases legacy pin")
                }
            }
        }
        let ordinary = make()
        ordinary.active = .window(301)
        ordinary.capture.startBarrier = PhaseBarrier()
        let ordinarySwitch = Task { @MainActor in await ordinary.select(.window(302), bringForward:true) }
        await ordinary.capture.startBarrier!.reached()
        await ordinary.handlePick(.desktop)
        expect(ordinary.pickArrivedWhileSwitching == nil,
               "automatic desktop request still cannot override ordinary window switch")
        await ordinary.handlePick(.window(303))
        let ordinaryBarrier = ordinary.capture.startBarrier!
        ordinary.capture.startBarrier = nil
        ordinaryBarrier.resume()
        await ordinarySwitch.value
        await settle()
        expect(ordinary.active == .window(303), "latest human window pick survives ordinary transition")

        for boundary in ["audio", "capture"] {
            let c = make()
            let refresh = PhaseBarrier()
            let stop = PhaseBarrier()
            c.catalog.refreshBarrier = refresh
            c.catalog.refreshResult = false
            move(c, x:-1350)
            await refresh.reached()
            c.catalog.displayInventory.invalidate(preservingDisplay:13)
            c.displaysChanged()
            if boundary == "audio" { c.audioBarrier = stop } else { c.capture.stopBarrier = stop }
            refresh.resume()
            await stop.reached()
            expect(c.switching && c.restartOf == nil, "refill/\(boundary) holds none cleanup after failed refresh")
            c.catalog.refreshBarrier = nil
            c.catalog.refreshResult = true
            refill(c)
            await settle()
            c.audioBarrier = nil
            c.capture.stopBarrier = nil
            stop.resume()
            await settle()
            expect(c.active == .desktop && c.videoEpoch != nil && c.capture.running,
                   "refill/\(boundary) validated inventory during suspended cleanup restarts desktop")
        }

        let replayed = make()
        let firstStart = PhaseBarrier()
        let replay = PhaseBarrier()
        replayed.active = .window(400)
        replayed.capture.startBarrier = firstStart
        replayed.replayBarrier = replay
        let firstPick = Task { @MainActor in await replayed.select(.window(401), bringForward:true) }
        await firstStart.reached()
        await replayed.handlePick(.window(402))
        replayed.capture.startBarrier = nil
        firstStart.resume()
        await firstPick.value
        await replay.reached()
        let newerStart = PhaseBarrier()
        replayed.capture.startBarrier = newerStart
        let newerPick = Task { @MainActor in await replayed.handlePick(.window(403)) }
        await newerStart.reached()
        replay.resume()
        await settle()
        replayed.capture.startBarrier = nil
        newerStart.resume()
        await newerPick.value
        await settle()
        expect(replayed.active == .window(403) && replayed.committed.last == .window(403),
               "old A replay after new B admission cannot replace B")

        for outcome in ["window", "third", "none", "display", "mac", "automatic", "failure", "fence", "disconnect"] {
            let c = make()
            c.active = .window(500)
            let first = PhaseBarrier()
            let replay = PhaseBarrier()
            c.capture.startBarrier = first
            c.replayBarrier = replay
            let starting = Task { @MainActor in await c.select(.window(501), bringForward:true) }
            await first.reached()
            await c.handlePick(.window(502))
            c.capture.startBarrier = nil
            first.resume()
            await starting.value
            await replay.reached()
            var expected = StreamSource.window(503)
            if outcome == "none" {
                await c.handlePick(.none)
                expected = .none
            } else if outcome == "fence" {
                expect(c.inputFence.join(15, source:c.active, switching:false, desktopScope:c.desktopScope), "replay/fence legacy joins")
                await c.handlePick(.window(503))
                expected = .window(501)
            } else if outcome == "disconnect" {
                c.catalog.clientCount = 0
                await c.select(.none)
                expected = .none
            } else {
                let next = PhaseBarrier()
                c.capture.startBarrier = next
                if outcome == "failure" { c.capture.failStarts = [2]; expected = .none }
                let selection = c.catalog.displayInventory.current!
                let newer = Task { @MainActor in
                    if outcome == "display" { await c.select(.desktop, displaySelection:selection) }
                    else if outcome == "mac" { await c.select(.window(503), bringForward:true) }
                    else { await c.handlePick(.window(503)) }
                }
                await next.reached()
                if outcome == "display" { expected = .desktop }
                if outcome == "third" { await c.handlePick(.window(504)); expected = .window(504) }
                if outcome == "automatic" {
                    let sequence = c.pickSequence
                    await c.handlePick(.desktop)
                    expect(c.pickSequence == sequence, "automatic Desktop during ordinary transition does not admit intent")
                }
                replay.resume()
                await settle()
                c.capture.startBarrier = nil
                next.resume()
                await newer.value
            }
            replay.resume()
            await settle()
            expect(c.active == expected, "replay/\(outcome) respects newest admitted intent")
            expect(!c.committed.contains(.window(502)), "replay/\(outcome) superseded A never commits")
            if outcome == "failure" {
                expect(c.capture.starts == 2 && !c.capture.running && c.videoEpoch == nil,
                       "capture start throws at boundary without stale replay or published epoch")
            }
        }
        for boundary in ["audio", "capture"] {
            for outcome in ["none", "window", "display", "loss", "disconnect", "failure", "fence"] {
                let c = make()
                if outcome == "fence" { _ = c.inputFence.join(16, source:.desktop, switching:false, desktopScope:c.desktopScope) }
                let refresh = PhaseBarrier()
                let stop = PhaseBarrier()
                c.catalog.refreshBarrier = refresh
                c.catalog.refreshResult = false
                move(c, x:-1350)
                await refresh.reached()
                c.catalog.displayInventory.invalidate(preservingDisplay:13)
                c.displaysChanged()
                if boundary == "audio" { c.audioBarrier = stop } else { c.capture.stopBarrier = stop }
                refresh.resume()
                await stop.reached()
                c.catalog.refreshBarrier = nil
                c.catalog.refreshResult = true
                refill(c)
                if outcome == "none" { await c.handlePick(.none) }
                if outcome == "window" { await c.handlePick(.window(601)) }
                if outcome == "display" { await c.select(.desktop, displaySelection:c.catalog.displayInventory.current!) }
                if outcome == "disconnect" { c.catalog.clientCount = 0; c.deselectWhenSettled = true }
                if outcome == "loss" {
                    c.catalog.displayInventory.invalidate(preservingDisplay:13)
                    c.catalog.displayInventory.update([], signatures:[], frames:[], preservingDisplay:13)
                    c.displaysChanged()
                }
                if outcome == "failure" { c.capture.failStarts = [1] }
                c.audioBarrier = nil
                c.capture.stopBarrier = nil
                stop.resume()
                await settle()
                let expected: StreamSource = outcome == "window" ? .window(601) : (outcome == "display" ? .desktop : .none)
                expect(c.active == expected, "refill/\(boundary)/\(outcome) preserves cancellation and fences")
                if expected == .none {
                    expect(!c.capture.running && c.videoEpoch == nil && !c.audioLive,
                           "refill/\(boundary)/\(outcome) publishes no epoch and leaves no live capture or audio")
                }
            }
        }

        for human in [true, false] {
            let c = make()
            c.active = .window(701)
            let start = PhaseBarrier()
            c.capture.startBarrier = start
            let selecting = Task { @MainActor in await c.select(.window(701), bringForward:human) }
            await start.reached()
            let sequence = c.pickSequence
            await c.handlePick(.desktop)
            expect(c.pickSequence == sequence, "same-source/\(human) automatic Desktop never increments user sequence")
            c.capture.startBarrier = nil
            start.resume()
            await selecting.value
            await settle()
            expect(c.active == (human ? .window(701) : .desktop),
                   "same-source/\(human) automatic request respects human admission and internal restart semantics")
        }

        print("RECOVERY_CHECKS total=\(checks) failed=\(failures)")
        if failures != 0 { exit(1) }
    }
}
