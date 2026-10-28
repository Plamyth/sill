// Harness boundaries are fixtures; marked product declarations and async bodies are inserted verbatim by the runner.
import Foundation
import CryptoKit
struct CanvasScene: Codable { var id:UUID; var revision:Int }
struct Remote:Decodable { var noteSha256:String; var sceneSha256:String; var sceneJSONBase64:String; var reconciliationRequired:Bool? }
struct Scenario:Decodable { var scenes:[String:String]; var remoteA:Remote; var remoteB:Remote; var remoteD:Remote }
enum CanvasPacket { static func sha(_ bytes:Data)->String { SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined() } }
enum CanvasLocalFile { static func write(_ bytes:Data,to url:URL)throws { try bytes.write(to:url,options:.atomic) } }
// EXACT_PRODUCT_DECLARATIONS
struct History { var usingTool=false }
@MainActor final class FixtureStore {
    var inkHistory=History(); var scene:CanvasScene; var drawing=Data(); var fileWorkspaceCanSync=true
    var status=""; var inkBusy=false; var vaultInputBusy=false
    init(_ scene:CanvasScene){self.scene=scene}
    func refreshFileWorkspace(){}; func importScene(_ s:CanvasScene)throws{scene=s}; func saveNow(){}
}
enum SceneRenderer { static func png(scene:CanvasScene)async->Data? { Data([1]) } }
@MainActor final class FixtureRelay {
    var scenario:Scenario; var writes=0; var reads=0; var required:Bool?=true; var mode:VaultSaveConflict? = .reconciliationRequired
    init(_ s:Scenario){scenario=s}
    func vaultCanvas(id:UUID)async throws->Remote? {
        reads+=1; var r = writes==0 ? scenario.remoteA:scenario.remoteB
        r.reconciliationRequired = writes==0 ? false:required
        return r
    }
    func saveVaultCanvas(scene:CanvasScene,imagePNG:Data,baseSha256:String?)async throws->Remote {
        writes+=1
        if writes==1 {
            if let mode { throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:mode.rawValue]) }
            throw URLError(.networkConnectionLost)
        }
        return scenario.remoteD
    }
}
@MainActor final class Harness {
    static var checkpointURL:URL!
    var store:FixtureStore; var relay:FixtureRelay; var scenario:Scenario
    var canvasSyncBusy=false,canvasVaultEnabled=true,canvasVaultBlocked=false
    var canvasSaveConflict:VaultSaveConflict?
    var vaultSceneID:UUID; var vaultSyncAddress="fixture"; var relayAddress="fixture"; var relayToken="fixture-only"
    var syncedSceneSha:String?; var canvasNoteSha:String?; var pendingSceneSha:String?
    init(_ s:Scenario,relay:FixtureRelay?=nil,restore:Bool=false)throws {
        scenario=s;store=FixtureStore(try JSONDecoder().decode(CanvasScene.self,from:Data(s.scenes["2"]!.utf8)))
        self.relay=relay ?? FixtureRelay(s);vaultSceneID=store.scene.id
        syncedSceneSha=s.remoteA.sceneSha256;canvasNoteSha=s.remoteA.noteSha256
        if restore {
            let checkpoint=try JSONDecoder().decode(CanvasVaultCheckpoint.self,from:Data(contentsOf:Self.checkpointURL))
            syncedSceneSha=checkpoint.sceneSha;canvasNoteSha=checkpoint.noteSha;pendingSceneSha=checkpoint.pendingSceneSha
            canvasSaveConflict=checkpoint.saveConflict;canvasVaultBlocked=checkpoint.requiresExplicitReconciliation
        }
    }
    static func canvasVaultCheckpointURL()->URL { checkpointURL }
    func sceneBytes()throws->Data { Data(scenario.scenes[String(store.scene.revision)]!.utf8) }
    func saveCanvasVaultCheckpoint()throws {
        try CanvasLocalFile.write(JSONEncoder().encode(CanvasVaultCheckpoint(sceneID:store.scene.id,address:relayAddress,
            sceneSha:syncedSceneSha,noteSha:canvasNoteSha,pendingSceneSha:pendingSceneSha,saveConflict:canvasSaveConflict)),to:Self.checkpointURL)
    }
    func remoteCanvasIsPrefix(_ r:Remote,of scene:CanvasScene,drawing:Data)->Bool { false }
    // EXACT_WORKSPACE_FUNCTIONS
    func run()async throws {
        await synchronizeCanvasToVault()
        precondition(canvasVaultBlocked && canvasSaveConflict == .reconciliationRequired && relay.writes==1 && pendingSceneSha==scenario.remoteB.sceneSha256)
        let persisted=try Data(contentsOf:Self.checkpointURL)
        await refreshCanvasFromVault();store.scene.revision=3;await synchronizeCanvasToVault()
        precondition(relay.writes==1 && syncedSceneSha==scenario.remoteA.sceneSha256 && pendingSceneSha==scenario.remoteB.sceneSha256 && canvasVaultBlocked)
        let preservedAfter = try Data(contentsOf:Self.checkpointURL)
        precondition(preservedAfter==persisted)
        let reopened=try Harness(scenario,relay:relay,restore:true)
        await reopened.refreshCanvasFromVault();await reopened.synchronizeCanvasToVault()
        precondition(reopened.canvasVaultBlocked && relay.writes==1 && reopened.pendingSceneSha==scenario.remoteB.sceneSha256)
        await reopened.reconcileCanvasConflict()
        precondition(reopened.canvasVaultBlocked && relay.writes==1,"SHA match cannot clear unresolved server journal")
        relay.required=false;reopened.store.scene.revision=3;await reopened.reconcileCanvasConflict()
        precondition(reopened.canvasVaultBlocked && relay.writes==1,"explicit adjustment preserves newer local scene")
        reopened.store.scene.revision=2;await reopened.reconcileCanvasConflict()
        precondition(!reopened.canvasVaultBlocked && reopened.pendingSceneSha==nil && relay.writes==1)
        reopened.store.scene.revision=3;await reopened.synchronizeCanvasToVault();precondition(relay.writes==2)
        let unknown=try Harness(scenario);unknown.relay.mode = .unclassified;unknown.relay.required=nil
        await unknown.synchronizeCanvasToVault();await unknown.refreshCanvasFromVault();await unknown.reconcileCanvasConflict()
        precondition(unknown.canvasVaultBlocked && unknown.relay.writes==1 && unknown.canvasNoteSha==scenario.remoteA.noteSha256)
        let ack=try Harness(scenario);ack.relay.mode=nil;ack.relay.required=false
        await ack.synchronizeCanvasToVault();precondition(!ack.canvasVaultBlocked && ack.canvasSaveConflict == .acknowledgementLost)
        await ack.refreshCanvasFromVault();precondition(!ack.canvasVaultBlocked && ack.pendingSceneSha==nil && ack.canvasNoteSha==scenario.remoteB.noteSha256)
        ack.store.scene.revision=3;await ack.synchronizeCanvasToVault();precondition(ack.relay.writes==2)
        print("WORKSPACE_CONFLICT_OK preserved409=blocked restart=blocked newEdit=blocked unresolvedJournal=blocked explicitResolved=allowed ordinaryLostACK=recovered legacy409=explicitOnly")
    }
}
@main struct Main {
    @MainActor static func main()async throws {
        Harness.checkpointURL=URL(fileURLWithPath:CommandLine.arguments[2])
        let scenario=try JSONDecoder().decode(Scenario.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        try await Harness(scenario).run()
    }
}
