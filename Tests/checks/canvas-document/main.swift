import Foundation
import PencilKit
import AppKit

@main struct DocumentChecks {
    static var count = 0
    static func check(_ value: Bool, _ name: String) {
        precondition(value, name); count += 1; print("PASS \(name)")
    }
    static func refuses(_ name: String, _ action: () throws -> Void) {
        do { try action(); fatalError("accepted: \(name)") }
        catch { check(true,name) }
    }
    static func refusesFile(_ expected: CanvasDocumentFiles.Failure, _ name: String, _ action: () throws -> Void) {
        do { try action(); fatalError("accepted: \(name)") }
        catch let actual as CanvasDocumentFiles.Failure { check(actual == expected,name) }
        catch { fatalError("wrong failure: \(name): \(error)") }
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        print("BEGIN actual PKDrawing and document Files")
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        let fm = FileManager.default
        let points = [10.0,20.0,30.0].enumerated().map { i,x in
            PKStrokePoint(location:CGPoint(x:x,y:x/2),timeOffset:Double(i)/10,
                          size:CGSize(width:3+i,height:4+i),opacity:0.7,force:0.6,azimuth:0.3,altitude:1)
        }
        let stroke = PKStroke(ink:PKInk(.pen,color:.black),
            path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)),
            transform:CGAffineTransform(rotationAngle:0.3).scaledBy(x:1.2,y:0.9))
        let drawing = try PKDrawing(data:PKDrawing(strokes:[stroke]).dataRepresentation())
        let rawInk = drawing.dataRepresentation()
        var page = CanvasScene(); page.schemaVersion = 3
        page.drawingBase64 = rawInk.base64EncodedString(); page.strokes = CanvasScene.nativeInkStrokes(drawing)
        let first = UUID(), second = UUID(), linkID = UUID(), annotationID = UUID()
        page.nodes = [
            .init(id:first,kind:.note,frame:.init(x:0,y:10,width:200,height:100),text:"원문 e\u{301} 🖊️\r\n^original",
                  confidence:.confirmed,sourceStrokeIds:[stroke.id],
                  vaultNote:.init(path:"Own/Reference.md",sha256:CanvasPacket.sha(Data("원본".utf8)),relayAddress:"http://127.0.0.1:4242",blockID:"original",sourceState:.current)),
            .init(id:second,kind:.ellipse,frame:.init(x:300,y:10,width:200,height:100),text:"타원",confidence:.confirmed,sourceStrokeIds:[],rotationDegrees:23)]
        page.links = [.init(id:linkID,from:first,to:second,label:"원래 연결",kind:.parentChild,fromAnchor:.init(side:.right,offset:0.3))]
        page.annotations = [.init(id:annotationID,nodeId:first,text:"#한국어태그 e\u{301}",author:"사용자")]
        let original = try CanvasFileWorkspace.bytes(page)
        var document = try CanvasDocument(legacy:page)
        let mapping = try document.duplicatePage(page.id,expectedRevision:document.revision)
        let duplicate = document.activePage
        check(document.pages.map(\.id) == [page.id,mapping.pageID],"복제 순서와 새 페이지 UUID")
        check(try CanvasFileWorkspace.bytes(document.pages[0]) == original,"원래 페이지 바이트 보존")
        check(duplicate.drawingBase64 == page.drawingBase64 && duplicate.strokes == page.strokes,"native 잉크와 strokeID 페이지 범위 보존")
        let reopenedInk = try PKDrawing(data:Data(base64Encoded:duplicate.drawingBase64)!)
        check(reopenedInk.strokes.first!.transform == drawing.strokes.first!.transform && reopenedInk.strokes.first!.path.first!.force == drawing.strokes.first!.path.first!.force,"실제 PKDrawing transform 필압 왕복")
        check(duplicate.nodes[0].id == mapping.nodeIDs[first] && duplicate.nodes[1].id == mapping.nodeIDs[second],"노드 ID 재매핑")
        check(duplicate.links[0].id == mapping.linkIDs[linkID] && duplicate.links[0].from == mapping.nodeIDs[first] && duplicate.links[0].to == mapping.nodeIDs[second],"링크 ID와 양끝 재매핑")
        check(duplicate.annotations[0].id == mapping.annotationIDs[annotationID] && duplicate.annotations[0].nodeId == mapping.nodeIDs[first],"주석 ID와 노드 참조 재매핑")
        check(duplicate.nodes[0].vaultNote == page.nodes[0].vaultNote && duplicate.nodes[0].sourceStrokeIds == page.nodes[0].sourceStrokeIds,"외부 노트와 원시 잉크 참조 보존")
        check(Array(duplicate.nodes[0].text.utf8) == Array(page.nodes[0].text.utf8) && duplicate.annotations[0].text == page.annotations[0].text && duplicate.nodes[1].rotationDegrees == 23,"UTF8 주석 회전 보존")
        for version in [1,2,3] {
            var legacy = page; legacy.schemaVersion = version
            if version < 3 { legacy.nodes[1].kind = .box }
            if version == 1 { legacy.strokes = legacy.strokes.map { var s = $0; s.style = nil; return s } }
            let decoded = try CanvasDocument.decode(CanvasFileWorkspace.bytes(legacy))
            check(decoded.pages.count == 1 && decoded.pages[0] == legacy,"구 scene \(version) 단일 페이지 읽기")
        }
        let bytes = try document.bytes()
        refuses("구 scene reader가 새 문서를 명시 거부") { _ = try JSONDecoder().decode(CanvasScene.self,from:bytes) }
        var object = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        object["version"] = 99
        refuses("새 버전 실패를 legacy로 fallback하지 않음") { _ = try CanvasDocument.decode(JSONSerialization.data(withJSONObject:object)) }
        object["version"] = 1; object["schemaVersion"] = 3
        refuses("scene 필드가 섞인 외곽 거부") { _ = try CanvasDocument.decode(JSONSerialization.data(withJSONObject:object)) }
        object.removeValue(forKey:"schemaVersion"); object["activePageID"] = UUID().uuidString
        refuses("없는 현재 페이지 전체 거부") { _ = try CanvasDocument.decode(JSONSerialization.data(withJSONObject:object)) }
        let a = document.activePageID, b = page.id, snapshot = try document.pageSnapshot()
        check(document.matchesPageActivation(snapshot),"현재 입력 activation은 전체 직렬화 없이 소유 확인")
        check(try !CanvasDocument.decode(document.bytes()).accepts(snapshot),"새로 연 인스턴스는 이전 비동기 snapshot 거부")
        check(try !CanvasDocument.decode(document.bytes()).matchesPageActivation(snapshot),"새 인스턴스의 입력 activation 거부")
        var changedHidden = document
        var hidden = changedHidden.pages.first { $0.id != changedHidden.activePageID }!
        hidden.nodes[0].text += " 숨은 페이지 수정"; hidden.revision += 1
        try changedHidden.replacePage(hidden,expectedRevision:changedHidden.revision)
        check(!changedHidden.matchesPageActivation(snapshot) && !changedHidden.accepts(snapshot),"비선택 페이지 변경도 이전 입력 activation 거부")
        var changedActive = document, editing = document.activePage
        editing.nodes[0].text += " 현재 페이지 수정"
        try changedActive.updateActivePageForEditing(editing)
        check(!changedActive.matchesPageActivation(snapshot),"편집 turn의 전체 revision도 입력 activation 무효화")
        try document.selectPage(b,expectedRevision:document.revision)
        try document.selectPage(a,expectedRevision:document.revision)
        check(!document.accepts(snapshot),"A→B→A 이전 비동기 snapshot 거부")
        check(!document.matchesPageActivation(snapshot),"A→B→A 이전 입력 activation 거부")
        let currentSnapshot = try document.pageSnapshot()
        check(document.matchesPageActivation(currentSnapshot) && document.accepts(currentSnapshot),"최신 입력 activation과 전체 바이트 검사 일치")
        let beforeStale = try document.bytes()
        refuses("오래된 revision 복제 거부") { _ = try document.duplicatePage(a,expectedRevision:-1) }
        check(try document.bytes() == beforeStale,"stale 실패 전체 바이트 보존")
        let folder = out.appendingPathComponent("files",isDirectory:true)
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        let old = CanvasFileWorkspace(folder:folder,requiresScope:false)
        _ = try old.save(page,preview:png,expected:nil)
        let files = CanvasDocumentFiles(folder:folder,requiresScope:false)
        let legacy = try files.load(page.id)
        check(legacy.legacy && legacy.document.pages == [page],"실제 구 Files 세대 전체 읽기")
        let previews = Dictionary(uniqueKeysWithValues:document.pages.map { ($0.id,png) })
        let saved = try files.save(document,previews:previews,expected:legacy.token)
        check(saved.document == document && !saved.legacy && !saved.publicationPending,"두 페이지와 모든 자산 발행 후 readback")
        check(try CanvasDocumentFiles(folder:folder,requiresScope:false).load(page.id).document == document,"새 Files 인스턴스 전체 재열기")
        refuses("구 Files reader는 새 head 거부") { _ = try old.load(page.id) }
        let dir = files.documentURL(document.id), pointer = dir.appendingPathComponent("current.json")
        let head = try JSONDecoder().decode(CanvasDocumentFiles.Head.self,from:Data(contentsOf:pointer))
        let hiddenInk = dir.appendingPathComponent("revisions/\(head.generation.uuidString.lowercased())/pages/\(page.id.uuidString.lowercased())/drawing.pkdrawing")
        let heldInk = hiddenInk.deletingLastPathComponent().appendingPathComponent("held-own-ink")
        try fm.moveItem(at:hiddenInk,to:heldInk)
        refusesFile(.corrupt,"비선택 페이지 자산 누락시 문서 전체 거부") { _ = try files.load(document.id) }
        try fm.moveItem(at:heldInk,to:hiddenInk)
        check(try files.load(document.id).document == document,"누락 복원 뒤 전체 재열기")
        var external = document, changed = external.pages[0]; changed.nodes[0].text += " 외부 수정"; changed.revision += 1
        try external.replacePage(changed,expectedRevision:external.revision)
        let winner = try files.save(external,previews:previews,expected:saved.token)
        let wonBytes = try Data(contentsOf:pointer)
        refusesFile(.conflict,"비선택 페이지 변경의 전체 CAS 충돌") { _ = try files.save(document,previews:previews,expected:saved.token) }
        check(try Data(contentsOf:pointer) == wonBytes && files.load(document.id).document == external,"CAS 충돌은 head와 모든 페이지 보존")
        let revisions = dir.appendingPathComponent("revisions")
        try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:revisions.path)
        refusesFile(.permission,"실제 디렉터리 권한 실패") { _ = try files.save(document,previews:previews,expected:winner.token) }
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:revisions.path)
        check(try files.load(document.id).document == external,"실제 IO 실패 후 전체 재열기")
        struct Injected: Error {}
        let before = CanvasDocumentFiles(folder:folder,requiresScope:false,hooks:.init(afterGeneration:{ throw Injected() }))
        refuses("generation 완료 뒤 head 전 주입 실패") { _ = try before.save(document,previews:previews,expected:winner.token) }
        check(try Data(contentsOf:pointer) == wonBytes && files.load(document.id).document == external,"head 마지막 교체 전 실패 원본 보존")
        let after = CanvasDocumentFiles(folder:folder,requiresScope:false,hooks:.init(afterExchange:{ throw Injected() }))
        refusesFile(.publicationUnconfirmed,"head 교환 후 실패를 성공으로 반환하지 않음") { _ = try after.save(document,previews:previews,expected:winner.token) }
        let uncertain = try files.load(document.id)
        check(uncertain.document == document && uncertain.publicationPending,"교환 후 전체 제안본 재열기와 durable 미확인 표시")
        refusesFile(.pending,"미확인 발행 뒤 자동 후속 쓰기 차단") { _ = try files.save(external,previews:previews,expected:uncertain.token) }
        let preserved = try fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("base-") }
        check(try preserved.contains { try Data(contentsOf:$0) == wonBytes },"교환 전 전체 원본 head 보존")
        let raceFolder = out.appendingPathComponent("race-files",isDirectory:true)
        try fm.createDirectory(at:raceFolder,withIntermediateDirectories:true)
        let race = CanvasDocumentFiles(folder:raceFolder,requiresScope:false)
        let r1 = try race.save(document,previews:previews,expected:nil)
        let raceDir = race.documentURL(document.id), racePointer = raceDir.appendingPathComponent("current.json")
        let h1 = try Data(contentsOf:racePointer)
        _ = try race.save(external,previews:previews,expected:r1.token)
        let h2 = try Data(contentsOf:racePointer)
        try h1.write(to:racePointer)
        let nonCooperator = CanvasDocumentFiles(folder:raceFolder,requiresScope:false,hooks:.init(beforeExchange:{ try h2.write(to:racePointer) }))
        // 실제 변경 저장으로 head 교환에 진입한다. 동일 문서 저장은 새 no-op 경로의 검사 대상이다.
        refusesFile(.publicationUnconfirmed,"CAS 확인 직후 외부 head 교환 경합 탐지") { _ = try nonCooperator.save(external,previews:previews,expected:r1.token) }
        let raceRead = try race.load(document.id)
        let stages = try fm.contentsOfDirectory(at:raceDir,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("head-") }
        check(raceRead.publicationPending && raceRead.document == external,"경합 뒤 원자적 전체 제안본 유지와 미확인 barrier")
        check(try stages.contains { try Data(contentsOf:$0) == h2 },"비협력 외부 head도 별도 보존하고 자동 rollback하지 않음")
        print("CANVAS_DOCUMENT_OK \(count)")
    }
}
