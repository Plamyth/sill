import Foundation
import PencilKit
import AppKit

@MainActor
final class SuspendedRecognition {
    var input: PKDrawing?
    private var continuation: CheckedContinuation<String?, Never>?

    func recognize(_ drawing: PKDrawing) async -> String? {
        input = drawing
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitForInput() async {
        while input == nil { await Task.yield() }
    }

    func finish(_ text: String?) {
        continuation!.resume(returning: text)
        continuation = nil
    }
}

@main
struct HandwritingRaceCheck {
    @MainActor static func main() async throws {
        let expectedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        guard support.path.hasPrefix(expectedHome + "/") else {
            fatalError("Refusing to access real application support: \(support.path)")
        }
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(message)")
        }
        func drawing(_ x: CGFloat) -> PKDrawing {
            let points = [CGPoint(x: x, y: 20), CGPoint(x: x + 20, y: 50)].enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                    size: CGSize(width: 3, height: 3), opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
            }
            let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1))
            return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
        }
        func store(_ ink: PKDrawing) -> CanvasStore {
            let store = CanvasStore()
            store.scene = CanvasScene()
            store.drawing = PKDrawing()
            store.updateDrawing(ink)
            return store
        }
        let original = drawing(10)
        let changed = drawing(200)

        let edited = store(original)
        let editGate = SuspendedRecognition()
        let editTask = Task { await edited.proposeHandwriting(recognize: editGate.recognize) }
        await editGate.waitForInput()
        check(editGate.input == original, "recognizer received original SDK drawing")
        edited.updateDrawing(changed)
        let editedScene = edited.scene
        editGate.finish("original text")
        await editTask.value
        check(edited.scene == editedScene, "ink mutation rejects stale proposal")
        check(edited.drawing == changed, "ink mutation preserves current ink")

        let imported = store(original)
        let importGate = SuspendedRecognition()
        let importTask = Task { await imported.proposeHandwriting(recognize: importGate.recognize) }
        await importGate.waitForInput()
        var replacement = CanvasScene()
        replacement.drawingBase64 = changed.dataRepresentation().base64EncodedString()
        try imported.importScene(replacement)
        let importedScene = imported.scene
        importGate.finish("old scene text")
        await importTask.value
        check(imported.scene == importedScene, "import rejects previous scene recognition")
        check(imported.drawing == changed, "import preserves imported ink")

        let overlapping = store(original)
        let first = SuspendedRecognition(), second = SuspendedRecognition()
        let firstTask = Task { await overlapping.proposeHandwriting(recognize: first.recognize) }
        await first.waitForInput()
        let secondTask = Task { await overlapping.proposeHandwriting(recognize: second.recognize) }
        await second.waitForInput()
        second.finish("newest")
        await secondTask.value
        let newest = overlapping.proposedNode
        first.finish("oldest")
        await firstTask.value
        check(overlapping.scene.nodes.count == 1 && overlapping.proposalText == "newest" &&
            overlapping.proposedNode == newest, "out of order completion keeps latest proposal")

        let selected = store(original)
        selected.addNode(.note)
        let selectionGate = SuspendedRecognition()
        let selectionTask = Task { await selected.proposeHandwriting(recognize: selectionGate.recognize) }
        await selectionGate.waitForInput()
        selected.proposedNode = selected.selectedNode
        selected.proposalText = "user editing this proposal"
        let selectedScene = selected.scene
        let selectedProposal = selected.proposedNode
        selectionGate.finish("late text")
        await selectionTask.value
        check(selected.scene == selectedScene && selected.proposedNode == selectedProposal &&
            selected.proposalText == "user editing this proposal", "late recognition preserves user proposal selection")

        for action in ["selection", "proposal text", "tool", "same scene import"] {
            let editing = store(original)
            editing.addNode(.note)
            editing.addNode(.note)
            let gate = SuspendedRecognition()
            let task = Task { await editing.proposeHandwriting(recognize: gate.recognize) }
            await gate.waitForInput()
            switch action {
            case "selection": editing.select(editing.scene.nodes.first!.id)
            case "proposal text": editing.proposalText = "user's correction"
            case "tool": editing.mode = .eraser
            default: try editing.importScene(editing.scene)
            }
            let sceneBefore = editing.scene
            let selectionBefore = editing.selectedNode
            let proposalBefore = editing.proposedNode
            let textBefore = editing.proposalText
            let modeBefore = editing.mode
            let statusBefore = editing.status
            gate.finish("late result")
            await task.value
            check(editing.scene == sceneBefore && editing.selectedNode == selectionBefore &&
                editing.proposedNode == proposalBefore && editing.proposalText == textBefore &&
                editing.mode == modeBefore && editing.status == statusBefore,
                "\(action) invalidates pending recognition")
        }

        let latestOnly = store(original)
        let earlier = SuspendedRecognition(), later = SuspendedRecognition()
        let earlierTask = Task { await latestOnly.proposeHandwriting(recognize: earlier.recognize) }
        await earlier.waitForInput()
        let laterTask = Task { await latestOnly.proposeHandwriting(recognize: later.recognize) }
        await later.waitForInput()
        earlier.finish("superseded")
        await earlierTask.value
        check(latestOnly.scene.nodes.isEmpty, "new request supersedes old result before either publishes")
        later.finish("latest result")
        await laterTask.value
        check(latestOnly.scene.nodes.count == 1 && latestOnly.proposalText == "latest result",
            "latest request can publish after superseded completion")

        let staleFailure = store(original)
        let failureGate = SuspendedRecognition()
        let failureTask = Task { await staleFailure.proposeHandwriting(recognize: failureGate.recognize) }
        await failureGate.waitForInput()
        staleFailure.updateDrawing(changed)
        let currentStatus = staleFailure.status
        failureGate.finish(nil)
        await failureTask.value
        check(staleFailure.status == currentStatus, "stale empty result preserves current status")

        let normal = store(original)
        let normalGate = SuspendedRecognition()
        let normalTask = Task { await normal.proposeHandwriting(recognize: normalGate.recognize) }
        await normalGate.waitForInput()
        normalGate.finish("recognized text")
        await normalTask.value
        let proposal = normal.scene.nodes.last!
        check(proposal.sourceStrokeIds == original.strokes.map(\.id), "proposal retains recognized stroke IDs")
        check(proposal.frame.x == original.bounds.midX && proposal.frame.y == original.bounds.midY,
            "proposal uses recognized drawing bounds")
        check(normal.drawing == original && normal.scene.strokes.map(\.id) == original.strokes.map(\.id),
            "successful recognition preserves original ink")
        normal.proposalText = "corrected text"
        normal.confirmProposal()
        check(normal.scene.nodes.last!.text == "corrected text" &&
            normal.scene.nodes.last!.sourceStrokeIds == original.strokes.map(\.id),
            "confirmation preserves original provenance")

        if CommandLine.arguments.contains("--sdk-smoke") {
            let sdkStore = store(original)
            await sdkStore.proposeHandwriting()
            check(sdkStore.drawing == original, "real PKStrokeRecognizer path preserves original ink")
            print("SDK recognition completed; proposal count \(sdkStore.scene.nodes.count)")
        }

        print("RESULT \(checks) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
