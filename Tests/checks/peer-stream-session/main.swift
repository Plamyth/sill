import Foundation
import StreamProtocol

@MainActor
final class FakeCapture: PeerCaptureDriver {
    var onStopped: (() -> Void)?
    var starts = 0
    var stops = 0
    var keyframes = 0
    var rect = CGRect(x: 30, y: 50, width: 800, height: 600)
    var resolveGate: CheckedContinuation<Void, Never>?
    var suspendResolve = false
    var startGate: CheckedContinuation<Void, Never>?
    var suspendStart = false
    var stopOnStarts = 0
    var targetExists = true
    var plans: [(source: StreamSource, config: HostConfig, viewport: Viewport?)] = []
    var preparedEpochs: [UUID] = []
    var frames: ((StreamMessage, UUID) -> Void)?
    func resolve(source: StreamSource, display: DisplaySelection?, identity: String?, config: HostConfig,
                 viewport: Viewport?) async throws -> PeerCaptureDescription {
        plans.append((source, config, viewport))
        if suspendResolve { await withCheckedContinuation { resolveGate = $0 } }
        return PeerCaptureDescription(source: source, bounds: rect, width: 1600, height: 1200,
                                      displayID: display?.displayID, windowPID: nil, title: "격리 화면")
    }
    func start(_ description: PeerCaptureDescription, epoch: VideoEpoch,
               output: @escaping (StreamMessage, UUID) -> Void) async throws {
        starts += 1
        frames = output
        preparedEpochs.append(epoch.id)
        if starts <= stopOnStarts { onStopped?() }
        if suspendStart { await withCheckedContinuation { startGate = $0 } }
    }
    func stop() async { stops += 1 }
    func requestKeyframe() { keyframes += 1 }
    func currentBounds() -> CGRect? { targetExists ? rect : nil }
}

@main
struct Checks {
    @MainActor static func main() async {
        var count = 0
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            count += 1
            if !condition() { failures += 1; print("FAIL \(name)") }
        }
        var inventory = DisplayInventory()
        _ = inventory.update([DisplayInfo(id: 1, name: "주 화면", width: 800, height: 600, isMain: true),
                              DisplayInfo(id: 2, name: "다른 화면", width: 800, height: 600, isMain: false)],
                             signatures: ["physical1/rect", "physical2/rect"])
        let driverA = FakeCapture(), driverB = FakeCapture()
        let a = PeerStreamSession(driver: driverA, configuration: { .standard }, inventory: { inventory })
        let b = PeerStreamSession(driver: driverB, configuration: { .standard }, inventory: { inventory })
        var releaseA = 0, releaseB = 0, commitsA = 0, commitsB = 0
        a.onScopeInvalidated = { releaseA += 1 }; b.onScopeInvalidated = { releaseB += 1 }
        a.commit = { _, _, _ in commitsA += 1 }; b.commit = { _, _, _ in commitsB += 1 }
        func settle() async { for _ in 0..<40 { await Task.yield() } }
        a.select(SourceRequest(source: .window(10), origin: .human))
        b.select(SourceRequest(source: .window(20), origin: .human))
        await settle()
        check(a.source == .window(10), "A keeps window10")
        check(b.source == .window(20), "B keeps window20")
        check(a.epoch?.id != b.epoch?.id, "distinct peer epochs")
        check(a.generation != b.generation, "distinct generations")
        check(a.selectionRevision != b.selectionRevision, "distinct CAS scopes")
        let bEpoch = b.epoch!, bRevision = b.selectionRevision
        let aEpoch = a.epoch!, oldAdmission = a.admission
        check(a.inputRect(generation: aEpoch.generation, epoch: aEpoch.id) != nil, "A own input accepted")
        check(b.inputRect(generation: aEpoch.generation, epoch: aEpoch.id) == nil, "A input rejected by B")
        a.select(SourceRequest(source: .window(11), origin: .human))
        check(a.inputRect(generation: aEpoch.generation, epoch: aEpoch.id) == nil, "old input blocked before async work")
        var oldPublish = false; oldAdmission.publish { oldPublish = true }
        check(!oldPublish, "old encoder publication invalidated synchronously")
        await settle()
        check(a.source == .window(11), "A new selection commits")
        check(b.epoch == bEpoch && b.selectionRevision == bRevision, "A selection leaves B epoch and CAS intact")
        check(driverB.starts == 1 && releaseB == 1, "A selection never restarts or releases B")
        let starts = driverA.starts
        a.select(SourceRequest(source: .window(11), origin: .human)); await settle()
        check(driverA.starts == starts, "same source repeat keeps capture")
        a.updateViewport(Viewport(width: 300, height: 400, scale: 2, fps: 60)); await settle()
        check(driverA.starts == starts, "panel dimensions never resize or restart source")
        a.updateViewport(Viewport(width: 300, height: 400, scale: 2, fps: 30)); await settle()
        check(driverA.starts == starts + 1, "A rate changes only A encoder")
        check(driverB.starts == 1 && b.epoch == bEpoch, "B independent of A viewport")
        driverA.suspendResolve = true
        a.select(SourceRequest(source: .window(30), origin: .human)); await settle()
        check(driverA.resolveGate != nil, "delayed production resolve in progress")
        a.select(SourceRequest(source: .window(31), origin: .human))
        driverA.suspendResolve = false; driverA.resolveGate?.resume(); driverA.resolveGate = nil
        await settle()
        check(a.source == .window(31), "late old resolve cannot overwrite newest intent")
        check(b.epoch == bEpoch, "late A resolve never alters B")
        let epoch = a.epoch!
        driverA.rect.origin.x += 100
        check(a.inputRect(generation: epoch.generation, epoch: epoch.id) == nil, "moved source blocks old geometry input")
        a.catalogChanged(); await settle()
        check(a.epoch?.geometry.x == Double(driverA.rect.minX), "own geometry change refreshes own epoch")
        check(b.epoch == bEpoch, "geometry refresh leaves B intact")
        var listA = WindowList(macName: "격리", windows: [], active: .none)
        var listB = listA
        a.decorate(&listA); b.decorate(&listB)
        check(listA.active == .window(31) && listB.active == .window(20), "targeted catalogs keep distinct sources")
        check(listA.independentStreams == 1 && listA.sourceSelectionEffects == 0, "explicit independent observational capability")
        check(listA.videoEpoch != listB.videoEpoch, "catalogs carry own epochs")
        await a.close()
        check(a.isClosed && a.epoch == nil, "A close invalidates own scope")
        check(b.epoch == bEpoch && driverB.stops == 1, "A close leaves B capture running")
        let closedRevision = a.selectionRevision
        a.select(SourceRequest(source: .window(77), origin: .human)); await settle()
        check(a.selectionRevision == closedRevision && a.epoch == nil, "closed incarnation cannot restart")
        let c = PeerStreamSession(driver: FakeCapture(), configuration: { .standard }, inventory: { inventory })
        check(c.incarnation != a.incarnation, "reconnect has new incarnation")
        let selection = DisplaySelection(displayID: 1, inventoryID: inventory.revision!, origin: .automatic,
                                         selectionRevision: c.selectionRevision)
        c.selectDisplay(selection); await settle()
        check(c.source == .desktop && c.currentDisplayID == 1, "empty peer automatic desktop CAS")
        let current = c.epoch
        c.selectDisplay(selection); await settle()
        check(c.epoch == current, "old automatic CAS not replayed")
        check(b.epoch == bEpoch, "C automatic selection does not join or overwrite B")

        let stoppedDriver = FakeCapture()
        stoppedDriver.stopOnStarts = 1
        let stopped = PeerStreamSession(driver: stoppedDriver, configuration: { .standard }, inventory: { inventory })
        var stoppedCommits: [UUID] = [], stoppedResets: [UUID?] = []
        stopped.commit = { epoch, _, _ in stoppedCommits.append(epoch.id) }
        stopped.reset = { stoppedResets.append($0) }
        stopped.select(SourceRequest(source: .window(40), origin: .human)); await settle()
        check(stoppedDriver.starts == 2 && stoppedCommits.count == 1,
              "start-time stop recovers once before commit; starts=\(stoppedDriver.starts), commits=\(stoppedCommits.count)")
        check(stoppedCommits.first != stoppedDriver.preparedEpochs.first,
              "stopped start epoch is never committed")
        check(!stoppedResets.contains(where: { $0 == nil }), "no reset before the first prepared epoch")
        check(stoppedResets.compactMap { $0 } == Array(stoppedDriver.preparedEpochs.prefix(1)),
              "failed prepared epoch is reset with its exact UUID")
        await stopped.close()

        let brokenDriver = FakeCapture()
        brokenDriver.stopOnStarts = .max
        let broken = PeerStreamSession(driver: brokenDriver, configuration: { .standard }, inventory: { inventory })
        var brokenCommits = 0
        broken.commit = { _, _, _ in brokenCommits += 1 }
        broken.select(SourceRequest(source: .window(41), origin: .human)); await settle()
        check(brokenDriver.starts == 2 && broken.epoch == nil && brokenCommits == 0,
              "repeated start-time stop terminates recovery; starts=\(brokenDriver.starts), commits=\(brokenCommits)")
        check(broken.state.failure != nil, "failed recovery reports unavailable source")
        await broken.close()

        var latestConfig = HostConfig.standard
        let pendingDriver = FakeCapture()
        pendingDriver.suspendResolve = true
        let pending = PeerStreamSession(driver: pendingDriver, configuration: { latestConfig }, inventory: { inventory })
        pending.select(SourceRequest(source: .window(50), origin: .human)); await settle()
        latestConfig.bitrate = 8_000_000
        pending.configurationChanged()
        pending.updateViewport(Viewport(width: 400, height: 300, scale: nil, fps: 30))
        pendingDriver.suspendResolve = false
        pendingDriver.resolveGate?.resume(); pendingDriver.resolveGate = nil
        await settle()
        check(pendingDriver.plans.last?.config.bitrate == 8_000_000 && pendingDriver.plans.last?.viewport?.fps == 30,
              "pending resolve converges to latest config and FPS; bitrate=\(pendingDriver.plans.last?.config.bitrate ?? -1), fps=\(pendingDriver.plans.last?.viewport?.fps ?? -1)")
        pendingDriver.suspendStart = true
        pending.select(SourceRequest(source: .window(51), origin: .human)); await settle()
        check(pendingDriver.startGate != nil, "production start suspended for settings update")
        latestConfig.bitrate = 6_000_000
        pending.configurationChanged()
        pending.updateViewport(Viewport(width: 400, height: 300, scale: nil, fps: 24))
        pendingDriver.suspendStart = false
        pendingDriver.startGate?.resume(); pendingDriver.startGate = nil
        await settle()
        check(pendingDriver.plans.last?.config.bitrate == 6_000_000 && pendingDriver.plans.last?.viewport?.fps == 24,
              "pending start converges to latest config and FPS")
        pendingDriver.suspendResolve = true
        pending.select(SourceRequest(source: .window(52), origin: .human)); await settle()
        latestConfig.bitrate = 5_000_000
        pending.configurationChanged()
        pending.select(SourceRequest(source: .window(53), origin: .human))
        pendingDriver.suspendResolve = false
        pendingDriver.resolveGate?.resume(); pendingDriver.resolveGate = nil
        await settle()
        check(pending.source == .window(53) && pendingDriver.plans.last?.config.bitrate == 5_000_000,
              "settings convergence never restores an older human selection")
        await pending.close()

        let displayDriver = FakeCapture()
        let displayPeer = PeerStreamSession(driver: displayDriver, configuration: { .standard }, inventory: { inventory })
        displayPeer.selectDisplay(DisplaySelection(displayID: 1, inventoryID: inventory.revision!)); await settle()
        let displayEpoch = displayPeer.epoch, displayStarts = displayDriver.starts
        inventory.invalidate()
        displayPeer.catalogChanged(); b.catalogChanged(); await settle()
        check(displayPeer.epoch == displayEpoch && displayDriver.starts == displayStarts,
              "inventory observation preserves the selected peer epoch")
        _ = inventory.update([DisplayInfo(id: 1, name: "주 화면", width: 800, height: 600, isMain: true),
                              DisplayInfo(id: 2, name: "다른 화면", width: 900, height: 600, isMain: false)],
                             signatures: ["physical1/rect", "physical2/changed"])
        displayPeer.catalogChanged(); await settle()
        check(displayPeer.epoch == displayEpoch && displayDriver.starts == displayStarts,
              "another display topology change preserves selected physical capture")
        _ = inventory.update(inventory.infos, signatures: ["replacement/rect", "physical2/changed"])
        displayPeer.catalogChanged(); await settle()
        check(displayPeer.source == .none && displayPeer.epoch == nil, "selected physical replacement stops its own scope")
        check(b.epoch == bEpoch && driverB.starts == 1, "display replacement leaves other peer capture intact")
        await displayPeer.close()

        let launched = PeerStreamSession(driver: FakeCapture(), configuration: { .standard }, inventory: { inventory })
        let launch = launched.beginLaunch("test.delayed")
        launched.finishLaunch(launch, windowID: nil)
        launched.finishLaunch(launch, windowID: 60); await settle()
        check(launched.source == .window(60), "launch completion without a window keeps the launch intent")
        let superseded = launched.beginLaunch("test.cancelled")
        launched.select(SourceRequest(source: .window(60), origin: .human))
        launched.finishLaunch(superseded, windowID: 61); await settle()
        check(launched.source == .window(60), "even a same-source human selection cancels a pending launch")
        await launched.close()
        await b.close(); await c.close()
        check(commitsA >= 4 && commitsB == 1 && releaseA > releaseB, "production callbacks remain peer scoped")
        if failures > 0 { print("FAIL \(failures) of \(count) production peer stream session checks"); exit(1) }
        print("PASS \(count) production peer stream session checks; inert capture and transport; no host or device effects")
    }
}
