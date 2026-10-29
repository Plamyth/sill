import Foundation
import PencilKit

@main struct HierarchyOutlineChecks {
    static var checks:[String]=[]
    static func check(_ value:Bool,_ label:String) { precondition(value,label);checks.append(label);print("PASS",label) }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context)=CanvasRuntime.launch else { fatalError("isolated only") }
        let out=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        let sceneURL=try CanvasRuntime.stateURL(.scene),prefsURL=try CanvasRuntime.stateURL(.preferences)
        let key="canvas.hierarchyPresentation.v1", defaults=CanvasRuntime.defaults()
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==")!
        func store()->CanvasStore { let s=CanvasStore();s.enableDocumentChecks();s.filePreview={_ in png};s.setNoteConnection(address:context.relayAddress,token:context.token);return s }
        if CommandLine.arguments.contains("--reopen") {
            let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("expected.json"))) as! [String:Any],s=store()
            check(s.hierarchyOutlineVisible==expected["outline"] as! Bool,"fresh process restores view preference separately from source")
            check(try CanvasPacket.sha(s.document.bytes())==expected["documentSHA"] as! String,"fresh process reopens full original including hidden data")
            check(s.hierarchyOutlineRows.map{$0.id.uuidString}==expected["rows"] as! [String],"fresh process restores identical ordered visible IDs and collapse")
            if s.isDocumentSource { check(s.documentFileReady,"fresh process binds full document Files") }
            return
        }
        func reopen(_ s:CanvasStore)throws {
            let expected:[String:Any]=["outline":s.hierarchyOutlineVisible,"documentSHA":CanvasPacket.sha(try s.document.bytes()),"rows":s.hierarchyOutlineRows.map{$0.id.uuidString}]
            try JSONSerialization.data(withJSONObject:expected).write(to:out.appendingPathComponent("expected.json"))
            let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=[out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--reopen"]
            try p.run();p.waitUntilExit();check(p.terminationStatus==0,"separate process map/outline/source reopen completes")
        }
        // Own fixture setup only: distinguish absent preference from a later external non-string.
        for (label,value) in [("dictionary",["external":"keep"] as Any),("number",17 as Any)] {
            try CanvasLocalFile.write(Data("{}".utf8),to:prefsURL)
            let stale=store(), source=try stale.document.bytes()
            try defaults.set(value,forKey:key)
            let raw=try CanvasLocalFile.read(prefsURL)
            check(!stale.setHierarchyOutlineVisible(true,owner:stale.hierarchyFocusOwner),"absent then external \(label) refuses overwrite")
            check(try CanvasLocalFile.read(prefsURL)==raw && stale.document.bytes()==source,"external \(label) and original bytes remain intact")
        }
        try CanvasLocalFile.write(Data("{}".utf8),to:prefsURL)
        let points=[0.0,10,20].enumerated().map { i,d in PKStrokePoint(location:CGPoint(x:10+d,y:20+d),timeOffset:Double(i)/10,size:CGSize(width:3,height:5),opacity:0.8,force:0.7,azimuth:0.3,altitude:1) }
        let drawing=try PKDrawing(data:PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))]).dataRepresentation())
        var original=CanvasScene();original.schemaVersion=3;original.drawingBase64=drawing.dataRepresentation().base64EncodedString();original.strokes=CanvasScene.nativeInkStrokes(drawing)
        let a=original.addNode(kind:.note,at:.init(x:10,y:10),text:"부모"),b=original.addNode(kind:.note,at:.init(x:40,y:40),text:"자식"),c=original.addNode(kind:.note,at:.init(x:70,y:70),text:"손자"),d=original.addNode(kind:.note,at:.init(x:300,y:30),text:"숨은 원문"),m1=original.addNode(kind:.note,at:.init(x:400,y:40),text:"그룹 첫 원문"),m2=original.addNode(kind:.note,at:.init(x:500,y:40),text:"그룹 둘째 원문")
        _ = original.connectAsChild(parent:a,child:b);_ = original.connectAsChild(parent:b,child:c);_ = original.connect(c,to:d,label:"일반 교차 링크")
        let markdownURL=out.appendingPathComponent("own-source.md"),initialText="원래 Markdown 본문 e\u{301} 😀"
        try Data(initialText.utf8).write(to:markdownURL)
        original.nodes[original.nodes.firstIndex{$0.id==d}!].vaultNote = .init(path:"own-source.md",sha256:CanvasPacket.sha(Data(initialText.utf8)),relayAddress:context.relayAddress,sourceState:.current)
        original.annotations=[.init(id:UUID(),nodeId:c,text:"자손 주석",author:"사용자"),.init(id:UUID(),nodeId:d,text:"범위 밖 주석",author:"사용자"),.init(id:UUID(),nodeId:b,text:try CanvasCardTags.markdown("읽기"),author:CanvasCardTags.author)]
        let grouped=try CanvasGroup.Draft(scene:original,memberIDs:[m2,m1]).applying(to:original);original=grouped.scene
        let g=grouped.groupID
        try CanvasLocalFile.write(CanvasFileWorkspace.bytes(original),to:sceneURL)
        let s=store();s.selectedNode=a
        // The combined paper-vs-fold Undo guard must retain the stronger paper input barrier.
        s.applyPagePaper(.grid)
        check(try CanvasPagePaper.pattern(in:s.scene) == .grid && s.canUndoGraph,"combined source preserves paper Undo in original pen mode")
        let paperBytes=try s.document.bytes(), toolOwner=UUID()
        s.inkHistory.setUsingTool(true,owner:toolOwner);s.undoGraphEdit()
        check(try !s.canUndoGraph && s.document.bytes()==paperBytes,"active tool refuses paper Undo after outline guard composition")
        s.inkHistory.setUsingTool(false,owner:toolOwner);s.undoGraphEdit()
        check(try CanvasPagePaper.pattern(in:s.scene) == .plain && s.canRedoGraph,"paper Undo restores original annotation scope")
        let plainBytes=try s.document.bytes()
        s.inkHistory.setUsingTool(true,owner:toolOwner);s.redoGraphEdit()
        check(try !s.canRedoGraph && s.document.bytes()==plainBytes,"active tool also refuses paper Redo")
        s.inkHistory.setUsingTool(false,owner:toolOwner);s.redoGraphEdit();s.undoGraphEdit()
        check(try CanvasPagePaper.pattern(in:s.scene) == .plain && s.scene.annotations==original.annotations,"paper redo and undo preserve every original user annotation")
        let baseline=try s.document.bytes(),cache=try CanvasLocalFile.read(sceneURL),initialOwner=s.hierarchyFocusOwner
        check(s.mode == .pen,"fixture starts in original drawing mode")
        check(s.setHierarchyOutlineVisible(true,owner:initialOwner),"map to outline uses local view setting")
        check(try s.document.bytes()==baseline && CanvasLocalFile.read(sceneURL)==cache && s.selectedNode==a && s.mode == .pen,"view switch preserves canonical revision selection and input mode")
        let rows=s.hierarchyOutlineRows
        check(rows.first{$0.id==a}?.depth==0 && rows.first{$0.id==b}?.depth==1 && rows.first{$0.id==c}?.depth==2,"outline indents original ordinary parent-child IDs")
        let groupIndex=rows.firstIndex{$0.id==g}!
        check(rows[groupIndex+1].id==m2 && rows[groupIndex+2].id==m1 && rows[groupIndex+1].depth==1,"group members retain existing explicit order as display only")
        check(Set(rows.map(\.id))==s.cardTagVisibility.nodeIDs,"outline exactly matches current map visible IDs")
        check(s.selectHierarchyOutlineRow(b,owner:s.hierarchyFocusOwner) && s.selectedNode==b,"outline selection is same canonical card ID")
        check(s.toggleHierarchyOutlineRow(a,owner:s.hierarchyFocusOwner),"outline ordinary fold uses shared persisted transaction")
        check(!s.hierarchyOutlineRows.contains{$0.id==b} && s.scene.nodes.first{$0.id==a}?.isCollapsed==true,"same isCollapsed hides outline descendants")
        let foldedBytes=try s.document.bytes()
        s.inkHistory.setUsingTool(true,owner:toolOwner);s.undoGraphEdit()
        check(try !s.canUndoGraph && s.document.bytes()==foldedBytes,"new outline fold path cannot bypass active native input")
        s.inkHistory.setUsingTool(false,owner:toolOwner)
        check(s.setHierarchyOutlineVisible(false,owner:s.hierarchyFocusOwner),"outline returns to existing map")
        check(!s.cardTagVisibility.nodeIDs.contains(b) && s.canUndoGraph,"map shares fold and Undo even in preserved pen mode")
        s.undoGraphEdit();check(s.cardTagVisibility.nodeIDs.contains(c) && s.canRedoGraph,"map Undo restores same whole branch")
        check(s.setHierarchyOutlineVisible(true,owner:s.hierarchyFocusOwner),"outline reentry uses current whole branch state")
        s.redoGraphEdit();check(!s.hierarchyOutlineRows.contains{$0.id==b},"outline Redo shares original fold transaction")
        s.undoGraphEdit()
        check(s.toggleHierarchyOutlineRow(g,owner:s.hierarchyFocusOwner),"outline group disclosure reuses separate group toggle")
        check(!s.hierarchyOutlineRows.contains{$0.id==m1} && !s.cardTagVisibility.nodeIDs.contains(m2),"group collapse is shared across both projections")
        s.undoGraphEdit();check(s.hierarchyOutlineRows.contains{$0.id==m1},"group Undo restores same member IDs and order")
        let oldOutline=s.hierarchyFocusOwner
        check(s.setHierarchyOutlineVisible(false,owner:s.hierarchyFocusOwner) && s.setHierarchyOutlineVisible(true,owner:s.hierarchyFocusOwner),"outline-map-outline ABA returns to same source and view")
        check(!s.toggleHierarchyOutlineRow(a,owner:oldOutline),"old outline row callback rejects same-view ABA")
        s.vaultInputBusy=true
        check(!s.setHierarchyOutlineVisible(false,owner:s.hierarchyFocusOwner) && !s.toggleHierarchyOutlineRow(a,owner:s.hierarchyFocusOwner),"active native text input blocks view replacement and fold")
        s.vaultInputBusy=false
        check(!s.updateDrawing(PKDrawing()) && s.scene.drawingBase64==original.drawingBase64,"hidden outline ink cannot be overwritten")
        s.mode = .select;s.setCardTagFilter("#읽기")
        check(s.hierarchyOutlineRows.map(\.id).contains(b) && !s.hierarchyOutlineRows.map(\.id).contains(a) && Set(s.hierarchyOutlineRows.map(\.id))==s.cardTagVisibility.nodeIDs,"outline respects tag scope without creating hidden ancestors")
        s.setCardTagFilter(nil);s.selectedNode=b
        check(s.focusHierarchy(b,owner:s.hierarchyFocusOwner),"existing branch focus applies inside outline")
        check(s.hierarchyOutlineRows.map(\.id)==[b,c] && s.hierarchyOutlineRows.map(\.depth)==[0,1],"focused outline uses local visible indentation and original IDs")
        let oldSource=s.hierarchyFocusOwner,newText="외부 Markdown 본문 수정 e\u{301} 😀"
        try Data(newText.utf8).write(to:markdownURL)
        await s.refreshVaultNotes { path in
            let bytes=try Data(contentsOf:markdownURL)
            return VaultNoteSnapshot(path:path,text:String(decoding:bytes,as:UTF8.self),sha256:CanvasPacket.sha(bytes),modifiedAt:"")
        }
        check(s.scene.nodes.first{$0.id==d}?.vaultNote?.sha256==CanvasPacket.sha(Data(newText.utf8)),"actual external Markdown refresh updates hidden original reference")
        check(!s.toggleHierarchyOutlineRow(b,owner:oldSource) && s.hierarchyOutlineRows.map(\.id)==[b,c],"external source update invalidates old row owner without widening focus")
        check(s.leaveHierarchyFocus(owner:s.hierarchyFocusOwner),"focus exit keeps outline and original state")
        let groupNode=s.scene.nodes.first{$0.id==g}!
        check(s.toggleGroup(groupNode,owner:s.groupCommandOwner) && s.enterGroup(s.scene.nodes.first{$0.id==g}!,owner:s.groupCommandOwner),"existing group submap can be opened without redefining membership")
        check(s.hierarchyOutlineRows.map(\.id)==[m2,m1] && s.hierarchyOutlineRows.allSatisfy{$0.depth==0},"opened-group outline preserves exact member scope and order")
        check(s.setHierarchyOutlineVisible(false,owner:s.hierarchyFocusOwner) && s.openedGroupID==g,"map return preserves opened group view")
        check(s.setHierarchyOutlineVisible(true,owner:s.hierarchyFocusOwner) && s.openedGroupID==g,"outline reentry preserves opened group view")
        s.leaveGroup(owner:s.groupCommandOwner)
        s.saveNow();try reopen(s)
        let sceneBeforeDocument=s.scene
        try s.createDocument()
        let folder=out.appendingPathComponent("selected-files");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        await s.connectDocumentWorkspace(folder)
        check(s.documentFileReady && s.scene==sceneBeforeDocument,"actual whole Files generation includes shared map/outline source")
        let files=CanvasDocumentFiles(folder:folder,requiresScope:false)
        check(try files.load(s.document.id).document==s.document,"Files readback includes hidden links annotations native ink and references")
        let oldPage=s.hierarchyFocusOwner,pageA=s.scene.id
        await s.duplicateDocumentPage();let pageB=s.scene.id
        check(s.hierarchyOutlineVisible && Set(s.hierarchyOutlineRows.map(\.id))==s.cardTagVisibility.nodeIDs,"new page reuses outline view on its remapped original IDs")
        await s.selectDocumentPage(pageA);await s.selectDocumentPage(pageB);await s.selectDocumentPage(pageA)
        check(!s.toggleHierarchyOutlineRow(a,owner:oldPage),"page ABA rejects earlier outline callback")
        try reopen(s)
        let saved=try files.load(s.document.id);var external=saved.document;var page=external.activePage
        page.nodes[page.nodes.firstIndex{$0.id==b}!].text="외부 Files의 같은 카드 수정";page.revision += 1
        try external.replacePage(page,expectedRevision:external.revision)
        _ = try files.save(external,previews:Dictionary(uniqueKeysWithValues:external.pages.map{($0.id,png)}),expected:saved.token)
        let beforeReceive=s.hierarchyFocusOwner;s.refreshDocumentWorkspace()
        check(s.scene.nodes.first{$0.id==b}?.text=="외부 Files의 같은 카드 수정" && s.hierarchyOutlineRows.contains{$0.id==b},"external whole Files update appears in same outline card")
        check(!s.toggleHierarchyOutlineRow(a,owner:beforeReceive),"external Files read invalidates prior row edit owner")
        check(s.scene.drawingBase64==original.drawingBase64 && s.scene.strokes==original.strokes,"all switches folds undo IO and reverse updates preserve native ink")
        check(s.scene.links==original.links && s.scene.annotations==original.annotations,"no branch/group metadata general links or annotations were rewritten")
        let packet=try CanvasPacket(scene:s.scene,imagePNG:png,session:.init(threadId:UUID(),sessionId:"own-outline",observedAt:"own"))
        check(try JSONDecoder().decode(CanvasScene.self,from:Data(base64Encoded:packet.sceneJSONBase64)!)==s.scene,"AI packet retains entire original independent of outline visibility")
        let current=s.scene;var exhausted=current;exhausted.revision=Int.max;s.scene=exhausted
        check(!s.toggleHierarchyOutlineRow(a,owner:s.hierarchyFocusOwner) && s.scene==exhausted,"exhausted revision refuses fold without overflow or original replacement")
        s.scene=current
        let result:[String:Any]=["count":checks.count,"checks":checks,"actualStore":true,"actualFiles":true,"actualOwnMarkdownRead":true,"HTTP":false,"GUI":false,"device":false,"wholeOriginalAppAccepted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
    }
}
