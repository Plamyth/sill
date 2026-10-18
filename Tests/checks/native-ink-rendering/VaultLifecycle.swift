import Foundation
import PencilKit

struct VScene: Equatable { var id = UUID(); var revision = 1 }
@MainActor final class VStore { var scene = VScene(); var drawing = PKDrawing(); var status = "" }
struct VRemote { var sceneSha256: String; var noteSha256: String }
@MainActor final class VEffects {
    var read: (() async -> VRemote?)?
    var write: (() async -> VRemote)?
    var writes: [(UUID,String,String?,Int)] = []
    var checkpoints: [(UUID,String,String?)] = []
}
struct VConnection {
    let address: String
    let effects: VEffects
    @MainActor func vaultCanvas(id: UUID) async throws -> VRemote? {
        if let read = effects.read { return await read() }
        return VRemote(sceneSha256:"prior",noteSha256:"prior-note")
    }
    @MainActor func saveVaultCanvas(scene: VScene,imagePNG: Data,baseSha256: String?) async throws -> VRemote {
        effects.writes.append((scene.id,address,baseSha256,scene.revision))
        return await effects.write?() ?? VRemote(sceneSha256:"saved",noteSha256:"saved-note")
    }
}
@MainActor enum VRenderer {
    static var draw: (() async -> Data?)?
    static func png(scene: VScene) async -> Data? { await draw?() ?? Data([1]) }
}
enum VPacket { static func sha(_ data: Data) -> String { String(decoding:data,as:UTF8.self) } }
@MainActor final class VGate {
    private(set) var entered = false
    private var release: CheckedContinuation<Void,Never>?
    func pause() async { entered = true; await withCheckedContinuation { release = $0 } }
    func resume() { release?.resume(); release = nil }
}
@MainActor final class VHarness {
    let store = VStore()
    let effects = VEffects()
    var relayAddress = "X"
    var relayToken = "token-X"
    var canvasVaultEnabled = true
    var syncedSceneSha: String? = "prior"
    var canvasNoteSha: String? = "prior-note"
    var pendingSceneSha: String?
    var canvasVaultBlocked = false
    var canvasSyncBusy = false
    var vaultSceneID: UUID?
    var vaultSyncAddress: String? = "X"
    var relay: VConnection { VConnection(address:relayAddress,effects:effects) }
    init() { vaultSceneID = store.scene.id }
    func sceneBytes() throws -> Data { Data("local-\(store.scene.revision)".utf8) }
    func saveCanvasVaultCheckpoint() throws { effects.checkpoints.append((store.scene.id,relayAddress,pendingSceneSha)) }
    func remoteCanvasIsPrefix(_ remote: VRemote,of local: VScene,drawing: PKDrawing) -> Bool { false }
    /*ACTUAL_SYNC_METHOD*/
}

extension CanvasBridgeUITests {
    @MainActor func testCanvasVaultRenderLifecycle20261019() async {
        var checks = 0
        func check(_ result: Bool,_ name: String) { checks += 1; XCTAssertTrue(result,name) }
        for change in ["scene","address","token","disabled","cancelled","cas","same-scene-edit"] {
            let h = VHarness(); let original = h.store.scene.id
            let gate = VGate()
            VRenderer.draw = { await gate.pause(); return Data([1]) }
            let task = Task { await h.synchronizeCanvasToVault() }
            for _ in 0..<1000 { if gate.entered { break }; await Task.yield() }
            check(gate.entered,"render gate entered \(change)")
            switch change {
            case "scene": h.store.scene = VScene()
            case "address": h.relayAddress = "Y"
            case "token": h.relayToken = "token-Y"
            case "disabled": h.canvasVaultEnabled = false
            case "cancelled": task.cancel()
            case "cas": h.canvasNoteSha = "newer-note"
            default: h.store.scene.revision += 1
            }
            await h.synchronizeCanvasToVault()
            check(h.vaultSceneID == original && h.vaultSyncAddress == "X","replacement must not reset a busy operation")
            gate.resume(); await task.value
            if change == "same-scene-edit" {
                check(h.effects.writes.count == 1 && h.effects.writes[0].3 == 1,"save frozen earlier revision")
                check(h.effects.writes.first?.1 == "X" && h.effects.writes.first?.2 == "prior-note","bound relay and CAS")
            } else {
                check(h.effects.writes.isEmpty,"superseded render must not write \(change)")
                check(h.effects.checkpoints.isEmpty,"superseded render must not checkpoint \(change)")
            }
            check(!h.canvasSyncBusy,"busy released \(change)")
        }
        VRenderer.draw = nil
        do {
            let h = VHarness(); let gate = VGate()
            h.effects.read = { await gate.pause(); return VRemote(sceneSha256:"other",noteSha256:"other-note") }
            let task = Task { await h.synchronizeCanvasToVault() }
            for _ in 0..<1000 { if gate.entered { break }; await Task.yield() }
            check(gate.entered,"read gate entered")
            h.relayAddress = "Y"; gate.resume(); await task.value
            check(h.effects.checkpoints.isEmpty && h.effects.writes.isEmpty && !h.canvasVaultBlocked,"superseded read has no shared-state effect")
        }
        do {
            let h = VHarness(); let gate = VGate()
            h.effects.write = { await gate.pause(); return VRemote(sceneSha256:"remote-old",noteSha256:"remote-old-note") }
            let task = Task { await h.synchronizeCanvasToVault() }
            for _ in 0..<1000 { if gate.entered { break }; await Task.yield() }
            check(gate.entered && h.effects.writes.count == 1,"write begins on captured connection")
            h.relayAddress = "Y"; gate.resume(); await task.value
            check(h.syncedSceneSha == "prior" && h.canvasNoteSha == "prior-note","superseded response not accepted")
            check(h.effects.checkpoints.count == 1 && h.effects.checkpoints[0].1 == "X","only old-identity pending checkpoint remains")
        }
        print("VAULT_LIFECYCLE_CHECKS total=\(checks)")
    }
}
