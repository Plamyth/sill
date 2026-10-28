import Foundation
import PencilKit
import AppKit

@main struct CardTagChecks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(),label); count += 1; print("PASS \(label)")
    }
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder();encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated = CanvasRuntime.launch else { fatalError("isolated runtime required") }
        let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        struct Example: Decodable { let input: String; let markdown: String? }
        let examples = try JSONDecoder().decode([Example].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
        for example in examples {
            let actual = try? CanvasCardTags.markdown(example.input)
            check(actual.map { Array($0.utf8) } == example.markdown.map { Array($0.utf8) },"shared tag syntax \(count)")
        }
        let points = [10.0,30.0].enumerated().map { i,x in PKStrokePoint(location:CGPoint(x:x,y:x),timeOffset:Double(i)/10,
            size:CGSize(width:3,height:4),opacity:0.8,force:0.6,azimuth:0.3,altitude:1) }
        let drawing = try PKDrawing(data:PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),
            path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))]).dataRepresentation())
        let a=UUID(),b=UUID(),parent=UUID(),other=UUID()
        var base = CanvasScene();base.schemaVersion=3;base.drawingBase64=drawing.dataRepresentation().base64EncodedString()
        base.strokes=CanvasScene.nativeInkStrokes(drawing)
        base.nodes=[
            .init(id:parent,kind:.box,frame:.init(x:30,y:30,width:200,height:100),text:"기존 부모",confidence:.confirmed,sourceStrokeIds:[]),
            .init(id:a,kind:.note,frame:.init(x:30,y:200,width:260,height:120),text:"\u{feff}Alpha e\u{301}\r\n[[원문]] #본문문자열",confidence:.confirmed,sourceStrokeIds:[drawing.strokes[0].id],
                  vaultNote:.init(path:"Own/PDF-card.md",sha256:String(repeating:"a",count:64),relayAddress:"http://192.168.88.88:4242",blockID:"own-block",sourceState:.current)),
            .init(id:b,kind:.note,frame:.init(x:330,y:200,width:260,height:120),text:"Beta #일반본문",confidence:.confirmed,sourceStrokeIds:[]),
            .init(id:other,kind:.ellipse,frame:.init(x:700,y:100,width:100,height:80),text:"다른 도형",confidence:.confirmed,sourceStrokeIds:[])]
        _ = base.connectAsChild(parent:parent,child:a,label:"기존 계층")
        _ = base.connect(a,to:b,label:"기존 원문 관계")
        base.annotations=[.init(id:UUID(),nodeId:a,text:"유일 댓글 #댓글문자열 e\u{301}\r\n",author:"사용자")]
        let sceneURL=try CanvasRuntime.stateURL(.scene),state=sceneURL.deletingLastPathComponent()
        let folder=state.appendingPathComponent("selected-files",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        let files=CanvasFileWorkspace(folder:folder,requiresScope:false)
        _ = try files.save(base,preview:png,expected:nil)
        let binding=CanvasFileWorkspace.Binding(bookmark:try folder.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil),
                                               sceneID:base.id,savedSceneSHA:try CanvasFileWorkspace.sceneSHA(base))
        try CanvasLocalFile.write(CanvasFileWorkspace.bytes(base),to:sceneURL)
        try CanvasLocalFile.write(JSONEncoder().encode(binding),to:CanvasRuntime.stateURL(.workspace))
        let store=CanvasStore();store.mode = .select;store.selectedNode=a;store.filePreview={ _ in png }
        check(store.scene == base && store.fileWorkspaceCanSync,"actual Store restores original files and drawing")
        check(store.availableCardTags.isEmpty,"body PDF and ordinary comments never become classification tags")
        let initial=try Data(contentsOf:sceneURL)
        let cancelled=store.beginCardTagInput()!;store.cancelCardTagInput(sessionID:cancelled)
        check(!store.finishCardTagInput("취소",sessionID:cancelled) && store.scene == base,"cancel never applies or writes old input")
        let stale=store.beginCardTagInput()!;store.cancelCardTagInput(sessionID:stale)
        let current=store.beginCardTagInput()!
        check(!store.finishCardTagInput("old",sessionID:stale) && store.cardTagInputBusy,"old editor cannot finish or cancel a new editor")
        store.cancelCardTagInput(sessionID:stale)
        check(store.cardTagInputBusy,"stale cancel preserves current edit ownership")
        store.cancelCardTagInput(sessionID:current)
        for risk in ["selection","scene","mode","pencil"] {
            store.selectedNode=a
            let id=store.beginCardTagInput()!
            if risk == "selection" { store.selectedNode=b;store.selectedNode=a }
            if risk == "scene" { store.scene.revision += 1;store.scene=base }
            if risk == "mode" { store.mode = .pen;store.mode = .select }
            if risk == "pencil" { let owner=UUID();store.setPencilTraceActive(true,owner:owner);store.setPencilTraceActive(false,owner:owner) }
            check(!store.finishCardTagInput("stale",sessionID:id) && store.scene == base,"\(risk) ABA cannot apply stale tag")
        }
        store.selectedNode=a
        let blocked=store.beginCardTagInput()!
        check(!store.canApplyReconciledCanvas && !store.canBeginCardMerge,"tag input blocks shared replacement and merge")
        do { try store.importScene(base);fatalError("import while input") } catch { check(store.scene == base,"import refuses active tag input") }
        store.cancelCardTagInput(sessionID:blocked)
        for input in ["two words","#123","<tag>","a/b"] {
            let id=store.beginCardTagInput()!
            check(!store.finishCardTagInput(input,sessionID:id) && store.scene == base,"invalid tag preserves source \(input)")
        }
        let failing=store.beginCardTagInput()!
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:state.path)
        check(!store.finishCardTagInput("REA_TAG_20261021_A",sessionID:failing) && store.scene == base,"actual recovery write failure refuses tag install")
        check((try? Data(contentsOf:sceneURL)) == initial,"failed tag write leaves cache bytes unchanged")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:state.path)
        let accepted=store.beginCardTagInput()!
        check(store.finishCardTagInput("REA_TAG_20261021_A",sessionID:accepted),"tag added after successful actual cache write")
        let tagged=store.scene
        var identityWire=try JSONSerialization.jsonObject(with:bytes(tagged)) as! [String:Any]
        var identityAnnotations=identityWire["annotations"] as! [[String:Any]]
        identityAnnotations[identityAnnotations.count-1]["nodeId"]=a.uuidString.lowercased()
        identityWire["annotations"]=identityAnnotations
        let mixedUUID=try JSONDecoder().decode(CanvasScene.self,from:JSONSerialization.data(withJSONObject:identityWire))
        check((try? CanvasCardTags.tags(for:a,in:mixedUUID)) == ["#REA_TAG_20261021_A"],"UUID identity case matches relay without raw rewriting")
        var markerVariant=tagged
        markerVariant.annotations[markerVariant.annotations.count-1].author=CanvasCardTags.author.decomposedStringWithCanonicalMapping
        check(CanvasCardTags.available(in:markerVariant).isEmpty,"classification author marker requires exact UTF8")
        let originalNodes=try bytes(base.nodes),taggedNodes=try bytes(tagged.nodes)
        check(originalNodes == taggedNodes && tagged.links == base.links && tagged.strokes == base.strokes &&
              tagged.drawingBase64 == base.drawingBase64 && store.drawing == drawing,"tag preserves exact node body PDF refs hierarchy geometry and native drawing")
        check(tagged.annotations.first == base.annotations.first && store.availableCardTags == ["#REA_TAG_20261021_A"],"tag annotation and ordinary comment stay distinct")
        await store.saveFileWorkspace()
        let saved=try files.load(base.id)
        check(saved.scene == tagged && saved.preview == png,"actual Files source JSON drawing and preview agree")
        let fresh=CanvasStore()
        check(fresh.scene == tagged && fresh.availableCardTags == ["#REA_TAG_20261021_A"],"new Store rebuilds tag index from actual stored source")
        try CanvasFileWorkspace.bytes(base).write(to:output.appendingPathComponent("untagged-scene.json"))
        try CanvasFileWorkspace.bytes(tagged).write(to:output.appendingPathComponent("tagged-scene.json"))
        try png.write(to:output.appendingPathComponent("preview.png"))
        let duplicate=store.beginCardTagInput()!
        check(store.finishCardTagInput("rea_tag_20261021_a",sessionID:duplicate) && store.scene == tagged,"case-insensitive duplicate is exact no-op")
        let pointer=files.documentURL(base.id).appendingPathComponent("current.json")
        let beforeFilter=try Data(contentsOf:pointer)
        store.setCardTagFilter("#rea_tag_20261021_a")
        check(store.cardTagVisibility.nodeIDs.contains(a) && !store.cardTagVisibility.nodeIDs.contains(b) &&
              store.cardTagVisibility.nodeIDs.contains(parent) && store.cardTagVisibility.nodeIDs.contains(other),"single tag filters cards while keeping ink and non-card context")
        check(store.cardTagDisplayScene.nodes.map(\.id).contains(a) && !store.cardTagDisplayScene.nodes.map(\.id).contains(b),"Pele uses same derived card filter")
        store.selectLink(base.links[1].id)
        check(store.selectedLink == nil,"filtered-out link cannot receive stale selection or endpoint handles")
        store.select(b)
        check(store.selectedNode != b,"filtered-out card cannot receive hidden selection action")
        store.setCardTagFilter(nil)
        check(store.cardTagVisibility == tagged.visibility && store.scene == tagged && (try? Data(contentsOf:pointer)) == beforeFilter,"filter clear restores view without scene revision or disk writes")
        store.selectedNode=a
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:state.path)
        store.undoGraphEdit()
        check(store.scene == tagged && store.canUndoGraph,"common Undo IO failure keeps tag history and source")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:state.path)
        store.undoGraphEdit();await store.saveFileWorkspace()
        check(store.availableCardTags.isEmpty && store.scene.nodes == base.nodes && store.scene.annotations == base.annotations,"common Undo restores tag and original comment state")
        check(CanvasStore().availableCardTags.isEmpty,"new Store reopens persisted Undo")
        store.redoGraphEdit();await store.saveFileWorkspace()
        check(store.availableCardTags == ["#REA_TAG_20261021_A"] && CanvasStore().scene == store.scene,"common Redo restores stored Markdown tag and rebuilt index")
        let ready=try files.load(base.id)
        store.setCardTagFilter("#REA_TAG_20261021_A")
        store.selectLink(base.links[0].id)
        var external=ready.scene
        external.annotations[external.annotations.count-1].text="#외부"
        external.revision += 1
        _ = try files.save(external,preview:png,expected:ready.token)
        store.refreshFileWorkspace()
        check(store.scene == external && store.availableCardTags == ["#외부"] && !store.canUndoGraph,"external Files annotation change updates derived tags and invalidates stale Undo")
        check(store.selectedLink == nil,"external tag refresh clears link selection hidden by existing filter")
        check(CanvasStore().scene == external,"new Store reopens received external tag source")
        store.setCardTagFilter(nil)
        store.selectedNode=a
        let local=store.beginCardTagInput()!
        check(store.finishCardTagInput("local",sessionID:local),"local tag can remain pending")
        let pending=store.scene,head=try files.load(base.id)
        var competing=head.scene;competing.annotations.append(.init(id:UUID(),nodeId:b,text:"#rival",author:CanvasCardTags.author));competing.revision += 1
        _ = try files.save(competing,preview:png,expected:head.token)
        let rivalPointer=try Data(contentsOf:pointer)
        await store.saveFileWorkspace()
        check(store.fileWorkspaceState == .blocked && store.scene == pending,"external Files conflict retains pending local tag")
        store.retryFileWorkspaceSave();await store.saveFileWorkspace()
        let protected=try files.load(base.id)
        check(protected.scene == competing && (try? Data(contentsOf:pointer)) == rivalPointer,"retry cannot overwrite competing external tags")
        check(CanvasStore().scene == pending,"restart retains pending tag and originals after conflict")
        var duplicateRecord=tagged;duplicateRecord.annotations.append(duplicateRecord.annotations.last!)
        check((try? CanvasCardTags.tags(for:a,in:duplicateRecord)) == nil,"duplicate annotation identity is not silently merged")
        var duplicateName=tagged;duplicateName.annotations.append(.init(id:UUID(),nodeId:a,text:"#rea_tag_20261021_a",author:CanvasCardTags.author))
        check((try? CanvasCardTags.tags(for:a,in:duplicateName)) == nil,"duplicate tag identity is not silently selected")
        var orphan=tagged;orphan.annotations.append(.init(id:UUID(),nodeId:UUID(),text:"#orphan",author:CanvasCardTags.author))
        check(CanvasCardTags.available(in:orphan) == ["#REA_TAG_20261021_A"],"orphan records preserved without entering tag index")
        print("CARD_TAG_CHECKS_OK \(count); actual native/files; no UI/device/HTTP")
    }
}
