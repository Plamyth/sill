import Foundation
import AppKit
import PencilKit

@MainActor private final class SearchGate {
    private var answer: CheckedContinuation<[Set<UUID>],Error>?
    private var waiting: CheckedContinuation<Void,Never>?
    private var started = false
    func search(_ drawing: PKDrawing,_ query: String) async throws -> [Set<UUID>] {
        try await withCheckedThrowingContinuation { continuation in
            answer = continuation; started = true; waiting?.resume(); waiting = nil
        }
    }
    func wait() async {
        if !started { await withCheckedContinuation { waiting = $0 } }
    }
    func finish(_ value: [Set<UUID>]) { answer!.resume(returning:value); answer = nil }
    func fail() { answer!.resume(throwing:CocoaError(.fileReadUnknown)); answer = nil }
}

@MainActor private final class UndoCounter: NSObject { var calls = 0 }

@main struct SearchNavigationChecks {
    static var checks = [String]()
    static func check(_ value: Bool,_ name: String) {
        precondition(value,name);checks.append(name);print("PASS",name)
    }
    static func stroke(_ x: CGFloat,_ y: CGFloat) -> PKStroke {
        let points = [CGPoint(x:x,y:y),CGPoint(x:x+60,y:y+30)].enumerated().map { i,p in
            PKStrokePoint(location:p,timeOffset:Double(i)/10,size:CGSize(width:3,height:5),opacity:0.8,force:0.7,azimuth:0.2,altitude:1)
        }
        return PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated = CanvasRuntime.launch else { fatalError("isolated required") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        let size = CGSize(width:640,height:420)
        let origin = CanvasViewport()
        let box = CGRect(x:1600,y:1000,width:80,height:40)
        let moved = origin.revealing(box,in:size)!
        check(moved.zoom == origin.zoom && CGRect(origin:.zero,size:size).contains(box.offsetBy(dx:moved.pan.width,dy:moved.pan.height)),"화면 밖 결과를 현재 배율의 표시 영역으로 이동")
        let near = CGRect(x:50,y:50,width:80,height:40)
        check(origin.revealing(near,in:size) == origin,"이미 보이는 결과는 viewport를 쓰지 않음")
        let zoomed = CanvasViewport(zoom:2,pan:CGSize(width:80,height:-90)).revealing(box,in:size)!
        check(zoomed.zoom == 2 && abs(box.midX * 2 + zoomed.pan.width - size.width / 2) < 0.001,"확대와 기존 pan을 고려한 결과 중심 좌표")
        let wide = CGRect(x:200,y:200,width:1400,height:500)
        let wideView = origin.revealing(wide,in:size)!
        check(wideView.zoom == 1 && wide.midX + wideView.pan.width == size.width / 2,"화면보다 큰 결과는 배율을 바꾸지 않고 중심을 표시")
        for invalid in [CGSize.zero,CGSize(width:0,height:20),CGSize(width:-1,height:20),CGSize(width:CGFloat.infinity,height:20)] {
            check(origin.revealing(box,in:invalid) == nil,"측정되지 않거나 비정상 화면 크기 거부 \(invalid)")
        }
        check(origin.revealing(.null,in:size) == nil && CanvasViewport(zoom:.nan).revealing(box,in:size) == nil,"비정상 bounds와 배율은 성공으로 표시하지 않음")
        let first = stroke(1600,1000), second = stroke(40,40)
        let ink = try PKDrawing(data:PKDrawing(strokes:[first,second]).dataRepresentation())
        var scene = CanvasScene();scene.schemaVersion = 3;scene.width = 2400;scene.height = 1600
        scene.drawingBase64 = ink.dataRepresentation().base64EncodedString();scene.strokes = CanvasScene.nativeInkStrokes(ink)
        let a = scene.addNode(kind:.note,at:.init(x:300,y:200),text:"한글 원문 e\u{301}")
        let b = scene.addNode(kind:.note,at:.init(x:700,y:300),text:"숨은 본문")
        scene.nodes[0].sourceStrokeIds = [first.id];_ = scene.connect(a,to:b,label:"원문 관계")
        scene.annotations = [.init(id:UUID(),nodeId:a,text:"원본 주석",author:"사용자")]
        func makeStore(_ source: CanvasScene = scene) throws -> CanvasStore {
            let s = CanvasStore();s.enableDocumentChecks()
            try s.importSourceBytes(CanvasFileWorkspace.bytes(source))
            s.mode = .pen;s.setHandwritingSearchSurface(size);s.saveNow()
            return s
        }
        let s = try makeStore()
        s.mode = .select;s.selectedNode = a
        if CommandLine.arguments.contains("--view-only") {
            let original = try s.document.bytes()
            for kind in ["focus","outline"] {
                let captured = s.captureHandwritingSearchOwner()!
                if kind == "focus" {
                    check(s.focusHierarchy(a,owner:s.hierarchyFocusOwner) && s.leaveHierarchyFocus(owner:s.hierarchyFocusOwner),"deferred menu intent crosses actual focus ABA before dispatch")
                } else {
                    check(s.setHierarchyOutlineVisible(true,owner:s.hierarchyFocusOwner) && s.setHierarchyOutlineVisible(false,owner:s.hierarchyFocusOwner),"deferred menu intent crosses actual outline ABA before dispatch")
                }
                var called = false
                await s.searchHandwriting("한글",owner:captured) { _,_ in called=true;return [[first.id]] }
                check(!called && s.viewport==CanvasViewport() && s.inkSelection.isEmpty,"old \(kind) menu intent refuses before native provider starts")
            }
            let cancelled = s.captureHandwritingSearchOwner()!
            s.cancelHandwritingSearch();var dispatched=false
            await s.searchHandwriting("한글",owner:cancelled) { _,_ in dispatched=true;return [[first.id]] }
            check(!dispatched,"explicit cancellation retires an unstarted menu Task")
            for kind in ["focus","outline"] {
                let gate = SearchGate(), viewport = s.viewport
                let task = Task { @MainActor in await s.searchHandwriting("한글",search:gate.search) }
                await gate.wait()
                if kind == "focus" {
                    check(!s.focusHierarchy(a,owner:s.hierarchyFocusOwner),"pending search retains the existing focus busy barrier")
                } else {
                    check(!s.setHierarchyOutlineVisible(true,owner:s.hierarchyFocusOwner),"pending search retains the existing outline busy barrier")
                }
                s.cancelHandwritingSearch()
                if kind == "focus" {
                    check(s.focusHierarchy(a,owner:s.hierarchyFocusOwner),"explicit search cancellation releases branch focus without editing ink")
                    check(s.leaveHierarchyFocus(owner:s.hierarchyFocusOwner),"focus ABA returns to the same full view and geometry")
                } else {
                    check(s.setHierarchyOutlineVisible(true,owner:s.hierarchyFocusOwner),"explicit search cancellation releases outline without copying ink")
                    check(s.setHierarchyOutlineVisible(false,owner:s.hierarchyFocusOwner),"outline ABA returns to the same full view and geometry")
                }
                gate.finish([[first.id]]);await task.value
                check(s.viewport==viewport && s.inkSelection.isEmpty && s.mode == .select,"obsolete \(kind) callback cannot move or select hidden ink after ABA")
            }
            check(s.focusHierarchy(a,owner:s.hierarchyFocusOwner),"focus refusal fixture uses an actual current view")
            var invoked = false
            await s.searchHandwriting("한글") { _,_ in invoked=true;return [[first.id]] }
            check(!invoked && s.inkSelection.isEmpty,"focused hidden ink does not enter native search")
            check(s.leaveHierarchyFocus(owner:s.hierarchyFocusOwner),"full view can return after refused search")
            check(s.setHierarchyOutlineVisible(true,owner:s.hierarchyFocusOwner),"outline refusal fixture uses an actual current view")
            await s.searchHandwriting("한글") { _,_ in invoked=true;return [[first.id]] }
            check(!invoked && s.inkSelection.isEmpty,"outline hidden ink does not enter native search")
            check(s.setHierarchyOutlineVisible(false,owner:s.hierarchyFocusOwner),"map view can return after refused search")
            let currentIntent = s.captureHandwritingSearchOwner()!
            await s.searchHandwriting("한글",owner:currentIntent) { _,_ in [[first.id]] }
            check(s.viewport != CanvasViewport() && s.inkSelection==Set([first.id]),"current full map still reveals native search result")
            check(try s.document.bytes()==original,"view guards and successful navigation preserve canonical source")
            try JSONSerialization.data(withJSONObject:["count":checks.count,"checks":checks,"viewOnly":true,"GUI":false],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
            return
        }
        check(s.rotateNode(s.scene.nodes.first{$0.id==a}!,sceneID:s.scene.id,to:30),"보존 대조용 기존 graph Undo 생성")
        s.saveNow()
        let counter = UndoCounter(), manager = s.inkHistory.activate(s.nativeHistoryOwner)
        manager.beginUndoGrouping();manager.registerUndo(withTarget:counter) { $0.calls += 1 };manager.endUndoGrouping()
        let before = try s.document.bytes(), sceneBefore = try CanvasFileWorkspace.bytes(s.scene)
        let cacheURL = try CanvasRuntime.stateURL(.scene), cacheBefore = try CanvasLocalFile.read(cacheURL)
        let generation = s.inkHistory.generation
        await s.searchHandwriting("  한글 e\u{301}\n") { drawing,query in
            check(drawing == ink && query.utf8.elementsEqual("한글 e\u{301}".utf8),"한글·결합문자 검색어를 바꾸지 않고 기존 native 검색에 전달")
            return [[UUID()],[],[first.id,UUID()],[second.id]]
        }
        let target = PKDrawing(strokes:ink.strokes.filter{$0.id==first.id}).bounds
        let projected = target.offsetBy(dx:s.pan.width,dy:s.pan.height)
        check(CGRect(origin:.zero,size:size).contains(projected) && s.zoom == 1,"첫 유효 native 결과만 viewport 이동 대상으로 사용")
        check(s.mode == .lasso && s.inkSelection == Set([first.id,second.id]) && s.status.contains("2곳"),"기존 유효 결과 개수와 전체 일치 획 선택을 보존")
        check(try s.document.bytes() == before && CanvasFileWorkspace.bytes(s.scene) == sceneBefore,"검색 이동이 문서·글리프·노드·링크·주석·revision을 바꾸지 않음")
        check(try CanvasLocalFile.read(cacheURL) == cacheBefore && s.drawing == ink,"원본 복구 파일과 native 잉크·필압 바이트 유지")
        check(s.inkHistory.generation == generation && manager.canUndo && counter.calls == 0,"검색 이동이 기존 native Undo 소유·action을 소비하지 않음")
        s.inkHistory.undo();check(counter.calls == 1,"검색 후에도 같은 native Undo action 실행 가능")
        s.mode = .select;check(s.canUndoGraph,"검색 뒤 원래 graph Undo 이력 유지")
        s.undoGraphEdit();check(s.scene.nodes.first{$0.id==a}?.rotationDegrees != 30 && s.scene.links == scene.links,"기존 graph Undo는 원래 편집만 되돌림")
        s.redoGraphEdit();check(s.scene.nodes.first{$0.id==a}?.rotationDegrees == 30,"기존 graph Redo도 유지")
        let stable = try makeStore();stable.setInkSelection([second.id]);stable.viewport = moved
        let priorSelection = stable.inkSelection, priorViewport = stable.viewport, priorBytes = try stable.document.bytes()
        await stable.searchHandwriting("없음") {_,_ in []}
        check(stable.viewport == priorViewport && stable.inkSelection == priorSelection && !stable.status.contains("표시했습니다"),"일치 없음은 보기·선택 유지와 미성공 안내")
        var calls = 0
        await stable.searchHandwriting(" \n ") {_,_ in calls += 1;return [[first.id]]}
        check(calls == 0 && stable.viewport == priorViewport && stable.inkSelection == priorSelection,"빈 검색은 recognizer 호출과 이동 없음")
        await stable.searchHandwriting("오류") {_,_ in throw CocoaError(.fileReadUnknown)}
        check(stable.viewport == priorViewport && stable.inkSelection == priorSelection && stable.status.contains("마치지 못했습니다"),"검색 오류는 보기·원본·선택을 유지")
        check(try stable.document.bytes() == priorBytes,"빈/무결과/오류 뒤 문서 바이트 유지")
        let hidden = try makeStore();hidden.setHandwritingSearchSurface(nil)
        await hidden.searchHandwriting("숨김") {_,_ in calls += 1;return [[first.id]]}
        check(calls == 0 && hidden.viewport == origin && !hidden.status.contains("표시했습니다"),"보이지 않거나 측정되지 않은 화면은 검색 이동 성공 없음")
        hidden.setHandwritingSearchSurface(CGSize(width:CGFloat.nan,height:420))
        await hidden.searchHandwriting("크기 오류") {_,_ in calls += 1;return [[first.id]]}
        check(calls == 0,"NaN 화면 크기도 숨김으로 취급")
        var outside = scene
        let offInk = PKDrawing(strokes:[stroke(3100,1900)])
        outside.drawingBase64 = offInk.dataRepresentation().base64EncodedString();outside.strokes = CanvasScene.nativeInkStrokes(offInk)
        outside.nodes[0].sourceStrokeIds = []
        let off = try makeStore(outside), offBytes = try CanvasFileWorkspace.bytes(outside)
        await off.searchHandwriting("페이지 밖") {_,_ in [Set(offInk.strokes.map(\.id))]}
        check(off.viewport == origin && off.inkSelection.isEmpty && off.status.contains("확인하지 못했습니다"),"페이지 영역 밖 결과를 표시 성공으로 보고하지 않음")
        check(try CanvasFileWorkspace.bytes(off.scene) == offBytes,"페이지 밖 결과 거부 뒤 원본 유지")
        for action in ["source","sourceABA","viewABA","surfaceABA","resize","cancel","taskCancel","newEmptyQuery"] {
            let current = try makeStore(), gate = SearchGate()
            let task = Task { await current.searchHandwriting("old",search:gate.search) }
            await gate.wait()
            switch action {
            case "source":current.scene.nodes[0].text = "새 원문";current.saveNow()
            case "sourceABA":let original = current.scene;var interim = original;interim.nodes[0].text = "다른 원문";current.scene = interim;current.scene = original;current.saveNow()
            case "viewABA":current.viewport = moved;current.viewport = origin
            case "surfaceABA":current.setHandwritingSearchSurface(nil);current.setHandwritingSearchSurface(size)
            case "resize":current.setHandwritingSearchSurface(CGSize(width:320,height:420))
            case "cancel":current.cancelHandwritingSearch()
            case "taskCancel":task.cancel()
            default:await current.searchHandwriting(" ") {_,_ in []}
            }
            let bytes = try current.document.bytes(), view = current.viewport, selection = current.inkSelection, status = current.status
            gate.finish([[first.id]]);await task.value
            check(try current.document.bytes() == bytes && current.viewport == view && current.inkSelection == selection && current.status == status,"\(action) 뒤 늦은 양성 결과가 새 원본·보기·상태를 덮지 않음")
        }
        let oldSearch = try makeStore(), oldGate = SearchGate()
        let oldTask = Task { await oldSearch.searchHandwriting("old",search:oldGate.search) };await oldGate.wait()
        await oldSearch.searchHandwriting("new") {_,_ in [[second.id]]}
        let newest = oldSearch.viewport, newestSelection = oldSearch.inkSelection, newestStatus = oldSearch.status
        oldGate.fail();await oldTask.value
        check(oldSearch.viewport == newest && oldSearch.inkSelection == newestSelection && oldSearch.status == newestStatus,"이전 검색의 늦은 오류가 새 검색 성공을 덮지 않음")
        let recognition = try makeStore(), recognitionGate = SearchGate()
        let recognitionTask = Task { await recognition.proposeHandwriting { drawing in
            _ = try? await recognitionGate.search(drawing,"인식")
            return "기존 글자 인식 후보"
        } }
        await recognitionGate.wait()
        recognition.viewport = moved;recognition.setHandwritingSearchSurface(nil)
        recognitionGate.finish([]);await recognitionTask.value
        check(recognition.proposedNode != nil && recognition.proposalText == "기존 글자 인식 후보","검색 보기 무효화가 기존 글자 인식 요청을 취소하지 않음")
        try await checkHandwritingSearch(check)
        // Actual document/Files source: view-only navigation must not publish a generation or change the cache.
        let doc = try makeStore();try doc.createDocument()
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=")!
        doc.filePreview = {_ in png}
        let folder = out.appendingPathComponent("private-files",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        await doc.connectDocumentWorkspace(folder)
        check(doc.documentFileReady,"실제 전체 Document Files 원본 연결")
        let files = CanvasDocumentFiles(folder:folder,requiresScope:false), saved = try files.load(doc.document.id)
        let docCache = try CanvasRuntime.stateURL(.documentSource), rawDocCache = try CanvasLocalFile.read(docCache)
        await doc.searchHandwriting("문서 검색") {_,_ in [[first.id]]}
        let reloaded = try files.load(doc.document.id)
        check(try saved.document.bytes() == doc.document.bytes() && reloaded.document.bytes() == saved.document.bytes() && reloaded.token == saved.token,"문서 검색 이동은 전체 원본/Files 세대·토큰을 바꾸지 않음")
        check(try CanvasLocalFile.read(docCache) == rawDocCache,"문서 검색 이동의 보기 좌표를 원본 캐시에 저장하지 않음")
        let resumed = CanvasStore();check(resumed.viewport == origin,"기존 계약대로 새 Store viewport는 임시 기본값")
        await doc.duplicateDocumentPage();let pageB = doc.scene.id, pageA = saved.document.activePageID
        await doc.selectDocumentPage(pageA)
        let pageGate = SearchGate(), pageTask = Task { await doc.searchHandwriting("page-old",search:pageGate.search) };await pageGate.wait()
        await doc.selectDocumentPage(pageB)
        check(doc.scene.id == pageA,"진행 중 검색은 기존 문서 페이지 전환 장벽을 유지")
        doc.setHandwritingSearchSurface(nil)
        await doc.selectDocumentPage(pageB)
        check(doc.scene.id == pageB,"검색 화면 소유 반납 후 실제 페이지 B 전환")
        await doc.selectDocumentPage(pageA);doc.setHandwritingSearchSurface(size)
        check(doc.scene.id == pageA,"실제 A/B/A 복귀 확인")
        let pageBytes = try doc.document.bytes(), pageView = doc.viewport, pageStatus = doc.status
        pageGate.finish([[first.id]]);await pageTask.value
        check(try doc.document.bytes() == pageBytes && doc.viewport == pageView && doc.status == pageStatus,"페이지 A/B/A 뒤 이전 검색은 같은 pageID여도 이동하지 않음")
        try JSONSerialization.data(withJSONObject:["count":checks.count,"checks":checks,"actualStore":true,"actualPKDrawing":true,"injectedSearchResults":true,"previewFixture":true,"viewportPersisted":false,"GUI":false,"HTTP":false,"device":false,"wholeProductAccepted":false],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
    }
}
