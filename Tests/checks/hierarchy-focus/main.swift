import Foundation
import AppKit
import PencilKit

@main struct HierarchyFocusChecks {
    static var checks:[String]=[]
    static func check(_ value:Bool,_ name:String) { precondition(value,name); checks.append(name); print("PASS",name) }
    static func drawing(_ x:Double) throws -> PKDrawing {
        let points=[0.0,10,20].enumerated().map { i,d in PKStrokePoint(location:CGPoint(x:x+d,y:30+d),timeOffset:Double(i)/10,size:CGSize(width:3,height:5),opacity:0.8,force:0.65,azimuth:0.3,altitude:1) }
        return try PKDrawing(data:PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))]).dataRepresentation())
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context)=CanvasRuntime.launch else { fatalError("isolated only") }
        let out=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        let sceneURL=try CanvasRuntime.stateURL(.scene), prefsURL=try CanvasRuntime.stateURL(.preferences)
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==")!
        func store()->CanvasStore { let s=CanvasStore();s.enableDocumentChecks();s.mode = .select;s.filePreview={_ in png};return s }
        if CommandLine.arguments.contains("--reopen") {
            let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("expected.json"))) as! [String:Any]
            let s=store(), root=(expected["root"] as? String).flatMap(UUID.init(uuidString:))
            check(s.hierarchyFocusRootID==root,"new process restores current view root separately from source")
            check(s.hierarchyFocusVisits.map(\.uuidString)==expected["visits"] as! [String],"new process retains independent visit history")
            let bytes=try s.document.bytes()
            check(CanvasPacket.sha(bytes)==expected["documentSHA"] as! String,"new process reopens whole canonical document with hidden original data")
            if s.isDocumentSource { check(s.documentFileReady,"new process rebinds complete Files generation") }
            return
        }
        func reopen(_ s:CanvasStore) throws {
            var expected:[String:Any]=["visits":s.hierarchyFocusVisits.map(\.uuidString),"documentSHA":CanvasPacket.sha(try s.document.bytes())]
            if let id=s.hierarchyFocusRootID { expected["root"]=id.uuidString }
            try JSONSerialization.data(withJSONObject:expected).write(to:out.appendingPathComponent("expected.json"))
            let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=[out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--reopen"]
            try p.run();p.waitUntilExit();check(p.terminationStatus==0,"separate process completes view/source reopen")
        }
        let native=try drawing(10)
        var scene=CanvasScene();scene.schemaVersion=3;scene.drawingBase64=native.dataRepresentation().base64EncodedString();scene.strokes=CanvasScene.nativeInkStrokes(native)
        let a=scene.addNode(kind:.note,at:.init(x:20,y:20),text:"부모"),b=scene.addNode(kind:.note,at:.init(x:50,y:60),text:"자식"),c=scene.addNode(kind:.note,at:.init(x:80,y:100),text:"손자"),d=scene.addNode(kind:.note,at:.init(x:300,y:20),text:"범위 밖 원문")
        let m1=scene.addNode(kind:.note,at:.init(x:400,y:20),text:"그룹 1"),m2=scene.addNode(kind:.note,at:.init(x:500,y:20),text:"그룹 2")
        check(scene.connectAsChild(parent:a,child:b) && scene.connectAsChild(parent:b,child:c),"fixture has ordinary parent-child branches")
        _ = scene.connect(b,to:d,label:"숨은 교차 연결")
        scene.annotations=[.init(id:UUID(),nodeId:b,text:"자식 주석",author:"사용자"),.init(id:UUID(),nodeId:d,text:"숨은 원문 주석",author:"사용자"),.init(id:UUID(),nodeId:nil,text:"지도 주석",author:"사용자")]
        let grouped=try CanvasGroup.Draft(scene:scene,memberIDs:[m1,m2]).applying(to:scene);scene=grouped.scene
        let groupID=grouped.groupID
        scene = try CanvasGroup.toggling(scene.nodes.first{$0.id==groupID}!,in:scene)
        scene = try CanvasPagePaper.applying(.grid,to:scene)
        let full=try CanvasFileWorkspace.bytes(scene)
        try CanvasLocalFile.write(full,to:sceneURL)
        var s=store();s.selectedNode=a
        if CommandLine.arguments.contains("--aba-only") {
            let original = try s.document.bytes()
            check(s.focusHierarchy(a,owner:s.hierarchyFocusOwner),"ABA enters original A root")
            let oldA = s.hierarchyFocusOwner
            check(s.focusHierarchy(b,owner:s.hierarchyFocusOwner),"ABA enters child B root")
            check(s.focusHierarchyParent(owner:s.hierarchyFocusOwner) && s.hierarchyFocusRootID==a && s.selectedNode==a,"ABA returns to same A root and selected UUID")
            check(!s.focusHierarchy(c,owner:oldA) && s.hierarchyFocusRootID==a,"same-root ABA rejects old A callback by monotonic owner")
            check(try s.document.bytes()==original,"ABA never changes canonical original or revision")
            try JSONSerialization.data(withJSONObject:["count":checks.count,"checks":checks,"ABAOnly":true,"whole58Repeated":false],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
            return
        }
        let undoManager=s.inkHistory.activate(s.nativeHistoryOwner)
        var nativeUndoCalls=0
        undoManager.beginUndoGrouping();undoManager.registerUndo(withTarget:s) { _ in nativeUndoCalls += 1 };undoManager.endUndoGrouping()
        check(s.inkHistory.commandAvailability.canUndo,"existing native Undo owner has an action before focus")
        let docBefore=try s.document.bytes(), cacheBefore=try CanvasLocalFile.read(sceneURL), beforeOwner=s.hierarchyFocusOwner
        let focused=s.focusHierarchy(a,owner:beforeOwner)
        if !focused { print("FOCUS",s.status,s.hierarchyFocusNotice,s.sceneRecoveryNotice,s.hierarchyFocusInputAllowed,s.groupReadError ?? "") }
        check(focused,"selected ordinary card enters focus")
        s.inkHistory.undo()
        check(nativeUndoCalls==0 && undoManager.canUndo && !s.inkHistory.commandAvailability.canUndo,"focused native Undo refuses without consuming original action")
        check(s.cardTagVisibility.nodeIDs==Set([a,b,c]),"projection shows root and descendants only")
        check(s.cardTagVisibility.annotationIDs==Set([scene.annotations[0].id]),"projection excludes outside/global comments without deletion")
        check(try s.document.bytes()==docBefore && CanvasLocalFile.read(sceneURL)==cacheBefore,"focus leaves canonical document revision cache and hidden bytes untouched")
        check(s.scene==scene && s.drawing==native,"full links groups comments native ink and pressure remain authoritative")
        check(try CanvasPagePaper.pattern(in:s.scene) == .grid,"focus preserves canonical paper metadata while native ink is hidden")
        check(!s.updateDrawing(try drawing(200)) && s.drawing==native,"hidden Pencil drawing cannot mutate focused original")
        s.setInkSelection(Set(native.strokes.map(\.id)))
        check(s.inkSelection.isEmpty,"hidden native selection is refused")
        let packet=try CanvasPacket(scene:s.scene,imagePNG:png,session:.init(threadId:UUID(),sessionId:"own-focus",observedAt:"own"))
        check(try JSONDecoder().decode(CanvasScene.self,from:Data(base64Encoded:packet.sceneJSONBase64)!)==scene,"AI packet includes full source rather than focused projection")
        check(!s.focusHierarchy(d,owner:beforeOwner),"old selection/view callback cannot focus outside branch")
        s.selectedNode=b;check(s.focusHierarchy(b,owner:s.hierarchyFocusOwner),"child focus uses same stable card ID")
        let childOwner=s.hierarchyFocusOwner
        check(s.cardTagVisibility.nodeIDs==Set([b,c]),"child subtree projection excludes parent")
        check(s.focusHierarchyParent(owner:s.hierarchyFocusOwner) && s.hierarchyFocusRootID==a,"parent action follows original hierarchy")
        check(!s.focusHierarchy(c,owner:childOwner),"child-to-parent transition rejects former view callback")
        try reopen(s)
        check(s.hierarchyFocusVisits==[b,a],"current root and unique ordered visit history are separate")
        check(s.focusHierarchyParent(owner:s.hierarchyFocusOwner) && s.hierarchyFocusRootID==nil,"top-level branch parent returns to full view")
        s.selectedNode=a;check(s.focusHierarchy(a,owner:s.hierarchyFocusOwner),"explicit root focus resumes before editing")
        // Source edit and Undo remain whole-original transactions while focused.
        s.selectedNode=b
        check(s.rotateNode(s.scene.nodes.first{$0.id==b}!,sceneID:s.scene.id,to:30),"focused visible card edit uses existing graph transaction")
        check(s.hierarchyFocusRootID==a && s.canUndoGraph && s.scene.nodes.first{$0.id==d}==scene.nodes.first{$0.id==d},"focused edit retains root Undo and hidden card")
        let sourceAfterEdit=s.scene
        s.undoGraphEdit()
        check(s.scene.nodes==scene.nodes && s.scene.links==scene.links && s.hierarchyFocusRootID==a,"Undo restores full graph without treating focus as edit")
        check(s.canRedoGraph,"focus preserves existing Redo ownership")
        // Existing collapse and groups keep their state; root ignores ancestors outside its projection.
        s.selectedNode=b;s.toggleSelectedChildren()
        check(s.cardTagVisibility.nodeIDs==Set([a,b]) && s.scene.nodes.first{$0.id==b}?.isCollapsed==true,"existing collapsed child stays folded within focus")
        check(s.focusHierarchy(b,owner:s.hierarchyFocusOwner),"collapsed card can be focused without changing fold flag")
        check(s.cardTagVisibility.nodeIDs==Set([b]),"root fold is preserved")
        check(s.leaveHierarchyFocus(owner:s.hierarchyFocusOwner),"full return exits only view focus")
        check(s.inkHistory.commandAvailability.canUndo,"full return restores same native Undo action")
        check(s.scene.nodes.first{$0.id==b}?.isCollapsed==true && !s.cardTagVisibility.nodeIDs.contains(m1),"full return preserves fold and collapsed-group visibility")
        let groupNode=s.scene.nodes.first{$0.id==groupID}!
        check(s.enterGroup(groupNode,owner:s.groupCommandOwner),"existing group submap still opens independently")
        check(!s.canFocusHierarchy(m1),"ordinary branch focus does not replace active group view")
        s.leaveGroup(owner:s.groupCommandOwner)
        s.selectedNode=b;s.toggleSelectedChildren();s.selectedNode=a
        check(s.focusHierarchy(a,owner:s.hierarchyFocusOwner),"ordinary focus resumes after leaving group")
        let valid=s.scene
        var missing=valid;missing.nodes.removeAll{$0.id==a};missing.links.removeAll{$0.from==a || $0.to==a};missing.revision += 1
        s.scene=missing
        check(s.hierarchyFocusRootID==nil && !s.hierarchyFocusNotice.isEmpty && s.scene==missing,"external missing root falls back explicitly without altering received source")
        s.scene=valid;s.selectedNode=a;check(s.focusHierarchy(a,owner:s.hierarchyFocusOwner),"valid original can be explicitly focused again")
        var cycle=valid;cycle.links.append(.init(id:UUID(),from:c,to:a,label:"cycle",kind:.parentChild));cycle.revision += 1
        s.scene=cycle
        check(s.hierarchyFocusRootID==nil && !s.canFocusHierarchy(b) && s.scene==cycle,"cycle refuses focus without pruning original links")
        s.scene=valid;s.saveNow();s.selectedNode=a
        check(!s.focusHierarchy(UUID(),owner:s.hierarchyFocusOwner),"nonexistent root refuses without guessing")
        check(s.focusHierarchy(a,owner:s.hierarchyFocusOwner),"focus restored before preference conflict")
        let preference=CanvasRuntime.defaults(), originalText=preference.string(forKey:"canvas.hierarchyFocus.v1")!
        try preference.set(originalText+" ",forKey:"canvas.hierarchyFocus.v1")
        let externalPreference=try CanvasLocalFile.read(prefsURL)
        s.selectedNode=b
        check(!s.focusHierarchy(b,owner:s.hierarchyFocusOwner) && s.hierarchyFocusRootID==a,"external view preference change refuses stale overwrite")
        check(try CanvasLocalFile.read(prefsURL)==externalPreference,"preference conflict preserves external bytes")
        s=store();s.selectedNode=a
        check(s.hierarchyFocusRootID==a,"fresh Store reads independently modified valid preference")
        // Ordered multi-page source, full Files generation and reverse source update.
        check(s.leaveHierarchyFocus(owner:s.hierarchyFocusOwner),"leave before explicit legacy-to-document entry")
        try s.createDocument()
        let folder=out.appendingPathComponent("selected-files");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        await s.connectDocumentWorkspace(folder)
        check(s.documentFileReady,"canonical Document binds actual complete Files source")
        s.selectedNode=a;check(s.focusHierarchy(a,owner:s.hierarchyFocusOwner),"document page focus is independent of legacy state")
        let documentBytes=try s.document.bytes(), pageA=s.scene.id
        await s.saveDocumentWorkspace()
        let files=CanvasDocumentFiles(folder:folder,requiresScope:false)
        check(try files.load(s.document.id).document.bytes()==documentBytes,"Files save while focused stores whole hidden graph and native ink")
        let previews=Dictionary(uniqueKeysWithValues:s.document.pages.map{($0.id,png)})
        let (put,_,_)=try CanvasDocumentRelay.Put.make(bytes:s.document.bytes(),previews:previews,base:nil)
        check(try Data(base64Encoded:put.documentJSONBase64)==s.document.bytes(),"document Relay PUT contains whole document bytes")
        let oldPageOwner=s.hierarchyFocusOwner
        await s.duplicateDocumentPage()
        check(s.scene.id != pageA && s.hierarchyFocusRootID==nil,"duplicated page starts its own view without reusing old root ID")
        let pageB=s.scene.id, newRoot=s.scene.nodes.first{$0.text=="부모"}!.id
        s.selectedNode=newRoot;check(s.focusHierarchy(newRoot,owner:s.hierarchyFocusOwner),"second page uses remapped original card identity")
        await s.selectDocumentPage(pageA)
        check(s.hierarchyFocusRootID==a,"page return restores its own focus")
        await s.selectDocumentPage(pageB);await s.selectDocumentPage(pageA)
        check(!s.focusHierarchy(b,owner:oldPageOwner),"page ABA cannot reuse earlier command owner")
        try reopen(s)
        let saved=try files.load(s.document.id);var remote=saved.document;var page=remote.activePage
        page.nodes[page.nodes.firstIndex{$0.id==d}!].text="외부 전체원문 수정";page.revision += 1
        try remote.replacePage(page,expectedRevision:remote.revision)
        _ = try files.save(remote,previews:Dictionary(uniqueKeysWithValues:remote.pages.map{($0.id,png)}),expected:saved.token)
        s.refreshDocumentWorkspace()
        check(s.hierarchyFocusRootID==a && s.scene.nodes.first{$0.id==d}?.text=="외부 전체원문 수정","actual external Files change refreshes hidden source while focus remains valid")
        check(!s.cardTagVisibility.nodeIDs.contains(d) && s.document.pages.count==2,"inverse source read keeps view projection separate from full document")
        check(s.scene.drawingBase64==scene.drawingBase64 && s.scene.strokes==scene.strokes,"all navigation editing IO and inverse-read paths preserve native ink")
        check(try CanvasPagePaper.pattern(in:s.scene) == .grid,"page navigation and inverse Files reads preserve paper settings alongside focus")
        check(s.scene.nodes.first{$0.id==groupID}==valid.nodes.first{$0.id==groupID},"group state remains byte-equivalent after ordinary focus and Files roundtrip")
        let latest=try files.load(s.document.id);var removed=latest.document;var withoutRoot=removed.activePage
        withoutRoot.nodes.removeAll{$0.id==a};withoutRoot.links.removeAll{$0.from==a || $0.to==a};withoutRoot.annotations.removeAll{$0.nodeId==a};withoutRoot.revision += 1
        try removed.replacePage(withoutRoot,expectedRevision:removed.revision)
        _ = try files.save(removed,previews:Dictionary(uniqueKeysWithValues:removed.pages.map{($0.id,png)}),expected:latest.token)
        s.refreshDocumentWorkspace()
        check(s.hierarchyFocusRootID==nil && !s.hierarchyFocusNotice.isEmpty && s.scene==withoutRoot,"actual external Files root removal preserves entire received page and falls back explicitly")
        check(s.hierarchyFocusVisits.contains(a),"external removal never deletes visit history as if it were source")
        try reopen(s)
        let result:[String:Any]=["count":checks.count,"checks":checks,"sourceSHA":CanvasPacket.sha(full),"editedSHA":try CanvasFileWorkspace.sceneSHA(sourceAfterEdit),"actualStore":true,"actualFiles":true,"GUI":false,"HTTP":false,"device":false,"wholeOriginalAppAccepted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
    }
}
