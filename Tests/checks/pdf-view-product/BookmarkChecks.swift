import Foundation
import PDFKit
import AppKit

@main struct PDFBookmarkChecks {
    static var assertions = [String]()
    static func check(_ yes: Bool, _ name: String) { precondition(yes,name); assertions.append(name); print("PASS",name) }
    static func refuses(_ name: String, _ action: () throws -> Void) {
        do { try action(); fatalError("accepted: " + name) } catch { check(true,name) }
    }

    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated only") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        let vault = try OwnVault(); defer { vault.close() }
        let path = "문서/책갈피.pdf"
        func store() -> CanvasStore {
            let s = CanvasStore(); s.enableDocumentChecks(); s.setNoteConnection(address:context.relayAddress,token:context.token); return s
        }
        if CommandLine.arguments.contains("--reopen") {
            let s = store(), expected = try JSONDecoder().decode(VaultPDFViewState.self,from:Data(contentsOf:out.appendingPathComponent("expected.json")))
            check(await s.openPDFView(path,loadPDF:vault.pdf,loadNote:vault.note),"새 프로세스 Store가 실제 PDF와 보기 파일을 재열기")
            check(s.pdfViewReader?.viewState == expected,"새 프로세스의 책갈피·순서·crop 동일")
            if CommandLine.arguments.contains("--pending") {
                check(s.hasPendingPDFView && s.pdfExcerptRecovery?.viewRecovery?.submitted != nil && !s.canTransitionDocument,"새 프로세스가 미확인 제출과 교체 barrier 보존")
            } else { check(!s.hasPendingPDFView,"새 프로세스의 확인된 저장에는 추가 복구 의도 없음") }
            return
        }
        func reopen(_ state: VaultPDFViewState, pending: Bool = false) throws {
            try JSONEncoder().encode(state).write(to:out.appendingPathComponent("expected.json"))
            let p = Process(); p.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
            p.arguments = [out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--reopen"] + (pending ? ["--pending"] : [])
            try p.run(); p.waitUntilExit(); check(p.terminationStatus == 0,"독립 프로세스 재열기 · \(pending ? "미확인" : "확인됨")")
        }
        let pdf = pagesPDF([("PAGE1 ANCHOR1",""),("PAGE2 ANCHOR2","/Rotate 90"),("PAGE3 ANCHOR3","/Rotate 270")])
        _ = try vault.call("writePDF",["path":path,"base64":pdf.base64EncodedString()])
        let snapshot = try await vault.pdf(path), native = try VaultPDFReader(snapshot:snapshot)
        native.view.frame = CGRect(x:0,y:0,width:640,height:900)
        check(native.go(toPageNumber:3),"실제 3쪽 PDFKit 원문 3쪽 이동")
        let page = native.view.document!.page(at:2)!
        native.view.setCurrentSelection(page.selection(for:(page.string! as NSString).range(of:"ANCHOR3")),animate:false)
        let source = try native.excerpt(), s = store()
        check(s.preparePDFExcerpt(source),"기존 물리 3쪽 발췌 준비")
        let id = await s.savePDFExcerpt(allowCreate:true,create:{try await vault.save($0,nil,$1)},load:vault.note)
        check(id != nil && s.closeVaultEditor(),"실제 Obsidian 발췌 파일·원본 카드 저장")
        let card = s.scene.nodes.first { $0.id == id }!, sourceNote = try await vault.note(source.notePath)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let sourceBytes = try encoder.encode(source)
        try s.createDocument()
        let files = out.appendingPathComponent("selected-files",isDirectory:true)
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==")!
        s.filePreview = { _ in png }; await s.connectDocumentWorkspace(files)
        print("FILES",s.status,s.fileWorkspaceStatus,s.documentFileReady,s.documentBusy,s.canTransitionDocument)
        check(s.documentFileReady,"기존 전체 문서 Files 세대 연결")
        let documentBytes = try s.document.bytes()

        // Execute the exact base codec (only its Swift type name differs), not a fabricated old-format note.
        var old = LegacyPDFViewState(snapshot:snapshot,pageCount:3)
        old.displayOrder = [2,3,1]; old.crops[1] = .init(x:0.1,y:0,width:0.9,height:1)
        let oldText = try old.markdown(), legacy = try LegacyPDFViewState.SaveRequest(state:old,base:nil)
        let oldRequest = try JSONDecoder().decode(VaultPDFViewState.SaveRequest.self,from:JSONEncoder().encode(legacy))
        let base = try await vault.save(old.notePath,nil,oldText)
        _ = try oldRequest.confirmed(base)
        check(oldRequest.state.bookmarks.isEmpty && oldRequest.markdown == oldText,"정확 cd5 생성기의 v1 Markdown·Codable 요청 읽기")
        let oldRecovery = try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"draft":JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)),"submitted":JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy))])
        try JSONDecoder().decode(VaultPDFViewRecovery.self,from:oldRecovery).validate()
        check(true,"bookmarks 키 없는 기존 Codable recovery 검증")
        check(await s.openPDFView(path,source:source,loadPDF:vault.pdf,loadNote:vault.note),"v1 파일로 기존 Store Reader 열기")
        var reader = s.pdfViewReader!
        check(reader.pageNumber == 3 && reader.displayPageNumber == 2,"기존 발췌는 표시 순서와 무관한 물리 3쪽")
        try reader.setBookmark(true,physicalPageNumber:3)
        check(reader.viewState.bookmarks == [3] && reader.view.currentSelection?.string == source.quote,"책갈피 추가가 회전된 쪽의 문자 선택 보존")
        let bookmarked = reader.viewState
        try reader.setBookmark(true,physicalPageNumber:3)
        check(reader.viewState == bookmarked,"중복 추가는 올바른 no-op")
        try reader.undoViewState(); check(reader.viewState.bookmarks.isEmpty,"책갈피 추가 Undo")
        try reader.redoViewState(); check(reader.viewState == bookmarked,"책갈피 추가 Redo")
        check(reader.go(toPageNumber:1) && reader.go(toPageNumber:3) && reader.pageNumber == 3,"목록의 물리 번호로 1쪽에서 동일 원문 3쪽 복귀")
        check(s.preservePDFViewDraft(reader) && s.hasPendingPDFView && !s.canTransitionDocument,"책갈피 초안은 기존 내구 복구 파일과 페이지 교체 barrier 사용")
        let request = try reader.prepareViewStateSave(base:s.pdfViewBase)
        check(request.markdown.hasPrefix(VaultPDFViewState.bookmarkMarker) && request.markdown.contains("책갈피: 3\n"),"동일 Markdown의 명시 v2 책갈피 표현")
        refuses("이전 v1 reader는 새 책갈피 문서를 거부") { _ = try LegacyPDFViewState.parse(request.markdown,snapshot:snapshot,pageCount:3) }
        for bad in [request.markdown.replacingOccurrences(of:"책갈피: 3",with:"책갈피: 3, 3"),request.markdown.replacingOccurrences(of:"책갈피: 3",with:"책갈피: 0"),request.markdown.replacingOccurrences(of:"책갈피: 3",with:"책갈피: 4"),request.markdown.replacingOccurrences(of:"책갈피: 3",with:"책갈피: "),request.markdown.replacingOccurrences(of:"책갈피: 3",with:"책갈피: 3\n책갈피: 1"),request.markdown.replacingOccurrences(of:"state:v2",with:"state:v3"),request.markdown + "알 수 없는 표현\n"] {
            refuses("미지원·중복·범위 밖 책갈피 Markdown 거부") { _ = try VaultPDFViewState.parse(bad,snapshot:snapshot,pageCount:3) }
        }
        refuses("다른 UTF8 원문 path 거부") { _ = try VaultPDFViewState.parse(request.markdown,snapshot:.init(path:"다른.pdf",sha256:snapshot.sha256,dataBase64:snapshot.dataBase64),pageCount:3) }
        let null = try JSONEncoder().encode(bookmarked)
        var object = try JSONSerialization.jsonObject(with:null) as! [String:Any]; object["bookmarks"] = NSNull()
        refuses("명시 null Codable 책갈피 거부") { _ = try JSONDecoder().decode(VaultPDFViewState.self,from:JSONSerialization.data(withJSONObject:object)) }
        await s.savePDFView(request,reader:reader,save:vault.save,load:vault.note)
        check(!s.hasPendingPDFView && !reader.hasViewEdits,"실제 Files CAS PUT와 전체 GET 확인")
        try reopen(bookmarked)
        var external = bookmarked; external.bookmarks = [1,2]
        _ = try vault.call("external",["path":external.notePath,"text":try external.markdown()])
        await s.reloadPDFView(reader:reader,load:vault.note)
        check(reader.viewState == external && reader.viewState.displayOrder == bookmarked.displayOrder && reader.viewState.crops == bookmarked.crops,"AI 외부 Markdown 책갈피 역수신과 순서·crop 보존")
        for number in external.bookmarks { check(reader.go(toPageNumber:number) && reader.pageNumber == number,"역수신 목록의 동일 물리 쪽 이동") }
        try reader.returnToSource(source)
        check(reader.pageNumber == 3 && reader.view.currentSelection?.string == source.quote,"책갈피 역수신 뒤 기존 발췌 앵커·문자 선택 복귀")
        let invalid = (try external.markdown()).replacingOccurrences(of:"책갈피: 1, 2",with:"책갈피: 2, 2")
        _ = try vault.call("external",["path":external.notePath,"text":invalid])
        await s.reloadPDFView(reader:reader,load:vault.note)
        let invalidReadback = try await vault.note(external.notePath)
        check(reader.viewState == external && invalidReadback.text == invalid,"손상된 외부 원본과 기존 Reader 모두 보존")
        _ = try vault.call("external",["path":external.notePath,"text":try external.markdown()])
        try reader.setBookmark(false,physicalPageNumber:1); try reader.setBookmark(false,physicalPageNumber:2)
        let emptyText = try reader.viewState.markdown()
        check(reader.viewState.bookmarks.isEmpty && emptyText.hasPrefix(VaultPDFViewState.marker),"명시 제거는 원본을 지우지 않고 지원되는 빈 책갈피 v1로 저장")
        check(s.preservePDFViewDraft(reader),"제거 초안 내구 보존")
        let removal = try reader.prepareViewStateSave(base:s.pdfViewBase)
        var puts = 0
        await s.savePDFView(removal,reader:reader,save:{p,b,t in puts += 1; _ = try await vault.save(p,b,t); throw URLError(.networkConnectionLost)},load:vault.note)
        check(puts == 1 && s.pdfExcerptRecovery?.saveConflict == .acknowledgementLost && s.pdfExcerptRecovery?.viewRecovery?.submitted == removal,"ACK 유실은 한 번 전송한 제거 의도 전체 보존")
        try reopen(removal.state,pending:true)
        let restored = store()
        check(await restored.openPDFView(path,source:source,loadPDF:vault.pdf,loadNote:vault.note),"freshStore가 미확인 책갈피 제거를 기존 복구 파일에서 복원")
        reader = restored.pdfViewReader!
        await restored.reloadPDFView(reader:reader,load:vault.note)
        check(!restored.hasPendingPDFView && !reader.hasViewEdits && puts == 1,"명시 전체 GET만으로 ACK 확인 · 재PUT 없음")
        try reader.setBookmark(true,physicalPageNumber:3)
        let first = try reader.prepareViewStateSave(base:restored.pdfViewBase)
        await restored.savePDFView(first,reader:reader,save:{p,b,t in
            let note = try await vault.save(p,b,t)
            try reader.setBookmark(true,physicalPageNumber:1)
            check(restored.preservePDFViewDraft(reader),"저장 중 새 책갈피 입력도 같은 원장에 보존")
            return note
        },load:vault.note)
        check(reader.viewState.bookmarks == [3,1] && reader.hasViewEdits && restored.pdfExcerptRecovery?.viewRecovery?.submitted == nil,"늦은 성공이 새 책갈피를 덮지 않음")
        let latest = try reader.prepareViewStateSave(base:restored.pdfViewBase)
        await restored.savePDFView(latest,reader:reader,save:vault.save,load:vault.note)
        check(!restored.hasPendingPDFView,"새 입력의 명시 저장 완료")
        try reader.setBookmark(true,physicalPageNumber:2)
        check(restored.preservePDFViewDraft(reader),"CAS 충돌 전 책갈피 초안 보존")
        let cas = try reader.prepareViewStateSave(base:restored.pdfViewBase)
        var remote = latest.state; remote.bookmarks = [2]
        _ = try vault.call("external",["path":remote.notePath,"text":try remote.markdown()])
        await restored.savePDFView(cas,reader:reader,save:vault.save,load:vault.note)
        let held = restored.pdfExcerptRecovery
        check(held?.saveConflict == .unclassified && !restored.pdfViewCanPersist,"실제 외부 CAS 충돌은 기존 409 barrier 유지")
        await restored.reloadPDFView(reader:reader,load:vault.note)
        check(restored.pdfExcerptRecovery == held && reader.viewState == cas.state,"일반 GET으로 충돌 의도나 입력을 해제하지 않음")
        await restored.comparePDFViewConflict(reader:reader,load:vault.compare,loadCurrent:vault.note)
        await restored.adoptPDFViewCurrent(reader:reader,load:vault.note)
        check(!restored.hasPendingPDFView && restored.pdfViewReader?.viewState == remote && restored.pdfViewLocalChoice?.original == held,"명시 현재 원문 채택이 원래 CAS 의도 전체 보존")
        try restored.archiveCompletedPDFViewChoiceForNoteEditor()
        reader = restored.pdfViewReader!
        let accepted = reader
        let aba = await restored.openPDFView(path,loadPDF:{p in
            restored.setNoteConnection(address:"http://192.168.88.88:4243",token:context.token)
            restored.setNoteConnection(address:context.relayAddress,token:context.token)
            return try await vault.pdf(p)
        },loadNote:vault.note)
        check(!aba && restored.pdfViewReader !== accepted,"동일 주소로 돌아와도 ABA의 늦은 Reader 설치 거부")
        check(await restored.openPDFView(path,source:source,loadPDF:vault.pdf,loadNote:vault.note),"ABA 뒤 명시 새 요청만 재열기")
        reader = restored.pdfViewReader!
        try reader.setBookmark(true,physicalPageNumber:3)
        let retired = try reader.prepareViewStateSave(base:restored.pdfViewBase)
        await restored.savePDFView(retired,reader:reader,save:{p,b,t in
            let note = try await vault.save(p,b,t)
            restored.setNoteConnection(address:"http://192.168.88.88:4243",token:context.token)
            restored.setNoteConnection(address:context.relayAddress,token:context.token)
            return note
        },load:vault.note)
        check(restored.hasPendingPDFView && restored.pdfExcerptRecovery?.viewRecovery?.submitted == retired,"ABA 뒤 늦은 저장 확인은 보존 의도를 해제하지 않음")
        let finalStore = store()
        check(await finalStore.openPDFView(path,source:source,loadPDF:vault.pdf,loadNote:vault.note),"retired callback 뒤 freshStore 명시 복원")
        await finalStore.reloadPDFView(reader:finalStore.pdfViewReader!,load:vault.note)
        check(!finalStore.hasPendingPDFView,"freshStore의 명시 GET이 동일 제출만 확인")
        try reopen(retired.state)
        let finalPDF = try await vault.pdf(path), finalNote = try await vault.note(source.notePath)
        check(finalPDF.sha256 == snapshot.sha256 && finalNote.sha256 == sourceNote.sha256,"실제 PDF·기존 발췌 Markdown SHA 불변")
        check(try encoder.encode(source) == sourceBytes && finalStore.scene.nodes.first { $0.id == id } == card && finalStore.document.bytes() == documentBytes,"물리 앵커·원본 카드·전체 Files 문서 불변")
        let rotated = pagesPDF([("PAGE1","/Rotate 180")]), rotatedSnapshot = VaultPDFSnapshot(path:"180.pdf",sha256:CanvasPacket.sha(rotated),dataBase64:rotated.base64EncodedString())
        let r180 = try VaultPDFReader(snapshot:rotatedSnapshot); try r180.setBookmark(true,physicalPageNumber:1)
        check(r180.go(toPageNumber:1) && r180.view.document?.page(at:0)?.rotation == 180,"180도에서도 책갈피 물리 쪽·원문 회전 보존")
        check(NSApplication.shared.windows.isEmpty,"Window·GUI 생성 없음")
        try JSONSerialization.data(withJSONObject:["assertions":assertions,"count":assertions.count,"operations":vault.operations,"PDFSHA":snapshot.sha256,"sourceMarkdownSHA":sourceNote.sha256,"quoteSHA":CanvasPacket.sha(Data(source.quote.utf8)),"documentSHA":CanvasPacket.sha(documentBytes)],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
    }
}
