import Foundation
import PencilKit

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
        page.strokes = CanvasScene.nativeInkStrokes(originalInk); page.schemaVersion = 2
        page.nodes = [.init(id:UUID(),kind:.note,frame:.init(x:10,y:20,width:200,height:90),text:"원문 e\u{301} 🖊️",confidence:.confirmed,sourceStrokeIds:originalInk.strokes.map(\.id))]
        let pageBytes = try CanvasFileWorkspace.bytes(page)
        var model = try CanvasDocument(legacy:page)
        let snapshot = try model.pageSnapshot(), blankID = try model.addBlankPage(after:page.id,expectedRevision:model.revision)
        check(model.activePageID == blankID && model.pages.count == 2,"원본 다음에 빈 페이지 추가·선택")
        check(model.activePage.nodes.isEmpty && model.activePage.strokes.isEmpty && model.activePage.drawingBase64.isEmpty,"빈 페이지에 원본 필기·노드 복사 없음")
        check(model.activePage.width == 1200 && model.activePage.height == 900,"원본 용지 크기 유지")
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
        print("PAGE ACTION CHECKS \(checks)")
    }
}
