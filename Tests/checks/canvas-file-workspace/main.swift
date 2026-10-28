import Foundation
import PencilKit
#if canImport(UIKit)
import UIKit
#endif

@main struct FileWorkspaceChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let requested = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:requested,withIntermediateDirectories:true)
        let root = requested.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
            let result = try condition()
            precondition(result,label)
            checks += 1; print("PASS \(label)")
        }
        func rejected(_ label: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure(label) }
            catch { checks += 1; print("PASS \(label): \(error.localizedDescription)") }
        }
        var png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        let points = [10.0,30,60].map { x in
            PKStrokePoint(location:CGPoint(x:x,y:40),timeOffset:x / 100,size:CGSize(width:4,height:4),opacity:1,force:0.7,azimuth:0,altitude:1)
        }
        let drawing = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.white),
            path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:20)))])
        var scene = CanvasScene()
        scene.width = 100; scene.height = 100; scene.schemaVersion = 2
        scene.drawingBase64 = drawing.dataRepresentation().base64EncodedString()
        scene.strokes = CanvasScene.nativeInkStrokes(drawing)
        _ = scene.addNode(kind:.note,at:CanvasPoint(x:20,y:20),text:"한글 원본 e\u{301}")
        #if canImport(UIKit)
        guard let rendered = await SceneRenderer.png(scene:scene) else { preconditionFailure("preview rendering") }
        png = rendered
        check(UIImage(data:png)?.size.width == scene.width * UIScreen.main.scale,"actual preview decodes with scene dimensions")
        #endif
        let workspace = CanvasFileWorkspace(folder:root,requiresScope:false)
        let initial = try workspace.save(scene,preview:png,expected:nil)
        let reopened = try CanvasFileWorkspace(folder:root,requiresScope:false).load(scene.id)
        check(reopened.scene == scene && reopened.preview == png,"new instance reopens scene and preview bytes")
        let document = workspace.documentURL(scene.id)
        let headURL = document.appendingPathComponent("current.json")
        let firstHead = try Data(contentsOf:headURL)
        let head = try JSONDecoder().decode(CanvasFileWorkspace.Head.self,from:firstHead)
        let generation = document.appendingPathComponent("revisions/" + head.generation.uuidString.lowercased())
        let native = try Data(contentsOf:generation.appendingPathComponent("drawing.pkdrawing"))
        check(native == Data(base64Encoded:scene.drawingBase64)!,"actual native drawing file matches JSON")
        let nativeDrawing = try PKDrawing(data:native)
        check(nativeDrawing.strokes.count == drawing.strokes.count,"native drawing is decodable")
        try check(try workspace.documents() == [scene.id],"scene identity reused in document listing")
        rejected("safe export refuses existing original") { _ = try workspace.save(scene,preview:png,expected:nil) }
        try check(try Data(contentsOf:headURL) == firstHead,"failed export preserves current pointer")
        var remote = scene; remote.revision += 1; remote.nodes[0].text = "외부 원문 유지 · 외부 변경"
        let writer = CanvasFileWorkspace(folder:root,requiresScope:false)
        let edited = try writer.save(remote,preview:png,expected:initial.token)
        try check(try workspace.load(scene.id).scene == remote,"external coordinated writer round trip")
        rejected("stale writer conflicts") { _ = try workspace.save(scene,preview:png,expected:initial.token) }
        try check(try workspace.load(scene.id).token == edited.token,"conflict preserves external generation")
        try check(try Data(contentsOf:generation.appendingPathComponent("scene.json")) == CanvasFileWorkspace.bytes(scene),"previous generation remains recoverable")
        // A cancelled picker never invokes save; reopening and listing are read-only.
        let beforeCancel = try Data(contentsOf:headURL)
        _ = try workspace.documents(); _ = try workspace.load(scene.id)
        try check(try Data(contentsOf:headURL) == beforeCancel,"cancel/read-only browsing preserves pointer")
        let revisions = document.appendingPathComponent("revisions")
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:revisions.path)
        rejected("filesystem write failure propagates") { _ = try workspace.save(scene,preview:png,expected:edited.token) }
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:revisions.path)
        try check(try Data(contentsOf:headURL) == beforeCancel,"write failure preserves original commit")
        let editedHead = try JSONDecoder().decode(CanvasFileWorkspace.Head.self,from:beforeCancel)
        let editedSceneURL = document.appendingPathComponent("revisions/" + editedHead.generation.uuidString.lowercased() + "/scene.json")
        let originalRemote = try Data(contentsOf:editedSceneURL)
        try Data("{\"outside\":true}".utf8).write(to:editedSceneURL,options:.atomic)
        rejected("uncoordinated external modification is detected") { _ = try workspace.load(scene.id) }
        rejected("external modification cannot be overwritten") { _ = try workspace.save(scene,preview:png,expected:edited.token) }
        try check(try Data(contentsOf:editedSceneURL) == Data("{\"outside\":true}".utf8),"external bytes remain intact after rejected save")
        try originalRemote.write(to:editedSceneURL,options:.atomic)
        rejected("missing document does not recreate") { _ = try workspace.save(CanvasScene(),preview:png,expected:edited.token) }
        var invalidScene = scene; invalidScene.width = 0
        rejected("invalid scene cannot replace committed original") { _ = try workspace.save(invalidScene,preview:png,expected:edited.token) }
        try check(try workspace.load(scene.id).scene == remote,"invalid scene rejection preserves previous original")
        rejected("invalid preview preserves original") { _ = try workspace.save(scene,preview:Data(),expected:edited.token) }
        let denied = CanvasFileWorkspace(folder:root.appendingPathComponent("unavailable",isDirectory:true))
        rejected("unavailable folder fails closed") { _ = try denied.load(scene.id) }
        let binding = CanvasFileWorkspace.Binding(bookmark:Data([1,2,3]),sceneID:scene.id,savedSceneSHA:try CanvasFileWorkspace.sceneSHA(scene))
        let roundtrip = try JSONDecoder().decode(CanvasFileWorkspace.Binding.self,from:JSONEncoder().encode(binding))
        check(roundtrip.sceneID == scene.id && roundtrip.savedSceneSHA == binding.savedSceneSHA,"bookmark metadata preserves pending base hash")
        var stale = false
        rejected("invalid persisted bookmark refuses resolution") {
            _ = try URL(resolvingBookmarkData:roundtrip.bookmark,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale)
        }
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        check(support.path.hasPrefix(home + "/"),"store uses isolated test application support")
        let defaults = UserDefaults(suiteName:"files-test-" + UUID().uuidString)!
        let storeFolder = root.appendingPathComponent("store",isDirectory:true)
        try FileManager.default.createDirectory(at:storeFolder,withIntermediateDirectories:true)
        let legacyBytes = try JSONEncoder().encode(scene)
        let legacyURL = try CanvasRuntime.stateURL(.scene)
        try CanvasLocalFile.write(legacyBytes,to:legacyURL)
        let store = CanvasStore(defaults:defaults)
        let preservedLegacyURL = try CanvasRuntime.stateURL(.legacyScene)
        try check(try CanvasLocalFile.read(preservedLegacyURL) == legacyBytes,"legacy scene copied byte-for-byte before reference switch")
        store.scene.id = UUID()
        #if canImport(UIKit)
        store.filePreview = { await SceneRenderer.png(scene:$0) }
        #else
        store.filePreview = { _ in png }
        #endif
        check(!store.fileWorkspaceCanSync,"unconnected pending scene cannot publish as Files original")
        check(store.updateDrawing(drawing),"store accepts real native drawing")
        store.addNode(.note)
        let localScene = store.scene
        await store.connectFileWorkspace(storeFolder)
        check(store.fileWorkspaceCanSync,"store exports and connects selected folder")
        store.saveNow()
        await store.saveFileWorkspace()
        let ownDocuments = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first!
        try FileManager.default.createDirectory(at:ownDocuments,withIntermediateDirectories:true)
        await store.connectFileWorkspace(ownDocuments)
        check(store.fileWorkspaceCanSync && store.status.contains("앱 전용 폴더"),"own Documents cannot be accepted as a public original")
        await store.connectFileWorkspace(support)
        check(store.fileWorkspaceCanSync && store.status.contains("앱 전용 폴더"),"own ApplicationSupport cannot be accepted as a public original")
        try check(try CanvasLocalFile.read(preservedLegacyURL) == legacyBytes,"folder selection preserves untouched legacy bytes")
        let reopenedStore = CanvasStore(defaults:defaults)
        #if canImport(UIKit)
        reopenedStore.filePreview = { await SceneRenderer.png(scene:$0) }
        #else
        reopenedStore.filePreview = { _ in png }
        #endif
        check(reopenedStore.scene == localScene && reopenedStore.fileWorkspaceCanSync,"store resolves bookmark and restores Files source on restart")
        reopenedStore.addNode(.box)
        check(!reopenedStore.fileWorkspaceCanSync,"local edit immediately blocks relay until original saved")
        reopenedStore.saveNow()
        await reopenedStore.saveFileWorkspace()
        let storeWorkspace = CanvasFileWorkspace(folder:storeFolder,requiresScope:false)
        var savedStore = try storeWorkspace.load(localScene.id)
        check(savedStore.scene == reopenedStore.scene && reopenedStore.fileWorkspaceCanSync,"store autosave commits matching scene")
        let beforeFailureHead = try Data(contentsOf:storeWorkspace.documentURL(localScene.id).appendingPathComponent("current.json"))
        let storeRevisions = storeWorkspace.documentURL(localScene.id).appendingPathComponent("revisions")
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:storeRevisions.path)
        reopenedStore.addNode(.note)
        reopenedStore.saveNow()
        await reopenedStore.saveFileWorkspace()
        check(reopenedStore.fileWorkspaceState == .blocked && !reopenedStore.fileWorkspaceCanSync,"provider write failure blocks relay instead of accepting cache as original")
        try check(try Data(contentsOf:storeWorkspace.documentURL(localScene.id).appendingPathComponent("current.json")) == beforeFailureHead,"provider failure leaves selected original unchanged")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:storeRevisions.path)
        reopenedStore.retryFileWorkspaceSave()
        await reopenedStore.saveFileWorkspace()
        savedStore = try storeWorkspace.load(localScene.id)
        check(reopenedStore.fileWorkspaceCanSync && savedStore.scene == reopenedStore.scene,"explicit retry saves pending bytes to the same selected original")
        var external = savedStore.scene
        external.nodes[0].text = "외부 편집"; external.revision += 1
        _ = try storeWorkspace.save(external,preview:png,expected:savedStore.token)
        reopenedStore.refreshFileWorkspace()
        check(reopenedStore.scene == external && reopenedStore.fileWorkspaceCanSync,"clean store reads external edit")
        reopenedStore.saveNow()
        await reopenedStore.saveFileWorkspace()
        let cleanExternal = try storeWorkspace.load(localScene.id)
        external.nodes[0].text = "외부 두 번째 수정"; external.revision += 1
        _ = try storeWorkspace.save(external,preview:png,expected:cleanExternal.token)
        reopenedStore.addNode(.box)
        let pendingScene = reopenedStore.scene
        reopenedStore.saveNow()
        await reopenedStore.saveFileWorkspace()
        check(reopenedStore.fileWorkspaceState == .blocked && reopenedStore.scene == pendingScene,"dirty store preserves pending input on external conflict")
        try check(try storeWorkspace.load(localScene.id).scene == external,"blocked store preserves external original")
        let pending = try JSONDecoder().decode(CanvasScene.self,from:CanvasLocalFile.read(CanvasRuntime.stateURL(.scene)))
        check(pending == pendingScene,"pending cache retains unsaved scene bytes")
        let conflictRestart = CanvasStore(defaults:defaults)
        check(conflictRestart.fileWorkspaceState == .blocked && conflictRestart.scene == pendingScene,"restart retains unsaved conflict instead of external overwrite")
        let target = root.appendingPathComponent("race-export",isDirectory:true)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let raceSource = root.appendingPathComponent("race-source",isDirectory:true)
        try FileManager.default.createDirectory(at:raceSource,withIntermediateDirectories:true)
        let raceStore = CanvasStore(defaults:defaults)
        raceStore.scene.id = UUID()
        raceStore.filePreview = { _ in png }
        await raceStore.connectFileWorkspace(raceSource)
        check(raceStore.fileWorkspaceCanSync,"race starts from an accepted external original")
        raceStore.filePreview = { _ in
            raceStore.addNode(.note)
            return png
        }
        let beforeRace = raceStore.scene
        await raceStore.connectFileWorkspace(target)
        check(raceStore.scene.nodes.count == beforeRace.nodes.count + 1 && !raceStore.fileWorkspaceCanSync,
            "input during export remains pending and is not falsely marked saved")
        try check(try CanvasFileWorkspace(folder:target,requiresScope:false).documents().isEmpty,"stale preview cannot create exported original")
        print("PASSED \(checks) file workspace checks")
    }
}
