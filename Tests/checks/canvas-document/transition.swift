import Foundation
import PencilKit
import AppKit

@main struct DocumentTransitionChecks {
    static var checks: [String] = []
    static let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==")!
    static func check(_ value: Bool,_ name: String) { precondition(value,name); checks.append(name); print("PASS \(name)") }
    static func drawing(_ x: Double) throws -> PKDrawing {
        let points = [0.0,10,20].enumerated().map { i,dx in PKStrokePoint(location:CGPoint(x:x+dx,y:20+dx),timeOffset:Double(i)/10,size:CGSize(width:3,height:5),opacity:0.8,force:0.7,azimuth:0.3,altitude:1) }
        return try PKDrawing(data:PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))]).dataRepresentation())
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated required") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        if CommandLine.arguments.contains("--check-reopen") {
            let expected = try CanvasDocument.decodeDocument(Data(contentsOf:out.appendingPathComponent("expected.json")))
            let fresh = CanvasStore(); fresh.enableDocumentChecks()
            check(fresh.isDocumentSource && fresh.document == expected,"new process retains complete original and selected page")
            check(fresh.scene.drawingBase64 == expected.activePage.drawingBase64,"new process restores selected native ink")
            return
        }
        let scenario = CommandLine.arguments[2], fm = FileManager.default
        let store = CanvasStore(); store.enableDocumentChecks(); store.filePreview = { _ in png }
        store.addNode(.note); store.scene.nodes[0].text = "저장된 첫 페이지"
        _ = store.updateDrawing(try drawing(10)); try store.createDocument()
        let folder = out.appendingPathComponent("files",isDirectory:true)
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        let files = CanvasDocumentFiles(folder:folder,requiresScope:false)
        if scenario != "unbound" { await store.connectDocumentWorkspace(folder); check(store.documentFileReady,"initial complete canonical binding") }
        let originID = store.document.id, firstID = store.scene.id
        await store.duplicateDocumentPage()
        store.scene.nodes[0].text = "숨은 두 번째 페이지"
        _ = store.updateDrawing(try drawing(100))
        await store.selectDocumentPage(firstID)
        let saved = scenario == "unbound" ? nil : try files.load(originID)
        let other = try CanvasDocument(legacy:CanvasScene())
        let target = try files.save(other,previews:[other.activePageID:png],expected:nil)
        if scenario != "clean-bound" {
            store.scene.nodes[0].text = "DOC-STORE-R1 고유 미저장 본문 " + scenario
            store.scene.revision += 1
        }
        store.mode = .select; let node = store.scene.nodes[0]; store.selectedNode = node.id
        if scenario != "clean-bound" { check(store.rotateNode(node,sceneID:firstID,to:25),"prepare graph Undo on dirty page") }
        final class Counter { var value = 0 }
        let counter = Counter(), manager = store.inkHistory.activate(store.nativeHistoryOwner)
        manager.groupsByEvent = false; manager.beginUndoGrouping(); manager.registerUndo(withTarget:counter) { $0.value += 1 }; manager.endUndoGrouping()
        let dirty = store.document, selected = store.selectedNode, nativeOwner = store.nativeHistoryOwner, generation = store.inkHistory.generation
        let graphUndo = store.canUndoGraph, selection = store.inkSelection
        func unchanged() throws {
            check(store.document == dirty && store.scene.id == firstID,"failed switch retains entire document and selected page")
            check(store.selectedNode == selected && store.inkSelection == selection,"failed switch retains node and ink selection")
            check(store.nativeHistoryOwner == nativeOwner && store.inkHistory.generation == generation && manager.canUndo,"failed switch retains native Undo owner and actions")
            check(store.canUndoGraph == graphUndo && !store.documentBusy,"failed switch retains graph Undo and releases its busy owner")
            check(try files.load(other.id).token == target.token,"failed switch does not modify target source")
        }
        func reopen(_ expected: CanvasDocument) throws {
            try expected.bytes().write(to:out.appendingPathComponent("expected.json")) // comparison only; never used to restore product state.
            let process = Process(); process.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
            process.arguments = [out.path,scenario,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--check-reopen"]
            try process.run(); process.waitUntilExit(); check(process.terminationStatus == 0,"separate process reopens product state without backup injection")
        }
        if scenario == "dirty-bound" || scenario == "clean-bound" {
            let oldToken = saved!.token
            await store.connectDocumentWorkspace(folder,opening:other.id)
            check(store.document == other && store.documentFileReady,"opening another whole document remains available")
            let retained = try files.load(originID)
            check(retained.document == dirty && retained.document.pages.count == 2,"original Files preserves every dirty or hidden page before replacement")
            if scenario == "clean-bound" { check(retained.token == oldToken,"already preserved source requires no generation or recovery copy") }
            let fresh = CanvasStore(); fresh.enableDocumentChecks(); fresh.filePreview = { _ in png }
            check(fresh.document == other,"fresh Store opens the chosen target")
            await fresh.connectDocumentWorkspace(folder,opening:originID)
            check(fresh.document == dirty,"preserved original is available through ordinary Files open")
            try reopen(dirty)
        } else if scenario == "unbound" {
            await store.connectDocumentWorkspace(folder,opening:other.id)
            try unchanged(); try reopen(dirty)
            check(!store.documentFileReady,"unbound original is held until actual whole Files save")
            await store.connectDocumentWorkspace(folder)
            check(try files.load(originID).document == dirty,"id nil exports complete unbound original")
            check(store.documentFileReady && store.document == dirty && store.selectedNode == selected && manager.canUndo,"safe export retains current selection and Undo")
            await store.connectDocumentWorkspace(folder,opening:other.id)
            check(store.document == other,"opening is available after explicit unbound preservation")
        } else if scenario == "external-conflict" {
            var external = saved!.document, hidden = external.pages[1]
            hidden.nodes[0].text = "다른 writer의 숨은 페이지"; hidden.revision += 1
            try external.replacePage(hidden,expectedRevision:external.revision)
            let externalSaved = try files.save(external,previews:saved!.previews,expected:saved!.token)
            await store.saveDocumentWorkspace()
            check(store.fileWorkspaceState == .blocked,"prepare already blocked external Files save")
            await store.connectDocumentWorkspace(folder,opening:other.id)
            try unchanged(); try reopen(dirty)
            check(try files.load(originID).token == externalSaved.token,"external conflict never overwrites external source")
            let exported = out.appendingPathComponent("safe-export",isDirectory:true); try fm.createDirectory(at:exported,withIntermediateDirectories:true)
            await store.connectDocumentWorkspace(exported)
            check(try CanvasDocumentFiles(folder:exported,requiresScope:false).load(originID).document == dirty,"id nil safe export remains available after external conflict")
            check(try files.load(originID).document == external,"safe export leaves original external generation untouched")
        } else if scenario == "read-failure" {
            let directory = files.documentURL(originID)
            try fm.setAttributes([.posixPermissions:0o000],ofItemAtPath:directory.path)
            defer { try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path) }
            await store.saveDocumentWorkspace()
            check(store.fileWorkspaceState == .blocked,"prepare already blocked unreadable Files save")
            await store.connectDocumentWorkspace(folder,opening:other.id)
            try unchanged(); try reopen(dirty)
            check(store.document == dirty,"unreadable source cannot authorize replacement")
        } else if scenario == "cancel" {
            var continuation: CheckedContinuation<Data?,Never>?
            store.filePreview = { _ in await withCheckedContinuation { continuation = $0 } }
            let transition = Task { await store.connectDocumentWorkspace(folder,opening:other.id) }
            while continuation == nil { await Task.yield() }
            transition.cancel(); continuation!.resume(returning:png); await transition.value
            try unchanged(); try reopen(dirty)
            check(try files.load(originID).token == saved!.token,"cancel before publication leaves original Files head untouched")
        } else if scenario == "target-failure" {
            let targetHead = files.documentURL(other.id).appendingPathComponent("current.json")
            let bytes = try Data(contentsOf:targetHead)
            try Data("unsupported target head".utf8).write(to:targetHead)
            await store.connectDocumentWorkspace(folder,opening:other.id)
            try bytes.write(to:targetHead)
            try unchanged(); try reopen(dirty)
            check(try files.load(originID).document == dirty,"target read failure retains newly preserved original in Files")
            check(store.documentFileReady,"preservation success is separate from failed target open")
        } else if scenario == "raw-import" {
            do { try store.importSourceBytes(other.bytes()); fatalError("dirty import accepted") } catch { check(true,"raw import cannot bypass actual source preservation") }
            try unchanged(); try reopen(dirty)
            do { try store.returnToLegacySource(); fatalError("dirty legacy return accepted") } catch { check(true,"legacy return cannot bypass actual source preservation") }
            try unchanged()
        } else { fatalError("unknown scenario") }
        let fields: [String:Any] = ["case":scenario,"assertions":checks,"count":checks.count,"actualStore":true,"nativePKDrawing":true,"nativeFiles":true,"nativeUndoManager":true,"HTTP":false,"GUI":false,"device":false,"wholeProductAccepted":false]
        try JSONSerialization.data(withJSONObject:fields,options:.sortedKeys).write(to:out.appendingPathComponent("transition-observations.json"))
        print("R1_ASSERTIONS \(checks.count)")
    }
}
