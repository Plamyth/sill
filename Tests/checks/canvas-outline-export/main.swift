import Foundation
import PDFKit
import PencilKit

@main struct OutlineExportChecks {
    static func check(_ condition: Bool, _ label: String) {
        precondition(condition,label); print("PASS",label)
    }
    static func pdfRows(_ snapshot: CanvasStore.HierarchyOutlineSnapshot) -> [CanvasOutlinePDF.Row] {
        snapshot.entries.map { .init(id:$0.id,depth:$0.depth,text:$0.text,reference:$0.reference,isGroup:$0.isGroup) }
    }
    static func compact(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }
    static func snapshotBytes(_ snapshot: CanvasStore.HierarchyOutlineSnapshot) throws -> Data {
        try JSONSerialization.data(withJSONObject:snapshot.entries.map {
            ["id":$0.id.uuidString,"depth":$0.depth,"text":$0.text,"reference":$0.reference ?? "","group":$0.isGroup] as [String:Any]
        },options:[.sortedKeys])
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated only") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==")!
        func store() -> CanvasStore { let s = CanvasStore(); s.enableDocumentChecks(); s.filePreview = { _ in png }; return s }
        if CommandLine.arguments.contains("--reopen") {
            let s = store(), snapshot = try s.hierarchyOutlineSnapshot()
            let expected = try Data(contentsOf:out.appendingPathComponent("source-before-reopen.json"))
            check(try s.document.bytes() == expected,"새 프로세스에서 원본 전체 재열기")
            check(try snapshotBytes(snapshot) == Data(contentsOf:out.appendingPathComponent("snapshot-before-reopen.json")),"재열기한 canonical document의 같은 ID·순서·깊이·본문·참조")
            let file = try await RenderedSceneFile(outlineRows:pdfRows(snapshot),filename:"reopened")
            let pdf = PDFDocument(data:file.data)!
            check(try compact(pdf.string ?? "") == String(contentsOf:out.appendingPathComponent("pdf-text-before-reopen.txt"),encoding:.utf8),"재열기한 실제 Store 개요 PDF의 동일 텍스트와 순서")
            if s.isDocumentSource { check(s.documentFileReady,"새 Store의 기존 DocumentFiles binding 복원") }
            return
        }
        func reopen(_ s: CanvasStore) async throws {
            let snapshot = try s.hierarchyOutlineSnapshot()
            try s.document.bytes().write(to:out.appendingPathComponent("source-before-reopen.json"))
            try snapshotBytes(snapshot).write(to:out.appendingPathComponent("snapshot-before-reopen.json"))
            let pdf = PDFDocument(data:try await CanvasOutlinePDF.render(pdfRows(snapshot)))!
            try compact(pdf.string ?? "").write(to:out.appendingPathComponent("pdf-text-before-reopen.txt"),atomically:true,encoding:.utf8)
            let process = Process(); process.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
            process.arguments = [out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--reopen"]
            try process.run(); process.waitUntilExit(); check(process.terminationStatus == 0,"저장 후 새 프로세스 재열기 완료")
        }
        var scene = CanvasScene()
        let points = [0.0,10,20].enumerated().map { index,value in
            PKStrokePoint(location:CGPoint(x:10+value,y:20+value),timeOffset:Double(index)/10,
                size:CGSize(width:3,height:5),opacity:0.8,force:0.7,azimuth:0.3,altitude:1)
        }
        let drawing = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),
            path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))])
        scene.schemaVersion = 3; scene.drawingBase64 = drawing.dataRepresentation().base64EncodedString()
        scene.strokes = CanvasScene.nativeInkStrokes(drawing)
        let a = scene.addNode(kind:.note,at:.init(x:10,y:10),text:"부모 한국어")
        let b = scene.addNode(kind:.note,at:.init(x:20,y:20),text:"")
        let c = scene.addNode(kind:.note,at:.init(x:30,y:30),text:"자손 문단")
        let hidden = scene.addNode(kind:.note,at:.init(x:200,y:20),text:"숨은카드고유문구")
        let m1 = scene.addNode(kind:.note,at:.init(x:300,y:20),text:"그룹 첫째")
        let m2 = scene.addNode(kind:.note,at:.init(x:400,y:20),text:"그룹 둘째")
        _ = scene.connectAsChild(parent:a,child:b); _ = scene.connectAsChild(parent:b,child:c)
        scene.annotations = [.init(id:UUID(),nodeId:b,text:try CanvasCardTags.markdown("읽기"),author:CanvasCardTags.author)]
        scene.nodes[scene.nodes.firstIndex { $0.id == b }!].vaultNote = .init(path:"원문/한국어.md",sha256:String(repeating:"a",count:64),relayAddress:context.relayAddress,sourceState:.current)
        let grouped = try CanvasGroup.Draft(scene:scene,memberIDs:[m2,m1]).applying(to:scene)
        scene = grouped.scene
        let group = grouped.groupID
        var invalid = scene; invalid.links.append(.init(id:UUID(),from:c,to:a,label:"",kind:.parentChild))
        try CanvasLocalFile.write(CanvasFileWorkspace.bytes(invalid),to:CanvasRuntime.stateURL(.scene))
        let invalidStore = store()
        var invalidRejected = false
        do { _ = try invalidStore.hierarchyOutlineSnapshot() } catch { invalidRejected = true }
        check(invalidRejected,"잘못된 canonical 계층 스냅샷 거부")
        try CanvasLocalFile.write(CanvasFileWorkspace.bytes(scene),to:CanvasRuntime.stateURL(.scene))
        let s = store(); s.mode = .select
        let baseline = try s.document.bytes(), cache = try CanvasLocalFile.read(CanvasRuntime.stateURL(.scene))
        let canUndo = s.canUndoGraph, canRedo = s.canRedoGraph, dirty = s.vaultDirty
        let snapshot = try s.hierarchyOutlineSnapshot()
        check(snapshot.entries.map(\.id) == s.hierarchyOutlineRows.map(\.id) && snapshot.entries.map(\.depth) == s.hierarchyOutlineRows.map(\.depth),"개요 UI의 현재 순서와 깊이를 그대로 투영")
        let gi = snapshot.entries.firstIndex { $0.id == group }!
        check(snapshot.entries[gi+1].id == m2 && snapshot.entries[gi+2].id == m1,"그룹 명시 순서 보존")
        check(snapshot.entries.first { $0.id == b }?.reference == "원문/한국어.md","원문 참조는 읽기 전용 문자열 사본")
        let smallFile = try await RenderedSceneFile(outlineRows:pdfRows(snapshot),filename:"current-outline")
        let smallPDF = PDFDocument(data:smallFile.data)!
        check(smallPDF.pageCount == 1 && smallFile.format == .pdf,"실제 제품 FileDocument의 한 페이지 개요 PDF")
        let smallText = compact(smallPDF.string ?? "")
        check(smallText.contains("이름없는요소") && smallText.contains("원문/한국어.md") && smallText.contains("부모한국어"),"한국어와 빈 카드와 참조를 추출 가능")
        let page = smallPDF.page(at:0)!
        let parentX = smallPDF.findString("부모",withOptions:[]).first!.bounds(for:page).minX
        let childX = smallPDF.findString("이름",withOptions:[]).first!.bounds(for:page).minX
        check(childX > parentX,"PDF 텍스트 좌표에 실제 계층 들여쓰기")
        check(try s.document.bytes() == baseline && CanvasLocalFile.read(CanvasRuntime.stateURL(.scene)) == cache && s.canUndoGraph == canUndo && s.canRedoGraph == canRedo && s.vaultDirty == dirty,"내보내기는 canonical 전체 원본·저장 바이트·dirty·Undo/Redo 불변")
        check(s.acceptsHierarchyOutlineSnapshot(snapshot),"같은 source와 owner의 스냅샷 수용")
        check(s.setHierarchyOutlineVisible(true,owner:s.hierarchyFocusOwner),"기존 개요 UI 진입")
        let viewSnapshot = try s.hierarchyOutlineSnapshot()
        check(!s.acceptsHierarchyOutlineSnapshot(snapshot),"source SHA가 같아도 표시 owner 교체 거부")
        s.setCardTagFilter("#읽기")
        let filtered = try s.hierarchyOutlineSnapshot()
        check(Set(filtered.entries.map(\.id)) == s.cardTagVisibility.nodeIDs && filtered.entries.contains { $0.id == b } && !filtered.entries.contains { $0.id == a || $0.id == hidden },"기존 태그 규칙의 그룹 표시를 유지하고 숨은 부모와 형제 누출 없음")
        let filteredPDF = PDFDocument(data:try await CanvasOutlinePDF.render(pdfRows(filtered)))!
        check(!compact(filteredPDF.string ?? "").contains("숨은카드고유문구") && !compact(filteredPDF.string ?? "").contains("부모한국어"),"필터 PDF에서도 숨은 텍스트 누출 없음")
        s.setCardTagFilter(nil)
        check(!s.acceptsHierarchyOutlineSnapshot(viewSnapshot) && !s.acceptsHierarchyOutlineSnapshot(filtered),"태그 필터 왕복 ABA 거부")
        s.selectedNode = b
        check(s.focusHierarchy(b,owner:s.hierarchyFocusOwner),"초점 범위 진입")
        let focus = try s.hierarchyOutlineSnapshot()
        check(focus.entries.map(\.id) == [b,c] && focus.entries.map(\.depth) == [0,1],"초점 개요의 현재 순서와 상대 깊이")
        _ = s.leaveHierarchyFocus(owner:s.hierarchyFocusOwner)
        let groupNode = s.scene.nodes.first { $0.id == group }!
        check(s.toggleGroup(groupNode,owner:s.groupCommandOwner) && s.enterGroup(s.scene.nodes.first { $0.id == group }!,owner:s.groupCommandOwner),"열린 그룹 범위 진입")
        check(try s.hierarchyOutlineSnapshot().entries.map(\.id) == [m2,m1],"열린 그룹의 멤버 외 누출 없음")
        s.leaveGroup(owner:s.groupCommandOwner)
        s.undoGraphEdit()
        check(!s.acceptsHierarchyOutlineSnapshot(focus),"초점/그룹 변경 뒤 이전 owner 거부")
        s.saveNow()
        try await reopen(s)
        let ownerBeforeDocument = try s.hierarchyOutlineSnapshot()
        try s.createDocument()
        check(!s.acceptsHierarchyOutlineSnapshot(ownerBeforeDocument),"legacy에서 문서 전환 거부")
        let folder = out.appendingPathComponent("selected-files")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        await s.connectDocumentWorkspace(folder)
        if !s.documentFileReady { print("FILES_FAILURE",s.status,s.fileWorkspaceStatus) }
        check(s.documentFileReady,"현재 개요 canonical document를 기존 DocumentFiles에 실제 저장")
        let files = CanvasDocumentFiles(folder:folder,requiresScope:false)
        let saved = try files.load(s.document.id), beforeExternal = try s.hierarchyOutlineSnapshot()
        check(try saved.document.bytes() == s.document.bytes(),"저장한 canonical document 전체 바이트 readback")
        try await reopen(s)
        var external = saved.document, externalPage = external.activePage
        externalPage.nodes[externalPage.nodes.firstIndex { $0.id == a }!].text = "외부 CAS 갱신 한국어 본문"
        externalPage.revision += 1
        try external.replacePage(externalPage,expectedRevision:external.revision)
        _ = try files.save(external,previews:Dictionary(uniqueKeysWithValues:external.pages.map { ($0.id,png) }),expected:saved.token)
        s.refreshDocumentWorkspace()
        check(try s.document.bytes() == external.bytes() && s.document.revision > saved.document.revision,"정상 token CAS의 외부 본문/revision을 기존 수신 경로로 반영")
        check(s.scene.drawingBase64 == scene.drawingBase64 && s.scene.strokes == scene.strokes && s.scene.links == scene.links && s.scene.annotations == scene.annotations,"외부 본문 변경과 개요 내보내기 뒤 native 잉크·관계·태그 원본 보존")
        let received = try s.hierarchyOutlineSnapshot()
        check(received.entries.map(\.id) == beforeExternal.entries.map(\.id) && received.entries.first { $0.id == a }?.text == "외부 CAS 갱신 한국어 본문","수신 후 개요의 안정 ID·순서와 변경 본문 결속")
        check(!s.acceptsHierarchyOutlineSnapshot(beforeExternal) && beforeExternal.entries.first { $0.id == a }?.text == "부모 한국어","외부 갱신 뒤 이전 immutable snapshot을 변경하거나 수용하지 않음")
        let receivedBytes = try s.document.bytes()
        let receivedPDF = PDFDocument(data:try await CanvasOutlinePDF.render(pdfRows(received)))!
        check(compact(receivedPDF.string ?? "").contains("외부CAS갱신한국어본문") && !compact(receivedPDF.string ?? "").contains("부모한국어"),"외부 canonical 갱신이 현재 개요 PDF 텍스트에 반영")
        check(try s.document.bytes() == receivedBytes && files.load(s.document.id).document.bytes() == receivedBytes,"외부 갱신 후 PDF도 원본과 Files 세대를 변경하지 않음")
        try await reopen(s)
        let beforePage = try s.hierarchyOutlineSnapshot(), pageA = s.scene.id
        await s.duplicateDocumentPage(); await s.selectDocumentPage(pageA)
        check(!s.acceptsHierarchyOutlineSnapshot(beforePage),"페이지 왕복 ABA 거부")
        let beforeSelection = try s.hierarchyOutlineSnapshot(); s.selectedNode = hidden
        check(!s.acceptsHierarchyOutlineSnapshot(beforeSelection),"선택 owner 변경 거부")
        s.vaultInputBusy = true
        var refused = false
        do { _ = try s.hierarchyOutlineSnapshot() } catch { refused = true }
        check(refused,"활성 원문 입력 중 스냅샷 거부"); s.vaultInputBusy = false

        let count = 1500
        let longText = (0..<count).map { "문장\($0) 한국어 긴 문단 " + String(repeating:"경계테스트",count:8) }.joined(separator:" ") + "\n마지막문단끝"
        let longRows: [CanvasOutlinePDF.Row] = [
            .init(id:UUID(),depth:0,text:"첫행",reference:nil,isGroup:false),
            .init(id:UUID(),depth:1,text:longText,reference:nil,isGroup:false),
            .init(id:UUID(),depth:0,text:"마지막행",reference:nil,isGroup:false)
        ]
        let data = try await CanvasOutlinePDF.render(longRows)
        let url = out.appendingPathComponent("current-outline-long.pdf"); try data.write(to:url,options:.atomic)
        let reopened = PDFDocument(url:url)!
        check(try reopened.pageCount > 2 && Data(contentsOf:url) == data,"긴 개요의 여러 페이지 저장과 PDF 재열기")
        let extracted = compact(reopened.string ?? "")
        check(extracted.contains(compact(longText)) && extracted.contains("마지막행"),"긴 문단과 모든 페이지 경계에서 순서/텍스트 누락 없음")
        for i in 0..<reopened.pageCount {
            let page = reopened.page(at:i)!, bounds = page.bounds(for:.mediaBox).insetBy(dx:35,dy:35)
            var allInside = true
            for j in 0..<page.numberOfCharacters {
                let rect = page.characterBounds(at:j)
                if !rect.isEmpty && !bounds.contains(rect) { allInside = false }
            }
            check(allInside,"페이지 \(i) 모든 글자 잘림 없음")
        }
        for rows in [[],[longRows[1]], [.init(id:UUID(),depth:-1,text:"bad",reference:nil,isGroup:false)],
                     [longRows[0],longRows[0]], [longRows[0],.init(id:UUID(),depth:3,text:"bad",reference:nil,isGroup:false)]] as [[CanvasOutlinePDF.Row]] {
            var rejected = false
            do { _ = try await CanvasOutlinePDF.render(rows) } catch { rejected = true }
            check(rejected,"빈 개요/잘못된 깊이/중복 ID를 빈 PDF 성공으로 처리하지 않음")
        }
        let cancelled = Task { try await CanvasOutlinePDF.render(longRows) }; cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("취소가 파일을 반환함") } catch is CancellationError { print("PASS 취소는 PDF를 반환하지 않음") }
        let next = try await CanvasOutlinePDF.render([longRows[0]])
        check(PDFDocument(data:next)?.pageCount == 1,"취소 후 새 내보내기 helper 정상 실행")
        print("PASS current outline text PDF; UI/device/Pencil/image attachment/deeplink unverified")
    }
}
