import Foundation
import PencilKit
import AppKit

// Actual Store and extracted Workspace members; UI dispatch, renderer and output type are fixtures.
@MainActor enum UIScreen { struct Screen { let scale = 1.0 }; static let main = Screen() }
struct RenderedSceneFile {
    enum Format { case png, pdf }
    let data: Data
    init(png: Data, size: CGSize, format: Format, filename: String) throws { data = png }
}
@MainActor enum SceneRenderer {
    static var continuation: CheckedContinuation<Data?, Never>?
    static func png(scene: CanvasScene) async -> Data? {
        await withCheckedContinuation { continuation = $0 }
    }
}
@MainActor final class ExportBoundary {
    let store: CanvasStore
    init(_ store: CanvasStore) { self.store = store }
    var commentEditorOpen = false, connectionOpen = false, dictationOpen = false, exportOpen = false
    var handwritingSearchOpen = false, importOpen = false, inkSpacingOpen = false, inkTextDeleteOpen = false
    var inspectorOpen = false, proposalInputBusy = false, vaultOpen = false
    var workspaceDocumentsOpen = false, workspacePickerOpen = false
    var canvasEditorSheet: Any?, expandedCard: Any?
    private var renderedExport: RenderedExportState = .idle
    /* WORKSPACE_MEMBERS */
    var presented: Bool { /* EXPORTER_GETTER */ }
    var allowed: Bool { canPresentRenderedExport }
    var ready: Bool { renderedExport.document != nil }
    func start() { prepareRenderedExport(.png) }
    func presentationGateChanged() {
        let allowed = canPresentRenderedExport
        /* GATE_CHANGE */
    }
}

@main struct ExportChecks {
    @MainActor static func waitForRenderer() async -> CheckedContinuation<Data?, Never> {
        for _ in 0..<1000 {
            if let continuation = SceneRenderer.continuation {
                SceneRenderer.continuation = nil
                return continuation
            }
            await Task.yield()
        }
        fatalError("render continuation absent")
    }
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor static func main() async throws {
        guard case .isolated = CanvasRuntime.launch else { fatalError("isolated runtime required") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sceneURL = try CanvasRuntime.stateURL(.scene)
        var scene = CanvasScene()
        let id = UUID()
        scene.nodes = [.init(id: id, kind: .note, frame: .init(x: 10, y: 10, width: 200, height: 100),
                             text: "원문 e\u{301}\r\n", confidence: .confirmed, sourceStrokeIds: [])]
        try CanvasLocalFile.write(CanvasFileWorkspace.bytes(scene), to: sceneURL)
        let store = CanvasStore(); store.mode = .select; store.selectedNode = id
        let before = try Data(contentsOf: sceneURL), sha = try CanvasFileWorkspace.sceneSHA(store.scene)
        let boundary = ExportBoundary(store), png = Data("controlled render completion".utf8)
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); checks.append(name); print("PASS \(name)")
        }
        let first = store.beginCardTagInput()!
        boundary.start()
        await settle()
        check(!boundary.allowed && !boundary.ready && SceneRenderer.continuation == nil,
              "active tag input prevents render request")
        store.cancelCardTagInput(sessionID: first)

        boundary.start()
        let pending = await waitForRenderer()
        let second = store.beginCardTagInput()!
        check(!boundary.allowed && !boundary.presented, "tag input revokes live exporter binding")
        // Exercise completion-time gate even before SwiftUI's onChange dispatch.
        pending.resume(returning: png); await settle()
        check(!boundary.ready && !boundary.presented && store.cardTagInputBusy,
              "late PNG completion cannot present over tag input")
        store.cancelCardTagInput(sessionID: second)

        boundary.start()
        let cancelled = await waitForRenderer()
        let third = store.beginCardTagInput()!
        boundary.presentationGateChanged()
        store.cancelCardTagInput(sessionID: third)
        cancelled.resume(returning: png); await settle()
        check(!boundary.ready && !boundary.presented, "open then cancel tag input cannot resurrect old render")

        boundary.start()
        let ready = await waitForRenderer(); ready.resume(returning: png); await settle()
        check(boundary.ready && boundary.presented, "fresh explicit export remains reachable")
        let fourth = store.beginCardTagInput()!
        check(!boundary.presented, "ready exporter binding closes during tag ownership")
        boundary.presentationGateChanged()
        store.cancelCardTagInput(sessionID: fourth)
        check(!boundary.ready && !boundary.presented, "ready document is discarded without deferred reappearance")
        check(try CanvasFileWorkspace.sceneSHA(store.scene) == sha && Data(contentsOf: sceneURL) == before,
              "ownership transitions preserve exact scene and cached original bytes")
        let result: [String: Any] = ["passed": true, "checks": checks, "actualStore": true,
            "actualWorkspaceMembers": true, "actualSwiftUI": false, "actualRenderer": false,
            "deviceGUIHostServiceLiveVaultEffects": 0]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("export-ownership-result.json"))
    }
}
