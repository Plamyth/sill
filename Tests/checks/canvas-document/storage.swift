import Foundation
import AppKit

@main struct StorageReuseChecks {
    static let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
    static var count = 0
    static func check(_ value: Bool, _ label: String) { precondition(value,label); count += 1; print("PASS",label) }
    static func reject(_ failure: CanvasDocumentFiles.Failure, _ label: String, _ body: () throws -> Void) {
        do { try body(); fatalError("accepted \(label)") }
        catch let actual as CanvasDocumentFiles.Failure { check(actual == failure,label) }
        catch { fatalError("wrong error \(label): \(error)") }
    }
    struct Member: Equatable { let bytes: Int; let sha: String }
    static func inventory(_ folder: URL) throws -> [String:Member] {
        let fm = FileManager.default
        let all = fm.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey])!
        var result: [String:Member] = [:]
        for case let p as URL in all {
            if try p.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
                let bytes = try Data(contentsOf:p)
                result[String(p.path.dropFirst(folder.path.count+1))] = Member(bytes:bytes.count,sha:CanvasPacket.sha(bytes))
            }
        }
        return result
    }
    static func changed(_ source: CanvasDocument, _ suffix: String) throws -> CanvasDocument {
        var next = source, page = source.pages[0]; page.nodes[0].text += suffix; page.revision += 1
        try next.replacePage(page,expectedRevision:source.revision); return next
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        let input = URL(fileURLWithPath:CommandLine.arguments[2])
        let document = try CanvasDocument.decode(Data(contentsOf:input)), fm = FileManager.default
        let previews = Dictionary(uniqueKeysWithValues:document.pages.map { ($0.id,png) })
        func folder(_ name: String) throws -> URL { let p=out.appendingPathComponent(name,isDirectory:true); try fm.createDirectory(at:p,withIntermediateDirectories:true); return p }
        func attempt(_ root: URL, _ snapshot: CanvasDocumentFiles.Snapshot) throws -> (URL,UUID) {
            let dir=CanvasDocumentFiles(folder:root,requiresScope:false).documentURL(document.id)
            let h=try JSONDecoder().decode(CanvasDocumentFiles.Head.self,from:Data(contentsOf:dir.appendingPathComponent("current.json")))
            return (root.appendingPathComponent("document-recovery-\(document.id.uuidString.lowercased())/\(h.generation.uuidString.lowercased())"),h.generation)
        }
        let root = try folder("normal"), files = CanvasDocumentFiles(folder:root,requiresScope:false)
        let initial = try files.save(document,previews:previews,expected:nil)
        let before = try inventory(root), beforePaths = try fm.subpathsOfDirectory(atPath:root.path)
        let same = try files.save(document,previews:previews,expected:initial.token)
        let afterSame = try inventory(root), afterSamePaths = try fm.subpathsOfDirectory(atPath:root.path)
        let sum: ([String:Member]) -> Int = { $0.values.reduce(0) { $0+$1.bytes } }
        #if !STORAGE_BASELINE
        check(before == afterSame && Set(beforePaths) == Set(afterSamePaths) && same.token == initial.token,"no-op 실제 파일 bytes/경로/generation/intent 추가 0")
        reject(.conflict,"no-op도 틀린 expected token 거부") { _ = try files.save(document,previews:previews,expected:String(repeating:"0",count:64)) }
        #endif
        let proposal = try changed(document," 저장공간 단위")
        let prior = try inventory(root), priorPaths = try fm.subpathsOfDirectory(atPath:root.path)
        let normal = try files.save(proposal,previews:previews,expected:same.token), after = try inventory(root)
        let afterPaths = try fm.subpathsOfDirectory(atPath:root.path)
        let (archive,generation) = try attempt(root,normal)
        let baseExists = fm.fileExists(atPath:archive.appendingPathComponent("base").path)
        #if !STORAGE_BASELINE
        check(!baseExists,"정상 변경 저장은 base 전체 세대 재복사 0")
        let base = try CanvasDocumentFiles(folder:root,requiresScope:false).recoveryBase(document.id,attemptID:generation)
        check(base.document == document && base.previews == previews,"새 인스턴스의 durable base 참조 전체 복구 readback")
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:archive.appendingPathComponent("attempt.json"))) as! [String:Any]
        check(reference["schema"] as? String == "ccr.document-publication/v2" && reference["baseReference"] != nil,"base 참조 형식과 owner가 attempt에 지속 저장")
        check(prior.allSatisfy { key,value in key.hasSuffix(".sill/current.json") || after[key] == value },"base 원본과 기존 recovery 바이트를 변경/삭제하지 않음")
        let next = try changed(proposal," 다음 저장")
        let second = try files.save(next,previews:previews,expected:normal.token), (_,secondID) = try attempt(root,second)
        check(try files.recoveryBase(document.id,attemptID:secondID).document == proposal,"연속 참조도 앞 proposal 전체를 독립 복구")
        let oldRoot=out.appendingPathComponent("782-committed",isDirectory:true)
        try fm.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true),to:oldRoot)
        let oldFiles=CanvasDocumentFiles(folder:oldRoot,requiresScope:false), oldSnap=try oldFiles.load(document.id)
        let upgraded=try oldFiles.save(changed(oldSnap.document," 기존 보존 참조"),previews:oldSnap.previews,expected:oldSnap.token)
        let (oldArchive,oldID)=try attempt(oldRoot,upgraded)
        check(!fm.fileExists(atPath:oldArchive.appendingPathComponent("base").path),"782 v1 committed 보존본도 재복사 없이 참조")
        check(try oldFiles.recoveryBase(document.id,attemptID:oldID).document == oldSnap.document,"782 v1 보존본 참조를 새 인스턴스로 전체 복구")
        let previewRoot = try folder("preview-change"), pf = CanvasDocumentFiles(folder:previewRoot,requiresScope:false)
        let p0=try pf.save(document,previews:previews,expected:nil)
        var different=previews;var otherPNG=png;otherPNG[otherPNG.count-1] ^= 1;different[document.pages[0].id]=otherPNG
        let p1=try pf.save(document,previews:different,expected:p0.token)
        check(p1.token != p0.token && p1.previews == different,"문서가 같아도 비선택 preview 변경은 실제 저장")
        var selected=document;try selected.selectPage(document.pages[0].id,expectedRevision:selected.revision)
        let p2=try pf.save(selected,previews:different,expected:p1.token)
        check(p2.token != p1.token,"현재 페이지/revision 변경을 no-op으로 숨기지 않음")
        let externalRoot=try folder("external-generation"), ef=CanvasDocumentFiles(folder:externalRoot,requiresScope:false)
        let e0=try ef.save(document,previews:previews,expected:nil), (eArchive,_)=try attempt(externalRoot,e0)
        try fm.moveItem(at:eArchive,to:eArchive.deletingLastPathComponent().appendingPathComponent("held-own-attempt"))
        let e1=try ef.save(proposal,previews:previews,expected:e0.token), (newArchive,eID)=try attempt(externalRoot,e1)
        check(fm.fileExists(atPath:newArchive.appendingPathComponent("base/current.json").path),"기존 stable 참조가 없는 외부 세대는 독립 base 전체 보존")
        check(try ef.recoveryBase(document.id,attemptID:eID).document == document,"독립 보존한 외부 base도 전체 복구 readback")
        let corruptRoot = try folder("corrupt-base"), cf=CanvasDocumentFiles(folder:corruptRoot,requiresScope:false)
        let c0=try cf.save(document,previews:previews,expected:nil), (cArchive,_)=try attempt(corruptRoot,c0)
        let material=cArchive.appendingPathComponent("proposal"), held=cArchive.appendingPathComponent("held-proposal")
        let replacement=cArchive.appendingPathComponent("replacement")
        try fm.copyItem(at:material,to:replacement)
        let badHead=replacement.appendingPathComponent("current.json");try Data("unknown".utf8).write(to:badHead)
        try fm.moveItem(at:material,to:held);try fm.moveItem(at:replacement,to:material)
        let corruptBefore=try inventory(corruptRoot)
        reject(.corrupt,"stable base 경로가 교체/손상되면 새 저장 전 명시 거부") { _ = try cf.save(proposal,previews:previews,expected:c0.token) }
        check(try inventory(corruptRoot) == corruptBefore,"손상 base 거부는 원본·보존본·경로를 그대로 유지")
        let unknownRoot=try folder("unknown-reference"), uf=CanvasDocumentFiles(folder:unknownRoot,requiresScope:false)
        let u0=try uf.save(document,previews:previews,expected:nil), u1=try uf.save(proposal,previews:previews,expected:u0.token)
        let (uArchive,uID)=try attempt(unknownRoot,u1), recordURL=uArchive.appendingPathComponent("attempt.json")
        var record=try JSONSerialization.jsonObject(with:Data(contentsOf:recordURL)) as! [String:Any]
        var ref=record["baseReference"] as! [String:Any];ref["documentID"]=UUID().uuidString;record["baseReference"]=ref
        try JSONSerialization.data(withJSONObject:record).write(to:recordURL)
        reject(.corrupt,"다른 문서 owner의 typed 참조는 복구 거부") { _ = try uf.recoveryBase(document.id,attemptID:uID) }
        ref["documentID"]=document.id.uuidString;ref["generationID"]="../outside";record["baseReference"]=ref
        try JSONSerialization.data(withJSONObject:record).write(to:recordURL)
        do { _ = try uf.recoveryBase(document.id,attemptID:uID);fatalError("path traversal") } catch { check(true,"UUID 이외 경로는 decode에서 거부") }
        let legacyRoot=try folder("legacy"), legacyFiles=CanvasFileWorkspace(folder:legacyRoot,requiresScope:false)
        let l0=try legacyFiles.save(document.pages[0],preview:png,expected:nil), legacyDoc=try CanvasDocument(legacy:document.pages[0])
        let lf=CanvasDocumentFiles(folder:legacyRoot,requiresScope:false), l1=try lf.save(legacyDoc,previews:[legacyDoc.id:png],expected:l0.token)
        let lHead=try JSONDecoder().decode(CanvasDocumentFiles.Head.self,from:Data(contentsOf:lf.documentURL(legacyDoc.id).appendingPathComponent("current.json")))
        let lArchive=legacyRoot.appendingPathComponent("document-recovery-\(legacyDoc.id.uuidString.lowercased())/\(lHead.generation.uuidString.lowercased())")
        check(fm.fileExists(atPath:lArchive.appendingPathComponent("base/current.json").path) && !l1.legacy,"legacy는 no-op/참조로 우회하지 않고 독립 base 보존")
        check(try lf.recoveryBase(legacyDoc.id,attemptID:lHead.generation).document == legacyDoc,"legacy 독립 base도 새 인스턴스에서 전체 읽기")
        for phase in ["beforeExchange","afterExchange"] {
            let r=try folder(phase), f=CanvasDocumentFiles(folder:r,requiresScope:false)
            let start=try f.save(document,previews:previews,expected:nil), (owner,_)=try attempt(r,start)
            let target=owner.appendingPathComponent("proposal"), held=owner.appendingPathComponent("held-proposal")
            let disrupt = { try fm.moveItem(at:target,to:held) }
            var hooks=CanvasDocumentFiles.Hooks();if phase == "beforeExchange" { hooks.beforeExchange=disrupt } else { hooks.afterExchange=disrupt }
            let raced=CanvasDocumentFiles(folder:r,requiresScope:false,hooks:hooks)
            if phase == "afterExchange" {
                reject(.publicationUnconfirmed,"교환 후 base 참조 교체는 미확인") { _ = try raced.save(proposal,previews:previews,expected:start.token) }
                let snap=try f.load(document.id), (_,id)=try attempt(r,snap)
                check(snap.publicationPending && snap.document == proposal,"교환 후 참조 실패도 지속 barrier와 제안 유지")
                let retained = try f.recoveryBase(document.id,attemptID:id)
                check(retained.document == document && retained.publicationPending,"실패 시 독립 base fallback 복구도 미확인 barrier를 해제하지 않음")
            } else {
                do { _ = try raced.save(proposal,previews:previews,expected:start.token);fatalError("changed base accepted") } catch { check(true,"교환 전 base 참조 경합 거부") }
                check(try f.load(document.id).document == document,"교환 전 참조 실패는 canonical 원본 유지")
            }
        }
        let noOpRoot=try folder("no-op-identity"), nf=CanvasDocumentFiles(folder:noOpRoot,requiresScope:false)
        let n0=try nf.save(document,previews:previews,expected:nil), canonical=nf.documentURL(document.id)
        let rival=noOpRoot.appendingPathComponent("rival"), detached=noOpRoot.appendingPathComponent("detached")
        try fm.copyItem(at:canonical,to:rival)
        let late=CanvasDocumentFiles(folder:noOpRoot,requiresScope:false,hooks:.init(afterNoOpReadback:{ try fm.moveItem(at:canonical,to:detached);try fm.moveItem(at:rival,to:canonical) }))
        reject(.publicationUnconfirmed,"no-op도 동일 내용 디렉터리 교체 identity 거부") { _ = try late.save(document,previews:previews,expected:n0.token) }
        let barrierRoot=try folder("barrier"), bf=CanvasDocumentFiles(folder:barrierRoot,requiresScope:false)
        let b0=try bf.save(document,previews:previews,expected:nil)
        let marker=barrierRoot.appendingPathComponent("document-pending-\(document.id.uuidString.lowercased()).json")
        try Data("미확인".utf8).write(to:marker)
        let heldBefore=try inventory(barrierRoot)
        reject(.pending,"불변 문서도 기존 미확인 barrier를 우회하지 않음") { _ = try bf.save(document,previews:previews,expected:b0.token) }
        check(try inventory(barrierRoot) == heldBefore,"barrier의 원문과 파일을 삭제/수정하지 않음")
        #endif
        let result:[String:Any] = ["checks":count,"normal":["bytesBefore":sum(prior),"bytesAfter":sum(after),"deltaBytes":sum(after)-sum(prior),"pathsBefore":prior.count,"pathsAfter":after.count,"newPaths":after.keys.filter { prior[$0] == nil }.count,"newAllPaths":Set(afterPaths).subtracting(priorPaths).count,"baseDirectoryCreated":baseExists],"noOp":["deltaBytes":sum(afterSame)-sum(before),"newPaths":afterSame.keys.filter { before[$0] == nil }.count,"newAllPaths":Set(afterSamePaths).subtracting(beforePaths).count,"sameToken":same.token == initial.token],"GUI":false,"productUI":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("storage-observations.json"))
        print("STORAGE_REUSE_OK",count)
    }
}
