import Foundation
import PencilKit
import PDFKit
import AppKit

@main struct PageActionChecks {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) {
        precondition(value,label); checks += 1; print("PASS \(label)")
    }
    static func refuses(_ label: String, _ action: () throws -> Void) {
        do { try action(); fatalError("accepted: \(label)") } catch { check(true,label) }
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated required") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        if CommandLine.arguments.contains("--paper-reopen") {
            let store = CanvasStore(); store.enableDocumentChecks()
            let expected = try CanvasDocument.decode(Data(contentsOf:out.appendingPathComponent("expected-paper.json")))
            check(store.document == expected && store.documentFileReady,"용지 설정·전체 Files 원본 새 프로세스 복원")
            check(try CanvasPagePaper.pattern(in:store.scene) == .grid,"새 프로세스의 원본 격자 설정")
            return
        }
        if CommandLine.arguments.contains("--reopen-pages") {
            let store = CanvasStore(); store.enableDocumentChecks()
            let expected = try CanvasDocument.decode(Data(contentsOf:out.appendingPathComponent("expected.json")))
            check(store.isDocumentSource && store.document == expected && store.documentFileReady,"새 프로세스의 전체 페이지·순서·Files 원본 복원")
            return
        }
        let originalInk = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:[
            PKStrokePoint(location:.init(x:10,y:20),timeOffset:0,size:.init(width:2,height:2),opacity:1,force:0.7,azimuth:0,altitude:1),
            PKStrokePoint(location:.init(x:50,y:40),timeOffset:0.1,size:.init(width:2,height:2),opacity:1,force:0.9,azimuth:0,altitude:1)
        ],creationDate:Date(timeIntervalSince1970:0)))])
        var page = CanvasScene(); page.width = 1200; page.height = 900
        page.drawingBase64 = originalInk.dataRepresentation().base64EncodedString()
        page.strokes = CanvasScene.nativeInkStrokes(originalInk); page.schemaVersion = 2; page.penSettings = .default
        page.nodes = [.init(id:UUID(),kind:.note,frame:.init(x:10,y:20,width:200,height:90),text:"원문 e\u{301} 🖊️",confidence:.confirmed,sourceStrokeIds:originalInk.strokes.map(\.id))]
        let pageBytes = try CanvasFileWorkspace.bytes(page)
        if CommandLine.arguments.contains("--paper-only") {
            try await paperChecks(page:page,out:out,contextID:context.id)
            return
        }
        var model = try CanvasDocument(legacy:page)
        let snapshot = try model.pageSnapshot(), blankID = try model.addBlankPage(after:page.id,expectedRevision:model.revision)
        check(model.activePageID == blankID && model.pages.count == 2,"원본 다음에 빈 페이지 추가·선택")
        check(model.activePage.nodes.isEmpty && model.activePage.strokes.isEmpty && model.activePage.drawingBase64.isEmpty,"빈 페이지에 원본 필기·노드 복사 없음")
        check(model.activePage.width == 1200 && model.activePage.height == 900,"원본 용지 크기 유지")
        check(model.activePage.schemaVersion == page.schemaVersion && model.activePage.penSettings == page.penSettings,"펜 설정과 그 표현 버전을 함께 이어받음")
        check(try CanvasFileWorkspace.bytes(model.pages[0]) == pageBytes,"원본 페이지 전체 바이트 보존")
        check(!model.accepts(snapshot),"추가 전 비동기 입력 거부")
        let beforeOrder = Dictionary(uniqueKeysWithValues:try model.pages.map { ($0.id,try CanvasFileWorkspace.bytes($0)) })
        let selected = model.activePageID
        try model.reorderPages([blankID,page.id],expectedRevision:model.revision)
        check(model.pages.map(\.id) == [blankID,page.id] && model.activePageID == selected,"순서만 변경하고 현재 페이지 identity 유지")
        check(try model.pages.allSatisfy { try CanvasFileWorkspace.bytes($0) == beforeOrder[$0.id] },"순서 변경 뒤 모든 페이지의 필기·출처 바이트 동일")
        let unchanged = try model.bytes()
        try model.reorderPages(model.pages.map(\.id),expectedRevision:model.revision)
        check(try model.bytes() == unchanged,"같은 순서는 revision과 바이트를 쓰지 않음")
        for bad in [[blankID],[blankID,blankID],[blankID,UUID()]] {
            refuses("누락·중복·외래 페이지 순서 거부") { try model.reorderPages(bad,expectedRevision:model.revision) }
        }
        refuses("오래된 revision 추가 거부") { _ = try model.addBlankPage(after:page.id,expectedRevision:-1) }
        check(try model.bytes() == unchanged,"실패 뒤 문서 전체 불변")
        var full = model
        while full.pages.count < CanvasDocument.pageLimit {
            try full.addBlankPage(after:full.activePageID,expectedRevision:full.revision)
        }
        let fullBytes = try full.bytes()
        refuses("페이지 상한에서 추가 거부") { _ = try full.addBlankPage(after:full.activePageID,expectedRevision:full.revision) }
        check(try full.bytes() == fullBytes,"상한 거부 뒤 원본 문서 바이트 보존")

        let store = CanvasStore(); store.enableDocumentChecks()
        try store.importSourceBytes(CanvasFileWorkspace.bytes(page))
        try store.createDocument()
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=")!
        store.filePreview = { _ in png }
        let folder = out.appendingPathComponent("public-files",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        print("BIND BEFORE",store.canTransitionDocument,store.documentBusy,store.fileWorkspaceState,store.status)
        print("CANONICAL FOLDER",folder.path,folder.resolvingSymlinksInPath().path)
        await store.connectDocumentWorkspace(folder)
        print("BIND AFTER",store.documentFileReady,store.documentBusy,store.fileWorkspaceStatus,store.status)
        check(store.documentFileReady,"Store에서 공용 Files 원본 연결")
        await store.addBlankDocumentPage()
        check(store.document.pages.count == 2 && store.scene.id != page.id && store.documentFileReady,"Store 빈 페이지를 전체 Files 저장 후 설치")
        let added = store.scene.id
        await store.moveDocumentPage(added,by:-1)
        check(store.document.pages.map(\.id) == [added,page.id] && store.scene.id == added,"Store 순서 이동·현재 페이지 보존")
        let files = CanvasDocumentFiles(folder:folder,requiresScope:false)
        check(try files.load(store.document.id).document == store.document,"실제 Files 새 인스턴스의 전체 순서 일치")
        check(try CanvasFileWorkspace.bytes(store.document.pages[1]) == pageBytes,"Store 추가·이동 뒤 원본 raw 잉크·주석 불변")
        var expected = try store.document.bytes()
        await store.moveDocumentPage(added,by:-1)
        await store.moveDocumentPage(added,by:Int.max)
        check(try store.document.bytes() == expected && !store.documentBusy,"경계 이동·잘못된 offset은 무효이며 busy 해제")
        store.filePreview = { _ in nil }
        await store.addBlankDocumentPage()
        check(try store.document.bytes() == expected && files.load(store.document.id).document == store.document && !store.documentBusy,"미리보기 실패는 현재 페이지·전체 Files 원본을 바꾸지 않음")
        store.filePreview = { _ in png }
        let externalBase = try files.load(store.document.id)
        var external = externalBase.document
        try external.reorderPages([page.id,added],expectedRevision:external.revision)
        _ = try files.save(external,previews:Dictionary(uniqueKeysWithValues:external.pages.map { ($0.id,png) }),expected:externalBase.token)
        store.refreshDocumentWorkspace()
        check(store.document.pages.map(\.id) == [page.id,added] && store.scene.id == added && store.documentFileReady,"외부 원본 순서 수정을 Store가 역수신하고 현재 페이지 유지")
        check(try CanvasFileWorkspace.bytes(store.document.pages[0]) == pageBytes,"역수신도 기존 필기·원문 참조를 변경하지 않음")
        expected = try store.document.bytes()
        try expected.write(to:out.appendingPathComponent("expected.json"))
        let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments = [out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--reopen-pages"]
        try child.run(); child.waitUntilExit()
        check(child.terminationStatus == 0,"별도 프로세스 재열기 종료 확인")
        let pdf = PDFDocument()
        let image = NSImage(size:.init(width:200,height:200),flipped:false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        pdf.insert(PDFPage(image:image)!,at:0)
        let pdfBytes = pdf.dataRepresentation()!
        let pdfSnapshot = VaultPDFSnapshot(path:"PDF/페이지 결합 검증.pdf",sha256:CanvasPacket.sha(pdfBytes),dataBase64:pdfBytes.base64EncodedString())
        store.setNoteConnection(address:context.relayAddress,token:context.token)
        let opened = await store.openPDFView(pdfSnapshot.path,loadPDF:{ _ in pdfSnapshot },loadNote:{ _ in throw NSError(domain:"CanvasRelay",code:404) })
        check(opened,"전체 문서에 PDF 보기 상태 접합")
        let reader = store.pdfViewReader!
        try reader.setCrop(.init(x:0,y:0,width:0.8,height:1),physicalPageNumber:1)
        await store.addBlankDocumentPage()
        await store.moveDocumentPage(added,by:-1)
        check(try store.document.bytes() == expected && reader.hasViewEdits,"미저장 PDF 보기 초안이 페이지 추가·순서 변경을 막고 입력 보존")
        check(store.closePDFView() && store.hasPendingPDFView,"PDF 닫기도 보기 초안을 기존 복구 원장에 보존")
        await store.addBlankDocumentPage()
        check(try store.document.bytes() == expected,"보존 PDF 복구 의도가 있는 동안 페이지 변경 우회 없음")
        print("PAGE ACTION CHECKS \(checks)")
    }

    @MainActor static func paperChecks(page: CanvasScene, out: URL, contextID: UUID) async throws {
        var original = page
        let human = CanvasAnnotation(id:UUID(),nodeId:nil,text:CanvasPagePaper.gridMarkdown,author:"용지")
        original.annotations.append(human)
        let grid = try CanvasPagePaper.applying(.grid,to:original)
        check(try CanvasPagePaper.pattern(in:original) == .plain && CanvasPagePaper.pattern(in:grid) == .grid,"일반 사람 주석을 설정으로 오인하지 않고 격자 추가")
        check(grid.drawingBase64 == original.drawingBase64 && grid.strokes == original.strokes && grid.nodes == original.nodes && grid.links == original.links,"용지 변경의 native 필기·구조·원문 보존")
        check(grid.annotations.contains(human),"기존 주석 보존")
        check(CanvasPagePaper.isOnlyChange(from:original,to:grid),"용지만 달라진 history 식별")
        var unrelated = grid; unrelated.nodes[0].text += " 다른 편집"
        check(!CanvasPagePaper.isOnlyChange(from:original,to:unrelated),"용지와 다른 본문 변경은 펜 모드 Undo 예외를 받지 않음")
        check(try CanvasFileWorkspace.bytes(CanvasPagePaper.applying(.grid,to:grid)) == CanvasFileWorkspace.bytes(grid),"같은 용지 설정은 바이트·revision no-op")
        let plain = try CanvasPagePaper.applying(.plain,to:grid)
        check(plain.annotations == original.annotations && plain.drawingBase64 == original.drawingBase64,"무늬 해제는 예약된 설정만 제거")
        let record = grid.annotations.first(where:CanvasPagePaper.isMetadata)!
        for kind in ["duplicate","version","text","node"] {
            var invalid = grid
            let index = invalid.annotations.firstIndex { $0.id == record.id }!
            switch kind {
            case "duplicate": invalid.annotations.append(CanvasPagePaper.record())
            case "version": invalid.annotations[index].author = "ccr.sill.page-paper/v2"
            case "text": invalid.annotations[index].text += "\n추가 내용"
            default: invalid.annotations[index].nodeId = original.nodes[0].id
            }
            let before = try CanvasFileWorkspace.bytes(invalid)
            refuses("손상·미지원 용지 \(kind) 거부") { _ = try CanvasPagePaper.applying(.plain,to:invalid) }
            check(try CanvasFileWorkspace.bytes(invalid) == before,"거부된 설정과 모든 원문 유지")
        }
        let lines = CanvasPagePaper.gridLines(width:96,height:96)
        check(lines.count == 4 && lines[0].0.x == 32 && lines[0].1.y == 96,"격자는 고정 캔버스 포인트 좌표")
        check(CanvasPagePaper.gridLines(width:.infinity,height:100).isEmpty && CanvasPagePaper.gridLines(width:1e20,height:100).isEmpty,"비정상 크기에서 무한 격자·과대 배열 없음")
        var document = try CanvasDocument(legacy:grid)
        try document.addBlankPage(after:grid.id,expectedRevision:document.revision)
        check(try CanvasPagePaper.pattern(in:document.activePage) == .grid && document.activePage.annotations.count == 1,"새 빈 페이지는 용지만 상속하고 사용자 주석은 복사하지 않음")
        check(document.activePage.annotations[0].id != record.id,"새 페이지의 용지 주석 ID 분리")

        let store = CanvasStore(); store.enableDocumentChecks()
        try store.importSourceBytes(CanvasFileWorkspace.bytes(original)); try store.createDocument()
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=")!
        store.filePreview = { _ in png }
        let folder = out.appendingPathComponent("paper-files",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        await store.connectDocumentWorkspace(folder)
        check(store.documentFileReady,"용지 검사 공용 Files 연결")
        let ink = store.scene.drawingBase64
        store.applyPagePaper(.grid)
        check(try CanvasPagePaper.pattern(in:store.scene) == .grid && store.scene.drawingBase64 == ink,"Store 용지 편집과 원본 필기 유지")
        for inputMode in [CanvasMode.pen,.select,.lasso] {
            store.mode = inputMode
            let heldGrid = try store.document.bytes()
            store.documentPresentationBusy = true
            check(!store.canUndoGraph,"다른 입력 소유 중 용지 Undo 차단 \(inputMode.rawValue)")
            store.undoGraphEdit()
            check(try store.document.bytes() == heldGrid,"거부된 Undo는 원본·revision·history 유지 \(inputMode.rawValue)")
            store.documentPresentationBusy = false
            check(store.canUndoGraph,"입력 반납 후 용지 Undo 복구 \(inputMode.rawValue)")
            store.undoGraphEdit()
            check(try CanvasPagePaper.pattern(in:store.scene) == .plain && store.scene.drawingBase64 == ink,"같은 graph Undo로 용지 복원 \(inputMode.rawValue)")
            let heldPlain = try store.document.bytes()
            store.documentPresentationBusy = true
            check(!store.canRedoGraph,"다른 입력 소유 중 용지 Redo 차단 \(inputMode.rawValue)")
            store.redoGraphEdit()
            check(try store.document.bytes() == heldPlain,"거부된 Redo는 원본·revision·history 유지 \(inputMode.rawValue)")
            store.documentPresentationBusy = false
            check(store.canRedoGraph,"입력 반납 후 용지 Redo 복구 \(inputMode.rawValue)")
            store.redoGraphEdit()
            check(try CanvasPagePaper.pattern(in:store.scene) == .grid,"같은 graph Redo로 용지 재적용 \(inputMode.rawValue)")
        }
        store.mode = .pen
        await store.saveDocumentWorkspace()
        let files = CanvasDocumentFiles(folder:folder,requiresScope:false)
        check(try files.load(store.document.id).document == store.document,"전체 Files 원본에 용지와 필기 함께 저장")
        let beforeBusy = try store.document.bytes()
        store.documentPresentationBusy = true; store.applyPagePaper(.plain); store.documentPresentationBusy = false
        check(try store.document.bytes() == beforeBusy,"다른 입력 소유 중 용지 변경 거부")
        for pattern in [CanvasPagePaper.Pattern.plain,.grid] {
            let base = try files.load(store.document.id)
            var external = base.document
            let next = try CanvasPagePaper.applying(pattern,to:external.activePage)
            try external.replacePage(next,expectedRevision:external.revision)
            _ = try files.save(external,previews:base.previews,expected:base.token)
            store.refreshDocumentWorkspace()
            check(try CanvasPagePaper.pattern(in:store.scene) == pattern && store.scene.drawingBase64 == ink && store.documentFileReady,"외부 같은 원본의 용지 수정 역수신 \(pattern.rawValue)")
        }
        try store.document.bytes().write(to:out.appendingPathComponent("expected-paper.json"))
        let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments = [out.path,"--ccr-test-runtime",contextID.uuidString.lowercased(),"--paper-reopen"]
        try child.run(); child.waitUntilExit(); check(child.terminationStatus == 0,"용지 별도 프로세스 재열기 종료 확인")
        print("PAPER CHECKS \(checks)")
    }
}
