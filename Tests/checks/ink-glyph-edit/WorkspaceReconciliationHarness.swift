// Real async product bodies are inserted by reconciliation-check.py. Only SwiftUI state storage is substituted.
import Foundation
@MainActor final class WorkspaceReconciliationHarness {
    let store: CanvasStore, relay: CanvasRelay
    var relayAddress="http://192.168.88.88:4242",relayToken="own-fixture-token-012345678901"
    var proposalInputBusy=false
    var canvasVaultBlocked=true,canvasSyncBusy=false,canvasConflictOpen=false,canvasVaultEnabled=true
    var syncedSceneSha:String?,syncedLocalSceneSha:String?,canvasNoteSha:String?,pendingSceneSha:String?
    var canvasSaveConflict:VaultSaveConflict? = .reconciliationRequired
    var vaultSceneID:UUID?,vaultSyncAddress:String?
    var canvasConflict:CanvasRelay.VaultConflict?,canvasConflictLocalSHA:String?,canvasConflictStatus=""
    private var canvasConflictPending:CanvasConflictChoice?
    init(store:CanvasStore,relay:CanvasRelay) {self.store=store;self.relay=relay;vaultSceneID=store.scene.id;vaultSyncAddress=relayAddress}
    // EXACT_PRODUCT_MEMBERS
    func remoteCanvasIsPrefix(_ remote:CanvasRelay.VaultCanvas,of local:CanvasScene,drawing:Any)->Bool {false}
    func checks(_ check:(Bool,String)->Void) async throws {
        let original=store.scene
        await readCanvasConflictNote()
        check(canvasConflict != nil && canvasConflictOpen,"actual Workspace read action opens validated four-material comparison state")
        let writes=ReconciliationProtocol.requests.count
        store.scene.nodes[0].text="조회 뒤 새 입력"
        await resolveCanvasConflict(.useDisplaced)
        check(ReconciliationProtocol.requests.count==writes && canvasVaultBlocked,"actual Workspace rejects changed local snapshot before any PUT")
        store.scene=original;await readCanvasConflictNote()
        ReconciliationProtocol.mode="lost";ReconciliationProtocol.resolved=false
        await resolveCanvasConflict(.useDisplaced)
        check(canvasConflictPending?.disposition == .pending && canvasVaultBlocked && store.scene==original,"lost response leaves actual local choice journal and original scene held")
        store.scene.nodes[0].text="결과 미확인 뒤 새 입력"
        let changed=WorkspaceReconciliationHarness(store:store,relay:relay)
        await changed.readCanvasConflictNote()
        check(changed.canvasConflictOpen && changed.canvasConflictPending?.disposition == .refreshRequired,"reopened unresolved request remains readable after newer local input")
        let changedWrites=ReconciliationProtocol.requests.count
        await changed.resolveCanvasConflict(.useDisplaced)
        check(ReconciliationProtocol.requests.count==changedWrites,"newer local input requires fresh review and cannot re-submit old choice")
        store.scene=original
        let reopened=WorkspaceReconciliationHarness(store:store,relay:relay)
        await reopened.readCanvasConflictNote()
        check(reopened.canvasConflictPending?.decision == .useDisplaced,"reopened comparison restores same unresolved original decision")
        await reopened.resolveCanvasConflict(.useDisplaced)
        check(!reopened.canvasVaultBlocked && reopened.canvasConflictPending==nil,"explicit same-choice confirmation resolves actual Workspace barrier")
        let checkpoint=try JSONDecoder().decode(CanvasVaultCheckpoint.self,from:CanvasLocalFile.read(Self.canvasVaultCheckpointURL()))
        check(checkpoint.localSceneSha==reopened.syncedLocalSceneSha && checkpoint.sceneSha==reopened.syncedSceneSha && checkpoint.localSceneSha != checkpoint.sceneSha,"canonical local baseline remains separate from exact noncanonical server JSON SHA")
        let beforeAuto=ReconciliationProtocol.requests.count
        await reopened.synchronizeCanvasToVault()
        check(ReconciliationProtocol.requests.count==beforeAuto,"accepted noncanonical source does not trigger an unsolicited automatic rewrite")
        store.scene.nodes[0].text="이후 입력 ACK 유실"
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let edited=try encoder.encode(store.scene),editedSHA=CanvasPacket.sha(edited)
        var published=ReconciliationProtocol.selected,c=published["canvas"] as! [String:Any]
        c["sceneJSONBase64"]=edited.base64EncodedString();c["sceneSha256"]=editedSHA
        c["noteSha256"]=String(repeating:"f",count:64);published["canvas"]=c;ReconciliationProtocol.selected=published
        reopened.pendingSceneSha=editedSHA;reopened.canvasSaveConflict = .acknowledgementLost
        await reopened.refreshCanvasFromVault()
        let renders=SceneRenderer.calls
        await reopened.synchronizeCanvasToVault()
        check(reopened.syncedLocalSceneSha==editedSHA && reopened.pendingSceneSha==nil && SceneRenderer.calls==renders,"ordinary lost ACK updates local canonical baseline without re-render or duplicate automatic PUT")
        // Fresh fixture conflict: a typed409 requires new material/ID before another explicit choice.
        store.scene=original;canvasVaultBlocked=true;canvasConflictPending=nil
        await readCanvasConflictNote();ReconciliationProtocol.mode="stale"
        await resolveCanvasConflict(.keepCurrent)
        check(canvasConflictPending?.disposition == .refreshRequired && canvasVaultBlocked,"typed409 makes previous choice require new material read")
        let heldWrites=ReconciliationProtocol.requests.count
        await resolveCanvasConflict(.keepCurrent)
        check(ReconciliationProtocol.requests.count==heldWrites,"refreshRequired action guard sends zero stale PUT even without SwiftUI button guard")
        var next=ReconciliationProtocol.snapshot
        let newID=UUID().uuidString;next["recoveryID"]=newID
        next["history"]=[["recoveryID":ReconciliationProtocol.snapshot["recoveryID"]!,"files":["base.md":String(repeating:"a",count:64)]]]
        var expected=next["expected"] as! [String:Any];expected["historySha256"]=String(repeating:"b",count:64);next["expected"]=expected
        ReconciliationProtocol.snapshot=next;ReconciliationProtocol.mode="normal"
        let oldRequests=ReconciliationProtocol.requests.count
        await readNewConflictMaterials()
        check(canvasConflict?.recoveryID.uuidString==newID && canvasConflictPending==nil && ReconciliationProtocol.requests.count==oldRequests,"explicit fresh GET accepts child recoveryID/history without submitting a new decision")
    }
}
