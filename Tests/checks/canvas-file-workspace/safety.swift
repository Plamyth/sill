import Foundation
import PencilKit

@main struct WorkspaceSafetyChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let requested = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:requested,withIntermediateDirectories:true)
        let root = requested.resolvingSymlinksInPath()
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"))
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
            let passed = try condition(); precondition(passed,label)
            checks += 1; print("PASS \(label)")
        }
        func scene(_ text: String, id: UUID = UUID()) -> CanvasScene {
            var value = CanvasScene(); value.id = id; value.width = 100; value.height = 100
            _ = value.addNode(kind:.note,at:CanvasPoint(x:20,y:20),text:text)
            return value
        }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name,isDirectory:true)
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
            return url
        }
        func seed(_ local: CanvasScene, binding: CanvasScene, folder: URL) throws {
            let bookmark = try folder.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
            let value = CanvasFileWorkspace.Binding(bookmark:bookmark,sceneID:binding.id,
                savedSceneSHA:try CanvasFileWorkspace.sceneSHA(binding))
            try CanvasLocalFile.write(CanvasFileWorkspace.bytes(local),to:CanvasRuntime.stateURL(.scene))
            try CanvasLocalFile.write(JSONEncoder().encode(value),to:CanvasRuntime.stateURL(.workspace))
        }
        func hashes(_ folder: URL) throws -> [String:String] {
            let urls = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey])!
            var result: [String:String] = [:]
            for case let url as URL in urls where try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(folder.path.count))] = CanvasPacket.sha(try Data(contentsOf:url))
            }
            return result
        }
        let a = scene("저장 기준 A")
        var b = a; b.nodes[0].text = "보존해야 할 외부 B"; b.revision += 1
        var c = a; c.nodes[0].text = "미저장 C"; c.revision += 1
        for (name, local, saved) in [("restart-conflict",c,a),("binding-cache-interruption",a,b)] {
            let directory = try folder(name)
            let workspace = CanvasFileWorkspace(folder:directory,requiresScope:false)
            _ = try workspace.save(b,preview:png,expected:nil)
            try seed(local,binding:saved,folder:directory)
            let original = try hashes(directory)
            let cache = try CanvasLocalFile.read(CanvasRuntime.stateURL(.scene))
            let store = CanvasStore(); store.filePreview = { _ in png }
            check(store.fileWorkspaceState == .blocked && store.scene == local,"\(name): mismatched restart blocks")
            store.retryFileWorkspaceSave(); await store.saveFileWorkspace()
            check(store.fileWorkspaceState == .blocked && !store.fileWorkspaceCanSync,"\(name): retry cannot unlock conflict")
            try check(try hashes(directory) == original,"\(name): retry preserves every external file byte")
            try check(try CanvasLocalFile.read(CanvasRuntime.stateURL(.scene)) == cache,"\(name): retry preserves local pending bytes")
            try check(try workspace.load(a.id).scene == b,"\(name): external B remains current")
        }
        let directory = try folder("cancel-save")
        let workspace = CanvasFileWorkspace(folder:directory,requiresScope:false)
        _ = try workspace.save(a,preview:png,expected:nil)
        try seed(a,binding:a,folder:directory)
        let cancelled = CanvasStore()
        cancelled.addNode(.box)
        let pending = cancelled.scene
        let before = try hashes(directory)
        let bindingBefore = try CanvasLocalFile.read(CanvasRuntime.stateURL(.workspace))
        var continuation: CheckedContinuation<Data?,Never>?
        cancelled.filePreview = { _ in await withCheckedContinuation { continuation = $0 } }
        let save = Task { await cancelled.saveFileWorkspace() }
        while continuation == nil { await Task.yield() }
        save.cancel(); continuation!.resume(returning:png)
        await save.value
        cancelled.filePreview = { _ in nil }
        try check(try hashes(directory) == before,"cancelled preview cannot modify current or any revision file")
        try check(try CanvasLocalFile.read(CanvasRuntime.stateURL(.workspace)) == bindingBefore,"cancelled save cannot advance binding")
        check(cancelled.scene == pending && !cancelled.fileWorkspaceCanSync,"cancelled save retains pending input without ready state")

        let target = try folder("cancel-export")
        try seed(a,binding:a,folder:directory)
        let export = CanvasStore()
        continuation = nil
        export.filePreview = { _ in await withCheckedContinuation { continuation = $0 } }
        let connect = Task { await export.connectFileWorkspace(target) }
        while continuation == nil { await Task.yield() }
        connect.cancel(); continuation!.resume(returning:png)
        await connect.value
        try check(try hashes(target).isEmpty,"cancelled folder export creates no external document")
        try check(try hashes(directory) == before,"cancelled export preserves existing original")

        let recoveryFolder = try folder("corrupt-cache")
        let recoveryWorkspace = CanvasFileWorkspace(folder:recoveryFolder,requiresScope:false)
        _ = try recoveryWorkspace.save(b,preview:png,expected:nil)
        try seed(b,binding:b,folder:recoveryFolder)
        let corrupt = Data([0,255,123,34,10])
        try CanvasLocalFile.write(corrupt,to:CanvasRuntime.stateURL(.scene))
        let recovery = CanvasStore()
        recovery.addNode(.box)
        let memory = recovery.scene
        let filesBefore = try hashes(recoveryFolder)
        let oldPending = try FileManager.default.contentsOfDirectory(at:support,includingPropertiesForKeys:nil)
        await recovery.connectFileWorkspace(recoveryFolder,opening:UUID())
        check(recovery.scene == memory && recovery.fileWorkspaceState == .blocked,"failed open preserves protected in-memory scene")
        try check(try CanvasLocalFile.read(CanvasRuntime.stateURL(.scene)) == corrupt,"failed open preserves raw corrupt cache")
        await recovery.connectFileWorkspace(recoveryFolder,opening:b.id)
        check(recovery.scene == b && recovery.fileWorkspaceCanSync && recovery.sceneRecoveryNotice.isEmpty,"valid external original recovers unreadable cache")
        try check(try hashes(recoveryFolder) == filesBefore,"recovery reads without rewriting external original")
        let copies = try FileManager.default.contentsOfDirectory(at:support,includingPropertiesForKeys:nil).filter { !oldPending.contains($0) }
        let rawCopies = copies.filter { $0.lastPathComponent.hasPrefix("CanvasUnreadable-") }
        let pendingCopies = copies.filter { $0.lastPathComponent.hasPrefix("CanvasPending-") }
        check(!rawCopies.isEmpty && !pendingCopies.isEmpty,"recovery retains separate raw and current-scene copies")
        try check(try rawCopies.allSatisfy { try CanvasPacket.sha(Data(contentsOf:$0)) == CanvasPacket.sha(corrupt) },"corrupt cache copies preserve exact original bytes and hash")
        try check(try pendingCopies.allSatisfy { try JSONDecoder().decode(CanvasScene.self,from:Data(contentsOf:$0)) == memory },"current in-memory scene is separately preserved")
        let restarted = CanvasStore()
        check(restarted.scene == b && restarted.fileWorkspaceCanSync,"new instance reopens the recovered external original")
        print("PASSED \(checks) safety checks")
    }
}
