import Foundation
import PencilKit
import AppKit

@main struct CardMergeChecks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        precondition(value(), name); count += 1; print("PASS \(name)")
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated runtime required") }
        let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let sceneURL = try CanvasRuntime.stateURL(.scene)
        let state = sceneURL.deletingLastPathComponent()
        let folder = state.appendingPathComponent("selected-files",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let points = [10.0,20.0].enumerated().map { i,x in
            PKStrokePoint(location:CGPoint(x:x,y:x),timeOffset:Double(i)/10,
                          size:CGSize(width:3,height:4),opacity:0.7,force:0.6,azimuth:0.3,altitude:1)
        }
        let stroke = PKStroke(ink:PKInk(.pen,color:.black),
                              path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))
        let drawing = try PKDrawing(data:PKDrawing(strokes:[stroke]).dataRepresentation())
        let paths = ["Own/Alpha.md","Own/Beta.md"]
        let texts = ["Alpha e\u{301} 🖊️\r\n기존 메모 ^alpha", "Beta\nPDF 출처와 메모 ^beta"]
        let parents = [UUID(),UUID()]
        var base = CanvasScene();base.schemaVersion = 3
        base.drawingBase64 = drawing.dataRepresentation().base64EncodedString()
        base.strokes = CanvasScene.nativeInkStrokes(drawing)
        for i in 0..<2 {
            base.nodes.append(.init(id:parents[i],kind:.box,frame:.init(x:Double(i)*500,y:20,width:250,height:120),
                                    text:"다른 상위 \(i)",confidence:.confirmed,sourceStrokeIds:[]))
        }
        var ids: [UUID] = []
        for i in 0..<2 {
            let id = UUID(); ids.append(id)
            base.nodes.append(.init(id:id,kind:.note,frame:.init(x:Double(i)*500,y:220,width:260,height:120),
                text:texts[i],confidence:.confirmed,sourceStrokeIds:i == 0 ? [stroke.id] : [],
                vaultNote:.init(path:paths[i],sha256:CanvasPacket.sha(Data(texts[i].utf8)),relayAddress:context.relayAddress,
                                blockID:i == 0 ? "alpha" : "beta",sourceState:.current)))
            _ = base.connectAsChild(parent:parents[i],child:id,label:"기존 계층 \(i)")
        }
        base.annotations = [.init(id:UUID(),nodeId:ids[0],text:"사용자의 원본 댓글",author:"사용자")]
        _ = base.connect(ids[0],to:ids[1],label:"기존 일반 관계")
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        let files = CanvasFileWorkspace(folder:folder,requiresScope:false)
        _ = try files.save(base,preview:png,expected:nil)
        // macOS fixed-HOME minimal bookmarks are immediately stale; scoped bookmarks for this owned fixture are not.
        let binding = CanvasFileWorkspace.Binding(bookmark:try folder.bookmarkData(options:.withSecurityScope,
            includingResourceValuesForKeys:nil,relativeTo:nil),sceneID:base.id,savedSceneSHA:try CanvasFileWorkspace.sceneSHA(base))
        try CanvasLocalFile.write(CanvasFileWorkspace.bytes(base),to:sceneURL)
        try CanvasLocalFile.write(JSONEncoder().encode(binding),to:CanvasRuntime.stateURL(.workspace))
        let store = CanvasStore();store.mode = .select;store.filePreview = { _ in png }
        print("INITIAL_STORE sceneEqual=\(store.scene == base) filesReady=\(store.fileWorkspaceCanSync) status=\(store.status) fileStatus=\(store.fileWorkspaceStatus)")
        check(store.scene == base && store.fileWorkspaceCanSync,"actual Store restores bound source and native drawing")
        func queue(_ s: CanvasStore) {
            s.selectedNode = ids[1];s.beginCardMerge(s.scene.nodes.first { $0.id == ids[1] }!)
            s.selectedNode = ids[0];s.appendCardMerge(s.scene.nodes.first { $0.id == ids[0] }!)
        }
        queue(store)
        let originalCache = try Data(contentsOf:sceneURL)
        check(store.canConfirmCardMerge && store.scene == base,"ordered selection creates no scene mutation")
        store.cancelCardMerge()
        check(store.cardMergeDraft == nil && (try? Data(contentsOf:sceneURL)) == originalCache,"cancel preserves actual cache and source")
        queue(store)
        store.selectedNode = ids[1];store.selectedNode = ids[0]
        check(!store.confirmCardMerge() && store.scene == base,"selection ABA cannot confirm old selection intent")
        store.cancelCardMerge();queue(store)
        store.scene.revision += 1;store.scene = base
        check(!store.confirmCardMerge() && store.scene == base,"scene ABA cancels old draft")
        queue(store)
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:state.path)
        check(!store.confirmCardMerge() && store.scene == base && store.cardMergeDraft != nil,"actual cache write failure preserves draft and originals")
        check((try? Data(contentsOf:sceneURL)) == originalCache,"failed confirmation leaves actual cache bytes unchanged")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:state.path)
        check(store.confirmCardMerge(),"confirmation installs only after persistence")
        let merged = store.scene, mergedID = store.selectedNode!
        check(Array(merged.nodes.prefix(base.nodes.count)) == base.nodes && Array(merged.links.prefix(base.links.count)) == base.links,
              "all original nodes references parent child and ordinary links unchanged")
        check(merged.annotations.first == base.annotations.first && merged.strokes == base.strokes &&
              merged.drawingBase64 == base.drawingBase64 && store.drawing == drawing,"comments ink pressure and native drawing preserved")
        check(CanvasCardMerge.members(of:mergedID,in:merged)?.map(\.id) == [ids[1],ids[0]],"selected order survives domain representation")
        check(merged.nodes.last!.text.contains(texts[1] + "\n\n[2]\n" + texts[0]),"UTF8 CRLF NFD text copied in chosen order")
        await store.saveFileWorkspace()
        let saved = try files.load(base.id)
        check(saved.scene == merged && saved.preview == png && store.fileWorkspaceCanSync,"actual Files JSON drawing preview generation agrees")
        check(CanvasStore().scene == merged,"new Store reopens actual merged JSON and drawing")
        try CanvasFileWorkspace.bytes(merged).write(to:output.appendingPathComponent("merged-scene.json"))
        try png.write(to:output.appendingPathComponent("preview.png"))

        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:state.path)
        store.undoGraphEdit()
        check(store.scene == merged && store.canUndoGraph,"common Undo IO failure retains memory and history")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:state.path)
        store.undoGraphEdit();await store.saveFileWorkspace()
        check(store.scene.nodes == base.nodes && store.scene.links == base.links && store.scene.annotations == base.annotations,
              "common Undo restores graph without touching original ink")
        check(CanvasStore().scene == store.scene,"fresh Store reopens persisted Undo")
        store.redoGraphEdit();await store.saveFileWorkspace()
        check(store.scene.nodes == merged.nodes && store.scene.links == merged.links && store.scene.revision > merged.revision,
              "common Redo restores merge with monotonic revision")
        check(CanvasStore().scene == store.scene,"fresh Store reopens persisted Redo")
        check(!store.unmergeCard(store.scene.nodes.last!),"unmerge refuses missing selection after Undo removed that selection")
        store.select(mergedID)

        let beforeIO = try files.load(base.id)
        let sourcePointer = files.documentURL(base.id).appendingPathComponent("current.json")
        let pointerBytes = try Data(contentsOf:sourcePointer)
        let revisions = files.documentURL(base.id).appendingPathComponent("revisions")
        check(store.unmergeCard(store.scene.nodes.last!),"unmerge creates pending source change for failure check")
        let ioPending = store.scene
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:revisions.path)
        await store.saveFileWorkspace()
        check(store.fileWorkspaceState == .blocked && store.scene == ioPending &&
              (try? Data(contentsOf:sourcePointer)) == pointerBytes,"Files generation IO failure preserves prior source pointer and pending scene")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:revisions.path)
        store.retryFileWorkspaceSave();await store.saveFileWorkspace()
        check(store.fileWorkspaceCanSync && store.scene == ioPending,"IO retry publishes only same preserved pending unmerge")
        store.undoGraphEdit();await store.saveFileWorkspace()
        check(store.scene.nodes == beforeIO.scene.nodes && store.scene.links == beforeIO.scene.links,"common Undo after successful retry restores merge")

        var custom = store.scene
        let extra = CanvasAnnotation(id:UUID(),nodeId:mergedID,text:"병합 뒤의 유일한 사용자 댓글",author:"사용자")
        custom.annotations.append(extra)
        custom.nodes[custom.nodes.count - 1].text += "\n병합 뒤의 유일한 수정"
        let extraLink = CanvasLink(id:UUID(),from:mergedID,to:parents[0],label:"추가한 일반 링크")
        custom.links.append(extraLink);custom.revision += 1
        store.scene = custom
        let expected = store.scene.nodes.last!
        check(store.unmergeCard(expected),"explicit unmerge available after body edits")
        let unmerged = store.scene
        check(unmerged.nodes == custom.nodes && unmerged.annotations.contains(extra) && unmerged.links.contains(extraLink),
              "unmerge retains combined unique body comments and unrelated links")
        check(CanvasCardMerge.members(of:mergedID,in:unmerged) == nil &&
              base.links.allSatisfy(unmerged.links.contains),"unmerge removes only owned membership and preserves hierarchy")
        await store.saveFileWorkspace()
        check(CanvasStore().scene == unmerged,"fresh Store reopens unmerge without deleting source cards")
        store.undoGraphEdit();await store.saveFileWorkspace()
        check(CanvasCardMerge.members(of:mergedID,in:store.scene)?.map(\.id) == [ids[1],ids[0]],"common Undo reverses explicit unmerge")
        store.redoGraphEdit();await store.saveFileWorkspace()
        check(store.scene.nodes.last!.text.utf8.elementsEqual(custom.nodes.last!.text.utf8) && store.canUndoGraph,"Redo preserves unique combined body")

        // A separately persisted source edit is received through the existing refresh path.
        store.undoGraphEdit();await store.saveFileWorkspace()
        let oldAggregate = store.scene.nodes.last!
        let ownNotes = output.appendingPathComponent("own-note-fixtures",isDirectory:true)
        try FileManager.default.createDirectory(at:ownNotes,withIntermediateDirectories:true)
        var latest: [String:String] = [:]
        for i in 0..<2 { latest[paths[i]] = i == 0 ? "새 원문 e\u{301} 🖊️ ^alpha" : texts[i] }
        for (path,text) in latest { try Data(text.utf8).write(to:ownNotes.appendingPathComponent(URL(fileURLWithPath:path).lastPathComponent)) }
        store.setNoteConnection(address:context.relayAddress,token:context.token)
        await store.refreshVaultNotes { path in
            let bytes = try Data(contentsOf:ownNotes.appendingPathComponent(URL(fileURLWithPath:path).lastPathComponent))
            return .init(path:path,text:String(data:bytes,encoding:.utf8)!,sha256:CanvasPacket.sha(bytes),modifiedAt:"own-file")
        }
        check(store.scene.nodes.first { $0.id == ids[0] }!.vaultNote!.sha256 == CanvasPacket.sha(Data(latest[paths[0]]!.utf8)),
              "external source update received with same nodeID and new reference SHA")
        check(store.scene.nodes.last == oldAggregate && CanvasCardMerge.members(of:mergedID,in:store.scene)?.map(\.id) == [ids[1],ids[0]],
              "source refresh keeps ordered references and does not silently overwrite combined body")
        check(!store.canRedoGraph && !store.canUndoGraph,"external source update invalidates old card history")
        store.saveNow();await store.saveFileWorkspace()
        check(CanvasStore().scene == store.scene,"fresh Store reopens source refresh and merged provenance")

        // An external Files writer wins before our local unmerge is published.
        let head = try files.load(base.id)
        check(store.unmergeCard(store.scene.nodes.last!),"local unmerge can remain pending")
        let pending = store.scene
        var external = head.scene;external.nodes[0].text = "별도 Files writer";external.revision += 1
        _ = try files.save(external,preview:png,expected:head.token)
        let externalHead = try Data(contentsOf:files.documentURL(base.id).appendingPathComponent("current.json"))
        await store.saveFileWorkspace()
        check(store.fileWorkspaceState == .blocked && store.scene == pending,"external Files conflict retains pending local unmerge")
        let protectedExternal = try files.load(base.id)
        check(protectedExternal.scene == external,"external source is not overwritten by pending graph change")
        store.retryFileWorkspaceSave();await store.saveFileWorkspace()
        check((try? Data(contentsOf:files.documentURL(base.id).appendingPathComponent("current.json"))) == externalHead,
              "retry cannot unlock conflict and overwrite external pointer")
        check(CanvasStore().scene == pending,"restart retains pending current graph after conflict")

        // Real failure and malformed membership never destroy existing graph data.
        for change in ["duplicate","missing","label","marker"] {
            var damaged = merged
            if change == "duplicate" { damaged.links.append(damaged.links.last!) }
            if change == "missing" { damaged.nodes.removeAll { $0.id == ids[0] } }
            if change == "label" { damaged.links[damaged.links.count - 1].label += "x" }
            if change == "marker" { damaged.annotations[damaged.annotations.count - 1].text += "수정" }
            do { _ = try CanvasCardMerge.unmerging(mergedID,in:damaged);fatalError("accepted \(change)") }
            catch { check(CanvasCardMerge.members(of:mergedID,in:damaged) == nil,"malformed \(change) rejected without mutation") }
        }
        print("CARD_MERGE_CHECKS_OK \(count); actual files and PKDrawing; no UI/device/recognizer/HTTP")
    }
}
