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
    var frames: ((StreamMessage, UUID) -> Void)?
    func resolve(source: StreamSource, display: DisplaySelection?, identity: String?, config: HostConfig,
                 viewport: Viewport?) async throws -> PeerCaptureDescription {
        if suspendResolve { await withCheckedContinuation { resolveGate = $0 } }
        return PeerCaptureDescription(source: source, bounds: rect, width: 1600, height: 1200,
                                      displayID: display?.displayID, windowPID: nil, title: "격리 화면")
    }
    func start(_ description: PeerCaptureDescription, epoch: VideoEpoch,
               output: @escaping (StreamMessage, UUID) -> Void) async throws { starts += 1; frames = output }
    func stop() async { stops += 1 }
    func requestKeyframe() { keyframes += 1 }
    func currentBounds() -> CGRect? { rect }
}

@main
struct Checks {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name); count += 1
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
        await b.close(); await c.close()
        check(commitsA >= 4 && commitsB == 1 && releaseA > releaseB, "production callbacks remain peer scoped")
        print("PASS \(count) production peer stream session checks; inert capture and transport; no host or device effects")
    }
}
