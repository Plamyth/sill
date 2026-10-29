import Foundation
import PencilKit
import AppKit

private func groupCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw NSError(domain:"GroupChecks",code:1,userInfo:[NSLocalizedDescriptionKey:label]) }
    print("PASS \(label)")
}
private func groupPNG() -> Data {
    Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
}

@MainActor func checkGroups(output: URL) async throws {
    guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated only") }
    let windows = NSApplication.shared.windows.count
    let sceneURL = try CanvasRuntime.stateURL(.scene), state = sceneURL.deletingLastPathComponent()
    let folder = state.appendingPathComponent("group-selected-files")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let points = [10.0,20.0].enumerated().map { i,x in
        PKStrokePoint(location:.init(x:x,y:x),timeOffset:Double(i)/10,size:.init(width:3,height:4),opacity:0.7,force:0.6,azimuth:0.3,altitude:1)
    }
    let stroke = PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))
    let drawing = try PKDrawing(data:PKDrawing(strokes:[stroke]).dataRepresentation())
    var base = CanvasScene(); base.schemaVersion = 3
    base.drawingBase64 = drawing.dataRepresentation().base64EncodedString(); base.strokes = CanvasScene.nativeInkStrokes(drawing)
    var ids = [UUID]()
    for i in 0..<3 {
        let id = UUID(); ids.append(id)
        let text = "원문 \(i) e\u{301} 🖊️\r\n^source\(i)"
        base.nodes.append(.init(id:id,kind:.note,frame:.init(x:Double(i)*350 + 50,y:180,width:260,height:120),text:text,
                                confidence:.confirmed,sourceStrokeIds:i == 0 ? [stroke.id] : [],
                                vaultNote:.init(path:"Own/\(i).md",sha256:CanvasPacket.sha(Data(text.utf8)),relayAddress:context.relayAddress,blockID:"source\(i)",sourceState:.current)))
    }
    _ = base.connect(ids[0],to:ids[1],label:"원래 일반 연결")
    _ = base.connect(ids[0],to:ids[2],label:"숨은 카드와의 원래 연결")
    base.annotations = [.init(id:UUID(),nodeId:ids[0],text:"기존 댓글 e\u{301}\r\n",author:"사용자"),
                        .init(id:UUID(),nodeId:ids[2],text:"숨은 카드의 댓글",author:"사용자")]
    let files = CanvasFileWorkspace(folder:folder,requiresScope:false), png = groupPNG()
    _ = try files.save(base,preview:png,expected:nil)
    let binding = CanvasFileWorkspace.Binding(bookmark:try folder.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil),
        sceneID:base.id,savedSceneSHA:try CanvasFileWorkspace.sceneSHA(base))
    try CanvasLocalFile.write(CanvasFileWorkspace.bytes(base),to:sceneURL)
    try CanvasLocalFile.write(JSONEncoder().encode(binding),to:CanvasRuntime.stateURL(.workspace))
    let store = CanvasStore(); store.mode = .select; store.filePreview = { _ in png }
    try groupCheck(store.scene == base && store.fileWorkspaceCanSync,"actual Store and Files restore own native-ink scene")
    func queue() {
        store.selectedNode = ids[1]; store.beginGroup(owner:store.groupCommandOwner)
        store.selectedNode = ids[0]; store.appendGroupCard(owner:store.groupCommandOwner)
    }
    queue(); try groupCheck(store.canConfirmGroup && store.scene == base,"explicit ordered group selection does not mutate source")
    store.selectedNode = ids[2]; store.selectedNode = ids[0]
    try groupCheck(!store.confirmGroup() && store.scene == base,"selection ABA refuses old group draft")
    store.cancelGroupDraft(); queue(); store.scene.revision += 1; store.scene = base
    try groupCheck(!store.confirmGroup() && store.scene == base,"scene ABA refuses old group draft")
    queue(); store.cancelGroupDraft(); try groupCheck(store.groupDraft == nil && store.scene == base,"explicit cancel keeps all original cards")
    queue(); let priorCache = try Data(contentsOf:sceneURL)
    try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:state.path)
    try groupCheck(!store.confirmGroup() && store.groupDraft != nil && store.scene == base,"cache IO failure keeps ordered draft and original source")
    try groupCheck(Data(contentsOf:sceneURL) == priorCache,"failed group leaves cache bytes unchanged")
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:state.path)
    try groupCheck(store.confirmGroup(),"group installs after actual cache persistence")
    let groupID = store.selectedNode!, made = store.scene
    store.undoGraphEdit()
    try groupCheck(store.scene.nodes == base.nodes && store.scene.links == base.links && store.scene.annotations == base.annotations && store.scene.drawingBase64 == base.drawingBase64,"creation Undo removes only new group metadata and preserves originals")
    store.redoGraphEdit()
    try groupCheck(store.scene.nodes == made.nodes && store.scene.links == made.links && store.scene.annotations == made.annotations,"creation Redo restores the same CCR group and ordered IDs")
    try groupCheck(made.nodes.filter { ids.contains($0.id) } == base.nodes && made.links.starts(with:base.links),"original card IDs order frames references and ordinary links stay identical")
    try groupCheck(made.drawingBase64 == base.drawingBase64 && made.strokes == base.strokes && store.drawing == drawing && made.annotations.first == base.annotations.first,"native ink bytes pressure sourceStrokeIDs and old comments stay identical")
    try groupCheck(store.groups.first?.memberIDs == [ids[1],ids[0]] && store.groups.first?.node.kind == .box,"group reuses a box and ordered general links")
    var refusedHierarchy = made
    try groupCheck(!refusedHierarchy.connectAsChild(parent:ids[2],child:ids[0]) && refusedHierarchy == made,
                   "ordinary parentChild command cannot corrupt existing group membership")
    let owner = store.groupCommandOwner, node = store.groups[0].node
    store.scene.revision += 1; store.scene = made
    try groupCheck(!store.toggleGroup(node,owner:owner),"stale menu owner after scene ABA cannot fold a group")
    store.selectedNode = groupID
    try groupCheck(store.toggleGroup(node,owner:store.groupCommandOwner),"same group folds using persisted isCollapsed")
    let folded = store.scene, foldedNode = store.groups[0].node
    let beforeHierarchyNoop = try store.document.bytes(), beforeHierarchyOwner = store.groupCommandOwner
    store.toggleSelectedChildren()
    try groupCheck(store.scene == folded && store.document.bytes() == beforeHierarchyNoop && store.groupCommandOwner == beforeHierarchyOwner && !store.scene.canToggleChildren(of:groupID),"ordinary hierarchy fold cannot bypass group persistence or mutate document revision and owner")
    try groupCheck(!store.cardTagVisibility.nodeIDs.contains(ids[0]) && store.cardTagVisibility.nodeIDs.contains(groupID) && store.cardTagVisibility.nodeIDs.contains(ids[2]),"main map shows group summary and unrelated card while hiding members")
    let diagram = try CanvasDiagramSnapshot(scene:folded)
    try groupCheck(!diagram.nodes.contains(where:{ $0.id == ids[0] }) && diagram.nodes.contains(where:{ $0.id == groupID }),"existing diagram projection shares group collapse semantics")
    let savedSHA = try CanvasFileWorkspace.sceneSHA(store.scene)
    try groupCheck(store.enterGroup(foldedNode,owner:store.groupCommandOwner),"enter submap through bound owner and same group ID")
    try groupCheck(store.cardTagVisibility.nodeIDs == Set([ids[1],ids[0]]) && store.cardTagDisplayScene.nodes.map(\.id) == [ids[1],ids[0]],"submap projects the same two original cards in explicit membership order without copying a scene")
    try groupCheck(CanvasFileWorkspace.sceneSHA(store.scene) == savedSHA && store.drawing == drawing,"navigation changes neither canonical JSON nor shared native ink")
    store.select(ids[0]); try groupCheck(store.selectedNode == ids[0],"existing card selection targets the original member ID inside submap")
    store.leaveGroup(); try groupCheck(store.openedGroupID == nil && store.scene == folded,"return to main preserves persisted group state")
    try groupCheck(store.enterGroup(foldedNode,owner:store.groupCommandOwner),"same persisted membership re-enters the submap")
    let hiddenNodes = store.scene.nodes.filter { !store.cardTagVisibility.nodeIDs.contains($0.id) }
    let hiddenLinks = store.scene.links.filter { !store.cardTagVisibility.linkIDs.contains($0.id) }
    let hiddenAnnotations = store.scene.annotations.filter { !store.cardTagVisibility.annotationIDs.contains($0.id) }
    let beforeEdit = store.scene
    store.select(ids[0]); let commentID = store.beginCommentEdit()!
    store.commentText = "하위 지도에서 편집한 댓글 e\u{301}\r\n"
    try groupCheck(store.confirmComment(sessionID:commentID) && store.openedGroupID == groupID,"submap edits use the actual Store comment path on the original card")
    let bytes = JSONEncoder(); bytes.outputFormatting = [.sortedKeys]
    try groupCheck(bytes.encode(store.scene.nodes.filter { !store.cardTagVisibility.nodeIDs.contains($0.id) }) == bytes.encode(hiddenNodes) &&
                   bytes.encode(store.scene.links.filter { !store.cardTagVisibility.linkIDs.contains($0.id) }) == bytes.encode(hiddenLinks) &&
                   bytes.encode(store.scene.annotations.filter { !store.cardTagVisibility.annotationIDs.contains($0.id) }) == bytes.encode(hiddenAnnotations) &&
                   store.scene.drawingBase64 == beforeEdit.drawingBase64 && store.scene.strokes == beforeEdit.strokes,
                   "submap comment edit preserves bytes of hidden cards links annotations and all native ink")
    store.undoGraphEdit()
    try groupCheck(store.scene.hasSameGraph(as:beforeEdit) && store.scene.drawingBase64 == beforeEdit.drawingBase64,"common Undo restores full source rather than the projected subset")
    store.leaveGroup(); store.selectedNode = groupID
    try groupCheck(store.toggleGroup(foldedNode,owner:store.groupCommandOwner) && store.groups[0].node.id == groupID,"unfold keeps exact container and member identities")
    store.undoGraphEdit(); try groupCheck(store.groups[0].node.isCollapsed == true,"common persisted Undo restores group collapse")
    store.redoGraphEdit(); try groupCheck(store.groups[0].node.isCollapsed == false,"common persisted Redo restores group expansion")
    store.undoGraphEdit(); await store.saveFileWorkspace()
    let head = try files.load(base.id)
    try groupCheck(head.scene == store.scene && CanvasStore().scene == store.scene,"actual Files and fresh Store reopen identical ordered membership")
    try CanvasFileWorkspace.bytes(head.scene).write(to:output.appendingPathComponent("group-scene.json")); try png.write(to:output.appendingPathComponent("preview.png"))
    var external = head.scene
    let membership = external.links.indices.filter { external.links[$0].from == groupID && external.links[$0].label.hasPrefix(CanvasGroup.linkPrefix) }
    for (index,offset) in membership.enumerated() { external.links[offset].label = CanvasGroup.linkPrefix + String(2 - index) }
    external.nodes[0].text = "외부 제목 e\u{301}"
    external.annotations[0].text = "외부 댓글\r\n같은 원문"; external.revision += 1
    _ = try files.save(external,preview:png,expected:head.token); store.refreshFileWorkspace()
    try groupCheck(store.scene == external && store.groups[0].memberIDs == [ids[0],ids[1]],"external JSON order title and comment changes refresh through actual Files")
    try groupCheck(store.scene.nodes.filter { ids.contains($0.id) } == base.nodes && store.scene.drawingBase64 == base.drawingBase64,"reverse JSON editing preserves all source cards and native ink")
    store.selectedNode = groupID
    try groupCheck(store.toggleGroup(store.groups[0].node,owner:store.groupCommandOwner),"a local group edit may remain pending before Files publication")
    let pending = store.scene, latest = try files.load(base.id)
    var outside = latest.scene; outside.revision += 1; outside.nodes[0].text += " · 별도"
    _ = try files.save(outside,preview:png,expected:latest.token); await store.saveFileWorkspace()
    try groupCheck(store.fileWorkspaceState == .blocked && store.scene == pending && files.load(base.id).scene == outside,"Files CAS conflict retains pending group and refuses external overwrite")
    store.retryFileWorkspaceSave(); await store.saveFileWorkspace()
    try groupCheck(files.load(base.id).scene == outside,"retry cannot remove the existing Files conflict barrier")
    try CanvasFileWorkspace.bytes(pending).write(to:output.appendingPathComponent("group-expected-reopen.json"))
    for damage in ["duplicate","missing","version","cycle","parent","orphan","frame"] {
        var bad = made
        switch damage {
        case "duplicate": bad.links.append(bad.links.last!)
        case "missing": bad.nodes.removeAll { $0.id == ids[0] }
        case "version": bad.annotations[bad.annotations.count - 1].author = "ccr.sill.group/v2"
        case "cycle": bad.links[bad.links.count - 1].to = groupID
        case "parent": bad.links.append(.init(id:UUID(),from:ids[2],to:ids[0],label:"external",kind:.parentChild))
        case "frame": bad.nodes[bad.nodes.firstIndex(where:{ $0.id == ids[0] })!].frame.width = -1
        default: bad.annotations.removeLast()
        }
        do { _ = try CanvasGroup.entries(in:bad); throw NSError(domain:"accepted malformed group",code:1) }
        catch let error as CanvasGroup.Failure { try groupCheck(error == .unsupported,"malformed \(damage) is explicitly rejected with raw data preserved") }
    }
    var hierarchical = base; _ = hierarchical.connectAsChild(parent:ids[2],child:ids[0])
    try groupCheck(hierarchical.toggleChildren(of:ids[2]) && !hierarchical.visibility.nodeIDs.contains(ids[0]),"existing parentChild collapse remains separate and unchanged")
    do { _ = try CanvasGroup.Draft(scene:hierarchical,memberIDs:[ids[0]]); throw NSError(domain:"accepted parentChild",code:1) }
    catch is CanvasGroup.Failure { print("PASS parentChild membership is not converted to a group") }
    let single = try CanvasGroup.Draft(scene:base,memberIDs:[ids[0]]).applying(to:base)
    try groupCheck(CanvasGroup.entries(in:single.scene)[0].memberIDs == [ids[0]],"REA-observed single-card group is supported")
    let merge = try CanvasCardMerge.Draft(scene:base,memberIDs:[ids[1],ids[0]]).applying(to:base)
    try groupCheck(CanvasCardMerge.members(of:merge.cardID,in:merge.scene)?.map(\.id) == [ids[1],ids[0]],"existing merge uses the shared ordered-link parser with unchanged behavior")
    try groupCheck(NSApplication.shared.windows.count == windows,"group checks open no native window")
    print("GROUP_SUBMAP_FILES_OK")
}

@MainActor func checkGroupsReopen(output: URL) throws {
    let expected = try JSONDecoder().decode(CanvasScene.self,from:Data(contentsOf:output.appendingPathComponent("group-expected-reopen.json")))
    let store = CanvasStore(); store.mode = .select
    try groupCheck(store.scene == expected && store.openedGroupID == nil,"new process reopens pending canonical group without a second map database")
    try groupCheck(store.groups.count == 1 && store.groups[0].memberIDs.count == 2,"new process derives exact ordered membership from the same JSON")
    print("GROUP_SUBMAP_REOPEN_OK")
}

@MainActor func checkGroupsDocument(output: URL) async throws {
    let base = try JSONDecoder().decode(CanvasScene.self,from:Data(contentsOf:output.appendingPathComponent("group-scene.json")))
    let sceneURL = try CanvasRuntime.stateURL(.scene)
    try CanvasLocalFile.write(CanvasFileWorkspace.bytes(base),to:sceneURL)
    let binding = try CanvasRuntime.stateURL(.workspace); if FileManager.default.fileExists(atPath:binding.path) { try FileManager.default.removeItem(at:binding) }
    let store = CanvasStore(); store.mode = .select; store.enableDocumentChecks(); store.filePreview = { _ in groupPNG() }
    try store.createDocument()
    let folder = output.resolvingSymlinksInPath().appendingPathComponent("group-document-files",isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    await store.connectDocumentWorkspace(folder)
    print("GROUP_DOCUMENT_BIND",store.isDocumentSource,store.documentFileReady,store.documentBusy,store.status,store.fileWorkspaceStatus)
    try groupCheck(store.documentFileReady,"group page uses existing whole-document Files storage")
    let firstID = store.scene.id, first = store.scene, oldOwner = store.groupCommandOwner, group = store.groups[0].node
    try groupCheck(store.enterGroup(group,owner:oldOwner),"group opens within the actual active document page")
    await store.duplicateDocumentPage()
    try groupCheck(store.document.pages.count == 2 && store.scene.id != firstID && store.openedGroupID == nil,"page transition closes submap view and keeps group membership page-local")
    try groupCheck(store.groups.count == 1 && store.groups[0].memberIDs != CanvasGroup.entries(in:first)[0].memberIDs,"existing page duplication remaps only same-page group links and card IDs")
    await store.selectDocumentPage(firstID)
    try groupCheck(!store.enterGroup(group,owner:oldOwner) && !store.toggleGroup(group,owner:oldOwner),"page ABA rejects old group menu owner after returning to the same page")
    try groupCheck(store.scene == first && store.document.pages.count == 2,"other page actions do not rewrite the original group page")
    try groupCheck(CanvasFileWorkspace.bytes(store.scene) == CanvasFileWorkspace.bytes(first),"page return retains canonical bytes of hidden cards links annotations and original ink")
    let files = CanvasDocumentFiles(folder:folder,requiresScope:false), loaded = try files.load(store.document.id)
    try groupCheck(loaded.document == store.document,"whole document reopen preserves both page-local group graphs and original ink")
    try groupCheck(CanvasStore().document == store.document,"fresh Store restores the whole document and ordered group without external state")
    print("GROUP_SUBMAP_DOCUMENT_OK")
}
